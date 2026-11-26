import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

// Build 8 fix pass 2, F1 (S1): no part of making, saving, loading or sending a report may overflow a 512 KB stack.
//
// Production runs the whole thing inside `actor DiagnosticsEngine`, on a Swift concurrency thread (512 KB stack on
// iOS and macOS). Each MetricKit frame is two container levels, and the scrubber lets 300 levels through, so a
// 148-frame report is a 300-level DiagnosticValue. JSONEncoder, JSONDecoder and the synthesized release of an
// indirect enum all recurse once per level.
//
// Compiles on today's code on purpose (it names no new API), so it can be run to see it fail. On today's code the
// 147, 150 and 300 frame cases CRASH the test process (stack overflow in JSONEncoder inside DiagnosticQueue.add),
// the 5,000 frame case fails on its assertions (the scrubber hands back `{}`), 92 frames passes. After the fix every
// case passes, because DiagnosticStack moves the work onto a 16 MB thread.
//
// The test code itself never recurses over a deep value on the small stack: it asserts on scalars that the path
// hands back, and looks at the deep value only afterwards, on the test's own 8 MB main thread.

/// What one trip through the whole path leaves behind. Plain values only, so handing it between threads is safe.
struct Fix2PathResult: Sendable {
    var stackBytes = 0
    var scrubbedKeys: [String] = []
    var builtBuild = 0
    var built = false
    var added = false
    var pendingCount = 0
    var pendingID: UUID?
    var requestBody: Data?
    var requestThrew = false
    var queuedFileBytes = 0
}

enum Fix2Path {
    static let id = UUID(uuidString: "0F1F2F3F-0000-4000-8000-0000000000F1")!
    static let destination = Destination("https://meetspike-demo.example.workers.dev")!

    /// scrub, DiagnosticReportBuilder.diagnostic, queue.add, pending, DiagnosticUploader.request, then release of
    /// every deep value, all on the calling thread (each deep value goes out of scope before this returns).
    static func run(frames: Int, directory: URL) -> Fix2PathResult {
        var result = Fix2PathResult()
        #if canImport(Darwin)
        result.stackBytes = Int(pthread_get_stacksize_np(pthread_self()))
        #endif
        let json = Data(Fix2Payload.crash(frames: frames).utf8)
        let queue = DiagnosticQueue(directory: directory)
        do {
            let scrubbed = DiagnosticScrubber.scrub(json)
            if case .object(let root) = scrubbed { result.scrubbedKeys = root.keys.sorted() }
        }
        do {
            let report = DiagnosticReportBuilder.diagnostic(
                kind: .crash, json: json, id: id, at: B8.date(0), now: B8.date(60), running: .fix2, crumbs: ["a crumb"])
            result.built = true
            result.builtBuild = report.build
            queue.add(report)
        }
        do {
            let pending = queue.pending()
            result.pendingCount = pending.count
            result.pendingID = pending.first?.id
            if let first = pending.first {
                do {
                    let request = try DiagnosticUploader.request(
                        report: first, destination: destination, credentials: .init(ingestSecret: "s3cret"))
                    result.requestBody = request.httpBody
                } catch {
                    result.requestThrew = true
                }
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasSuffix(".json") {
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            result.queuedFileBytes += size ?? 0
        }
        return result
    }
}

final class Fix2Box<Value: Sendable>: @unchecked Sendable { var value: Value? }

/// Runs a closure on a `Thread` with the 512 KB stack the engine's concurrency threads have, and waits.
func fix2OnSmallThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    let box = Fix2Box<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    done.wait()
    return box.value!
}

actor Fix2Engine {
    func run(frames: Int, directory: URL) -> Fix2PathResult { Fix2Path.run(frames: frames, directory: directory) }
}

final class Build8Fix2StackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("fix2-stack") }
    override func tearDown() { B8.remove(directory) }

    /// What must hold after the whole path, whatever the frame count. The deep value is looked at here, on 8 MB.
    private func assertWholePath(_ result: Fix2PathResult, frames: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(result.built, file: file, line: line)
        XCTAssertEqual(result.pendingCount, 1, "the report must be saved and read back", file: file, line: line)
        XCTAssertEqual(result.pendingID, Fix2Path.id, file: file, line: line)
        XCTAssertFalse(result.requestThrew, "request() must not throw for a body this size", file: file, line: line)
        XCTAssertGreaterThan(result.queuedFileBytes, 1000, "the queue file is the report, not an empty object", file: file, line: line)
        // The scrubbed report keeps its metadata at every frame count (the build is the crashed one, 8, not the running 99).
        XCTAssertEqual(result.builtBuild, 8, "metadata must survive: build comes from the diagnostic, not the running app", file: file, line: line)
        XCTAssertTrue(result.scrubbedKeys.contains("callStackTree"), "\(result.scrubbedKeys)", file: file, line: line)
        XCTAssertTrue(result.scrubbedKeys.contains("diagnosticMetaData"), "\(result.scrubbedKeys)", file: file, line: line)
        let body = try XCTUnwrap(result.requestBody, file: file, line: line)
        XCTAssertLessThan(body.count, DiagnosticUploader.maxBodyBytes, file: file, line: line)
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: body)
        XCTAssertEqual(decoded.id, Fix2Path.id, file: file, line: line)
        XCTAssertEqual(decoded.build, 8, file: file, line: line)
        XCTAssertEqual(decoded.version, "1.1", file: file, line: line)
        XCTAssertEqual(decoded.crumbs, ["a crumb"], file: file, line: line)
        XCTAssertEqual(B8.depth(decoded.report), Fix2Payload.keptDepth(frames: frames), "depth of what was sent", file: file, line: line)
        XCTAssertEqual(Fix2Payload.metaValue(decoded.report, "signal"), .number(5), file: file, line: line)
        let names = Fix2Payload.chainNames(decoded.report)
        XCTAssertEqual(names.first, "f0", file: file, line: line)
        XCTAssertEqual(names.count, min(frames, 148), file: file, line: line)
        XCTAssertNotNil(decoded.signature, "the signature is made from the shallow frames", file: file, line: line)
    }

    // MARK: A Thread with a 512 KB stack

    func testTheSmallThreadReallyHasASmallStack() {
        let size = fix2OnSmallThread { () -> Int in
            #if canImport(Darwin)
            return Int(pthread_get_stacksize_np(pthread_self()))
            #else
            return 512 * 1024
            #endif
        }
        XCTAssertLessThanOrEqual(size, 600_000, "this file proves nothing if the thread is not small")
    }

    func testWholePathAt92FramesOnA512KBThread() throws {
        let dir = directory!
        let result = fix2OnSmallThread { Fix2Path.run(frames: 92, directory: dir) }
        try assertWholePath(result, frames: 92)
    }

    func testWholePathAt147FramesOnA512KBThread() throws {
        let dir = directory!
        let result = fix2OnSmallThread { Fix2Path.run(frames: 147, directory: dir) }
        try assertWholePath(result, frames: 147)
    }

    func testWholePathAt150FramesOnA512KBThread() throws {
        let dir = directory!
        let result = fix2OnSmallThread { Fix2Path.run(frames: 150, directory: dir) }
        try assertWholePath(result, frames: 150)
    }

    func testWholePathAt300FramesOnA512KBThread() throws {
        let dir = directory!
        let result = fix2OnSmallThread { Fix2Path.run(frames: 300, directory: dir) }
        try assertWholePath(result, frames: 300)
    }

    func testWholePathAt5000FramesOnA512KBThread() throws {
        let dir = directory!
        let result = fix2OnSmallThread { Fix2Path.run(frames: 5000, directory: dir) }
        try assertWholePath(result, frames: 5000)
    }

    // MARK: A detached task on an actor, the way DiagnosticsEngine runs

    func testTheConcurrencyThreadReallyIsSmall() async {
        #if canImport(Darwin)
        let engine = Fix2Engine()
        let result = await Task.detached(priority: .utility) { await engine.run(frames: 1, directory: self.directory) }.value
        XCTAssertLessThanOrEqual(result.stackBytes, 600_000, "the actor tests below prove nothing if this thread is big")
        #endif
    }

    private func onActor(_ frames: Int) async -> Fix2PathResult {
        let engine = Fix2Engine()
        let dir = directory!
        return await Task.detached(priority: .utility) { await engine.run(frames: frames, directory: dir) }.value
    }

    func testWholePathAt92FramesInADetachedTaskOnAnActor() async throws {
        try assertWholePath(await onActor(92), frames: 92)
    }

    func testWholePathAt147FramesInADetachedTaskOnAnActor() async throws {
        try assertWholePath(await onActor(147), frames: 147)
    }

    func testWholePathAt150FramesInADetachedTaskOnAnActor() async throws {
        try assertWholePath(await onActor(150), frames: 150)
    }

    func testWholePathAt300FramesInADetachedTaskOnAnActor() async throws {
        try assertWholePath(await onActor(300), frames: 300)
    }

    func testWholePathAt5000FramesInADetachedTaskOnAnActor() async throws {
        try assertWholePath(await onActor(5000), frames: 5000)
    }

    // MARK: Each step on its own (so a failure names the step), at the deepest the scrubber lets through

    /// A 300-level report made on the 8 MB test thread, then handed to each step on a small thread. The report is
    /// released here afterwards, on the big stack, so only the step under test is measured.
    private func deepReport() -> DiagnosticReport {
        DiagnosticReportBuilder.diagnostic(
            kind: .crash, json: Data(Fix2Payload.crash(frames: 148).utf8), id: Fix2Path.id, at: B8.date(0), now: B8.date(60),
            running: .fix2, crumbs: [])
    }

    func testScrubOnItsOwnAt148And5000Frames() {
        for frames in [148, 5000] {
            let json = Data(Fix2Payload.crash(frames: frames).utf8)
            let keys = fix2OnSmallThread { () -> [String] in
                guard case .object(let root) = DiagnosticScrubber.scrub(json) else { return [] }
                return root.keys.sorted()
            }
            XCTAssertEqual(keys, ["callStackTree", "diagnosticMetaData"], "\(frames) frames")
        }
    }

    func testBuilderOnItsOwnAt148Frames() {
        let json = Data(Fix2Payload.crash(frames: 148).utf8)
        let (signature, build) = fix2OnSmallThread { () -> (String?, Int) in
            let report = DiagnosticReportBuilder.diagnostic(
                kind: .crash, json: json, id: Fix2Path.id, at: B8.date(0), now: B8.date(60), running: .fix2, crumbs: [])
            return (report.signature, report.build)
        }
        XCTAssertNotNil(signature)
        XCTAssertEqual(build, 8)
    }

    func testQueueAddOnItsOwnAt148Frames() {
        let report = deepReport()
        let queue = DiagnosticQueue(directory: directory)
        fix2OnSmallThread { queue.add(report) }
        XCTAssertEqual(B8.files(in: directory), [Fix2Path.id.uuidString.lowercased() + ".json"])
    }

    func testQueuePendingOnItsOwnAt148Frames() {
        let queue = DiagnosticQueue(directory: directory)
        queue.add(deepReport())
        let count = fix2OnSmallThread { queue.pending().count }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(B8.files(in: directory).count, 1, "reading it must not delete it")
    }

    func testUploaderRequestOnItsOwnAt148Frames() throws {
        let report = deepReport()
        let bytes = fix2OnSmallThread { () -> Int? in
            try? DiagnosticUploader.request(report: report, destination: Fix2Path.destination, credentials: .init(ingestSecret: "s")).httpBody?.count
        }
        XCTAssertNotNil(bytes)
        XCTAssertLessThan(try XCTUnwrap(bytes), DiagnosticUploader.maxBodyBytes)
    }

    func testReleasingAReportOnASmallThreadDoesNotOverflow() {
        // The last owner of a 300-level value may be on the small thread (pending() results, the report in the
        // engine). It has to be freed without the stack growing 300 levels deep.
        let queue = DiagnosticQueue(directory: directory)
        queue.add(deepReport())
        let ok = fix2OnSmallThread { () -> Bool in
            var held: [DiagnosticReport]? = queue.pending()
            let count = held?.count ?? 0
            held = nil
            return count == 1 && held == nil
        }
        XCTAssertTrue(ok)
    }
}
