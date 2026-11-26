import Foundation

/// The short state the Live Activity shows next to the heart rate.
public enum LiveGlanceStatus: String, Codable, Hashable, Sendable {
    case live
    case reconnecting
    case waiting

    public var label: String {
        switch self {
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .waiting: "Waiting for WHOOP"
        }
    }

    /// Live only with a fresh reading from a connected strap. A dropped strap
    /// reads as reconnecting; everything else (starting, searching, connecting,
    /// Bluetooth off) is waiting.
    public init(connection: BluetoothStatus, hasFreshReading: Bool) {
        if connection == .connected, hasFreshReading {
            self = .live
        } else if connection == .reconnecting {
            self = .reconnecting
        } else {
            self = .waiting
        }
    }
}

/// Everything the Live Activity draws. It is the ActivityKit content state, so
/// keep it small and Codable. The meeting title stays on the device.
public struct LiveGlanceContent: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// The two-minute lead-in before a meeting.
        case startsIn
        /// The meeting is underway.
        case endsIn
        /// The ten-minute cooldown after the meeting.
        case wrapUp
        /// Go live now, outside any meeting window.
        case open
    }

    public var bpm: Int?
    public var status: LiveGlanceStatus
    public var title: String
    public var phase: Phase
    /// Lower bound of the timer range. Always at or before the update time.
    public var timerFrom: Date
    /// When the timer reaches zero. Nil for `.open`, which counts up instead.
    public var timerTo: Date?
    public var meetingStart: Date?
    public var meetingEnd: Date?
    /// Whether the activity offers "Still going" and "Ended now". Nil (an older state) means no.
    public var canExtend: Bool?
    public var canEnd: Bool?

    public init(
        bpm: Int?, status: LiveGlanceStatus, title: String, phase: Phase,
        timerFrom: Date, timerTo: Date?, meetingStart: Date?, meetingEnd: Date?,
        canExtend: Bool? = nil, canEnd: Bool? = nil
    ) {
        self.bpm = bpm
        self.status = status
        self.title = title
        self.phase = phase
        self.timerFrom = timerFrom
        self.timerTo = timerTo
        self.meetingStart = meetingStart
        self.meetingEnd = meetingEnd
        self.canExtend = canExtend
        self.canEnd = canEnd
    }

    /// The words before the timer, for example "Ends in".
    public var timerLabel: String {
        switch phase {
        case .startsIn: "Starts in"
        case .endsIn: "Ends in"
        case .wrapUp: "Stops in"
        case .open: "Live for"
        }
    }

    /// How much of the meeting has passed, 0...1, for the progress ring.
    public func progress(at now: Date) -> Double {
        switch phase {
        case .open, .wrapUp: return 1
        case .startsIn: return 0
        case .endsIn:
            guard let start = meetingStart, let end = meetingEnd, end > start else { return 0 }
            return min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start)))
        }
    }

    /// The same content without the BPM, so the throttle can tell a BPM-only
    /// change from one that changes the layout or the timer.
    var structure: LiveGlanceContent {
        var copy = self
        copy.bpm = nil
        return copy
    }
}

/// Decides what the Live Activity shows, or that it should not run.
public enum LiveGlancePlan {
    /// The activity title when Go live now runs outside a meeting.
    public static let goLiveTitle = "Go live"

    /// Nil when the phone is not listening. Inside a meeting window the
    /// countdown follows the displayed meeting; with Go live now and no
    /// meeting it counts up from when Go live started.
    public static func content(
        schedule: MeetingSchedule, listening: Bool, manualSince: Date?,
        bpm: Int?, status: LiveGlanceStatus, now: Date, adjust: LiveAdjust.Offer = .none
    ) -> LiveGlanceContent? {
        guard listening else { return nil }
        if let block = schedule.activeBlock(at: now), let meeting = schedule.displayedMeeting(at: now) {
            let phase: LiveGlanceContent.Phase
            let from: Date
            let to: Date
            if now < meeting.start {
                phase = .startsIn
                from = min(block.start, now)
                to = meeting.start
            } else if now < meeting.end {
                phase = .endsIn
                from = meeting.start
                to = meeting.end
            } else {
                phase = .wrapUp
                from = meeting.end
                to = block.end
            }
            return LiveGlanceContent(
                bpm: bpm, status: status, title: meeting.title, phase: phase,
                timerFrom: from, timerTo: to, meetingStart: meeting.start, meetingEnd: meeting.end,
                canExtend: adjust.stillGoing ? true : nil, canEnd: adjust.endedNow ? true : nil
            )
        }
        return LiveGlanceContent(
            bpm: bpm, status: status, title: goLiveTitle, phase: .open,
            timerFrom: min(manualSince ?? now, now), timerTo: nil, meetingStart: nil, meetingEnd: nil
        )
    }

    /// When the activity should end on its own: the end of the listening
    /// block. Nil with Go live now outside a meeting window.
    public static func windowEnd(schedule: MeetingSchedule, now: Date) -> Date? {
        schedule.activeBlock(at: now)?.end
    }
}

/// Keeps Live Activity updates inside ActivityKit's budget. BPM arrives about
/// once a second; the activity only needs a fresh number every 5 to 10 seconds.
public struct LiveGlanceThrottle: Sendable {
    /// No BPM-only update sooner than this after the last one.
    public var minInterval: TimeInterval = 5
    /// A small BPM change waits this long.
    public var steadyInterval: TimeInterval = 10
    /// A change of at least this many BPM goes out after `minInterval`.
    public var bigChange = 3
    /// Send even without a change after this long, so the stale date moves on.
    public var keepAlive: TimeInterval = 30
    /// Two layout changes (status, phase, title) need at least this gap.
    public var structuralGap: TimeInterval = 1

    public private(set) var sent: LiveGlanceContent?
    public private(set) var sentAt: Date?

    public init() {}

    public func shouldSend(_ content: LiveGlanceContent, now: Date) -> Bool {
        guard let sent, let sentAt else { return true }
        let elapsed = now.timeIntervalSince(sentAt)
        if content.structure != sent.structure { return elapsed >= structuralGap }
        if elapsed >= keepAlive { return true }
        guard elapsed >= minInterval, content.bpm != sent.bpm else { return false }
        guard let new = content.bpm, let old = sent.bpm else { return true }
        return abs(new - old) >= bigChange || elapsed >= steadyInterval
    }

    public mutating func markSent(_ content: LiveGlanceContent, at now: Date) {
        sent = content
        sentAt = now
    }

    public mutating func reset() {
        sent = nil
        sentAt = nil
    }
}
