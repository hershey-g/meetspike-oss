import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

// Build 8, helpers that landed without tests: WhatsNew (D11), DiagnosticReportBuilder (D9 report making),
// DiagnosticIDs / DiagnosticSeenIDs (D9 dedupe), DiagnosticPolicy (D9, D10), BluetoothCrumb.transition (D9 crumbs)
// and the APIClient request observer (D9 crumbs). Written from the spec (spec8.md), not from the code. Reuses the B8
// helpers (Build8DiagnosticReportTests.swift) and the APIStub (APISupportTests.swift).

// MARK: Server rules, as the phone must satisfy them

/// What the Worker's `sanitizeDiagnostic` + body limit accept, from the spec. Returns the problems found.
private func serverProblems(_ data: Data, now: Date) -> [String] {
    var problems: [String] = []
    if data.count >= 256 * 1024 { problems.append("body \(data.count) bytes is not under 256 KB") }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ["not a JSON object"] }
    let uuid = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .caseInsensitive)
    func matches(_ text: String) -> Bool { uuid.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    if let id = object["id"] as? String { if !matches(id) { problems.append("id") } } else { problems.append("id missing") }
    let kinds: Set<String> = ["crash", "hang", "cpu", "disk", "exit", "error", "test"]
    if !kinds.contains(object["kind"] as? String ?? "") { problems.append("kind") }
    if let at = object["at"] as? String, let date = DiagnosticTime.parse(at) {
        if date.timeIntervalSince(now) > 86_400 { problems.append("at is more than a day ahead: \(at)") }
    } else { problems.append("at does not parse") }
    if object["app"] as? String != "ios" { problems.append("app") }
    if let build = object["build"] as? Int, build > 0 { } else { problems.append("build") }
    for key in ["version", "os", "device"] {
        if let text = object[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { } else { problems.append(key) }
    }
    if object["signature"] != nil, !(object["signature"] is String) { problems.append("signature") }
    if !(object["report"] is [String: Any]) { problems.append("report is not an object") }
    if let crumbs = object["crumbs"] { if !(crumbs is [String]) { problems.append("crumbs") } }
    return problems
}

private let running = DiagnosticReportBuilder.Running(build: 8, version: "1.1", os: "iPhone OS 26.1 (23B85)", device: "iPhone16,2")
private let reportID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-0000000000AB")!

private func wire(_ report: DiagnosticReport) throws -> Data { try JSONEncoder().encode(report) }

// MARK: D11 What's new

final class Build8WhatsNewTests: XCTestCase {
    private func builds(_ releases: [ReleaseNotes.Release]) -> [Int] { releases.map(\.build) }

    func testFreshInstallStoresTheCurrentBuildAndShowsNothing() {
        let decision = WhatsNew.decide(stored: nil, existingInstall: false, current: 8)
        XCTAssertEqual(decision.releases, [])
        XCTAssertEqual(decision.store, 8)
    }

    func testExistingInstallWithNothingStoredCountsAsHavingSeenBuild7() {
        XCTAssertEqual(WhatsNew.lastBuildBeforeTracking, 7)
        XCTAssertEqual(WhatsNew.lastSeen(stored: nil, existingInstall: true), 7)
        XCTAssertNil(WhatsNew.lastSeen(stored: nil, existingInstall: false))
        let decision = WhatsNew.decide(stored: nil, existingInstall: true, current: 8)
        XCTAssertEqual(builds(decision.releases), [8], "an update from build 7 shows build 8 only")
        XCTAssertEqual(decision.store, 8)
    }

    func testStoredSevenOnEightShowsEight() {
        let decision = WhatsNew.decide(stored: 7, existingInstall: true, current: 8)
        XCTAssertEqual(builds(decision.releases), [8])
        XCTAssertEqual(decision.releases.first?.version, "1.1")
        XCTAssertEqual(decision.store, 8)
    }

    func testStoredEqualToCurrentShowsNothing() {
        let decision = WhatsNew.decide(stored: 8, existingInstall: true, current: 8)
        XCTAssertEqual(decision.releases, [])
        XCTAssertEqual(decision.store, 8)
    }

    func testTheStoredValueWinsOverTheExistingInstallFlag() {
        XCTAssertEqual(WhatsNew.lastSeen(stored: 8, existingInstall: true), 8)
        XCTAssertEqual(WhatsNew.lastSeen(stored: 8, existingInstall: false), 8)
        XCTAssertEqual(WhatsNew.lastSeen(stored: 5, existingInstall: false), 5)
        XCTAssertEqual(WhatsNew.decide(stored: 8, existingInstall: false, current: 8).releases, [])
    }

    func testDowngradeShowsNothingAndNeverForgetsTheNewerBuild() {
        for stored in [9, 8] {
            let decision = WhatsNew.decide(stored: stored, existingInstall: true, current: 7)
            XCTAssertEqual(decision.releases, [], "stored \(stored), running 7")
            // If a downgrade lowered the stored build, going back up to 8 would show the notes a second time.
            XCTAssertGreaterThanOrEqual(decision.store, stored)
        }
        let upAgain = WhatsNew.decide(stored: WhatsNew.decide(stored: 8, existingInstall: true, current: 7).store,
                                      existingInstall: true, current: 8)
        XCTAssertEqual(upAgain.releases, [], "downgrade then upgrade again must not repeat the sheet")
    }

    func testSkippedBuildsShowNewestFirst() {
        let decision = WhatsNew.decide(stored: 5, existingInstall: true, current: 8)
        XCTAssertEqual(builds(decision.releases), [8, 7, 6])
        XCTAssertEqual(decision.store, 8)
        let all = WhatsNew.decide(stored: 3, existingInstall: true, current: 8)
        XCTAssertEqual(builds(all.releases), [8, 7, 6, 5, 4])
        XCTAssertEqual(builds(all.releases), builds(all.releases).sorted(by: >))
    }

    func testABuildWithoutANoteStillStoresItself() {
        let newest = ReleaseNotes.all.first?.build ?? 0
        let decision = WhatsNew.decide(stored: newest, existingInstall: true, current: newest + 1)
        XCTAssertEqual(decision.releases, [], "no note exists for the next build yet, and the newest was seen")
        XCTAssertEqual(decision.store, newest + 1)
    }

    /// The Meetspike wiring asks `decide` at launch, even while onboarding is on screen, and keeps `store`. This pins the
    /// two pure halves of "a fresh install finishing onboarding later must still not show it".
    func testAFreshInstallThatFinishesOnboardingLaterStillShowsNothing() {
        var stored: Int?
        // Launch 1, onboarding on screen: a fresh install (no saved link, onboarding not complete).
        let first = WhatsNew.decide(stored: stored, existingInstall: false, current: 8)
        XCTAssertEqual(first.releases, [])
        stored = first.store
        // Onboarding finishes: now it looks like an existing install, but the stored build is there.
        let later = WhatsNew.decide(stored: stored, existingInstall: true, current: 8)
        XCTAssertEqual(later.releases, [], "a fresh install must never get the sheet after onboarding")
        // And the next update still works from there.
        let expected = ReleaseNotes.all.map(\.build).filter { $0 > later.store && $0 <= 9 }
        XCTAssertEqual(builds(WhatsNew.decide(stored: later.store, existingInstall: true, current: 9).releases), expected)
    }

    /// The reason the first call must happen before onboarding ends: without it, a fresh install looks like an
    /// old one. If the wiring ever skips the early call, this is the bug that comes back.
    func testWithoutTheEarlyCallAFinishedFreshInstallWouldLookLikeAnUpdate() {
        XCTAssertEqual(builds(WhatsNew.decide(stored: nil, existingInstall: true, current: 8).releases), [8])
    }
}

// MARK: D9 the report builder

final class Build8ReportBuilderTests: XCTestCase {
    private let now = B8.date(0)

    private func diagnosticJSON(
        build: String? = "7", version: String? = "1.0", os: String? = "iPhone OS 26.0 (23A340)", device: String? = "iPhone15,3"
    ) -> Data {
        var meta: [String] = ["\"platformArchitecture\":\"arm64e\"", "\"exceptionType\":1", "\"signal\":11"]
        if let build { meta.append("\"appBuildVersion\":\"\(build)\"") }
        if let version { meta.append("\"appVersion\":\"\(version)\"") }
        if let os { meta.append("\"osVersion\":\"\(os)\"") }
        if let device { meta.append("\"deviceType\":\"\(device)\"") }
        let text = """
        {"diagnosticMetaData":{\(meta.joined(separator: ","))},
         "exceptionReason":{"composedMessage":"Meeting with Dr Smith about the layoff"},
         "callStackTree":{"callStackPerThread":false,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
           {"binaryName":"MeetspikeHR","binaryUUID":"AAAA-BBBB","offsetIntoBinaryTextSegment":4096,"address":4300000000,"sampleCount":1}]}]}}
        """
        return Data(text.utf8)
    }

    private func crash(_ json: Data, at: Date? = nil, crumbs: [String] = ["c1", "c2"], kind: DiagnosticReport.Kind = .crash) -> DiagnosticReport {
        DiagnosticReportBuilder.diagnostic(kind: kind, json: json, id: reportID, at: at ?? now.addingTimeInterval(-60),
                                           now: now, running: running, crumbs: crumbs)
    }

    // build / version / os / device

    func testBuildVersionOSAndDeviceComeFromTheDiagnosticNotTheRunningApp() {
        let report = crash(diagnosticJSON())
        XCTAssertEqual(report.build, 7, "the crashed build, not the one running now (8)")
        XCTAssertEqual(report.version, "1.0")
        XCTAssertEqual(report.os, "iPhone OS 26.0 (23A340)")
        XCTAssertEqual(report.device, "iPhone15,3")
        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.kind, .crash)
    }

    func testEachMissingFieldFallsBackToTheRunningApp() {
        let none = crash(diagnosticJSON(build: nil, version: nil, os: nil, device: nil))
        XCTAssertEqual(none.build, 8)
        XCTAssertEqual(none.version, "1.1")
        XCTAssertEqual(none.os, running.os)
        XCTAssertEqual(none.device, running.device)
        let onlyBuild = crash(diagnosticJSON(build: "6", version: nil, os: nil, device: nil))
        XCTAssertEqual(onlyBuild.build, 6)
        XCTAssertEqual(onlyBuild.version, "1.1")
        let onlyOS = crash(diagnosticJSON(build: nil, version: nil, os: "iPhone OS 25.5", device: nil))
        XCTAssertEqual(onlyOS.build, 8)
        XCTAssertEqual(onlyOS.os, "iPhone OS 25.5")
        XCTAssertEqual(onlyOS.device, running.device)
    }

    func testAnUnusableBuildNumberFallsBackInsteadOfSendingABadBody() throws {
        for bad in ["abc", "", "  ", "0", "-3", "7.5x", "99999999999999999999"] {
            let report = crash(diagnosticJSON(build: bad))
            XCTAssertGreaterThan(report.build, 0, "build \"\(bad)\"")
            XCTAssertEqual(serverProblems(try wire(report), now: now), [], "build \"\(bad)\"")
        }
        XCTAssertEqual(crash(diagnosticJSON(build: "abc")).build, 8)
    }

    func testABuildThatIsANumberInTheJSONIsRead() {
        let json = Data(#"{"diagnosticMetaData":{"appBuildVersion":7,"appVersion":"1.0"}}"#.utf8)
        XCTAssertEqual(crash(json).build, 7)
    }

    func testEmptyOrBlankTextFieldsFallBack() {
        let report = crash(diagnosticJSON(build: "7", version: "  ", os: "", device: "\n"))
        XCTAssertEqual(report.version, "1.1")
        XCTAssertEqual(report.os, running.os)
        XCTAssertEqual(report.device, running.device)
    }

    // crumbs

    func testCrumbsAreAttachedOnlyToACrash() {
        XCTAssertEqual(crash(diagnosticJSON(), kind: .crash).crumbs, ["c1", "c2"])
        for kind in [DiagnosticReport.Kind.hang, .cpu, .disk] {
            XCTAssertEqual(crash(diagnosticJSON(), kind: kind).crumbs, [], "\(kind) happened in a session that is not on file")
        }
    }

    func testExitAndTestReportsNeverCarryCrumbs() throws {
        let payload = Data(#"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeAppWatchdogExitCount":1}}}"#.utf8)
        XCTAssertEqual(DiagnosticReportBuilder.exits(json: payload, id: reportID, at: now, now: now, running: running)?.crumbs, [])
        XCTAssertEqual(DiagnosticReportBuilder.test(id: reportID, at: now, running: running).crumbs, [])
        XCTAssertFalse(String(decoding: try wire(DiagnosticReportBuilder.test(id: reportID, at: now, running: running)), as: UTF8.self).contains("crumbs"))
    }

    // at

    func testAFutureTimestampIsHandledSoTheServerAccepts() throws {
        for ahead in [3_600.0, 86_400.0 * 2, 86_400.0 * 365, 86_400.0 * 365 * 1000] {
            let report = crash(diagnosticJSON(), at: now.addingTimeInterval(ahead))
            XCTAssertLessThanOrEqual(report.at.timeIntervalSince(now), 86_400, "\(ahead)s ahead")
            XCTAssertEqual(serverProblems(try wire(report), now: now), [], "\(ahead)s ahead")
        }
        let exit = DiagnosticReportBuilder.exits(
            json: Data(#"{"applicationExitMetrics":{"backgroundExitData":{"cumulativeMemoryPressureExitCount":2}}}"#.utf8),
            id: reportID, at: now.addingTimeInterval(86_400 * 30), now: now, running: running)
        XCTAssertLessThanOrEqual(try XCTUnwrap(exit).at.timeIntervalSince(now), 86_400)
        XCTAssertEqual(serverProblems(try wire(try XCTUnwrap(exit)), now: now), [])
    }

    func testAPastOrCurrentTimestampIsKept() {
        let past = now.addingTimeInterval(-86_400 * 3)
        XCTAssertEqual(crash(diagnosticJSON(), at: past).at, past)
        XCTAssertEqual(crash(diagnosticJSON(), at: now).at, now)
    }

    func testANonFiniteTimestampDoesNotCrashOrBreakTheBody() throws {
        for seconds in [Double.infinity, -Double.infinity, Double.nan] {
            let report = crash(diagnosticJSON(), at: Date(timeIntervalSince1970: seconds))
            XCTAssertEqual(serverProblems(try wire(report), now: now), [], "\(seconds)")
        }
    }

    // exits

    func testExitsReportIsAFlatMapOfOnlyTheNonZeroCounts() throws {
        let payload = Data("""
        {"metaData":{"appBuildVersion":"7","appVersion":"1.0","osVersion":"iPhone OS 26.0 (23A340)","deviceType":"iPhone15,3"},
         "applicationExitMetrics":{
           "foregroundExitData":{"cumulativeNormalAppExitCount":40,"cumulativeMemoryResourceLimitExitCount":2,"cumulativeAppWatchdogExitCount":0},
           "backgroundExitData":{"cumulativeNormalAppExitCount":9,"cumulativeBackgroundTaskAssertionTimeoutExitCount":3,
                                 "cumulativeSuspendedWithLockedFileExitCount":1,"cumulativeMemoryPressureExitCount":0}}}
        """.utf8)
        let report = try XCTUnwrap(DiagnosticReportBuilder.exits(json: payload, id: reportID, at: now, now: now, running: running))
        XCTAssertEqual(report.kind, .exit)
        XCTAssertNil(report.signature)
        XCTAssertEqual(report.build, 7)
        XCTAssertEqual(report.os, "iPhone OS 26.0 (23A340)")
        XCTAssertEqual(report.device, "iPhone15,3")
        guard case .object(let root) = report.report, case .object(let exits)? = root["exits"] else {
            return XCTFail("report must be {exits: {...}}: \(report.report)")
        }
        XCTAssertEqual(Set(root.keys), ["exits"])
        XCTAssertFalse(exits.isEmpty)
        for (key, value) in exits {
            guard case .number(let count) = value else { return XCTFail("\(key) is not a number: \(value)") }
            XCTAssertGreaterThan(count, 0, "zero counts are left out: \(key)")
        }
        XCTAssertEqual(exits.values.compactMap { (value: DiagnosticValue) -> Double? in
            if case .number(let n) = value { return n } else { return nil }
        }.reduce(0, +), 6, "2 + 3 + 1, and normal exits never count")
        XCTAssertEqual(serverProblems(try wire(report), now: now), [])
    }

    func testExitsIsNilWhenNothingAbnormalHappened() {
        let clean: [String] = [
            #"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeNormalAppExitCount":50},"backgroundExitData":{"cumulativeNormalAppExitCount":4}}}"#,
            #"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeAppWatchdogExitCount":0,"cumulativeMemoryResourceLimitExitCount":0}}}"#,
            #"{"applicationExitMetrics":{}}"#, #"{}"#, "", "garbage", "[1,2]", "null",
            #"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeAppWatchdogExitCount":-4}}}"#,
            #"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeAppWatchdogExitCount":"3"}}}"#,
        ]
        for text in clean {
            XCTAssertNil(DiagnosticReportBuilder.exits(json: Data(text.utf8), id: reportID, at: now, now: now, running: running), text)
        }
    }

    func testExitsFallsBackToTheRunningAppWithoutMetaData() throws {
        let payload = Data(#"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeAppWatchdogExitCount":1}}}"#.utf8)
        let report = try XCTUnwrap(DiagnosticReportBuilder.exits(json: payload, id: reportID, at: now, now: now, running: running))
        XCTAssertEqual(report.build, 8)
        XCTAssertEqual(report.version, "1.1")
        XCTAssertEqual(report.os, running.os)
        XCTAssertEqual(report.device, running.device)
    }

    // test report

    func testTheTestReportShape() throws {
        let report = DiagnosticReportBuilder.test(id: reportID, at: now, running: running)
        XCTAssertEqual(report.kind, .test)
        XCTAssertEqual(report.id, reportID)
        XCTAssertEqual(report.at, now)
        XCTAssertEqual(report.build, 8)
        XCTAssertEqual(report.version, "1.1")
        XCTAssertEqual(report.os, running.os)
        XCTAssertEqual(report.device, running.device)
        XCTAssertNil(report.signature)
        XCTAssertEqual(report.crumbs, [])
        guard case .object(let body) = report.report else { return XCTFail("report must be an object") }
        XCTAssertFalse(body.isEmpty, "a test report says something")
        XCTAssertEqual(serverProblems(try wire(report), now: now), [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: wire(report)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "test")
        XCTAssertEqual(object["app"] as? String, "ios")
    }

    // the whole body

    func testEveryKindMakesABodyTheServerAccepts() throws {
        for kind in [DiagnosticReport.Kind.crash, .hang, .cpu, .disk] {
            XCTAssertEqual(serverProblems(try wire(crash(diagnosticJSON(), kind: kind)), now: now), [], "\(kind)")
        }
    }

    func testReportsHoldNoPersonalTextFromTheDiagnostic() throws {
        let text = String(decoding: try wire(crash(diagnosticJSON())), as: UTF8.self)
        XCTAssertFalse(text.contains("Dr Smith"))
        XCTAssertFalse(text.contains("layoff"))
        XCTAssertTrue(text.contains("MeetspikeHR"))
    }

    private func hugeDiagnostic(binaryName: String) -> Data {
        let frame = "{\"binaryName\":\"\(binaryName)\",\"binaryUUID\":\"E1E1E1E1-2222-3333-4444-555555555555\"," +
            "\"offsetIntoBinaryTextSegment\":123456789,\"address\":140737488355328,\"sampleCount\":5,\"subFrames\":[]}"
        let stack = "{\"threadAttributed\":false,\"callStackRootFrames\":[" + Array(repeating: frame, count: 100).joined(separator: ",") + "]}"
        let tree = "{\"callStackPerThread\":false,\"callStacks\":[" + Array(repeating: stack, count: 60).joined(separator: ",") + "]}"
        let text = "{\"diagnosticMetaData\":{\"appBuildVersion\":\"8\",\"appVersion\":\"1.1\",\"osVersion\":\"iPhone OS 26.1\",\"deviceType\":\"iPhone16,2\"},\"callStackTree\":\(tree)}"
        return Data(text.utf8)
    }

    func testAHugeTreeWithMaxCrumbsStaysUnder256KB() throws {
        let crumbs = (0..<150).map { _ in String(repeating: "x", count: 200) }
        let plain = crash(hugeDiagnostic(binaryName: String(repeating: "a", count: 500)), crumbs: crumbs)
        XCTAssertEqual(plain.crumbs.count, 150)
        let size = try wire(plain).count
        XCTAssertLessThan(size, 256 * 1024, "body is \(size) bytes")
        XCTAssertGreaterThan(B8.nodeCount(plain.report), 100, "the report is cut, not emptied")
        XCTAssertEqual(serverProblems(try wire(plain), now: now), [])
    }

    func testStringsThatEscapeBadlyStillFit() throws {
        // `/` and `"` double in JSON, control characters grow six times, and emoji take four bytes.
        let crumbs = (0..<150).map { _ in String(repeating: "x", count: 200) }
        for name in [String(repeating: "/", count: 500), String(repeating: "\\u0001", count: 500),
                     String(repeating: "\\\"", count: 500), String(repeating: "\u{1F600}", count: 240)] {
            let report = crash(hugeDiagnostic(binaryName: name), crumbs: crumbs)
            let size = try wire(report).count
            XCTAssertLessThan(size, 256 * 1024, "\(name.prefix(6)): \(size) bytes")
            XCTAssertGreaterThan(B8.nodeCount(report.report), 100, "the report is cut, not emptied")
        }
    }

    func testAVeryDeepTreeStaysUnderTheLimitAndNeverCrashes() throws {
        var open = ""
        var close = ""
        // 150 pairs is about 450 levels: past the 300 limit, but inside what the JSON parser itself will read.
        for _ in 0..<150 { open += "{\"subFrames\":[{\"callStackRootFrames\":"; close += "}]}" }
        let text = "{\"callStackTree\":\(open){\"binaryName\":\"deep\"}\(close)}"
        let report = crash(Data(text.utf8), crumbs: (0..<150).map { _ in String(repeating: "y", count: 200) })
        XCTAssertLessThan(try wire(report).count, 256 * 1024)
        XCTAssertLessThanOrEqual(B8.depth(report.report), 300)
        XCTAssertGreaterThan(B8.depth(report.report), 100, "the tree was read and cut at the limit, not dropped")
    }

    func testGarbageJSONNeverCrashesAndFallsBackToTheRunningApp() throws {
        var noise = Data()
        for index in 0..<4096 { noise.append(UInt8((index &* 31 &+ 7) & 0xFF)) }
        let garbage: [Data] = [
            Data(), Data("not json".utf8), Data("null".utf8), Data("[]".utf8), Data("[[[[".utf8), Data("{".utf8), Data("{}".utf8),
            Data("\"text\"".utf8), Data("42".utf8), noise, Data([0xFF, 0xFE, 0x00]),
            Data(#"{"diagnosticMetaData":null}"#.utf8), Data(#"{"diagnosticMetaData":[1,2]}"#.utf8),
            Data(#"{"diagnosticMetaData":{"appBuildVersion":{"x":1},"appVersion":[1],"osVersion":true,"deviceType":null}}"#.utf8),
            Data(#"{"diagnosticMetaData":{"appBuildVersion":1e999}}"#.utf8),
            Data(#"{"diagnosticMetaData":{"appBuildVersion":1e30}}"#.utf8),
            Data(#"{"diagnosticMetaData":{"appBuildVersion":-1,"appVersion":"\u0000"}}"#.utf8),
            Data(String(repeating: "[", count: 200_000).utf8),
            Data((String(repeating: "{\"a\":", count: 100_000) + "1" + String(repeating: "}", count: 100_000)).utf8),
        ]
        for (index, data) in garbage.enumerated() {
            for kind in [DiagnosticReport.Kind.crash, .hang, .cpu, .disk] {
                let report = crash(data, kind: kind)
                XCTAssertEqual(serverProblems(try wire(report), now: now), [], "garbage #\(index) \(kind)")
                XCTAssertEqual(report.build, 8, "garbage #\(index)")
            }
            XCTAssertNil(DiagnosticReportBuilder.exits(json: data, id: reportID, at: now, now: now, running: running), "garbage #\(index)")
        }
    }
}

// MARK: D9 stable ids and the seen-ids file

final class Build8DiagnosticIDTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("ids") }
    override func tearDown() { if let directory { B8.remove(directory) } }

    private let payload = Data(#"{"callStackTree":{"callStacks":[]}}"#.utf8)

    func testStableIDIsDeterministic() {
        let a = DiagnosticIDs.stable(payload: payload, kind: .crash, index: 0)
        for _ in 0..<5 { XCTAssertEqual(DiagnosticIDs.stable(payload: payload, kind: .crash, index: 0), a) }
        XCTAssertEqual(DiagnosticIDs.stable(payload: Data(payload), kind: .crash, index: 0), a)
    }

    func testStableIDDiffersByKindIndexAndPayload() {
        let base = DiagnosticIDs.stable(payload: payload, kind: .crash, index: 0)
        let kinds: [DiagnosticReport.Kind] = [.crash, .hang, .cpu, .disk, .exit, .error, .test]
        XCTAssertEqual(Set(kinds.map { DiagnosticIDs.stable(payload: payload, kind: $0, index: 0) }).count, kinds.count)
        XCTAssertEqual(Set((0..<200).map { DiagnosticIDs.stable(payload: payload, kind: .crash, index: $0) }).count, 200)
        XCTAssertNotEqual(DiagnosticIDs.stable(payload: payload, kind: .crash, index: 1), base)
        var other = payload
        other[other.count - 1] = UInt8(ascii: "]")
        XCTAssertNotEqual(DiagnosticIDs.stable(payload: other, kind: .crash, index: 0), base)
        other = payload
        other.append(0x20)
        XCTAssertNotEqual(DiagnosticIDs.stable(payload: other, kind: .crash, index: 0), base, "one more byte")
        XCTAssertNotEqual(DiagnosticIDs.stable(payload: Data(), kind: .crash, index: 0), base)
        // Many payloads, no collisions.
        let ids = (0..<500).map { DiagnosticIDs.stable(payload: Data("payload-\($0)".utf8), kind: .crash, index: 0) }
        XCTAssertEqual(Set(ids).count, 500)
        // Payload and index/kind are not blurred together.
        XCTAssertNotEqual(DiagnosticIDs.stable(payload: Data("a".utf8), kind: .crash, index: 11),
                          DiagnosticIDs.stable(payload: Data("a1".utf8), kind: .crash, index: 1))
    }

    func testStableIDIsAUUIDTheServerAccepts() throws {
        let regex = try NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        for index in 0..<50 {
            let id = DiagnosticIDs.stable(payload: Data("p\(index)".utf8), kind: .hang, index: index)
            let text = id.uuidString.lowercased()
            XCTAssertNotNil(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), text)
            XCTAssertEqual(UUID(uuidString: text), id)
            let body = try JSONEncoder().encode(DiagnosticReportBuilder.test(id: id, at: B8.date(0), running: running))
            XCTAssertEqual(serverProblems(body, now: B8.date(0)), [])
        }
        let empty = DiagnosticIDs.stable(payload: Data(), kind: .crash, index: 0)
        XCTAssertNotNil(UUID(uuidString: empty.uuidString))
    }

    // seen ids

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { DiagnosticIDs.stable(payload: Data("seen-\($0)".utf8), kind: .crash, index: $0) }
    }

    func testAnIDIsNewOnceThenSeen() {
        let seen = DiagnosticSeenIDs(file: directory.appendingPathComponent("seen.txt"))
        let id = ids(1)[0]
        XCTAssertFalse(seen.contains(id))
        XCTAssertTrue(seen.insert(id))
        XCTAssertFalse(seen.insert(id))
        XCTAssertFalse(seen.insert(id))
        XCTAssertTrue(seen.contains(id))
        XCTAssertTrue(seen.insert(ids(2)[1]), "a different id is new")
    }

    func testSeenIDsSurviveANewInstance() {
        let file = directory.appendingPathComponent("nested/seen.txt")
        let id = ids(1)[0]
        XCTAssertTrue(DiagnosticSeenIDs(file: file).insert(id))
        let again = DiagnosticSeenIDs(file: file)
        XCTAssertTrue(again.contains(id))
        XCTAssertFalse(again.insert(id), "a relaunch must not queue the same payload twice")
    }

    func testTheCaseOfAnIDDoesNotMatter() {
        let seen = DiagnosticSeenIDs(file: directory.appendingPathComponent("seen.txt"))
        let id = UUID(uuidString: "A1B2C3D4-0000-4000-8000-0000000000AB")!
        XCTAssertTrue(seen.insert(id))
        XCTAssertFalse(seen.insert(UUID(uuidString: "a1b2c3d4-0000-4000-8000-0000000000ab")!))
    }

    func testTheListIsBoundedAt200KeepingTheNewest() throws {
        let file = directory.appendingPathComponent("seen.txt")
        let seen = DiagnosticSeenIDs(file: file)
        XCTAssertEqual(seen.limit, 200)
        let all = ids(260)
        for id in all { XCTAssertTrue(seen.insert(id)) }
        for id in all[60...] { XCTAssertTrue(seen.contains(id), "newest 200 are kept") }
        for id in all[..<60] { XCTAssertFalse(seen.contains(id), "the oldest 60 are dropped") }
        let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, 200)
        XCTAssertFalse(seen.insert(all[259]))
    }

    func testASmallLimitKeepsTheNewest() {
        let seen = DiagnosticSeenIDs(file: directory.appendingPathComponent("small.txt"), limit: 3)
        let all = ids(5)
        for id in all { XCTAssertTrue(seen.insert(id)) }
        XCTAssertEqual(all.map { seen.contains($0) }, [false, false, true, true, true])
    }

    func testACorruptFileIsHarmless() throws {
        let file = directory.appendingPathComponent("corrupt.txt")
        var junk = Data([0xFF, 0xFE, 0x00, 0x0A, 0x80, 0x0A])
        junk.append(Data("not-a-uuid\n\n\n   \n\u{0}\n".utf8))
        junk.append(Data(String(repeating: "z", count: 100_000).utf8))
        try junk.write(to: file)
        let seen = DiagnosticSeenIDs(file: file)
        let id = ids(1)[0]
        XCTAssertFalse(seen.contains(id))
        XCTAssertTrue(seen.insert(id))
        XCTAssertFalse(seen.insert(id))
        XCTAssertTrue(DiagnosticSeenIDs(file: file).contains(id))
        // An empty file and a file that is a directory.
        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        XCTAssertTrue(DiagnosticSeenIDs(file: empty).insert(id))
        let folder = directory.appendingPathComponent("folder.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(DiagnosticSeenIDs(file: folder).insert(id), "nothing to read, nothing written, no crash")
    }

    func testAnUnwritableLocationIsHarmless() throws {
        // The parent is a regular file, so nothing can be created under it.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let seen = DiagnosticSeenIDs(file: blocker.appendingPathComponent("inner/seen.txt"))
        let id = ids(1)[0]
        XCTAssertTrue(seen.insert(id), "a report is still made when the list cannot be kept")
        XCTAssertFalse(seen.contains(id))
        // A read only directory.
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        _ = DiagnosticSeenIDs(file: locked.appendingPathComponent("seen.txt")).insert(id)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }

    func testTwoThreadsRacingOnTheSameIDLetExactlyOneThrough() async {
        let file = directory.appendingPathComponent("race.txt")
        let id = ids(1)[0]
        let wins = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<40 { group.addTask { DiagnosticSeenIDs(file: file).insert(id) } }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        XCTAssertEqual(wins, 1)
    }
}

// MARK: D9, D10 the policy

final class Build8PolicyTests: XCTestCase {
    private let bools = [false, true]

    func testShouldQueueTruthTable() {
        for enabled in bools {
            for demo in bools {
                XCTAssertEqual(DiagnosticPolicy.shouldQueue(enabled: enabled, demo: demo), enabled && !demo,
                               "enabled \(enabled) demo \(demo)")
            }
        }
        XCTAssertTrue(DiagnosticPolicy.shouldQueue(enabled: true, demo: false))
        XCTAssertFalse(DiagnosticPolicy.shouldQueue(enabled: false, demo: false), "the switch is off")
        XCTAssertFalse(DiagnosticPolicy.shouldQueue(enabled: true, demo: true), "demo mode makes no reports")
    }

    func testShouldUploadTruthTable() {
        var trues = 0
        for enabled in bools {
            for demo in bools {
                for destination in bools {
                    for secret in bools {
                        let result = DiagnosticPolicy.shouldUpload(enabled: enabled, demo: demo, hasDestination: destination, hasSecret: secret)
                        let expected = enabled && !demo && destination && secret
                        XCTAssertEqual(result, expected, "enabled \(enabled) demo \(demo) destination \(destination) secret \(secret)")
                        if result { trues += 1 }
                    }
                }
            }
        }
        XCTAssertEqual(trues, 1, "exactly one combination uploads")
        XCTAssertTrue(DiagnosticPolicy.shouldUpload(enabled: true, demo: false, hasDestination: true, hasSecret: true))
        XCTAssertFalse(DiagnosticPolicy.shouldUpload(enabled: true, demo: true, hasDestination: true, hasSecret: true), "demo mode never uploads")
    }

    func testTheTestReportResultTextMatchesTheMenuSpec() {
        XCTAssertEqual(DiagnosticPolicy.testResultText(sent: true), "Sent.")
        XCTAssertEqual(DiagnosticPolicy.testResultText(sent: false), "Not sent yet. It will try again.")
    }

    func testWaitingTextShowsACountOnlyWhenReportsAreWaiting() {
        XCTAssertNil(DiagnosticPolicy.waitingText(count: 0))
        XCTAssertNil(DiagnosticPolicy.waitingText(count: -1))
        XCTAssertEqual(DiagnosticPolicy.waitingText(count: 1)?.contains("1"), true)
        XCTAssertEqual(DiagnosticPolicy.waitingText(count: 7)?.contains("7"), true)
        for count in [1, 2, 20] {
            let text = DiagnosticPolicy.waitingText(count: count) ?? ""
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.isEmpty)
        }
    }
}

// MARK: D9 Bluetooth crumbs

final class Build8BluetoothCrumbTests: XCTestCase {
    private let all: [BluetoothStatus] = [
        .starting, .searching, .reconnecting, .poweredOff, .unauthorized, .unsupported, .waiting, .connecting, .connected,
        .paused, .sleeping, .outsideMeeting,
    ]
    private let unusable: [BluetoothStatus] = [.poweredOff, .unauthorized, .unsupported]

    func testNothingChangedMakesNoCrumb() {
        for status in all { XCTAssertNil(BluetoothCrumb.transition(from: status, to: status), "\(status)") }
    }

    func testConnectMakesAConnectedCrumb() {
        for old in all where old != .connected {
            XCTAssertEqual(BluetoothCrumb.transition(from: old, to: .connected), .connected, "\(old) to connected")
        }
        XCTAssertEqual(BluetoothCrumb.transition(from: nil, to: .connected), .connected, "the first status of a launch")
    }

    func testLosingTheConnectionMakesACrumb() {
        for new in all where new != .connected && !unusable.contains(new) {
            XCTAssertEqual(BluetoothCrumb.transition(from: .connected, to: new), .disconnected, "connected to \(new)")
        }
        for new in unusable {
            XCTAssertNotNil(BluetoothCrumb.transition(from: .connected, to: new), "losing the link because Bluetooth went away is still worth a crumb")
        }
    }

    func testFailureToUseBluetoothMakesAFailedCrumb() {
        for new in unusable {
            for old in all where old != new && old != .connected {
                XCTAssertEqual(BluetoothCrumb.transition(from: old, to: new), .failed, "\(old) to \(new)")
            }
            XCTAssertEqual(BluetoothCrumb.transition(from: nil, to: new), .failed)
        }
    }

    func testTheNoisyMiddleStatesMakeNoCrumb() {
        let quiet: [BluetoothStatus] = [.starting, .searching, .reconnecting, .waiting, .connecting, .paused, .sleeping, .outsideMeeting]
        for old in quiet + [nil] {
            for new in quiet where old != new {
                XCTAssertNil(BluetoothCrumb.transition(from: old, to: new), "\(String(describing: old)) to \(new)")
            }
        }
    }

    func testReadingsNeverMakeCrumbs() {
        // A heart rate reading leaves the status at `connected`: the same status again, so no crumb, however many.
        var crumbs = 0
        var previous: BluetoothStatus? = .connected
        for _ in 0..<10_000 {
            if BluetoothCrumb.transition(from: previous, to: .connected) != nil { crumbs += 1 }
            previous = .connected
        }
        XCTAssertEqual(crumbs, 0)
    }

    func testAWholeSessionLogsOnlyTheRealEvents() {
        let session: [BluetoothStatus] = [.starting, .searching, .connecting, .connected, .connected, .reconnecting, .searching,
                                          .connecting, .connected, .poweredOff, .waiting, .connecting, .connected, .sleeping]
        var previous: BluetoothStatus?
        var logged: [BluetoothCrumb] = []
        for status in session {
            if let crumb = BluetoothCrumb.transition(from: previous, to: status) { logged.append(crumb) }
            previous = status
        }
        XCTAssertEqual(logged, [.connected, .disconnected, .connected, .failed, .connected, .disconnected])
    }

    func testTheCrumbTextHasNoPersonalData() {
        for crumb in [BluetoothCrumb.connected, .disconnected, .failed] {
            XCTAssertEqual(Crumb.bluetooth(crumb).body, "bluetooth \(crumb.rawValue)")
        }
    }
}

// MARK: D9 the API client observer

private final class Observed: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(path: String, status: Int, ms: Int)] = []

    func add(_ path: String, _ status: Int, _ ms: Int) { lock.withLock { items.append((path, status, ms)) } }
    var all: [(path: String, status: Int, ms: Int)] { lock.withLock { items } }
}

final class Build8APIObserverTests: XCTestCase {
    private func client(
        host: String, credentials: Credentials? = nil, seen: Observed
    ) -> APIClient {
        APIClient(
            origin: "https://\(host)", credentials: credentials, userAgent: "MeetspikeTest/1.0",
            configuration: APIStub.configuration(), observer: { path, status, ms in seen.add(path, status, ms) }
        )!
    }

    func testObserverIsCalledOncePerRequestWithPathStatusAndMilliseconds() async throws {
        let host = "observer-ok.example.com"
        let body = try APIFixture.data("view-day.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: body) }
        let seen = Observed()
        _ = try await client(host: host, seen: seen).view(date: "2026-11-24")
        let calls = seen.all
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.path, "/api/view", "the path, with no query")
        XCTAssertEqual(calls.first?.status, 200)
        XCTAssertGreaterThanOrEqual(calls.first?.ms ?? -1, 0)
    }

    func testTheMillisecondsAreMilliseconds() async throws {
        let host = "observer-slow.example.com"
        let body = try APIFixture.data("view-day.json")
        APIStub.register(host: host) { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return .json(status: 200, body: body)
        }
        let seen = Observed()
        _ = try await client(host: host, seen: seen).view(date: "2026-11-24")
        let ms = try XCTUnwrap(seen.all.first?.ms)
        XCTAssertGreaterThanOrEqual(ms, 100, "a 150 ms answer is not seconds or nanoseconds")
        XCTAssertLessThan(ms, 5_000)
    }

    func testObserverSeesTheStatusOfAFailedAnswerOnce() async throws {
        let host = "observer-500.example.com"
        APIStub.register(host: host) { _ in .json(status: 500, body: Data(#"{"error":"boom"}"#.utf8)) }
        let seen = Observed()
        do {
            _ = try await client(host: host, seen: seen).view(date: "2026-11-24")
            XCTFail("a 500 must throw")
        } catch {}
        XCTAssertEqual(seen.all.map(\.status), [500])
        XCTAssertEqual(seen.all.map(\.path), ["/api/view"])
    }

    func testATransportFailureIsStatusZeroWithAMillisecondCount() async {
        for (index, code) in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost].enumerated() {
            let host = "observer-down-\(index).example.com"
            APIStub.register(host: host) { _ in .failure(code) }
            let seen = Observed()
            do {
                _ = try await client(host: host, seen: seen).view(date: "2026-11-24")
                XCTFail("must throw")
            } catch {}
            XCTAssertEqual(seen.all.count, 1, "\(code)")
            XCTAssertEqual(seen.all.first?.status, 0, "\(code)")
            XCTAssertEqual(seen.all.first?.path, "/api/view", "\(code)")
            XCTAssertGreaterThanOrEqual(seen.all.first?.ms ?? -1, 0)
        }
    }

    func testARefusedRedirectAndASignInPageAreObservedOnce() async {
        let redirectHost = "observer-redirect.example.com"
        APIStub.register(host: redirectHost) { _ in .redirectThroughSession(to: "https://evil.example.org/login") }
        let htmlHost = "observer-html.example.com"
        APIStub.register(host: htmlHost) { _ in .html(status: 200) }
        for host in [redirectHost, htmlHost] {
            let seen = Observed()
            do {
                _ = try await client(host: host, seen: seen).view(date: "2026-11-24")
                XCTFail("an Access problem must throw")
            } catch {}
            XCTAssertEqual(seen.all.count, 1, host)
            XCTAssertEqual(seen.all.first?.path, "/api/view", host)
        }
        XCTAssertEqual(APIStub.seen(host: "evil.example.org").count, 0, "redirects are never followed")
    }

    func testOneObserverCallPerEachRequestOfAMultiRequestOperation() async throws {
        // An older Worker has no /api/refresh, so a refresh is two requests. Each is observed.
        let host = "observer-two.example.com"
        APIStub.register(host: host) { request in
            if request.url?.path == "/api/refresh" { return .json(status: 404, body: Data(#"{"error":"nope"}"#.utf8)) }
            return .json(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        let seen = Observed()
        _ = try? await client(host: host, seen: seen).refresh(full: false)
        XCTAssertEqual(seen.all.map(\.path), ["/api/refresh", "/api/calendar/sync"])
        XCTAssertEqual(seen.all.map(\.status), [404, 200])
    }

    func testObserverNeverSeesQueryStringsOrSecrets() async throws {
        let host = "observer-secret.example.com"
        let body = try APIFixture.data("view-day.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: body) }
        let credentials = Credentials(ingestSecret: "ingest-SECRET-123", accessID: "access-ID-456", accessSecret: "access-SECRET-789")
        let seen = Observed()
        let api = client(host: host, credentials: credentials, seen: seen)
        _ = try await api.view(date: "2026-11-24")
        _ = try? await api.view(start: "2026-11-01", end: "2026-11-30")
        _ = try? await api.searchPeople(query: "needle-search-text")
        _ = try? await api.liveHR(meetingID: "meeting-abc", since: 12)
        XCTAssertEqual(seen.all.count, 4)
        for call in seen.all {
            XCTAssertFalse(call.path.contains("?"), call.path)
            XCTAssertFalse(call.path.contains("="), call.path)
            XCTAssertFalse(call.path.contains("&"), call.path)
            for secret in ["ingest-SECRET-123", "access-ID-456", "access-SECRET-789", "needle-search-text", "2026-11", "since"] {
                XCTAssertFalse(call.path.contains(secret), "\(call.path) leaks \(secret)")
            }
        }
        // The values did go on the wire, so the test is not vacuous.
        XCTAssertTrue(APIStub.seen(host: host).contains { $0.url?.query?.contains("needle-search-text") == true })
    }

    func testTheCrumbRouteNeverKeepsAnIDOrEmailFromAnObservedPath() async throws {
        let host = "observer-route.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: Data(#"{"meetings":[]}"#.utf8)) }
        let seen = Observed()
        let api = client(host: host, seen: seen)
        _ = try? await api.meetingHR(id: "evt-9f8e7d", fill: true)
        _ = try? await api.personMeetings(email: "jane.doe@example.com", start: "2026-11-01", end: "2026-11-30", compact: true)
        XCTAssertEqual(seen.all.count, 2)
        let routes = seen.all.map { CrumbRoute.name(path: $0.path) }
        XCTAssertEqual(routes, ["/api/meetings/:id/hr", "/api/people/:id/meetings"])
        for call in seen.all {
            let line = Crumb.request(route: CrumbRoute.name(path: call.path), status: call.status, ms: call.ms).body
            XCTAssertFalse(line.contains("jane"), line)
            XCTAssertFalse(line.contains("evt-9f8e7d"), line)
            XCTAssertFalse(line.contains("example.com"), line)
        }
    }

    func testAClientWithoutAnObserverStillWorks() async throws {
        let host = "observer-none.example.com"
        let body = try APIFixture.data("view-day.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: body) }
        let view = try await APIClient.stubbed(host: host).view(date: "2026-11-24")
        XCTAssertEqual(view.today, "2026-11-24")
    }
}
