import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Credentials: Codable, Sendable {
    public var ingestSecret: String
    public var accessID: String?
    public var accessSecret: String?

    public init(ingestSecret: String, accessID: String? = nil, accessSecret: String? = nil) {
        self.ingestSecret = ingestSecret
        self.accessID = accessID
        self.accessSecret = accessSecret
    }

    public static func isHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

public struct Destination: Sendable {
    public let origin: URL
    public let endpoint: URL
    public let liveEndpoint: URL
    public let reminderEndpoint: URL
    public let reminderOwnerEndpoint: URL
    public let sourceDisplayEndpoint: URL
    public let latestBuildEndpoint: URL

    public init?(_ value: String) {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input), let host = parts.host?.lowercased(), !host.isEmpty,
              let scheme = parts.scheme?.lowercased(), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        let loopback = host == "localhost"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        parts.scheme = scheme
        parts.path = ""
        guard let url = parts.url else { return nil }
        parts.path = "/api/whoop-web/ingest"
        guard let endpoint = parts.url else { return nil }
        parts.path = "/api/whoop-web/live"
        guard let liveEndpoint = parts.url else { return nil }
        parts.path = "/api/whoop-web/reminder"
        guard let reminderEndpoint = parts.url else { return nil }
        parts.path = "/api/whoop-web/reminder/owner"
        guard let reminderOwnerEndpoint = parts.url else { return nil }
        parts.path = "/api/settings/source-display"
        guard let sourceDisplayEndpoint = parts.url else { return nil }
        parts.path = "/api/whoop-web/app/ios"
        guard let latestBuildEndpoint = parts.url else { return nil }
        origin = url
        self.endpoint = endpoint
        self.liveEndpoint = liveEndpoint
        self.reminderEndpoint = reminderEndpoint
        self.reminderOwnerEndpoint = reminderOwnerEndpoint
        self.sourceDisplayEndpoint = sourceDisplayEndpoint
        self.latestBuildEndpoint = latestBuildEndpoint
    }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum IngestUploadError: Error {
    case missingReceipt
}

public struct SourceDisplay: Decodable, Equatable, Sendable {
    public enum Source: String, Sendable { case oura, whoop }

    public let oura: Bool
    public let whoop: Bool
}

public final class Uploader: Sendable {
    private struct IngestReceipt: Decodable {
        let ok: Bool
        let rawStored: Bool
    }

    let session: URLSession

    public convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func post(_ body: Data, to destination: Destination, credentials: Credentials) async throws -> Int? {
        let request = Self.request(body, to: destination, credentials: credentials)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 200 {
            guard let receipt = try? JSONDecoder().decode(IngestReceipt.self, from: data),
                  receipt.ok, receipt.rawStored else { throw IngestUploadError.missingReceipt }
        }
        return status
    }

    static func request(_ body: Data, to destination: Destination, credentials: Credentials) -> URLRequest {
        request(body, to: destination.endpoint, credentials: credentials)
    }

    public func postLive(
        _ points: [HeartRatePoint], includeMeeting: Bool, to destination: Destination, credentials: Credentials
    ) async throws -> LiveUploadResponse {
        let body = try JSONEncoder().encode(LiveUploadPayload(points: points, includeMeeting: includeMeeting))
        var request = Self.request(body, to: destination.liveEndpoint, credentials: credentials)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveUploadError.invalidResponse }
        guard http.statusCode == 200 else { throw LiveUploadError.http(http.statusCode) }
        let decoder = JSONDecoder()
        // Calendar timestamps include milliseconds when written by Google sync.
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw LiveUploadError.invalidResponse }
            return date
        }
        let reply = try decoder.decode(LiveUploadResponse.self, from: data)
        guard reply.ok else { throw LiveUploadError.invalidResponse }
        return reply
    }

    /// The calendar meeting starting now, for the Heart Rate Broadcast reminder.
    public func reminderLookup(to destination: Destination, credentials: Credentials) async throws -> ReminderLookup {
        var request = Self.request(Data(), to: destination.reminderEndpoint, credentials: credentials)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveUploadError.invalidResponse }
        guard http.statusCode == 200 else { throw LiveUploadError.http(http.statusCode) }
        let reply = try JSONDecoder().decode(ReminderLookup.self, from: data)
        guard reply.ok else { throw LiveUploadError.invalidResponse }
        return reply
    }

    public func sourceDisplay(
        at destination: Destination, credentials: Credentials, update: (SourceDisplay.Source, Bool)? = nil
    ) async throws -> SourceDisplay {
        let body = try update.map { try JSONEncoder().encode([$0.0.rawValue: $0.1]) }
        var request = Self.request(body ?? Data(), to: destination.sourceDisplayEndpoint, credentials: credentials,
                                   includeIngestSecret: false)
        request.httpMethod = body == nil ? "GET" : "PATCH"
        request.httpBody = body
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveUploadError.invalidResponse }
        guard http.statusCode == 200 else { throw LiveUploadError.http(http.statusCode) }
        return try JSONDecoder().decode(SourceDisplay.self, from: data)
    }

    /// The newest iPhone TestFlight build the Worker knows about, or nil.
    public func latestIOSBuild(at destination: Destination, credentials: Credentials) async throws -> Int? {
        var request = Self.request(Data(), to: destination.latestBuildEndpoint, credentials: credentials)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveUploadError.invalidResponse }
        guard http.statusCode == 200 else { throw LiveUploadError.http(http.statusCode) }
        let reply = try JSONDecoder().decode(LatestBuildReply.self, from: data)
        guard reply.ok else { throw LiveUploadError.invalidResponse }
        return reply.build
    }

    /// Ask the Worker to forward the reminder to Pushover. Returns the HTTP status.
    public func postReminder(_ alert: HRReminderAlert, to destination: Destination, credentials: Credentials) async throws -> Int? {
        let body = try Self.reminderBody(alert)
        var request = Self.request(body, to: destination.reminderEndpoint, credentials: credentials)
        request.timeoutInterval = 10
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    }

    /// The iPhone checks in (active, with the meeting starts it scheduled a
    /// reminder for) or steps down.
    public func checkInReminderOwner(
        active: Bool, covered: [Date] = [], push: PushRegistration? = nil,
        to destination: Destination, credentials: Credentials
    ) async throws -> ReminderOwnerReply {
        var request = Self.request(
            try Self.reminderOwnerBody(active: active, covered: covered, push: push),
            to: destination.reminderOwnerEndpoint, credentials: credentials
        )
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveUploadError.invalidResponse }
        guard http.statusCode == 200 else { throw LiveUploadError.http(http.statusCode) }
        let reply = try JSONDecoder().decode(ReminderOwnerReply.self, from: data)
        guard reply.ok else { throw LiveUploadError.invalidResponse }
        return reply
    }

    static func reminderOwnerBody(active: Bool, covered: [Date], push: PushRegistration?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(ReminderOwnerPost(active: active, covered: covered, push: push))
    }

    static func reminderBody(_ alert: HRReminderAlert) throws -> Data {
        try JSONEncoder().encode(ReminderPost(title: alert.title, repeated: alert.isRepeat))
    }

    static func request(
        _ body: Data, to endpoint: URL, credentials: Credentials, includeIngestSecret: Bool = true
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if includeIngestSecret {
            request.setValue("Bearer \(credentials.ingestSecret)", forHTTPHeaderField: "Authorization")
        }
        if let id = credentials.accessID, let secret = credentials.accessSecret,
           Credentials.isHeaderValue(id), Credentials.isHeaderValue(secret) {
            request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        request.httpBody = body
        return request
    }
}
