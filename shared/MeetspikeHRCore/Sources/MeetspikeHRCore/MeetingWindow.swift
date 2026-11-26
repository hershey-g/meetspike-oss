import Foundation

public struct CalendarMeeting: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date

    public init?(title: String, start: Date, end: Date, isAllDay: Bool = false, isDeclined: Bool = false) {
        guard !isAllDay, !isDeclined, (0...8 * 3_600).contains(end.timeIntervalSince(start)), start < end else {
            return nil
        }
        self.title = title.isEmpty ? "Untitled meeting" : title
        self.start = start
        self.end = end
    }

    /// A window the person or the Mac set (see `OverrideRules`), which can be up to 12 h. The public init keeps its 8 h
    /// limit for EventKit events. `title` is already the shown title.
    init(effective title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }

    /// How long before the start the phone starts listening.
    public static let leadIn: TimeInterval = 300
    public var listenFrom: Date { start.addingTimeInterval(-Self.leadIn) }
    /// How long the phone keeps listening after the end.
    public static let cooldown: TimeInterval = 600
    public var listenUntil: Date { end.addingTimeInterval(Self.cooldown) }
}

public struct MeetingSchedule: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public let first: CalendarMeeting
        public fileprivate(set) var last: CalendarMeeting
        public var start: Date { first.listenFrom }
        public var end: Date { last.listenUntil }

        func contains(_ now: Date) -> Bool { start <= now && now < end }
    }

    public let meetings: [CalendarMeeting]
    public let blocks: [Block]

    public init(_ meetings: [CalendarMeeting] = []) {
        self.meetings = meetings.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.title < $1.title
        }
        var blocks: [Block] = []
        for meeting in self.meetings {
            if let index = blocks.indices.last, meeting.listenFrom <= blocks[index].end {
                if meeting.end > blocks[index].last.end { blocks[index].last = meeting }
            } else {
                blocks.append(Block(first: meeting, last: meeting))
            }
        }
        self.blocks = blocks
    }

    public func activeBlock(at now: Date) -> Block? {
        blocks.first { $0.contains(now) }
    }

    public func displayedMeeting(at now: Date) -> CalendarMeeting? {
        meetings.last { $0.start <= now && now < $0.end }
            ?? meetings.first { now < $0.start && $0.listenFrom <= now }
            ?? meetings.last { $0.start <= now && now < $0.listenUntil }
            ?? meetings.first { $0.start > now }
    }

    func nextBoundary(after now: Date) -> Date? {
        blocks.lazy.flatMap { [$0.start, $0.end] }.first { $0 > now }
    }
}

/// Whether the Mac should listen to the strap right now.
public enum ListenGate {
    /// Explain permissions before a meeting can start Bluetooth automatically.
    public static func shouldListenOnPhone(
        onboardingComplete: Bool, manualLive: Bool, inMeetingWindow: Bool
    ) -> Bool {
        onboardingComplete && (manualLive || inMeetingWindow)
    }

    /// Meeting-only mode needs Calendar access to know when meetings are. When
    /// access is denied, listen continuously rather than never. Until the first
    /// reading, listen so setup can find the strap and trigger the Bluetooth prompt.
    public static func shouldListen(
        paused: Bool, sleeping: Bool, meetingOnly: Bool, calendarDenied: Bool,
        manualLive: Bool, setupComplete: Bool, inMeetingWindow: Bool
    ) -> Bool {
        guard !paused, !sleeping else { return false }
        return !meetingOnly || calendarDenied || manualLive || !setupComplete || inMeetingWindow
    }
}

/// Rules for the Mac "Go live now" switch, which persists across relaunches.
public enum ManualLive {
    /// Restored at launch only while meeting-only mode is on. With continuous
    /// recording a saved Go live has no meaning, so it starts off.
    public static func restored(meetingOnly: Bool, saved: Bool) -> Bool {
        meetingOnly && saved
    }

    /// Turning meeting-only off clears Go live; turning it on leaves it as is.
    public static func afterMeetingOnlyChange(meetingOnly: Bool, current: Bool) -> Bool {
        meetingOnly && current
    }

    /// The switch can always be turned off. Turning it on is blocked while
    /// paused or while Calendar access is missing in meeting-only mode.
    public static func canToggle(isOn: Bool, paused: Bool, calendarAccessNeeded: Bool) -> Bool {
        isOn || !(paused || calendarAccessNeeded)
    }
}
