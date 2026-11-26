import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 iPhone spec: "Live: while in a window, the Live card and Lock Screen Live Activity get 'Still going' (adds 15
// min each tap, up to 4 h past the calendar end) and 'Ended now'." Shared contract: stillGoing = max(currentEnd, now) +
// 15 min, capped at calendarEnd + 4 h, nil at the cap. endedNow = now when after the start, else nil. A window runs from
// 2 minutes before the start to 10 minutes after the end (the cooldown).
//
// Written from the spec, after the code. Pure: LiveAdjust, OverrideRules.stillGoing / endedNow.

final class Build9HelpersLiveAdjustTests: XCTestCase {
    /// Fix pass F1 added `didntJoin` to `Offer`, true for a different window (see Build9FixF1DidntJoinTests). These
    /// tests are about the Still going and Ended now buttons, so they compare those two flags only.
    private struct Flags: Equatable { var stillGoing: Bool; var endedNow: Bool }
    private func offer(_ target: LiveAdjustTarget?, _ now: Date) -> Flags {
        let offer = LiveAdjust.offer(target, now: now)
        return Flags(stillGoing: offer.stillGoing, endedNow: offer.endedNow)
    }
    private let off = Flags(stillGoing: false, endedNow: false)

    private let min15: TimeInterval = 900
    private let cap: TimeInterval = 3600 + 4 * 3600

    /// A meeting 0 to 3600 s on the calendar, as the phone is using it unless `end` says otherwise.
    private func target(end: TimeInterval = 3600, start: TimeInterval = 0) -> LiveAdjustTarget {
        LiveAdjustTarget(meetingID: "ev1", title: "Standup", start: B9.at(start), end: B9.at(end), calendarEnd: B9.at(3600))
    }

    private func endOf(_ edit: OverrideEdit?) -> Date? {
        guard let edit, case .set(let date) = edit.endUtc else { return nil }
        return date
    }

    // MARK: Still going

    func testStillGoingAddsFifteenMinutesToTheEnd() throws {
        let edit = try XCTUnwrap(LiveAdjust.stillGoing(target(), now: B9.at(3000)))
        XCTAssertEqual(edit.scope, .event)
        XCTAssertEqual(edit.endUtc, .set(B9.at(3600 + 900)))
        XCTAssertEqual(edit.startUtc, .unchanged)
        XCTAssertEqual(edit.state, .unchanged, "never changes whether you joined")
    }

    func testStillGoingAfterTheEndAddsFifteenMinutesToNow() {
        // In the cooldown the meeting already ran over: 15 minutes from now, not from the old end.
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(target(), now: B9.at(3600 + 300))), B9.at(3600 + 300 + 900))
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(target(), now: B9.at(3600))), B9.at(3600 + 900))
    }

    func testEachTapAddsAnotherFifteenMinutesUntilFourHoursPastTheCalendarEnd() {
        var current = target()
        let now = B9.at(1800)
        var taps = 0
        while let next = endOf(LiveAdjust.stillGoing(current, now: now)) {
            taps += 1
            XCTAssertEqual(next, current.end.addingTimeInterval(900), "tap \(taps)")
            current.end = next
            if taps > 100 { return XCTFail("never stops") }
        }
        XCTAssertEqual(taps, 16, "4 h in steps of 15 min")
        XCTAssertEqual(current.end, B9.at(cap))
        XCTAssertNil(LiveAdjust.stillGoing(current, now: now), "nil at the cap")
    }

    func testStillGoingNeverGoesPastTheCap() {
        // 10 minutes of room left: a full 15 minute step is cut at the cap.
        let nearCap = target(end: cap - 600)
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(nearCap, now: B9.at(1800))), B9.at(cap))
        // One second of room left.
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(target(end: cap - 1), now: B9.at(1800))), B9.at(cap))
        // At the cap, and past it.
        XCTAssertNil(LiveAdjust.stillGoing(target(end: cap), now: B9.at(1800)))
        XCTAssertNil(LiveAdjust.stillGoing(target(end: cap + 600), now: B9.at(1800)))
    }

    func testStillGoingIsGoneWhenNowIsAlreadyAtTheCap() {
        // The meeting ran so long ago that another 15 minutes cannot be granted.
        XCTAssertNil(LiveAdjust.stillGoing(target(), now: B9.at(cap)))
        XCTAssertNil(LiveAdjust.stillGoing(target(), now: B9.at(cap + 3600)))
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(target(), now: B9.at(cap - 1))), B9.at(cap))
    }

    func testTheCapCountsFromTheCalendarEndNotTheMovedEnd() {
        // The person already moved the end 1 h later: the cap is still 4 h after the calendar's end.
        let moved = LiveAdjustTarget(meetingID: "e", title: "x", start: B9.at(0), end: B9.at(7200), calendarEnd: B9.at(3600))
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(moved, now: B9.at(3000))), B9.at(7200 + 900))
        let late = LiveAdjustTarget(meetingID: "e", title: "x", start: B9.at(0), end: B9.at(cap - 300), calendarEnd: B9.at(3600))
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(late, now: B9.at(3000))), B9.at(cap))
    }

    func testStillGoingSharedRuleMatchesTheEditAndKeepsTheFiftenMinuteStep() {
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: B9.at(3600), calendarEnd: B9.at(3600), now: B9.at(100)), B9.at(4500))
        XCTAssertEqual(OverrideRules.stillGoingStep, 900)
        XCTAssertEqual(OverrideRules.maxLateEnd, 4 * 3600)
    }

    // MARK: Ended now

    func testEndedNowSetsTheEndToNow() throws {
        let edit = try XCTUnwrap(LiveAdjust.endedNow(target(), now: B9.at(1500)))
        XCTAssertEqual(edit.scope, .event)
        XCTAssertEqual(edit.endUtc, .set(B9.at(1500)))
        XCTAssertEqual(edit.startUtc, .unchanged)
        XCTAssertEqual(edit.state, .unchanged)
        XCTAssertEqual(try H9.wire(edit)["endUtc"] as? String, B9.iso(1500))
    }

    func testEndedNowNeedsNowAfterTheStart() {
        XCTAssertNil(LiveAdjust.endedNow(target(), now: B9.at(0)), "the end must be after the start")
        XCTAssertNil(LiveAdjust.endedNow(target(), now: B9.at(-60)), "not started yet")
        XCTAssertEqual(endOf(LiveAdjust.endedNow(target(), now: B9.at(1))), B9.at(1))
        // Against the start the phone uses now, which can be a moved start.
        XCTAssertNil(LiveAdjust.endedNow(target(start: 600), now: B9.at(300)))
        XCTAssertEqual(endOf(LiveAdjust.endedNow(target(start: 600), now: B9.at(900))), B9.at(900))
        XCTAssertNil(OverrideRules.endedNow(start: B9.at(5), now: B9.at(5)))
        XCTAssertEqual(OverrideRules.endedNow(start: B9.at(5), now: B9.at(6)), B9.at(6))
    }

    // MARK: What the Live card and the Live Activity offer

    func testNothingIsOfferedWithoutATarget() {
        XCTAssertEqual(offer(nil, B9.at(900)), off)
        XCTAssertFalse(LiveAdjust.Offer.none.stillGoing)
        XCTAssertFalse(LiveAdjust.Offer.none.endedNow)
    }

    func testBeforeTheStartNothingIsOffered() {
        XCTAssertEqual(offer(target(), B9.at(-1)), off)
        XCTAssertEqual(offer(target(), B9.at(-120)), off, "the two minute lead is not the meeting yet")
    }

    func testWhileTheMeetingRunsBothAreOffered() {
        XCTAssertEqual(offer(target(), B9.at(1)), Flags(stillGoing: true, endedNow: true))
        XCTAssertEqual(offer(target(), B9.at(1800)), Flags(stillGoing: true, endedNow: true))
        XCTAssertEqual(offer(target(), B9.at(3599)), Flags(stillGoing: true, endedNow: true))
    }

    func testAtTheExactStartThereIsNothingToEndYet() {
        // Ended now needs now after the start, so it waits one tick; Still going is fine.
        XCTAssertEqual(offer(target(), B9.at(0)), Flags(stillGoing: true, endedNow: false))
    }

    func testInTheCooldownOnlyStillGoingIsOffered() {
        XCTAssertEqual(offer(target(), B9.at(3600)), Flags(stillGoing: true, endedNow: false))
        XCTAssertEqual(offer(target(), B9.at(3600 + 599)), Flags(stillGoing: true, endedNow: false))
    }

    /// Spec: "while in a window". The window ends 10 minutes after the end, so a meeting that ended an hour ago does
    /// not get a "Still going" button. A judgement call on the wording; see the report.
    func testAfterTheCooldownNothingIsOffered() {
        XCTAssertEqual(offer(target(), B9.at(3600 + 600)), off)
        XCTAssertEqual(offer(target(), B9.at(3600 + 3 * 3600)), off)
    }

    func testAtTheCapStillGoingIsGoneButEndedNowRemains() {
        let capped = target(end: cap)
        XCTAssertEqual(offer(capped, B9.at(3000)), Flags(stillGoing: false, endedNow: true))
        XCTAssertEqual(offer(capped, B9.at(cap)), off)
    }

    func testOfferFollowsTheMovedEndNotTheCalendarsEnd() {
        let moved = target(end: 7200)
        XCTAssertEqual(offer(moved, B9.at(5400)), Flags(stillGoing: true, endedNow: true), "still running at 90 min")
        XCTAssertEqual(offer(moved, B9.at(7200 + 100)), Flags(stillGoing: true, endedNow: false))
    }

    // MARK: A row from the Worker as the target

    func testARowBecomesATargetWithTheTimesTheWorkerGave() throws {
        let override = MeetingOverride(calendarStartUtc: B9.at(0), calendarEndUtc: B9.at(3600))
        let target = try XCTUnwrap(LiveAdjust.target(
            meetingID: "ev1", title: "Standup", startUtc: B9.iso(0), endUtc: B9.iso(3600), override: override))
        XCTAssertEqual(target.meetingID, "ev1")
        XCTAssertEqual(target.title, "Standup")
        XCTAssertEqual(target.start, B9.at(0))
        XCTAssertEqual(target.end, B9.at(3600))
        XCTAssertEqual(target.calendarEnd, B9.at(3600))
        XCTAssertEqual(LiveAdjust.target(meetingID: "x", title: nil, startUtc: B9.iso(0), endUtc: B9.iso(60), override: nil)?.title, "")
    }

    func testARowWithNoOverrideIsTheCalendarItself() throws {
        let target = try XCTUnwrap(LiveAdjust.target(
            meetingID: "ev1", title: "Standup", startUtc: B9.iso(0), endUtc: B9.iso(3600), override: nil))
        XCTAssertEqual(target.calendarEnd, B9.at(3600))
        XCTAssertEqual(target.end, B9.at(3600))
    }

    func testARowCannotBeATargetWithoutTimesOrWhenLeftOut() {
        XCTAssertNil(LiveAdjust.target(meetingID: "e", title: "x", startUtc: nil, endUtc: B9.iso(60), override: nil))
        XCTAssertNil(LiveAdjust.target(meetingID: "e", title: "x", startUtc: B9.iso(0), endUtc: nil, override: nil))
        XCTAssertNil(LiveAdjust.target(meetingID: "e", title: "x", startUtc: "soon", endUtc: "later", override: nil))
        XCTAssertNil(LiveAdjust.target(meetingID: "e", title: "x", startUtc: B9.iso(60), endUtc: B9.iso(60), override: nil), "zero length")
        for state in [MeetingOverride.State.notJoined, .unlinked] {
            XCTAssertNil(
                LiveAdjust.target(
                    meetingID: "e", title: "x", startUtc: B9.iso(0), endUtc: B9.iso(60),
                    override: MeetingOverride(state: state, scope: .event)), "\(state): nothing is live for a meeting left out")
        }
        XCTAssertNotNil(LiveAdjust.target(
            meetingID: "e", title: "x", startUtc: B9.iso(0), endUtc: B9.iso(60),
            override: MeetingOverride(state: .linked, scope: .event)))
    }

    func testASecondTapAddsToTheFirstThatIsStillWaiting() throws {
        // First tap at 3000 s: the end 3600 s becomes 4500 s, queued because the phone was offline.
        let row = try H9.row("ev1", start: 0, end: 3600)
        let first = try XCTUnwrap(LiveAdjust.target(
            meetingID: "ev1", title: "Standup", startUtc: row.startUtc, endUtc: row.endUtc, override: row.override))
        let firstEdit = try XCTUnwrap(LiveAdjust.stillGoing(first, now: B9.at(3000)))
        XCTAssertEqual(endOf(firstEdit), B9.at(4500))

        // The row now carries the waiting edit.
        let waiting = [H9.item("ev1", firstEdit, queued: 3000)]
        let overlaid = OverrideOverlay.apply(waiting, to: [row])[0]
        let second = try XCTUnwrap(LiveAdjust.target(
            meetingID: "ev1", title: "Standup", startUtc: overlaid.startUtc, endUtc: overlaid.endUtc, override: overlaid.override))
        XCTAssertEqual(second.end, B9.at(4500), "reads through the waiting edit")
        XCTAssertEqual(second.calendarEnd, B9.at(3600), "the cap still counts from the calendar")
        XCTAssertEqual(endOf(LiveAdjust.stillGoing(second, now: B9.at(3100))), B9.at(5400))
    }

    func testTheOfferForARowFollowsTheTimesTheWorkerAlreadyApplied() throws {
        // The Worker has the end moved to 5400 s; the row's own times are the moved ones, the override has the calendar's.
        let override = MeetingOverride(endUtc: B9.at(5400), calendarStartUtc: B9.at(0), calendarEndUtc: B9.at(3600))
        let target = try XCTUnwrap(LiveAdjust.target(
            meetingID: "ev1", title: "Standup", startUtc: B9.iso(0), endUtc: B9.iso(5400), override: override))
        XCTAssertEqual(target.end, B9.at(5400))
        XCTAssertEqual(target.calendarEnd, B9.at(3600))
        XCTAssertEqual(offer(target, B9.at(4000)), Flags(stillGoing: true, endedNow: true))
    }
}
