import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

final class APISSEParserTests: XCTestCase {
    private func parse(_ chunks: [String]) -> [SSEMessage] {
        var parser = SSEParser()
        var out: [SSEMessage] = []
        for chunk in chunks { out += parser.push(chunk) }
        return out + parser.finish()
    }

    func testOneEventInOneChunk() {
        XCTAssertEqual(
            parse(["event: text\ndata: {\"delta\":\"hi\"}\n\n"]),
            [SSEMessage(event: "text", data: #"{"delta":"hi"}"#)]
        )
    }

    func testEveryPossibleSplitGivesTheSameEvents() throws {
        let text = String(decoding: try APIFixture.data("ask-stream.sse"), as: UTF8.self)
        let whole = parse([text])
        XCTAssertGreaterThan(whole.count, 8)
        let bytes = Array(text.utf8)
        for cut in stride(from: 1, to: bytes.count, by: 7) {
            var parser = SSEParser()
            var out = parser.push(Data(bytes[..<cut]))
            out += parser.push(Data(bytes[cut...]))
            out += parser.finish()
            XCTAssertEqual(out, whole, "split at byte \(cut)")
        }
    }

    func testByteByByteMatchesWholeInput() throws {
        let data = try APIFixture.data("ask-stream.sse")
        var parser = SSEParser()
        var out: [SSEMessage] = []
        for byte in data { out += parser.push(byte: byte) }
        out += parser.finish()
        XCTAssertEqual(out, parse([String(decoding: data, as: UTF8.self)]))
    }

    func testCommentsAndPingsAreIgnored() {
        let out = parse([": ping\n\n", "event: text\n: another comment\ndata: {\"delta\":\"x\"}\n\n", ": ping\n\n"])
        XCTAssertEqual(out, [SSEMessage(event: "text", data: #"{"delta":"x"}"#)])
    }

    func testCRLFLineEndingsAndALoneCR() {
        XCTAssertEqual(
            parse(["event: text\r\ndata: {\"delta\":\"a\"}\r\n\r\n"]),
            [SSEMessage(event: "text", data: #"{"delta":"a"}"#)]
        )
        // CR and LF of one line ending in separate chunks must not make a blank line (which would end the event early).
        XCTAssertEqual(
            parse(["event: text\r", "\ndata: {\"delta\":\"b\"}\r", "\n\r", "\n"]),
            [SSEMessage(event: "text", data: #"{"delta":"b"}"#)]
        )
        // A bare CR is a line ending too.
        XCTAssertEqual(parse(["event: text\rdata: x\r\r"]), [SSEMessage(event: "text", data: "x")])
    }

    func testMultiLineDataAndDefaultEventName() {
        XCTAssertEqual(parse(["data: one\ndata: two\n\n"]), [SSEMessage(event: "message", data: "one\ntwo")])
        XCTAssertEqual(parse(["data:no-space\n\n"]), [SSEMessage(event: "message", data: "no-space")])
    }

    func testEventWithoutDataIsDropped() {
        XCTAssertEqual(parse(["event: text\n\nevent: done\ndata: {}\n\n"]), [SSEMessage(event: "done", data: "{}")])
    }

    func testUnterminatedLastEventIsFlushedOnFinish() {
        XCTAssertEqual(parse(["event: text\ndata: {\"delta\":\"tail\"}"]), [SSEMessage(event: "text", data: #"{"delta":"tail"}"#)])
    }

    func testMultiByteCharactersSplitAcrossChunks() {
        let line = Data("event: text\ndata: {\"delta\":\"caf\u{E9} \u{1F44D}\"}\n\n".utf8)
        for cut in 1..<line.count {
            var parser = SSEParser()
            let out = parser.push(line.prefix(cut)) + parser.push(line.suffix(from: cut)) + parser.finish()
            XCTAssertEqual(out.count, 1, "split at \(cut)")
            XCTAssertEqual(AskEvent(out[0]), .text("caf\u{E9} \u{1F44D}"), "split at \(cut)")
        }
    }

    // MARK: AskEvent mapping

    func testStepEvents() {
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "step", data: #"{"id":"calendar","label":"Reading your calendar","status":"active"}"#)),
            .step(AskStep(id: "calendar", label: "Reading your calendar", status: .active))
        )
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "step", data: #"{"id":"calendar","label":"Read 19 meetings","status":"done"}"#)),
            .step(AskStep(id: "calendar", label: "Read 19 meetings", status: .done))
        )
        // Anything but "done" is active, a missing label is empty, a missing id is dropped.
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "step", data: #"{"id":"x","status":"weird"}"#)),
            .step(AskStep(id: "x", label: "", status: .active))
        )
        XCTAssertNil(AskEvent(SSEMessage(event: "step", data: #"{"label":"no id"}"#)))
    }

    func testTextDoneAndErrorEvents() {
        XCTAssertEqual(AskEvent(SSEMessage(event: "text", data: #"{"delta":"Hello"}"#)), .text("Hello"))
        XCTAssertEqual(AskEvent(SSEMessage(event: "text", data: #""bare string""#)), .text("bare string"))
        XCTAssertNil(AskEvent(SSEMessage(event: "text", data: #"{"delta":""}"#)))
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "done", data: #"{"truncated":true,"interrupted":true,"model":"m","start":"2026-10-28","end":"2026-11-24"}"#)),
            .done(AskDone(truncated: true, interrupted: true, refused: false, model: "m", start: "2026-10-28", end: "2026-11-24"))
        )
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "done", data: #"{"truncated":false,"refused":true}"#)),
            .done(AskDone(refused: true))
        )
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "error", data: #"{"error":"Replace the key.","needsKey":true}"#)),
            .error(AskFailure(message: "Replace the key.", needsKey: true))
        )
        XCTAssertEqual(
            AskEvent(SSEMessage(event: "error", data: #"{"error":"Try again."}"#)),
            .error(AskFailure(message: "Try again.", needsKey: false))
        )
        XCTAssertNil(AskEvent(SSEMessage(event: "mystery", data: "{}")))
    }

    func testFullFixtureProducesTheExpectedEvents() throws {
        var parser = AskEventParser()
        let events = parser.push(try APIFixture.data("ask-stream.sse")) + parser.finish()
        XCTAssertEqual(events.first, .step(AskStep(id: "calendar", label: "Reading your calendar", status: .active)))
        XCTAssertEqual(events.last, .done(AskDone(truncated: false, model: "claude-opus-5-5", start: "2026-10-28", end: "2026-11-24")))
        XCTAssertFalse(events.contains(.cutOff))
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        let text = events.compactMap { event -> String? in if case .text(let t) = event { t } else { nil } }.joined()
        XCTAssertTrue(text.hasPrefix("Heavy days cost you about **15 points**"))
        XCTAssertTrue(text.contains("| Nov 12 | 6 | 31% |"))
    }

    func testErrorEventIsTerminalWithNeedsKey() throws {
        var parser = AskEventParser()
        let events = parser.push(try APIFixture.data("ask-stream-error.sse")) + parser.finish()
        XCTAssertEqual(events.last, .error(AskFailure(message: "Anthropic no longer accepts the saved key. Replace it in More.", needsKey: true)))
        XCTAssertFalse(events.contains(.cutOff))
    }

    func testStreamEndingWithoutDoneOrErrorIsCutOff() throws {
        var parser = AskEventParser()
        let events = parser.push(try APIFixture.data("ask-stream-cutoff.sse")) + parser.finish()
        XCTAssertEqual(events.last, .cutOff)
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        XCTAssertTrue(events.contains(.text("Your busiest day was Nov 12, with")), "partial text is kept")
    }

    func testNothingAfterATerminalEventCounts() {
        var parser = AskEventParser()
        let events = parser.push("event: done\ndata: {\"truncated\":false}\n\nevent: text\ndata: {\"delta\":\"late\"}\n\n") + parser.finish()
        XCTAssertEqual(events, [.done(AskDone())])
    }

    // MARK: askStream over the client

    private func collect(_ stream: AsyncThrowingStream<AskEvent, Error>) async throws -> [AskEvent] {
        var events: [AskEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private var request: AskRequest {
        AskRequest(question: "How was my week?", sourceDisplay: .make(oura: true, whoop: true))
    }

    func testAskStreamYieldsEventsFromChunkedBytes() async throws {
        let host = "stream-ok.example.com"
        let data = try APIFixture.data("ask-stream.sse")
        // Awkward chunk sizes on purpose.
        let chunks = stride(from: 0, to: data.count, by: 37).map { Data(data[$0..<min($0 + 37, data.count)]) }
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: chunks) }
        let client = APIClient.stubbed(host: host, credentials: Credentials(ingestSecret: "x", accessID: "id-dummy", accessSecret: "key-dummy"))
        let events = try await collect(client.askStream(request))
        XCTAssertEqual(events.last, .done(AskDone(truncated: false, model: "claude-opus-5-5", start: "2026-10-28", end: "2026-11-24")))
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)

        let seen = try XCTUnwrap(APIStub.seen(host: host).first)
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.url?.path, "/api/ask/stream")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id-dummy")
        let body = try JSONSerialization.jsonObject(with: APIStub.body(of: seen)) as? [String: Any]
        XCTAssertEqual(body?["question"] as? String, "How was my week?")
    }

    func testAskStreamCutOffWhenConnectionDropsOrEndsEarly() async throws {
        let ended = "stream-cut.example.com"
        let data = try APIFixture.data("ask-stream-cutoff.sse")
        APIStub.register(host: ended) { _ in .stream(status: 200, chunks: [data]) }
        let events = try await collect(APIClient.stubbed(host: ended).askStream(request))
        XCTAssertEqual(events.last, .cutOff)
        XCTAssertTrue(events.contains(.text("Your busiest day was Nov 12, with")))

        let dropped = "stream-drop.example.com"
        APIStub.register(host: dropped) { _ in .stream(status: 200, chunks: [data], failAfter: .networkConnectionLost) }
        let afterDrop = try await collect(APIClient.stubbed(host: dropped).askStream(request))
        // URLSession may discard bytes it had not handed over yet when the connection fails, so only the
        // terminal event is certain here.
        XCTAssertEqual(afterDrop.last, .cutOff)
        XCTAssertEqual(afterDrop.filter(\.isTerminal).count, 1)
    }

    func testAskStreamPreStreamJSONErrorsBecomeErrorEvents() async throws {
        let needsKey = "stream-409.example.com"
        let body = try APIFixture.data("err-needs-key.json")
        APIStub.register(host: needsKey) { _ in .json(status: 409, body: body) }
        let events = try await collect(APIClient.stubbed(host: needsKey).askStream(request))
        XCTAssertEqual(events, [.error(AskFailure(message: "Add your Claude API key in More, then ask again.", needsKey: true))])

        let tooLong = "stream-413.example.com"
        let long = try APIFixture.data("err-too-long.json")
        APIStub.register(host: tooLong) { _ in .json(status: 413, body: long) }
        let big = try await collect(APIClient.stubbed(host: tooLong).askStream(request))
        XCTAssertEqual(big, [.error(AskFailure(message: "That question is too long to send. Start a new chat and try again.", needsKey: false))])

        let plain = "stream-400.example.com"
        APIStub.register(host: plain) { _ in .json(status: 400, body: Data(#"{"error":"Ask a question first."}"#.utf8)) }
        let bad = try await collect(APIClient.stubbed(host: plain).askStream(request))
        XCTAssertEqual(bad, [.error(AskFailure(message: "Ask a question first.", needsKey: false))])
    }

    func testAskStreamThrowsForAccessAndOffline() async throws {
        let rejected = "stream-access.example.com"
        APIStub.register(host: rejected) { _ in .redirect(status: 302, location: "https://login.example.net") }
        do {
            _ = try await collect(APIClient.stubbed(host: rejected).askStream(request))
            XCTFail("a redirect means access rejected")
        } catch {
            XCTAssertEqual(error as? APIError, .accessRejected)
        }

        let html = "stream-html.example.com"
        APIStub.register(host: html) { _ in .html(status: 200) }
        do {
            _ = try await collect(APIClient.stubbed(host: html).askStream(request))
            XCTFail("an HTML page means access rejected")
        } catch {
            XCTAssertEqual(error as? APIError, .accessRejected)
        }

        let offline = "stream-offline.example.com"
        APIStub.register(host: offline) { _ in .failure(.notConnectedToInternet) }
        do {
            _ = try await collect(APIClient.stubbed(host: offline).askStream(request))
            XCTFail("no network means offline")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
    }

    func testCancellingTheConsumerEndsTheStreamWithoutError() async throws {
        let host = "stream-cancel.example.com"
        let data = try APIFixture.data("ask-stream-cutoff.sse")
        APIStub.register(host: host) { _ in .stream(status: 200, chunks: [data]) }
        let client = APIClient.stubbed(host: host)
        let task = Task { () -> Int in
            var count = 0
            for try await _ in client.askStream(request) {
                count += 1
                try Task.checkCancellation()
            }
            return count
        }
        task.cancel()
        // Either outcome is fine; what matters is that it ends and never hangs.
        _ = await task.result
    }

    func testUnconfiguredAPIThrowsNotConfigured() async {
        let api = UnconfiguredAPI()
        do {
            _ = try await api.view(date: "2026-11-24")
            XCTFail("unconfigured must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .notConfigured)
        }
        do {
            for try await _ in api.askStream(request) {}
            XCTFail("unconfigured must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .notConfigured)
        }
    }
}
