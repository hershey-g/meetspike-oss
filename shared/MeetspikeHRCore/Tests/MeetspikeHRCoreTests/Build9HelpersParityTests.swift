import Foundation
import XCTest
@testable import MeetspikeHRCore

// Parity with the Worker. The spec says the Swift rules have "the same bounds as the server" and the phone, the Mac and
// the Worker must agree on what a meeting's real times are. Fixtures/override-parity.json holds a table of cases and
// the answers `effectiveTimes` and `seriesIdOf` in src/lib/meeting-override.ts gave for them. They were generated with
// `node --experimental-strip-types` (the command is in the file's "generatedBy"). Nothing here is computed in Swift.
//
//   effective: 324 grid cases around every limit (2 h early start, 4 h late end, 12 h window, inverted and equal
//   pairs, all four sources present or missing) plus 220 seeded random cases, including zero length calendars.
//   seriesIds: ids with and without the _YYYYMMDD / _YYYYMMDDTHHMMSSZ suffix, and odd ones.

final class Build9HelpersParityTests: XCTestCase {
    private struct Table: Decodable {
        struct Case: Decodable {
            struct Calendar: Decodable { var startUtc: String; var endUtc: String }
            struct Chosen: Decodable { var startUtc: String?; var endUtc: String?; var seenStartUtc: String?; var seenEndUtc: String? }
            var cal: Calendar
            var chosen: Chosen
            var expect: Calendar
        }
        struct Series: Decodable { var id: String; var seriesId: String? }
        var generatedBy: String
        var effective: [Case]
        var seriesIds: [Series]
    }

    private func table() throws -> Table {
        try JSONDecoder().decode(Table.self, from: APIFixture.data("override-parity.json"))
    }

    func testTheTableIsBigEnoughToMeanSomething() throws {
        let table = try table()
        XCTAssertGreaterThanOrEqual(table.effective.count, 500)
        XCTAssertTrue(table.generatedBy.contains("src/lib/meeting-override.ts"))
        let moved = table.effective.filter { $0.expect.startUtc != $0.cal.startUtc || $0.expect.endUtc != $0.cal.endUtc }
        XCTAssertGreaterThan(moved.count, 100, "the table must have cases where the answer is not the calendar")
        XCTAssertGreaterThan(table.effective.count - moved.count, 20, "and cases where it is")
    }

    func testEffectiveTimesAgreeWithTheWorkerOnEveryCase() throws {
        let table = try table()
        var failures: [String] = []
        for (index, row) in table.effective.enumerated() {
            let calStart = try XCTUnwrap(APITime.parse(row.cal.startUtc))
            let calEnd = try XCTUnwrap(APITime.parse(row.cal.endUtc))
            let override = MeetingOverride(
                startUtc: APITime.parse(row.chosen.startUtc), endUtc: APITime.parse(row.chosen.endUtc),
                seenStartUtc: APITime.parse(row.chosen.seenStartUtc), seenEndUtc: APITime.parse(row.chosen.seenEndUtc))
            let got = OverrideRules.effective(start: calStart, end: calEnd, override: override)
            let wantStart = try XCTUnwrap(APITime.parse(row.expect.startUtc))
            let wantEnd = try XCTUnwrap(APITime.parse(row.expect.endUtc))
            if got.start != wantStart || got.end != wantEnd {
                failures.append("#\(index) cal \(row.cal.startUtc)..\(row.cal.endUtc) chosen \(row.chosen) worker \(row.expect.startUtc)..\(row.expect.endUtc) phone \(B9.iso(got.start))..\(B9.iso(got.end))")
            }
        }
        XCTAssertEqual(failures.count, 0, "\(failures.count) of \(table.effective.count) differ from the Worker. First: \(failures.prefix(3))")
    }

    func testTheSameAnswersInEveryTimeZone() throws {
        let table = try table()
        // A DST change inside the table's window must change nothing: real elapsed seconds only.
        let sample = Array(table.effective.enumerated().filter { $0.offset % 7 == 0 }.map(\.element))
        try B9.inZones(B9.zones) { zone in
            for row in sample {
                let calStart = try XCTUnwrap(APITime.parse(row.cal.startUtc))
                let calEnd = try XCTUnwrap(APITime.parse(row.cal.endUtc))
                let override = MeetingOverride(
                    startUtc: APITime.parse(row.chosen.startUtc), endUtc: APITime.parse(row.chosen.endUtc),
                    seenStartUtc: APITime.parse(row.chosen.seenStartUtc), seenEndUtc: APITime.parse(row.chosen.seenEndUtc))
                let got = OverrideRules.effective(start: calStart, end: calEnd, override: override)
                XCTAssertEqual(got.start, APITime.parse(row.expect.startUtc), zone)
                XCTAssertEqual(got.end, APITime.parse(row.expect.endUtc), zone)
            }
        }
    }

    func testSeriesIdsAgreeWithTheWorker() throws {
        for row in try table().seriesIds where !row.id.contains("\n") {
            XCTAssertEqual(OverrideOverlay.seriesID(of: row.id), row.seriesId, "id \(row.id.debugDescription)")
        }
    }

    /// The Worker's pattern is anchored at the very end, so an id that ends in a line break is not a series. A regex
    /// whose `$` also matches before a final line break says it is. Not a real Google id; kept for exact parity.
    func testAnIdEndingInALineBreakIsNotASeriesLikeOnTheWorker() throws {
        let rows = try table().seriesIds.filter { $0.id.contains("\n") }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertNil(row.seriesId, "the Worker says not a series")
            XCTAssertNil(OverrideOverlay.seriesID(of: row.id), "id \(row.id.debugDescription)")
        }
    }

    func testTheOverrideTheWorkerSendsDecodesToTheSameWindow() throws {
        // The shape of GET /api/view's `override`: startUtc / endUtc the person set, seen times, calendar times.
        let json = #"""
        {"state":null,"scope":null,"startUtc":"2026-11-25T14:10:00.000Z","endUtc":null,"seenStartUtc":"2026-11-25T14:05:00.000Z",
         "seenEndUtc":"2026-11-25T14:50:00.000Z","seenNone":false,"seriesId":"abc","calendarStartUtc":"2026-11-25T14:00:00.000Z",
         "calendarEndUtc":"2026-11-25T15:00:00.000Z"}
        """#
        let override = try JSONDecoder().decode(MeetingOverride.self, from: Data(json.utf8))
        let window = OverrideRules.effective(
            start: try XCTUnwrap(override.calendarStartUtc), end: try XCTUnwrap(override.calendarEndUtc), override: override)
        // The person's start (step 0) with the Mac's end (step 1) is the cheapest pair.
        XCTAssertEqual(window.start, B9.at(600))
        XCTAssertEqual(window.end, B9.at(3000))
    }
}
