import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The answer to Settings' "Test connection". It calls the same small
/// authenticated route the update check uses (`GET /api/whoop-web/app/ios`),
/// with the same ingest secret and Access headers as uploads, so a pass here
/// means uploads will get through.
public enum ConnectionCheck: Equatable, Sendable {
    case connected
    /// The Worker answered 401: the ingest secret is wrong.
    case wrongSecret
    /// Cloudflare Access answered: 403, a redirect to sign in, or its HTML page.
    case accessBlocked
    /// No answer at all: offline, DNS, TLS or timeout.
    case unreachable
    /// The Worker has no INGEST_ADMIN_SECRET.
    case serverNotReady
    case unexpected(Int)

    public var title: String {
        switch self {
        case .connected: "Connected"
        case .wrongSecret: "Wrong ingest secret (401)"
        case .accessBlocked: "Blocked by Cloudflare Access"
        case .unreachable: "Can't reach server"
        case .serverNotReady: "Server has no ingest secret"
        case .unexpected(let status): "Unexpected answer (HTTP \(status))"
        }
    }

    public var detail: String {
        switch self {
        case .connected: "Heart rate will sync to this server."
        case .wrongSecret: "Scan a new setup code, or enter the ingest secret again."
        case .accessBlocked: "Add the Access client ID and secret, or check the service token rule in Cloudflare Access."
        case .unreachable: "Check the Meetspike URL and your internet connection."
        case .serverNotReady: "Add INGEST_ADMIN_SECRET to the Worker, then test again."
        case .unexpected: "Try again in a minute. If it keeps happening, check the Worker logs."
        }
    }

    public var isConnected: Bool { self == .connected }

    /// Reads one HTTP answer. `body` only matters for a 200, which must be the Worker's JSON.
    public static func classify(status: Int, contentType: String?, body: Data) -> ConnectionCheck {
        let type = (contentType ?? "").lowercased()
        let html = type.contains("text/html")
        let json = type.contains("application/json")
        switch status {
        case 200:
            if html { return .accessBlocked }
            struct Reply: Decodable { let ok: Bool }
            return (try? JSONDecoder().decode(Reply.self, from: body))?.ok == true ? .connected : .unexpected(200)
        case 300..<400, 403: return .accessBlocked
        case 401: return json ? .wrongSecret : .accessBlocked
        case 503 where json: return .serverNotReady
        // Cloudflare's own HTML error pages (a Worker exception is a 500 page) are not Access.
        case 500..<600: return .unexpected(status)
        default: return html ? .accessBlocked : .unexpected(status)
        }
    }
}

extension Uploader {
    public func testConnection(at destination: Destination, credentials: Credentials) async -> ConnectionCheck {
        var request = Self.request(Data(), to: destination.latestBuildEndpoint, credentials: credentials)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return ConnectionCheck.classify(
                status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data
            )
        } catch {
            return .unreachable
        }
    }
}
