import Foundation

/// A meeting as the Worker knows it, with its override. `calendarStart` and `calendarEnd` are the original times
/// (the override's `calendarStartUtc` and `calendarEndUtc`; the meeting's own times on the wire are the effective ones).
public struct RemoteMeeting: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var calendarStart: Date
    public var calendarEnd: Date
    public var override: MeetingOverride?

    public init(id: String, title: String, calendarStart: Date, calendarEnd: Date, override: MeetingOverride?) {
        self.id = id
        self.title = title
        self.calendarStart = calendarStart
        self.calendarEnd = calendarEnd
        self.override = override
    }
}

/// One of the phone's meetings with what the Worker says about it.
public struct ResolvedMeeting: Equatable, Sendable {
    /// The meeting as EventKit has it (the calendar's times).
    public var original: CalendarMeeting
    /// What it is for listening: the effective times, or nil when the meeting is left out.
    public var effective: CalendarMeeting?
    /// The Worker meeting this one matched, when exactly one did. Its id is what the override calls need.
    public var remote: RemoteMeeting?

    public init(original: CalendarMeeting, effective: CalendarMeeting?, remote: RemoteMeeting?) {
        self.original = original
        self.effective = effective
        self.remote = remote
    }
}

/// Lays the Worker's overrides over the phone's EventKit meetings.
public enum OverrideMatch {
    /// A Worker meeting is a candidate for a phone meeting when its original start is within 90 s (inclusive) and the
    /// titles are equal after trimming and ignoring case. Exactly one candidate: its override is applied (excluded
    /// meetings are dropped, the rest get their effective times). Two or more, or none: the meeting stays as it is.
    /// The order of the list is kept.
    public static func apply(_ overrides: [RemoteMeeting], to meetings: [CalendarMeeting]) -> [CalendarMeeting] {
        guard !overrides.isEmpty else { return meetings }
        return resolve(overrides, to: meetings).compactMap(\.effective)
    }

    /// `apply`, keeping what each phone meeting matched, so a button can name the Worker meeting it acts on.
    public static func resolve(_ overrides: [RemoteMeeting], to meetings: [CalendarMeeting]) -> [ResolvedMeeting] {
        guard !overrides.isEmpty else {
            return meetings.map { ResolvedMeeting(original: $0, effective: $0, remote: nil) }
        }
        let keyed = overrides.map { (key: normalized($0.title), remote: $0) }
        return meetings.map { meeting in
            let key = normalized(meeting.title)
            let candidates = keyed.filter {
                $0.key == key && abs($0.remote.calendarStart.timeIntervalSince(meeting.start)) <= 90
            }
            guard candidates.count == 1 else { return ResolvedMeeting(original: meeting, effective: meeting, remote: nil) }
            let remote = candidates[0].remote
            if OverrideRules.excluded(remote.override) {
                return ResolvedMeeting(original: meeting, effective: nil, remote: remote)
            }
            let window = OverrideRules.effective(start: meeting.start, end: meeting.end, override: remote.override)
            if window.start == meeting.start, window.end == meeting.end {
                return ResolvedMeeting(original: meeting, effective: meeting, remote: remote)
            }
            let moved = CalendarMeeting(effective: meeting.title, start: window.start, end: window.end)
            return ResolvedMeeting(original: meeting, effective: moved, remote: remote)
        }
    }

    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
