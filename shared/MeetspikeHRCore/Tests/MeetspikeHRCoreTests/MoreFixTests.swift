import Foundation
import XCTest
@testable import MeetspikeHRCore

// More track fix pass: dayLabel, connectionDetail, setupURL (origin safety), askKeyStatus, syncMessage, refresh posting.
// Handoff copy: the hook did not let the more track create Tests/MeetspikeHRCoreTests/MoreFixTests.swift. Move this file there.

final class MoreFixTests: XCTestCase {
    private func part(_ json: String) throws -> RefreshPart { try MobileJSON.decode(RefreshPart.self, json) }
    private func status(_ json: String) throws -> ViewStatus { try MobileJSON.decode(ViewStatus.self, json) }
    private func ask(_ json: String) throws -> AskStatus { try MobileJSON.decode(AskStatus.self, json) }

    // MARK: dayLabel

    func testDayLabel() {
        XCTAssertEqual(MoreLogic.dayLabel("2026-11-24"), "Tue, Nov 24")
        XCTAssertEqual(MoreLogic.dayLabel("2026-01-02"), "Fri, Jan 2")
        XCTAssertEqual(MoreLogic.dayLabel("not a day"), "not a day")
    }

    // MARK: connectionDetail

    func testConnectionDetail() throws {
        let st = try status("""
        {"googleConnected":true,"wearables":[
          {"source":"whoop","label":"WHOOP","connected":true,"lastDataDay":"2026-11-24","history":{"min":"2026-01-02","max":"2026-11-24"}},
          {"source":"oura","label":"Oura","connected":true}
        ]}
        """)
        let rows = MoreLogic.connectionRows(status: st)
        XCTAssertEqual(
            MoreLogic.connectionDetail(for: rows[0], status: st),
            "Last data Tue, Nov 24 \u{B7} History 2026-01-02 to 2026-11-24")
        XCTAssertEqual(MoreLogic.connectionDetail(for: rows[1], status: st), "No data yet")
        XCTAssertEqual(MoreLogic.connectionDetail(for: rows[2], status: st), "Read-only")
        XCTAssertEqual(MoreLogic.connectionDetail(for: rows[2], status: nil), "Read-only")
    }

    func testConnectionDetailHistoryWithoutLastDay() throws {
        let st = try status(#"{"wearables":[{"source":"oura","label":"Oura","connected":true,"history":{"min":"2026-02-01","max":"2026-11-23"}}]}"#)
        let row = MoreConnectionRow(id: "oura", title: "Oura", isConnected: true, isDisplayed: true, lastDataDay: nil)
        XCTAssertEqual(MoreLogic.connectionDetail(for: row, status: st), "History 2026-02-01 to 2026-11-23")
    }

    // MARK: setupURL

    func testSetupURLOnTheWorkerOrigin() throws {
        let origin = try XCTUnwrap(URL(string: "https://meetspike.example.workers.dev"))
        XCTAssertEqual(MoreLogic.setupURL(origin: origin, rowID: "oura")?.absoluteString, "https://meetspike.example.workers.dev/setup?wearable=oura")
        XCTAssertEqual(MoreLogic.setupURL(origin: origin, rowID: "google")?.absoluteString, "https://meetspike.example.workers.dev/setup")
        XCTAssertEqual(MoreLogic.setupURL(origin: origin, rowID: "")?.absoluteString, "https://meetspike.example.workers.dev/setup")
    }

    func testSetupURLDropsPathCredentialsAndFragment() throws {
        let origin = try XCTUnwrap(URL(string: "https://user:pw@meetspike.example.workers.dev:8443/api/x?y=1#frag"))
        let url = try XCTUnwrap(MoreLogic.setupURL(origin: origin, rowID: "whoop"))
        XCTAssertEqual(url.absoluteString, "https://meetspike.example.workers.dev:8443/setup?wearable=whoop")
        XCTAssertEqual(url.host, "meetspike.example.workers.dev")
    }

    func testSetupURLRejectsNonHTTPSOrigins() throws {
        for raw in ["http://meetspike.example.workers.dev", "javascript:alert(1)", "file:///etc/passwd", "tel:5551234", "meetspike.example.workers.dev", "https://", "ftp://meetspike.example.workers.dev"] {
            guard let origin = URL(string: raw) else { continue }
            XCTAssertNil(MoreLogic.setupURL(origin: origin, rowID: "oura"), raw)
            XCTAssertNil(MoreLogic.setupURL(origin: origin, rowID: "google"), raw)
        }
    }

    func testSetupURLRejectsRowIDsThatCouldLeaveTheOrigin() throws {
        let origin = try XCTUnwrap(URL(string: "https://meetspike.example.workers.dev"))
        for id in ["oura&next=https://evil.example", "a/b", "oura#x", "oura?x=1", "../x", "o ura", "https://evil.example"] {
            XCTAssertNil(MoreLogic.setupURL(origin: origin, rowID: id), id)
        }
    }

    // MARK: askKeyStatus

    func testAskKeyStatus() throws {
        let saved = MoreLogic.askKeyStatus(try ask(#"{"available":true,"connected":true,"tail":"a1b2"}"#))
        XCTAssertEqual(saved.text, "Key \u{2026}a1b2")
        XCTAssertTrue(saved.isSet)
        XCTAssertEqual(MoreLogic.askKeyStatus(try ask(#"{"connected":true}"#)).text, "Key set")
        XCTAssertEqual(MoreLogic.askKeyStatus(try ask(#"{"available":true,"connected":false}"#)).text, "Add key")
        XCTAssertEqual(MoreLogic.askKeyStatus(nil).text, "Add key")
        let notSetUp = MoreLogic.askKeyStatus(try ask(#"{"available":false,"connected":false}"#))
        XCTAssertEqual(notSetUp.text, "Not set up")
        XCTAssertFalse(notSetUp.isSet)
    }

    // MARK: syncMessage

    func testSyncedCountsWrittenPlusRemoved() throws {
        let r = RefreshResult(calendar: try part(#"{"ok":true,"written":3,"removed":2}"#))
        XCTAssertEqual(MoreLogic.syncMessage(r), "Synced just now. 5 meetings updated.")
    }

    func testSyncedSingularAndZero() throws {
        XCTAssertEqual(
            MoreLogic.syncMessage(RefreshResult(calendar: try part(#"{"ok":true,"written":1}"#))),
            "Synced just now. 1 meeting updated.")
        XCTAssertEqual(
            MoreLogic.syncMessage(RefreshResult(calendar: try part(#"{"ok":true,"written":1,"removed":0}"#))),
            "Synced just now. 1 meeting updated.")
        XCTAssertEqual(
            MoreLogic.syncMessage(RefreshResult(calendar: try part(#"{"ok":true}"#))),
            "Synced just now. 0 meetings updated.")
        XCTAssertEqual(MoreLogic.syncMessage(RefreshResult()), "Synced just now. 0 meetings updated.")
    }

    func testSyncStillSyncing() throws {
        let r = RefreshResult(calendar: try part(#"{"ok":true,"pending":true,"written":4}"#))
        XCTAssertEqual(MoreLogic.syncMessage(r), "Still syncing in the background. New meetings show up when it finishes.")
    }

    func testSyncNeedsGoogleAndCalendarError() throws {
        XCTAssertEqual(MoreLogic.syncMessage(RefreshResult(needsGoogle: true)), "Connect Google Calendar to sync meetings.")
        let failed = RefreshResult(calendar: try part(#"{"ok":false,"error":"HTTP 500"}"#))
        XCTAssertEqual(MoreLogic.syncMessage(failed), "Calendar sync failed: HTTP 500")
    }

    func testSyncWearableFailureNotesFollowShowData() throws {
        let r = RefreshResult(
            calendar: try part(#"{"ok":true,"written":2}"#),
            whoop: try part(#"{"ok":false}"#), oura: try part(#"{"ok":false}"#))
        XCTAssertEqual(MoreLogic.syncMessage(r), "Synced just now. 2 meetings updated. WHOOP did not refresh. Oura did not refresh.")
        XCTAssertEqual(MoreLogic.syncMessage(r, showWhoop: false, showOura: true), "Synced just now. 2 meetings updated. Oura did not refresh.")
        XCTAssertEqual(MoreLogic.syncMessage(r, showWhoop: false, showOura: false), "Synced just now. 2 meetings updated.")
    }

    // MARK: dataRefreshed posting

    func testDataRefreshedStillPostsWhenAWearableRefreshedWithoutGoogle() throws {
        let wearableOnly = RefreshResult(
            calendar: try part(#"{"ok":false,"needsGoogle":true}"#),
            whoop: try part(#"{"ok":true}"#), needsGoogle: true)
        XCTAssertTrue(MoreLogic.shouldPostDataRefreshed(wearableOnly))
        let nothing = RefreshResult(
            calendar: try part(#"{"ok":false,"needsGoogle":true}"#),
            oura: try part(#"{"ok":false}"#), needsGoogle: true)
        XCTAssertFalse(MoreLogic.shouldPostDataRefreshed(nothing))
        XCTAssertTrue(MoreLogic.shouldPostDataRefreshed(RefreshResult(calendar: try part(#"{"ok":true}"#))))
    }
}
