import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 fix pass, F8: `MeetingOverride.seriesState: MeetingOverride.State?`, the series' own saved state, even when
// the event's own choice wins. Nil when the series has none (or an older Worker did not send it). Decoding is lenient
// like the other fields: an unknown value or a wrong type reads as nil and the rest of the object is still read.
// `init` takes `seriesState:` with a default of nil, so every existing call still compiles.
//
// This is the only F8 file that needs the new member, so it is the only one that fails to compile today. The
// behavior (Undo sends linked) is in Build9FixF8UndoTests.

final class Build9FixF8SeriesStateModelTests: XCTestCase {
    private func decode(_ json: String) throws -> MeetingOverride {
        try MobileJSON.decode(MeetingOverride.self, json)
    }

    func testTheSeriesStateIsReadFromTheWorkerJSON() throws {
        let cases: [(String, MeetingOverride.State)] = [("not_joined", .notJoined), ("unlinked", .unlinked), ("linked", .linked)]
        for (text, state) in cases {
            let override = try decode(#"{"state":"not_joined","scope":"event","seriesId":"s","seriesState":"\#(text)"}"#)
            XCTAssertEqual(override.seriesState, state, text)
            XCTAssertEqual(override.state, .notJoined, "the event's own choice is still the state")
            XCTAssertEqual(override.scope, .event)
        }
    }

    func testMissingNullOrUnknownIsNil() throws {
        XCTAssertNil(try decode(#"{"state":"not_joined","scope":"event"}"#).seriesState)
        XCTAssertNil(try decode(#"{"seriesState":null}"#).seriesState)
        let unknown = try decode(#"{"state":"unlinked","scope":"event","seriesId":"s","seriesState":"something_new"}"#)
        XCTAssertNil(unknown.seriesState)
        XCTAssertEqual(unknown.state, .unlinked, "the rest of the object is still read")
        XCTAssertEqual(unknown.seriesId, "s")
        XCTAssertNil(try decode(#"{"state":"unlinked","seriesState":7}"#).seriesState)
    }

    func testTheInitDefaultsToNilAndTakesAValue() {
        XCTAssertNil(MeetingOverride().seriesState)
        XCTAssertNil(MeetingOverride(state: .notJoined, scope: .event, seriesId: "s").seriesState)
        XCTAssertEqual(MeetingOverride(state: .notJoined, scope: .event, seriesId: "s", seriesState: .unlinked).seriesState, .unlinked)
    }

    func testItSurvivesEncodingAndDecodingAgain() throws {
        let original = MeetingOverride(state: .notJoined, scope: .event, seriesId: "s", seriesState: .notJoined)
        let data = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(MeetingOverride.self, from: data)
        XCTAssertEqual(again.seriesState, .notJoined)
        XCTAssertEqual(again, original)
    }

    func testUndoUsesItWithTheDirectInit() {
        let both = MeetingOverride(state: .notJoined, scope: .event, seriesId: "s", seriesState: .notJoined)
        XCTAssertEqual(MeetingActions.plan(.undo, override: both), .save(OverrideEdit(scope: .event, state: .set(.linked))))
        let ownOnly = MeetingOverride(state: .notJoined, scope: .event, seriesId: "s")
        XCTAssertEqual(MeetingActions.plan(.undo, override: ownOnly), .save(OverrideEdit(scope: .event, state: .clear)))
    }
}
