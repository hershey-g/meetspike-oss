import Charts
import MeetspikeHRCore
import SwiftUI

/// Formats a time in the meeting's own zone, "9:45 AM".
func todayClock(_ date: Date, zone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
}

/// One decimal, "1.0" (`fmtLevel` in app.js).
func todayLevel(_ value: Double?) -> String {
    guard let value else { return "\u{2013}" }
    return String(format: "%.1f", (value * 10).rounded(.toNearestOrAwayFromZero) / 10)
}

/// Heart rate over the meeting with 10 minutes either side: the usual band behind it, the meeting shaded, and the
/// WHOOP stress line on a 0 to 3 scale (`hrChart` in app.js).
///
/// It only renders a `MeetingChartModel`, which is built once per loaded detail off the main actor. Nothing here is
/// proportional to the raw series, and the view is Equatable (use `.equatable()`), so a redraw of Today with the same
/// model and zone does not rebuild the chart marks.
struct MeetingHRChart: View, Equatable {
    let model: MeetingChartModel
    let zone: TimeZone

    private var span: Double { max(1, model.high - model.low) }

    /// Stress levels 0 to 3 drawn over the full height, like the web chart.
    private func stressY(_ level: Double) -> Double { model.low + (max(0, min(3, level)) / 3) * span }

    private func color(for provider: String) -> Color {
        provider == "Oura" && model.sourceLabel == "WHOOP + Oura" ? TodayPalette.sleep : TodayPalette.strain
    }

    var body: some View {
        let stress = model.stress
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                if let band = model.band {
                    RectangleMark(xStart: .value("From", model.from), xEnd: .value("To", model.to),
                                  yStart: .value("Usual low", band.lowerBound), yEnd: .value("Usual high", band.upperBound))
                        .foregroundStyle(TodayPalette.sleep.opacity(0.16))
                }
                if let meetingStart = model.meetingStart, let meetingEnd = model.meetingEnd {
                    RectangleMark(xStart: .value("Start", meetingStart), xEnd: .value("End", meetingEnd),
                                  yStart: .value("Low", model.low), yEnd: .value("High", model.high))
                        .foregroundStyle(TodayPalette.strain.opacity(0.07))
                    RuleMark(x: .value("Start", meetingStart))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .foregroundStyle(.secondary.opacity(0.7))
                    RuleMark(x: .value("End", meetingEnd))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                if stress.count > 1 {
                    ForEach(Array(stress.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.date), y: .value("Stress", stressY(point.level)),
                                 series: .value("Series", "stress"))
                            .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                            .foregroundStyle(Theme.warn)
                    }
                } else if let only = stress.first {
                    PointMark(x: .value("Time", only.date), y: .value("Stress", stressY(only.level)))
                        .symbolSize(18)
                        .foregroundStyle(Theme.warn)
                }
                ForEach(model.segments) { segment in
                    if segment.points.count == 1, let point = segment.points.first {
                        PointMark(x: .value("Time", point.date), y: .value("BPM", point.bpm))
                            .symbolSize(20)
                            .foregroundStyle(color(for: segment.provider))
                    } else {
                        ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("Time", point.date), y: .value("BPM", point.bpm),
                                     series: .value("Series", "hr-\(segment.id)"))
                                .lineStyle(StrokeStyle(lineWidth: 2.2, lineJoin: .round))
                                .foregroundStyle(color(for: segment.provider))
                        }
                    }
                }
            }
            .chartXScale(domain: model.from...model.to)
            .chartYScale(domain: model.low...model.high)
            .chartXAxis {
                AxisMarks(values: edgeDates) { value in
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                        if let date = value.as(Date.self) {
                            Text(todayClock(date, zone: zone)).font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel().font(.caption2)
                }
                if !stress.isEmpty {
                    AxisMarks(position: .trailing, values: (0...3).map { model.low + Double($0) / 3 * span }) { value in
                        AxisValueLabel {
                            if let y = value.as(Double.self) {
                                Text("\(Int(((y - model.low) / span * 3).rounded()))").font(.caption2).foregroundStyle(Theme.warn)
                            }
                        }
                    }
                }
            }
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)

            legend
        }
    }

    private var edgeDates: [Date] { [model.meetingStart ?? model.from, model.meetingEnd ?? model.to] }

    private var spoken: String {
        let source = model.sourceLabel
        var text = "\(source) heart rate from \(Int((model.minBpm ?? 0).rounded())) to \(Int((model.maxBpm ?? 0).rounded())) bpm during the meeting"
        if let mean = model.usualMeanBpm { text += ", WHOOP usual about \(Int(mean.rounded()))" }
        if !model.stress.isEmpty { text += ", WHOOP stress up to \(todayLevel(model.peakStress)) of 3" }
        return text
    }

    private var legend: some View {
        let source = model.sourceLabel
        var parts: [Text] = []
        let dot = { (name: String, color: Color) in Text(Image(systemName: name)).foregroundColor(color) }
        if source == "WHOOP + Oura" {
            parts.append(dot("circle.fill", TodayPalette.strain) + Text(" WHOOP "))
            parts.append(dot("circle.fill", TodayPalette.sleep) + Text(" Oura heart rate"))
        } else {
            parts.append(dot("circle.fill", TodayPalette.strain) + Text(" \(source) heart rate"))
        }
        if let band = model.band {
            parts.append(dot("rectangle.fill", TodayPalette.sleep.opacity(0.5))
                + Text(" Your WHOOP usual (\(Int(band.lowerBound.rounded()))\u{2013}\(Int(band.upperBound.rounded())))"))
        }
        if !model.stress.isEmpty {
            parts.append(dot("minus", Theme.warn) + Text(" WHOOP Stress (0\u{2013}3)"))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(parts.indices, id: \.self) { parts[$0] } }
            VStack(alignment: .leading, spacing: 2) { ForEach(parts.indices, id: \.self) { parts[$0] } }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// The small line shown while the full detail loads, from the series that came with the day. It only draws a
/// `MeetingSparklineModel` (thinned, built once per day load), so a redraw never walks the raw series.
struct MeetingSparkline: View, Equatable {
    let model: MeetingSparklineModel

    var body: some View {
        Chart {
            ForEach(Array(model.points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.date), y: .value("BPM", point.bpm))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineJoin: .round))
                    .foregroundStyle(TodayPalette.strain)
            }
        }
        .chartYScale(domain: (model.minBpm - 4)...(model.maxBpm + 4))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 64)
        .accessibilityLabel(
            "Heart rate during the meeting, \(Int(model.minBpm.rounded())) to \(Int(model.maxBpm.rounded())) bpm")
    }
}
