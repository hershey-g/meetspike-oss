import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 fix pass, F1: "I didn't join" is only offered for a meeting that is current.
//
// NEW API: `LiveAdjust.Offer.didntJoin: Bool`. True only while the meeting is current: from 2 minutes before its
// effective start to the end of its cooldown (the same window as the listening window, `CalendarMeeting.listenFrom`
// to `listenUntil`). Never for a future meeting. It does not depend on the 4 h cap, and `Offer.none.didntJoin` is false.
//
// This file is the only one that needs the new member, so it is the only one that fails to compile today.
// The Mac button wiring (show the choice with Undo for the meeting it was used on, never retarget within the same
// click burst) lives in the Mac app, not in this package, and has no test here.

final class Build9FixF1DidntJoinTests: XCTestCase {
    private let cap: TimeInterval = 3600 + 4 * 3600

    private func target(start: TimeInterval = 0, end: TimeInterval = 3600) -> LiveAdjustTarget {
        LiveAdjustTarget(meetingID: "ev1", title: "Standup", start: B9.at(start), end: B9.at(end), calendarEnd: B9.at(3600))
    }

    func testNoTargetMeansNoButton() {
        XCTAssertFalse(LiveAdjust.offer(nil, now: B9.at(900)).didntJoin)
        XCTAssertFalse(LiveAdjust.Offer.none.didntJoin)
    }

    func testAFutureMeetingNeverOffersIt() {
        // The review's repro: the only meeting is hours away.
        for ahead in [6 * 3600.0, 3600, 600, 121, 120.5] {
            XCTAssertFalse(LiveAdjust.offer(target(), now: B9.at(-ahead)).didntJoin, "\(ahead) s before the start")
        }
    }

    func testItAppearsTwoMinutesBeforeTheStartAndNotOneSecondEarlier() {
        XCTAssertFalse(LiveAdjust.offer(target(), now: B9.at(-121)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(target(), now: B9.at(-120)).didntJoin, "the listening window opens here")
        XCTAssertTrue(LiveAdjust.offer(target(), now: B9.at(-1)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(target(), now: B9.at(0)).didntJoin)
    }

    func testItIsOfferedWhileTheMeetingRuns() {
        for second in [1.0, 900, 1800, 3599] {
            XCTAssertTrue(LiveAdjust.offer(target(), now: B9.at(second)).didntJoin, "\(second) s in")
        }
    }

    func testItIsOfferedThroughTheCooldownAndGoneWhenItEnds() {
        XCTAssertTrue(LiveAdjust.offer(target(), now: B9.at(3600)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(target(), now: B9.at(3600 + 599)).didntJoin)
        XCTAssertFalse(LiveAdjust.offer(target(), now: B9.at(3600 + 600)).didntJoin, "the cooldown is over")
        XCTAssertFalse(LiveAdjust.offer(target(), now: B9.at(3600 + 3 * 3600)).didntJoin)
    }

    func testTheWindowFollowsTheMovedTimesNotTheCalendarOnes() {
        // The owner moved the meeting to 600 s .. 7200 s.
        let moved = target(start: 600, end: 7200)
        XCTAssertFalse(LiveAdjust.offer(moved, now: B9.at(600 - 121)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(moved, now: B9.at(600 - 120)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(moved, now: B9.at(5000)).didntJoin, "past the calendar end, inside the moved one")
        XCTAssertTrue(LiveAdjust.offer(moved, now: B9.at(7200 + 599)).didntJoin)
        XCTAssertFalse(LiveAdjust.offer(moved, now: B9.at(7200 + 600)).didntJoin)
    }

    func testTheFourHourCapOnStillGoingDoesNotTakeItAway() {
        let capped = target(start: 0, end: cap)
        let offer = LiveAdjust.offer(capped, now: B9.at(3000))
        XCTAssertFalse(offer.stillGoing)
        XCTAssertTrue(offer.endedNow)
        XCTAssertTrue(offer.didntJoin)
        XCTAssertTrue(LiveAdjust.offer(capped, now: B9.at(cap)).didntJoin, "in the cooldown, Still going is gone, this is not")
    }

    func testTheOtherTwoButtonsKeepTheirRules() {
        // Adding the member must not move the rules the earlier tests pin.
        let running = LiveAdjust.offer(target(), now: B9.at(1800))
        XCTAssertTrue(running.stillGoing)
        XCTAssertTrue(running.endedNow)
        let lead = LiveAdjust.offer(target(), now: B9.at(-60))
        XCTAssertFalse(lead.stillGoing)
        XCTAssertFalse(lead.endedNow)
        let cooldown = LiveAdjust.offer(target(), now: B9.at(3700))
        XCTAssertTrue(cooldown.stillGoing)
        XCTAssertFalse(cooldown.endedNow)
    }

    // MARK: Through the schedule, as the Mac menu reads it

    func testTheOnlyMeetingIsSixHoursAwayAndIsMatchedSoThereIsATargetButNoButton() throws {
        let phone = [B9.meeting("Planning", 6 * 3600, 6 * 3600 + 1800)]
        let remote = [H9.remote("ev-late", title: "Planning", start: 6 * 3600, end: 6 * 3600 + 1800)]
        let now = B9.at(0)
        let shown = try XCTUnwrap(MeetingSchedule(phone).displayedMeeting(at: now), "the menu shows the next meeting")
        let target = try XCTUnwrap(LiveAdjust.target(displayed: shown, resolved: OverrideMatch.resolve(remote, to: phone)))
        XCTAssertFalse(LiveAdjust.offer(target, now: now).didntJoin)
        XCTAssertFalse(LiveAdjust.offer(target, now: now).stillGoing)
    }

    func testAfterTheCurrentMeetingIsLeftOutTheNextOneIsNotOfferedUntilItIsCurrent() throws {
        let phone = [B9.meeting("Standup", 0, 1800), B9.meeting("Planning", 7200, 9000)]
        let first = H9.remote("ev1", title: "Standup", start: 0, end: 1800, override: MeetingOverride(state: .notJoined, scope: .event))
        let second = H9.remote("ev2", title: "Planning", start: 7200, end: 9000)
        let now = B9.at(900)

        // The tap on "I didn't join" for the first meeting drops it, and the menu now shows the second.
        let after = OverrideMatch.apply([first, second], to: phone)
        let shown = try XCTUnwrap(MeetingSchedule(after).displayedMeeting(at: now))
        XCTAssertEqual(shown.title, "Planning")
        let target = try XCTUnwrap(LiveAdjust.target(displayed: shown, resolved: OverrideMatch.resolve([first, second], to: phone)))
        XCTAssertEqual(target.meetingID, "ev2")
        XCTAssertFalse(LiveAdjust.offer(target, now: now).didntJoin, "a second click must not exclude the next meeting")

        // Once that meeting is itself current, it is offered.
        XCTAssertTrue(LiveAdjust.offer(target, now: B9.at(7200 - 100)).didntJoin)
    }
}
