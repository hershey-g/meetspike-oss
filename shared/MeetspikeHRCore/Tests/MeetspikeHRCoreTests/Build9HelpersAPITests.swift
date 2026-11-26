import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

// Build 9 spec, server contract the phone talks to:
//   PUT /api/meetings/:id/override  JSON {scope:'event'|'series', state?: 'not_joined'|'unlinked'|'linked'|null,
//   startUtc?: ISO|null, endUtc?: ISO|null}. 415 for non JSON, 400 shape, 404 unknown event, 503 not migrated.
//   null clears. Times only for scope event. Same guards as company rename.
// iPhone: "Any save reloads today, dates, people, company and widgets. ResponseCache cleared for the affected day.
//   Failure leaves the old state and says so." (Crumb route templates are covered in Build9RoutesNotesTests.)
//
// Written from the spec, after the code. The call goes through a stubbed URLSession; nothing leaves the machine.

final class Build9HelpersRequestTests: XCTestCase {
    private func okBody(_ id: String = "m1") -> Data {
        Data(#"{"ok":true,"id":"\#(id)","scope":"event","excluded":true,"startUtc":"2026-11-25T14:00:00.000Z","endUtc":"2026-11-25T14:30:00.000Z","override":{"state":"not_joined","scope":"event","seenNone":false,"seriesId":"s"}}"#.utf8)
    }

    private func line(_ request: URLRequest) -> String {
        let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
        return "\(request.httpMethod ?? "") \(path)\(request.url?.query.map { "?\($0)" } ?? "")"
    }

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: APIStub.body(of: request)) as? [String: Any])
    }

    // MARK: The request

    func testMethodPathBodyAndHeaders() async throws {
        let host = "b9-override-request.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: self.okBody()) }
        let client = APIClient.stubbed(
            host: host, credentials: Credentials(ingestSecret: "ingest-dummy", accessID: "id-dummy", accessSecret: "key-dummy"))

        _ = try await client.saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)))
        let request = try XCTUnwrap(APIStub.seen(host: host).first)

        XCTAssertEqual(line(request), "PUT /api/meetings/m1/override", "no query string")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "the Worker answers 415 to anything else")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id-dummy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "key-dummy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MeetspikeTest/1.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the ingest bearer never goes to /api")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(try json(request) as NSDictionary, ["scope": "event", "state": "not_joined"] as NSDictionary)
    }

    func testBodyForEveryKindOfEdit() async throws {
        let host = "b9-override-bodies.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: self.okBody()) }
        let client = APIClient.stubbed(host: host)
        let start = B9.at(0)
        let end = B9.at(1800)
        let edits: [(OverrideEdit, [String: Any])] = [
            (OverrideEdit(scope: .event, state: .set(.unlinked)), ["scope": "event", "state": "unlinked"]),
            (OverrideEdit(scope: .event, state: .set(.linked)), ["scope": "event", "state": "linked"]),
            (OverrideEdit(scope: .event, state: .clear), ["scope": "event", "state": NSNull()]),
            (OverrideEdit(scope: .series, state: .set(.notJoined)), ["scope": "series", "state": "not_joined"]),
            (OverrideEdit(scope: .series, state: .clear), ["scope": "series", "state": NSNull()]),
            (
                OverrideEdit(scope: .event, startUtc: .set(start), endUtc: .set(end)),
                ["scope": "event", "startUtc": "2026-11-25T14:00:00.000Z", "endUtc": "2026-11-25T14:30:00.000Z"]
            ),
            (
                OverrideEdit(scope: .event, startUtc: .clear, endUtc: .clear),
                ["scope": "event", "startUtc": NSNull(), "endUtc": NSNull()]
            ),
            (OverrideEdit(scope: .event, endUtc: .set(end)), ["scope": "event", "endUtc": "2026-11-25T14:30:00.000Z"]),
            // Times are only for one meeting: a series edit that was handed times still sends none.
            (
                OverrideEdit(scope: .series, state: .set(.unlinked), startUtc: .set(start), endUtc: .set(end)),
                ["scope": "series", "state": "unlinked"]
            ),
        ]
        for (edit, _) in edits { _ = try await client.saveOverride(meetingID: "m1", edit: edit) }
        let seen = APIStub.seen(host: host)
        XCTAssertEqual(seen.count, edits.count)
        for (request, expected) in zip(seen, edits.map(\.1)) {
            XCTAssertEqual(try json(request) as NSDictionary, expected as NSDictionary)
        }
    }

    func testTimesAreUTCWithAFractionWhateverTheDeviceZoneIs() throws {
        let edit = OverrideEdit(scope: .event, startUtc: .set(B9.at(0)), endUtc: .set(B9.at(5400.5)))
        B9.inZones(B9.zones) { zone in
            let body = try? H9.wire(edit)
            XCTAssertEqual(body?["startUtc"] as? String, "2026-11-25T14:00:00.000Z", zone)
            XCTAssertEqual(body?["endUtc"] as? String, "2026-11-25T15:30:00.500Z", zone)
        }
    }

    func testOddMeetingIdsAreEscapedIntoOnePathSegment() async throws {
        let host = "b9-override-odd-ids.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: self.okBody()) }
        let client = APIClient.stubbed(host: host)
        let ids: [(String, String)] = [
            ("m1", "m1"),
            ("abc_20261125T140000Z", "abc_20261125T140000Z"),
            ("a b", "a%20b"),
            ("a/b", "a%2Fb"),
            ("a?b#c", "a%3Fb%23c"),
            ("100%", "100%25"),
            ("a%2Fb", "a%252Fb"),
            ("a+b@x.com", "a%2Bb%40x.com"),
            ("\u{E9}", "%C3%A9"),
            ("tab\there", "tab%09here"),
            ("semi;colon:and=eq&amp", "semi%3Bcolon%3Aand%3Deq%26amp"),
            ("../x", "..%2Fx"),
        ]
        for (id, _) in ids { _ = try await client.saveOverride(meetingID: id, edit: OverrideEdit(scope: .event, state: .clear)) }
        let seen = APIStub.seen(host: host)
        XCTAssertEqual(seen.map(line), ids.map { "PUT /api/meetings/\($0.1)/override" })
        // The Worker reads the id back exactly, and the call never carries a query or fragment.
        for (request, (id, _)) in zip(seen, ids) {
            XCTAssertNil(request.url?.query, id)
            XCTAssertNil(request.url?.fragment, id)
            let path = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath })
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.count, 5, "\(id): /api/meetings/<id>/override is exactly five parts: \(path)")
            XCTAssertEqual(parts[3].removingPercentEncoding, id)
        }
    }

    /// A segment that is only dots would be read as a path step up, and the PUT would land on another route.
    func testAnIdOfOnlyDotsStillStaysInsideTheMeetingRoute() async throws {
        let host = "b9-override-dots.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: self.okBody()) }
        let client = APIClient.stubbed(host: host)
        for id in ["..", "."] {
            _ = try await client.saveOverride(meetingID: id, edit: OverrideEdit(scope: .event, state: .clear))
        }
        for request in APIStub.seen(host: host) {
            let path = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath })
            XCTAssertTrue(path.hasPrefix("/api/meetings/"), path)
            XCTAssertFalse(path.split(separator: "/").contains(".."), "a '..' segment climbs out of the route: \(path)")
            XCTAssertFalse(path.split(separator: "/").contains("."), "a '.' segment is dropped by URL rules: \(path)")
        }
    }

    // MARK: The answers

    func testA200GivesTheMeetingAsItIsNow() async throws {
        let host = "b9-override-200.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: self.okBody("ev-9")) }
        let result = try await APIClient.stubbed(host: host).saveOverride(
            meetingID: "ev-9", edit: OverrideEdit(scope: .event, state: .set(.notJoined)))
        XCTAssertEqual(result.ok, true)
        XCTAssertEqual(result.id, "ev-9")
        XCTAssertEqual(result.scope, "event")
        XCTAssertEqual(result.excluded, true)
        XCTAssertEqual(result.startUtc, "2026-11-25T14:00:00.000Z")
        XCTAssertEqual(result.override?.state, .notJoined)
        XCTAssertEqual(result.override?.seriesId, "s")
    }

    func testTheWorkersSentenceComesBackFor400And404And503() async throws {
        let cases: [(Int, String)] = [
            (400, "Pick not_joined, unlinked, linked or null."),
            (404, "No such meeting."),
            (503, "Not available yet."),
            (415, "Send JSON."),
        ]
        for (status, sentence) in cases {
            let host = "b9-override-\(status).example.com"
            APIStub.register(host: host) { _ in .json(status: status, body: Data(#"{"error":"\#(sentence)"}"#.utf8)) }
            do {
                _ = try await APIClient.stubbed(host: host).saveOverride(
                    meetingID: "m1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)))
                XCTFail("\(status) must throw")
            } catch {
                XCTAssertEqual(error as? APIError, .http(status: status, message: sentence), "\(status)")
            }
        }
    }

    func testAnErrorWithNoSentenceStillSaysSomething() async throws {
        let host = "b9-override-nobody.example.com"
        APIStub.register(host: host) { _ in .json(status: 503, body: Data()) }
        do {
            _ = try await APIClient.stubbed(host: host).saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
            XCTFail("503 must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 503, message: "Something went wrong (503)."))
        }
    }

    func testOfflineIsOfflineAndTheEditCanBeQueued() async throws {
        let host = "b9-override-offline.example.com"
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost] {
            APIStub.register(host: host) { _ in .failure(code) }
            do {
                _ = try await APIClient.stubbed(host: host).saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
                XCTFail("\(code) must throw")
            } catch {
                XCTAssertEqual(error as? APIError, .offline, "\(code)")
                // The app then keeps the edit and says so.
                guard case .keep(let words) = OverrideDelivery.verdict(for: error) else { return XCTFail("offline keeps the edit") }
                XCTAssertTrue(words.contains("Saved on this phone"), words)
            }
        }
    }

    func testASignInPageIsNotASave() async throws {
        let host = "b9-override-access.example.com"
        for reply in [StubReply.html(status: 200), .json(status: 401, body: Data()), .json(status: 403, body: Data()),
                      .redirect(status: 302, location: "https://login.example.net/")] {
            APIStub.register(host: host) { _ in reply }
            do {
                _ = try await APIClient.stubbed(host: host).saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
                XCTFail("must not count as saved")
            } catch {
                XCTAssertEqual(error as? APIError, .accessRejected)
            }
        }
    }

    func testAnAnswerNobodyCanReadIsAnErrorNotASave() async throws {
        let host = "b9-override-garbage.example.com"
        APIStub.register(host: host) { _ in .json(status: 200, body: Data("not json".utf8)) }
        do {
            _ = try await APIClient.stubbed(host: host).saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
            XCTFail("an unreadable 200 is not a confirmed save")
        } catch let APIError.decoding(reason) {
            XCTAssertFalse(reason.contains("not json"), "never echoes the response")
        } catch {
            XCTFail("expected decoding, got \(error)")
        }
    }

    func testTheErrorsFromTheWireDecideWhatHappensToTheEdit() async throws {
        let cases: [(Int, Bool)] = [(400, false), (404, false), (503, true), (500, true), (502, true)]
        for (status, kept) in cases {
            let host = "b9-override-verdict-\(status).example.com"
            APIStub.register(host: host) { _ in .json(status: status, body: Data(#"{"error":"Words."}"#.utf8)) }
            do {
                _ = try await APIClient.stubbed(host: host).saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
                XCTFail("\(status)")
            } catch {
                switch OverrideDelivery.verdict(for: error) {
                case .keep: XCTAssertTrue(kept, "\(status) should be dropped")
                case .drop(let words):
                    XCTAssertFalse(kept, "\(status) should be kept")
                    XCTAssertEqual(words, "Words.", "the Worker's sentence is shown")
                }
            }
        }
    }

    // MARK: Writes are never cached

    func testAWriteIsNeverSavedOrServedFromTheCache() async throws {
        let directory = try tempDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        let host = "b9-override-cache.example.com"
        let view = try APIFixture.data("view-day.json")
        APIStub.register(host: host) { request in
            request.httpMethod == "PUT" ? .json(status: 200, body: self.okBody()) : .json(status: 200, body: view)
        }
        let client = APIClient(
            origin: "https://\(host)", credentials: nil, userAgent: "MeetspikeTest/1.0",
            configuration: APIStub.configuration(), cache: cache)!
        _ = try await client.view(date: "2026-11-24")
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        XCTAssertEqual(before, 1)

        _ = try await client.saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1, "the PUT answer is not kept")
        XCTAssertFalse(try APIRequest.putOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear)).cacheable)

        // Offline: a write is an error, never an old answer.
        APIStub.register(host: host) { _ in .failure(.notConnectedToInternet) }
        do {
            _ = try await client.saveOverride(meetingID: "m1", edit: OverrideEdit(scope: .event, state: .clear))
            XCTFail("offline write must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
    }
}

// MARK: Cache clearing

final class Build9HelpersCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: ResponseCache!

    override func setUpWithError() throws {
        directory = try tempDirectory()
        cache = ResponseCache(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func save(_ requests: [APIRequest]) async throws {
        for request in requests { try await cache.write(Data(#"{"k":1}"#.utf8), for: request) }
    }

    private func kept(_ requests: [APIRequest]) async -> [String] {
        var out: [String] = []
        for request in requests where await cache.readData(for: request) != nil { out.append(request.cacheKey) }
        return out
    }

    private func gone(_ requests: [APIRequest]) async -> [String] {
        var out: [String] = []
        for request in requests where await cache.readData(for: request) == nil { out.append(request.cacheKey) }
        return out
    }

    func testTheAffectedDayIsForgottenAndOtherDaysAreNot() async throws {
        let days = ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26"].map(APIRequest.view(date:))
        try await save(days)
        await cache.invalidate(days: ["2026-11-24"], meetingID: nil)
        let goneKeys = await gone(days)
        XCTAssertEqual(goneKeys, [days[1].cacheKey])
        let keptKeys = await kept(days)
        XCTAssertEqual(keptKeys.count, 3)
    }

    func testAMoveAcrossMidnightForgetsBothDays() async throws {
        // 23:30 on the 24th moved to 00:30 on the 25th touches the old day and the new one.
        let days = ["2026-11-23", "2026-11-24", "2026-11-25", "2026-11-26"].map(APIRequest.view(date:))
        try await save(days)
        await cache.invalidate(days: ["2026-11-24", "2026-11-25"], meetingID: "m1")
        let goneKeys = await gone(days)
        XCTAssertEqual(goneKeys, [days[1].cacheKey, days[2].cacheKey])
        let keptKeys = await kept(days)
        XCTAssertEqual(keptKeys, [days[0].cacheKey, days[3].cacheKey])
    }

    func testEveryRangeThatHoldsAnAffectedDayIsForgotten() async throws {
        let holds = [
            APIRequest.view(start: "2026-11-24", end: "2026-11-24"),
            APIRequest.view(start: "2026-11-01", end: "2026-11-30"),
            APIRequest.view(start: "2026-11-24", end: "2026-12-01"),
            APIRequest.view(start: "2026-11-18", end: "2026-11-24"),
            APIRequest.people(start: "2026-10-28", end: "2026-11-24"),
            APIRequest.people(start: "2026-11-24", end: "2026-11-24"),
            APIRequest.companies(start: "2026-11-01", end: "2026-11-30"),
            APIRequest.personMeetings(email: "dana.sample@example.com", start: "2026-11-01", end: "2026-11-30"),
            APIRequest.companyMeetings(domain: "example.com", start: "2026-11-01", end: "2026-11-30"),
        ]
        let misses = [
            APIRequest.view(start: "2026-11-01", end: "2026-11-23"),
            APIRequest.view(start: "2026-11-25", end: "2026-11-30"),
            APIRequest.people(start: "2026-10-01", end: "2026-10-31"),
            APIRequest.companies(start: "2026-12-01", end: "2026-12-31"),
            APIRequest.personMeetings(email: "dana.sample@example.com", start: "2026-11-01", end: "2026-11-23"),
        ]
        try await save(holds + misses)
        await cache.invalidate(days: ["2026-11-24"], meetingID: nil)
        let gone = await gone(holds)
        XCTAssertEqual(gone.count, holds.count, "still saved: \(Set(holds.map(\.cacheKey)).subtracting(gone))")
        let kept = await kept(misses)
        XCTAssertEqual(kept.count, misses.count, "forgotten by mistake: \(Set(misses.map(\.cacheKey)).subtracting(kept))")
    }

    func testTheMeetingDetailIsForgottenForThatMeetingOnly() async throws {
        let mine = [
            APIRequest.meetingHR(id: "m1", fill: false),
            APIRequest.meetingHR(id: "m1", fill: true),
        ]
        let others = [
            APIRequest.meetingHR(id: "m10", fill: true),
            APIRequest.meetingHR(id: "m1x", fill: false),
            APIRequest.meetingHR(id: "other", fill: false),
        ]
        try await save(mine + others)
        await cache.invalidate(days: [], meetingID: "m1")
        let goneMine = await gone(mine)
        XCTAssertEqual(goneMine.count, 2)
        let keptOthers = await kept(others)
        XCTAssertEqual(keptOthers.count, 3)
    }

    func testTheDetailOfAnOddIdIsFoundByTheSameEscaping() async throws {
        let odd = ["a b", "a/b", "100%", "a+b@x.com", "abc_20261125T140000Z"]
        let requests = odd.map { APIRequest.meetingHR(id: $0, fill: false) }
        try await save(requests)
        for (index, id) in odd.enumerated() {
            await cache.invalidate(days: [], meetingID: id)
            let remaining = await kept(requests)
            XCTAssertEqual(remaining.count, requests.count - index - 1, id)
        }
    }

    func testSeveralMeetingsOfOneSaveAreAllForgotten() async throws {
        // Two edits sent together: the second meeting's detail goes with the first's.
        let one = APIRequest.meetingHR(id: "m1", fill: false)
        let two = APIRequest.meetingHR(id: "m2", fill: false)
        try await save([one, two])
        await cache.invalidate(days: ["2026-11-24"], meetingID: "m1")
        await cache.invalidate(days: [], meetingID: "m2")
        let keptKeys = await kept([one, two])
        XCTAssertEqual(keptKeys, [])
    }

    func testThingsWithNoDayAreLeftAlone() async throws {
        let other = [
            APIRequest.askStatus,
            APIRequest.sourceDisplay,
            APIRequest.liveHR(meetingID: "m1", since: 0),
            APIRequest.searchPeople(query: "dana"),
        ]
        // searchPeople and liveHR are never cached on disk, so write them directly to be sure they would survive.
        try await save(other)
        await cache.invalidate(days: ["2026-11-24"], meetingID: "m1")
        let keptKeys = await kept(other)
        XCTAssertEqual(keptKeys.count, other.count)
    }

    func testNothingNamedForgetsNothing() async throws {
        let all = [APIRequest.view(date: "2026-11-24"), APIRequest.meetingHR(id: "m1", fill: false)]
        try await save(all)
        await cache.invalidate(days: [], meetingID: nil)
        let keptKeys = await kept(all)
        XCTAssertEqual(keptKeys.count, 2)
    }

    func testAMissingOrJunkCacheFolderIsFineAndJunkIsLeftAlone() async throws {
        let junk = directory.appendingPathComponent("junk.json")
        try Data("not an envelope".utf8).write(to: junk)
        try await save([APIRequest.view(date: "2026-11-24")])
        await cache.invalidate(days: ["2026-11-24"], meetingID: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: junk.path))
        let missing = ResponseCache(directory: directory.appendingPathComponent("never-made"))
        await missing.invalidate(days: ["2026-11-24"], meetingID: "m1")
    }

    func testClearForgetsEverythingForSignOut() async throws {
        let all = [APIRequest.view(date: "2026-11-24"), APIRequest.askStatus]
        try await save(all)
        await cache.clear()
        let keptKeys = await kept(all)
        XCTAssertEqual(keptKeys, [])
        // And the cache works again afterwards.
        try await save([all[0]])
        let again = await kept([all[0]])
        XCTAssertEqual(again.count, 1)
    }
}
