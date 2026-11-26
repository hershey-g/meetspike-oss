import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `meetspike://pair?origin=<https origin>&code=<one-time code>`, from the QR
/// code on the setup page. It carries no secret: the phone trades the code
/// once at `<origin>/hooks/pair` for its sync keys.
public struct PairingLink: Equatable, Sendable {
    /// Normalized origin, e.g. `https://meetspike.example`.
    public let origin: String
    public let code: String

    public static let codeLength = 48

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "meetspike", url.host?.lowercased() == "pair",
              url.path.isEmpty || url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let rawOrigin = items.first(where: { $0.name == "origin" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value,
              Self.isCode(code),
              let destination = Destination(rawOrigin) else { return nil }
        origin = destination.origin.absoluteString
        self.code = code
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url)
    }

    /// The server's name, shown before connecting so a stray code cannot quietly redirect uploads.
    /// Includes a non-default port, so the name shown is exactly where the keys come from.
    public var host: String {
        guard let url = URL(string: origin), let name = url.host else { return origin }
        return url.port.map { "\(name):\($0)" } ?? name
    }

    public var destination: Destination? { Destination(origin) }

    var exchangeURL: URL? { URL(string: origin + "/hooks/pair") }

    static func isCode(_ value: String) -> Bool {
        value.utf8.count == codeLength && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }
}

/// What the Worker hands back for a good code.
public struct PairingReply: Decodable, Equatable, Sendable {
    public struct Access: Decodable, Equatable, Sendable {
        public let clientId: String
        public let clientSecret: String

        public init(clientId: String, clientSecret: String) {
            self.clientId = clientId
            self.clientSecret = clientSecret
        }
    }

    public let ok: Bool
    public let ingestSecret: String
    public let access: Access?

    public init(ok: Bool, ingestSecret: String, access: Access?) {
        self.ok = ok
        self.ingestSecret = ingestSecret
        self.access = access
    }

    /// The credentials to save. Without an Access token from the server, a
    /// token already saved for the same server is kept.
    public func credentials(keeping saved: Credentials?, sameOrigin: Bool) -> Credentials {
        if let access {
            return Credentials(ingestSecret: ingestSecret, accessID: access.clientId, accessSecret: access.clientSecret)
        }
        let keep = sameOrigin ? saved : nil
        return Credentials(ingestSecret: ingestSecret, accessID: keep?.accessID, accessSecret: keep?.accessSecret)
    }

    var isUsable: Bool {
        guard ok, Credentials.isHeaderValue(ingestSecret) else { return false }
        guard let access else { return true }
        return Credentials.isHeaderValue(access.clientId) && Credentials.isHeaderValue(access.clientSecret)
    }
}

public enum PairingError: Error, Equatable, Sendable {
    /// Unknown, used or expired code.
    case expired
    case rateLimited
    /// The Worker has no INGEST_ADMIN_SECRET.
    case serverNotReady
    /// Cloudflare Access answered instead of the Worker: /hooks/* is not bypassed.
    case accessBlocked
    case unreachable
    case unexpected(Int?)

    public var message: String {
        switch self {
        case .expired: "This code has expired or was already used. Make a new one on the setup page."
        case .rateLimited: "Too many tries. Wait a minute and scan again."
        case .serverNotReady: "Your server has no ingest secret yet. Add INGEST_ADMIN_SECRET to the Worker."
        case .accessBlocked: "Cloudflare Access blocked pairing. Bypass Access for /hooks/* and try again."
        case .unreachable: "Can't reach the server. Check your connection and try again."
        case .unexpected(let status): status.map { "Pairing failed (HTTP \($0)). Try a new code." } ?? "Pairing failed. Try a new code."
        }
    }
}

extension Uploader {
    /// Trades a one-time code for the sync keys. Sends only the code: no saved secret or Access header.
    public func redeemPairing(_ link: PairingLink) async throws -> PairingReply {
        guard let url = link.exchangeURL else { throw PairingError.unexpected(nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["code": link.code])
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PairingError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw PairingError.unexpected(nil) }
        let html = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html")
        switch http.statusCode {
        case 200 where !html:
            guard let reply = try? JSONDecoder().decode(PairingReply.self, from: data), reply.isUsable else {
                throw PairingError.unexpected(200)
            }
            return reply
        case 404, 410: throw html ? PairingError.unexpected(http.statusCode) : PairingError.expired
        case 429: throw PairingError.rateLimited
        case 503 where !html: throw PairingError.serverNotReady
        case 300..<400, 401, 403: throw PairingError.accessBlocked
        // Cloudflare's own HTML error pages (a Worker exception is a 500 page) are not Access.
        case 500..<600: throw PairingError.unexpected(http.statusCode)
        default: throw html ? PairingError.accessBlocked : PairingError.unexpected(http.statusCode)
        }
    }
}
