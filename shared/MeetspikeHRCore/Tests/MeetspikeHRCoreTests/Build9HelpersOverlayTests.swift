import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 iPhone spec: "Saved overrides survive offline" and "Listening windows use effective times and skip excluded
// meetings", and the resolution rules: an event choice beats a series choice, `linked` on one meeting opts it out of a
// series rule, excluded = not_joined or unlinked. While an edit is waiting in the outbox the rows and the listening
// windows must already behave as the person chose. Series id = event id without `_YYYYMMDD` / `_YYYYMMDDTHHMMSSZ`,
// null when there is no suffix.
//
// Written from the spec, after the code. Pure: OverrideOverlay.

final class Build9HelpersOverlayTests: XCTestCase {
    private typealias Items = [(id: String, override: MeetingOverride?)]

    private let ruleOut = MeetingOverride(state: .notJoined, scope: .series, seriesId: "s")
    private let plain = MeetingOverride(seriesId: "s")

    // MARK: Series ids

    func testSeriesIdIsTheIdWithoutTheInstanceSuffix() {
        XCTAssertEqual(OverrideOverlay.seriesID(of: "abc123_20261125T140000Z"), "abc123")
        XCTAssertEqual(OverrideOverlay.seriesID(of: "abc123_20261125"), "abc123")
        XCTAssertEqual(OverrideOverlay.seriesID(of: "a_b_20261125T140000Z"), "a_b")
    }

    func testIdsWithoutTheSuffixAreNotSeries() {
        // Spec: 23 live ids contain "_" without the suffix and are NOT series unless they end in _YYYYMMDD exactly.
        for id in [
            "abc123", "", "_", "abc_def", "abc_2026112", "abc_202611250", "abc_20261125T14000Z", "abc_20261125T140000",
            "abc_20261125T140000Zx", "20261125", "_20261125", "abc_2026-11-25",
        ] {
            XCTAssertNil(OverrideOverlay.seriesID(of: id), "\(id)")
        }
    }

    // MARK: Rows

    func testAWaitingNotJoinedLeavesTheRowOutAndNoOtherRow() throws {
        let rows = [try H9.row("a"), try H9.row("b", title: "Planning", score: 0.5), try H9.row("c")]
        let pending = [H9.item("b", OverrideEdit(scope: .event, state: .set(.notJoined)))]
        let result = OverrideOverlay.apply(pending, to: rows)

        XCTAssertEqual(result.map(\.id), ["a", "b", "c"], "same rows, same order")
        XCTAssertEqual(result.map { $0.excluded == true }, [false, true, false])
        XCTAssertEqual(result[1].override?.state, .notJoined)
        XCTAssertEqual(result[1].override?.scope, .event)
        XCTAssertEqual(result[0], rows[0], "rows nobody edited are untouched")
        XCTAssertEqual(result[2], rows[2])
        XCTAssertEqual(result[1].title, "Planning")
    }

    func testWaitingUnlinkedAlsoLeavesTheRowOutWithItsOwnLabel() throws {
        let result = OverrideOverlay.apply(
            [H9.item("a", OverrideEdit(scope: .event, state: .set(.unlinked)))], to: [try H9.row("a")])
        XCTAssertEqual(result[0].excluded, true)
        XCTAssertEqual(MeetingActions.excludedLabel(result[0].override), "Not linked")
    }

    func testAWaitingLinkedKeepsTheRowIn() throws {
        let result = OverrideOverlay.apply(
            [H9.item("a", OverrideEdit(scope: .event, state: .set(.linked)))], to: [try H9.row("a")])
        XCTAssertNil(result[0].excluded)
        XCTAssertEqual(result[0].override?.state, .linked)
    }

    func testAWaitingUndoPutsALeftOutRowBack() throws {
        let left = try H9.row("a", override: MeetingOverride(state: .notJoined, scope: .event), excluded: true)
        let result = OverrideOverlay.apply([H9.item("a", OverrideEdit(scope: .event, state: .clear))], to: [left])
        XCTAssertNil(result[0].excluded)
        XCTAssertNil(result[0].override?.state)
        XCTAssertNil(result[0].override?.scope)
    }

    func testNothingWaitingChangesNothing() throws {
        let rows = [try H9.row("a", override: ruleOut, excluded: true), try H9.row("b")]
        XCTAssertEqual(OverrideOverlay.apply([], to: rows), rows)
        let items: Items = [("a", ruleOut), ("b", nil)]
        XCTAssertEqual(OverrideOverlay.apply([], to: items), [ruleOut, nil])
        XCTAssertEqual(OverrideOverlay.apply([], to: [H9.remote()]), [H9.remote()])
    }

    func testAnEditForAMeetingNotInTheListChangesNothing() throws {
        let rows = [try H9.row("a"), try H9.row("b")]
        let result = OverrideOverlay.apply([H9.item("zzz", OverrideEdit(scope: .event, state: .set(.notJoined)))], to: rows)
        XCTAssertEqual(result, rows)
    }

    func testNewestEditWins() {
        let items: Items = [("a", nil)]
        let pending = [
            H9.item("a", OverrideEdit(scope: .event, state: .set(.notJoined)), queued: 0),
            H9.item("a", OverrideEdit(scope: .event, state: .set(.linked)), queued: 10),
        ]
        XCTAssertEqual(OverrideOverlay.apply(pending, to: items)[0]?.state, .linked)
        let undone = pending + [H9.item("a", OverrideEdit(scope: .event, state: .clear), queued: 20)]
        XCTAssertNil(OverrideOverlay.apply(undone, to: items)[0]?.state)
    }

    // MARK: Times

    func testWaitingTimesLandOnTheMeetingAndClearWithUseCalendarTimes() {
        let items: Items = [("a", nil)]
        let set = OverrideEdit(scope: .event, startUtc: .set(B9.at(-600)), endUtc: .set(B9.at(2400)))
        let moved = OverrideOverlay.apply([H9.item("a", set)], to: items)[0]
        XCTAssertEqual(moved?.startUtc, B9.at(-600))
        XCTAssertEqual(moved?.endUtc, B9.at(2400))
        XCTAssertNil(moved?.state, "times do not decide a state")
        XCTAssertFalse(OverrideRules.excluded(moved))

        let cleared = OverrideOverlay.apply(
            [H9.item("a", set, queued: 0), H9.item("a", OverrideEdit(scope: .event, startUtc: .clear, endUtc: .clear), queued: 5)],
            to: items)[0]
        XCTAssertNil(cleared?.startUtc)
        XCTAssertNil(cleared?.endUtc)
    }

    func testAStateEditKeepsTheTimesTheMeetingAlreadyHad() {
        let had = MeetingOverride(startUtc: B9.at(-300), endUtc: B9.at(2000))
        let result = OverrideOverlay.apply(
            [H9.item("a", OverrideEdit(scope: .event, state: .set(.linked)))], to: [(id: "a", override: had)])[0]
        XCTAssertEqual(result?.startUtc, B9.at(-300))
        XCTAssertEqual(result?.endUtc, B9.at(2000))
    }

    func testASeriesEditNeverMovesTimes() {
        // OverrideEdit drops times for the series scope, so a series edit cannot move a meeting.
        let edit = OverrideEdit(scope: .series, state: .set(.notJoined), startUtc: .set(B9.at(0)), endUtc: .set(B9.at(60)))
        let result = OverrideOverlay.apply([H9.item("s_20261125", edit)], to: [(id: "s_20261125", override: plain)])[0]
        XCTAssertNil(result?.startUtc)
        XCTAssertNil(result?.endUtc)
        XCTAssertEqual(result?.state, .notJoined)
    }

    // MARK: Series

    func testASeriesEditReachesEveryMeetingOfTheSeriesAndNoOther() {
        let items: Items = [
            ("s_20261124", plain), ("s_20261125", plain), ("other_20261125", MeetingOverride(seriesId: "other")),
            ("single", nil),
        ]
        let edit = OverrideEdit(scope: .series, state: .set(.notJoined))
        let result = OverrideOverlay.apply([H9.item("s_20261125", edit)], to: items)
        XCTAssertEqual(result.map(OverrideRules.excluded), [true, true, false, false])
        XCTAssertEqual(result[0]?.scope, .series)
        XCTAssertEqual(result[0]?.seriesId, "s")
    }

    func testAnEventChoiceBeatsASeriesEdit() {
        let own = MeetingOverride(state: .linked, scope: .event, seriesId: "s")
        let items: Items = [("s_20261124", plain), ("s_20261125", own)]
        let result = OverrideOverlay.apply(
            [H9.item("s_20261124", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: items)
        XCTAssertEqual(result.map(OverrideRules.excluded), [true, false], "linked on one meeting opts it out of the rule")
        XCTAssertEqual(result[1], own)
    }

    func testASeriesEditCannotCrossAnEventChoiceMadeAfterIt() {
        // A series rule, then "just this one" kept: newest event choice wins for that meeting.
        let items: Items = [("s_20261124", plain), ("s_20261125", plain)]
        let pending = [
            H9.item("s_20261124", OverrideEdit(scope: .series, state: .set(.notJoined)), queued: 0),
            H9.item("s_20261125", OverrideEdit(scope: .event, state: .set(.linked)), queued: 10),
        ]
        XCTAssertEqual(OverrideOverlay.apply(pending, to: items).map(OverrideRules.excluded), [true, false])
    }

    func testASeriesEditForAnEventOutsideTheListStillReachesTheListedOnes() {
        // The id carries the suffix, so the series is known even when that meeting is on another day.
        let items: Items = [("s_20261125", plain)]
        let result = OverrideOverlay.apply(
            [H9.item("s_20261201", OverrideEdit(scope: .series, state: .set(.unlinked)))], to: items)
        XCTAssertTrue(OverrideRules.excluded(result[0]))
    }

    func testASeriesEditForAMeetingWithNoSeriesIdDoesNothing() {
        let items: Items = [("plain-id", nil), ("s_20261125", plain)]
        let result = OverrideOverlay.apply(
            [H9.item("plain-id", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: items)
        XCTAssertEqual(result.map(OverrideRules.excluded), [false, false])
    }

    func testSeriesIdIsFoundFromTheIdWhenTheOverrideHasNone() {
        // A meeting the Worker sent with no override object, in a series by its id.
        let items: Items = [("s_20261124T140000Z", nil), ("s_20261125T140000Z", nil)]
        let result = OverrideOverlay.apply(
            [H9.item("s_20261124T140000Z", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: items)
        XCTAssertEqual(result.map(OverrideRules.excluded), [true, true])
    }

    func testRemovingTheSeriesRuleLeavesEventChoicesAlone() {
        let own = MeetingOverride(state: .notJoined, scope: .event, seriesId: "s")
        let items: Items = [("s_20261124", ruleOut), ("s_20261125", own)]
        let result = OverrideOverlay.apply(
            [H9.item("s_20261124", OverrideEdit(scope: .series, state: .clear))], to: items)
        XCTAssertEqual(result.map(OverrideRules.excluded), [false, true])
    }

    /// Spec: "Resolution: event state wins over series state. `linked` on an event opts it out of a series rule."
    /// So clearing that opt out (Undo on the linked meeting) brings the series rule back for that meeting. The other
    /// meetings in the list show what the rule is, so the phone can know it before the Worker answers.
    func testClearingAnOptOutBringsTheSeriesRuleBack() {
        let optedOut = MeetingOverride(state: .linked, scope: .event, seriesId: "s")
        let items: Items = [("s_20261124", ruleOut), ("s_20261125", optedOut)]
        let result = OverrideOverlay.apply([H9.item("s_20261125", OverrideEdit(scope: .event, state: .clear))], to: items)
        XCTAssertEqual(
            result.map(OverrideRules.excluded), [true, true],
            "the series rule is not overridden any more, so this meeting is left out again")
    }

    // MARK: Rows and listening see the same edit

    func testTheSameWaitingEditLeavesTheRowOutAndSilencesListening() throws {
        let rows = [try H9.row("ev1", title: "Standup", start: 0, end: 1800)]
        let pending = [H9.item("ev1", OverrideEdit(scope: .event, state: .set(.notJoined)))]

        XCTAssertEqual(OverrideOverlay.apply(pending, to: rows)[0].excluded, true)

        let remote = [H9.remote("ev1", start: 0, end: 1800)]
        let phone = [B9.meeting("Standup", 0, 1800)]
        let withEdit = OverrideOverlay.apply(pending, to: remote)
        XCTAssertEqual(OverrideMatch.apply(withEdit, to: phone), [], "left out: no listening window")
        XCTAssertEqual(OverrideMatch.apply(remote, to: phone), phone, "without the edit it listens")
    }

    func testAWaitingTimeEditMovesTheListeningWindow() {
        let remote = [H9.remote("ev1", start: 0, end: 1800)]
        let pending = [H9.item("ev1", OverrideEdit(scope: .event, endUtc: .set(B9.at(2700))))]
        let moved = OverrideMatch.apply(OverrideOverlay.apply(pending, to: remote), to: [B9.meeting("Standup", 0, 1800)])
        XCTAssertEqual(moved.first?.start, B9.at(0))
        XCTAssertEqual(moved.first?.end, B9.at(2700))
    }

    func testRemoteOverlayChangesOnlyTheOverride() {
        let remote = [H9.remote("ev1", title: "Standup", start: 60, end: 1860, override: plain)]
        let pending = [H9.item("ev1", OverrideEdit(scope: .event, state: .set(.unlinked)))]
        let result = OverrideOverlay.apply(pending, to: remote)
        XCTAssertEqual(result[0].id, "ev1")
        XCTAssertEqual(result[0].title, "Standup")
        XCTAssertEqual(result[0].calendarStart, B9.at(60))
        XCTAssertEqual(result[0].calendarEnd, B9.at(1860))
        XCTAssertEqual(result[0].override?.state, .unlinked)
        XCTAssertEqual(result[0].override?.seriesId, "s")
    }
}
