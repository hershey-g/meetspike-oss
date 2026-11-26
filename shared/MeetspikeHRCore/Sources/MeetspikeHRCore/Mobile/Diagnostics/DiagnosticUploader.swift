import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DiagnosticRequestError: Error, Equatable {
    case bodyTooLarge(Int)
    case badURL
}

/// Sends queued reports to the user's own Worker.
public enum DiagnosticUploader {
    public enum Outcome: Equatable, Sendable {
        /// The Worker has it. The file goes.
        case sent
        /// Not now (offline, Worker down, wrong secret, throttled). The file stays and the run stops.
        case retryLater
        /// The Worker will never take it (400 bad shape, 413 too big). The file goes so it cannot block the queue.
        case reject
    }

    /// The Worker answers 413 over 256 KB.
    public static let maxBodyBytes = 256 * 1024

    public static let path = "/api/whoop-web/app/diagnostics"

    /// nil is "no HTTP answer", a network error.
    public static func outcome(status: Int?) -> Outcome {
        guard let status else { return .retryLater }
        switch status {
        case 200...299: return .sent
        case 400, 413: return .reject
        default: return .retryLater   // 401, 403, 404, 429, 5xx, redirects and anything odd
        }
    }

    /// Oldest first, one at a time. The closure is called once per report.
    public static func send(queue: DiagnosticQueue, send: (DiagnosticReport) async -> Outcome) async {
        for report in queue.pending() {
            switch await send(report) {
            case .sent, .reject: queue.remove(id: report.id)
            case .retryLater: return
            }
        }
    }

    public static func request(report: DiagnosticReport, destination: Destination, credentials: Credentials) throws -> URLRequest {
        guard var parts = URLComponents(url: destination.origin, resolvingAgainstBaseURL: false) else {
            throw DiagnosticRequestError.badURL
        }
        parts.path = path
        guard let url = parts.url else { throw DiagnosticRequestError.badURL }
        // A report can be 300 levels deep and the encoder recurses once per level: do it on the big stack.
        let body = try DiagnosticStack.run { () throws -> Data in try JSONEncoder().encode(report) }
        guard body.count < maxBodyBytes else { throw DiagnosticRequestError.bodyTooLarge(body.count) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.ingestSecret)", forHTTPHeaderField: "Authorization")
        if let id = credentials.accessID, let secret = credentials.accessSecret,
           Credentials.isHeaderValue(id), Credentials.isHeaderValue(secret) {
            request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        request.httpBody = body
        return request
    }
}

/// The network half: one URLSession that never follows a redirect, never keeps cookies, caches nothing.
public final class DiagnosticSender: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Never throws. A report that cannot even be built into a request (too big) is a reject, so it cannot jam the
    /// queue. Everything else is decided by the HTTP status.
    public func send(_ report: DiagnosticReport, to destination: Destination, credentials: Credentials) async -> DiagnosticUploader.Outcome {
        let request: URLRequest
        do {
            request = try DiagnosticUploader.request(report: report, destination: destination, credentials: credentials)
        } catch {
            return .reject
        }
        if Task.isCancelled { return .retryLater }
        do {
            let (_, response) = try await session.data(for: request)
            return DiagnosticUploader.outcome(status: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return .retryLater
        }
    }
}
