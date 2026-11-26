import Foundation
import XCTest
@testable import MeetspikeHRCore

final class BroadcasterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let strap = UUID()
    private let other = UUID()
    /// A made-up company identifier, standing in for one assigned to WHOOP.
    private let testCompany: UInt16 = 0xABCD

    private func ad(
        _ name: String? = nil, peripheral: String? = nil, data: [UInt8]? = nil, services: [String] = ["180D"]
    ) -> Advertisement {
        Advertisement(
            localName: name, peripheralName: peripheral, manufacturerData: data.map { Data($0) }, serviceUUIDs: services
        )
    }

    // MARK: Advertisement details

    func testDisplayNamePrefersLocalNameThenPeripheralName() {
        XCTAssertEqual(ad("WHOOP 4C1234", peripheral: "Cached").displayName, "WHOOP 4C1234")
        XCTAssertEqual(ad(nil, peripheral: "Cached").displayName, "Cached")
        XCTAssertEqual(ad("", peripheral: nil).displayName, "no name")
        XCTAssertEqual(ad().displayName, "no name")
    }

    func testManufacturerDataCompanyIDIsLittleEndianWithShortHexPrefix() {
        let short = ad(data: [0x4C, 0x00, 0x02, 0x15])
        XCTAssertEqual(short.companyID, 0x004C)
        XCTAssertEqual(short.companyHex, "0x004C")
        XCTAssertEqual(short.manufacturerPrefix, "0215")

        let long = ad(data: [0xCD, 0xAB] + Array(0x00...0x0A))
        XCTAssertEqual(long.companyHex, "0xABCD")
        XCTAssertEqual(long.manufacturerPrefix, "0001020304050607…")

        XCTAssertEqual(ad(data: [0x01, 0x02]).manufacturerPrefix, "")
        XCTAssertNil(ad(data: [0x01]).companyID, "One byte is not a company identifier")
        XCTAssertNil(ad().companyID)
        XCTAssertNil(ad().manufacturerPrefix)
    }

    func testSummaryLine() {
        XCTAssertEqual(
            ad("WHOOP 4C1234", data: [0xCD, 0xAB, 0x0A, 0x0B], services: ["180D", "180A"]).summary,
            "WHOOP 4C1234 · company 0xABCD, data 0A0B · services 180D, 180A"
        )
        XCTAssertEqual(ad(services: []).summary, "no name · no manufacturer data · no services listed")
        XCTAssertEqual(ad(data: [0x6B, 0x00]).summary, "no name · company 0x006B · services 180D")
    }

    func testHeartRateServiceInShortOrFullForm() {
        XCTAssertTrue(ad(services: ["180d"]).advertisesHeartRate)
        XCTAssertTrue(ad(services: ["0000180D-0000-1000-8000-00805F9B34FB"]).advertisesHeartRate)
        XCTAssertFalse(ad(services: ["180F"]).advertisesHeartRate)
        XCTAssertFalse(ad(services: []).advertisesHeartRate)
    }

    // MARK: Matching

    func testNameContainingWhoopInAnyCaseMatches() {
        for name in ["WHOOP 4C1234", "whoop", "My Whoop Strap", "4.0 wHoOp"] {
            XCTAssertTrue(StrapMatch.accepts(id: other, advertisement: ad(name), preferredID: nil), name)
        }
        XCTAssertTrue(StrapMatch.accepts(id: other, advertisement: ad(nil, peripheral: "Whoop"), preferredID: nil))
        XCTAssertFalse(StrapMatch.accepts(id: other, advertisement: ad("Polar H10"), preferredID: nil))
        XCTAssertFalse(StrapMatch.accepts(id: other, advertisement: ad(), preferredID: nil))
        // The name-only matcher used for already-connected peripherals agrees.
        XCTAssertTrue(StrapMatch.accepts(id: other, names: ["My Whoop"], preferredID: nil))
    }

    func testWhoopMustOfferHeartRateServiceUnlessScanWasFiltered() {
        let noService = ad("WHOOP 4C1234", services: [])
        XCTAssertFalse(StrapMatch.accepts(id: other, advertisement: noService, preferredID: nil))
        XCTAssertTrue(StrapMatch.accepts(id: other, advertisement: noService, preferredID: nil, viaHeartRateFilter: true))
    }

    func testCompanyIdentifierMatchesWithoutName() {
        let byCompany = ad(data: [0xCD, 0xAB, 0x01])
        XCTAssertTrue(StrapMatch.accepts(
            id: other, advertisement: byCompany, preferredID: nil, whoopCompanyIDs: [testCompany]
        ))
        XCTAssertFalse(StrapMatch.accepts(
            id: other, advertisement: ad(data: [0x4C, 0x00]), preferredID: nil, whoopCompanyIDs: [testCompany]
        ))
        // No identifier is assigned to WHOOP, Inc. yet, so the default set matches nothing.
        XCTAssertTrue(StrapMatch.whoopCompanyIDs.isEmpty)
        XCTAssertFalse(StrapMatch.accepts(id: other, advertisement: byCompany, preferredID: nil))
    }

    func testRememberedStrapMatchesByIdentifierOnly() {
        XCTAssertTrue(StrapMatch.accepts(id: strap, advertisement: ad(), preferredID: strap))
        XCTAssertTrue(StrapMatch.accepts(id: strap, advertisement: ad(services: []), preferredID: strap))
        XCTAssertFalse(StrapMatch.accepts(id: other, advertisement: ad("WHOOP 4C1234"), preferredID: strap))
    }

    // MARK: Diagnostics

    func testDiagnosticsListEveryBroadcasterAndMergeRepeatDiscoveries() {
        var scan = ScanDiagnostics()
        scan.begin(at: now)
        XCTAssertTrue(scan.record(id: other, advertisement: ad(data: [0x6B, 0x00]), accepted: false))
        XCTAssertFalse(scan.record(id: other, advertisement: ad(data: [0x6B, 0x00]), accepted: false))
        // A scan response adds the name later.
        XCTAssertTrue(scan.record(id: other, advertisement: ad("Polar H10", services: ["180D", "180F"]), accepted: false))
        XCTAssertEqual(scan.broadcasters.count, 1)
        XCTAssertEqual(scan.broadcasterLines, ["Polar H10 · company 0x006B · services 180D, 180F"])

        scan.record(id: strap, advertisement: ad(), accepted: true)
        XCTAssertEqual(scan.broadcasterLines.count, 2)
        XCTAssertEqual(scan.whoopBroadcasters, [strap])
    }

    func testLateNameMakesBroadcasterAWhoop() {
        var scan = ScanDiagnostics()
        scan.begin(at: now)
        scan.record(id: other, advertisement: ad(), accepted: false)
        XCTAssertTrue(scan.whoopBroadcasters.isEmpty)
        scan.record(id: other, advertisement: ad("WHOOP 4C1234"), accepted: false)
        XCTAssertEqual(scan.whoopBroadcasters, [other])
        XCTAssertEqual(scan.otherWhoops, [other])
    }

    func testManualCandidateOnlyForExactlyOneUnknownBroadcasterAfterTimeout() {
        var scan = ScanDiagnostics()
        scan.begin(at: now)
        scan.record(id: other, advertisement: ad(), accepted: false)
        XCTAssertNil(scan.manualCandidate(now: now.addingTimeInterval(5)), "Too early")
        let later = now.addingTimeInterval(ScanDiagnostics.noWhoopAfter)
        XCTAssertEqual(scan.manualCandidate(now: later)?.id, other)

        var two = scan
        two.record(id: UUID(), advertisement: ad("Polar H10"), accepted: false)
        XCTAssertNil(two.manualCandidate(now: later), "Two unknown broadcasters")

        var whoop = scan
        whoop.record(id: strap, advertisement: ad("WHOOP"), accepted: false)
        XCTAssertNil(whoop.manualCandidate(now: later), "A WHOOP was heard")

        XCTAssertNil(ScanDiagnostics().manualCandidate(now: later), "No scan")
    }

    // MARK: Menu status

    func testNoWhoopStatusListsBroadcastersAndOffersUseThisBroadcaster() {
        var scan = ScanDiagnostics()
        scan.begin(at: now.addingTimeInterval(-30))
        scan.record(id: other, advertisement: ad(data: [0x6B, 0x00, 0x01]), accepted: false)
        let status = MenuStatus(HRSnapshot(status: .searching, scan: scan, now: now))
        XCTAssertEqual(status.headline, "No WHOOP broadcast found — check HR Broadcast")
        XCTAssertEqual(status.diagnostics, "Heard 1 heart rate broadcaster, none from a WHOOP.")
        XCTAssertEqual(status.broadcasters, ["no name · company 0x006B, data 01 · services 180D"])
        XCTAssertEqual(status.action, .useBroadcaster(other))
        XCTAssertEqual(status.actionTitle, "Use this broadcaster (no name)")
        XCTAssertTrue(status.detail?.contains("Use this broadcaster") ?? false)
    }

    func testScanningStatusListsBroadcastersWithoutOfferingEarly() {
        var scan = ScanDiagnostics()
        scan.begin(at: now.addingTimeInterval(-3))
        scan.record(id: other, advertisement: ad("Polar H10"), accepted: false)
        let status = MenuStatus(HRSnapshot(status: .searching, scan: scan, now: now))
        XCTAssertEqual(status.headline, "Scanning for WHOOP…")
        XCTAssertEqual(status.broadcasters, ["Polar H10 · no manufacturer data · services 180D"])
        XCTAssertNil(status.action)
    }

    func testTwoUnknownBroadcastersGetNoButton() {
        var scan = ScanDiagnostics()
        scan.begin(at: now.addingTimeInterval(-30))
        scan.record(id: other, advertisement: ad("Polar H10"), accepted: false)
        scan.record(id: UUID(), advertisement: ad(), accepted: false)
        let status = MenuStatus(HRSnapshot(status: .searching, scan: scan, now: now))
        XCTAssertEqual(status.headline, "No WHOOP broadcast found — check HR Broadcast")
        XCTAssertEqual(status.broadcasters.count, 2)
        XCTAssertNil(status.action)
        XCTAssertFalse(status.detail?.contains("Use this broadcaster") ?? true)
    }
}
