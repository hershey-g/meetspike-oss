import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

final class SyncPairingTests: XCTestCase {
    private let code = String(repeating: "aB3_-", count: 9) + "xyz"

    private func link(host: String) throws -> PairingLink {
        try XCTUnwrap(PairingLink(string: "meetspike://pair?origin=https%3A%2F%2F\(host)&code=\(code)"))
    }

    // MARK: Link

    func testParsesTheSetupPageLink() throws {
        XCTAssertEqual(code.count, 48)
        let parsed = try XCTUnwrap(PairingLink(string: "meetspike://pair?origin=https%3A%2F%2Fmeetspike.example%2F&code=\(code)"))
        XCTAssertEqual(parsed.origin, "https://meetspike.example")
        XCTAssertEqual(parsed.code, code)
        XCTAssertEqual(parsed.host, "meetspike.example")
        XCTAssertEqual(try link(host: "meetspike.example:8443").host, "meetspike.example:8443")
        XCTAssertEqual(parsed.exchangeURL?.absoluteString, "https://meetspike.example/hooks/pair")
    }

    func testRejectsLinksThatAreNotSafeSetupCodes() {
        for bad in [
            "https://meetspike.example/pair?origin=https%3A%2F%2Fa.example&code=\(code)",
            "meetspike://other?origin=https%3A%2F%2Fa.example&code=\(code)",
            "meetspike://pair?origin=http%3A%2F%2Fa.example&code=\(code)",
            "meetspike://pair?origin=https%3A%2F%2Fa.example%2Fpath&code=\(code)",
            "meetspike://pair?origin=https%3A%2F%2Fa.example&code=short",
            "meetspike://pair?origin=https%3A%2F%2Fa.example&code=\(code.dropLast())!",
            "meetspike://pair?code=\(code)",
            "not a url"
        ] {
            XCTAssertNil(PairingLink(string: bad), bad)
        }
    }

    // MARK: Exchange

    func testRedeemSendsOnlyTheCodeAndReturnsKeys() async throws {
        let host = "pair-ok.example.invalid"
        APIStub.register(host: host) { _ in
            .json(status: 200, body: Data(#"{"ok":true,"ingestSecret":"fixture-ingest","access":{"clientId":"cid.access","clientSecret":"csecret"}}"#.utf8))
        }
        let reply = try await Uploader(configuration: APIStub.configuration()).redeemPairing(link(host: host))
        XCTAssertEqual(reply.ingestSecret, "fixture-ingest")
        XCTAssertEqual(reply.access, .init(clientId: "cid.access", clientSecret: "csecret"))
        let sent = try XCTUnwrap(APIStub.seen(host: host).first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/hooks/pair")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        let body = try JSONSerialization.jsonObject(with: APIStub.body(of: sent)) as? [String: String]
        XCTAssertEqual(body, ["code": code])
    }

    func testRedeemMapsEveryFailure() async throws {
        let cases: [(String, StubReply, PairingError)] = [
            ("pair-404", .json(status: 404, body: Data(#"{"error":"gone"}"#.utf8)), .expired),
            ("pair-429", .json(status: 429, body: Data("{}".utf8)), .rateLimited),
            ("pair-503", .json(status: 503, body: Data("{}".utf8)), .serverNotReady),
            ("pair-302", .redirect(status: 302, location: "https://team.cloudflareaccess.com/"), .accessBlocked),
            ("pair-403", .html(status: 403), .accessBlocked),
            ("pair-html", .html(status: 200), .accessBlocked),
            ("pair-offline", .failure(.notConnectedToInternet), .unreachable),
            ("pair-junk", .json(status: 200, body: Data(#"{"ok":true,"ingestSecret":"has space"}"#.utf8)), .unexpected(200)),
            ("pair-500", .json(status: 500, body: Data("{}".utf8)), .unexpected(500)),
            ("pair-500-html", .html(status: 500), .unexpected(500)),
            ("pair-503-html", .html(status: 503), .unexpected(503))
        ]
        let uploader = Uploader(configuration: APIStub.configuration())
        for (name, reply, expected) in cases {
            let host = "\(name).example.invalid"
            APIStub.register(host: host) { _ in reply }
            do {
                _ = try await uploader.redeemPairing(link(host: host))
                XCTFail("\(name) should fail")
            } catch let error as PairingError {
                XCTAssertEqual(error, expected, name)
                XCTAssertFalse(error.message.contains("\u{2014}"))
            }
        }
    }

    func testPairedCredentialsKeepASavedAccessTokenOnlyForTheSameServer() {
        let saved = Credentials(ingestSecret: "old", accessID: "saved-id", accessSecret: "saved-key")
        let plain = PairingReply(ok: true, ingestSecret: "new", access: nil)
        let same = plain.credentials(keeping: saved, sameOrigin: true)
        XCTAssertEqual([same.ingestSecret, same.accessID, same.accessSecret], ["new", "saved-id", "saved-key"])
        let other = plain.credentials(keeping: saved, sameOrigin: false)
        XCTAssertNil(other.accessID)
        let withAccess = PairingReply(ok: true, ingestSecret: "new", access: .init(clientId: "id2", clientSecret: "key2"))
            .credentials(keeping: saved, sameOrigin: true)
        XCTAssertEqual([withAccess.accessID, withAccess.accessSecret], ["id2", "key2"])
    }

    // MARK: Test connection

    func testConnectionReportsEachOutcomePrecisely() async throws {
        let cases: [(String, StubReply, ConnectionCheck)] = [
            ("check-ok", .json(status: 200, body: Data(#"{"ok":true,"build":7}"#.utf8)), .connected),
            ("check-401", .json(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)), .wrongSecret),
            ("check-403", .html(status: 403), .accessBlocked),
            ("check-login", .redirect(status: 302, location: "https://team.cloudflareaccess.com/cdn-cgi/access/login"), .accessBlocked),
            ("check-login-page", .html(status: 200), .accessBlocked),
            ("check-offline", .failure(.cannotFindHost), .unreachable),
            ("check-timeout", .failure(.timedOut), .unreachable),
            ("check-503", .json(status: 503, body: Data(#"{"error":"INGEST_ADMIN_SECRET is not set"}"#.utf8)), .serverNotReady),
            ("check-500", .json(status: 500, body: Data("{}".utf8)), .unexpected(500)),
            ("check-worker-exception", .html(status: 500), .unexpected(500)),
            ("check-503-html", .html(status: 503), .unexpected(503))
        ]
        let uploader = Uploader(configuration: APIStub.configuration())
        let credentials = Credentials(ingestSecret: "fixture", accessID: "cid", accessSecret: "ckey")
        for (name, reply, expected) in cases {
            let host = "\(name).example.invalid"
            APIStub.register(host: host) { _ in reply }
            let destination = try XCTUnwrap(Destination("https://\(host)"))
            let result = await uploader.testConnection(at: destination, credentials: credentials)
            XCTAssertEqual(result, expected, name)
        }
        let sent = try XCTUnwrap(APIStub.seen(host: "check-ok.example.invalid").first)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/api/whoop-web/app/ios")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "CF-Access-Client-Id"), "cid")
    }

    func testConnectionCopyIsShortAndHasNoEmDashes() {
        let all: [ConnectionCheck] = [.connected, .wrongSecret, .accessBlocked, .unreachable, .serverNotReady, .unexpected(500)]
        XCTAssertEqual(all.map(\.title), [
            "Connected", "Wrong ingest secret (401)", "Blocked by Cloudflare Access", "Can't reach server",
            "Server has no ingest secret", "Unexpected answer (HTTP 500)"
        ])
        for check in all {
            XCTAssertFalse((check.title + check.detail).contains("\u{2014}"))
            XCTAssertLessThan(check.detail.count, 110)
        }
    }

    // MARK: Settings form

    func testSaveIsOffUntilSomethingChanges() {
        var form = SyncSettingsForm(origin: "https://meetspike.example", savedOrigin: "https://meetspike.example/", hasSavedIngest: true)
        XCTAssertFalse(form.hasChanges)
        XCTAssertFalse(form.canSave)
        XCTAssertNil(form.hint)
        form.origin = "https://other.example"
        XCTAssertTrue(form.originChanged)
        XCTAssertEqual(form.problem, .ingestNewServer, "saved keys never go to a new address")
        XCTAssertFalse(form.canSave)
        form.ingest = "other-secret"
        XCTAssertTrue(form.canSave)
        form.ingest = ""
        form.origin = "https://meetspike.example"
        XCTAssertFalse(form.originChanged)
        form.ingest = "new-secret"
        XCTAssertTrue(form.canSave)
    }

    func testSaveExplainsInvalidInput() {
        var form = SyncSettingsForm(origin: "meetspike.example", hasSavedIngest: true)
        XCTAssertEqual(form.problem, .origin)
        XCTAssertFalse(form.canSave)
        XCTAssertEqual(form.hint, SyncSettingsForm.Problem.origin.message)
        form.origin = "https://meetspike.example"
        form.hasSavedIngest = false
        XCTAssertEqual(form.problem, .ingestMissing)
        form.ingest = "two words"
        XCTAssertEqual(form.problem, .ingestInvalid)
        form.ingest = "ok-secret"
        form.accessID = "cid"
        XCTAssertEqual(form.problem, .accessIncomplete)
        form.accessSecret = "has space"
        XCTAssertEqual(form.problem, .accessInvalid)
        form.accessSecret = "ckey"
        XCTAssertNil(form.problem)
        XCTAssertTrue(form.canSave)
        for problem: SyncSettingsForm.Problem in [.origin, .ingestMissing, .ingestNewServer, .ingestInvalid, .accessIncomplete, .accessInvalid] {
            XCTAssertFalse(problem.message.contains("\u{2014}"))
        }
    }

    func testFirstSetupHasNoSavedAddressToProtect() {
        let form = SyncSettingsForm(origin: "https://meetspike.example", ingest: "s", savedOrigin: "", hasSavedIngest: false)
        XCTAssertFalse(form.originChanged)
        XCTAssertTrue(form.canSave)
    }
}
