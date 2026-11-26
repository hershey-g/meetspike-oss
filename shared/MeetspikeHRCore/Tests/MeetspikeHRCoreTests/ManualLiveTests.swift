import XCTest
@testable import MeetspikeHRCore

final class ManualLiveTests: XCTestCase {
    func testRestoredOnlyInMeetingOnlyMode() {
        XCTAssertTrue(ManualLive.restored(meetingOnly: true, saved: true))
        XCTAssertFalse(ManualLive.restored(meetingOnly: false, saved: true))
        XCTAssertFalse(ManualLive.restored(meetingOnly: true, saved: false))
        XCTAssertFalse(ManualLive.restored(meetingOnly: false, saved: false))
    }

    func testTurningMeetingOnlyOffClearsGoLive() {
        XCTAssertFalse(ManualLive.afterMeetingOnlyChange(meetingOnly: false, current: true))
        XCTAssertTrue(ManualLive.afterMeetingOnlyChange(meetingOnly: true, current: true))
        XCTAssertFalse(ManualLive.afterMeetingOnlyChange(meetingOnly: true, current: false))
    }

    func testCanAlwaysTurnOff() {
        XCTAssertTrue(ManualLive.canToggle(isOn: true, paused: false, calendarAccessNeeded: true))
        XCTAssertTrue(ManualLive.canToggle(isOn: true, paused: true, calendarAccessNeeded: false))
        XCTAssertTrue(ManualLive.canToggle(isOn: true, paused: true, calendarAccessNeeded: true))
    }

    func testCannotTurnOnWhilePausedOrCalendarMissing() {
        XCTAssertFalse(ManualLive.canToggle(isOn: false, paused: true, calendarAccessNeeded: false))
        XCTAssertFalse(ManualLive.canToggle(isOn: false, paused: false, calendarAccessNeeded: true))
        XCTAssertTrue(ManualLive.canToggle(isOn: false, paused: false, calendarAccessNeeded: false))
    }

    func testPauseStillWinsOverRestoredGoLive() {
        let live = ManualLive.restored(meetingOnly: true, saved: true)
        XCTAssertFalse(ListenGate.shouldListen(
            paused: true, sleeping: false, meetingOnly: true, calendarDenied: false,
            manualLive: live, setupComplete: true, inMeetingWindow: false
        ))
        XCTAssertTrue(ListenGate.shouldListen(
            paused: false, sleeping: false, meetingOnly: true, calendarDenied: false,
            manualLive: live, setupComplete: true, inMeetingWindow: false
        ))
    }
}
