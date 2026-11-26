import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif
import XCTest
@testable import MeetspikeHRCore

final class UploaderTests: XCTestCase {
    func testDestinationAllowsOnlyHTTPSOriginsAndTheLocalFixture() throws {
        let remote = try XCTUnwrap(Destination(" HTTPS://example.invalid:8443/ "))
        XCTAssertEqual(remote.origin.absoluteString, "https://example.invalid:8443")
        XCTAssertEqual(remote.endpoint.absoluteString, "https://example.invalid:8443/api/whoop-web/ingest")
        XCTAssertEqual(Destination("http://localhost:8080")?.endpoint.path, "/api/whoop-web/ingest")

        for origin in [
            "http://example.invalid", "http://localhost.example.invalid", "http://127.0.0.1:8080",
            "https://user:pass@example.invalid", "https://example.invalid/?token=dummy",
            "https://example.invalid/#fragment", "https://example.invalid/path", "file:///tmp/file", "https://"
        ] {
            XCTAssertNil(Destination(origin), origin)
        }
    }

    func testBearerAndOptionalAccessHeaders() throws {
        let destination = try XCTUnwrap(Destination("https://example.invalid"))
        let body = Data("fixture".utf8)
        let bearerOnly = Uploader.request(body, to: destination, credentials: .init(ingestSecret: "dummy"))
        XCTAssertEqual(bearerOnly.httpMethod, "POST")
        XCTAssertEqual(bearerOnly.httpBody, body)
        XCTAssertEqual(bearerOnly.value(forHTTPHeaderField: "Authorization"), "Bearer dummy")
        XCTAssertEqual(bearerOnly.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(bearerOnly.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(bearerOnly.value(forHTTPHeaderField: "CF-Access-Client-Secret"))

        let complete = Uploader.request(
            body, to: destination, credentials: .init(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: "fixture-key")
        )
        XCTAssertEqual(complete.value(forHTTPHeaderField: "CF-Access-Client-Id"), "fixture-id")
        XCTAssertEqual(complete.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "fixture-key")

        let incomplete: [Credentials] = [
            .init(ingestSecret: "dummy", accessID: "fixture-id"),
            .init(ingestSecret: "dummy", accessSecret: "fixture-key"),
            .init(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: ""),
            .init(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: "invalid\nvalue")
        ]
        for credentials in incomplete {
            let request = Uploader.request(body, to: destination, credentials: credentials)
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
        }
    }

    func testRedirectDelegateRefusesAnotherRequestWithoutNetwork() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let first = try XCTUnwrap(URL(string: "https://example.invalid/api/whoop-web/ingest"))
        let other = try XCTUnwrap(URL(string: "https://redirect.invalid/"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: first, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": other.absoluteString]
        ))
        let task = session.dataTask(with: first)
        let refused = expectation(description: "Refuses redirected request")
        RefuseRedirects().urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: other)
        ) { redirected in
            XCTAssertNil(redirected)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 1)
    }

    func testTransportReportsOnlyHTTPStatusFromFixture() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusFixture.self]
        let uploader = Uploader(configuration: configuration)
        let destination = try XCTUnwrap(Destination("https://example.invalid"))
        let status = try await uploader.post(Data(), to: destination, credentials: .init(ingestSecret: "dummy"))
        XCTAssertEqual(status, 401)
    }

    func testSuccessRequiresRawStorageReceipt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusFixture.self]
        let uploader = Uploader(configuration: configuration)
        let credentials = Credentials(ingestSecret: "dummy")
        let legacy = try XCTUnwrap(Destination("https://legacy-ack.example.invalid"))
        do {
            _ = try await uploader.post(Data(), to: legacy, credentials: credentials)
            XCTFail("A legacy 200 must leave the batch pending")
        } catch IngestUploadError.missingReceipt {}

        let raw = try XCTUnwrap(Destination("https://raw-ack.example.invalid"))
        let status = try await uploader.post(Data(), to: raw, credentials: credentials)
        XCTAssertEqual(status, 200)
    }

    func testSourceDisplayReadsAndPatchesOneSourceThroughAccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusFixture.self]
        let uploader = Uploader(configuration: configuration)
        let destination = try XCTUnwrap(Destination("https://display.example.invalid"))
        let credentials = Credentials(ingestSecret: "dummy", accessID: "fixture-id", accessSecret: "fixture-key")

        let current = try await uploader.sourceDisplay(at: destination, credentials: credentials)
        XCTAssertFalse(current.oura)
        XCTAssertFalse(current.whoop)
        let updated = try await uploader.sourceDisplay(at: destination, credentials: credentials, update: (.oura, true))
        XCTAssertTrue(updated.oura)
        XCTAssertFalse(updated.whoop)
    }

    #if os(macOS)
    func testProtectedKeychainItemUsesDeviceOnlyAccessibilityWithoutOpeningKeychain() {
        let data = Data("fixture".utf8)
        let item = CredentialStore.newItem(data: data, protected: true)
        XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(
            item[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(item[kSecValueData as String] as? Data, data)
        let login = CredentialStore.newItem(data: data, protected: false)
        XCTAssertNil(login[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(login[kSecAttrAccessible as String])
    }
    #endif
}

private final class StatusFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let status: Int
        let body: String
        switch url.host {
        case "legacy-ack.example.invalid":
            (status, body) = (200, #"{"ok":true}"#)
        case "raw-ack.example.invalid":
            (status, body) = (200, #"{"ok":true,"rawStored":true}"#)
        case "display.example.invalid":
            let allowed = url.path == "/api/settings/source-display"
                && request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "fixture-id"
                && request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "fixture-key"
                && request.value(forHTTPHeaderField: "Authorization") == nil
            let patch = request.httpMethod == "PATCH" && Self.body(of: request) == Data(#"{"oura":true}"#.utf8)
            switch (allowed, request.httpMethod, patch) {
            case (true, "GET", _): (status, body) = (200, #"{"oura":false,"whoop":false}"#)
            case (true, "PATCH", true): (status, body) = (200, #"{"oura":true,"whoop":false}"#)
            default: (status, body) = (400, "invalid request")
            }
        default:
            (status, body) = (401, "ignored fixture response")
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream on Apple platforms.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
