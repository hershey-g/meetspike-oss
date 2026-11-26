import Foundation
import XCTest
@testable import MeetspikeHRCore

// Regression tests for five known bugs in the build 5 iPhone app. Each test names the bug it pins and the app
// code that must call the helper. Helpers that do not exist yet are the contract the builders implement.

final class Build5BugTests: XCTestCase {
    private func part(_ json: String) throws -> RefreshPart { try MobileJSON.decode(RefreshPart.self, json) }

    /// A RefreshResult the way APIClient.refresh builds it from a fixture reply.
    private func result(fromFixture name: String) throws -> RefreshResult {
        let reply = try APIFixture.decode(RefreshReply.self, name)
        return RefreshResult(
            calendar: reply.calendar, whoop: reply.whoop, oura: reply.oura, syncedAt: reply.syncedAt,
            needsGoogle: reply.calendar?.needsGoogle == true)
    }

    // MARK: 1. Sleep text "7 h 60 m" (TodayFormat.sleepText, used by the sleep ring)

    func testSleepTextNeverShowsSixtyMinutes() {
        // 28790 s = 479.83 min. Rounding minutes after splitting off hours gave "7 h 60 m".
        XCTAssertEqual(TodayFormat.sleepText(seconds: 28790), "8 h 0 m")
        XCTAssertEqual(TodayFormat.sleepText(seconds: 3570), "1 h 0 m")      // 59.5 min rounds up to the next hour
        XCTAssertEqual(TodayFormat.sleepText(seconds: 86370), "24 h 0 m")
    }

    func testSleepTextRoundsTotalMinutesHalfUp() {
        XCTAssertEqual(TodayFormat.sleepText(seconds: 26970), "7 h 30 m")     // 449.5 min
        XCTAssertEqual(TodayFormat.sleepText(seconds: 26969), "7 h 29 m")     // 449.48 min
    }

    func testSleepTextKeepsTheFormatForNormalValues() {
        XCTAssertEqual(TodayFormat.sleepText(seconds: 27000), "7 h 30 m")
        XCTAssertEqual(TodayFormat.sleepText(seconds: 28800), "8 h 0 m")
        XCTAssertEqual(TodayFormat.sleepText(seconds: 3600), "1 h 0 m")
        XCTAssertEqual(TodayFormat.sleepText(seconds: 1800), "0 h 30 m")
        XCTAssertEqual(TodayFormat.sleepText(seconds: 23460), "6 h 31 m")
    }

    func testSleepTextNeverContainsSixtyMinutesForAnyValue() {
        for seconds in stride(from: 0, through: 40_000, by: 7) {
            let text = TodayFormat.sleepText(seconds: Double(seconds))
            let expected = Int((Double(seconds) / 60).rounded(.toNearestOrAwayFromZero))
            guard text == "\(expected / 60) h \(expected % 60) m" else {
                XCTFail("\(seconds) s gave \(text)")  // first miss only, so a failing run stays readable
                return
            }
        }
    }

    // MARK: 2. Today date labels from an offline copy

    // The screen must call this with env.today (never the cached view's own `today`) and the briefing day.
    func testDateBarOfflineCopyFromYesterdayIsNotToday() {
        let bar = TodayLogic.dateBar(day: "2026-11-24", today: "2026-11-25")
        XCTAssertFalse(bar.isToday, "an offline copy of yesterday must not be labelled Today")
        XCTAssertTrue(bar.canGoNext)
    }

    func testDateBarOnToday() {
        let bar = TodayLogic.dateBar(day: "2026-11-25", today: "2026-11-25")
        XCTAssertTrue(bar.isToday)
        XCTAssertFalse(bar.canGoNext)
    }

    func testDateBarAfterTodayCannotGoNext() {
        let bar = TodayLogic.dateBar(day: "2026-11-26", today: "2026-11-25")
        XCTAssertFalse(bar.isToday)
        XCTAssertFalse(bar.canGoNext)
    }

    func testDateBarAcrossMonthAndYearEdges() {
        let rolled = TodayLogic.dateBar(day: "2026-12-31", today: "2027-01-01")
        XCTAssertFalse(rolled.isToday)
        XCTAssertTrue(rolled.canGoNext)
        let same = TodayLogic.dateBar(day: "2027-01-01", today: "2027-01-01")
        XCTAssertTrue(same.isToday)
        XCTAssertFalse(same.canGoNext)
    }

    // MARK: 3. One sync outcome for Today and Menu

    func testOutcomeCalendarSynced() throws {
        let written = try result(fromFixture: "refresh-written-removed.json")
        XCTAssertEqual(SyncOutcome.decide(written).calendar, .synced(changed: 4))
        XCTAssertEqual(SyncOutcome.decide(written).wearableNotes, [])
        XCTAssertEqual(SyncOutcome.decide(try result(fromFixture: "refresh.json")).calendar, .synced(changed: 2))
        XCTAssertEqual(SyncOutcome.decide(RefreshResult()).calendar, .synced(changed: 0))
    }

    func testOutcomePendingCalendarIsNeverDone() throws {
        let pending = RefreshResult(calendar: try part(#"{"ok":true,"pending":true,"written":4}"#))
        XCTAssertEqual(SyncOutcome.decide(pending).calendar, .pending)
        // Still pending when a wearable also failed.
        let both = RefreshResult(
            calendar: try part(#"{"ok":true,"pending":true}"#), whoop: try part(#"{"ok":false}"#))
        XCTAssertEqual(SyncOutcome.decide(both).calendar, .pending)
        XCTAssertEqual(SyncOutcome.decide(both).wearableNotes, ["WHOOP did not refresh."])
    }

    func testOutcomeNeedsGoogleKeepsWearableFailure() throws {
        // refresh-needs-google.json: calendar needsGoogle, WHOOP ok, Oura failed.
        let outcome = SyncOutcome.decide(try result(fromFixture: "refresh-needs-google.json"))
        XCTAssertEqual(outcome.calendar, .needsGoogle)
        XCTAssertEqual(outcome.wearableNotes, ["Oura did not refresh."])
    }

    func testOutcomeCalendarErrorKeepsWearableFailures() throws {
        let failed = RefreshResult(
            calendar: try part(#"{"ok":false,"error":"HTTP 500"}"#),
            whoop: try part(#"{"ok":false}"#), oura: try part(#"{"ok":false}"#))
        let outcome = SyncOutcome.decide(failed)
        XCTAssertEqual(outcome.calendar, .failed("HTTP 500"))
        XCTAssertEqual(outcome.wearableNotes, ["WHOOP did not refresh.", "Oura did not refresh."])
    }

    func testOutcomeHidesWearablesThePersonTurnedOff() throws {
        let failed = RefreshResult(
            calendar: try part(#"{"ok":false,"error":"HTTP 500"}"#),
            whoop: try part(#"{"ok":false}"#), oura: try part(#"{"ok":false}"#))
        XCTAssertEqual(SyncOutcome.decide(failed, showWhoop: false, showOura: true).wearableNotes, ["Oura did not refresh."])
        XCTAssertEqual(SyncOutcome.decide(failed, showWhoop: true, showOura: false).wearableNotes, ["WHOOP did not refresh."])
        XCTAssertEqual(SyncOutcome.decide(failed, showWhoop: false, showOura: false).wearableNotes, [])
        let needsGoogle = try result(fromFixture: "refresh-needs-google.json")
        XCTAssertEqual(SyncOutcome.decide(needsGoogle, showOura: false).wearableNotes, [])
    }

    func testMenuMessageShowsGoogleProblemAndWearableFailure() throws {
        let message = MoreLogic.syncMessage(try result(fromFixture: "refresh-needs-google.json"))
        XCTAssertTrue(message.hasPrefix("Connect Google Calendar to sync meetings."), message)
        XCTAssertTrue(message.contains("Oura did not refresh."), message)
        XCTAssertFalse(message.contains("WHOOP did not refresh."), message)
        XCTAssertEqual(
            MoreLogic.syncMessage(try result(fromFixture: "refresh-needs-google.json"), showOura: false),
            "Connect Google Calendar to sync meetings.")
    }

    func testMenuMessageShowsCalendarErrorAndWearableFailures() throws {
        let failed = RefreshResult(
            calendar: try part(#"{"ok":false,"error":"HTTP 500"}"#),
            whoop: try part(#"{"ok":false}"#), oura: try part(#"{"ok":false}"#))
        let message = MoreLogic.syncMessage(failed)
        XCTAssertTrue(message.hasPrefix("Calendar sync failed: HTTP 500"), message)
        XCTAssertTrue(message.contains("WHOOP did not refresh."), message)
        XCTAssertTrue(message.contains("Oura did not refresh."), message)
        let oneHidden = MoreLogic.syncMessage(failed, showWhoop: false)
        XCTAssertFalse(oneHidden.contains("WHOOP"), oneHidden)
        XCTAssertTrue(oneHidden.contains("Oura did not refresh."), oneHidden)
    }

    func testMenuMessageStillSyncingKeepsItsWordingAndWearableNote() throws {
        let pending = RefreshResult(calendar: try part(#"{"ok":true,"pending":true}"#), oura: try part(#"{"ok":false}"#))
        XCTAssertEqual(
            MoreLogic.syncMessage(pending),
            "Still syncing in the background. New meetings show up when it finishes. Oura did not refresh.")
        XCTAssertFalse(MoreLogic.syncMessage(pending).contains("Synced just now"))
    }

    // MARK: 4. Person page must not show another person's data

    private let week = DatesSpan(start: "2026-11-18", end: "2026-11-24")
    private let month = DatesSpan(start: "2026-10-28", end: "2026-11-24")

    func testPersonReloadsWhenOnlyTheEmailChanges() {
        XCTAssertTrue(PeopleLogic.shouldReloadPerson(
            loadedEmail: "a@example.com", loadedSpan: week, email: "b@example.com", span: week))
    }

    func testPersonDoesNotReloadForTheSameEmailAndSpan() {
        XCTAssertFalse(PeopleLogic.shouldReloadPerson(
            loadedEmail: "a@example.com", loadedSpan: week, email: "a@example.com", span: week))
    }

    func testPersonReloadsWhenOnlyTheSpanChanges() {
        XCTAssertTrue(PeopleLogic.shouldReloadPerson(
            loadedEmail: "a@example.com", loadedSpan: week, email: "a@example.com", span: month))
    }

    func testPersonReloadsWhenNothingIsLoaded() {
        XCTAssertTrue(PeopleLogic.shouldReloadPerson(
            loadedEmail: nil, loadedSpan: nil, email: "a@example.com", span: week))
        XCTAssertTrue(PeopleLogic.shouldReloadPerson(
            loadedEmail: nil, loadedSpan: week, email: "a@example.com", span: week))
        XCTAssertTrue(PeopleLogic.shouldReloadPerson(
            loadedEmail: "a@example.com", loadedSpan: nil, email: "a@example.com", span: week))
    }

    func testLateAnswerForAnotherPersonIsDropped() {
        // Person A's request is still in flight while person B is on screen.
        XCTAssertFalse(PeopleLogic.acceptsPersonAnswer(
            answerEmail: "a@example.com", answerSpan: week, showingEmail: "b@example.com", showingSpan: week))
    }

    func testLateAnswerForAnotherSpanIsDropped() {
        XCTAssertFalse(PeopleLogic.acceptsPersonAnswer(
            answerEmail: "a@example.com", answerSpan: week, showingEmail: "a@example.com", showingSpan: month))
    }

    func testAnswerForWhatIsShowingIsAccepted() {
        XCTAssertTrue(PeopleLogic.acceptsPersonAnswer(
            answerEmail: "a@example.com", answerSpan: week, showingEmail: "a@example.com", showingSpan: week))
    }

    // MARK: 5. A changed Meetspike URL or token must reload People (pure part only)
    //
    // Menu has no pure logic to pin: MoreScreen's `.task { await load() }` has no id, so it needs
    // `.task(id: env.connectionRevision)` in the app target. That part is wiring and is not covered by swift test.
    // People's gate is pure: content loaded for the old connection must not count as content for the new one.

    func testGateTreatsANewConnectionAsNoContent() {
        var gate = PeopleLoadGate()
        gate.markLoaded(week, connection: 1)
        XCTAssertTrue(gate.hasContent(for: week, connection: 1))
        XCTAssertFalse(gate.hasContent(for: week, connection: 2))
        XCTAssertTrue(gate.showsSpinner(for: week, connection: 2), "old server's people must not stay on screen")
        XCTAssertTrue(gate.resetsPager(for: week, connection: 2))
        XCTAssertFalse(gate.showsSpinner(for: week, connection: 1))
        XCTAssertFalse(gate.resetsPager(for: week, connection: 1))
    }

    func testGateStillKeysOnSpanWithinOneConnection() {
        var gate = PeopleLoadGate()
        gate.markLoaded(week, connection: 3)
        XCTAssertFalse(gate.hasContent(for: month, connection: 3))
        gate.clear()
        XCTAssertFalse(gate.hasContent(for: week, connection: 3))
    }
}
