import Foundation

// Logic for the iPhone Live tab, kept free of UI types so it is testable on any platform.

/// How far the live heart rate sits above the person's usual resting rate.
public enum SpikeLevel: String, Sendable, Equatable, CaseIterable {
    case normal, elevated, high
}

/// The live BPM against the usual resting heart rate: "+14 over resting", "6 under resting".
public struct RestingComparison: Equatable, Sendable {
    /// Thresholds, in beats per minute over resting.
    ///
    /// Resting comes from the Worker's `usual.restingHr`: the 28-day median of the wearable's lowest heart rate
    /// overnight. Sitting awake in a meeting already runs about 10 to 15 over that, so the bands start higher than
    /// a daytime resting rate would need:
    /// - under 15 over (or any amount under resting): normal
    /// - 15 to 29 over: elevated
    /// - 30 or more over: high
    public static let elevatedFrom = 15
    public static let highFrom = 30

    public let bpm: Int
    public let resting: Int

    /// Nil without a resting value or a reading, so the card shows nothing extra.
    public init?(bpm: Int?, resting: Int?) {
        guard let bpm, let resting, bpm > 0, resting > 0 else { return nil }
        self.bpm = bpm
        self.resting = resting
    }

    /// Beats over resting. Negative when under.
    public var delta: Int { bpm - resting }

    public var level: SpikeLevel { Self.level(delta: delta) }

    public static func level(delta: Int) -> SpikeLevel {
        if delta >= highFrom { return .high }
        if delta >= elevatedFrom { return .elevated }
        return .normal
    }

    /// Short text beside the BPM.
    public var label: String {
        if delta > 0 { return "+\(delta) over resting" }
        if delta < 0 { return "\(-delta) under resting" }
        return "At resting"
    }

    /// What VoiceOver reads.
    public var accessibilityLabel: String {
        let rate = "your resting rate of \(resting)"
        let level: String
        switch self.level {
        case .normal: level = ""
        case .elevated: level = ". Elevated"
        case .high: level = ". High"
        }
        if delta > 0 { return "\(delta) over \(rate)\(level)" }
        if delta < 0 { return "\(-delta) under \(rate)" }
        return "At \(rate)"
    }
}

/// The usual resting heart rate the Live tab compares against, and how long a saved one stays usable.
public enum RestingBaseline {
    /// A saved value older than this is not shown. The usual is a 28-day median, so it moves slowly.
    public static let maxAge: TimeInterval = 14 * 86_400
    /// A saved value younger than this is fresh enough that the Live tab does not ask the Worker again.
    public static let refreshAfter: TimeInterval = 6 * 3_600
    /// Anything outside this is a bad value, not a resting heart rate.
    public static let plausible = 25...130

    /// Whole bpm from `usual.restingHr`, or nil when missing or implausible.
    public static func value(fromUsual usual: Double?) -> Int? {
        guard let usual, usual.isFinite else { return nil }
        let rounded = Int(usual.rounded())
        return plausible.contains(rounded) ? rounded : nil
    }

    /// The saved value while it is recent enough to trust. A save dated in the future counts as now.
    public static func current(saved: Int?, savedAt: Date?, now: Date) -> Int? {
        guard let saved, plausible.contains(saved), let savedAt else { return nil }
        return now.timeIntervalSince(savedAt) <= maxAge ? saved : nil
    }

    /// Whether an answer saved at `answerAt` should replace one saved at `savedAt`. An older copy never wins.
    public static func shouldReplace(savedAt: Date?, with answerAt: Date) -> Bool {
        guard let savedAt else { return true }
        return answerAt >= savedAt
    }

    /// Whether the Live tab should ask the Worker for a fresh usual.
    public static func needsRefresh(savedAt: Date?, now: Date) -> Bool {
        guard let savedAt else { return true }
        return now.timeIntervalSince(savedAt) > refreshAfter
    }
}

/// Decides when the Live tab plays its one "connected" haptic: the first time the connection turns live in a
/// listening session. Not on every reading, not again after a drop and reconnect in the same session, and not
/// when a new session goes live within `quietPeriod` of the last haptic (Go live toggled off and on, a block
/// ending and the next starting).
public struct LiveHapticGate: Equatable, Sendable {
    public static let quietPeriod: TimeInterval = 120

    private var firedThisSession = false
    private var lastFired: Date?

    public init() {}

    /// Feed every change. `listening`: Bluetooth is meant to be on (the connection is not outside a meeting).
    /// `live`: a fresh reading is coming in. Returns true when the haptic should play now.
    public mutating func update(live: Bool, listening: Bool, now: Date) -> Bool {
        guard listening else {
            firedThisSession = false
            return false
        }
        guard live, !firedThisSession else { return false }
        firedThisSession = true
        if let lastFired, now.timeIntervalSince(lastFired) < Self.quietPeriod { return false }
        lastFired = now
        return true
    }
}

/// Running min, mean and max of heart-rate readings. Built once from stored readings, then topped up with the
/// newer in-memory ones, so a long meeting's numbers stay cheap to keep current.
public struct HeartRateStats: Equatable, Sendable {
    public private(set) var count = 0
    public private(set) var sum = 0
    public private(set) var min: Int?
    public private(set) var max: Int?
    /// The latest reading counted.
    public private(set) var through: Date?

    public init() {}

    public init(_ readings: [HeartRatePoint]) {
        for reading in readings { add(reading) }
    }

    public mutating func add(_ reading: HeartRatePoint) {
        count += 1
        sum += reading.bpm
        min = Swift.min(min ?? reading.bpm, reading.bpm)
        max = Swift.max(max ?? reading.bpm, reading.bpm)
        through = Swift.max(through ?? reading.time, reading.time)
    }

    /// Adds the readings inside `window` that are newer than the last one counted.
    public func adding(_ readings: [HeartRatePoint], within window: ClosedRange<Date>) -> HeartRateStats {
        var next = self
        for reading in readings where window.contains(reading.time) && (through.map { reading.time > $0 } ?? true) {
            next.add(reading)
        }
        return next
    }

    public var summary: (min: Int, avg: Int, max: Int)? {
        guard count > 0, let min, let max else { return nil }
        return (min, Int((Double(sum) / Double(count)).rounded()), max)
    }
}

/// What the Live tab's 15-minute chart marks and how it labels its numbers.
public enum LiveChart {
    /// The chart's span.
    public static let span: TimeInterval = 900

    public static func range(now: Date) -> ClosedRange<Date> { now.addingTimeInterval(-span)...now }

    /// The meeting to mark: one underway now, else the one that ended most recently inside the range. When
    /// meetings overlap, the one that started last.
    public static func meeting(in schedule: MeetingSchedule, range: ClosedRange<Date>) -> CalendarMeeting? {
        let now = range.upperBound
        let overlapping = schedule.meetings.filter { $0.start <= now && $0.end > range.lowerBound }
        let underway = overlapping.filter { $0.end > now }
        return (underway.isEmpty ? overlapping : underway).max {
            $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
        }
    }

    /// The meeting's part of the range, for shading. Nil when it does not overlap.
    public static func shaded(_ meeting: CalendarMeeting, in range: ClosedRange<Date>) -> ClosedRange<Date>? {
        let start = Swift.max(meeting.start, range.lowerBound)
        let end = Swift.min(meeting.end, range.upperBound)
        return start < end ? start...end : nil
    }

    /// The window the Min / Avg / Max cover: the meeting up to now, or the whole range.
    public static func statsWindow(meeting: CalendarMeeting?, range: ClosedRange<Date>) -> ClosedRange<Date> {
        guard let meeting else { return range }
        return meeting.start...Swift.max(meeting.start, Swift.min(meeting.end, range.upperBound))
    }

    /// Whether the stats need readings older than the chart holds in memory.
    public static func needsStoredReadings(meeting: CalendarMeeting?, range: ClosedRange<Date>) -> Bool {
        guard let meeting else { return false }
        return meeting.start < range.lowerBound
    }

    public static func statsTitle(meeting: CalendarMeeting?) -> String {
        meeting == nil ? "Last 15 min" : "This meeting"
    }
}
