import XCTest
@testable import MeetspikeHRCore

// Build 8 regression tests for three small fixes:
//   1. the test-report line (DiagnosticPolicy.testLine) now also knows "refused" and "couldn't save"
//   2. APIClient.askStream tells the request observer exactly once per stream, with the real status
//   3. RequestCrumbFilter keeps the live heart rate poll from filling the crumb trail
// Fake data only.

// MARK: 1. The test report line

final class Build8TestLineTests: XCTestCase {
    private typealias Line = DiagnosticPolicy.TestLine

    private func line(
        _ id: UUID?, pending: Set<UUID> = [], refused: Set<UUID> = [], unsaved: Set<UUID> = []
    ) -> Line {
        DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: pending, refusedIDs: refused, unsavedIDs: unsaved)
    }

    func testTheTextOfEveryLine() {
        XCTAssertNil(Line.none.text)
        XCTAssertEqual(Line.waiting.text, "Not sent yet. It will try again.")
        XCTAssertEqual(Line.sent.text, "Sent.")
        XCTAssertEqual(Line.refused.text, "Not sent. Your server refused it.")
        XCTAssertEqual(Line.notSaved.text, "Couldn't save the report.")
    }

    func testNoTestYetIsNoLineWhateverTheSetsHold() {
        XCTAssertEqual(line(nil), .none)
        XCTAssertEqual(line(nil, pending: [UUID()], refused: [UUID()], unsaved: [UUID()]), .none)
    }

    func testStillInTheQueueIsWaiting() {
        let id = UUID()
        XCTAssertEqual(line(id, pending: [id]), .waiting)
    }

    func testGoneFromTheQueueIsSent() {
        XCTAssertEqual(line(UUID()), .sent)
    }

    func testRefusedIsRefusedAndNeverSent() {
        let id = UUID()
        XCTAssertEqual(line(id, refused: [id]), .refused)
        XCTAssertNotEqual(line(id, refused: [id]).text, "Sent.")
    }

    func testUnsavedIsNotSavedAndNeverSent() {
        let id = UUID()
        XCTAssertEqual(line(id, unsaved: [id]), .notSaved)
        XCTAssertNotEqual(line(id, unsaved: [id]).text, "Sent.")
    }

    func testPriorityIsPendingThenRefusedThenUnsaved() {
        let id = UUID()
        XCTAssertEqual(line(id, pending: [id], refused: [id]), .waiting)
        XCTAssertEqual(line(id, pending: [id], unsaved: [id]), .waiting)
        XCTAssertEqual(line(id, pending: [id], refused: [id], unsaved: [id]), .waiting)
        XCTAssertEqual(line(id, refused: [id], unsaved: [id]), .refused)
    }

    func testOtherIDsInTheSetsDoNotMatter() {
        let id = UUID()
        let others: Set<UUID> = [UUID(), UUID(), UUID()]
        XCTAssertEqual(line(id, pending: others, refused: others, unsaved: others), .sent)
        XCTAssertEqual(line(id, pending: others.union([id])), .waiting)
        XCTAssertEqual(line(id, pending: others, refused: others.union([id]), unsaved: others), .refused)
        XCTAssertEqual(line(id, pending: others, refused: others, unsaved: others.union([id])), .notSaved)
    }

    func testTheNewSetsDefaultToEmpty() {
        let id = UUID()
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: []), .sent)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [id]), .waiting)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: nil, pendingIDs: []), .none)
    }
}

// MARK: 2. askStream and the request observer

private final class FixObserved: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(path: String, status: Int, ms: Int)] = []

    func add(_ path: String, _ status: Int, _ ms: Int) { lock.withLock { items.append((path, status, ms)) } }
    var all: [(path: String, status: Int, ms: Int)] { lock.withLock { items } }
}

final class Build8AskStreamObserverTests: XCTestCase {
    private var request: AskRequest {
        AskRequest(question: "How was my week?", sourceDisplay: .make(oura: true, whoop: true))
    }

    private func client(host: String, seen: FixObserved) -> APIClient {
        APIClient(
            origin: "https://\(host)", credentials: nil, userAgent: "MeetspikeTest/1.0",
            configuration: APIStub.configuration(), observer: { path, status, ms in seen.add(path, status, ms) }
        )!
    }

    /// Reads the whole stream, swallowing a thrown error (some answers throw, some become events).
    private func drain(_ stream: AsyncThrowingStream<AskEvent, Error>) async {
        do { for try await _ in stream {} } catch {}
    }

    private func assertOnce(
        _ seen: FixObserved, status: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let calls = seen.all
        XCTAssertEqual(calls.count, 1, "exactly one observer call", file: file, line: line)
        XCTAssertEqual(calls.first?.path, "/api/ask/stream", "the path with no query", file: file, line: line)
        XCTAssertEqual(calls.first?.status, status, file: file, line: line)
        XCTAssertGreaterThanOrEqual(calls.first?.ms ?? -1, 0, file: file, line: line)
    }

    func testASuccessfulStreamIsOneCallWithStatus200() async throws {
        let host = "fix-stream-200.example.com"
        let data = try APIFixture.data("ask-stream.sse")
        let chunks = stride(from: 0, to: data.count, by: 41).map { Data(data[$0..<min($0 + 41, data.count)]) }
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: chunks) }
        let seen = FixObserved()
        await drain(client(host: host, seen: seen).askStream(request))
        assertOnce(seen, status: 200)
    }

    func testA401IsOneCallWithStatus401() async throws {
        let host = "fix-stream-401.example.com"
        APIStub.register(host: host) { _ in .json(status: 401, body: Data(#"{"error":"no"}"#.utf8)) }
        let seen = FixObserved()
        await drain(client(host: host, seen: seen).askStream(request))
        assertOnce(seen, status: 401)
    }

    func testA500IsOneCallWithStatus500() async throws {
        let host = "fix-stream-500.example.com"
        APIStub.register(host: host) { _ in .json(status: 500, body: Data(#"{"error":"boom"}"#.utf8)) }
        let seen = FixObserved()
        await drain(client(host: host, seen: seen).askStream(request))
        assertOnce(seen, status: 500)
    }

    func testTransportFailureBeforeHeadersIsOneCallWithStatus0() async throws {
        for (index, code) in [URLError.Code.notConnectedToInternet, .cannotFindHost, .timedOut].enumerated() {
            let host = "fix-stream-down-\(index).example.com"
            APIStub.register(host: host) { _ in .failure(code) }
            let seen = FixObserved()
            await drain(client(host: host, seen: seen).askStream(request))
            assertOnce(seen, status: 0)
        }
    }

    func testAMidBodyDropAfterHeadersAddsNothing() async throws {
        let host = "fix-stream-drop.example.com"
        let data = try APIFixture.data("ask-stream-cutoff.sse")
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: [data], failAfter: .networkConnectionLost) }
        let seen = FixObserved()
        await drain(client(host: host, seen: seen).askStream(request))
        try await Task.sleep(nanoseconds: 150_000_000)
        assertOnce(seen, status: 200)
    }

    func testAMidBodyDropAfterAnErrorAnswerStillOneCall() async throws {
        let host = "fix-stream-500-drop.example.com"
        APIStub.register(host: host) { _ in .stream(status: 500, chunks: [Data("oops".utf8)], failAfter: .networkConnectionLost) }
        let seen = FixObserved()
        await drain(client(host: host, seen: seen).askStream(request))
        try await Task.sleep(nanoseconds: 150_000_000)
        assertOnce(seen, status: 500)
    }

    func testCancelAfterHeadersIsStillOneCall() async throws {
        let host = "fix-stream-cancel-after.example.com"
        let data = try APIFixture.data("ask-stream.sse")
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: [data]) }
        let seen = FixObserved()
        let api = client(host: host, seen: seen)
        let request = request
        let task = Task { () -> Int in
            var count = 0
            do {
                for try await _ in api.askStream(request) {
                    count += 1
                    withUnsafeCurrentTask { $0?.cancel() }   // cancel from inside, once the first event is in
                }
            } catch {}
            return count
        }
        let received = await task.value
        XCTAssertGreaterThanOrEqual(received, 1, "the headers had arrived: an event was delivered")
        try await Task.sleep(nanoseconds: 200_000_000)
        assertOnce(seen, status: 200)
    }

    func testCancelBeforeHeadersNeverGivesTwoCalls() async throws {
        let host = "fix-stream-cancel-before.example.com"
        let data = try APIFixture.data("ask-stream.sse")
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: [data]) }
        let seen = FixObserved()
        let api = client(host: host, seen: seen)
        let request = request
        let task = Task {
            do { for try await _ in api.askStream(request) {} } catch {}
        }
        task.cancel()
        await task.value
        try await Task.sleep(nanoseconds: 200_000_000)
        let calls = seen.all
        XCTAssertLessThanOrEqual(calls.count, 1, "a cancel must not produce two calls")
        for call in calls {
            XCTAssertEqual(call.path, "/api/ask/stream")
            XCTAssertGreaterThanOrEqual(call.ms, 0)
        }
    }

    func testCancelledRequestWithNoAnswerNeverGivesTwoCalls() async throws {
        let host = "fix-stream-cancel-fail.example.com"
        APIStub.register(host: host) { _ in .failure(.cancelled) }
        let seen = FixObserved()
        await drain(client(host: host, seen: seen).askStream(request))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThanOrEqual(seen.all.count, 1)
        for call in seen.all { XCTAssertEqual(call.status, 0) }
    }

    func testTwoStreamsAreTwoCalls() async throws {
        let host = "fix-stream-two.example.com"
        let data = try APIFixture.data("ask-stream.sse")
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: [data]) }
        let seen = FixObserved()
        let api = client(host: host, seen: seen)
        await drain(api.askStream(request))
        await drain(api.askStream(request))
        XCTAssertEqual(seen.all.count, 2)
        XCTAssertEqual(seen.all.map(\.status), [200, 200])
    }
}

// MARK: 3. The request crumb filter

private final class TrueCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
}

final class Build8RequestCrumbFilterTests: XCTestCase {
    private let live = "/api/meetings/:id/live-hr"

    func testTheDefaultPollingRouteIsLiveHR() {
        XCTAssertEqual(RequestCrumbFilter.defaultPollingRoutes, ["/api/meetings/:id/live-hr"])
    }

    func testTheDefaultRouteIsWhatCrumbRouteGivesForARealLiveHRPath() {
        for path in [
            "/api/meetings/abc-123/live-hr",
            "/api/meetings/0b6f1d52-2c0e-4b0b-9a53-5d8a1f3f7e11/live-hr",
            "/api/meetings/abc-123/live-hr?since=1700000000",
        ] {
            let route = CrumbRoute.name(path: path)
            XCTAssertTrue(RequestCrumbFilter.defaultPollingRoutes.contains(route), "\(path) -> \(route)")
            XCTAssertEqual(route, live)
        }
        // And the filter built with the defaults really treats that route as polling.
        let filter = RequestCrumbFilter()
        let route = CrumbRoute.name(path: "/api/meetings/abc-123/live-hr")
        XCTAssertTrue(filter.shouldRecord(route: route, status: 200))
        XCTAssertFalse(filter.shouldRecord(route: route, status: 200))
    }

    func testNonPollingRoutesAreAlwaysRecorded() {
        let filter = RequestCrumbFilter()
        for route in ["/api/view", "/api/meetings/:id/hr", "/api/ask/stream", "other"] {
            for status in [200, 200, 200, 204, 404, 500, 0] {
                XCTAssertTrue(filter.shouldRecord(route: route, status: status), "\(route) \(status)")
            }
        }
    }

    func testPollingFirstSuccessIsRecordedAndRepeatsAreNot() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
        for _ in 0..<50 { XCTAssertFalse(filter.shouldRecord(route: live, status: 200)) }
    }

    func testPollingNon2xxIsAlwaysRecorded() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        for status in [500, 500, 500, 401, 401, 404, 0, 0, 302, 302, 199, 300] {
            XCTAssertTrue(filter.shouldRecord(route: live, status: status), "\(status)")
        }
    }

    func testARecoveryShowsOnce() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
        XCTAssertFalse(filter.shouldRecord(route: live, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 500))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 500))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200), "the recovery is written")
        XCTAssertFalse(filter.shouldRecord(route: live, status: 200), "but only once")
        XCTAssertFalse(filter.shouldRecord(route: live, status: 200))
    }

    func testAChangeBetweenTwoSuccessCodesShowsOnce() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 204), "status changed")
        XCTAssertFalse(filter.shouldRecord(route: live, status: 204))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200), "changed back")
        XCTAssertFalse(filter.shouldRecord(route: live, status: 200))
    }

    func testASuccessRightAfterATransportFailureIsRecorded() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 0))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
    }

    func testOtherRoutesDoNotDisturbThePollingState() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: "/api/view", status: 200))
        XCTAssertTrue(filter.shouldRecord(route: "/api/view", status: 500))
        XCTAssertFalse(filter.shouldRecord(route: live, status: 200))
    }

    func testSeparatePollingRoutesKeepSeparateState() {
        let hr = "/api/meetings/:id/hr"
        let filter = RequestCrumbFilter(pollingRoutes: [live, hr])
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: hr, status: 200), "its own first success")
        XCTAssertFalse(filter.shouldRecord(route: live, status: 200))
        XCTAssertFalse(filter.shouldRecord(route: hr, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: live, status: 500))
        XCTAssertFalse(filter.shouldRecord(route: hr, status: 200), "a failure on one route does not reset the other")
        XCTAssertTrue(filter.shouldRecord(route: live, status: 200), "recovery on the first")
        XCTAssertFalse(filter.shouldRecord(route: hr, status: 200))
    }

    func testSeparateFiltersKeepSeparateState() {
        let first = RequestCrumbFilter(pollingRoutes: [live])
        let second = RequestCrumbFilter(pollingRoutes: [live])
        XCTAssertTrue(first.shouldRecord(route: live, status: 200))
        XCTAssertTrue(second.shouldRecord(route: live, status: 200))
        XCTAssertFalse(first.shouldRecord(route: live, status: 200))
    }

    func testAnEmptyPollingSetRecordsEverything() {
        let filter = RequestCrumbFilter(pollingRoutes: [])
        for _ in 0..<5 { XCTAssertTrue(filter.shouldRecord(route: live, status: 200)) }
    }

    func testManyThreadsWithTheSameSuccessRecordExactlyOnce() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        let counter = TrueCounter()
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            if filter.shouldRecord(route: live, status: 200) { counter.add("n") }
        }
        XCTAssertEqual(counter.count("n"), 1)
    }

    func testManyThreadsAcrossManyRoutesRecordOncePerRoute() {
        let routes = (0..<8).map { "/poll/\($0)" }
        let filter = RequestCrumbFilter(pollingRoutes: Set(routes))
        let counter = TrueCounter()
        DispatchQueue.concurrentPerform(iterations: 4000) { index in
            let route = routes[index % routes.count]
            if filter.shouldRecord(route: route, status: 200) { counter.add(route) }
        }
        for route in routes { XCTAssertEqual(counter.count(route), 1, route) }
    }

    func testManyThreadsWithFailuresRecordEveryOne() {
        let filter = RequestCrumbFilter(pollingRoutes: [live])
        let counter = TrueCounter()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            if filter.shouldRecord(route: live, status: 500) { counter.add("n") }
        }
        XCTAssertEqual(counter.count("n"), 1000)
    }
}
