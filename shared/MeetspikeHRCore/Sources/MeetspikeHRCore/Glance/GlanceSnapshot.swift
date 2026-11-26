import Foundation

/// The highest BPM heard during one listening block.
public struct GlancePeak: Codable, Hashable, Sendable {
    public var title: String
    public var bpm: Int
    /// Identifies the block, so a new meeting starts a new peak.
    public var blockStart: Date
    public var end: Date

    public init(title: String, bpm: Int, blockStart: Date, end: Date) {
        self.title = title
        self.bpm = bpm
        self.blockStart = blockStart
        self.end = end
    }
}

/// Tracks the peak BPM of the current listening block.
public struct MeetingPeakTracker: Sendable {
    public private(set) var peak: GlancePeak?

    /// Pass the saved peak at launch so a relaunch mid-meeting keeps it.
    public init(peak: GlancePeak? = nil) {
        self.peak = peak
    }

    /// Returns true when the stored peak changed.
    @discardableResult
    public mutating func record(bpm: Int, title: String, blockStart: Date, blockEnd: Date) -> Bool {
        guard bpm > 0 else { return false }
        if var current = peak, current.blockStart == blockStart {
            var changed = false
            if bpm > current.bpm {
                current.bpm = bpm
                current.title = title
                changed = true
            }
            if current.end != blockEnd {
                current.end = blockEnd
                changed = true
            }
            if changed { peak = current }
            return changed
        }
        peak = GlancePeak(title: title, bpm: bpm, blockStart: blockStart, end: blockEnd)
        return true
    }
}

/// What the app shares with its widgets through the App Group. It stays on
/// the device, so meeting titles are fine here.
public struct GlanceSnapshot: Codable, Equatable, Sendable {
    public struct Meeting: Codable, Hashable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date

        public init(title: String, start: Date, end: Date) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    /// Current and upcoming meetings, soonest first.
    public var meetings: [Meeting]
    public var latestBPM: Int?
    public var latestAt: Date?
    public var lastPeak: GlancePeak?
    /// The phone was listening when this was written.
    public var listening: Bool

    public static let maxMeetings = 12

    public init(meetings: [Meeting], latestBPM: Int?, latestAt: Date?, lastPeak: GlancePeak?, listening: Bool) {
        self.meetings = meetings
        self.latestBPM = latestBPM
        self.latestAt = latestAt
        self.lastPeak = lastPeak
        self.listening = listening
    }

    /// Meetings that have not ended yet, capped so the shared data stays small.
    public static func upcoming(_ schedule: MeetingSchedule, now: Date) -> [Meeting] {
        schedule.meetings.lazy
            .filter { $0.end > now }
            .prefix(maxMeetings)
            .map { Meeting(title: $0.title, start: $0.start, end: $0.end) }
    }
}

/// When the app should write the snapshot and reload widget timelines.
/// WidgetKit allows only a few dozen reloads a day, so BPM-only changes wait.
public enum GlanceReload {
    public static let bpmInterval: TimeInterval = 300

    public static func needed(old: GlanceSnapshot?, new: GlanceSnapshot, lastReload: Date, now: Date) -> Bool {
        guard let old else { return true }
        if old.meetings != new.meetings || old.listening != new.listening
            || old.lastPeak?.blockStart != new.lastPeak?.blockStart {
            return true
        }
        if old.latestBPM != new.latestBPM || old.lastPeak != new.lastPeak {
            return now.timeIntervalSince(lastReload) >= bpmInterval
        }
        return false
    }
}

/// Reads and writes the snapshot in the shared App Group defaults.
public struct GlanceStore {
    public static let appGroup = "group.com.hersheyg.meetspike.hr"
    static let key = "glanceSnapshot.v1"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = UserDefaults(suiteName: GlanceStore.appGroup)) {
        self.defaults = defaults
    }

    public func load() -> GlanceSnapshot? {
        guard let data = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(GlanceSnapshot.self, from: data)
    }

    public func save(_ snapshot: GlanceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: Self.key)
    }
}

/// What one widget timeline entry shows.
public struct GlanceEntry: Equatable, Sendable {
    public enum Countdown: Equatable, Sendable {
        /// Within the hour: count down to the start.
        case startsIn(Date)
        /// Underway: count down to the end.
        case endsIn(Date)
        /// More than an hour away: show the start time.
        case later(Date)
        case none
    }

    public enum Heart: Equatable, Sendable {
        /// A reading from the last few minutes.
        case latest(Int)
        /// The highest BPM of the last meeting.
        case peak(Int, title: String)
        case none
    }

    public var date: Date
    public var meeting: GlanceSnapshot.Meeting?
    public var countdown: Countdown
    public var heart: Heart
    /// How much of the shown meeting has passed, 0...1.
    public var progress: Double

    /// A reading older than this no longer counts as the latest BPM.
    public static let latestMaxAge: TimeInterval = 600

    public init(date: Date, meeting: GlanceSnapshot.Meeting?, countdown: Countdown, heart: Heart, progress: Double) {
        self.date = date
        self.meeting = meeting
        self.countdown = countdown
        self.heart = heart
        self.progress = progress
    }

    public init(snapshot: GlanceSnapshot?, at date: Date) {
        let meetings = snapshot?.meetings ?? []
        let current = meetings.last { $0.start <= date && date < $0.end }
        let next = meetings.first { $0.start > date }
        if let current {
            meeting = current
            countdown = .endsIn(current.end)
            let length = current.end.timeIntervalSince(current.start)
            progress = length > 0 ? min(1, max(0, date.timeIntervalSince(current.start) / length)) : 0
        } else if let next {
            meeting = next
            countdown = next.start.timeIntervalSince(date) > MeetingCountdown.timerHorizon ? .later(next.start) : .startsIn(next.start)
            progress = 0
        } else {
            meeting = nil
            countdown = .none
            progress = 0
        }
        if let bpm = snapshot?.latestBPM, let at = snapshot?.latestAt,
           at <= date, date.timeIntervalSince(at) < Self.latestMaxAge {
            heart = .latest(bpm)
        } else if let peak = snapshot?.lastPeak {
            heart = .peak(peak.bpm, title: peak.title)
        } else {
            heart = .none
        }
        self.date = date
    }

    public var countdownLabel: String {
        switch countdown {
        case .startsIn: "Starts in"
        case .endsIn: "Ends in"
        case .later: "Next"
        case .none: "No meetings ahead"
        }
    }

    public var heartCaption: String {
        switch heart {
        case .latest: "Now"
        case .peak: "Last peak"
        case .none: "No reading yet"
        }
    }

    public var bpm: Int? {
        switch heart {
        case .latest(let bpm), .peak(let bpm, _): bpm
        case .none: nil
        }
    }
}

/// The dates a widget timeline needs, so countdowns, the progress ring and
/// the latest BPM stay right without the app reloading them.
public enum GlanceTimeline {
    public static let horizon: TimeInterval = 6 * 3_600
    public static let ringStep: TimeInterval = 300
    public static let maxEntries = 60

    public static func dates(for snapshot: GlanceSnapshot?, from now: Date) -> [Date] {
        let limit = now.addingTimeInterval(horizon)
        var dates: Set<Date> = [now]
        for meeting in snapshot?.meetings ?? [] where meeting.start < limit {
            dates.insert(meeting.start.addingTimeInterval(-MeetingCountdown.timerHorizon))
            dates.insert(meeting.start)
            dates.insert(meeting.end)
            var step = meeting.start.addingTimeInterval(ringStep)
            while step < meeting.end {
                dates.insert(step)
                step.addTimeInterval(ringStep)
            }
        }
        if let at = snapshot?.latestAt { dates.insert(at.addingTimeInterval(GlanceEntry.latestMaxAge)) }
        return dates.filter { $0 >= now && $0 <= limit }.sorted().prefix(maxEntries).map { $0 }
    }

    public static func entries(for snapshot: GlanceSnapshot?, from now: Date) -> [GlanceEntry] {
        dates(for: snapshot, from: now).map { GlanceEntry(snapshot: snapshot, at: $0) }
    }
}
