import MeetspikeHRCore
import SwiftUI

/// What a Live Activity view needs. `isStale` comes from ActivityKit when the
/// app has not updated in a while, which means readings stopped arriving.
struct GlanceActivityModel {
    var state: LiveGlanceContent
    var isStale: Bool
    var now: Date

    init(state: LiveGlanceContent, isStale: Bool = false, now: Date = .now) {
        self.state = state
        self.isStale = isStale
        self.now = now
    }

    var status: LiveGlanceStatus { isStale ? .waiting : state.status }
    /// Only a live reading shows a number; anything older would mislead.
    var bpm: Int? { status == .live ? state.bpm : nil }
    var progress: Double { state.progress(at: now) }
    /// What the compact trailing slot says, from the shared rule.
    var compactLabel: CompactLabel { state.compactLabel(now: now) }
    /// "In meeting · title" while the meeting is on.
    var titleLine: String { state.titleLine }

    var accessibilitySummary: String {
        "\(GlanceText.bpmAccessibility(bpm)). \(status.label). \(titleLine)."
    }
}

/// The Lock Screen and notification banner presentation.
struct GlanceLockScreenView: View {
    let model: GlanceActivityModel
    /// The title line; "In meeting · title" while the meeting is on. Defaults to the model's.
    var title: String?

    var body: some View {
        VStack(spacing: 12) {
            readout
            GlanceAdjustButtons(state: model.state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .contain)
    }

    private var readout: some View {
        HStack(spacing: 14) {
            GlanceRing(progress: model.progress, lineWidth: 5) {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(model.status == .live ? GlanceColor.spike : GlanceColor.secondary)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? model.titleLine)
                    .font(.headline)
                    .foregroundStyle(GlanceColor.text)
                    .lineLimit(1)
                GlanceText.timerLine(model.state)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(GlanceColor.secondary)
                    .lineLimit(1)
                GlanceStatusLabel(status: model.status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(GlanceText.bpm(model.bpm))
                    .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(GlanceColor.text)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("BPM")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GlanceColor.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(GlanceText.bpmAccessibility(model.bpm))
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Still going" and "Ended now" under the readout, only while the app says they apply. They are Live Activity
/// intents: the app runs them, this extension only draws them. At least 44 pt tall.
struct GlanceAdjustButtons: View {
    let state: LiveGlanceContent

    var body: some View {
        if state.canExtend == true || state.canEnd == true {
            HStack(spacing: 10) {
                if state.canExtend == true {
                    Button(intent: StillGoingIntent()) { label("Still going", "plus.circle") }
                        .accessibilityLabel("Still going")
                        .accessibilityHint("Adds 15 minutes to this meeting")
                }
                if state.canEnd == true {
                    Button(intent: EndedNowIntent()) { label("Ended now", "stop.circle") }
                        .accessibilityLabel("Ended now")
                        .accessibilityHint("Ends this meeting now")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(GlanceColor.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(GlanceColor.secondary.opacity(0.22), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Compact leading: the heart and the BPM.
struct GlanceIslandCompactLeading: View {
    let model: GlanceActivityModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .foregroundStyle(GlanceColor.status(model.status))
            Text(GlanceText.bpm(model.bpm))
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(GlanceColor.text)
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GlanceText.bpmAccessibility(model.bpm))
    }
}

/// Compact trailing: how long the meeting has left, so the island says a meeting is on. Minutes left is a
/// self-updating timer, so it needs no app wake. The wrap-up tail keeps the small green ring.
struct GlanceIslandCompactTrailing: View {
    let model: GlanceActivityModel
    var label: CompactLabel

    init(model: GlanceActivityModel, label: CompactLabel? = nil) {
        self.model = model
        self.label = label ?? model.compactLabel
    }

    var body: some View {
        switch label {
        case .ring:
            GlanceRing(progress: model.progress, lineWidth: 3)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        case .minutesLeft(let minutes, let end):
            timer(end: end, showsHours: minutes >= 60)
                .accessibilityLabel("\(minutes) minutes left")
        case .lessThanAMinute(let end):
            timer(end: end, showsHours: false)
                .accessibilityLabel("Less than a minute left")
        case .startsIn, .live:
            Text(label.text ?? "")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(label == .live ? GlanceColor.spike : GlanceColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
    }

    private func timer(end: Date, showsHours: Bool) -> some View {
        Text(timerInterval: model.state.timerFrom...max(end, model.state.timerFrom), countsDown: true, showsHours: showsHours)
            .font(.system(.footnote, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(GlanceColor.text)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: showsHours ? 52 : 40, alignment: .trailing)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// Minimal: the ring with the heart inside, when another app shares the island.
struct GlanceIslandMinimal: View {
    let model: GlanceActivityModel

    var body: some View {
        GlanceRing(progress: model.progress, lineWidth: 2.5) {
            Image(systemName: "heart.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(GlanceColor.status(model.status))
        }
        .frame(width: 22, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GlanceText.bpmAccessibility(model.bpm))
    }
}

/// Expanded leading region: big BPM.
struct GlanceIslandExpandedLeading: View {
    let model: GlanceActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(GlanceColor.status(model.status))
                Text("BPM").font(.caption2.weight(.semibold)).foregroundStyle(GlanceColor.secondary)
            }
            .font(.caption)
            Text(GlanceText.bpm(model.bpm))
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(GlanceColor.text)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 6)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GlanceText.bpmAccessibility(model.bpm))
    }
}

/// Expanded trailing region: the meeting progress ring.
struct GlanceIslandExpandedTrailing: View {
    let model: GlanceActivityModel

    var body: some View {
        GlanceRing(progress: model.progress, lineWidth: 4.5) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GlanceColor.text)
        }
        .frame(width: 46, height: 46)
        .padding(.trailing, 6)
        .accessibilityHidden(true)
    }
}

/// Expanded center and bottom: title, timer and status.
struct GlanceIslandExpandedBottom: View {
    let model: GlanceActivityModel
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title ?? model.titleLine)
                    .font(.headline)
                    .foregroundStyle(GlanceColor.text)
                    .lineLimit(1)
                HStack {
                    GlanceText.timerLine(model.state)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(GlanceColor.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    GlanceStatusLabel(status: model.status)
                }
            }
            .accessibilityElement(children: .combine)
            GlanceAdjustButtons(state: model.state).padding(.top, 4)
        }
        .padding(.horizontal, 6)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}
