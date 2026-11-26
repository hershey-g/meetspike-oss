import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

// Build 8, track `app`, D5 + D6: the on-disk queue and the uploader. Helpers (B8) are in Build8DiagnosticReportTests.swift.
//
// Names the builder must provide:
//
//   public struct DiagnosticQueue: Sendable
//       public init(directory: URL, maxFiles: Int = 20)       non-failing; the directory is created on first add
//       public func add(_ report: DiagnosticReport)           non-mutating, never throws; one file `<lowercase uuid>.json`
//                                                             per report holding the JSON the wire body uses; the same id
//                                                             again replaces the file; when more than maxFiles would be
//                                                             left, the reports with the oldest `at` are deleted (the new
//                                                             one included if it is the oldest)
//       public func pending() -> [DiagnosticReport]           sorted by `at` ascending (ties by id string); a file that
//                                                             does not decode is deleted and skipped
//       public func remove(id: UUID)                          unknown id does nothing
//
//   public enum DiagnosticUploader
//       public enum Outcome: Equatable, Sendable { case sent, retryLater, reject }
//       public static func outcome(status: Int?) -> Outcome   nil is "no HTTP answer" (network error)
//       public static func send(queue: DiagnosticQueue, send: (DiagnosticReport) async -> Outcome) async
//           one report at a time, oldest first, the closure is called once per report; .sent and .reject delete the
//           file and go on; .retryLater keeps the file and stops
//       public static func request(report: DiagnosticReport, destination: Destination, credentials: Credentials) throws -> URLRequest
//           POST `<destination.origin>/api/whoop-web/app/diagnostics`, body is the report's wire JSON, headers as
//           Uploader.request sets them (Content-Type, Accept, Bearer ingest secret, CF-Access pair only when both valid)

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    var all: [UUID] { lock.lock(); defer { lock.unlock() }; return ids }

    func enter(_ id: UUID) {
        lock.lock(); ids.append(id); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
    }

    func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
}

final class Build8QueueTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("queue") }
    override func tearDown() { B8.remove(directory) }

    private func ids(_ reports: [DiagnosticReport]) -> [UUID] { reports.map(\.id) }

    func testStartsEmptyAndDoesNotNeedTheDirectory() {
        XCTAssertEqual(DiagnosticQueue(directory: directory).pending(), [])
        let missing = directory.appendingPathComponent("not/yet", isDirectory: true)
        XCTAssertEqual(DiagnosticQueue(directory: missing).pending(), [])
        DiagnosticQueue(directory: missing).add(B8.report(1))
        XCTAssertEqual(DiagnosticQueue(directory: missing).pending().count, 1)
    }

    func testReportsComeBackEqualAndOldestFirst() {
        let queue = DiagnosticQueue(directory: directory)
        let reports = (1...4).map { B8.report($0) }
        for report in reports { queue.add(report) }
        XCTAssertEqual(queue.pending(), reports)
    }

    func testOrderFollowsTheReportDateNotTheOrderOfAdding() {
        let queue = DiagnosticQueue(directory: directory)
        for n in [3, 1, 4, 2] { queue.add(B8.report(n)) }
        XCTAssertEqual(ids(queue.pending()), (1...4).map { B8.report($0).id })
    }

    func testEqualDatesAreOrderedByIDSoTheOrderIsStable() {
        let queue = DiagnosticQueue(directory: directory)
        for n in [3, 1, 2] { queue.add(B8.report(n, at: 7)) }
        XCTAssertEqual(ids(queue.pending()), (1...3).map { B8.report($0).id })
    }

    func testSurvivesANewInstanceOnTheSameDirectory() {
        DiagnosticQueue(directory: directory).add(B8.report(1))
        XCTAssertEqual(DiagnosticQueue(directory: directory).pending(), [B8.report(1)])
    }

    func testOneFilePerReportNamedByLowercaseUUID() {
        let queue = DiagnosticQueue(directory: directory)
        for n in 1...3 { queue.add(B8.report(n)) }
        XCTAssertEqual(B8.files(in: directory), (1...3).map { B8.report($0).id.uuidString.lowercased() + ".json" }.sorted())
    }

    func testAFileHoldsTheWireBody() throws {
        let queue = DiagnosticQueue(directory: directory)
        let report = B8.report(5, signature: "sig")
        queue.add(report)
        let file = directory.appendingPathComponent(report.id.uuidString.lowercased() + ".json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["app"] as? String, "ios")
        XCTAssertEqual(object["id"] as? String, report.id.uuidString.lowercased())
        XCTAssertEqual(object["signature"] as? String, "sig")
    }

    func testTheSameIDTwiceIsOneFile() {
        let queue = DiagnosticQueue(directory: directory)
        var report = B8.report(1)
        queue.add(report)
        report.signature = "second"
        queue.add(report)
        XCTAssertEqual(B8.files(in: directory).count, 1)
        XCTAssertEqual(queue.pending(), [report])
    }

    func testOverTheLimitTheOldestAreDropped() {
        let queue = DiagnosticQueue(directory: directory, maxFiles: 3)
        for n in 1...5 { queue.add(B8.report(n)) }
        XCTAssertEqual(ids(queue.pending()), (3...5).map { B8.report($0).id })
        XCTAssertEqual(B8.files(in: directory).count, 3, "the dropped ones are gone from disk too")
    }

    func testANewReportOlderThanEverythingIsTheOneThatGoes() {
        let queue = DiagnosticQueue(directory: directory, maxFiles: 3)
        for n in [5, 4, 3, 2, 1] { queue.add(B8.report(n)) }
        XCTAssertEqual(ids(queue.pending()), (3...5).map { B8.report($0).id })
        XCTAssertEqual(B8.files(in: directory).count, 3)
    }

    func testDefaultLimitIs20() {
        let queue = DiagnosticQueue(directory: directory)
        for n in 1...25 { queue.add(B8.report(n)) }
        XCTAssertEqual(ids(queue.pending()), (6...25).map { B8.report($0).id })
    }

    func testReplacingAtTheLimitDropsNothing() {
        let queue = DiagnosticQueue(directory: directory, maxFiles: 3)
        for n in 1...3 { queue.add(B8.report(n)) }
        var again = B8.report(2)
        again.signature = "again"
        queue.add(again)
        XCTAssertEqual(queue.pending().count, 3)
        XCTAssertEqual(queue.pending()[safe: 1]?.signature, "again")
    }

    func testRemoveDeletesTheFile() {
        let queue = DiagnosticQueue(directory: directory)
        for n in 1...3 { queue.add(B8.report(n)) }
        queue.remove(id: B8.report(2).id)
        XCTAssertEqual(ids(queue.pending()), [B8.report(1).id, B8.report(3).id])
        XCTAssertEqual(B8.files(in: directory).count, 2)
        queue.remove(id: B8.report(2).id)
        queue.remove(id: UUID())
        XCTAssertEqual(queue.pending().count, 2)
    }

    func testACorruptFileIsDeletedAndTheRestStillComeBack() throws {
        let queue = DiagnosticQueue(directory: directory)
        queue.add(B8.report(1))
        queue.add(B8.report(3))
        let bad: [(String, Data)] = [
            ("garbage", Data("not json at all".utf8)),
            ("truncated", Data(#"{"id":"00000000-0000-4000-8000-000000000002","kind":"cra"#.utf8)),
            ("empty", Data()),
            ("wrongshape", Data("{}".utf8)),
            ("array", Data("[1,2,3]".utf8)),
            ("binary", Data([0xFF, 0xFE, 0x00, 0x01])),
            ("badkind", Data(#"{"id":"00000000-0000-4000-8000-0000000000aa","kind":"nope","at":"2026-11-25T05:00:00.000Z","app":"ios","build":8,"version":"1.1","os":"x","device":"y","report":{}}"#.utf8)),
        ]
        var names: [String] = []
        for (index, (_, data)) in bad.enumerated() {
            let name = String(format: "00000000-0000-4000-8000-0000000001%02d.json", index)
            try data.write(to: directory.appendingPathComponent(name))
            names.append(name)
        }
        XCTAssertEqual(ids(queue.pending()), [B8.report(1).id, B8.report(3).id])
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "\(name) should be deleted")
        }
        XCTAssertEqual(B8.files(in: directory).count, 2)
        // Asking again is fine.
        XCTAssertEqual(queue.pending().count, 2)
    }

    func testACorruptFileDoesNotStopAnAddOrTheLimit() throws {
        let queue = DiagnosticQueue(directory: directory, maxFiles: 2)
        try Data("junk".utf8).write(to: directory.appendingPathComponent("00000000-0000-4000-8000-000000000f00.json"))
        for n in 1...3 { queue.add(B8.report(n)) }
        XCTAssertEqual(ids(queue.pending()), [B8.report(2).id, B8.report(3).id])
    }

    func testAnUnwritableDirectoryNeverThrowsOrCrashes() throws {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let queue = DiagnosticQueue(directory: blocker)
        queue.add(B8.report(1))
        XCTAssertEqual(queue.pending(), [])
        queue.remove(id: B8.report(1).id)
    }

    func testManyThreadsAddingAndRemovingAtOnce() {
        let queue = DiagnosticQueue(directory: directory, maxFiles: 1000)
        DispatchQueue.concurrentPerform(iterations: 6) { thread in
            for n in 0..<15 {
                queue.add(B8.report(thread * 100 + n + 1))
                if n % 4 == 0 { _ = queue.pending() }   // reading while others write must not delete a half-written file
            }
        }
        XCTAssertEqual(queue.pending().count, 90)
        DispatchQueue.concurrentPerform(iterations: 6) { thread in
            for n in 0..<15 where n % 2 == 0 { queue.remove(id: B8.report(thread * 100 + n + 1).id) }
        }
        XCTAssertEqual(queue.pending().count, 42)
    }

    func testAReportWithLargeContentRoundTrips() {
        var report = B8.report(1)
        report.report = .object(["message": .string(String(repeating: "é", count: 500)), "list": .array((0..<500).map { .number(Double($0)) })])
        report.crumbs = (0..<150).map { "2026-11-25T05:00:00.000Z dayLoad \($0)ms ok" }
        let queue = DiagnosticQueue(directory: directory)
        queue.add(report)
        XCTAssertEqual(queue.pending(), [report])
    }

    func testQueueIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        _ = requireSendable(DiagnosticQueue(directory: directory))
    }
}

final class Build8UploaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("uploader") }
    override func tearDown() { B8.remove(directory) }

    private func filled(_ count: Int) -> DiagnosticQueue {
        let queue = DiagnosticQueue(directory: directory)
        for n in 1...count { queue.add(B8.report(n)) }
        return queue
    }

    private func id(_ n: Int) -> UUID { B8.report(n).id }

    // MARK: Status mapping

    func testStatusMapping() {
        for status in [200, 201, 202, 204, 206, 250, 299] { XCTAssertEqual(DiagnosticUploader.outcome(status: status), .sent, "\(status)") }
        for status in [400, 413] { XCTAssertEqual(DiagnosticUploader.outcome(status: status), .reject, "\(status)") }
        for status in [100, 101, 199, 300, 301, 302, 303, 307, 308, 399, 401, 402, 403, 404, 405, 408, 409, 410, 414, 415, 418,
                       422, 425, 429, 451, 499, 500, 501, 502, 503, 504, 507, 520, 522, 524, 599, 600, 0, -1, 1000] {
            XCTAssertEqual(DiagnosticUploader.outcome(status: status), .retryLater, "\(status)")
        }
        XCTAssertEqual(DiagnosticUploader.outcome(status: nil), .retryLater, "no answer is a network failure")
    }

    // MARK: send

    func testSendsOldestFirstAndEmptiesTheQueue() async {
        let queue = filled(4)
        let calls = Calls()
        await DiagnosticUploader.send(queue: queue) { report in
            calls.enter(report.id)
            defer { calls.leave() }
            return .sent
        }
        XCTAssertEqual(calls.all, (1...4).map(id))
        XCTAssertEqual(queue.pending(), [])
        XCTAssertEqual(B8.files(in: directory), [])
    }

    func testSendsOneAtATime() async {
        let queue = filled(5)
        let calls = Calls()
        await DiagnosticUploader.send(queue: queue) { report in
            calls.enter(report.id)
            try? await Task.sleep(nanoseconds: 5_000_000)
            calls.leave()
            return .sent
        }
        XCTAssertEqual(calls.maxInFlight, 1)
        XCTAssertEqual(calls.all.count, 5)
    }

    func testRetryLaterKeepsTheFileAndStops() async {
        let queue = filled(4)
        let calls = Calls()
        await DiagnosticUploader.send(queue: queue) { report in
            calls.enter(report.id)
            return report.id == B8.report(2).id ? .retryLater : .sent
        }
        XCTAssertEqual(calls.all, [id(1), id(2)], "3 and 4 are not tried after a retryLater")
        XCTAssertEqual(queue.pending().map(\.id), [id(2), id(3), id(4)])
    }

    func testRetryLaterOnTheFirstSendsNothingElse() async {
        let queue = filled(3)
        let calls = Calls()
        await DiagnosticUploader.send(queue: queue) { report in calls.enter(report.id); return .retryLater }
        XCTAssertEqual(calls.all, [id(1)])
        XCTAssertEqual(queue.pending().count, 3)
    }

    func testRejectDeletesTheFileAndGoesOn() async {
        let queue = filled(3)
        let calls = Calls()
        await DiagnosticUploader.send(queue: queue) { report in
            calls.enter(report.id)
            return report.id == B8.report(1).id ? .reject : .sent
        }
        XCTAssertEqual(calls.all, [id(1), id(2), id(3)])
        XCTAssertEqual(queue.pending(), [])
    }

    func testMixedOutcomes() async {
        let queue = filled(5)
        let calls = Calls()
        let script: [UUID: DiagnosticUploader.Outcome] = [id(1): .sent, id(2): .reject, id(3): .retryLater, id(4): .sent, id(5): .sent]
        await DiagnosticUploader.send(queue: queue) { report in calls.enter(report.id); return script[report.id] ?? .retryLater }
        XCTAssertEqual(calls.all, [id(1), id(2), id(3)])
        XCTAssertEqual(queue.pending().map(\.id), [id(3), id(4), id(5)])
    }

    func testAnEmptyQueueNeverCallsTheClosure() async {
        let calls = Calls()
        await DiagnosticUploader.send(queue: DiagnosticQueue(directory: directory)) { report in calls.enter(report.id); return .sent }
        XCTAssertEqual(calls.all, [])
    }

    func testTheClosureGetsTheStoredReportIntact() async {
        let queue = DiagnosticQueue(directory: directory)
        let report = B8.report(9, signature: "Foundation+777 < SwiftUI+5532160")
        queue.add(report)
        let seen = Calls()
        let got = Box()
        await DiagnosticUploader.send(queue: queue) { sent in seen.enter(sent.id); got.value = sent; return .sent }
        XCTAssertEqual(got.value, report)
    }

    func testRunningItAgainAfterARetrySendsTheRemainder() async {
        let queue = filled(3)
        let first = Calls()
        await DiagnosticUploader.send(queue: queue) { report in
            first.enter(report.id)
            return report.id == B8.report(2).id ? .retryLater : .sent
        }
        let second = Calls()
        await DiagnosticUploader.send(queue: queue) { report in second.enter(report.id); return .sent }
        XCTAssertEqual(second.all, [id(2), id(3)])
        XCTAssertEqual(queue.pending(), [])
    }

    func testAReportAddedWhileSendingIsNotLostAndThereIsNoDuplicateSend() async {
        let queue = filled(2)
        let calls = Calls()
        await DiagnosticUploader.send(queue: queue) { report in
            calls.enter(report.id)
            if report.id == B8.report(1).id { queue.add(B8.report(3)) }
            return .sent
        }
        let sent = calls.all
        XCTAssertEqual(Set(sent).count, sent.count, "no report is sent twice")
        XCTAssertTrue(Set(queue.pending().map(\.id)).isDisjoint(with: sent), "what was sent is gone, and the rest is still queued")
        XCTAssertEqual(Set(sent).union(queue.pending().map(\.id)), [id(1), id(2), id(3)])
    }

    private final class Box: @unchecked Sendable {
        var value: DiagnosticReport?
    }

    // MARK: request

    private let destination = Destination("https://meetspike-demo.example.workers.dev")!

    func testRequestShape() throws {
        let report = B8.report(7, signature: "sig")
        let request = try DiagnosticUploader.request(report: report, destination: destination, credentials: .init(ingestSecret: "s3cret-ingest"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://meetspike-demo.example.workers.dev/api/whoop-web/app/diagnostics")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s3cret-ingest")
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticReport.self, from: body), report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["app"] as? String, "ios")
        XCTAssertLessThan(body.count, 256 * 1024)
    }

    func testRequestUsesTheOriginWhateverTheOtherEndpointsAre() throws {
        let local = try XCTUnwrap(Destination("http://localhost:8787"))
        let request = try DiagnosticUploader.request(report: B8.report(1), destination: local, credentials: .init(ingestSecret: "x"))
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8787/api/whoop-web/app/diagnostics")
        let port = try XCTUnwrap(Destination(" HTTPS://example.invalid:8443/ "))
        let other = try DiagnosticUploader.request(report: B8.report(1), destination: port, credentials: .init(ingestSecret: "x"))
        XCTAssertEqual(other.url?.absoluteString, "https://example.invalid:8443/api/whoop-web/app/diagnostics")
    }

    func testAccessHeadersOnlyWhenBothAreValid() throws {
        let both = try DiagnosticUploader.request(
            report: B8.report(1), destination: destination,
            credentials: .init(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: "fixture-key")
        )
        XCTAssertEqual(both.value(forHTTPHeaderField: "CF-Access-Client-Id"), "fixture-id")
        XCTAssertEqual(both.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "fixture-key")
        XCTAssertEqual(both.value(forHTTPHeaderField: "Authorization"), "Bearer dummy")

        let incomplete: [Credentials] = [
            .init(ingestSecret: "dummy", accessID: "fixture-id"),
            .init(ingestSecret: "dummy", accessSecret: "fixture-key"),
            .init(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: ""),
            .init(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: "invalid\nvalue"),
            .init(ingestSecret: "dummy", accessID: "has space", accessSecret: "fixture-key"),
        ]
        for credentials in incomplete {
            let request = try DiagnosticUploader.request(report: B8.report(1), destination: destination, credentials: credentials)
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy")
        }
    }

    func testNoSecretEverEndsUpInTheURLOrBody() throws {
        let request = try DiagnosticUploader.request(
            report: B8.report(1), destination: destination,
            credentials: .init(ingestSecret: "SECRET-INGEST", accessID: "SECRET-ID", accessSecret: "SECRET-KEY")
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        for secret in ["SECRET-INGEST", "SECRET-ID", "SECRET-KEY"] {
            XCTAssertFalse(url.contains(secret))
            XCTAssertFalse(body.contains(secret))
        }
        XCTAssertNil(request.url?.query)
    }

    func testRequestIsAFreshRequestEachTime() throws {
        let a = try DiagnosticUploader.request(report: B8.report(1), destination: destination, credentials: .init(ingestSecret: "x"))
        let b = try DiagnosticUploader.request(report: B8.report(2), destination: destination, credentials: .init(ingestSecret: "x"))
        XCTAssertNotEqual(a.httpBody, b.httpBody)
    }
}
