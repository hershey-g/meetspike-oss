import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9, shared Swift contract: `OverrideRules`, the pure rules the phone and the Mac share with the Worker.
//
// NEW API (names fixed here, see Build9OverrideModelTests.swift for MeetingOverride):
//
//   public enum OverrideRules
//       public static func effective(start: Date, end: Date, override: MeetingOverride?) -> (start: Date, end: Date)
//       public static func excluded(_ override: MeetingOverride?) -> Bool
//       public static func suggestsNotJoined(_ override: MeetingOverride?) -> Bool
//       public static func stillGoing(currentEnd: Date, calendarEnd: Date, now: Date) -> Date?
//       public static func endedNow(start: Date, now: Date) -> Date?
//
// effective: per field, the user's time, then the time the Mac saw, then the calendar's. A candidate is used only
// when it is inside the bounds, otherwise it is ignored and the next source is tried:
//   start no more than 2 h before the calendar start, end no more than 4 h after the calendar end, end after start,
//   and end minus start at most 12 h. All limits are inclusive and in real elapsed seconds (never wall clock, so a
//   DST change inside the meeting changes nothing). With no override, or nothing usable, the calendar times come
//   back untouched (even a calendar window longer than 12 h: the calendar is the last source and is never judged).
//
// Resolutions the spec left open, pinned here:
//   - A user start that is valid but leaves no valid end (for example a start after the calendar end) is dropped
//     too, so the result is always a valid window. Which of start or end is dropped when only the PAIR is bad
//     (a 12 h + 1 s window made of a valid start and a valid end) is NOT pinned: the tests only check the bounds.
//   - stillGoing returns nil when `now` is already at or past the cap (calendar end + 4 h): another 15 minutes
//     cannot be granted for a meeting that long gone.
//   - endedNow returns nil when `now` equals the start (it must be strictly after).

final class Build9OverrideEffectiveTests: XCTestCase {
    private let calStart = B9.at(0)
    private let calEnd = B9.at(3600)

    private func effective(
        _ override: MeetingOverride?, start: TimeInterval = 0, end: TimeInterval = 3600
    ) -> (start: Date, end: Date) {
        OverrideRules.effective(start: B9.at(start), end: B9.at(end), override: override)
    }

    private func assertWindow(
        _ result: (start: Date, end: Date), _ start: TimeInterval, _ end: TimeInterval, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.start, B9.at(start), "start \(message)", file: file, line: line)
        XCTAssertEqual(result.end, B9.at(end), "end \(message)", file: file, line: line)
    }

    // MARK: Sources and order

    func testNoOverrideIsTheCalendar() {
        assertWindow(effective(nil), 0, 3600)
        assertWindow(effective(MeetingOverride()), 0, 3600)
    }

    func testAStateAloneNeverMovesTheTimes() {
        for state in [MeetingOverride.State.notJoined, .unlinked, .linked] {
            assertWindow(effective(MeetingOverride(state: state, scope: .event)), 0, 3600, "\(state)")
        }
        assertWindow(effective(MeetingOverride(seenNone: true)), 0, 3600, "seenNone alone")
    }

    func testTheUsersTimesWin() {
        let override = MeetingOverride(startUtc: B9.at(300), endUtc: B9.at(3900))
        assertWindow(effective(override), 300, 3900)
    }

    func testTheUsersStartAloneKeepsTheCalendarEnd() {
        assertWindow(effective(MeetingOverride(startUtc: B9.at(600))), 600, 3600)
    }

    func testTheUsersEndAloneKeepsTheCalendarStart() {
        assertWindow(effective(MeetingOverride(endUtc: B9.at(2700))), 0, 2700)
    }

    func testSeenTimesFillInWhenTheUserSetNothing() {
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(120), seenEndUtc: B9.at(3000))), 120, 3000)
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(120))), 120, 3600)
        assertWindow(effective(MeetingOverride(seenEndUtc: B9.at(3000))), 0, 3000)
    }

    func testTheUsersTimeBeatsSeenFieldByField() {
        let userStart = MeetingOverride(startUtc: B9.at(600), seenStartUtc: B9.at(120), seenEndUtc: B9.at(3000))
        assertWindow(effective(userStart), 600, 3000, "user start, seen end")
        let userEnd = MeetingOverride(endUtc: B9.at(2700), seenStartUtc: B9.at(120), seenEndUtc: B9.at(3000))
        assertWindow(effective(userEnd), 120, 2700, "seen start, user end")
    }

    func testTheMeetingsTitleOrStateDoNotChangeWhichTimesAreUsed() {
        // An excluded meeting still has times (the row shows them dimmed, and Undo needs them).
        let override = MeetingOverride(state: .notJoined, scope: .event, startUtc: B9.at(300), endUtc: B9.at(3000))
        assertWindow(effective(override), 300, 3000)
    }

    // MARK: Start bound: at most 2 h before the calendar start

    func testAStartTwoHoursEarlyIsAllowedAndOneSecondMoreIsNot() {
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-7200))), -7200, 3600, "exactly 2 h")
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-7200.001))), 0, 3600, "a hair past 2 h falls to the calendar")
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-7201))), 0, 3600, "1 s past 2 h")
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-86_400))), 0, 3600, "a day early")
    }

    func testAnOutOfBoundsUserStartFallsToTheSeenStartThenTheCalendar() {
        let withSeen = MeetingOverride(startUtc: B9.at(-7201), seenStartUtc: B9.at(-60))
        assertWindow(effective(withSeen), -60, 3600, "seen start used")
        let seenAlsoBad = MeetingOverride(startUtc: B9.at(-7201), seenStartUtc: B9.at(-9000))
        assertWindow(effective(seenAlsoBad), 0, 3600, "both ignored")
    }

    func testAStartAfterTheCalendarStartIsAllowed() {
        // Joined late.
        assertWindow(effective(MeetingOverride(startUtc: B9.at(1200))), 1200, 3600)
    }

    // MARK: End bound: at most 4 h after the calendar end

    func testAnEndFourHoursLateIsAllowedAndOneSecondMoreIsNot() {
        assertWindow(effective(MeetingOverride(endUtc: B9.at(3600 + 14_400))), 0, 3600 + 14_400, "exactly 4 h")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(3600 + 14_400.001))), 0, 3600, "a hair past 4 h")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(3600 + 14_401))), 0, 3600, "1 s past 4 h")
    }

    func testAnOutOfBoundsUserEndFallsToTheSeenEndThenTheCalendar() {
        let withSeen = MeetingOverride(endUtc: B9.at(3600 + 14_401), seenEndUtc: B9.at(4200))
        assertWindow(effective(withSeen), 0, 4200, "seen end used")
        let seenAlsoBad = MeetingOverride(endUtc: B9.at(3600 + 14_401), seenEndUtc: B9.at(3600 + 20_000))
        assertWindow(effective(seenAlsoBad), 0, 3600, "both ignored")
    }

    func testAnEarlyEndIsAllowedWhenItIsAfterTheStart() {
        assertWindow(effective(MeetingOverride(endUtc: B9.at(1))), 0, 1, "one second after the start")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(60))), 0, 60)
    }

    // MARK: End after start

    func testAnEndAtOrBeforeTheStartIsIgnored() {
        assertWindow(effective(MeetingOverride(endUtc: B9.at(0))), 0, 3600, "end equals start")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(-1))), 0, 3600, "end one second before start")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(-3600))), 0, 3600, "end an hour before start")
    }

    func testAnEndBeforeTheStartFallsToASeenEnd() {
        assertWindow(effective(MeetingOverride(endUtc: B9.at(-60), seenEndUtc: B9.at(3000))), 0, 3000)
    }

    func testTheEndMustBeAfterTheEffectiveStartNotJustTheCalendarStart() {
        // User start 20 minutes in, a seen end 10 minutes in: the seen end is before the start the person set.
        let override = MeetingOverride(startUtc: B9.at(1200), seenEndUtc: B9.at(600))
        let result = effective(override)
        XCTAssertEqual(result.start, B9.at(1200))
        XCTAssertGreaterThan(result.end, result.start)
        XCTAssertNotEqual(result.end, B9.at(600))
    }

    // MARK: 12 h window

    func testAWindowOfExactlyTwelveHoursIsAllowedAndOneSecondMoreIsNot() {
        // A 9 h calendar meeting (08:00 to 17:00 on the day): the end limit (21:00) is looser than the 12 h window.
        let start: TimeInterval = 0
        let end: TimeInterval = 9 * 3600
        assertWindow(effective(MeetingOverride(endUtc: B9.at(12 * 3600)), start: start, end: end), 0, 12 * 3600, "exactly 12 h")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(12 * 3600 + 1)), start: start, end: end), 0, end, "12 h and 1 s")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(13 * 3600)), start: start, end: end), 0, end, "13 h")
    }

    func testAWindowOverTwelveHoursFallsToTheNextSource() {
        let start: TimeInterval = 0
        let end: TimeInterval = 9 * 3600
        let override = MeetingOverride(endUtc: B9.at(12 * 3600 + 60), seenEndUtc: B9.at(10 * 3600))
        assertWindow(effective(override, start: start, end: end), 0, 10 * 3600)
    }

    func testAnEarlyStartAndALateEndCannotTogetherPassTwelveHours() {
        // 9 h calendar meeting. Start 2 h early (allowed) and end 4 h late (allowed) would be 15 h.
        let start: TimeInterval = 7200
        let end: TimeInterval = 7200 + 9 * 3600
        let override = MeetingOverride(startUtc: B9.at(0), endUtc: B9.at(end + 14_400))
        let result = effective(override, start: start, end: end)
        XCTAssertLessThanOrEqual(result.end.timeIntervalSince(result.start), 12 * 3600)
        XCTAssertGreaterThan(result.end, result.start)
        XCTAssertNotEqual(result.end, B9.at(end + 14_400), "the 4 h late end would make the window 15 h")
    }

    func testTheCalendarWindowIsNeverJudged() {
        // A 14 h calendar event (not a meeting, but it can come through) is returned as it is.
        assertWindow(effective(nil, start: 0, end: 14 * 3600), 0, 14 * 3600)
        assertWindow(effective(MeetingOverride(state: .linked), start: 0, end: 14 * 3600), 0, 14 * 3600)
    }

    // MARK: A start that leaves no valid end

    func testAUserStartAfterTheCalendarEndLeavesAValidWindow() {
        // Start 2 h after the calendar end, nothing else set. The calendar end is before it, so the pair is dropped.
        let result = effective(MeetingOverride(startUtc: B9.at(3600 + 7200)))
        XCTAssertGreaterThan(result.end, result.start)
        XCTAssertLessThanOrEqual(result.end, calEnd.addingTimeInterval(4 * 3600))
        XCTAssertGreaterThanOrEqual(result.start, calStart.addingTimeInterval(-2 * 3600))
    }

    // MARK: Every combination stays inside the bounds

    func testNoCombinationOfFieldsEverEscapesTheBounds() {
        // Two calendar meetings (1 h and 8 h) crossed with start and end candidates that sit on both sides of every
        // limit. Whatever the rule does with a bad value, the answer is always a window inside the bounds, and each
        // side is one of the offered values or the calendar's.
        for (calLength, label) in [(3600.0, "1 h"), (8 * 3600.0, "8 h")] {
            let startOffsets: [TimeInterval?] = [nil, -9000, -7201, -7200, -3600, 0, 600, calLength - 1, calLength, calLength + 3600]
            let endOffsets: [TimeInterval?] = [nil, -3600, 0, 1, 600, calLength, calLength + 3600, calLength + 14_400,
                                               calLength + 14_401, calLength + 20_000, 13 * 3600, 21 * 3600]
            var checked = 0
            for userStart in startOffsets {
                for userEnd in endOffsets {
                    for seenStart in startOffsets {
                        for seenEnd in endOffsets {
                            let override = MeetingOverride(
                                startUtc: userStart.map(B9.at), endUtc: userEnd.map(B9.at),
                                seenStartUtc: seenStart.map(B9.at), seenEndUtc: seenEnd.map(B9.at))
                            let result = effective(override, start: 0, end: calLength)
                            let context = "\(label): user \(String(describing: userStart))...\(String(describing: userEnd)) seen \(String(describing: seenStart))...\(String(describing: seenEnd))"
                            XCTAssertGreaterThanOrEqual(result.start, B9.at(-7200), context)
                            XCTAssertLessThanOrEqual(result.end, B9.at(calLength + 14_400), context)
                            XCTAssertGreaterThan(result.end, result.start, context)
                            XCTAssertLessThanOrEqual(result.end.timeIntervalSince(result.start), 12 * 3600, context)
                            let starts = [userStart, seenStart, 0].compactMap { $0 }.map(B9.at)
                            let ends = [userEnd, seenEnd, calLength].compactMap { $0 }.map(B9.at)
                            XCTAssertTrue(starts.contains(result.start), "start is a value that was offered: \(context)")
                            XCTAssertTrue(ends.contains(result.end), "end is a value that was offered: \(context)")
                            checked += 1
                        }
                    }
                }
            }
            XCTAssertGreaterThan(checked, 10_000)
        }
    }

    // MARK: DST and time zones

    func testTheBoundsAreRealSecondsAcrossAFallBack() {
        // 01:30 EDT to 01:30 EST in New York is one real hour. Wall clock math would see 0 h or 2 h.
        B9.inZones(B9.zones) { zone in
            let start = B9.fallBackInstant
            let end = start.addingTimeInterval(3600)
            func run(_ override: MeetingOverride) -> (start: Date, end: Date) {
                OverrideRules.effective(start: start, end: end, override: override)
            }
            XCTAssertEqual(run(MeetingOverride(startUtc: start.addingTimeInterval(-7200))).start,
                           start.addingTimeInterval(-7200), "2 h early is allowed: \(zone)")
            XCTAssertEqual(run(MeetingOverride(startUtc: start.addingTimeInterval(-7201))).start, start,
                           "2 h and 1 s early is not: \(zone)")
            XCTAssertEqual(run(MeetingOverride(endUtc: end.addingTimeInterval(14_400))).end,
                           end.addingTimeInterval(14_400), "4 h late is allowed: \(zone)")
            XCTAssertEqual(run(MeetingOverride(endUtc: end.addingTimeInterval(14_401))).end, end,
                           "4 h and 1 s late is not: \(zone)")
        }
    }

    func testTheBoundsAreRealSecondsAcrossASpringForward() {
        B9.inZones(B9.zones) { zone in
            let start = B9.springForwardInstant
            let end = start.addingTimeInterval(9 * 3600)
            func run(_ override: MeetingOverride) -> (start: Date, end: Date) {
                OverrideRules.effective(start: start, end: end, override: override)
            }
            XCTAssertEqual(run(MeetingOverride(endUtc: start.addingTimeInterval(12 * 3600))).end,
                           start.addingTimeInterval(12 * 3600), "a 12 h window across the jump: \(zone)")
            XCTAssertEqual(run(MeetingOverride(endUtc: start.addingTimeInterval(12 * 3600 + 1))).end, end,
                           "12 h and 1 s: \(zone)")
            XCTAssertEqual(run(MeetingOverride(startUtc: start.addingTimeInterval(-7200))).start,
                           start.addingTimeInterval(-7200), zone)
        }
    }

    func testTheSameInstantsGiveTheSameAnswerInEveryZone() {
        var answers: [String: [TimeInterval]] = [:]
        B9.inZones(B9.zones) { zone in
            let override = MeetingOverride(startUtc: B9.at(-600), endUtc: B9.at(4000), seenStartUtc: B9.at(60))
            let result = OverrideRules.effective(start: B9.at(0), end: B9.at(3600), override: override)
            answers[zone] = [result.start.timeIntervalSince1970, result.end.timeIntervalSince1970]
        }
        XCTAssertEqual(Set(answers.values.map { $0.map { Int($0) } }).count, 1, "\(answers)")
    }
}

// MARK: excluded, suggestsNotJoined

final class Build9OverrideStateTests: XCTestCase {
    func testNotJoinedAndUnlinkedAreExcluded() {
        XCTAssertTrue(OverrideRules.excluded(MeetingOverride(state: .notJoined, scope: .event)))
        XCTAssertTrue(OverrideRules.excluded(MeetingOverride(state: .unlinked, scope: .event)))
        XCTAssertTrue(OverrideRules.excluded(MeetingOverride(state: .notJoined, scope: .series)))
        XCTAssertTrue(OverrideRules.excluded(MeetingOverride(state: .unlinked, scope: .series)))
        XCTAssertTrue(OverrideRules.excluded(MeetingOverride(state: .notJoined)), "scope does not matter")
    }

    func testLinkedAndNoStateAreNotExcluded() {
        XCTAssertFalse(OverrideRules.excluded(nil))
        XCTAssertFalse(OverrideRules.excluded(MeetingOverride()))
        XCTAssertFalse(OverrideRules.excluded(MeetingOverride(state: .linked, scope: .event)),
                       "linked on an event opts it out of a series rule")
        XCTAssertFalse(OverrideRules.excluded(MeetingOverride(state: .linked, scope: .series)))
    }

    func testTimesAndSeenNoneAloneDoNotExclude() {
        XCTAssertFalse(OverrideRules.excluded(MeetingOverride(startUtc: B9.at(0), endUtc: B9.at(60))))
        XCTAssertFalse(OverrideRules.excluded(MeetingOverride(seenNone: true)))
        XCTAssertFalse(OverrideRules.excluded(MeetingOverride(seenStartUtc: B9.at(0), seenEndUtc: B9.at(60))))
    }

    func testSeenNoneWithNoStateSuggestsNotJoined() {
        XCTAssertTrue(OverrideRules.suggestsNotJoined(MeetingOverride(seenNone: true)))
        XCTAssertTrue(OverrideRules.suggestsNotJoined(MeetingOverride(scope: nil, seenNone: true, seriesId: "s")))
    }

    func testNothingSeenOrNoOverrideSuggestsNothing() {
        XCTAssertFalse(OverrideRules.suggestsNotJoined(nil))
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride()))
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride(seenNone: false)))
    }

    func testAnAnswerSilencesTheSuggestion() {
        // "No" on the note saves state linked: the note must not come back.
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride(state: .linked, scope: .event, seenNone: true)))
        // Already excluded: there is nothing left to suggest.
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride(state: .notJoined, scope: .event, seenNone: true)))
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride(state: .unlinked, scope: .series, seenNone: true)))
    }

    func testASeriesLinkedAnswerAlsoSilencesIt() {
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride(state: .linked, scope: .series, seenNone: true)))
    }
}

// MARK: Still going and Ended now

final class Build9StillGoingTests: XCTestCase {
    private let calendarEnd = B9.at(3600)
    private var cap: Date { calendarEnd.addingTimeInterval(4 * 3600) }
    private let quarter: TimeInterval = 15 * 60

    func testAddsFifteenMinutesToTheCurrentEndWhileTheMeetingIsRunning() {
        let now = B9.at(3000)
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: calendarEnd, calendarEnd: calendarEnd, now: now),
                       calendarEnd.addingTimeInterval(quarter))
    }

    func testAddsFifteenMinutesFromNowWhenTheMeetingAlreadyRanOver() {
        // The calendar said 15:00. It is 15:10. The end becomes 15:25, not 15:15.
        let now = calendarEnd.addingTimeInterval(600)
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: calendarEnd, calendarEnd: calendarEnd, now: now),
                       now.addingTimeInterval(quarter))
    }

    func testAnEndInTheFutureIsExtendedFromTheEndNotFromNow() {
        let current = calendarEnd.addingTimeInterval(1800)
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: current, calendarEnd: calendarEnd, now: B9.at(3000)),
                       current.addingTimeInterval(quarter))
    }

    func testNowExactlyAtTheCurrentEndAddsFifteenMinutes() {
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: calendarEnd, calendarEnd: calendarEnd, now: calendarEnd),
                       calendarEnd.addingTimeInterval(quarter))
    }

    func testTheResultIsAlwaysLaterThanTheCurrentEnd() throws {
        for current in stride(from: 0.0, to: 14_400, by: 900) {
            let end = calendarEnd.addingTimeInterval(current)
            let next = try XCTUnwrap(OverrideRules.stillGoing(currentEnd: end, calendarEnd: calendarEnd, now: end), "\(current)")
            XCTAssertGreaterThan(next, end)
        }
    }

    func testNeverPastFourHoursAfterTheCalendarEnd() throws {
        // Five minutes below the cap: the answer is the cap itself, not 10 minutes beyond it.
        let almost = cap.addingTimeInterval(-300)
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: almost, calendarEnd: calendarEnd, now: almost), cap)
        // One second below.
        let hair = cap.addingTimeInterval(-1)
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: hair, calendarEnd: calendarEnd, now: hair), cap)
        // A full step below lands exactly on the cap.
        let step = cap.addingTimeInterval(-quarter)
        XCTAssertEqual(OverrideRules.stillGoing(currentEnd: step, calendarEnd: calendarEnd, now: step), cap)
    }

    func testAtTheCapThereIsNothingLeftToAdd() {
        XCTAssertNil(OverrideRules.stillGoing(currentEnd: cap, calendarEnd: calendarEnd, now: cap.addingTimeInterval(-60)))
        XCTAssertNil(OverrideRules.stillGoing(currentEnd: cap, calendarEnd: calendarEnd, now: B9.at(3000)))
        XCTAssertNil(OverrideRules.stillGoing(currentEnd: cap.addingTimeInterval(1), calendarEnd: calendarEnd, now: B9.at(3000)),
                     "an end already past the cap")
    }

    func testNowPastTheCapGrantsNothing() {
        // Pinned resolution: the cap has passed in real time, so "still going" cannot move the end anywhere useful.
        XCTAssertNil(OverrideRules.stillGoing(currentEnd: calendarEnd, calendarEnd: calendarEnd, now: cap))
        XCTAssertNil(OverrideRules.stillGoing(currentEnd: calendarEnd, calendarEnd: calendarEnd, now: cap.addingTimeInterval(3600)))
    }

    func testSixteenTapsReachTheCapAndTheSeventeenthIsRefused() throws {
        var end = calendarEnd
        var taps = 0
        while let next = OverrideRules.stillGoing(currentEnd: end, calendarEnd: calendarEnd, now: B9.at(3000)) {
            XCTAssertGreaterThan(next, end)
            end = next
            taps += 1
            XCTAssertLessThan(taps, 100, "never ends")
        }
        XCTAssertEqual(taps, 16, "4 h in 15 minute steps")
        XCTAssertEqual(end, cap)
    }

    func testTheCapFollowsTheCalendarEndNotTheCurrentEnd() throws {
        // Another meeting: calendar end at +10 h. Its cap is +14 h, whatever the other one's was.
        let otherEnd = B9.at(10 * 3600)
        let next = try XCTUnwrap(OverrideRules.stillGoing(currentEnd: otherEnd, calendarEnd: otherEnd, now: otherEnd))
        XCTAssertEqual(next, otherEnd.addingTimeInterval(quarter))
        XCTAssertNil(OverrideRules.stillGoing(currentEnd: otherEnd.addingTimeInterval(4 * 3600), calendarEnd: otherEnd, now: otherEnd))
    }

    func testTheCapIsRealTimeAcrossAFallBack() {
        B9.inZones(B9.zones) { zone in
            let end = B9.fallBackInstant.addingTimeInterval(3600)
            let limit = end.addingTimeInterval(4 * 3600)
            XCTAssertEqual(OverrideRules.stillGoing(currentEnd: limit.addingTimeInterval(-60), calendarEnd: end, now: end), limit, zone)
            XCTAssertNil(OverrideRules.stillGoing(currentEnd: limit, calendarEnd: end, now: end), zone)
        }
    }
}

final class Build9EndedNowTests: XCTestCase {
    func testEndedNowIsNowOnceTheMeetingHasStarted() {
        XCTAssertEqual(OverrideRules.endedNow(start: B9.at(0), now: B9.at(1500)), B9.at(1500))
        XCTAssertEqual(OverrideRules.endedNow(start: B9.at(0), now: B9.at(1)), B9.at(1))
        XCTAssertEqual(OverrideRules.endedNow(start: B9.at(0), now: B9.at(0.001)), B9.at(0.001))
    }

    func testEndedNowBeforeTheStartIsRefused() {
        XCTAssertNil(OverrideRules.endedNow(start: B9.at(0), now: B9.at(-1)))
        XCTAssertNil(OverrideRules.endedNow(start: B9.at(0), now: B9.at(-0.001)))
        XCTAssertNil(OverrideRules.endedNow(start: B9.at(3600), now: B9.at(0)), "a meeting an hour away")
    }

    func testEndedNowAtTheStartIsRefusedBecauseTheEndMustBeAfterIt() {
        XCTAssertNil(OverrideRules.endedNow(start: B9.at(0), now: B9.at(0)))
    }

    func testTheAnswerIsAlwaysAfterTheStart() throws {
        for offset in stride(from: 1.0, through: 7200, by: 599) {
            let end = try XCTUnwrap(OverrideRules.endedNow(start: B9.at(0), now: B9.at(offset)))
            XCTAssertGreaterThan(end, B9.at(0))
        }
    }
}
