import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 follow-up, the one fix pass (fix9c.md). The Swift halves.
//   H2  OverrideRules.effective counts a seen value only inside [calendar start - 15 min, calendar end + 4 h], both
//       inclusive, like effectiveTimes in src/lib/meeting-override.ts. Fixtures/override-parity.json was regenerated
//       from the Worker (test/fixtures/gen-override-parity.mjs) with cases around the new limits; the existing
//       Build9HelpersParityTests.testEffectiveTimesAgreeWithTheWorkerOnEveryCase checks every one of them.
//   H5  AttendanceReportDelivery.verdict: every 3xx is .later.
// The server halves (H1, H3, H4, H6, H7) are in test/override-followup-fix.test.ts.

// MARK: - H2

final class Build9FollowupFixH2Tests: XCTestCase {
    /// Calendar 14:00 to 15:00 (seconds 0 to 3600 from B9.base).
    private func effective(_ override: MeetingOverride, calendarStart: TimeInterval = 0, calendarEnd: TimeInterval = 3600)
        -> (start: Date, end: Date) {
        OverrideRules.effective(start: B9.at(calendarStart), end: B9.at(calendarEnd), override: override)
    }

    private func assertWindow(_ got: (start: Date, end: Date), _ start: TimeInterval, _ end: TimeInterval,
                              _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.start, B9.at(start), "start \(message)", file: file, line: line)
        XCTAssertEqual(got.end, B9.at(end), "end \(message)", file: file, line: line)
    }

    func testASeenStartCountsFromExactlyFifteenMinutesBeforeTheCalendarStart() {
        // 15 min 1 s early is out, 15 min exactly is in, 14 min 59 s is in. The Worker says the same.
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(-901), seenEndUtc: B9.at(3000))), 0, 3000, "15:01 early")
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(-900), seenEndUtc: B9.at(3000))), -900, 3000, "15:00 early")
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(-899), seenEndUtc: B9.at(3000))), -899, 3000, "14:59 early")
    }

    func testTheSeenStartLimitIsInclusiveToTheMillisecond() {
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(-900.001), seenEndUtc: B9.at(3000))), 0, 3000, "1 ms past")
    }

    func testASeenStartTwoHoursEarlyIsNoLongerUsed() {
        // The old limit was 2 h. A seen start 1 h early used to count.
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(-3600), seenEndUtc: B9.at(3000))), 0, 3000, "1 h early")
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(-7200), seenEndUtc: B9.at(3000))), 0, 3000, "2 h early")
    }

    func testASeenEndCountsUpToFourHoursAfterTheCalendarEndInclusive() {
        let limit: TimeInterval = 3600 + 4 * 3600
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(300), seenEndUtc: B9.at(limit))), 300, limit, "end + 4 h")
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(300), seenEndUtc: B9.at(limit - 1))), 300, limit - 1, "end + 4 h - 1 s")
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(300), seenEndUtc: B9.at(limit + 0.001))), 300, 3600, "1 ms past")
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(300), seenEndUtc: B9.at(limit + 1))), 300, 3600, "1 s past")
    }

    func testTheReviewsCaseTheCalendarMovedAndTheSightingIsFromTheOldTime() {
        // Calendar moved to 16:00 to 17:00 (7200 to 10800). The Mac saw 15:02 to 15:55 for the old time.
        let override = MeetingOverride(seenStartUtc: B9.at(3720), seenEndUtc: B9.at(6900))
        assertWindow(effective(override, calendarStart: 7200, calendarEnd: 10_800), 7200, 10_800, "the real meeting keeps its window")
    }

    func testASightingInsideTheLimitsStillCounts() {
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(120), seenEndUtc: B9.at(3300))), 120, 3300)
        assertWindow(effective(MeetingOverride(seenEndUtc: B9.at(1200))), 0, 1200, "seen end alone")
    }

    func testTheOwnersOwnTimesKeepTheOldLimits() {
        // The owner may start up to 2 h early and end up to 4 h late, whatever the Mac saw.
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-7200))), -7200, 3600, "2 h early")
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-7201))), 0, 3600, "2 h and 1 s early")
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-3600), seenStartUtc: B9.at(-60))), -3600, 3600, "own start beats a seen one")
        let late: TimeInterval = 3600 + 4 * 3600
        assertWindow(effective(MeetingOverride(endUtc: B9.at(late))), 0, late, "4 h late")
        assertWindow(effective(MeetingOverride(endUtc: B9.at(late + 1))), 0, 3600, "4 h and 1 s late")
    }

    func testAnOwnStartIsUsedEvenWhenTheSeenOneAroundItIsOutOfRange() {
        let override = MeetingOverride(startUtc: B9.at(-1800), seenStartUtc: B9.at(-1200), seenEndUtc: B9.at(3600 + 5 * 3600))
        assertWindow(effective(override), -1800, 3600)
    }

    // The Worker's seenTimeFits checks both bounds for both seen values. The two tests below cover the other side of
    // the window for each value. Expected answers are what effectiveTimes in src/lib/meeting-override.ts returns.

    func testASeenEndBeforeFifteenMinutesBeforeTheCalendarStartIsIgnored() {
        // Owner start 2 h early (-7200), calendar 0 to 3600. A seen end below -900 would pair with the owner's start
        // (a window that ends before the meeting starts); the Worker ignores it and ends at the calendar end.
        func window(_ seenEnd: TimeInterval) -> (start: Date, end: Date) {
            effective(MeetingOverride(startUtc: B9.at(-7200), seenEndUtc: B9.at(seenEnd)))
        }
        assertWindow(window(-1800), -7200, 3600, "seen end 30 min before the calendar start")
        assertWindow(window(-3600), -7200, 3600, "seen end 1 h before")
        assertWindow(window(-901), -7200, 3600, "15:01 before")
        assertWindow(window(-900.001), -7200, 3600, "15:00 and 1 ms before")
        assertWindow(window(-900), -7200, -900, "exactly 15:00 before is used")
        assertWindow(window(-899), -7200, -899, "14:59 before is used")
        // With a seen start too, the pair (seen start, seen end) needs both to fit.
        assertWindow(effective(MeetingOverride(startUtc: B9.at(-7200), seenStartUtc: B9.at(-900), seenEndUtc: B9.at(-1800))),
                     -7200, 3600, "a seen end before the limit is ignored even next to a valid seen start")
    }

    func testASeenStartAfterFourHoursPastTheCalendarEndIsIgnored() {
        // Past the limit nothing can end after a seen start (an end is at most calendar end + 4 h), so the answer is
        // the owner's end or the calendar. The Worker agrees on every one of these (see the fixture).
        let limit: TimeInterval = 3600 + 4 * 3600
        for offset in [0, 0.001, 1, 6 * 3600] as [TimeInterval] {
            let seenStart = limit + offset
            assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(seenStart))), 0, 3600, "seen start alone at limit + \(offset)")
            assertWindow(effective(MeetingOverride(endUtc: B9.at(limit), seenStartUtc: B9.at(seenStart))), 0, limit,
                         "owner end at +4 h and a seen start at limit + \(offset)")
            assertWindow(effective(MeetingOverride(startUtc: B9.at(-3600), seenStartUtc: B9.at(seenStart))), -3600, 3600,
                         "owner start and a seen start at limit + \(offset)")
        }
        // One second inside the limit the seen start fits, and pairs with the owner's end at the limit.
        assertWindow(effective(MeetingOverride(endUtc: B9.at(limit), seenStartUtc: B9.at(limit - 1))), limit - 1, limit, "1 s inside")
        // Past the calendar end but inside the limit it is a valid seen start; with a later seen end it is used.
        assertWindow(effective(MeetingOverride(seenStartUtc: B9.at(4200), seenEndUtc: B9.at(6600))), 4200, 6600, "inside the limit")
    }

    func testTheRegeneratedFixtureHasTheCasesAroundTheNewLimits() throws {
        struct Table: Decodable {
            struct Case: Decodable {
                struct Times: Decodable { var startUtc: String?; var endUtc: String?; var seenStartUtc: String?; var seenEndUtc: String? }
                var cal: Times
                var chosen: Times
                var expect: Times
            }
            var generatedBy: String
            var effective: [Case]
        }
        let table = try JSONDecoder().decode(Table.self, from: APIFixture.data("override-parity.json"))
        XCTAssertTrue(table.generatedBy.contains("15 min"), "generatedBy says which Worker rule produced the answers")
        func seconds(_ text: String?) -> TimeInterval? { APITime.parse(text)?.timeIntervalSince1970 }
        let limits = table.effective.filter { row in
            guard let calStart = seconds(row.cal.startUtc), let seen = seconds(row.chosen.seenStartUtc) else { return false }
            return abs(seen - (calStart - 900)) <= 1.001
        }
        // 14:59, 15:00 and 15:01 minutes before (and a millisecond either side), alone and with seen ends.
        XCTAssertGreaterThanOrEqual(limits.count, 12, "cases around the 15 minute limit")
        XCTAssertTrue(limits.contains { seconds($0.chosen.seenStartUtc) == (seconds($0.cal.startUtc) ?? 0) - 900 && $0.expect.startUtc == $0.chosen.seenStartUtc },
                      "a case where exactly 15 minutes early is used")
        XCTAssertTrue(limits.contains { (seconds($0.chosen.seenStartUtc) ?? 0) < (seconds($0.cal.startUtc) ?? 0) - 900 && $0.expect.startUtc == $0.cal.startUtc },
                      "a case where earlier than 15 minutes is ignored")
        let ends = table.effective.filter { row in
            guard let calEnd = seconds(row.cal.endUtc), let seen = seconds(row.chosen.seenEndUtc) else { return false }
            return abs(seen - (calEnd + 4 * 3600)) <= 1.001
        }
        XCTAssertGreaterThanOrEqual(ends.count, 8, "cases around the 4 hour limit")
        XCTAssertTrue(ends.contains { $0.expect.endUtc == $0.chosen.seenEndUtc }, "a case where the limit itself is used")
        XCTAssertTrue(ends.contains { (seconds($0.chosen.seenEndUtc) ?? 0) > (seconds($0.cal.endUtc) ?? 0) + 4 * 3600 && $0.expect.endUtc != $0.chosen.seenEndUtc },
                      "a case where past the limit is ignored")
    }
}

// MARK: - H5

final class Build9FollowupFixH5Tests: XCTestCase {
    private func verdict(_ status: Int?) -> AttendanceReportDelivery.Verdict { AttendanceReportDelivery.verdict(status: status) }

    func testEveryRedirectKeepsTheReportForLater() {
        // 301 and 308 included: a Mac still pointed at the old host gets a 301 from the domain move, and the queued
        // report must survive it.
        for status in 300...399 { XCTAssertEqual(verdict(status), .later, "\(status)") }
    }

    func testTheOtherClientErrorsStayDropped() {
        for status in [400, 404, 405, 410, 413, 415, 418, 422, 451, 499] { XCTAssertEqual(verdict(status), .drop, "\(status)") }
    }

    func testTheRestIsUnchanged() {
        for status in [200, 202, 204, 299] { XCTAssertEqual(verdict(status), .done, "\(status)") }
        for status in [401, 403, 503] { XCTAssertEqual(verdict(status), .later, "\(status)") }
        for status in [408, 425, 429, 500, 502, 599] { XCTAssertEqual(verdict(status), .retry, "\(status)") }
        XCTAssertEqual(verdict(nil), .retry)
    }
}
