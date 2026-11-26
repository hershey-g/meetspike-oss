import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9: the leftovers from the build 8 reviews, plus the version bump.
//
// Everything in this file compiles against today's API and fails on its assertions until build 9 is written.
//
//   L1 DiagnosticQueue.add returns false when its own trim removed the new report (it is older than everything
//      kept, so it was the one dropped). True only when the report is on disk after the trim.
//   L2 The exit report's version is also read from the payload root `appVersion`, when metaData has none.
//      When both exist, metaData wins over the payload root.
//   L3 MetricKit `jsonRepresentation()` runs inside DiagnosticStack (a payload can be 300 levels deep).
//      Read from ios/MeetspikeHR/Sources/Diagnostics/DiagnosticsService.swift.
//   L4 ios/capture-screenshots.py takes the dark pass only.
//   V  Version 1.2 (9): MARKETING_VERSION "1.2" and CURRENT_PROJECT_VERSION "9" in ios/MeetspikeHR/project.yml, and
//      the newest release note is that build.
//
// Not testable here, by design of the package: "live crash delivery is handled before past payloads so crumbs aren't
// lost" (the order of two MetricKit callbacks in the app target; the pure decision, `DiagnosticPolicy.attachCrumbs`,
// is unchanged and already covered by the Build 8 tests).

// MARK: L1

final class Build9QueueTrimTests: XCTestCase {
    private func queue(maxFiles: Int, _ name: String = "queue-trim") throws -> DiagnosticQueue {
        DiagnosticQueue(directory: try B9.tempDirectory(self, name), maxFiles: maxFiles)
    }

    func testAnOlderReportThanEverythingKeptIsTheOneTrimmedAndAddSaysFalse() throws {
        let queue = try queue(maxFiles: 2)
        XCTAssertTrue(queue.add(B8.report(10)))
        XCTAssertTrue(queue.add(B8.report(20)))
        let tooOld = B8.report(5)
        XCTAssertFalse(queue.add(tooOld), "it was written and then trimmed away: it is not on disk")
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(10).id, B8.report(20).id])
        XCTAssertFalse(queue.pendingIDs().contains(tooOld.id))
    }

    func testANewerReportIsKeptAndPushesOutTheOldest() throws {
        let queue = try queue(maxFiles: 2)
        XCTAssertTrue(queue.add(B8.report(10)))
        XCTAssertTrue(queue.add(B8.report(20)))
        XCTAssertTrue(queue.add(B8.report(30)))
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(20).id, B8.report(30).id])
    }

    func testAReportBetweenTheOthersIsKept() throws {
        let queue = try queue(maxFiles: 2)
        XCTAssertTrue(queue.add(B8.report(10)))
        XCTAssertTrue(queue.add(B8.report(30)))
        XCTAssertTrue(queue.add(B8.report(20)), "newer than 10, so 10 goes")
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(20).id, B8.report(30).id])
    }

    func testAQueueOfOneKeepsTheNewestAndRefusesAnOlderOne() throws {
        let queue = try queue(maxFiles: 1)
        XCTAssertTrue(queue.add(B8.report(20)))
        XCTAssertFalse(queue.add(B8.report(10)))
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(20).id], "the kept one is not disturbed")
        XCTAssertTrue(queue.add(B8.report(30)))
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(30).id])
    }

    func testAnOlderReportIsAcceptedWhileThereIsRoom() throws {
        let queue = try queue(maxFiles: 3)
        XCTAssertTrue(queue.add(B8.report(20)))
        XCTAssertTrue(queue.add(B8.report(10)), "the queue is not full, nothing is trimmed")
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(10).id, B8.report(20).id])
    }

    func testTwoReportsAtTheSameTimeTrimByIDAndTheAnswerAgrees() throws {
        // Ties sort by id, so the lower id is "older". Whichever one is trimmed, add says so.
        let queue = try queue(maxFiles: 1)
        let low = B8.report(1, at: 50)
        let high = B8.report(2, at: 50)
        XCTAssertTrue(queue.add(high))
        XCTAssertFalse(queue.add(low), "same time, lower id sorts first, so it is the one dropped")
        XCTAssertEqual(queue.pending().map(\.id), [high.id])
    }

    func testAddingTheSameReportAgainWhileItIsKeptStaysTrue() throws {
        let queue = try queue(maxFiles: 2)
        XCTAssertTrue(queue.add(B8.report(10)))
        XCTAssertTrue(queue.add(B8.report(10)))
        XCTAssertEqual(queue.pending().count, 1)
    }

    func testTheAnswerMatchesWhatIsOnDiskForEveryOrder() throws {
        // Add 6 reports in a scrambled order to a queue of 3. For each add, the answer is true exactly when that report
        // is still pending afterwards.
        let queue = try queue(maxFiles: 3)
        for n in [40, 10, 60, 20, 50, 30] {
            let report = B8.report(n)
            let saved = queue.add(report)
            XCTAssertEqual(saved, queue.pendingIDs().contains(report.id), "report \(n)")
        }
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(40).id, B8.report(50).id, B8.report(60).id])
    }
}

// MARK: L2

final class Build9ExitVersionTests: XCTestCase {
    private let running = DiagnosticReportBuilder.Running(build: 9, version: "1.2", os: "iPhone OS 26.2", device: "iPhone17,1")
    private let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000e9")!

    private func payload(root: String, meta: String) -> Data {
        Data("""
        {
          "timeStampBegin": "2026-11-24 05:00:00 +0000",
          "timeStampEnd": "2026-11-25 05:00:00 +0000",
          \(root)
          "metaData": { \(meta) },
          "applicationExitMetrics": {
            "foregroundExitData": { "cumulativeNormalAppExitCount": 4, "cumulativeAppWatchdogExitCount": 2 },
            "backgroundExitData": { "cumulativeNormalAppExitCount": 9 }
          }
        }
        """.utf8)
    }

    private func exit(_ json: Data) throws -> DiagnosticReport {
        try XCTUnwrap(DiagnosticReportBuilder.exits(json: json, id: id, at: B8.date(0), now: B8.date(100), running: running))
    }

    func testTheVersionAtThePayloadRootIsUsed() throws {
        let json = payload(root: #""appVersion": "1.1","#,
                           meta: #""appBuildVersion": "8", "osVersion": "iPhone OS 26.1 (23B85)", "deviceType": "iPhone16,2""#)
        let report = try exit(json)
        XCTAssertEqual(report.version, "1.1", "the build that crashed, not the one running now (1.2)")
        XCTAssertEqual(report.build, 8)
        XCTAssertEqual(report.os, "iPhone OS 26.1 (23B85)")
        XCTAssertEqual(report.device, "iPhone16,2")
        XCTAssertEqual(report.kind, .exit)
    }

    func testTheRootVersionIsUsedWhenThereIsNoMetaDataAtAll() throws {
        let json = Data(#"""
        {"appVersion": "1.0", "applicationExitMetrics": {"foregroundExitData": {"cumulativeAppWatchdogExitCount": 1}, "backgroundExitData": {}}}
        """#.utf8)
        XCTAssertEqual(try exit(json).version, "1.0")
    }

    func testMetaDataWinsOverTheRootVersionWhenBothExist() throws {
        let json = payload(root: #""appVersion": "1.0","#, meta: #""appBuildVersion": "8", "appVersion": "1.1""#)
        XCTAssertEqual(try exit(json).version, "1.1")
    }

    func testTheMetaDataVersionIsStillUsedWithoutARootOne() throws {
        let json = payload(root: "", meta: #""appBuildVersion": "8", "appVersion": "1.1""#)
        XCTAssertEqual(try exit(json).version, "1.1")
    }

    func testNoVersionAnywhereFallsBackToTheRunningApp() throws {
        let json = payload(root: "", meta: #""appBuildVersion": "8""#)
        XCTAssertEqual(try exit(json).version, "1.2")
    }

    func testABlankRootVersionFallsBackToTheRunningApp() throws {
        let json = payload(root: #""appVersion": "   ","#, meta: #""appBuildVersion": "8""#)
        XCTAssertEqual(try exit(json).version, "1.2")
    }

    func testTheRootVersionIsTrimmed() throws {
        let json = payload(root: #""appVersion": " 1.1 ","#, meta: #""appBuildVersion": "8""#)
        XCTAssertEqual(try exit(json).version, "1.1")
    }

    func testACleanDayStillMakesNoReportWhateverTheVersion() {
        let json = Data(#"""
        {"appVersion": "1.1", "metaData": {"appBuildVersion": "8"},
         "applicationExitMetrics": {"foregroundExitData": {"cumulativeNormalAppExitCount": 4}, "backgroundExitData": {}}}
        """#.utf8)
        XCTAssertNil(DiagnosticReportBuilder.exits(json: json, id: id, at: B8.date(0), now: B8.date(100), running: running))
    }
}

// MARK: L3, L4, V (files in the repo)

final class Build9ProjectFilesTests: XCTestCase {
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

    // MARK: V

    func testVersionIs1Point2Build12() throws {
        let yml = try read("ios/MeetspikeHR/project.yml")
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"1.2\""), "MARKETING_VERSION must be \"1.2\"")
        XCTAssertTrue(yml.contains("CURRENT_PROJECT_VERSION: \"12\""), "CURRENT_PROJECT_VERSION must be \"12\"")
        XCTAssertFalse(yml.contains("CURRENT_PROJECT_VERSION: \"11\""), "no target left on build 11")
        XCTAssertFalse(yml.contains("CURRENT_PROJECT_VERSION: \"10\""), "no target left on build 10")
        XCTAssertFalse(yml.contains("CURRENT_PROJECT_VERSION: \"9\""), "no target left on build 9")
        XCTAssertFalse(yml.contains("CURRENT_PROJECT_VERSION: \"8\""), "no target left on build 8")
        XCTAssertFalse(yml.contains("MARKETING_VERSION: \"1.1\""), "no target left on 1.1")
    }

    func testTheNewestReleaseNoteIsTheBuildBeingShipped() throws {
        let yml = try read("ios/MeetspikeHR/project.yml")
        let release = try XCTUnwrap(ReleaseNotes.all.first)
        let shipped = try XCTUnwrap(yml.range(of: #"CURRENT_PROJECT_VERSION: "(\d+)""#, options: .regularExpression)
            .flatMap { Int(yml[$0].filter(\.isNumber)) }, "project.yml has a build number")
        XCTAssertEqual(release.build, shipped, "newest note equals the project build")
        XCTAssertTrue(yml.contains("CURRENT_PROJECT_VERSION: \"\(release.build)\""))
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"\(release.version)\""))
    }

    // MARK: L4

    func testScreenshotsAreTheDarkPassOnly() throws {
        let script = try read("ios/capture-screenshots.py")
        XCTAssertTrue(script.contains("\"dark\""), "the dark pass stays")
        XCTAssertFalse(script.contains("\"light\""), "no light pass: the app is dark only")
        XCTAssertFalse(script.contains("'light'"))
        XCTAssertNil(script.range(of: #"for appearance in \[[^\]]*light"#, options: .regularExpression))
    }

    // MARK: L3

    private let service = "ios/MeetspikeHR/Sources/Diagnostics/DiagnosticsService.swift"

    /// Start of the member function (4 space indent, not a nested one) that contains `index`.
    private func enclosingFunction(of index: String.Index, in text: String) throws -> (start: String.Index, name: String) {
        let pattern = try NSRegularExpression(pattern: #"\n    (?:@\w+ )?(?:private |static |fileprivate |nonisolated )*func (\w+)"#)
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        let limit = text.distance(from: text.startIndex, to: index)
        let match = try XCTUnwrap(pattern.matches(in: text, range: whole).last { $0.range.location < limit }, "no function before the call")
        let name = String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
        return (try XCTUnwrap(Range(match.range, in: text)).lowerBound, name)
    }

    func testEveryJSONRepresentationRunsOnTheBigStack() throws {
        let text = try read(service)
        var searchFrom = text.startIndex
        var found = 0
        var offenders: [String] = []
        while let range = text.range(of: "jsonRepresentation()", range: searchFrom..<text.endIndex) {
            searchFrom = range.upperBound
            found += 1
            let function = try enclosingFunction(of: range.lowerBound, in: text)
            if text[function.start..<range.lowerBound].contains("DiagnosticStack.run") { continue }
            // Not inside it here, so every use of this function must be inside one.
            var uses = 0
            var from = text.startIndex
            while let use = text.range(of: function.name, range: from..<text.endIndex) {
                from = use.upperBound
                let line = String(text[text.lineRange(for: use)]).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.contains("func \(function.name)") { continue }
                uses += 1
                let windowStart = text.index(use.lowerBound, offsetBy: -400, limitedBy: text.startIndex) ?? text.startIndex
                if !text[windowStart..<use.lowerBound].contains("DiagnosticStack.run"), !offenders.contains(line) {
                    offenders.append(line)
                }
            }
            if uses == 0 { offenders.append("`\(function.name)` is never called inside DiagnosticStack.run") }
        }
        XCTAssertGreaterThan(found, 0, "no jsonRepresentation() in \(service)")
        XCTAssertEqual(offenders, [], "jsonRepresentation() builds a payload that can be 300 levels deep. These calls are outside DiagnosticStack.run")
    }
}
