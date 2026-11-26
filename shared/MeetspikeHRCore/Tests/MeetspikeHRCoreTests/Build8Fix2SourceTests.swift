import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8 fix pass 2: the parts of F5, F6 and F8 that live in the app target (ios/MeetspikeHR) and in
// ios/crash-reports.py. The package tests cannot import the app or run MetricKit, so these read the files by path,
// the same way Build8ProjectFilesTests does, and check the decisions the spec fixes. They compile on today's API and
// fail on their assertions. They skip (loudly) when there is no ios/ folder next to the package.
//
// What they cannot check: that MetricKit delivers what the engine expects. The decision order itself is also walked
// over the real primitives in Build8Fix2EngineOrderTests (Build8Fix2ContractTests.swift).

final class Build8Fix2SourceTests: XCTestCase {
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

    private let service = "ios/MeetspikeHR/Sources/Diagnostics/DiagnosticsService.swift"

    /// The text of the function that starts at `signature`, up to the next member function (or the end of the file).
    private func body(of signature: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let start = try XCTUnwrap(text.range(of: signature), "no \(signature)", file: file, line: line)
        let rest = text[start.lowerBound...]
        let after = rest.dropFirst(signature.count)
        let nextFunction = "\n    (?:@\\w+ )?(?:private |static |fileprivate )*func "
        if let next = after.range(of: nextFunction, options: .regularExpression) {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    private func index(of needle: String, in text: String, file: StaticString = #filePath, line: UInt = #line) throws -> String.Index {
        try XCTUnwrap(text.range(of: needle)?.lowerBound, "missing `\(needle)`", file: file, line: line)
    }

    // MARK: F5

    func testEngineFollowsTheSavedBeforeSeenOrder() throws {
        let text = try read(service)
        for signature in ["func handle(diagnostics", "func handle(metrics"] {
            let code = try body(of: signature, in: text)
            let begin = try index(of: "attempts.begin", in: code)
            let add = try index(of: "queue.add", in: code)
            let build = try index(of: "DiagnosticReportBuilder.", in: code)
            XCTAssertLessThan(begin, build, "\(signature): a try is counted before anything is built")
            XCTAssertLessThan(build, add, signature)
            // The id is remembered only after the report is saved.
            let afterAdd = code[add...]
            XCTAssertTrue(afterAdd.contains("seen.insert"), "\(signature): seen.insert must come after queue.add succeeded")
            XCTAssertTrue(afterAdd.contains("attempts.finish"), "\(signature): a saved report clears its tries")
            // Nothing between building and saving may mark it seen.
            XCTAssertFalse(code[build..<add].contains("seen.insert"), "\(signature): seen before saved")
            XCTAssertFalse(code[build..<add].contains("accept("), "\(signature): accept() marked it seen before saved")
        }
    }

    func testEngineSkipsWhatItHasSeenAndChecksBeforeTrying() throws {
        let text = try read(service)
        for signature in ["func handle(diagnostics", "func handle(metrics"] {
            let code = try body(of: signature, in: text)
            XCTAssertTrue(code.contains("seen.contains"), "\(signature): skip an id that is already seen")
            XCTAssertLessThan(try index(of: "seen.contains", in: code), try index(of: "attempts.begin", in: code), signature)
        }
    }

    func testAFailedSaveFinishesTheAttemptAndLeavesTheIdUnseen() throws {
        let text = try read(service)
        for signature in ["func handle(diagnostics", "func handle(metrics"] {
            let code = try body(of: signature, in: text)
            let occurrences = code.components(separatedBy: "attempts.finish").count - 1
            XCTAssertGreaterThanOrEqual(occurrences, 2, "\(signature): finish on success and on a failed save, so a full disk costs no tries")
            XCTAssertTrue(code.contains("if queue.add(") || code.contains("guard queue.add(") || code.contains("= queue.add("),
                          "\(signature): the result of queue.add decides what happens next")
        }
    }

    func testTheEngineUsesDiagnosticAttemptsInItsOwnFile() throws {
        let text = try read(service)
        XCTAssertTrue(text.contains("DiagnosticAttempts(file:"), "the engine owns a DiagnosticAttempts")
        XCTAssertFalse(text.contains("guard accept("), "the old accept() marked the id seen before the report was saved")
    }

    func testTheSwitchOffPathStillRemembersTheIdWithoutATry() throws {
        let text = try read(service)
        let code = try body(of: "func handle(diagnostics", in: text)
        XCTAssertTrue(code.contains("shouldQueue("), "the switch and demo mode are still checked")
        let allowed = try index(of: "shouldQueue(", in: code)
        XCTAssertLessThan(allowed, try index(of: "attempts.begin", in: code), "off means no try is spent")
        XCTAssertTrue(code[allowed...].prefix(300).contains("seen.insert"), "off: remember the id so the report does not appear later")
    }

    // MARK: F6

    func testCrumbsAreDecidedByThePolicyAndOnlyLiveDeliveryIsLive() throws {
        let text = try read(service)
        XCTAssertTrue(text.contains("DiagnosticPolicy.attachCrumbs(crashCount:"), "the decision is the pure policy function")
        XCTAssertTrue(text.contains("live:"), "handle() is told where the payloads came from")
        // didReceive is live, pastDiagnosticPayloads is not.
        let didReceive = try body(of: "func didReceive(_ payloads: [MXDiagnosticPayload])", in: text)
        XCTAssertTrue(didReceive.range(of: "live:\\s*true", options: .regularExpression) != nil, "didReceive(_: [MXDiagnosticPayload]) is live delivery")
        let start = try body(of: "func start(demo: Bool)", in: text)
        let pastIndex = try index(of: "pastDiagnosticPayloads", in: start)
        XCTAssertTrue(start[pastIndex...].range(of: "live:\\s*false", options: .regularExpression) != nil,
                      "pastDiagnosticPayloads is never live")
        XCTAssertFalse(start.range(of: "live:\\s*true", options: .regularExpression) != nil, "nothing at launch is live")
    }

    func testTheCrashCountIsOverTheWholeCallNotPerPayload() throws {
        let text = try read(service)
        let code = try body(of: "func handle(diagnostics", in: text)
        let policy = try index(of: "attachCrumbs(crashCount:", in: code)
        // The count is taken before any item is turned into a report.
        XCTAssertLessThan(policy, try index(of: "DiagnosticReportBuilder.diagnostic", in: code))
        XCTAssertFalse(code.contains("crashCount: 1"), "a literal 1 would defeat the count")
    }

    func testTheCrumbsAreOnlyReadWhenTheyWillBeUsed() throws {
        let text = try read(service)
        let code = try body(of: "func handle(diagnostics", in: text)
        let policy = try index(of: "attachCrumbs(crashCount:", in: code)
        let read = try index(of: "previousSession()", in: code)
        XCTAssertLessThan(policy, read, "ask the policy first; do not read the session for a crash that gets none")
    }

    func testCrashReportsToolSaysTheCrumbsMayBeFromAnotherSession() throws {
        let script = try read("ios/crash-reports.py")
        let sentence = "From the session before the report arrived. Compare the times with the crash time."
        XCTAssertTrue(script.contains(sentence), "the exact line the spec gives")
        let lines = script.components(separatedBy: "\n")
        let title = try XCTUnwrap(lines.firstIndex { $0.contains("Breadcrumbs (") }, "the breadcrumbs title line")
        let note = try XCTUnwrap(lines.firstIndex { $0.contains(sentence) })
        let loop = try XCTUnwrap(lines.firstIndex { $0.contains("for crumb in crumbs") })
        XCTAssertGreaterThan(note, title, "under the title")
        XCTAssertLessThan(note, loop, "before the crumbs")
        XCTAssertLessThan(note - title, 4, "right under the title")
        XCTAssertTrue(lines[note].contains("print("), "it is printed")
    }

    func testCrashReportsToolStillPrintsTheCrumbsAfterTheNote() throws {
        let script = try read("ios/crash-reports.py")
        XCTAssertTrue(script.contains("print(f\"  {clean(crumb, 200)}\")"), "the crumb lines are unchanged")
    }

    // MARK: F8

    func testEngineRecordsSentIDsAndPassesThemToTheLine() throws {
        let text = try read(service)
        XCTAssertTrue(text.contains("sentIDs"), "the engine keeps the ids the Worker took")
        XCTAssertTrue(text.range(of: "sentIDs:\\s*\\w", options: .regularExpression) != nil, "and hands them to testLine")
        let send = try body(of: "private func send(to target", in: text)
        XCTAssertTrue(send.contains("sentIDs.insert") || send.contains("sentIDs.formUnion"), "recorded when the outcome is .sent")
        XCTAssertLessThan(try index(of: ".sent", in: send), try index(of: "sentIDs.insert", in: send), "after the outcome is known")
    }
}
