import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 11 fix pass, F7 and F8 (spec11-fix.md).
//
// NEW API: `HRReminderPolicy.tooEarly(now: Date, meetings: [CalendarMeeting]) -> Bool`, pure.
// True when some meeting has `start - 300 s <= now < start - 120 s` and no meeting satisfies
// `start - 120 s <= now <= end + 600 s`. The Mac skips its reminder step while it is true (meeting-only mode),
// so the five minute listening lead never makes the Mac remind earlier than two minutes before a meeting.

final class Build11TooEarlyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    private func meeting(_ title: String, _ start: TimeInterval, _ end: TimeInterval) -> CalendarMeeting {
        CalendarMeeting(title: title, start: at(start), end: at(end))!
    }

    /// One meeting starting at 0 and ending at 1800.
    private var one: [CalendarMeeting] { [meeting("Call", 0, 1_800)] }

    func testBoundariesAroundTheFiveAndTwoMinuteMarks() {
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-301), meetings: one), "more than five minutes out: not listening yet")
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-300), meetings: one), "listening starts, reminders must wait")
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-299), meetings: one))
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-200), meetings: one))
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-121), meetings: one))
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-120), meetings: one), "the old T-2 mark: reminders are allowed again")
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-60), meetings: one))
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(0), meetings: one))
    }

    func testFractionalSecondsFollowTheSameEdges() {
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-120.001), meetings: one))
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-300.001), meetings: one))
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-299.999), meetings: one))
    }

    func testNeverTooEarlyDuringOrAfterAMeeting() {
        for seconds: TimeInterval in [1, 600, 1_799, 1_800, 1_800 + 300, 1_800 + 600, 1_800 + 601, 7_200] {
            XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(seconds), meetings: one), "\(seconds) s")
        }
    }

    func testNoMeetingsIsNeverTooEarly() {
        for seconds: TimeInterval in [-400, -300, -200, -121, 0, 500] {
            XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(seconds), meetings: []), "\(seconds) s")
        }
    }

    func testAMeetingInProgressKeepsReminders() {
        // Next meeting at 0; the earlier one runs from -3000 to -100, so at -200 it is in progress.
        let meetings = [meeting("Earlier", -3_000, -100), meeting("Next", 0, 1_800)]
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-200), meetings: meetings), "something is running, remind as usual")
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-200), meetings: meetings.reversed()), "order does not matter")
    }

    func testAMeetingInItsAfterWindowKeepsReminders() {
        // Ended at -500: its after-window (end + 600) runs to +100, so it covers now = -200.
        let inAfter = [meeting("Earlier", -3_000, -500), meeting("Next", 0, 1_800)]
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-200), meetings: inAfter))
        // The edge is inclusive: end + 600 == now still counts. Ended at -850 gives -250 exactly.
        let edge = [meeting("Earlier", -3_000, -850), meeting("Next", 0, 1_800)]
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-250), meetings: edge), "now == end + 600 is still inside")
        let past = [meeting("Earlier", -3_000, -851), meeting("Next", 0, 1_800)]
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-250), meetings: past), "one second later the earlier meeting is fully over")
    }

    func testAnEarlierMeetingTwoMinutesBeforeItsStartCountsAsNothingYet() {
        // A far later meeting does not matter: only the one whose early range holds now.
        let meetings = [meeting("Soon", 0, 1_800), meeting("Much later", 20_000, 21_000)]
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-200), meetings: meetings))
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(10_000), meetings: meetings))
    }

    func testBackToBackMeetingsAreNeverTooEarlyBetweenThem() {
        let meetings = [meeting("A", 0, 1_800), meeting("B", 1_800, 3_600)]
        for seconds: TimeInterval in [1_000, 1_500, 1_680, 1_700, 1_800, 1_900] {
            XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(seconds), meetings: meetings), "\(seconds) s")
        }
    }

    func testTwoMeetingsAtOneStartBehaveLikeOne() {
        let meetings = [meeting("A", 0, 1_800), meeting("B", 0, 900)]
        XCTAssertTrue(HRReminderPolicy.tooEarly(now: at(-200), meetings: meetings))
        XCTAssertFalse(HRReminderPolicy.tooEarly(now: at(-100), meetings: meetings))
    }

    /// Uses the constants that already exist where they match (lead 300, cooldown 600), so a later change moves both.
    func testTheConstantsStillMatchTheSpecNumbers() {
        XCTAssertEqual(CalendarMeeting.leadIn, 300)
        XCTAssertEqual(CalendarMeeting.cooldown, 600)
    }
}

final class Build11FixFilesTests: XCTestCase {
    private func read(_ path: String, file: String = #filePath) throws -> String {
        var root = URL(fileURLWithPath: file)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("mac").path) {
                XCTFail("missing \(path)")
                return ""
            }
            throw XCTSkip("no mac/ folder next to this package")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testMacControllerSkipsEvaluationWhileTooEarlyInMeetingOnlyMode() throws {
        let source = try read("mac/MeetspikeHR/Sources/MeetspikeHR/HRReminderController.swift")
        XCTAssertTrue(source.contains("tooEarly"), "the controller asks the policy before it evaluates")
    }

    func testMacReadmeSaysFifteenMinutesForMergedPauseBlocks() throws {
        let readme = try read("mac/MeetspikeHR/README.md")
        XCTAssertFalse(readme.contains("about 12 minutes"), "five minutes of lead plus ten of cooldown is 15")
        XCTAssertTrue(readme.contains("about 15 minutes apart"))
    }
}
