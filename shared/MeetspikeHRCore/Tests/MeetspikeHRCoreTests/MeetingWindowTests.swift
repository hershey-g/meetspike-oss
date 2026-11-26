import Foundation
import XCTest
@testable import MeetspikeHRCore

final class MeetingWindowTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testWindowIncludesLeadAndCooldownWithExclusiveEnd() throws {
        // Build 11: listening starts five minutes before a meeting (it was two).
        let call = try meeting("Call", 20, 50)
        let schedule = MeetingSchedule([call])
        XCTAssertNil(schedule.activeBlock(at: at(15).addingTimeInterval(-0.001)))
        XCTAssertEqual(schedule.activeBlock(at: at(15))?.first, call)
        XCTAssertEqual(schedule.activeBlock(at: at(59))?.last, call)
        XCTAssertNil(schedule.activeBlock(at: at(60)))
        XCTAssertEqual(schedule.nextBoundary(after: at(14)), at(15))
        XCTAssertEqual(schedule.nextBoundary(after: at(15)), at(60))
        XCTAssertNil(schedule.nextBoundary(after: at(60)))
    }

    func testBlocksMergeOverlapsAndTouchingPadsWithoutLosingLatestEnd() throws {
        let first = try meeting("First", 20, 50)
        let inside = try meeting("Overlapping", 30, 40)
        let second = try meeting("Second", 64, 80)
        let separate = try meeting("Separate", 96, 99)
        let schedule = MeetingSchedule([separate, second, inside, first])
        // First ends at 50 + 10 min cooldown = 60. Second listens from 64 - 5 = 59, so they merge. Second ends at 90.
        // Separate listens from 96 - 5 = 91, so it is its own block.
        XCTAssertEqual(schedule.blocks.map(\.first), [first, separate])
        XCTAssertEqual(schedule.blocks.map(\.last), [second, separate])
        XCTAssertEqual(schedule.activeBlock(at: at(60))?.last, second)
        XCTAssertNil(schedule.activeBlock(at: at(90)))
        XCTAssertEqual(schedule.activeBlock(at: at(91))?.first, separate)
        XCTAssertEqual(schedule.displayedMeeting(at: at(35)), inside)
        XCTAssertEqual(schedule.displayedMeeting(at: at(54)), first)
        XCTAssertEqual(schedule.displayedMeeting(at: at(60)), second)
        XCTAssertEqual(schedule.displayedMeeting(at: at(90)), separate)
    }

    func testListeningStartsFiveMinutesBeforeAMeeting() {
        XCTAssertEqual(CalendarMeeting.leadIn, 300)
        let call = CalendarMeeting(title: "Call", start: at(20), end: at(50))
        XCTAssertEqual(call?.listenFrom, at(15))
        XCTAssertEqual(call?.listenUntil, at(60), "the ten minute cooldown is unchanged")
    }

    func testAllDayDeclinedAndUnsupportedDurationsAreExcluded() throws {
        XCTAssertNil(CalendarMeeting(title: "All day", start: at(0), end: at(15), isAllDay: true))
        XCTAssertNil(CalendarMeeting(title: "Declined", start: at(0), end: at(15), isDeclined: true))
        XCTAssertNil(CalendarMeeting(title: "Zero", start: at(0), end: at(0)))
        XCTAssertNil(CalendarMeeting(title: "Reversed", start: at(1), end: at(0)))
        XCTAssertNil(CalendarMeeting(title: "Too long", start: at(0), end: at(481)))
        XCTAssertEqual(try meeting("", 0, 480).title, "Untitled meeting")
    }

    func testListenGateFallsBackToContinuousWhenCalendarIsDenied() {
        func listen(paused: Bool = false, sleeping: Bool = false, meetingOnly: Bool = true, denied: Bool = false,
                    manual: Bool = false, setup: Bool = true, inWindow: Bool = false) -> Bool {
            ListenGate.shouldListen(paused: paused, sleeping: sleeping, meetingOnly: meetingOnly, calendarDenied: denied,
                                    manualLive: manual, setupComplete: setup, inMeetingWindow: inWindow)
        }
        XCTAssertFalse(listen(), "meeting-only, outside a meeting")
        XCTAssertTrue(listen(inWindow: true))
        XCTAssertTrue(listen(denied: true), "no calendar: listen continuously")
        XCTAssertTrue(listen(meetingOnly: false))
        XCTAssertTrue(listen(manual: true))
        XCTAssertTrue(listen(setup: false), "first-run setup listens")
        XCTAssertFalse(listen(paused: true, denied: true, inWindow: true), "pause wins")
        XCTAssertFalse(listen(sleeping: true, meetingOnly: false), "sleep wins")
    }

    private func meeting(_ title: String, _ start: Int, _ end: Int) throws -> CalendarMeeting {
        try XCTUnwrap(CalendarMeeting(title: title, start: at(start), end: at(end)))
    }

    private func at(_ minute: Int) -> Date { base.addingTimeInterval(Double(60 * minute)) }
}
