import Foundation

/// When the Lock Screen heart rate (the Live Activity) may show. Stored on the phone; this only controls the
/// Live Activity. Listening, recording, widgets and reminders do not look at it.
public enum LiveActivityMode: String, Codable, CaseIterable, Sendable {
    /// Never start one. A running one ends right away.
    case off
    /// Only while a meeting is on, and only once this phone has a heart-rate reading in that meeting.
    case duringMeetings
    /// The whole listening window, and Go live now.
    case whenListening

    public static let `default`: LiveActivityMode = .duringMeetings

    /// The UserDefaults key.
    public static let storageKey = "liveActivityMode"

    /// The saved value. Nothing saved, or text this build does not know, gives the default and never turns it off.
    public static func stored(_ raw: String?) -> LiveActivityMode {
        raw.flatMap(LiveActivityMode.init(rawValue:)) ?? .default
    }

    public var label: String {
        switch self {
        case .off: "Off"
        case .duringMeetings: "During meetings"
        case .whenListening: "Whenever listening"
        }
    }

    /// The small line on the Live tab.
    public var liveTabLine: String { "Lock Screen: \(label)" }

    public static let footer =
        "Heart rate is still recorded either way. You can also swipe it away on the Lock Screen to hide it until this meeting ends."
}

/// The decision itself, pure so it can be tested without ActivityKit.
public enum LiveActivityRule {
    /// Whether the Live Activity should be showing right now.
    ///
    /// During meetings runs from the lead-in of a listening block through the end of the last meeting in it (the
    /// effective, extended or ended time). iOS cannot start a Live Activity from the background, so it has to be
    /// wanted for the whole lead-in, while the app can still be open. There is no wrap-up tail, and back-to-back
    /// meetings in one block stay one activity. Go live now outside a block never shows.
    public static func shouldShow(
        mode: LiveActivityMode, schedule: MeetingSchedule, listening: Bool, manualLive: Bool, now: Date
    ) -> Bool {
        guard listening else { return false }
        switch mode {
        case .off:
            return false
        case .whenListening:
            // Same as LiveGlancePlan: any listening moment has content, Go live now included.
            return true
        case .duringMeetings:
            return meetingsEnd(schedule: schedule, now: now) != nil
        }
    }

    /// When During meetings stops showing for the block that is listening now: the end of its last meeting. Nil
    /// outside a block, and once that end has passed (the wrap-up tail). The controller ends the activity then.
    public static func meetingsEnd(schedule: MeetingSchedule, now: Date) -> Date? {
        guard let block = schedule.activeBlock(at: now), now < block.last.end else { return nil }
        return block.last.end
    }
}

/// What the compact Dynamic Island trailing slot draws.
public enum CompactLabel: Equatable, Sendable {
    /// "12m". The widget keeps it live with a timer to `end`, so it needs no app wake.
    case minutesLeft(Int, end: Date)
    /// "<1m".
    case lessThanAMinute(end: Date)
    /// "in 3m", the Whenever listening lead-in.
    case startsIn(minutes: Int)
    /// "Live", Go live now outside a meeting.
    case live
    /// The wrap-up tail: no text, the progress ring.
    case ring

    public var text: String? {
        switch self {
        case .minutesLeft(let minutes, _): "\(minutes)m"
        case .lessThanAMinute: "<1m"
        case .startsIn(let minutes): "in \(minutes)m"
        case .live: "Live"
        case .ring: nil
        }
    }
}

extension LiveGlanceContent {
    /// The first line says the meeting is on: "In meeting · Sync". The view cuts a long title.
    public static let inMeetingPrefix = "In meeting \u{B7} "

    public var titleLine: String {
        phase == .endsIn ? Self.inMeetingPrefix + title : title
    }

    /// Minutes round up, like a countdown: 11m30s left reads 12m.
    public func compactLabel(now: Date) -> CompactLabel {
        switch phase {
        case .endsIn:
            let end = timerTo ?? meetingEnd ?? now
            let remaining = end.timeIntervalSince(now)
            if remaining < 60 { return .lessThanAMinute(end: end) }
            return .minutesLeft(Int((remaining / 60).rounded(.up)), end: end)
        case .startsIn:
            let start = meetingStart ?? timerTo ?? now
            let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
            return .startsIn(minutes: max(1, minutes))
        case .wrapUp:
            return .ring
        case .open:
            return .live
        }
    }
}
