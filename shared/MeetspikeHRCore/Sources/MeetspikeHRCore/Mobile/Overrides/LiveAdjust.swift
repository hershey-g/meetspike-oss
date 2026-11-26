import Foundation

/// "Still going" and "Ended now", for the meeting the phone is listening to right now (the Live card and the Lock
/// Screen Live Activity). Pure: it names the meeting and the edit, the app sends it.
public struct LiveAdjustTarget: Equatable, Sendable {
    /// The Worker's meeting id, what the override call needs.
    public var meetingID: String
    public var title: String
    /// The times the phone is using now (effective).
    public var start: Date
    public var end: Date
    /// The calendar's end, which caps "Still going" at 4 h past it.
    public var calendarEnd: Date

    public init(meetingID: String, title: String, start: Date, end: Date, calendarEnd: Date) {
        self.meetingID = meetingID
        self.title = title
        self.start = start
        self.end = end
        self.calendarEnd = calendarEnd
    }
}

public enum LiveAdjust {
    /// "I didn't join" shows from this long before the start. It is not the listening lead-in (five minutes).
    static let didntJoinLead: TimeInterval = 120

    /// The Worker meeting behind the meeting the phone shows now (`schedule.displayedMeeting`). Nil when the phone
    /// meeting did not match exactly one Worker meeting, so a button would not know what to change.
    public static func target(displayed: CalendarMeeting?, resolved: [ResolvedMeeting]) -> LiveAdjustTarget? {
        guard let displayed,
              let match = resolved.first(where: { $0.effective == displayed }),
              let remote = match.remote else { return nil }
        return LiveAdjustTarget(
            meetingID: remote.id, title: displayed.title, start: displayed.start, end: displayed.end,
            calendarEnd: remote.calendarEnd)
    }

    /// The same for a meeting row from the Worker (the Today tab). `startUtc` and `endUtc` are the row's own times; the
    /// calendar's come from the override when it has them. Times are read through the override, so a change that is
    /// still waiting to be sent counts: a second tap adds to the first.
    public static func target(
        meetingID: String, title: String?, startUtc: String?, endUtc: String?, override: MeetingOverride?
    ) -> LiveAdjustTarget? {
        guard let rowStart = APITime.parse(startUtc), let rowEnd = APITime.parse(endUtc) else { return nil }
        let calendarStart = override?.calendarStartUtc ?? rowStart
        let calendarEnd = override?.calendarEndUtc ?? rowEnd
        guard calendarEnd > calendarStart, !OverrideRules.excluded(override) else { return nil }
        let window = OverrideRules.effective(start: calendarStart, end: calendarEnd, override: override)
        return LiveAdjustTarget(
            meetingID: meetingID, title: title ?? "", start: window.start, end: window.end, calendarEnd: calendarEnd)
    }

    /// The edit "Still going" makes, or nil at the 4 h cap.
    public static func stillGoing(_ target: LiveAdjustTarget, now: Date) -> OverrideEdit? {
        OverrideRules.stillGoing(currentEnd: target.end, calendarEnd: target.calendarEnd, now: now)
            .map { OverrideEdit(scope: .event, endUtc: .set($0)) }
    }

    /// The edit "Ended now" makes, or nil before the meeting has started.
    public static func endedNow(_ target: LiveAdjustTarget, now: Date) -> OverrideEdit? {
        OverrideRules.endedNow(start: target.start, now: now)
            .map { OverrideEdit(scope: .event, endUtc: .set($0)) }
    }

    /// What the Live Activity offers right now.
    public struct Offer: Equatable, Sendable {
        public var stillGoing: Bool
        public var endedNow: Bool
        /// "I didn't join": only while the meeting is current, from the start of the listening window (2 minutes before
        /// the start) to the end of its cooldown. Never for a future meeting, and not tied to the 4 h cap.
        public var didntJoin: Bool
        public static let none = Offer(stillGoing: false, endedNow: false, didntJoin: false)

        public init(stillGoing: Bool, endedNow: Bool, didntJoin: Bool = false) {
            self.stillGoing = stillGoing
            self.endedNow = endedNow
            self.didntJoin = didntJoin
        }
    }

    /// "Still going" while the meeting runs or is in its cooldown and the cap is not reached. "Ended now" while it runs.
    /// The listening window ends at the end plus the cooldown (`CalendarMeeting.cooldown`, 10 min); after that nothing
    /// is offered, so the buttons match what the phone is listening to.
    public static func offer(_ target: LiveAdjustTarget?, now: Date) -> Offer {
        guard let target else { return .none }
        let running = now >= target.start && now < target.end
        let cooldown = now >= target.end && now < target.end.addingTimeInterval(CalendarMeeting.cooldown)
        return Offer(
            stillGoing: (running || cooldown) && stillGoing(target, now: now) != nil,
            endedNow: running && endedNow(target, now: now) != nil,
            didntJoin: now >= target.start.addingTimeInterval(-didntJoinLead)
                && now < target.end.addingTimeInterval(CalendarMeeting.cooldown))
    }
}
