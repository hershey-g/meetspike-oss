import Foundation

/// What the app remembers about a pause, saved across relaunches.
public struct PauseRecord: Codable, Equatable, Sendable {
    /// When the user pressed Pause.
    public let pausedAt: Date
    /// Meeting-only mode was on. A pause set with continuous capture holds
    /// until the user resumes, even if meeting-only is switched on later.
    public let meetingOnly: Bool
    /// The meeting block the pause was set in, if any. Kept as an interval
    /// rather than just a start, because a block's start moves when its first
    /// meeting is edited, cancelled or drops out of the calendar lookback.
    public let blockStart: Date?
    public let blockEnd: Date?

    public init(pausedAt: Date, meetingOnly: Bool, blockStart: Date? = nil, blockEnd: Date? = nil) {
        self.pausedAt = pausedAt
        self.meetingOnly = meetingOnly
        self.blockStart = blockStart
        self.blockEnd = blockEnd
    }
}

/// Keeps Pause from silently eating a meeting. A pause set outside a meeting
/// block ends when the next block starts. A pause set inside a block holds for
/// the rest of that block only. In continuous mode (meeting-only off) no
/// meetings drive listening, so Pause holds until the user resumes.
public enum PausePolicy {
    /// The record to save when the user pauses at `now`.
    public static func record(at now: Date, meetingOnly: Bool, schedule: MeetingSchedule) -> PauseRecord {
        let block = schedule.activeBlock(at: now)
        return PauseRecord(pausedAt: now, meetingOnly: meetingOnly, blockStart: block?.start, blockEnd: block?.end)
    }

    /// Fills in the paused block once the calendar has loaded, for a pause
    /// recorded before the schedule was known (at launch, or by an older
    /// version that saved no block).
    public static func anchored(_ record: PauseRecord, schedule: MeetingSchedule) -> PauseRecord {
        guard record.blockStart == nil, let block = schedule.blocks.first(where: { $0.contains(record.pausedAt) }) else {
            return record
        }
        return PauseRecord(
            pausedAt: record.pausedAt, meetingOnly: record.meetingOnly, blockStart: block.start, blockEnd: block.end
        )
    }

    /// Whether `block` is the one the pause was set in: it contains the
    /// moment of the pause, or overlaps the block saved then.
    public static func isPausedBlock(_ block: MeetingSchedule.Block, _ record: PauseRecord) -> Bool {
        if block.contains(record.pausedAt) { return true }
        guard let start = record.blockStart, let end = record.blockEnd else { return false }
        return block.start < end && start < block.end
    }

    /// Whether to resume now.
    public static func shouldAutoResume(
        record: PauseRecord?, meetingOnly: Bool, schedule: MeetingSchedule, now: Date
    ) -> Bool {
        guard let record, record.meetingOnly, meetingOnly, let block = schedule.activeBlock(at: now) else { return false }
        return !isPausedBlock(block, record)
    }

    /// When the pause will lift on its own, or nil when it won't (continuous
    /// mode, no calendar, or no later block in the loaded schedule).
    public static func nextAutoResume(
        record: PauseRecord?, meetingOnly: Bool, calendarAvailable: Bool, schedule: MeetingSchedule, now: Date
    ) -> Date? {
        guard let record, record.meetingOnly, meetingOnly, calendarAvailable else { return nil }
        return schedule.blocks.first { $0.end > now && !isPausedBlock($0, record) }.map { max($0.start, now) }
    }

    /// After meeting-only is switched on while paused: a continuous-mode pause
    /// becomes a meeting-only pause set now, so it holds for the block in
    /// progress and lifts at the next one.
    public static func afterMeetingOnlyChange(
        _ record: PauseRecord?, meetingOnly: Bool, schedule: MeetingSchedule, now: Date
    ) -> PauseRecord? {
        guard let record, meetingOnly, !record.meetingOnly else { return record }
        return Self.record(at: now, meetingOnly: true, schedule: schedule)
    }
}

/// Saves the pause across relaunches.
public struct PauseStore {
    static let pausedKey = "paused"
    static let recordKey = "pauseRecord"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved record, or nil when not paused. A pause saved by an older
    /// version has no record; it is treated as set now, so a relaunch inside
    /// a meeting holds for that block instead of resuming at once.
    public func load(now: Date, meetingOnly: Bool) -> PauseRecord? {
        guard defaults.bool(forKey: Self.pausedKey) else { return nil }
        if let data = defaults.data(forKey: Self.recordKey),
           let record = try? JSONDecoder().decode(PauseRecord.self, from: data) {
            return record
        }
        return PauseRecord(pausedAt: now, meetingOnly: meetingOnly)
    }

    public func save(_ record: PauseRecord?) {
        defaults.set(record != nil, forKey: Self.pausedKey)
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Self.recordKey)
        } else {
            defaults.removeObject(forKey: Self.recordKey)
        }
    }
}
