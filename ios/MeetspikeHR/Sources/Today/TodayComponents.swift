import MeetspikeHRCore
import SwiftUI
import UIKit

/// Today's own colours. `Theme` has good / warn / bad; strain and sleep come from public/app.css (--strain, --sleep).
enum TodayPalette {
    static let strain = color(0x2F9BEA)
    static let sleep = color(0x8FB3D1)
    /// Text on a filled good / warn / bad pill.
    static let onFill = color(0x15191E)

    static func color(_ tone: TodayTone) -> Color {
        switch tone {
        case .good: Theme.good
        case .warn: Theme.warn
        case .bad: Theme.bad
        case .none: .secondary
        }
    }

    static func color(_ tone: TodayTrend.Tone) -> Color {
        switch tone {
        case .good: Theme.good
        case .bad: Theme.bad
        case .flat: .secondary
        }
    }

    private static func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

/// Small uppercase heading used on every card.
struct TodayKicker: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Date bar

/// Previous day, the day label (a button that opens the date picker), next day.
struct TodayDateBar: View {
    let label: String
    let sub: String
    let canGoNext: Bool
    let pickDate: () -> Void
    let previous: () -> Void
    let next: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var dayText: some View {
        Text(label).font(.subheadline.weight(.semibold)).textCase(.uppercase).tracking(0.8)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: previous) {
                Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 48)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Previous day")

            Button(action: pickDate) {
                Group {
                    if typeSize.isAccessibilitySize {
                        // Room is short: the date goes under the day word instead of being cut off.
                        VStack(spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar").foregroundStyle(.secondary).accessibilityHidden(true)
                                dayText
                            }
                            if !sub.isEmpty { Text(sub).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar").foregroundStyle(.secondary).accessibilityHidden(true)
                            dayText
                            if !sub.isEmpty { Text("\u{B7} \(sub)").font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the date picker")

            Button(action: next) {
                Image(systemName: "chevron.right").font(.headline).frame(width: 44, height: 48)
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(!canGoNext)
            .accessibilityLabel("Next day")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: Rings

struct TodayRingModel: Identifiable {
    let id: String
    let label: String
    let value: String
    let progress: Double
    let color: Color
    let note: String
    let spoken: String
}

struct TodayRing: View {
    let ring: TodayRingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Theme.inset, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0, min(1, ring.progress)))
                    .stroke(ring.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: ring.progress)
                Text(ring.value)
                    .font(.title3.weight(.bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: 104)
            .aspectRatio(1, contentMode: .fit)
            Text(ring.label)
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .multilineTextAlignment(.center)
            Text(ring.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ring.spoken)
    }
}

// MARK: Compare to usual

/// One "against your usual" row (`metricRow` in app.js).
struct TodayMetric: Identifiable {
    let id: String
    let name: String
    let value: String
    let usual: String?
    let trend: TodayTrend

    init?(
        name: String, value: Double?, usual: Double?, unit: String = "", higherIs: TodayHigherIs = .better,
        step: Double = 1, words: TodayTrendWords = .higherLower
    ) {
        guard let value, let trend = TodayLogic.metricTrend(
            value: value, usual: usual, step: step, higherIs: higherIs, words: words) else { return nil }
        self.id = name
        self.name = name
        self.value = TodayFormat.number(value) + unit
        self.usual = usual.map { "usual \(TodayFormat.number($0))\(unit)" }
        self.trend = trend
    }
}

struct TodayMetricRow: View {
    let metric: TodayMetric

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                name
                Spacer(minLength: 8)
                numbers
                trend.frame(minWidth: 72, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                name
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    numbers
                    Spacer(minLength: 8)
                    trend
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var name: some View {
        Text(metric.name).font(.subheadline).foregroundStyle(.secondary)
    }

    private var numbers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metric.value).font(.body.weight(.bold))
            if let usual = metric.usual { Text(usual).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var trend: some View {
        HStack(spacing: 4) {
            switch metric.trend.direction {
            case .up: Text("\u{25B2}").font(.caption2)
            case .down: Text("\u{25BC}").font(.caption2)
            case .usual, .none: EmptyView()
            }
            Text(metric.trend.text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(TodayPalette.color(metric.trend.tone))
    }

    private var spoken: String {
        var parts = [metric.name, metric.value]
        if let usual = metric.usual { parts.append(usual) }
        if !metric.trend.text.isEmpty { parts.append(metric.trend.text) }
        return parts.joined(separator: ", ")
    }
}

// MARK: Pills

struct TodayPill: View {
    let tone: TodayTone
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .foregroundStyle(tone == .none ? Color.secondary : TodayPalette.onFill)
            .background {
                if tone == .none {
                    Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                } else {
                    Capsule().fill(TodayPalette.color(tone))
                }
            }
    }
}

// MARK: Timeline

/// Meetings between 7 am and 9 pm as bars on a strip.
struct TodayTimeline: View {
    let events: [Meeting]

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.background)
                    ForEach(events) { event in
                        if let bar = TodayLogic.timelineBar(startLocal: event.startLocal, durationS: event.durationS) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(bar.afterHours ? TodayPalette.strain : TodayPalette.sleep)
                                .frame(width: max(3, proxy.size.width * bar.width), height: proxy.size.height - 8)
                                .offset(x: proxy.size.width * bar.left)
                        }
                    }
                }
            }
            .frame(height: 28)
            TimelineLabels(ticks: [(7, "7 AM"), (11, "11 AM"), (15, "3 PM"), (18, "6 PM"), (21, "9 PM")])
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meetings between 7 am and 9 pm")
    }
}

/// Hour labels under the strip. Each sits at its real x on the same 7 am to 9 pm scale as the bars. The first label
/// starts at the left edge and the last ends at the right edge, so nothing is clipped. A middle label that would touch
/// a neighbour at large text sizes is dropped.
private struct TimelineLabels: View {
    let ticks: [(hour: Double, text: String)]

    var body: some View {
        TimelineLabelLayout {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                Text(tick.text)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutValue(key: TimelineFraction.self, value: tick.hour)
            }
        }
        .clipped()
    }
}

private struct TimelineFraction: LayoutValueKey {
    static let defaultValue: Double = 7
}

private struct TimelineLabelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gap: CGFloat = 8
        let span = TodayLogic.timelineToHour - TodayLogic.timelineFromHour
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // Left edge of each label: centred on its hour, then kept inside the bounds.
        let lefts: [CGFloat] = subviews.indices.map { index in
            let fraction = (subviews[index][TimelineFraction.self] - TodayLogic.timelineFromHour) / span
            let centre = bounds.minX + bounds.width * CGFloat(fraction)
            return min(max(centre - sizes[index].width / 2, bounds.minX), bounds.maxX - sizes[index].width)
        }
        let last = subviews.count - 1
        var kept: [Int] = [0]
        if last > 0 { kept.append(last) }
        // Middle labels, in order, are kept when they clear everything already kept.
        if last > 1 {
            for index in 1..<last {
                let clear = kept.allSatisfy { other in
                    lefts[index] + sizes[index].width + gap <= lefts[other]
                        || lefts[other] + sizes[other].width + gap <= lefts[index]
                }
                if clear { kept.append(index) }
            }
        }
        for index in subviews.indices {
            if kept.contains(index) {
                subviews[index].place(
                    at: CGPoint(x: lefts[index], y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
            } else {
                // Off to the side; the container clips it.
                subviews[index].place(
                    at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
            }
        }
    }
}
