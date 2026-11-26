import Foundation

/// The rules the phone and the Mac share with the Worker (src/lib/meeting-override.ts). Pure: real elapsed seconds
/// only, never wall clock, so a DST change inside a meeting changes nothing.
public enum OverrideRules {
    /// A start may be this early, an end this late (against the calendar), and a window this long.
    public static let maxEarlyStart: TimeInterval = 2 * 3_600
    public static let maxLateEnd: TimeInterval = 4 * 3_600
    /// A start the Mac saw counts only from this long before the calendar start (src/lib/meeting-override.ts,
    /// MAX_SEEN_EARLY_MS). A seen end counts up to `maxLateEnd`, like the person's.
    public static let maxSeenEarlyStart: TimeInterval = 15 * 60
    public static let maxWindow: TimeInterval = 12 * 3_600
    /// What "Still going" adds.
    public static let stillGoingStep: TimeInterval = 15 * 60

    /// The times a meeting really had, the same answer as `effectiveTimes` in src/lib/meeting-override.ts. Per field the
    /// order is the person's time, then the time the Mac saw, then the calendar's. The person's start more than 2 h
    /// before the calendar start, or the person's end more than 4 h after the calendar end, is skipped. A seen value
    /// (start or end) counts only inside [calendar start - 15 min, calendar end + 4 h]. Of the pairs left, one must end after
    /// it starts and last at most 12 h. Pairs are tried by how many steps down from the person's choice they are (the
    /// start step plus the end step, a tie goes to the better start). The calendar pair is the last resort, so the
    /// answer is always a valid window. Limits are inclusive.
    public static func effective(start: Date, end: Date, override: MeetingOverride?) -> (start: Date, end: Date) {
        guard let override else { return (start, end) }
        let earliestStart = start.addingTimeInterval(-maxEarlyStart)
        let latestEnd = end.addingTimeInterval(maxLateEnd)
        // A seen value (either one) counts only inside [calendar start - 15 min, calendar end + 4 h], both inclusive:
        // the Worker's seenTimeFits.
        let seenFrom = start.addingTimeInterval(-maxSeenEarlyStart)
        func seenFits(_ date: Date) -> Bool { date >= seenFrom && date <= latestEnd }
        let starts = [override.startUtc, override.seenStartUtc].enumerated()
            .compactMap { rank, date in
                date.flatMap { (rank == 0 ? $0 >= earliestStart : seenFits($0)) ? (date: $0, rank: rank) : nil }
            }
        let ends = [override.endUtc, override.seenEndUtc].enumerated()
            .compactMap { rank, date in
                date.flatMap { (rank == 0 ? $0 <= latestEnd : seenFits($0)) ? (date: $0, rank: rank) : nil }
            }

        func fits(_ from: Date, _ to: Date) -> Bool {
            to > from && to.timeIntervalSince(from) <= maxWindow
        }
        var pairs: [(start: Date, end: Date, cost: Int, startRank: Int)] = []
        for from in starts {
            for to in ends where fits(from.date, to.date) {
                pairs.append((from.date, to.date, from.rank + to.rank, from.rank))
            }
            // The calendar end stands in below the seen one (rank 2).
            if fits(from.date, end) { pairs.append((from.date, end, from.rank + 2, from.rank)) }
        }
        for to in ends where fits(start, to.date) {
            pairs.append((start, to.date, 2 + to.rank, 2))
        }
        // Stable: equal costs keep the order they were found in, like the Worker.
        let best = pairs.enumerated().min { lhs, rhs in
            if lhs.element.cost != rhs.element.cost { return lhs.element.cost < rhs.element.cost }
            if lhs.element.startRank != rhs.element.startRank { return lhs.element.startRank < rhs.element.startRank }
            return lhs.offset < rhs.offset
        }?.element
        guard let best else { return (start, end) }
        return (best.start, best.end)
    }

    /// Not joined or not linked: the meeting is out of scores, averages and listening. "Linked" on an event is the
    /// person saying "keep it" against a series rule, so it is not excluded.
    public static func excluded(_ override: MeetingOverride?) -> Bool {
        switch override?.state {
        case .notJoined?, .unlinked?: return true
        case .linked?, nil: return false
        }
    }

    /// The Mac never saw Zoom and nobody has answered yet: show "Looks like you didn't join".
    public static func suggestsNotJoined(_ override: MeetingOverride?) -> Bool {
        guard let override else { return false }
        return override.seenNone && override.state == nil
    }

    /// What the end becomes when "Still going" is tapped: 15 minutes past the current end, or past now when the
    /// meeting already ran over. Never past 4 h after the calendar end. Nil when that cap is reached (or already gone).
    public static func stillGoing(currentEnd: Date, calendarEnd: Date, now: Date) -> Date? {
        let cap = calendarEnd.addingTimeInterval(maxLateEnd)
        guard now < cap, currentEnd < cap else { return nil }
        let next = max(currentEnd, now).addingTimeInterval(stillGoingStep)
        return min(next, cap)
    }

    /// What the end becomes when "Ended now" is tapped. Nil unless now is after the start (the end must be after it).
    public static func endedNow(start: Date, now: Date) -> Date? {
        now > start ? now : nil
    }
}
