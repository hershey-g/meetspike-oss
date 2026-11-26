import MeetspikeHRCore
import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widget content. The family is passed in so the
/// Debug gallery in the app can render every size too.
struct GlanceWidgetView: View {
    let entry: GlanceEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .systemMedium: GlanceMediumWidget(entry: entry)
            case .accessoryRectangular: GlanceRectangularWidget(entry: entry)
            case .accessoryCircular: GlanceCircularWidget(entry: entry)
            default: GlanceSmallWidget(entry: entry)
            }
        }
        // Widgets have a fixed size; past this the layout cannot fit.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .combine)
    }

    static func isSystem(_ family: WidgetFamily) -> Bool {
        family == .systemSmall || family == .systemMedium
    }
}

private extension GlanceEntry {
    var isLive: Bool { if case .latest = heart { true } else { false } }
    var title: String { meeting?.title ?? "No meetings ahead" }
    var peakDetail: String? { if case .peak(_, let title) = heart { title } else { nil } }
}

struct GlanceSmallWidget: View {
    let entry: GlanceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                GlanceRing(progress: entry.progress, lineWidth: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GlanceColor.spike)
                }
                .frame(width: 30, height: 30)
                Spacer()
                Text(entry.heartCaption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(entry.isLive ? GlanceColor.spike : GlanceColor.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(GlanceText.bpm(entry.bpm))
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(GlanceColor.text)
                    .minimumScaleFactor(0.6)
                Text("BPM")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GlanceColor.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GlanceText.bpmAccessibility(entry.bpm))
            Spacer(minLength: 4)
            Text(entry.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlanceColor.text)
                .lineLimit(1)
            // With no meeting the title already says "No meetings ahead".
            if entry.meeting != nil {
                GlanceText.countdownLine(entry)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(GlanceColor.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

struct GlanceMediumWidget: View {
    let entry: GlanceEntry

    var body: some View {
        HStack(spacing: 16) {
            GlanceRing(progress: entry.progress, lineWidth: 8) {
                VStack(spacing: 0) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(GlanceColor.spike)
                    Text(GlanceText.bpm(entry.bpm))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(GlanceColor.text)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("BPM")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GlanceColor.secondary)
                }
                .padding(10)
            }
            .frame(width: 112, height: 112)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GlanceText.bpmAccessibility(entry.bpm))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.heartCaption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.isLive ? GlanceColor.spike : GlanceColor.secondary)
                if let peak = entry.peakDetail {
                    Text(peak)
                        .font(.caption)
                        .foregroundStyle(GlanceColor.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(entry.meeting == nil ? "" : (entry.countdown.isUnderway ? "In progress" : "Next meeting"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GlanceColor.secondary)
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(GlanceColor.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if entry.meeting != nil {
                    GlanceText.countdownLine(entry)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(entry.countdown.isUnderway ? GlanceColor.spike : GlanceColor.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GlanceRectangularWidget: View {
    let entry: GlanceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").widgetAccentable()
                Text("\(GlanceText.bpm(entry.bpm)) BPM").fontWeight(.semibold)
                Text(entry.heartCaption).foregroundStyle(.secondary)
            }
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(GlanceText.bpmAccessibility(entry.bpm)), \(entry.heartCaption)")
            Text(entry.title)
                .font(.subheadline)
                .lineLimit(1)
            if entry.meeting != nil {
                GlanceText.countdownLine(entry)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Three lines in a 76-point-tall slot: larger text cannot fit.
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

struct GlanceCircularWidget: View {
    let entry: GlanceEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            GlanceRing(progress: entry.progress, lineWidth: 4, tint: .primary, track: .primary.opacity(0.2))
                .widgetAccentable()
                .padding(2)
            VStack(spacing: -1) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .bold))
                    .widgetAccentable()
                Text(GlanceText.bpm(entry.bpm))
                    .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(GlanceText.bpmAccessibility(entry.bpm)), \(entry.heartCaption)")
    }
}

private extension GlanceEntry.Countdown {
    var isUnderway: Bool { if case .endsIn = self { true } else { false } }
}

/// Fixed data for placeholders, previews and the Debug gallery.
enum GlanceSamples {
    static func snapshot(now: Date = .now) -> GlanceSnapshot {
        GlanceSnapshot(
            meetings: [
                .init(title: "Weekly pipeline review", start: now.addingTimeInterval(-17 * 60), end: now.addingTimeInterval(13 * 60)),
                .init(title: "Design sync with Olive", start: now.addingTimeInterval(45 * 60), end: now.addingTimeInterval(90 * 60)),
            ],
            latestBPM: 78, latestAt: now.addingTimeInterval(-4),
            lastPeak: GlancePeak(title: "Weekly pipeline review", bpm: 94, blockStart: now.addingTimeInterval(-19 * 60),
                                 end: now.addingTimeInterval(23 * 60)),
            listening: true
        )
    }

    static func entry(now: Date = .now) -> GlanceEntry {
        GlanceEntry(snapshot: snapshot(now: now), at: now)
    }

    static func activity(now: Date = .now, status: LiveGlanceStatus = .live) -> LiveGlanceContent {
        LiveGlanceContent(
            bpm: 78, status: status, title: "Weekly pipeline review", phase: .endsIn,
            timerFrom: now.addingTimeInterval(-17 * 60 - 20), timerTo: now.addingTimeInterval(12 * 60 + 40),
            meetingStart: now.addingTimeInterval(-17 * 60 - 20), meetingEnd: now.addingTimeInterval(12 * 60 + 40),
            canExtend: true, canEnd: true
        )
    }
}
