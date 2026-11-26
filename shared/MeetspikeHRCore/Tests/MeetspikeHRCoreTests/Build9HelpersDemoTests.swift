import Foundation
import XCTest
@testable import MeetspikeHRCore

// The app's demo day (used for screenshots) must show every meeting state the spec describes: one meeting in a
// series, one left out as "Not linked", one with the quiet "Looks like you didn't join" note, and one left out as
// "Didn't join". The bundled demo JSON has to stay the same as the test fixtures, so a plain DemoAPI shows no choices.
//
// Written from the spec, after the code. DemoAPI with seedsMeetingChoices, DemoMeetingChoices.

final class Build9HelpersDemoTests: XCTestCase {
    private func demo(seeded: Bool = true) -> DemoAPI {
        DemoAPI(directory: APIFixture.directory, seedsMeetingChoices: seeded)
    }

    private func events(_ api: DemoAPI) async throws -> [Meeting] {
        try await api.view(date: DemoAPI.demoToday).day?.calendar?.events ?? []
    }

    // MARK: The plain fixtures do not change

    func testAPlainDemoShowsNoChoicesAtAll() async throws {
        let rows = try await events(demo(seeded: false))
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0.override == nil && $0.excluded == nil })
        let view = try await demo(seeded: false).view(date: DemoAPI.demoToday)
        XCTAssertEqual(view.day?.calendar?.eventCount, 5)
    }

    // MARK: The seeded day

    func testTheSeededDayLeavesOutTwoMeetingsWithTheTwoLabels() async throws {
        let rows = try await events(demo())
        let left = rows.filter { $0.excluded == true }
        XCTAssertEqual(left.count, 2)
        XCTAssertEqual(
            Set(left.map { MeetingActions.excludedLabel($0.override) }), ["Didn't join", "Not linked"],
            "one of each")
        XCTAssertEqual(left.filter { $0.override?.state == .unlinked }.count, 1, "one not linked")
        XCTAssertEqual(left.filter { $0.override?.state == .notJoined }.count, 1, "one didn't join")
        XCTAssertTrue(left.allSatisfy { OverrideRules.excluded($0.override) })
    }

    func testTheSeededDayHasOneQuietNote() async throws {
        let rows = try await events(demo())
        let asking = rows.filter { OverrideRules.suggestsNotJoined($0.override) }
        XCTAssertEqual(asking.count, 1)
        XCTAssertNotEqual(asking.first?.excluded, true, "the note is under a meeting that is still in")
        XCTAssertNil(asking.first?.override?.state, "nobody has answered")
    }

    func testTheSeededDayHasAMeetingInASeriesThatOffersAllOfThem() async throws {
        let rows = try await events(demo())
        let inSeries = rows.filter { $0.excluded != true && $0.override?.seriesId != nil && $0.override?.state == nil }
        XCTAssertFalse(inSeries.isEmpty, "a plain meeting in a series, so Just this one / All of them is shown")
        for row in inSeries {
            XCTAssertEqual(
                MeetingActions.plan(.notJoined, override: row.override), .askScope(.state(.notJoined)), row.id)
        }
        // And at least one meeting is not in a series, so the direct path is shown too.
        XCTAssertTrue(rows.contains { $0.override?.seriesId == nil })
    }

    func testLeftOutMeetingsHaveNoScoreNoFlagsNoHeartRateAndComeLast() async throws {
        let rows = try await events(demo())
        let left = rows.filter { $0.excluded == true }
        for row in left {
            XCTAssertNil(row.score, row.id)
            XCTAssertTrue(row.flags.isEmpty, row.id)
            XCTAssertNil(row.hrStress, row.id)
        }
        let firstLeft = try XCTUnwrap(rows.firstIndex { $0.excluded == true })
        XCTAssertTrue(rows[firstLeft...].allSatisfy { $0.excluded == true }, "left out rows come after the others")
        // The others keep their scores.
        XCTAssertTrue(rows.filter { $0.excluded != true }.allSatisfy { $0.score != nil })
    }

    func testTheDayTotalsLeaveOutTheLeftOutMeetings() async throws {
        let view = try await demo().view(date: DemoAPI.demoToday)
        let calendar = try XCTUnwrap(view.day?.calendar)
        let counted = calendar.events.filter { $0.excluded != true }
        XCTAssertEqual(calendar.eventCount, counted.count, "never in averages or counts")
        XCTAssertEqual(calendar.eventCount, 3)
        XCTAssertEqual(calendar.totalDurationS, counted.reduce(0) { $0 + ($1.durationS ?? 0) })
        XCTAssertEqual(calendar.afterHoursCount, counted.filter { $0.afterHours == true }.count)
    }

    func testTheSeededDayHasTheSameMeetingsAsTheFixture() async throws {
        let plain = try await events(demo(seeded: false))
        let seeded = try await events(demo())
        XCTAssertEqual(Set(seeded.map(\.id)), Set(plain.map(\.id)), "nothing added, nothing removed")
        XCTAssertEqual(seeded.count, plain.count)
    }

    func testDaysWithNoMeetingsStayEmptyWhenSeeded() async throws {
        let view = try await demo().view(date: "2026-11-10")
        XCTAssertEqual(view.day?.calendar?.events.count, 0)
    }

    // MARK: Saving in the demo

    func testASaveInTheDemoChangesTheDayAndUndoChangesItBack() async throws {
        let api = demo(seeded: false)
        let result = try await api.saveOverride(meetingID: "m-pipeline", edit: OverrideEdit(scope: .event, state: .set(.notJoined)))
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.id, "m-pipeline")
        XCTAssertEqual(result.scope, "event")

        var rows = try await events(api)
        XCTAssertEqual(rows.first { $0.id == "m-pipeline" }?.excluded, true)
        XCTAssertEqual(rows.filter { $0.excluded == true }.count, 1)

        _ = try await api.saveOverride(meetingID: "m-pipeline", edit: OverrideEdit(scope: .event, state: .clear))
        rows = try await events(api)
        XCTAssertNil(rows.first { $0.id == "m-pipeline" }?.excluded)
        XCTAssertEqual(rows.filter { $0.excluded == true }.count, 0)
    }

    func testTheDemoFailureToggleFailsASaveAndChangesNothing() async throws {
        let api = demo(seeded: false)
        api.failure = .offline
        do {
            _ = try await api.saveOverride(meetingID: "m-pipeline", edit: OverrideEdit(scope: .event, state: .set(.notJoined)))
            XCTFail("a failing demo must fail the save")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
        api.failure = nil
        let rows = try await events(api)
        XCTAssertTrue(rows.allSatisfy { $0.excluded == nil }, "the old state stays")
    }

    func testAnUnconfiguredAppCannotSave() async {
        do {
            _ = try await UnconfiguredAPI().saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
            XCTFail("an unconfigured app cannot save")
        } catch {
            XCTAssertEqual(error as? APIError, .notConfigured)
        }
    }
}
