import Foundation

/// Every way a Meetspike API call can fail. Callers must handle these; nothing
/// is swallowed. `accessRejected` is the only one that should send the person
/// back to sign-in or to re-check their Access token.
public enum APIError: Error, Equatable, Sendable {
    /// Redirect, 401, 403 or an HTML page: Cloudflare Access did not let the request through.
    case accessRejected
    /// The Worker answered with an error status. `message` is the Worker's own `error` text when it sent one.
    case http(status: Int, message: String)
    /// No usable network, DNS, TLS or timeout failure before any answer came back.
    case offline
    /// The answer was 2xx but not the JSON shape we expect.
    case decoding(String)
    /// The request itself cannot be built (bad path) or the origin is not https (http only for localhost).
    case invalidRequest(String)
    /// No origin is saved yet (see `UnconfiguredAPI`).
    case notConfigured

    /// Short, plain sentence for a banner or an inline error.
    public var message: String {
        switch self {
        case .accessRejected: "Sign-in needed. Check your Access token in Menu."
        case .http(_, let message): message
        case .offline: "Can't reach Meetspike. Check your connection."
        case .decoding: "Meetspike sent something unexpected. Try again."
        case .invalidRequest: "That request isn't valid."
        case .notConfigured: "Add your Meetspike URL in Menu."
        }
    }

    /// HTTP status when the Worker answered, else nil.
    public var status: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }
}
