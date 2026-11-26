import Foundation
import XCTest
@testable import MeetspikeHRCore

final class SetupStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let strap = UUID()
    private let other = UUID()

    private func snapshot(
        _ status: BluetoothStatus, permission: BluetoothPermission = .allowed, scan: ScanDiagnostics = ScanDiagnostics(),
        bpm: Int? = nil, secondsAgo: TimeInterval = 0, fromConnection: Bool = true, setupComplete: Bool = false,
        uploaded: Date? = nil, uploadProblem: String? = nil
    ) -> HRSnapshot {
        HRSnapshot(
            status: status, permission: permission, scan: scan, latestBPM: bpm,
            latestReadingAt: bpm == nil ? nil : now.addingTimeInterval(-secondsAgo),
            readingIsFromConnection: fromConnection, setupComplete: setupComplete,
            lastSuccessfulUpload: uploaded, uploadProblem: uploadProblem, now: now
        )
    }

    private func scan(startedSecondsAgo: TimeInterval, _ seen: [(UUID, [String], Bool)] = []) -> ScanDiagnostics {
        var scan = ScanDiagnostics()
        scan.begin(at: now.addingTimeInterval(-startedSecondsAgo))
        for (id, names, accepted) in seen { scan.record(id: id, names: names, accepted: accepted) }
        return scan
    }

    // MARK: Menu bar icon

    func testIconShowsFilledHeartAndBPMForFreshReading() {
        let icon = MenuBarIcon(snapshot(.connected, bpm: 72, secondsAgo: 1))
        XCTAssertEqual(icon.style, .live)
        XCTAssertEqual(icon.symbol, "heart.fill")
        XCTAssertEqual(icon.text, "72")
        XCTAssertEqual(icon.accessibilityLabel, "Meetspike HR, 72 beats per minute")
    }

    func testIconShowsOutlineHeartAndDashWithoutCurrentReading() {
        let cases = [
            snapshot(.searching),
            snapshot(.connected, bpm: 72, secondsAgo: 45),
            snapshot(.reconnecting, bpm: 72, secondsAgo: 2),
            snapshot(.connected, bpm: 72, secondsAgo: 2, fromConnection: false)
        ]
        for value in cases {
            let icon = MenuBarIcon(value)
            XCTAssertEqual(icon.style, .waiting, "\(value.status)")
            XCTAssertEqual(icon.symbol, "heart")
            XCTAssertEqual(icon.text, "–")
        }
    }

    func testIconHasDistinctPausedAndBlockedStates() {
        let paused = MenuBarIcon(snapshot(.paused, bpm: 72, secondsAgo: 1))
        XCTAssertEqual(paused.style, .paused)
        XCTAssertEqual(paused.symbol, "pause.circle.fill")
        XCTAssertEqual(paused.text, "")

        for value in [snapshot(.unauthorized), snapshot(.poweredOff), snapshot(.waiting, permission: .denied)] {
            let icon = MenuBarIcon(value)
            XCTAssertEqual(icon.style, .blocked)
            XCTAssertEqual(icon.symbol, "heart.slash")
            XCTAssertEqual(icon.text, "–")
        }
        XCTAssertEqual(Set([paused.symbol, MenuBarIcon(snapshot(.searching)).symbol]).count, 2)
    }

    func testIconAlwaysHasASymbolAndOnlyLiveOrPausedIsFullStrength() {
        let cases: [(HRSnapshot, MenuBarIcon.Style, Bool)] = [
            (snapshot(.connected, bpm: 72, secondsAgo: 1), .live, false),
            (snapshot(.searching), .waiting, true),
            (snapshot(.unauthorized), .blocked, true),
            (snapshot(.paused), .paused, false)
        ]
        for (value, style, dimmed) in cases {
            let icon = MenuBarIcon(value)
            XCTAssertEqual(icon.style, style)
            XCTAssertEqual(icon.isDimmed, dimmed, "\(style)")
            XCTAssertFalse(icon.symbol.isEmpty, "The heart or pause symbol must always be drawn")
            XCTAssertTrue(icon.accessibilityLabel.hasPrefix("Meetspike HR, "))
        }
    }

    // MARK: Menu status text

    func testBluetoothNotAllowedOffersPrivacySettings() {
        for value in [snapshot(.unauthorized), snapshot(.starting, permission: .denied)] {
            let status = MenuStatus(value)
            XCTAssertEqual(status.headline, "Bluetooth not allowed — open System Settings")
            XCTAssertEqual(status.action, .openSettings(.bluetoothPrivacy))
            XCTAssertNotNil(status.actionTitle)
            XCTAssertTrue(status.isProblem)
        }
        XCTAssertEqual(
            SystemSettingsLink.bluetoothPrivacy.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        )
    }

    func testBluetoothOffAndPermissionPrompt() {
        let off = MenuStatus(snapshot(.poweredOff))
        XCTAssertEqual(off.headline, "Bluetooth is off — turn it on")
        XCTAssertEqual(off.action, .openSettings(.bluetooth))

        let asking = MenuStatus(snapshot(.starting, permission: .notDetermined))
        XCTAssertEqual(asking.headline, "Waiting for Bluetooth permission")
        XCTAssertFalse(asking.isProblem)
    }

    func testScanningThenNoBroadcastAfterThreshold() {
        let early = MenuStatus(snapshot(.searching, scan: scan(startedSecondsAgo: 5)))
        XCTAssertEqual(early.headline, "Scanning for WHOOP…")
        XCTAssertEqual(early.diagnostics, "No heart rate broadcasts heard yet.")
        XCTAssertFalse(early.isProblem)

        let late = MenuStatus(snapshot(.searching, scan: scan(startedSecondsAgo: ScanDiagnostics.noWhoopAfter, [
            (UUID(), ["Polar H10"], false)
        ])))
        XCTAssertEqual(late.headline, "No WHOOP broadcast found — check HR Broadcast")
        XCTAssertEqual(late.diagnostics, "Heard 1 heart rate broadcaster, none from a WHOOP.")
        XCTAssertTrue(late.detail?.contains("Menu → Device Settings → HR Broadcast") ?? false)
        XCTAssertTrue(late.isProblem)
    }

    func testOtherWhoopIsReportedWhileScanning() {
        let status = MenuStatus(snapshot(.searching, scan: scan(startedSecondsAgo: 3, [(other, ["WHOOP 4C1234"], false)])))
        XCTAssertEqual(status.headline, "Found a WHOOP, but not your remembered strap")
        XCTAssertEqual(status.diagnostics, "Heard 1 heart rate broadcaster, including a WHOOP that is not your remembered strap.")
    }

    func testConnectedAndPausedText() {
        XCTAssertEqual(MenuStatus(snapshot(.connecting)).headline, "WHOOP found — connecting…")
        XCTAssertEqual(MenuStatus(snapshot(.connected, bpm: 70, secondsAgo: 1)).headline, "Receiving heart rate")
        XCTAssertEqual(MenuStatus(snapshot(.connected)).headline, "Connected — waiting for heart rate")
        XCTAssertEqual(MenuStatus(snapshot(.paused)).headline, "Paused")
        XCTAssertEqual(MenuStatus(snapshot(.paused, permission: .denied)).headline, "Paused")
        XCTAssertEqual(MenuStatus(snapshot(.reconnecting)).headline, "Lost the WHOOP — trying again…")
    }

    // MARK: Scan diagnostics

    func testScanDiagnosticsCountsUniqueBroadcasters() {
        var diagnostics = ScanDiagnostics()
        XCTAssertFalse(diagnostics.noWhoopHeard(now: now), "No scan has started")
        diagnostics.begin(at: now)
        let polar = UUID()
        XCTAssertTrue(diagnostics.record(id: polar, names: ["Polar"], accepted: false))
        XCTAssertFalse(diagnostics.record(id: polar, names: ["Polar"], accepted: false), "Repeat discovery is not new")
        XCTAssertTrue(diagnostics.record(id: strap, names: [], accepted: true), "A remembered strap counts without a name")
        XCTAssertEqual(diagnostics.heartRateBroadcasters.count, 2)
        XCTAssertEqual(diagnostics.whoopBroadcasters, [strap])
        XCTAssertEqual(diagnostics.summary, "Heard 2 heart rate broadcasters, including 1 WHOOP.")

        diagnostics.begin(at: now)
        XCTAssertEqual(diagnostics.heartRateBroadcasters.count, 0, "A new scan starts fresh")
        diagnostics.record(id: strap, names: ["WHOOP"], accepted: true)
        XCTAssertEqual(diagnostics.summary, "Heard 1 WHOOP.")
        XCTAssertFalse(diagnostics.noWhoopHeard(now: now.addingTimeInterval(60)))
    }

    // MARK: Walkthrough

    func testWalkthroughShowsUntilFirstReading() {
        XCTAssertTrue(Walkthrough.showsAtLaunch(setupComplete: false))
        XCTAssertFalse(Walkthrough.showsAtLaunch(setupComplete: true))
        XCTAssertFalse(Walkthrough.isFinished(snapshot(.connected)))
        XCTAssertTrue(Walkthrough.isFinished(snapshot(.connected, bpm: 61, secondsAgo: 1)))
        XCTAssertTrue(Walkthrough.isFinished(snapshot(.searching, setupComplete: true)))
    }

    func testWalkthroughCoversEverySetupPoint() {
        let text = Walkthrough.steps.map { "\($0.title) \($0.detail)" }.joined(separator: "\n")
        for phrase in [
            "Wear", "Menu → Device Settings → HR Broadcast", "firmware update", "WHOOP app connected", "Peloton",
            "Zwift", "one listener at a time", "Do NOT put the strap in pairing mode",
            "do NOT add it in the Mac's Bluetooth settings", "Forget This Device", "click Allow"
        ] {
            XCTAssertTrue(text.contains(phrase), phrase)
        }
        XCTAssertEqual(Walkthrough.steps.filter(\.isWarning).map(\.id), ["nopair"])
        XCTAssertEqual(Set(Walkthrough.steps.map(\.id)).count, Walkthrough.steps.count)
    }

    func testChecksBeforeAnythingHappens() {
        let checks = SetupCheck.all(snapshot(.starting, permission: .notDetermined))
        XCTAssertEqual(checks.map(\.kind), [.bluetoothPermission, .scanning, .strapFound, .firstReading, .lastUpload])
        XCTAssertEqual(checks.map(\.state), [.inProgress, .waiting, .waiting, .waiting, .waiting])
    }

    func testChecksWhenPermissionDenied() {
        let checks = SetupCheck.all(snapshot(.unauthorized, permission: .denied))
        XCTAssertEqual(checks[0].state, .problem)
        XCTAssertEqual(checks[1].state, .waiting)
    }

    func testChecksWhileScanningAndAfterNoBroadcast() {
        let scanning = SetupCheck.all(snapshot(.searching, scan: scan(startedSecondsAgo: 2)))
        XCTAssertEqual(scanning.map(\.state), [.done, .inProgress, .waiting, .waiting, .waiting])

        let missing = SetupCheck.all(snapshot(.searching, scan: scan(startedSecondsAgo: 30)))
        XCTAssertEqual(missing[2].state, .problem)
        XCTAssertTrue(missing[2].detail.contains("HR Broadcast"))
    }

    func testChecksWhenConnectedReadingAndUploaded() {
        let connected = SetupCheck.all(snapshot(.connected))
        XCTAssertEqual(connected.map(\.state), [.done, .done, .done, .inProgress, .waiting])

        let live = SetupCheck.all(snapshot(.connected, bpm: 64, secondsAgo: 1, uploaded: now.addingTimeInterval(-180)))
        XCTAssertEqual(live.map(\.state), [.done, .done, .done, .done, .done])
        XCTAssertEqual(live[3].detail, "64 bpm")
        XCTAssertEqual(live[4].detail, "Uploaded 3 minutes ago")
    }

    func testChecksReportUploadProblemAndPause() {
        let failing = SetupCheck.all(snapshot(.connected, bpm: 64, secondsAgo: 1, uploadProblem: "HTTP 401. Will retry."))
        XCTAssertEqual(failing[4].state, .problem)
        XCTAssertEqual(failing[4].detail, "HTTP 401. Will retry.")

        let paused = SetupCheck.all(snapshot(.paused, setupComplete: true))
        XCTAssertEqual(paused[1].state, .waiting)
        XCTAssertEqual(paused[3].state, .done)
        XCTAssertEqual(paused[3].detail, "Received before")
    }

    func testUploadTimeWording() {
        XCTAssertEqual(SetupCheck.uploadTime(now, now: now), "just now")
        XCTAssertEqual(SetupCheck.uploadTime(now.addingTimeInterval(-60), now: now), "1 minute ago")
        XCTAssertEqual(SetupCheck.uploadTime(now.addingTimeInterval(-7_200), now: now), "2 hours ago")
    }
}
