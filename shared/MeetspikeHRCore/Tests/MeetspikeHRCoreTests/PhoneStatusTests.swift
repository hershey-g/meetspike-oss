import Foundation
import XCTest
@testable import MeetspikeHRCore

final class PhoneStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPhoneDoesNotStartBluetoothBeforePermissionExplanations() {
        for manual in [false, true] {
            for meeting in [false, true] {
                XCTAssertFalse(ListenGate.shouldListenOnPhone(
                    onboardingComplete: false, manualLive: manual, inMeetingWindow: meeting
                ))
                XCTAssertEqual(ListenGate.shouldListenOnPhone(
                    onboardingComplete: true, manualLive: manual, inMeetingWindow: meeting
                ), manual || meeting)
            }
        }
    }

    private func state(
        _ connection: BluetoothStatus, permission: BluetoothPermission = .allowed, listening: Bool = true,
        latestAgo: TimeInterval? = nil, current: Bool = true
    ) -> PhoneHeartState {
        PhoneHeartState(
            connection: connection, permission: permission, listening: listening,
            latestAt: latestAgo.map { now.addingTimeInterval(-$0) }, hasCurrentReading: current, now: now
        )
    }

    func testFreshReadingOnLiveConnectionIsLive() {
        XCTAssertEqual(state(.connected, latestAgo: 2).tone, .live)
        XCTAssertEqual(state(.connected, latestAgo: 2).title, "Live")
    }

    func testConnectedWithoutFreshReadingWaits() {
        XCTAssertEqual(state(.connected).tone, .working)
        XCTAssertEqual(state(.connected, latestAgo: 50).tone, .working)
        XCTAssertEqual(state(.connected, latestAgo: 2, current: false).tone, .working)
    }

    func testNoPhoneTextUsesTheOldAppName() {
        let all: [BluetoothStatus] = [.starting, .searching, .reconnecting, .poweredOff, .unauthorized, .unsupported,
                                      .waiting, .connecting, .connected, .paused, .sleeping, .outsideMeeting]
        for connection in all {
            for permission in [BluetoothPermission.notDetermined, .allowed, .denied] {
                for listening in [false, true] {
                    let heart = state(connection, permission: permission, listening: listening, latestAgo: 1)
                    XCTAssertFalse(heart.title.contains("Meetspike HR"), "\(connection) \(permission)")
                    XCTAssertFalse(heart.detail?.contains("Meetspike HR") ?? false, "\(connection) \(permission)")
                }
            }
        }
    }

    func testDeniedPermissionWinsEvenWhenIdle() {
        let denied = state(.outsideMeeting, permission: .denied, listening: false)
        XCTAssertEqual(denied.tone, .problem)
        XCTAssertEqual(denied.action, .openSettings)
        XCTAssertEqual(state(.unauthorized).action, .openSettings)
    }

    func testNotListeningIsIdleWhateverTheLastStatus() {
        XCTAssertEqual(state(.connected, listening: false, latestAgo: 1).tone, .idle)
        XCTAssertEqual(state(.outsideMeeting, listening: false).title, "Not listening")
    }

    func testSearchingAndWaitingExplainWhatToDo() {
        XCTAssertTrue(state(.searching).detail?.contains("HR Broadcast") == true)
        XCTAssertTrue(state(.waiting).detail?.contains("open") == true)
        XCTAssertEqual(state(.poweredOff).tone, .problem)
        XCTAssertEqual(state(.reconnecting).tone, .working)
    }

    func testCountdownPhases() throws {
        let meeting = try XCTUnwrap(CalendarMeeting(
            title: "Review", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2_400)
        ))
        let schedule = MeetingSchedule([meeting])
        XCTAssertEqual(MeetingCountdown(meeting: meeting, schedule: schedule, now: now), .startsIn(meeting.start))
        XCTAssertEqual(
            MeetingCountdown(meeting: meeting, schedule: schedule, now: now.addingTimeInterval(601)), .endsIn(meeting.end)
        )
        XCTAssertEqual(
            MeetingCountdown(meeting: meeting, schedule: schedule, now: now.addingTimeInterval(2_500)),
            .cooldown(meeting.listenUntil)
        )
        XCTAssertEqual(MeetingCountdown(meeting: meeting, schedule: schedule, now: now.addingTimeInterval(3_100)), .ended)
    }

    func testFarMeetingsShowADateInsteadOfALongTimer() throws {
        let tomorrow = try XCTUnwrap(CalendarMeeting(
            title: "Tomorrow", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(88_200)
        ))
        let schedule = MeetingSchedule([tomorrow])
        XCTAssertEqual(MeetingCountdown(meeting: tomorrow, schedule: schedule, now: now), .later(tomorrow.start))
        let edge = now.addingTimeInterval(86_400 - MeetingCountdown.timerHorizon)
        XCTAssertEqual(MeetingCountdown(meeting: tomorrow, schedule: schedule, now: edge), .startsIn(tomorrow.start))
    }
}
