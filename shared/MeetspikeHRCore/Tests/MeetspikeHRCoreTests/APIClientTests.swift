import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

final class APIClientTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data { try APIFixture.data(name) }

    // MARK: Origin and headers

    func testOnlyHTTPSOriginsAndLocalhostAreAccepted() {
        XCTAssertNotNil(APIClient(origin: "https://example.com", credentials: nil))
        XCTAssertNotNil(APIClient(origin: " HTTPS://Example.com/ ", credentials: nil))
        XCTAssertNotNil(APIClient(origin: "http://localhost:8787", credentials: nil))
        for origin in [
            "http://example.com", "http://127.0.0.1:8787", "ftp://example.com", "https://user:pass@example.com",
            "https://example.com/path", "https://example.com/?x=1", "", "example.com",
        ] {
            XCTAssertNil(APIClient(origin: origin, credentials: nil), origin)
        }
    }

    func testRequestCarriesAccessHeadersUserAgentAndNoIngestSecret() throws {
        let client = APIClient(
            origin: "https://example.com",
            credentials: Credentials(ingestSecret: "ingest-dummy", accessID: "id-dummy", accessSecret: "key-dummy"),
            userAgent: "MeetspikeTest/1.0"
        )!
        let request = try client.urlRequest(for: .view(date: "2026-11-24"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/view?date=2026-11-24")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id-dummy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "key-dummy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MeetspikeTest/1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the ingest bearer never goes to /api reads")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"), "no body, no content type")

        let post = try client.urlRequest(for: .refresh())
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(post.timeoutInterval, 60)
    }

    func testAccessHeadersNeedBothValidParts() throws {
        let partial: [Credentials?] = [
            nil,
            Credentials(ingestSecret: "x"),
            Credentials(ingestSecret: "x", accessID: "id-only"),
            Credentials(ingestSecret: "x", accessSecret: "secret-only"),
            Credentials(ingestSecret: "x", accessID: "id", accessSecret: ""),
            Credentials(ingestSecret: "x", accessID: "id", accessSecret: "bad\nvalue"),
        ]
        for credentials in partial {
            let client = APIClient(origin: "https://example.com", credentials: credentials)!
            let request = try client.urlRequest(for: .askStatus)
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        }
    }

    // MARK: Transport outcomes

    func testGetDecodesAndSendsHeadersOverTheWire() async throws {
        let host = "headers.example.com"
        let body = try fixture("view-day.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: body) }
        let client = APIClient.stubbed(host: host, credentials: Credentials(ingestSecret: "x", accessID: "id-dummy", accessSecret: "key-dummy"))
        let view = try await client.view(date: "2026-11-24")
        XCTAssertEqual(view.today, "2026-11-24")
        let seen = try XCTUnwrap(APIStub.seen(host: host).first)
        XCTAssertEqual(seen.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id-dummy")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "User-Agent"), "MeetspikeTest/1.0")
        XCTAssertEqual(seen.url?.query, "date=2026-11-24")
    }

    func testRedirectsAreRefusedAndMeanAccessRejected() async throws {
        let direct = "redirect-direct.example.com"
        APIStub.register(host: direct) { _ in .redirect(status: 302, location: "https://login.example.net/") }
        do {
            _ = try await APIClient.stubbed(host: direct).view(date: "2026-11-24")
            XCTFail("a redirect must not be followed or accepted")
        } catch {
            XCTAssertEqual(error as? APIError, .accessRejected)
        }

        let viaSession = "redirect-session.example.com"
        APIStub.register(host: viaSession) { _ in .redirectThroughSession(to: "https://login.example.net/") }
        do {
            _ = try await APIClient.stubbed(host: viaSession).view(date: "2026-11-24")
            XCTFail("a redirect must not be followed or accepted")
        } catch {
            XCTAssertEqual(error as? APIError, .accessRejected)
        }
        XCTAssertTrue(APIStub.seen(host: "login.example.net").isEmpty, "the redirect target is never contacted")
    }

    func testAccessRejectedForUnauthorizedForbiddenAndHTML() async throws {
        let cases: [(String, StubReply)] = [
            ("rejected-401.example.com", .json(status: 401, body: Data(#"{"error":"no"}"#.utf8))),
            ("rejected-403.example.com", .json(status: 403, body: Data(#"{"error":"no"}"#.utf8))),
            ("rejected-html.example.com", .html(status: 200)),
            ("rejected-html-502.example.com", .html(status: 502)),
        ]
        for (host, reply) in cases {
            APIStub.register(host: host) { _ in reply }
            do {
                _ = try await APIClient.stubbed(host: host).askStatus()
                XCTFail("\(host) should be rejected")
            } catch {
                XCTAssertEqual(error as? APIError, .accessRejected, host)
            }
        }
    }

    func testHTTPErrorsCarryTheWorkersSentence() async throws {
        let host = "http-error.example.com"
        APIStub.register(host: host) { request in
            request.url?.path.hasSuffix("/hr") == true
                ? .json(status: 404, body: Data(#"{"error":"per-meeting detail is unavailable","enabled":false}"#.utf8))
                : .json(status: 500, body: Data("not json".utf8))
        }
        let client = APIClient.stubbed(host: host)
        do {
            _ = try await client.meetingHR(id: "m1", fill: false)
            XCTFail("404 should throw")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 404, message: "per-meeting detail is unavailable"))
        }
        do {
            _ = try await client.view(date: "2026-11-24")
            XCTFail("500 should throw")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 500, message: "Something went wrong (500)."))
        }
    }

    func testNetworkFailuresAreOfflineAndBadBodiesAreDecoding() async throws {
        let offline = "offline.example.com"
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost, .secureConnectionFailed] {
            APIStub.register(host: offline) { _ in .failure(code) }
            do {
                _ = try await APIClient.stubbed(host: offline).askStatus()
                XCTFail("\(code) should be offline")
            } catch {
                XCTAssertEqual(error as? APIError, .offline, "\(code)")
            }
        }

        let broken = "decoding.example.com"
        APIStub.register(host: broken) { _ in .json(status: 200, body: Data(#"{"people":[{"name":"No email"}]}"#.utf8)) }
        do {
            _ = try await APIClient.stubbed(host: broken).people(start: "2026-11-01", end: "2026-11-24")
            XCTFail("a person without an email cannot decode")
        } catch let APIError.decoding(reason) {
            XCTAssertTrue(reason.contains("PeopleResponse"), reason)
            XCTAssertFalse(reason.contains("No email"), "decoding errors never echo response values")
        } catch {
            XCTFail("expected decoding error, got \(error)")
        }
    }

    // MARK: Typed endpoints

    func testEndpointPathsAndMethods() async throws {
        let host = "paths.example.com"
        APIStub.register(host: host) { request in
            switch request.url?.path ?? "" {
            case "/api/people/search": .json(status: 200, body: (try? APIFixture.data("people-search.json")) ?? Data())
            case "/api/settings/source-display": .json(status: 200, body: (try? APIFixture.data("source-display.json")) ?? Data())
            case "/api/ask/key": .json(status: 200, body: (try? APIFixture.data("ask-key-saved.json")) ?? Data())
            case "/api/ask/status": .json(status: 200, body: (try? APIFixture.data("ask-status.json")) ?? Data())
            case let path where path.hasSuffix("/live-hr"): .json(status: 200, body: (try? APIFixture.data("live-hr.json")) ?? Data())
            case let path where path.hasSuffix("/hr"): .json(status: 200, body: (try? APIFixture.data("meeting-hr.json")) ?? Data())
            case let path where path.hasSuffix("/meetings"): .json(status: 200, body: (try? APIFixture.data("person-meetings.json")) ?? Data())
            case "/api/people": .json(status: 200, body: (try? APIFixture.data("people.json")) ?? Data())
            default: .json(status: 404, body: Data(#"{"error":"unexpected"}"#.utf8))
            }
        }
        let client = APIClient.stubbed(host: host)
        _ = try await client.meetingHR(id: "m 1")
        _ = try await client.meetingHR(id: "m1", fill: true)
        _ = try await client.liveHR(meetingID: "m1", since: 12)
        _ = try await client.people(start: "2026-10-28", end: "2026-11-24")
        let found = try await client.searchPeople(query: "  dana ")
        XCTAssertEqual(found.count, 2)
        let empty = try await client.searchPeople(query: "   ")
        XCTAssertTrue(empty.isEmpty)
        _ = try await client.personMeetings(email: "dana.sample@example.com", start: "2026-10-28", end: "2026-11-24")
        _ = try await client.askStatus()
        _ = try await client.setSourceDisplay(.oura, enabled: false)
        _ = try await client.sourceDisplay()
        _ = try await client.saveAskKey("  sk-ant-dummy  ")
        _ = try await client.deleteAskKey()

        let seen = APIStub.seen(host: host)
        func line(_ r: URLRequest) -> String {
            let path = r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
            return "\(r.httpMethod ?? "") \(path)\(r.url?.query.map { "?\($0)" } ?? "")"
        }
        XCTAssertEqual(seen.map(line), [
            "GET /api/meetings/m%201/hr?fill=0",
            "GET /api/meetings/m1/hr",
            "GET /api/meetings/m1/live-hr?since=12",
            "GET /api/people?start=2026-10-28&end=2026-11-24",
            "GET /api/people/search?q=dana",
            "GET /api/people/dana.sample%40example.com/meetings?start=2026-10-28&end=2026-11-24&compact=1",
            "GET /api/ask/status",
            "PATCH /api/settings/source-display",
            "GET /api/settings/source-display",
            "PUT /api/ask/key",
            "DELETE /api/ask/key",
        ])
        let patch = try XCTUnwrap(seen.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(String(decoding: APIStub.body(of: patch), as: UTF8.self), #"{"oura":false}"#)
        let put = try XCTUnwrap(seen.first { $0.httpMethod == "PUT" })
        let key = try JSONSerialization.jsonObject(with: APIStub.body(of: put)) as? [String: String]
        XCTAssertEqual(key, ["key": "sk-ant-dummy"], "the key is trimmed and only ever sent in the body")
        XCTAssertFalse(seen.contains { $0.url?.absoluteString.contains("sk-ant") == true })
    }

    func testEmptyKeyIsRefusedBeforeAnyRequest() async {
        let host = "emptykey.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: Data("{}".utf8)) }
        do {
            _ = try await APIClient.stubbed(host: host).saveAskKey("  ")
            XCTFail("an empty key must not be sent")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidRequest("empty key"))
        }
        XCTAssertTrue(APIStub.seen(host: host).isEmpty)
    }

    // MARK: Refresh

    func testRefreshUsesTheNewEndpoint() async throws {
        let host = "refresh-new.example.com"
        let body = try fixture("refresh.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: body) }
        let result = try await APIClient.stubbed(host: host).refresh(full: true)
        XCTAssertFalse(result.usedCalendarFallback)
        XCTAssertFalse(result.needsGoogle)
        XCTAssertNil(result.calendarError)
        XCTAssertEqual(result.calendar?.ok, true)
        XCTAssertEqual(result.oura?.pending, true)
        XCTAssertEqual(result.syncedAt, "2026-11-24T14:10:00.000Z")
        let seen = try XCTUnwrap(APIStub.seen(host: host).first)
        XCTAssertEqual(seen.url?.path, "/api/refresh")
        XCTAssertEqual(String(decoding: APIStub.body(of: seen), as: UTF8.self), #"{"full":true,"mode":"live"}"#)
    }

    func testRefresh404FallsBackToCalendarSync() async throws {
        let host = "refresh-old.example.com"
        let body = try fixture("calendar-sync.json")
        APIStub.register(host: host) { request in
            request.url?.path == "/api/calendar/sync"
                ? .json(status: 200, body: body)
                : .json(status: 404, body: Data(#"{"error":"not found"}"#.utf8))
        }
        let result = try await APIClient.stubbed(host: host).refresh(full: false)
        XCTAssertTrue(result.usedCalendarFallback)
        XCTAssertEqual(result.calendar?.ok, true)
        XCTAssertNil(result.whoop)
        XCTAssertFalse(result.needsGoogle)
        XCTAssertEqual(APIStub.seen(host: host).map { $0.url?.path }, ["/api/refresh", "/api/calendar/sync"])
        let sync = try XCTUnwrap(APIStub.seen(host: host).last)
        XCTAssertEqual(String(decoding: APIStub.body(of: sync), as: UTF8.self), #"{"mode":"live"}"#)
    }

    func testRefreshTreatsNeedsGoogleAsNotAnError() async throws {
        // 409 from the older calendar sync, after a 404 from refresh.
        let old = "refresh-409-old.example.com"
        let needs = try fixture("err-needs-google.json")
        APIStub.register(host: old) { request in
            request.url?.path == "/api/calendar/sync" ? .json(status: 409, body: needs) : .json(status: 404, body: Data("{}".utf8))
        }
        let fallback = try await APIClient.stubbed(host: old).refresh()
        XCTAssertTrue(fallback.needsGoogle)
        XCTAssertTrue(fallback.usedCalendarFallback)
        XCTAssertNil(fallback.calendarError)

        // 409 straight from /api/refresh.
        let direct = "refresh-409.example.com"
        APIStub.register(host: direct) { _ in .json(status: 409, body: needs) }
        let straight = try await APIClient.stubbed(host: direct).refresh()
        XCTAssertTrue(straight.needsGoogle)
        XCTAssertNil(straight.calendarError)

        // A calendar part inside a 200 that says needsGoogle, with wearables still refreshed.
        let inside = "refresh-part.example.com"
        let part = try fixture("refresh-needs-google.json")
        APIStub.register(host: inside) { _ in .json(status: 200, body: part) }
        let partial = try await APIClient.stubbed(host: inside).refresh()
        XCTAssertTrue(partial.needsGoogle)
        XCTAssertNil(partial.calendarError)
        XCTAssertTrue(partial.wearableRefreshed)
        XCTAssertTrue(partial.ouraFailed)
    }

    func testRefreshRealFailuresStillThrowOrReport() async throws {
        let host = "refresh-fail.example.com"
        APIStub.register(host: host) { _ in .json(status: 502, body: Data(#"{"error":"Google Calendar sync failed: boom"}"#.utf8)) }
        do {
            _ = try await APIClient.stubbed(host: host).refresh()
            XCTFail("a 502 is a real failure")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 502, message: "Google Calendar sync failed: boom"))
        }

        let part = "refresh-part-fail.example.com"
        let body = Data(#"{"calendar":{"ok":false,"error":"Google Calendar sync failed: boom"},"whoop":{"ok":true}}"#.utf8)
        APIStub.register(host: part) { _ in .json(status: 200, body: body) }
        let result = try await APIClient.stubbed(host: part).refresh()
        XCTAssertEqual(result.calendarError, "Google Calendar sync failed: boom")
        XCTAssertFalse(result.needsGoogle)
        XCTAssertTrue(result.wearableRefreshed)
    }

    // MARK: Offline cache

    func testGoodAnswersAreCachedAndServedWhenOffline() async throws {
        let host = "cache.example.com"
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory, now: { Date(timeIntervalSince1970: 1_000) })
        let body = try fixture("view-day.json")
        let online = LockedFlag(true)
        APIStub.register(host: host) { _ in online.value ? .json(status: 200, body: body) : .failure(.notConnectedToInternet) }
        let client = APIClient.stubbed(host: host, cache: cache)

        let fresh = try await client.loadView(date: "2026-11-24")
        XCTAssertFalse(fresh.isFromCache)
        XCTAssertEqual(fresh.value.today, "2026-11-24")

        online.value = false
        let offline = try await client.loadView(date: "2026-11-24")
        XCTAssertTrue(offline.isFromCache)
        XCTAssertEqual(offline.savedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(offline.value.day?.calendar?.events.count, 5)
        let instant = await client.cachedView(date: "2026-11-24")
        XCTAssertEqual(instant?.value.today, "2026-11-24")

        // A day never fetched has nothing to show: the offline error comes through.
        do {
            _ = try await client.loadView(date: "2026-11-20")
            XCTFail("nothing cached for that day")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
    }

    func testOnlyOfflineFallsBackToCache() async throws {
        let host = "cache-errors.example.com"
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        let body = try fixture("view-day.json")
        let mode = LockedFlag(true)
        APIStub.register(host: host) { _ in mode.value ? .json(status: 200, body: body) : .redirect(status: 302, location: "https://login.example.net") }
        let client = APIClient.stubbed(host: host, cache: cache)
        _ = try await client.loadView(date: "2026-11-24")
        mode.value = false
        do {
            _ = try await client.loadView(date: "2026-11-24")
            XCTFail("access rejected must not be hidden by old data")
        } catch {
            XCTAssertEqual(error as? APIError, .accessRejected)
        }
    }

    func testLiveHRAndPostsAreNeverCached() async throws {
        let host = "nocache.example.com"
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        let live = try fixture("live-hr.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: live) }
        let client = APIClient.stubbed(host: host, cache: cache)
        _ = try await client.liveHR(meetingID: "m1", since: 0)
        let hit = await cache.readData(for: .liveHR(meetingID: "m1", since: 0))
        XCTAssertNil(hit)
    }
}

/// A tiny thread-safe switch for stub handlers.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool) { flag = value }
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
