import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 fix pass, F8 (phone half): Undo on a meeting that is left out by both its own choice and its series sends
// `linked` for the event, so the meeting really comes back. Clearing the event's own choice would hand the meeting to
// the series rule, and it would stay out.
//
// DATA CONTRACT (the one new thing here): the phone cannot tell from `override.scope` alone, because an event choice
// wins and reports scope "event". The override object GET /api/view puts on a meeting therefore carries the state the
// series rule gives, even when the event's own choice wins:
//
//     "override": { "state": "not_joined", "scope": "event", "seriesId": "s", "seriesState": "not_joined" | "unlinked" | "linked" | null, ... }
//
// `MeetingOverride` reads it (the Swift property name is the builder's; these tests decode from JSON, so only the JSON
// key `seriesState` is fixed). Missing or null means no series rule (an older Worker answers like that), and Undo
// then clears as before. The server and web side of the same rule is in the Worker tests.

final class Build9FixF8UndoTests: XCTestCase {
    private func override(_ json: String) throws -> MeetingOverride {
        try MobileJSON.decode(MeetingOverride.self, json)
    }

    private func both(own: String = "not_joined", series: String = "not_joined") throws -> MeetingOverride {
        try override(#"{"state":"\#(own)","scope":"event","seriesId":"s","seriesState":"\#(series)"}"#)
    }

    private let putBack = OverrideEdit(scope: .event, state: .set(.linked))

    func testUndoWhenBothTheMeetingAndItsSeriesAreLeftOutSendsLinkedForTheEvent() throws {
        for own in ["not_joined", "unlinked"] {
            for series in ["not_joined", "unlinked"] {
                let override = try both(own: own, series: series)
                XCTAssertTrue(MeetingActions.canUndo(override))
                XCTAssertEqual(
                    MeetingActions.plan(.undo, override: override), .save(putBack), "own \(own), series \(series)")
            }
        }
    }

    func testThatEditReallyBringsTheMeetingBackThroughTheOverlay() throws {
        let override = try both()
        let sibling = MeetingOverride(state: .notJoined, scope: .series, seriesId: "s")
        let items: [(id: String, override: MeetingOverride?)] = [("s_20261125", override), ("s_20261126", sibling)]
        guard case .save(let edit) = MeetingActions.plan(.undo, override: override) else { return XCTFail("saves right away") }
        let after = OverrideOverlay.apply([H9.item("s_20261125", edit)], to: items)
        XCTAssertEqual(after.map(OverrideRules.excluded), [false, true], "this one is back, the series rule still holds for the others")
    }

    func testThatEditGoesOutAsLinkedOnTheWire() throws {
        guard case .save(let edit) = MeetingActions.plan(.undo, override: try both()) else { return XCTFail("saves right away") }
        let body = try H9.wire(edit)
        XCTAssertEqual(body["scope"] as? String, "event")
        XCTAssertEqual(body["state"] as? String, "linked")
        XCTAssertNil(body["startUtc"])
        XCTAssertNil(body["endUtc"])
    }

    // MARK: The cases that keep their old answer

    func testAnEventChoiceWithNoSeriesRuleIsStillJustCleared() throws {
        let clear = OverrideEdit(scope: .event, state: .clear)
        let absent = try override(#"{"state":"not_joined","scope":"event","seriesId":"s"}"#)
        let null = try override(#"{"state":"not_joined","scope":"event","seriesId":"s","seriesState":null}"#)
        let alone = try override(#"{"state":"unlinked","scope":"event"}"#)
        for override in [absent, null, alone] {
            XCTAssertEqual(MeetingActions.plan(.undo, override: override), .save(clear))
        }
    }

    func testASeriesRuleThatKeepsMeetingsInDoesNotTurnUndoIntoLinked() throws {
        // The series says linked: clearing the own choice already puts the meeting back.
        let override = try both(own: "not_joined", series: "linked")
        XCTAssertEqual(MeetingActions.plan(.undo, override: override), .save(OverrideEdit(scope: .event, state: .clear)))
    }

    func testAnOwnLinkedChoiceIsStillClearedSoTheSeriesRuleCanApply() throws {
        let override = try both(own: "linked", series: "not_joined")
        XCTAssertEqual(MeetingActions.plan(.undo, override: override), .save(OverrideEdit(scope: .event, state: .clear)))
    }

    func testARuleOnlyFromTheSeriesStillAsksJustThisOneOrAllOfThem() throws {
        let rule = try override(#"{"state":"not_joined","scope":"series","seriesId":"s","seriesState":"not_joined"}"#)
        XCTAssertEqual(MeetingActions.plan(.undo, override: rule), .askScope(.undo))
        XCTAssertEqual(MeetingActions.answer(.event, to: .undo, override: rule), putBack)
        XCTAssertEqual(MeetingActions.answer(.series, to: .undo, override: rule), OverrideEdit(scope: .series, state: .clear))
    }
}
