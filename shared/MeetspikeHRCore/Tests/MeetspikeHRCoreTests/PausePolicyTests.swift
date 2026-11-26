import XCTest
@testable import MeetspikeHRCore

final class PausePolicyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    /// Minutes after 8:00.
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    private func meeting(_ title: String, _ start: Double, _ end: Double) -> CalendarMeeting {
        CalendarMeeting(title: title, start: at(start), end: at(end))!
    }

    /// 9:30-10:00 and 11:00-11:30.
    private var schedule: MeetingSchedule {
        MeetingSchedule([meeting("Standup", 90, 120), meeting("Review", 180, 210)])
    }

    private func resumes(
        meetingOnly: Bool = true, pausedMeetingOnly: Bool = true, pausedAt: Date, now: Date,
        pausedSchedule: MeetingSchedule? = nil, nowSchedule: MeetingSchedule? = nil
    ) -> Bool {
        let record = PausePolicy.record(at: pausedAt, meetingOnly: pausedMeetingOnly, schedule: pausedSchedule ?? schedule)
        return PausePolicy.shouldAutoResume(
            record: record, meetingOnly: meetingOnly, schedule: nowSchedule ?? schedule, now: now
        )
    }

    func testPausedBeforeBlockResumesAtBlockStart() {
        let pausedAt = at(51) // 8:51
        XCTAssertFalse(resumes(pausedAt: pausedAt, now: at(80)), "still outside the block")
        XCTAssertFalse(resumes(pausedAt: pausedAt, now: at(84)), "build 11: the block opens five minutes early, not before")
        XCTAssertTrue(resumes(pausedAt: pausedAt, now: at(85)), "block opens five minutes early")
        XCTAssertTrue(resumes(pausedAt: pausedAt, now: at(95)), "mid-meeting still resumes")
    }

    func testPausedInsideBlockHoldsForThatBlockThenResumesAtNext() {
        let pausedAt = at(100) // during Standup
        XCTAssertFalse(resumes(pausedAt: pausedAt, now: at(110)))
        XCTAssertFalse(resumes(pausedAt: pausedAt, now: at(125)), "still in the ten-minute pad")
        XCTAssertFalse(resumes(pausedAt: pausedAt, now: at(150)), "between blocks")
        XCTAssertTrue(resumes(pausedAt: pausedAt, now: at(178)), "next block starts")
    }

    func testNotPausedIsNoOp() {
        XCTAssertFalse(PausePolicy.shouldAutoResume(record: nil, meetingOnly: true, schedule: schedule, now: at(95)))
    }

    func testContinuousModeRespectsPause() {
        XCTAssertFalse(resumes(meetingOnly: false, pausedMeetingOnly: false, pausedAt: at(51), now: at(95)))
        XCTAssertFalse(resumes(meetingOnly: false, pausedAt: at(100), now: at(178)))
    }

    func testNoBlockNeverResumes() {
        let record = PausePolicy.record(at: at(51), meetingOnly: true, schedule: MeetingSchedule())
        XCTAssertFalse(PausePolicy.shouldAutoResume(record: record, meetingOnly: true, schedule: MeetingSchedule(), now: at(95)))
    }

    // MARK: Block identity

    /// A 9:30-10:00 and B 10:00-11:00 share one block. Paused at 9:50, then A
    /// is cancelled at 10:15: B's block now starts 9:58 but is the same block.
    func testFirstMeetingCancelledMidBlockKeepsPause() {
        let merged = MeetingSchedule([meeting("A", 90, 120), meeting("B", 120, 180)])
        let bOnly = MeetingSchedule([meeting("B", 120, 180)])
        XCTAssertFalse(resumes(pausedAt: at(110), now: at(135), pausedSchedule: merged, nowSchedule: bOnly))
    }

    func testEarlierOverlappingEventAppearsKeepsPause() {
        let original = MeetingSchedule([meeting("A", 90, 120)])
        let grown = MeetingSchedule([meeting("Early", 70, 95), meeting("A", 90, 120)])
        XCTAssertFalse(resumes(pausedAt: at(100), now: at(110), pausedSchedule: original, nowSchedule: grown))
    }

    func testFirstMeetingMovedLaterKeepsPause() {
        let original = MeetingSchedule([meeting("A", 90, 150)])
        let moved = MeetingSchedule([meeting("A", 110, 150)])
        XCTAssertFalse(resumes(pausedAt: at(100), now: at(115), pausedSchedule: original, nowSchedule: moved))
    }

    /// A long chain whose first meeting drops out of the calendar lookback.
    func testLookbackDropKeepsPause() {
        let full = MeetingSchedule([meeting("A", 0, 30), meeting("B", 35, 300), meeting("C", 300, 560)])
        let trimmed = MeetingSchedule([meeting("C", 300, 560)])
        XCTAssertFalse(resumes(pausedAt: at(20), now: at(500), pausedSchedule: full, nowSchedule: trimmed))
    }

    func testDistinctLaterBlockStillResumes() {
        let original = MeetingSchedule([meeting("A", 90, 120)])
        let later = MeetingSchedule([meeting("A", 90, 120), meeting("C", 140, 170)])
        XCTAssertTrue(resumes(pausedAt: at(100), now: at(139), pausedSchedule: original, nowSchedule: later))
    }

    func testAnchoredFillsBlockForRecordMadeBeforeCalendarLoaded() {
        let merged = MeetingSchedule([meeting("A", 90, 120), meeting("B", 120, 180)])
        let bare = PauseRecord(pausedAt: at(110), meetingOnly: true)
        let anchored = PausePolicy.anchored(bare, schedule: merged)
        XCTAssertEqual(anchored.blockStart, at(85))
        XCTAssertEqual(anchored.blockEnd, at(190))
        let bOnly = MeetingSchedule([meeting("B", 120, 180)])
        XCTAssertFalse(PausePolicy.shouldAutoResume(record: anchored, meetingOnly: true, schedule: bOnly, now: at(135)))
        XCTAssertEqual(PausePolicy.anchored(anchored, schedule: bOnly), anchored, "an anchored record keeps its block")
    }

    // MARK: Resume time shown in the menu

    func testNextAutoResumeIsNextBlockStart() {
        let record = PausePolicy.record(at: at(51), meetingOnly: true, schedule: schedule)
        XCTAssertEqual(
            PausePolicy.nextAutoResume(record: record, meetingOnly: true, calendarAvailable: true, schedule: schedule, now: at(60)),
            at(85)
        )
    }

    /// Meetings 9:30-10:00, 10:00-11:00 and 11:10-12:00 form one block.
    /// Paused at 10:01, it resumes at the next block (13:55), not at 11:10.
    func testNextAutoResumeSkipsMeetingsInThePausedBlock() {
        let chain = MeetingSchedule([
            meeting("A", 90, 120), meeting("B", 120, 180), meeting("C", 190, 240), meeting("D", 360, 390),
        ])
        let record = PausePolicy.record(at: at(121), meetingOnly: true, schedule: chain)
        XCTAssertEqual(
            PausePolicy.nextAutoResume(record: record, meetingOnly: true, calendarAvailable: true, schedule: chain, now: at(121)),
            at(355)
        )
        XCTAssertFalse(PausePolicy.shouldAutoResume(record: record, meetingOnly: true, schedule: chain, now: at(191)))
    }

    func testNoResumePromiseWithoutCalendarOrMeetingOnlyOrNextBlock() {
        let record = PausePolicy.record(at: at(51), meetingOnly: true, schedule: schedule)
        XCTAssertNil(PausePolicy.nextAutoResume(record: record, meetingOnly: true, calendarAvailable: false, schedule: schedule, now: at(60)))
        XCTAssertNil(PausePolicy.nextAutoResume(record: record, meetingOnly: false, calendarAvailable: true, schedule: schedule, now: at(60)))
        XCTAssertNil(PausePolicy.nextAutoResume(record: record, meetingOnly: true, calendarAvailable: true, schedule: MeetingSchedule(), now: at(60)))
        XCTAssertNil(PausePolicy.nextAutoResume(record: nil, meetingOnly: true, calendarAvailable: true, schedule: schedule, now: at(60)))
        let inLast = PausePolicy.record(at: at(200), meetingOnly: true, schedule: schedule)
        XCTAssertNil(PausePolicy.nextAutoResume(record: inLast, meetingOnly: true, calendarAvailable: true, schedule: schedule, now: at(200)))
        let continuous = PausePolicy.record(at: at(51), meetingOnly: false, schedule: schedule)
        XCTAssertNil(PausePolicy.nextAutoResume(record: continuous, meetingOnly: true, calendarAvailable: true, schedule: schedule, now: at(60)))
    }

    // MARK: Meeting-only switched on while paused

    func testContinuousPauseHoldsWhenMeetingOnlyTurnedOnMidBlock() {
        let continuous = PausePolicy.record(at: at(0), meetingOnly: false, schedule: schedule)
        let switched = PausePolicy.afterMeetingOnlyChange(continuous, meetingOnly: true, schedule: schedule, now: at(100))
        XCTAssertFalse(PausePolicy.shouldAutoResume(record: switched, meetingOnly: true, schedule: schedule, now: at(100)))
        XCTAssertTrue(PausePolicy.shouldAutoResume(record: switched, meetingOnly: true, schedule: schedule, now: at(178)))
    }

    func testMeetingOnlyChangeLeavesOtherRecordsAlone() {
        let record = PausePolicy.record(at: at(51), meetingOnly: true, schedule: schedule)
        XCTAssertEqual(PausePolicy.afterMeetingOnlyChange(record, meetingOnly: true, schedule: schedule, now: at(100)), record)
        XCTAssertEqual(PausePolicy.afterMeetingOnlyChange(record, meetingOnly: false, schedule: schedule, now: at(100)), record)
        XCTAssertNil(PausePolicy.afterMeetingOnlyChange(nil, meetingOnly: true, schedule: schedule, now: at(100)))
    }
}

final class PauseStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suiteName = "PauseStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A pause set inside a meeting survives a relaunch and still holds for
    /// that block: the record written is the one read back by a new store.
    func testPauseInsideBlockSurvivesRelaunch() {
        let schedule = MeetingSchedule([CalendarMeeting(title: "A", start: base.addingTimeInterval(5_400), end: base.addingTimeInterval(7_200))!])
        let record = PausePolicy.record(at: base.addingTimeInterval(6_000), meetingOnly: true, schedule: schedule)
        PauseStore(defaults: defaults).save(record)

        let relaunched = PauseStore(defaults: defaults).load(now: base.addingTimeInterval(6_600), meetingOnly: true)
        XCTAssertEqual(relaunched, record)
        XCTAssertNotNil(relaunched?.blockStart)
        XCTAssertFalse(PausePolicy.shouldAutoResume(
            record: relaunched, meetingOnly: true, schedule: schedule, now: base.addingTimeInterval(6_600)
        ))
    }

    func testResumeClearsSavedPause() {
        let store = PauseStore(defaults: defaults)
        store.save(PauseRecord(pausedAt: base, meetingOnly: true))
        store.save(nil)
        XCTAssertNil(PauseStore(defaults: defaults).load(now: base, meetingOnly: true))
        XCTAssertFalse(defaults.bool(forKey: "paused"))
        XCTAssertNil(defaults.data(forKey: "pauseRecord"))
    }

    /// An older version saved only `paused`. Treat it as paused now, so a
    /// relaunch mid-meeting holds for that block instead of resuming at once.
    func testLegacyPauseIsTreatedAsSetAtLaunch() {
        defaults.set(true, forKey: "paused")
        let now = base.addingTimeInterval(6_000)
        let loaded = PauseStore(defaults: defaults).load(now: now, meetingOnly: true)
        XCTAssertEqual(loaded, PauseRecord(pausedAt: now, meetingOnly: true))
        let schedule = MeetingSchedule([CalendarMeeting(title: "A", start: base.addingTimeInterval(5_400), end: base.addingTimeInterval(7_200))!])
        XCTAssertFalse(PausePolicy.shouldAutoResume(record: loaded, meetingOnly: true, schedule: schedule, now: now))
    }

    func testNotPausedLoadsNil() {
        XCTAssertNil(PauseStore(defaults: defaults).load(now: base, meetingOnly: true))
    }
}
