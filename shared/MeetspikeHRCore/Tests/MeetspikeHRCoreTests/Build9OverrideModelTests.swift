import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9, shared Swift contract: `MeetingOverride`, the shape `GET /api/view` puts on each meeting.
//
// NEW API. A missing type stops this whole test target compiling, so the names are fixed here. All of it lives in
// shared/MeetspikeHRCore/Sources/MeetspikeHRCore/Mobile/Overrides/ and is public.
//
//   public struct MeetingOverride: Codable, Equatable, Sendable
//       public enum State: String, Codable, Sendable { case notJoined = "not_joined", unlinked, linked }
//       public enum Scope: String, Codable, Sendable { case event, series }
//       public var state: State?, scope: Scope?
//       public var startUtc, endUtc, seenStartUtc, seenEndUtc: Date?
//       public var seenNone: Bool
//       public var seriesId: String?
//       public init(state: State? = nil, scope: Scope? = nil, startUtc: Date? = nil, endUtc: Date? = nil,
//                   seenStartUtc: Date? = nil, seenEndUtc: Date? = nil, seenNone: Bool = false, seriesId: String? = nil)
//
// Wire form (server `override` object): ISO 8601 text for the four dates (with or without fraction, Z or an offset),
// `state` "not_joined" | "unlinked" | "linked" | null, `scope` "event" | "series" | null, `seenNone` a bool,
// `seriesId` text or null. Plain `JSONDecoder()` / `JSONEncoder()` with no strategies set must work.
//
// Decoding is lenient: a value the app does not know never fails the decode. It is read as "not set" (state, scope,
// the dates, seriesId) or false (seenNone), and everything else on the object is still read. Encoding then decoding
// gives back an equal value (dates at millisecond precision).

final class Build9OverrideModelTests: XCTestCase {
    private func decode(_ json: String) throws -> MeetingOverride {
        try JSONDecoder().decode(MeetingOverride.self, from: Data(json.utf8))
    }

    func testRawValuesAreTheWireNames() {
        XCTAssertEqual(MeetingOverride.State.notJoined.rawValue, "not_joined")
        XCTAssertEqual(MeetingOverride.State.unlinked.rawValue, "unlinked")
        XCTAssertEqual(MeetingOverride.State.linked.rawValue, "linked")
        XCTAssertEqual(MeetingOverride.Scope.event.rawValue, "event")
        XCTAssertEqual(MeetingOverride.Scope.series.rawValue, "series")
        XCTAssertNil(MeetingOverride.State(rawValue: "joined"))
    }

    func testTheEmptyOverrideSaysNothing() {
        let empty = MeetingOverride()
        XCTAssertNil(empty.state)
        XCTAssertNil(empty.scope)
        XCTAssertNil(empty.startUtc)
        XCTAssertNil(empty.endUtc)
        XCTAssertNil(empty.seenStartUtc)
        XCTAssertNil(empty.seenEndUtc)
        XCTAssertFalse(empty.seenNone)
        XCTAssertNil(empty.seriesId)
    }

    func testDecodesAFullServerObject() throws {
        let override = try decode("""
        {"state":"not_joined","scope":"series","startUtc":"2026-11-25T14:05:00.000Z","endUtc":"2026-11-25T14:40:00Z",
         "seenStartUtc":"2026-11-25T14:01:15.000Z","seenEndUtc":"2026-11-25T14:44:30.500Z","seenNone":false,
         "seriesId":"abc123"}
        """)
        XCTAssertEqual(override.state, .notJoined)
        XCTAssertEqual(override.scope, .series)
        XCTAssertEqual(override.startUtc, B9.at(300))
        XCTAssertEqual(override.endUtc, B9.at(2400))
        XCTAssertEqual(override.seenStartUtc, B9.at(75))
        XCTAssertEqual(override.seenEndUtc, B9.at(2670.5))
        XCTAssertFalse(override.seenNone)
        XCTAssertEqual(override.seriesId, "abc123")
    }

    func testDecodesEachStateAndScope() throws {
        for (text, state) in [("not_joined", MeetingOverride.State.notJoined), ("unlinked", .unlinked), ("linked", .linked)] {
            XCTAssertEqual(try decode("{\"state\":\"\(text)\"}").state, state, text)
        }
        for (text, scope) in [("event", MeetingOverride.Scope.event), ("series", .series)] {
            XCTAssertEqual(try decode("{\"scope\":\"\(text)\"}").scope, scope, text)
        }
    }

    func testNullAndMissingFieldsAreNotSet() throws {
        XCTAssertEqual(try decode("{}"), MeetingOverride())
        XCTAssertEqual(try decode("""
        {"state":null,"scope":null,"startUtc":null,"endUtc":null,"seenStartUtc":null,"seenEndUtc":null,
         "seenNone":false,"seriesId":null}
        """), MeetingOverride())
    }

    func testAnUnknownStateIsNilAndTheRestIsStillRead() throws {
        // A newer Worker may add a state. The phone must not fail the whole day because of it.
        let override = try decode("""
        {"state":"snoozed","scope":"event","startUtc":"2026-11-25T14:05:00.000Z","seenNone":true,"seriesId":"s1"}
        """)
        XCTAssertNil(override.state)
        XCTAssertEqual(override.scope, .event)
        XCTAssertEqual(override.startUtc, B9.at(300))
        XCTAssertTrue(override.seenNone)
        XCTAssertEqual(override.seriesId, "s1")
    }

    func testAnUnknownScopeIsNilAndTheRestIsStillRead() throws {
        let override = try decode(#"{"state":"unlinked","scope":"calendar"}"#)
        XCTAssertEqual(override.state, .unlinked)
        XCTAssertNil(override.scope)
    }

    func testWrongTypesAreReadAsNotSetNotAsAFailure() throws {
        let override = try decode("""
        {"state":7,"scope":["event"],"startUtc":1795615500000,"endUtc":"tomorrow at 3","seenStartUtc":"",
         "seenEndUtc":{"a":1},"seenNone":"yes","seriesId":12}
        """)
        XCTAssertEqual(override, MeetingOverride())
    }

    func testOneBadFieldDoesNotHideTheGoodOnes() throws {
        let override = try decode(#"{"state":"linked","startUtc":"nonsense","endUtc":"2026-11-25T15:00:00Z"}"#)
        XCTAssertEqual(override.state, .linked)
        XCTAssertNil(override.startUtc)
        XCTAssertEqual(override.endUtc, B9.at(3600))
    }

    func testUnknownKeysAreIgnored() throws {
        let override = try decode(#"{"state":"linked","futureField":{"deep":[1,2,3]},"extra":true}"#)
        XCTAssertEqual(override.state, .linked)
    }

    func testDatesWithAnOffsetAreTheSameInstant() throws {
        let override = try decode(#"{"startUtc":"2026-11-25T09:05:00-05:00","endUtc":"2026-11-25T20:10:00+05:30"}"#)
        XCTAssertEqual(override.startUtc, B9.at(300))
        XCTAssertEqual(override.endUtc, B9.at(2400))
    }

    func testDecodingDoesNotDependOnTheDeviceTimeZone() throws {
        try B9.inZones(B9.zones) { zone in
            let override = try decode(#"{"startUtc":"2026-11-25T14:05:00.000Z","seenStartUtc":"2026-11-25T14:00:00Z"}"#)
            XCTAssertEqual(override.startUtc, B9.at(300), zone)
            XCTAssertEqual(override.seenStartUtc, B9.at(0), zone)
        }
    }

    func testEncodeThenDecodeGivesTheSameValue() throws {
        let values: [MeetingOverride] = [
            MeetingOverride(),
            MeetingOverride(state: .notJoined, scope: .event),
            MeetingOverride(state: .unlinked, scope: .series, seriesId: "series-9"),
            MeetingOverride(state: .linked, scope: .event, startUtc: B9.at(300.125), endUtc: B9.at(2400),
                            seenStartUtc: B9.at(75), seenEndUtc: B9.at(2670.5), seenNone: false, seriesId: "s"),
            MeetingOverride(seenNone: true),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(MeetingOverride.self, from: data), value)
        }
    }

    func testEncodingUsesTheWireNames() throws {
        let value = MeetingOverride(state: .notJoined, scope: .series, seenNone: true, seriesId: "s1")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "not_joined")
        XCTAssertEqual(object["scope"] as? String, "series")
        XCTAssertEqual(object["seenNone"] as? Bool, true)
        XCTAssertEqual(object["seriesId"] as? String, "s1")
    }

    func testAListOfOverridesDecodesEvenWithOneUnknownState() throws {
        let list = try JSONDecoder().decode([MeetingOverride].self, from: Data("""
        [{"state":"not_joined"},{"state":"from_the_future"},{"state":"linked"}]
        """.utf8))
        XCTAssertEqual(list.map(\.state), [.notJoined, nil, .linked])
    }
}
