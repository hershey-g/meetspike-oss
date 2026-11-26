import Foundation

/// What a person can say about a meeting, and what each choice becomes. The same menu as the web
/// (public/meeting-actions.js): I didn't join, Don't link this meeting, Meeting times, Use calendar times, Undo, and
/// for a meeting in a series a "Just this one" / "All of them" question first. Pure: the screens ask, the model sends.
public enum MeetingActions {
    public enum Action: Equatable, Sendable {
        case notJoined
        case unlinked
        case times
        case calendarTimes
        case undo
        /// "Yes" on the note: leave it out.
        case skipYes
        /// "No" on the note: keep it, and stop asking.
        case skipNo
    }

    /// What was asked for before the scope question is answered.
    public enum Pending: Equatable, Sendable {
        case state(MeetingOverride.State)
        case undo
    }

    public enum Plan: Equatable, Sendable {
        /// Send this now.
        case save(OverrideEdit)
        /// Ask "Just this one" or "All of them" first.
        case askScope(Pending)
        /// Open the times sheet.
        case askTimes
    }

    /// The words under a meeting that is left out.
    public static func excludedLabel(_ override: MeetingOverride?) -> String {
        override?.state == .unlinked ? "Not linked" : "Didn't join"
    }

    /// The quiet question under a meeting the Mac never saw Zoom for.
    public static let skippedQuestion = "Looks like you didn't join. Unlink it?"

    public static func plan(_ action: Action, override: MeetingOverride?) -> Plan {
        let inSeries = override?.seriesId != nil
        switch action {
        case .notJoined: return inSeries ? .askScope(.state(.notJoined)) : .save(OverrideEdit(scope: .event, state: .set(.notJoined)))
        case .unlinked: return inSeries ? .askScope(.state(.unlinked)) : .save(OverrideEdit(scope: .event, state: .set(.unlinked)))
        case .times: return .askTimes
        case .calendarTimes: return .save(OverrideEdit(scope: .event, startUtc: .clear, endUtc: .clear))
        case .undo:
            // Left out by a rule on the series: put it back for this one meeting or for all of them.
            if override?.scope == .series { return .askScope(.undo) }
            // Left out by its own choice and by its series: clearing the choice would hand it to the series rule, and
            // it would stay out. Say linked for this one instead.
            if let seriesState = override?.seriesState, isExcludedState(seriesState), override?.state != .linked {
                return .save(OverrideEdit(scope: .event, state: .set(.linked)))
            }
            return .save(OverrideEdit(scope: .event, state: .clear))
        case .skipYes: return .save(OverrideEdit(scope: .event, state: .set(.unlinked)))
        case .skipNo: return .save(OverrideEdit(scope: .event, state: .set(.linked)))
        }
    }

    private static func isExcludedState(_ state: MeetingOverride.State) -> Bool {
        state == .notJoined || state == .unlinked
    }

    /// The answer to the scope question.
    public static func answer(_ scope: MeetingOverride.Scope, to pending: Pending, override: MeetingOverride?) -> OverrideEdit {
        switch (pending, scope) {
        case (.state(let state), _):
            return OverrideEdit(scope: scope, state: .set(state))
        case (.undo, .event):
            // Opt this one out of the series rule. Without a series rule there is nothing to opt out of: clear.
            return OverrideEdit(scope: .event, state: override?.scope == .series ? .set(.linked) : .clear)
        case (.undo, .series):
            return OverrideEdit(scope: .series, state: .clear)
        }
    }

    /// The edit for new times from the times sheet, or why it cannot be sent.
    /// With the calendar's times it also refuses what the rules would ignore (the same limits as
    /// `OverrideRules.effective`); without them it can only check the length of the window.
    public static func times(
        start: Date, end: Date, calendar: CalendarBounds? = nil
    ) -> Result<OverrideEdit, TimesProblem> {
        guard end > start else { return .failure(.endNotAfterStart) }
        guard end.timeIntervalSince(start) <= OverrideRules.maxWindow else { return .failure(.tooLong) }
        if let calendar {
            if start < calendar.start.addingTimeInterval(-OverrideRules.maxEarlyStart) { return .failure(.startTooEarly) }
            if end > calendar.end.addingTimeInterval(OverrideRules.maxLateEnd) { return .failure(.endTooLate) }
        }
        return .success(OverrideEdit(scope: .event, startUtc: .set(start), endUtc: .set(end)))
    }

    /// The calendar's own start and end for a meeting, which the Worker's limits count from.
    public struct CalendarBounds: Equatable, Sendable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        /// The calendar times of a meeting row, or nil when the phone cannot tell. The Worker sends them in the
        /// override. A row with no times set or seen shows the calendar's times as they are. A row that has moved
        /// times and no calendar times (an older Worker) may show moved ones, so they are not taken as the calendar's.
        public static func of(rowStart: Date?, rowEnd: Date?, override: MeetingOverride?) -> CalendarBounds? {
            if let start = override?.calendarStartUtc, let end = override?.calendarEndUtc, end > start {
                return CalendarBounds(start: start, end: end)
            }
            let moved = override.map {
                $0.startUtc != nil || $0.endUtc != nil || $0.seenStartUtc != nil || $0.seenEndUtc != nil
            } ?? false
            guard !moved, let rowStart, let rowEnd, rowEnd > rowStart else { return nil }
            return CalendarBounds(start: rowStart, end: rowEnd)
        }
    }

    public enum TimesProblem: Error, Equatable, Sendable {
        case endNotAfterStart
        case tooLong
        case startTooEarly
        case endTooLate

        public var message: String {
            switch self {
            case .endNotAfterStart: "The end has to be after the start."
            case .tooLong: "A meeting can be 12 hours long at most."
            case .startTooEarly: "The start can be 2 hours before the calendar start at most."
            case .endTooLate: "The end can be 4 hours after the calendar end at most."
            }
        }
    }

    /// Whether the menu offers "Use calendar times" (the person set times).
    public static func hasOwnTimes(_ override: MeetingOverride?) -> Bool {
        override?.startUtc != nil || override?.endUtc != nil
    }

    /// Whether the menu offers "Undo": a choice on this meeting, or a rule from its series that left it out.
    public static func canUndo(_ override: MeetingOverride?) -> Bool {
        override?.state != nil
    }

    /// The title of the scope question: "I didn't join for", "Don't link for", "Put it back for".
    public static func scopeTitle(_ pending: Pending) -> String {
        switch pending {
        case .undo: "Put it back for"
        case .state(.unlinked): "Don't link for"
        case .state(.linked): "Keep it for"
        case .state(.notJoined): "I didn't join for"
        }
    }
}

/// What to do about one saved edit when the Worker answered with an error.
///
/// Two questions, two functions. `verdict(for:)` is about an edit that is already waiting in the outbox (keep it or
/// drop it). `outcomeWhenMade(for:)` is about a choice that was just made: only offline waits; any other failure is
/// refused, leaves the old state and says so. Nothing refused when it is made is queued.
public enum OverrideDelivery {
    public enum Verdict: Equatable, Sendable {
        /// Keep a WAITING edit queued and try later (no network, sign-in, a Worker that is not ready, a server error).
        /// This describes an edit that is already in the outbox. A choice that fails at the moment it is made is
        /// decided by `outcomeWhenMade(for:)`: only offline waits, the rest leaves the old state and is not queued.
        case keep(String)
        /// It can never succeed (a bad request, the meeting is gone). Drop it and say so.
        case drop(String)
    }

    /// 400 and 404 are final. 503 (the table is not there yet), offline, a rejected sign-in and every other failure
    /// stay queued.
    public static func verdict(for error: Error) -> Verdict {
        guard let error = error as? APIError else { return .keep("Couldn't save. Nothing changed.") }
        switch error {
        case .offline: return .keep("Saved on this phone. It sends when you are back online.")
        case .accessRejected: return .keep(error.message)
        case .http(let status, let message):
            if status == 503 { return .keep(notAvailable) }
            if status == 400 || status == 404 { return .drop(message) }
            return .keep("Couldn't save. Nothing changed.")
        case .decoding: return .keep("Couldn't save. Nothing changed.")
        case .invalidRequest, .notConfigured: return .drop(error.message)
        }
    }

    public static let notAvailable = "Not available yet."

    /// What the caller does with the failure of a choice that was just made.
    public enum MadeOutcome: Equatable, Sendable {
        /// Offline: saved on the device, it sends later.
        case waiting(String)
        /// Refused when made (503, 500, a rejected sign-in, a bad request): the old state stays, and the text says so.
        /// It is not queued.
        case refused(String)
    }

    /// Only a missing network waits. Everything else is refused, with the Worker's own words when it gave a final
    /// answer (400, 404), else a plain line.
    public static func outcomeWhenMade(for error: Error) -> MadeOutcome {
        switch verdict(for: error) {
        case .drop(let text): return .refused(text)
        case .keep(let text):
            if (error as? APIError) == .offline { return .waiting(text) }
            return .refused(text)
        }
    }
}
