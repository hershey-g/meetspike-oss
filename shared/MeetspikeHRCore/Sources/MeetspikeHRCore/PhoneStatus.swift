import Foundation

/// What the iPhone heart-rate card says about the connection. Kept free of
/// UI types so the wording and priorities are testable on any platform.
public struct PhoneHeartState: Equatable, Sendable {
    public enum Tone: Sendable, Equatable {
        /// A fresh reading from a live connection.
        case live
        /// Listening, but not reading yet (starting, searching, reconnecting).
        case working
        /// Not listening on purpose (outside a meeting window).
        case idle
        /// Something the person has to fix (Bluetooth off or not allowed).
        case problem
    }

    public enum Action: Sendable, Equatable {
        case openSettings
    }

    public let tone: Tone
    public let title: String
    public let detail: String?
    public let action: Action?

    init(_ tone: Tone, _ title: String, _ detail: String? = nil, action: Action? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.action = action
    }

    public init(
        connection: BluetoothStatus, permission: BluetoothPermission, listening: Bool,
        latestAt: Date?, hasCurrentReading: Bool, now: Date
    ) {
        if permission == .denied || connection == .unauthorized {
            self.init(.problem, "Bluetooth not allowed",
                      "Allow Bluetooth for Meetspike in Settings so it can hear your WHOOP.", action: .openSettings)
            return
        }
        guard listening else {
            self.init(.idle, "Not listening",
                      "Meetspike listens from 5 minutes before each meeting until 10 minutes after.")
            return
        }
        switch connection {
        case .connected:
            let fresh = latestAt.map { !ReadingAge(readAt: $0, now: now, connected: hasCurrentReading).isStale } ?? false
            if fresh {
                self.init(.live, "Live")
            } else {
                self.init(.working, "Connected", "Waiting for heart rate. Make sure you're wearing the strap.")
            }
        case .connecting:
            self.init(.working, "Connecting", "Found your WHOOP. Connecting now.")
        case .searching:
            self.init(.working, "Looking for WHOOP",
                      "Turn on HR Broadcast in the WHOOP app: Menu → Device Settings → HR Broadcast.")
        case .reconnecting:
            self.init(.working, "Reconnecting", "Lost the WHOOP for a moment. Trying again.")
        case .waiting:
            self.init(.working, "Open to connect",
                      "iPhone only searches for your WHOOP while Meetspike is open. Keep it open until it connects.")
        case .starting:
            self.init(.working, "Starting Bluetooth")
        case .poweredOff:
            self.init(.problem, "Bluetooth is off", "Turn on Bluetooth in Control Center.")
        case .unauthorized:
            self.init(.problem, "Bluetooth not allowed", nil, action: .openSettings)
        case .unsupported:
            self.init(.problem, "Bluetooth unavailable", "This device can't use Bluetooth LE.")
        case .paused, .sleeping, .outsideMeeting:
            self.init(.idle, "Not listening",
                      "Meetspike listens from 5 minutes before each meeting until 10 minutes after.")
        }
    }
}

/// Where the displayed meeting is relative to now.
public enum MeetingCountdown: Equatable, Sendable {
    /// More than an hour away: show the start date and time, not a timer.
    case later(Date)
    /// Within the hour: count down to the start.
    case startsIn(Date)
    /// Underway: count down to the end.
    case endsIn(Date)
    /// Over, but the 10-minute cooldown is still listening.
    case cooldown(Date)
    /// Over and no longer listening.
    case ended

    /// Timers longer than this read badly ("47:12:33"); show a date instead.
    public static let timerHorizon: TimeInterval = 3_600

    public init(meeting: CalendarMeeting, schedule: MeetingSchedule, now: Date) {
        if now < meeting.start {
            self = meeting.start.timeIntervalSince(now) > Self.timerHorizon ? .later(meeting.start) : .startsIn(meeting.start)
        } else if now < meeting.end {
            self = .endsIn(meeting.end)
        } else if let block = schedule.activeBlock(at: now) {
            self = .cooldown(block.end)
        } else {
            self = .ended
        }
    }
}
