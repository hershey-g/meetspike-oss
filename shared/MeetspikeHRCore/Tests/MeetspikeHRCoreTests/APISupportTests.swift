import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MeetspikeHRCore

/// Shared helpers for the API tests: fixture loading and a URLProtocol that answers without a network.
enum APIFixture {
    static var directory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

/// What a stubbed host answers.
enum StubReply {
    case json(status: Int, body: Data, headers: [String: String] = [:])
    case html(status: Int)
    case redirect(status: Int, location: String)
    /// Redirect through URLSession's redirect machinery (exercises the refuse-redirects delegate).
    case redirectThroughSession(to: String)
    case failure(URLError.Code)
    /// A streaming answer delivered in chunks, optionally ending with an error.
    case stream(status: Int, chunks: [Data], failAfter: URLError.Code? = nil)
}

/// URLProtocol stub. Each test registers a handler under its own host so tests never share state.
final class APIStub: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> StubReply] = [:]
    private static var requests: [String: [URLRequest]] = [:]

    static func register(host: String, _ handler: @escaping (URLRequest) -> StubReply) {
        lock.withLock {
            handlers[host] = handler
            requests[host] = []
        }
    }

    static func seen(host: String) -> [URLRequest] {
        lock.withLock { requests[host] ?? [] }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStub.self]
        return configuration
    }

    /// The body of a request seen by the stub (URLSession turns httpBody into a stream).
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let handler = Self.lock.withLock { () -> ((URLRequest) -> StubReply)? in
            Self.requests[host, default: []].append(request)
            return Self.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch handler(request) {
        case .json(let status, let body, let headers):
            var fields = ["Content-Type": "application/json"]
            headers.forEach { fields[$0.key] = $0.value }
            respond(url: url, status: status, headers: fields, chunks: [body])
        case .html(let status):
            respond(url: url, status: status, headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data("<html>Sign in</html>".utf8)])
        case .redirect(let status, let location):
            respond(url: url, status: status, headers: ["Location": location], chunks: [])
        case .redirectThroughSession(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // If the session's delegate refuses the redirect, this 302 is the final answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .stream(let status, let chunks, let failAfter):
            respond(url: url, status: status, headers: ["Content-Type": "text/event-stream"], chunks: chunks, failAfter: failAfter)
        }
    }

    private func respond(url: URL, status: Int, headers: [String: String], chunks: [Data], failAfter: URLError.Code? = nil) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failAfter {
            client?.urlProtocol(self, didFailWithError: URLError(failAfter))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

extension APIClient {
    /// A client for `host` with the network stubbed out.
    static func stubbed(
        host: String, credentials: Credentials? = nil, cache: ResponseCache? = nil
    ) -> APIClient {
        APIClient(origin: "https://\(host)", credentials: credentials, userAgent: "MeetspikeTest/1.0",
                  configuration: APIStub.configuration(), cache: cache)!
    }
}

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetspike-api-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
