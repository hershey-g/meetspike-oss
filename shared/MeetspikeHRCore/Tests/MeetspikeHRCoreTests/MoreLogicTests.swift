import Foundation
import XCTest
@testable import MeetspikeHRCore

// More track: connection rows, version label, source toggle request.

final class MoreConnectionRowsTests: XCTestCase {
    private func status(_ json: String) throws -> ViewStatus { try MobileJSON.decode(ViewStatus.self, json) }

    func testNoStatusStillOffersGoogleToConnect() throws {
        // The web always draws the Google row, as "Connect" when there is no status yet (app.js renderMore).
        XCTAssertEqual(
            MoreLogic.connectionRows(status: nil),
            [MoreConnectionRow(id: "google", title: "Google Calendar", isConnected: false, isDisplayed: nil, lastDataDay: nil)])
    }

    func testLastDataDayOnlyWhenTheWearableHasHistory() throws {
        // The web shows "Last data ..." only when history.min exists, else "No data yet".
        let rows = MoreLogic.connectionRows(status: try status("""
        {"googleConnected":true,"wearables":[
          {"source":"whoop","label":"WHOOP","connected":true,"lastDataDay":"2026-11-24","history":{"min":"2026-01-02","max":"2026-11-24"}},
          {"source":"oura","label":"Oura","connected":true,"lastDataDay":"2026-11-23"}
        ]}
        """))
        XCTAssertEqual(rows.map(\.id), ["whoop", "oura", "google"])
        XCTAssertEqual(rows.first?.lastDataDay, "2026-11-24")
        XCTAssertNil(rows[safe: 1]?.lastDataDay)
    }

    func testWearablesThenGoogleInTheOrderSent() throws {
        let rows = MoreLogic.connectionRows(status: try status("""
        {"googleConnected":true,"wearables":[
          {"source":"whoop","label":"WHOOP","displayEnabled":true,"connected":true,"lastDataDay":"2026-11-24","history":{"min":"2026-01-02","max":"2026-11-24"}},
          {"source":"oura","label":"Oura","displayEnabled":false,"connected":true,"lastDataDay":"2026-11-23","history":{"min":"2026-02-01","max":"2026-11-23"}}
        ]}
        """))
        XCTAssertEqual(rows, [
            MoreConnectionRow(id: "whoop", title: "WHOOP", isConnected: true, isDisplayed: true, lastDataDay: "2026-11-24"),
            MoreConnectionRow(id: "oura", title: "Oura", isConnected: true, isDisplayed: false, lastDataDay: "2026-11-23"),
            MoreConnectionRow(id: "google", title: "Google Calendar", isConnected: true, isDisplayed: nil, lastDataDay: nil),
        ])
    }

    func testOrderFollowsTheWorkerNotAlphabet() throws {
        let rows = MoreLogic.connectionRows(status: try status("""
        {"googleConnected":false,"wearables":[
          {"source":"oura","label":"Oura","displayEnabled":true,"connected":true},
          {"source":"whoop","label":"WHOOP","displayEnabled":true,"connected":true}
        ]}
        """))
        XCTAssertEqual(rows.map(\.id), ["oura", "whoop", "google"])
    }

    func testNoWearablesStillShowsGoogle() throws {
        let rows = MoreLogic.connectionRows(status: try status(#"{"googleConnected":false,"wearables":[]}"#))
        XCTAssertEqual(rows, [MoreConnectionRow(id: "google", title: "Google Calendar", isConnected: false, isDisplayed: nil, lastDataDay: nil)])
    }

    func testEmptyStatusShowsGoogleAsNotConnected() throws {
        let rows = MoreLogic.connectionRows(status: try status("{}"))
        XCTAssertEqual(rows.map(\.id), ["google"])
        XCTAssertEqual(rows.first?.isConnected, false)
    }

    func testDisconnectedWearableAndHiddenWearable() throws {
        let rows = MoreLogic.connectionRows(status: try status("""
        {"googleConnected":true,"wearables":[
          {"source":"whoop","label":"WHOOP","displayEnabled":false,"connected":false}
        ]}
        """))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.isConnected, false)
        XCTAssertEqual(rows.first?.isDisplayed, false)
        XCTAssertNil(rows.first?.lastDataDay)
    }

    func testWearableMissingConnectedReadsAsNotConnected() throws {
        let rows = MoreLogic.connectionRows(status: try status(#"{"wearables":[{"source":"oura","label":"Oura"}]}"#))
        XCTAssertEqual(rows.first?.id, "oura")
        XCTAssertEqual(rows.first?.isConnected, false)
    }

    func testGoogleHasNoSwitchAndNoLastDataDay() throws {
        let rows = MoreLogic.connectionRows(status: try status(#"{"googleConnected":true,"wearables":[]}"#))
        let google = try XCTUnwrap(rows.first { $0.id == "google" })
        XCTAssertNil(google.isDisplayed)
        XCTAssertNil(google.lastDataDay)
        XCTAssertTrue(google.isConnected)
    }

    func testRowsFromTheBundledViewFixture() throws {
        let view = try APIFixture.decode(ViewResponse.self, "view-day.json")
        let rows = MoreLogic.connectionRows(status: view.status)
        XCTAssertEqual(rows.count, (view.status?.wearables.count ?? 0) + 1)
        XCTAssertEqual(rows.last?.id, "google")
        XCTAssertEqual(rows.last?.isConnected, true)
        XCTAssertEqual(rows.dropLast().map(\.id), view.status?.wearables.compactMap(\.source))
    }
}

final class MoreVersionLabelTests: XCTestCase {
    func testVersionAndBuild() throws {
        XCTAssertEqual(MoreLogic.versionLabel(version: "1.0", build: "4"), "Version 1.0 (4)")
        XCTAssertEqual(MoreLogic.versionLabel(version: "2.3.1", build: "17"), "Version 2.3.1 (17)")
    }

    func testNoBuild() throws {
        XCTAssertEqual(MoreLogic.versionLabel(version: "1.0", build: nil), "Version 1.0")
        XCTAssertEqual(MoreLogic.versionLabel(version: "1.0", build: ""), "Version 1.0")
    }

    func testNoVersion() throws {
        XCTAssertEqual(MoreLogic.versionLabel(version: nil, build: "4"), "")
        XCTAssertEqual(MoreLogic.versionLabel(version: nil, build: nil), "")
    }
}

final class MoreSourceToggleTests: XCTestCase {
    func testPatchesExactlyOneKey() throws {
        let request = MoreLogic.sourceToggleRequest(source: .oura, enabled: true)
        XCTAssertEqual(request.method, .patch)
        XCTAssertEqual(request.path, "/api/settings/source-display")
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Bool], ["oura": true])
        let off = MoreLogic.sourceToggleRequest(source: .whoop, enabled: false)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(off.body)) as? [String: Bool], ["whoop": false])
        XCTAssertFalse(request.cacheable)
    }
}
