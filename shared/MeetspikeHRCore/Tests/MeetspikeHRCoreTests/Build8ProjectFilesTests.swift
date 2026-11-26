import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8, track `app`, D12 + D13 + D14 + the version bump, as far as a file read can check them. These read the
// repo's ios/ files by path from this test file's location (shared/MeetspikeHRCore/Tests/MeetspikeHRCoreTests), so
// they only run inside a full checkout; in a copy of the package without ios/ they skip, loudly.
//
// What a file read cannot check (UI looks, the MetricKit wiring, the release run itself) is in the hand-off list.

final class Build8ProjectFilesTests: XCTestCase {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func read(_ path: String) throws -> String {
        let url = repoRoot.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("ios/MeetspikeHR").path) {
                XCTFail("missing \(path)")
            } else {
                throw XCTSkip("no ios/ folder next to this package: \(repoRoot.path)")
            }
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let text = try read(path)
        let object = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
        return try XCTUnwrap(object as? [String: Any], path)
    }

    // MARK: Version

    func testVersionAndBuildAreBumped() throws {
        // Build 8 shipped as 1.1 (8). The project must never be behind it, and must match the newest release note.
        let yml = try read("ios/MeetspikeHR/project.yml")
        let newest = try XCTUnwrap(ReleaseNotes.all.first)
        XCTAssertGreaterThanOrEqual(newest.build, 8)
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"\(newest.version)\""), "MARKETING_VERSION must be \"\(newest.version)\"")
        XCTAssertTrue(yml.contains("CURRENT_PROJECT_VERSION: \"\(newest.build)\""), "CURRENT_PROJECT_VERSION must be \"\(newest.build)\"")
    }

    func testTheNewestReleaseNoteIsTheBuildBeingShipped() throws {
        let yml = try read("ios/MeetspikeHR/project.yml")
        let release = try XCTUnwrap(ReleaseNotes.all.first)
        XCTAssertGreaterThanOrEqual(release.build, 8)
        XCTAssertTrue(yml.contains("CURRENT_PROJECT_VERSION: \"\(release.build)\""))
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"\(release.version)\""))
    }

    // MARK: D12 dark only

    func testInfoPlistForcesDark() throws {
        let info = try plist("ios/MeetspikeHR/Info.plist")
        XCTAssertEqual(info["UIUserInterfaceStyle"] as? String, "Dark")
    }

    func testThemeFilesHaveOneColorEachNotALightAndADarkBranch() throws {
        for path in ["ios/MeetspikeHR/Sources/Theme.swift", "ios/MeetspikeHR/Sources/Today/TodayComponents.swift"] {
            let text = try read(path)
            XCTAssertFalse(text.contains("light:"), "\(path) still has a light branch")
            XCTAssertFalse(text.contains("userInterfaceStyle"), "\(path) still switches on the interface style")
        }
    }

    func testRootPrefersDark() throws {
        let app = try read("ios/MeetspikeHR/Sources/MeetspikeHRApp.swift")
        let tabs = try read("ios/MeetspikeHR/Sources/App/RootTabView.swift")
        XCTAssertTrue((app + tabs).contains(".preferredColorScheme(.dark)"))
    }

    // MARK: D13 privacy manifest

    func testPrivacyManifestDeclaresCrashPerformanceAndOtherDiagnosticData() throws {
        let manifest = try plist("ios/MeetspikeHR/Resources/PrivacyInfo.xcprivacy")
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        let collected = try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        var byType: [String: [String: Any]] = [:]
        for entry in collected { if let type = entry["NSPrivacyCollectedDataType"] as? String { byType[type] = entry } }
        for type in ["NSPrivacyCollectedDataTypeHealth", "NSPrivacyCollectedDataTypeCrashData",
                     "NSPrivacyCollectedDataTypePerformanceData", "NSPrivacyCollectedDataTypeOtherDiagnosticData"] {
            let entry = try XCTUnwrap(byType[type], "missing \(type)")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                           ["NSPrivacyCollectedDataTypePurposeAppFunctionality"], type)
        }
        XCTAssertNotNil(manifest["NSPrivacyAccessedAPITypes"], "the existing UserDefaults declaration stays")
    }

    // MARK: D14 scripts (existence and the key moves only; the release run is a manual check)

    func testReleaseScriptKeepsDSYMsAndSetsWhatToTest() throws {
        let script = try read("ios/release-testflight.py")
        XCTAssertTrue(script.contains("dSYMs"), "no dSYM keeping")
        XCTAssertTrue(script.contains("Application Support/Meetspike"), "dSYMs go under ~/Library/Application Support/Meetspike")
        XCTAssertTrue(script.contains("betaBuildLocalizations"), "no What to Test call")
        XCTAssertTrue(script.contains("whatsNew"), "no whatsNew field")
        XCTAssertTrue(script.contains("ReleaseNotes.swift"), "the notes come from ReleaseNotes.swift, the single source")
    }

    func testCrashReportsScriptExists() throws {
        let script = try read("ios/crash-reports.py")
        XCTAssertTrue(script.contains("--show"))
        XCTAssertTrue(script.contains("atos"))
        XCTAssertTrue(script.contains("/api/whoop-web/app/diagnostics"))
        XCTAssertTrue(script.contains("MeetspikeHR"))
        XCTAssertTrue(script.contains("dSYMs"))
    }
}
