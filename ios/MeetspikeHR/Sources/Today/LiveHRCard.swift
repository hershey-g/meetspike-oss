import Charts
import MeetspikeHRCore
import SwiftUI

/// Polls `live-hr` for one meeting every 5 seconds while it runs (`pollLivePanel` in app.js, live-hr.js).
/// The loop lives in a `.task`, so it stops when the card leaves the screen, the tab changes or the app goes
/// to the background.
@MainActor
final class LiveHRWatcher: ObservableObject {
    let meetingID: String
    @Published private(set) var session: TodayLiveSession
    /// Not published: the card's 1 second clock asks for the chart on every tick, and nothing is rescanned until a reading
    /// arrives or the clock passes a moment that changes the answer (see `LiveChartMemo`).
    private var memo = LiveChartMemo()

    init(meetingID: String, window: LiveWindowMs) {
        self.meetingID = meetingID
        session = TodayLiveSession(window: window)
    }

    /// The chart for `nowMs`, thinned to about 400 drawn points, without rescanning the readings on a quiet tick.
    /// The meeting was made longer or shorter: poll across the new window.
    func update(window: LiveWindowMs) {
        if session.window != window { session.window = window }
    }

    func chart(nowMs: Double) -> TodayLiveChart {
        memo.chart(points: session.points, window: session.window, nowMs: nowMs)
    }

    func run(env: AppEnvironment) async {
        while !Task.isCancelled {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if nowMs >= session.window.toMs {
                session.status = "Live window ended"
                return
            }
            let requested = session.cursor
            do {
                let reply = try await env.api.liveHR(meetingID: meetingID, since: requested)
                if Task.isCancelled { return }
                session.apply(reply, requestedCursor: requested)
                env.noteOnline()
            } catch is CancellationError {
                return
            } catch let error as APIError {
                if Task.isCancelled { return }
                env.report(error)
                if !session.apply(error) { return }
            } catch {
                if Task.isCancelled { return }
                session.noteFailure()
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(session.pollDelay * 1_000_000_000))
            } catch {
                return
            }
        }
    }
}

/// The live WHOOP heart rate card on an open, running meeting.
struct LiveHRCard: View {
    let meetingID: String
    let window: LiveWindowMs
    /// "Still going" and "Ended now". Nil when the meeting is not known well enough to change.
    var adjust: LiveAdjustTarget?
    let timeZone: TimeZone
    /// False when the app is in the background or the tab is not showing: polling stops.
    let isActive: Bool

    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var watcher: LiveHRWatcher

    init(meetingID: String, window: LiveWindowMs, adjust: LiveAdjustTarget? = nil, timeZone: TimeZone, isActive: Bool) {
        self.meetingID = meetingID
        self.window = window
        self.adjust = adjust
        self.timeZone = timeZone
        self.isActive = isActive
        _watcher = StateObject(wrappedValue: LiveHRWatcher(meetingID: meetingID, window: window))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .task(id: LoopKey(isActive: isActive, until: window.toMs)) {
            guard isActive else { return }
            watcher.update(window: window)
            await watcher.run(env: env)
        }
    }

    private struct LoopKey: Equatable {
        var isActive: Bool
        var until: Double
    }

    private func content(now: Date) -> some View {
        let session = watcher.session
        let chart = watcher.chart(nowMs: now.timeIntervalSince1970 * 1000)
        let message = session.message(for: chart)
        let receiving = chart.current != nil && session.status.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live WHOOP heart rate").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(receiving ? Theme.good : .secondary)
                    .multilineTextAlignment(.trailing)
            }
            LiveAdjustButtons(target: adjust, now: now)
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(bpmText(chart)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("bpm").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if chart.last != nil && chart.current == nil {
                        Text("Last reading").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 16) {
                    stat("Min", chart.stats?.min)
                    stat("Avg", chart.stats?.avg)
                    stat("Max", chart.stats?.max)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statsSpoken(chart))
            }
            if chart.last != nil, let extent = chart.extent {
                LiveHRPlot(segments: chart.segments, last: chart.last, window: session.window, extent: extent, zone: timeZone)
                    .equatable()
                HStack(spacing: 14) {
                    Label("Meeting start", systemImage: "line.diagonal").labelStyle(.titleAndIcon)
                    Label("10-min pads", systemImage: "rectangle.fill")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
        .padding(12)
        .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func bpmText(_ chart: TodayLiveChart) -> String {
        if let current = chart.current { return String(current) }
        if let last = chart.last { return String(Int(last.bpm.rounded())) }
        return "\u{2013}"
    }

    private func stat(_ name: String, _ value: Int?) -> some View {
        VStack(spacing: 0) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "\u{2013}").font(.headline).monospacedDigit()
        }
    }

    private func statsSpoken(_ chart: TodayLiveChart) -> String {
        guard let stats = chart.stats else { return "During the meeting: no readings yet" }
        return "During the meeting, minimum \(stats.min), average \(stats.avg), maximum \(stats.max) beats per minute"
    }
}

/// The live trace across the padded window: pads shaded, meeting start marked, smooth line with a soft fill.
///
/// Equatable on exactly what it draws (use `.equatable()`), so the card's 1 second tick does not rebuild the marks: the
/// plot redraws only when a reading arrives, the window moves or a reading becomes due. The segments are already
/// thinned to about 400 points.
private struct LiveHRPlot: View, Equatable {
    let segments: [[LivePoint]]
    let last: LivePoint?
    let window: LiveWindowMs
    let extent: ClosedRange<Double>
    let zone: TimeZone

    private var step: Double { max(5, (((extent.upperBound - extent.lowerBound + 8) / 20).rounded(.up)) * 5) }
    private var low: Double { ((extent.lowerBound - 4) / step).rounded(.down) * step }
    private var high: Double { ((extent.upperBound + 4) / step).rounded(.up) * step }

    private func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    var body: some View {
        Chart {
            RectangleMark(xStart: .value("From", date(window.fromMs)), xEnd: .value("Start", date(window.startMs)),
                          yStart: .value("Low", low), yEnd: .value("High", high))
                .foregroundStyle(.secondary.opacity(0.12))
            RectangleMark(xStart: .value("End", date(window.endMs)), xEnd: .value("To", date(window.toMs)),
                          yStart: .value("Low", low), yEnd: .value("High", high))
                .foregroundStyle(.secondary.opacity(0.12))
            RuleMark(x: .value("Start", date(window.startMs)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(TodayPalette.sleep)
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if segment.count == 1, let only = segment.first {
                    PointMark(x: .value("Time", date(only.ms)), y: .value("BPM", only.bpm))
                        .symbolSize(14)
                        .foregroundStyle(TodayPalette.strain)
                } else {
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, point in
                        AreaMark(x: .value("Time", date(point.ms)), yStart: .value("Low", low), yEnd: .value("BPM", point.bpm),
                                 series: .value("Fill", "fill-\(index)"))
                            .interpolationMethod(.monotone)
                            // A plain fill: a gradient on every mark costs a lot more to draw.
                            .foregroundStyle(TodayPalette.strain.opacity(0.16))
                        LineMark(x: .value("Time", date(point.ms)), y: .value("BPM", point.bpm),
                                 series: .value("Line", "line-\(index)"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                            .foregroundStyle(TodayPalette.strain)
                    }
                }
            }
            if let last {
                PointMark(x: .value("Time", date(last.ms)), y: .value("BPM", last.bpm))
                    .symbolSize(40)
                    .foregroundStyle(TodayPalette.strain)
            }
        }
        .chartXScale(domain: date(window.fromMs)...date(window.toMs))
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks(values: [date(window.fromMs), date(window.toMs)]) { value in
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                    if let d = value.as(Date.self) { Text(todayClock(d, zone: zone)).font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: low, through: high, by: step))) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel().font(.caption2)
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "WHOOP heart rate ranged from \(Int(extent.lowerBound.rounded())) to \(Int(extent.upperBound.rounded())) beats per minute across the padded meeting window")
    }
}
