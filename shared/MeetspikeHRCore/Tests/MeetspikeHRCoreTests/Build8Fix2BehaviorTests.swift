import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8 fix pass 2: the findings that can be tested on today's API (F2, F3, F4 reading, F7). They compile now and
// fail on their assertions. Tests that need new names are in Build8Fix2ContractTests.swift; F1 is in
// Build8Fix2StackTests.swift. Spec: .claude/jobs/92fc823f/tmp/fix8.md. Shared payloads: Build8Fix2Support.swift.

// MARK: F2 (S2): the scrub survives any depth

final class Build8Fix2ScrubDepthTests: XCTestCase {
    private func scrub(_ json: String) -> DiagnosticValue { DiagnosticScrubber.scrub(Data(json.utf8)) }

    func testTheTestPayloadsAreWhatTheOtherTestsThinkTheyAre() {
        // Anchor for this file and the stack tests: up to 250 frames (500 containers) today's scrubber parses them
        // whole, and they have the depth and frame count the helpers say. This passes before and after the fix.
        for frames in [1, 2, 92, 147, 148, 149, 150, 200, 250] {
            let value = scrub(Fix2Payload.crash(frames: frames))
            XCTAssertEqual(B8.depth(value), Fix2Payload.keptDepth(frames: frames), "\(frames) frames")
            XCTAssertEqual(Fix2Payload.chainNames(value).count, min(frames, 148), "\(frames) frames")
            XCTAssertEqual(Fix2Payload.metaValue(value, "signal"), .number(5), "\(frames) frames")
        }
    }

    func testFiveThousandFramesStillGiveMetadataSignalAndTheShallowThreeHundredLevels() {
        let value = scrub(Fix2Payload.crash(frames: 5000))
        XCTAssertNotEqual(value, .object([:]), "a payload JSONSerialization refuses must not be lost whole")
        XCTAssertEqual(Fix2Payload.metaValue(value, "signal"), .number(5))
        XCTAssertEqual(Fix2Payload.metaValue(value, "appBuildVersion"), .string("8"))
        XCTAssertEqual(Fix2Payload.metaValue(value, "terminationReason"), .string("Namespace SIGNAL, Code 5"))
        XCTAssertEqual(B8.depth(value), 300, "everything inside the limit stays")
        let names = Fix2Payload.chainNames(value)
        XCTAssertEqual(names.count, 148)
        XCTAssertEqual(Array(names.prefix(3)), ["f0", "f1", "f2"])
        XCTAssertEqual(names.last, "f147")
    }

    func testEveryDepthPastTheJSONParserLimitStillScrubs() {
        // 512 is JSONSerialization's own limit (about 255 frames). Around it, past it, far past it.
        for frames in [250, 255, 256, 260, 300, 1000, 5000] {
            let value = scrub(Fix2Payload.crash(frames: frames))
            XCTAssertEqual(Fix2Payload.metaValue(value, "signal"), .number(5), "\(frames) frames")
            XCTAssertEqual(B8.depth(value), 300, "\(frames) frames")
        }
    }

    func testTheBuildIsTheCrashedBuildNotTheRunningOneAtAnyDepth() {
        let report = DiagnosticReportBuilder.diagnostic(
            kind: .crash, json: Data(Fix2Payload.crash(frames: 5000).utf8), id: Fix2Path.id, at: B8.date(0), now: B8.date(60),
            running: .fix2, crumbs: [])
        XCTAssertEqual(report.build, 8)
        XCTAssertEqual(report.version, "1.1")
        XCTAssertEqual(report.device, "iPhone16,2")
    }

    func testTheEncodedResultStillFitsTheBudgetAtAnyDepth() throws {
        let value = scrub(Fix2Payload.crash(frames: 5000))
        let wire = try JSONEncoder().encode(B8.report(1).with(report: value))
        XCTAssertLessThanOrEqual(wire.count, 200_000)
        XCTAssertGreaterThan(wire.count, 1000)
    }

    func testBracketsAndQuotesInsideStringsAreNotNesting() {
        // Strings and escapes are understood by the scan: none of this is a container, and the string ends where JSON says.
        let nasty = String(repeating: "[{", count: 400) + "}]\\\"" + String(repeating: "]", count: 400)
        let escaped = nasty.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let meta = "{\"appBuildVersion\":\"8\",\"signal\":11,\"terminationReason\":\"back\\\\\",\"message\":\"\(escaped)\"}"
        let value = scrub(Fix2Payload.crash(frames: 5000, meta: meta))
        XCTAssertEqual(Fix2Payload.metaValue(value, "signal"), .number(11))
        // A string that ends in an escaped backslash ends there: the quote after it closes it.
        XCTAssertEqual(Fix2Payload.metaValue(value, "terminationReason"), .string("back\\"))
        guard case .string(let kept)? = Fix2Payload.metaValue(value, "message") else { return XCTFail("message dropped") }
        XCTAssertTrue(kept.hasPrefix("[{[{"), "a string full of brackets is still a string")
        XCTAssertEqual(B8.depth(value), 300)
    }

    func testAShallowSiblingSurvivesADeepOne() {
        let deep = Fix2Payload.crash(frames: 5000)
        // Two threads in one tree: the deep one first, a shallow one after it. Both are scanned, only the deep one is cut.
        let json = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[
          {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"shallow","offsetIntoBinaryTextSegment":7,"sampleCount":1}]},
          {"threadAttributed":true,"callStackRootFrames":[\(deepRootFrame(deep))]}]},
         "diagnosticMetaData":{"signal":11}}
        """
        let value = scrub(json)
        XCTAssertEqual(Fix2Payload.metaValue(value, "signal"), .number(11))
        guard case .object(let root) = value, case .object(let tree)? = root["callStackTree"], case .array(let stacks)? = tree["callStacks"],
              stacks.count == 2, case .object(let first) = stacks[0], case .array(let roots)? = first["callStackRootFrames"],
              case .object(let frame)? = roots.first else { return XCTFail("shape lost: \(value)") }
        XCTAssertEqual(frame["binaryName"], .string("shallow"))
        XCTAssertEqual(B8.depth(value), 300)
    }

    /// The text of the first root frame inside `crash(frames:)`.
    private func deepRootFrame(_ crash: String) -> String {
        let marker = "\"callStackRootFrames\":["
        let start = crash.range(of: marker)!.upperBound
        let end = crash.range(of: "]}]},\"diagnosticMetaData\"", options: .backwards)!.lowerBound
        return String(crash[start..<end])
    }

    func testBrokenJSONStillGivesAnEmptyObjectAtAnyDepth() {
        let good = Fix2Payload.crash(frames: 5000)
        XCTAssertEqual(scrub(String(good.dropLast(40))), .object([:]), "cut off mid-way")
        XCTAssertEqual(scrub(String(good.dropLast())), .object([:]), "missing the last brace")
        XCTAssertEqual(scrub(good + "]"), .object([:]), "trailing junk")
        XCTAssertEqual(scrub(String(repeating: "{\"subFrames\":", count: 5000)), .object([:]), "never closed")
        XCTAssertEqual(scrub(String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)), .object([:]), "an array is not an object")
        XCTAssertEqual(scrub(""), .object([:]))
        XCTAssertEqual(scrub("not json"), .object([:]))
    }

    func testAHundredThousandLevelsOfObjectsNowKeepTheShallowPart() {
        // Valid JSON this deep used to be `{}` (JSONSerialization refuses it). Now deeper than 300 is cut, nothing more.
        let levels = 100_000
        let objects = String(repeating: "{\"subFrames\":", count: levels) + "1" + String(repeating: "}", count: levels)
        let value = scrub(objects)
        XCTAssertNotEqual(value, .object([:]))
        XCTAssertLessThanOrEqual(B8.depth(value), 301)
        XCTAssertGreaterThanOrEqual(B8.depth(value), 295)
    }

    func testAHundredThousandLevelsOfArraysIsStillNotAnObject() {
        let levels = 100_000
        XCTAssertEqual(scrub(String(repeating: "[", count: levels) + String(repeating: "]", count: levels)), .object([:]))
    }
}

// MARK: F3 (S2): which end of the stack is the crash site

final class Build8Fix2SignatureOrderTests: XCTestCase {
    private func signature(_ json: String, kind: DiagnosticReport.Kind = .crash) -> String? {
        DiagnosticSignature.make(kind: kind, report: DiagnosticScrubber.scrub(Data(json.utf8)))
    }

    private func frame(_ name: String, _ offset: Int, count: Int = 1, children: String? = nil) -> String {
        let sub = children.map { ",\"subFrames\":[\($0)]" } ?? ""
        return "{\"binaryName\":\"\(name)\",\"offsetIntoBinaryTextSegment\":\(offset),\"sampleCount\":\(count)\(sub)}"
    }

    /// Chain A > B > C > D > E from the root down.
    private func chain(perThread: String?, extra: String = "") -> String {
        let tree = frame("A", 1, children: frame("B", 2, children: frame("C", 3, children: frame("D", 4, children: frame("E", 5)))))
        let flag = perThread.map { "\"callStackPerThread\":\($0)," } ?? ""
        return """
        {"callStackTree":{\(flag)"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\(tree)]}]}\(extra)}
        """
    }

    func testPerThreadTreeHasTheCrashSiteAtTheRootSoTheFirstThreeFromTheRootAreUsed() {
        XCTAssertEqual(signature(chain(perThread: "true")), "A+1 < B+2 < C+3")
    }

    func testPerThreadFalseKeepsDeepestFirst() {
        XCTAssertEqual(signature(chain(perThread: "false")), "E+5 < D+4 < C+3")
    }

    func testMissingPerThreadFlagKeepsDeepestFirst() {
        XCTAssertEqual(signature(chain(perThread: nil)), "E+5 < D+4 < C+3")
    }

    func testOnlyTheBooleanTrueCounts() {
        XCTAssertEqual(signature(chain(perThread: "\"true\"")), "E+5 < D+4 < C+3")
        XCTAssertEqual(signature(chain(perThread: "1")), "E+5 < D+4 < C+3")
        XCTAssertEqual(signature(chain(perThread: "null")), "E+5 < D+4 < C+3")
    }

    func testAShortPerThreadChainUsesWhatItHasFromTheRoot() {
        let two = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"A","offsetIntoBinaryTextSegment":1,"sampleCount":2,"subFrames":[
            {"binaryName":"B","offsetIntoBinaryTextSegment":2,"sampleCount":2}]}]}]}}
        """
        XCTAssertEqual(signature(two, kind: .disk), "A+1 < B+2")
        let one = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"A","offsetIntoBinaryTextSegment":1,"sampleCount":2}]}]}}
        """
        XCTAssertEqual(signature(one, kind: .cpu), "A+1")
    }

    func testPerThreadStillFollowsTheHeaviestBranchThenTakesTheFirstThreeFromTheRoot() {
        let tree = frame("R", 10, count: 9, children: [
            frame("light", 11, count: 2, children: frame("lightLeaf", 12, count: 2)),
            frame("heavy1", 21, count: 7, children: frame("heavy2", 22, count: 7, children: frame("heavy3", 23, count: 7))),
        ].joined(separator: ","))
        let json = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\(tree)]}]}}
        """
        XCTAssertEqual(signature(json), "R+10 < heavy1+21 < heavy2+22")
    }

    func testFramesWithoutANameAreSkippedBeforeTheFirstThreeAreTaken() {
        let tree = "{\"sampleCount\":1,\"subFrames\":[" + frame("A", 1, children: frame("B", 2, children: frame("C", 3, children: frame("D", 4)))) + "]}"
        let json = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\(tree)]}]}}
        """
        XCTAssertEqual(signature(json), "A+1 < B+2 < C+3")
    }

    func testThePrefixIsUnchangedAndTheOrderChangesOnlyAfterIt() {
        let json = chain(perThread: "true", extra: ",\"diagnosticMetaData\":{\"exceptionType\":6,\"signal\":5}")
        XCTAssertEqual(signature(json), "6/5 | A+1 < B+2 < C+3")
        let deepest = chain(perThread: "false", extra: ",\"diagnosticMetaData\":{\"exceptionType\":6,\"signal\":5}")
        XCTAssertEqual(signature(deepest), "6/5 | E+5 < D+4 < C+3")
    }

    func testTheAttributedThreadIsStillThePickedOneForAPerThreadTree() {
        let other = frame("OTHER", 99, children: frame("OTHER2", 98))
        let mine = frame("A", 1, children: frame("B", 2))
        let json = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[
          {"threadAttributed":false,"callStackRootFrames":[\(other)]},
          {"threadAttributed":true,"callStackRootFrames":[\(mine)]}]}}
        """
        XCTAssertEqual(signature(json), "A+1 < B+2")
    }

    func testAFiveThousandFrameCrashSignatureIsTheCrashSite() {
        // End to end with F2: the stack is cut at 300 levels, but the crash site (the root of a per-thread tree) is intact.
        let perThread = signature(Fix2Payload.crash(frames: 5000, perThread: true))
        XCTAssertEqual(perThread, "6/5/Namespace SIGNAL, Code 5 | f0+0 < f1+1 < f2+2")
        // A main-thread style tree has its newest frame deepest, which here is the deepest one kept.
        let deepest = signature(Fix2Payload.crash(frames: 5000, perThread: false))
        XCTAssertEqual(deepest, "6/5/Namespace SIGNAL, Code 5 | f147+147 < f146+146 < f145+145")
    }

    func testTheReportBuilderUsesTheSameOrder() {
        let report = DiagnosticReportBuilder.diagnostic(
            kind: .crash, json: Data(chain(perThread: "true").utf8), id: Fix2Path.id, at: B8.date(0), now: B8.date(1),
            running: .fix2, crumbs: [])
        XCTAssertEqual(report.signature, "A+1 < B+2 < C+3")
    }
}

// MARK: F4 (S2): reading the queue

final class Build8Fix2QueueReadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("fix2-queue") }
    override func tearDown() { B8.remove(directory) }

    private func file(_ n: Int) -> URL {
        directory.appendingPathComponent(B8.report(n).id.uuidString.lowercased() + ".json")
    }

    private func requireDenied(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        if FileManager.default.isReadableFile(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            throw XCTSkip("this account can read a mode 000 file (running as root?), so it cannot test an unreadable file")
        }
    }

    func testAFileThatCannotBeReadIsKeptAndSkipped() throws {
        let queue = DiagnosticQueue(directory: directory)
        queue.add(B8.report(1))
        queue.add(B8.report(2))
        try requireDenied(file(1))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(1).path) }
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(2).id], "skipped, not returned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(1).path), "an unreadable file must not be deleted")
    }

    func testTheKeptFileIsBackOnceItCanBeReadAgain() throws {
        let queue = DiagnosticQueue(directory: directory)
        queue.add(B8.report(1))
        try requireDenied(file(1))
        XCTAssertEqual(queue.pending(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(1).path), "kept on the first look")
        XCTAssertEqual(queue.pending(), [], "still kept on the second look")
        guard FileManager.default.fileExists(atPath: file(1).path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(1).path)
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(1).id])
    }

    func testAFileThatReadsButDoesNotDecodeIsStillDeleted() throws {
        let queue = DiagnosticQueue(directory: directory)
        queue.add(B8.report(1))
        try Data("{\"not\":\"a report\"}".utf8).write(to: file(2))
        try Data([0xFF, 0xFE, 0x00]).write(to: file(3))
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(1).id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(2).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(3).path))
    }

    func testAnUnreadableFileDoesNotStopTheCorruptOneBesideItFromBeingDeleted() throws {
        let queue = DiagnosticQueue(directory: directory)
        queue.add(B8.report(1))
        try Data("garbage".utf8).write(to: file(2))
        try requireDenied(file(1))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(1).path) }
        XCTAssertEqual(queue.pending(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(2).path))
    }
}

// MARK: F7 (S2): background CPU limit exits

final class Build8Fix2ExitCountsTests: XCTestCase {
    private func counts(_ background: String, foreground: String = "") -> ExitCounts {
        let fg = foreground.isEmpty ? "" : "\"foregroundExitData\":{\(foreground)},"
        return ExitCounts(json: Data("{\"applicationExitMetrics\":{\(fg)\"backgroundExitData\":{\(background)}}}".utf8))
    }

    func testABackgroundCPULimitExitIsAProblem() {
        let found = counts("\"cumulativeCPUResourceLimitExitCount\":3")
        XCTAssertTrue(found.hasProblem)
        XCTAssertEqual(found.background.total, 3)
        XCTAssertEqual(found.foreground.total, 0)
    }

    func testItIsKeptInExitsLikeTheOthers() throws {
        let found = counts("\"cumulativeCPUResourceLimitExitCount\":3")
        guard case .object(let root) = found.report, case .object(let exits)? = root["exits"] else { return XCTFail("\(found.report)") }
        XCTAssertEqual(exits.count, 1, "exactly the one non-zero count: \(exits)")
        let (key, value) = try XCTUnwrap(exits.first)
        XCTAssertTrue(key.hasPrefix("background."), key)
        XCTAssertEqual(value, .number(3))
        XCTAssertFalse(["background.memoryLimit", "background.watchdog", "background.crash", "background.illegalInstruction",
                        "background.suspendedWithLockedFile", "background.backgroundTaskTimeout", "background.memoryPressure"].contains(key),
                       "it needs a name of its own, not another counter's")
    }

    func testItAddsToTheOtherCountersAndDoesNotReplaceThem() throws {
        let found = counts(
            "\"cumulativeCPUResourceLimitExitCount\":2,\"cumulativeAppWatchdogExitCount\":1,\"cumulativeMemoryPressureExitCount\":4")
        XCTAssertEqual(found.background.total, 7)
        XCTAssertEqual(found.background.watchdog, 1)
        XCTAssertEqual(found.background.memoryPressure, 4)
        guard case .object(let root) = found.report, case .object(let exits)? = root["exits"] else { return XCTFail() }
        XCTAssertEqual(exits.count, 3)
        XCTAssertEqual(exits["background.watchdog"], .number(1))
        XCTAssertEqual(exits["background.memoryPressure"], .number(4))
    }

    func testTheForegroundCPUKeyIsNotCounted() {
        // MXForegroundExitData has no CPU limit counter; the key in the foreground section is not a problem.
        let found = counts("", foreground: "\"cumulativeCPUResourceLimitExitCount\":3")
        XCTAssertFalse(found.hasProblem)
    }

    func testOddValuesStillCountAsNothing() {
        for value in ["0", "-2", "\"3\"", "true", "null", "1e999"] {
            XCTAssertFalse(counts("\"cumulativeCPUResourceLimitExitCount\":\(value)").hasProblem, value)
        }
    }

    func testTheBuilderMakesAnExitReportFromAloneCPULimit() throws {
        let json = Data("{\"applicationExitMetrics\":{\"backgroundExitData\":{\"cumulativeCPUResourceLimitExitCount\":3}}}".utf8)
        let report = try XCTUnwrap(DiagnosticReportBuilder.exits(json: json, id: Fix2Path.id, at: B8.date(0), now: B8.date(1), running: .fix2))
        XCTAssertEqual(report.kind, .exit)
    }
}
