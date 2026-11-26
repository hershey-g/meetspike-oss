import ActivityKit
import MeetspikeHRCore
import SwiftUI

/// Shared by the app and the widget extension: the Live Activity attributes.
/// Everything that changes lives in the content state, so one activity can
/// follow back-to-back meetings in the same listening block.
struct MeetspikeActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveGlanceContent
}

/// Colors for the Live Activity and widgets: WHOOP-style charcoal with the
/// Meetspike spike green, matching the app icon. Kept here, not in Theme, so
/// the widget extension does not need the app's UIKit theme.
enum GlanceColor {
    static let charcoal = rgb(0x15191E)
    static let panel = rgb(0x23282F)
    static let spike = rgb(0x4ADE6A)
    static let amber = rgb(0xF5C542)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.64)
    static let track = Color.white.opacity(0.16)

    static func status(_ status: LiveGlanceStatus) -> Color {
        switch status {
        case .live: spike
        case .reconnecting: amber
        case .waiting: secondary
        }
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}


/// The icon's green progress ring: how much of the meeting has passed.
struct GlanceRing<Center: View>: View {
    var progress: Double
    var lineWidth: CGFloat
    var tint: Color = GlanceColor.spike
    var track: Color = GlanceColor.track
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

extension GlanceRing where Center == EmptyView {
    init(progress: Double, lineWidth: CGFloat, tint: Color = GlanceColor.spike, track: Color = GlanceColor.track) {
        self.init(progress: progress, lineWidth: lineWidth, tint: tint, track: track) { EmptyView() }
    }
}

/// A small colored dot and a word, for example "Live".
struct GlanceStatusLabel: View {
    let status: LiveGlanceStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(GlanceColor.status(status)).frame(width: 6, height: 6)
            Text(status.label).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(GlanceColor.status(status))
        .accessibilityElement(children: .combine)
    }
}

enum GlanceText {
    static func bpm(_ bpm: Int?) -> String { bpm.map(String.init) ?? "--" }

    static func bpmAccessibility(_ bpm: Int?) -> String {
        bpm.map { "Heart rate \($0) beats per minute" } ?? "No heart rate yet"
    }

    /// The running timer for a Live Activity. Counts down to the end of the
    /// phase, or up from when Go live now started.
    static func timer(_ state: LiveGlanceContent) -> Text {
        if let to = state.timerTo {
            return Text(timerInterval: state.timerFrom...max(to, state.timerFrom), countsDown: true)
        }
        return Text(timerInterval: state.timerFrom...Date.distantFuture, countsDown: false)
    }

    /// "Ends in 12:40", as one Text so it lays out like a sentence.
    static func timerLine(_ state: LiveGlanceContent) -> Text {
        Text(state.timerLabel + " ") + timer(state)
    }

    /// The countdown part of a widget entry.
    static func countdown(_ entry: GlanceEntry) -> Text {
        switch entry.countdown {
        case .startsIn(let date), .endsIn(let date):
            return Text(timerInterval: entry.date...max(date, entry.date), countsDown: true)
        case .later(let date):
            if Calendar.current.isDate(date, inSameDayAs: entry.date) {
                return Text(date, style: .time)
            }
            return Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        case .none:
            return Text("")
        }
    }

    static func countdownLine(_ entry: GlanceEntry) -> Text {
        if case .none = entry.countdown { return Text(entry.countdownLabel) }
        return Text(entry.countdownLabel + " ") + countdown(entry)
    }
}
