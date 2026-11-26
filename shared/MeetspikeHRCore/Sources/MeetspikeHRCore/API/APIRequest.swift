import Foundation

/// One HTTP call to the Worker, as plain data. Typed endpoints are the static builders below,
/// so tests, the cache and `DemoAPI` all agree on paths and query strings.
public struct APIRequest: Equatable, Sendable {
    public enum Method: String, Sendable {
        case get = "GET", post = "POST", patch = "PATCH", put = "PUT", delete = "DELETE"
    }

    public var method: Method
    /// Absolute path starting with `/api/`. Already percent-encoded (use `segment(_:)` for variable parts).
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    /// Seconds. Refresh waits on the Worker for up to 15 s per source, so it asks for more.
    public var timeout: TimeInterval
    /// Successful GET answers are kept in the `ResponseCache` when this is true.
    public var cacheable: Bool

    public init(
        method: Method = .get, path: String, query: [URLQueryItem] = [], body: Data? = nil,
        timeout: TimeInterval = 30, cacheable: Bool? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeout = timeout
        self.cacheable = cacheable ?? (method == .get)
    }

    /// Percent-encodes one path segment or query value: only letters, digits and `-._~` pass through,
    /// so `@` and `+` in an email can never be misread by the server.
    public static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        // A segment of only dots ("." or "..") is a relative segment to URL rules and would climb out of the route.
        // Writing the dots as %2E keeps it a plain id on the wire (as a query value it decodes to the same dots).
        if !encoded.isEmpty, encoded.allSatisfy({ $0 == "." }) { return encoded.map { _ in "%2E" }.joined() }
        return encoded
    }

    /// `a=1&b=2` with every name and value encoded, in the order given.
    public var encodedQuery: String? {
        guard !query.isEmpty else { return nil }
        return query.map { "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))" }.joined(separator: "&")
    }

    /// Stable key for the response cache: method, path and the query sorted by name.
    public var cacheKey: String {
        let sorted = query.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        let items = sorted.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(method.rawValue) \(path)\(items.isEmpty ? "" : "?\(items)")"
    }

    /// The full URL against an origin, or nil when it cannot be built.
    public func url(origin: URL) -> URL? {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedPath = path
        parts.percentEncodedQuery = encodedQuery
        return parts.url
    }
}

// MARK: Typed endpoints

extension APIRequest {
    /// GET /api/view?date=D
    public static func view(date: String) -> APIRequest {
        APIRequest(path: "/api/view", query: [.init(name: "date", value: date)])
    }

    /// GET /api/view?start=S&end=E
    public static func view(start: String, end: String) -> APIRequest {
        APIRequest(path: "/api/view", query: [.init(name: "start", value: start), .init(name: "end", value: end)])
    }

    /// GET /api/meetings/:id/hr. `fill: false` sends `fill=0` so the Worker does not call WHOOP to fill gaps.
    public static func meetingHR(id: String, fill: Bool = false) -> APIRequest {
        APIRequest(
            path: "/api/meetings/\(encode(id))/hr",
            query: fill ? [] : [.init(name: "fill", value: "0")]
        )
    }

    /// GET /api/meetings/:id/live-hr?since=N (never cached)
    public static func liveHR(meetingID: String, since: Int = 0) -> APIRequest {
        APIRequest(
            path: "/api/meetings/\(encode(meetingID))/live-hr",
            query: [.init(name: "since", value: String(since))], timeout: 10, cacheable: false
        )
    }

    /// GET /api/people?start=S&end=E
    public static func people(start: String, end: String) -> APIRequest {
        APIRequest(path: "/api/people", query: [.init(name: "start", value: start), .init(name: "end", value: end)])
    }

    /// GET /api/people/search?q=Q (never cached on disk: the in-memory `PeopleSearchCache` covers it)
    public static func searchPeople(query: String) -> APIRequest {
        APIRequest(path: "/api/people/search", query: [.init(name: "q", value: query)], cacheable: false)
    }

    /// GET /api/people/:email/meetings?start=S&end=E&compact=1
    public static func personMeetings(email: String, start: String, end: String, compact: Bool = true) -> APIRequest {
        var query: [URLQueryItem] = [.init(name: "start", value: start), .init(name: "end", value: end)]
        if compact { query.append(.init(name: "compact", value: "1")) }
        return APIRequest(path: "/api/people/\(encode(email))/meetings", query: query)
    }

    /// GET /api/companies?start=S&end=E
    public static func companies(start: String, end: String) -> APIRequest {
        APIRequest(path: "/api/companies", query: [.init(name: "start", value: start), .init(name: "end", value: end)])
    }

    /// GET /api/companies/search?q=Q (never cached on disk)
    public static func searchCompanies(query: String) -> APIRequest {
        APIRequest(path: "/api/companies/search", query: [.init(name: "q", value: query)], cacheable: false)
    }

    /// GET /api/companies/:domain/meetings?start=S&end=E&compact=1
    public static func companyMeetings(domain: String, start: String, end: String, compact: Bool = true) -> APIRequest {
        var query: [URLQueryItem] = [.init(name: "start", value: start), .init(name: "end", value: end)]
        if compact { query.append(.init(name: "compact", value: "1")) }
        return APIRequest(path: "/api/companies/\(encode(domain))/meetings", query: query)
    }

    /// PUT /api/companies/:domain/name `{"name": "..."}`. A nil or empty name goes back to the name from the domain.
    public static func renameCompany(domain: String, name: String?) throws -> APIRequest {
        let body: Data
        if let name { body = try JSONEncoder().encode(["name": name]) } else { body = Data(#"{"name":null}"#.utf8) }
        return APIRequest(method: .put, path: "/api/companies/\(encode(domain))/name", body: body, timeout: 15, cacheable: false)
    }

    /// PUT /api/meetings/:id/override. The body is the edit as the Worker reads it (`OverrideEdit`).
    public static func putOverride(meetingID: String, edit: OverrideEdit) throws -> APIRequest {
        APIRequest(
            method: .put, path: "/api/meetings/\(encode(meetingID))/override", body: try JSONEncoder().encode(edit),
            timeout: 15, cacheable: false)
    }

    /// POST /api/refresh `{"mode":"live"}` or `{"mode":"live","full":true}`
    public static func refresh(full: Bool = false) -> APIRequest {
        APIRequest(method: .post, path: "/api/refresh", body: refreshBody(full: full), timeout: 60)
    }

    /// POST /api/calendar/sync, the older calendar-only endpoint refresh falls back to on 404.
    public static func calendarSync(full: Bool = false) -> APIRequest {
        APIRequest(method: .post, path: "/api/calendar/sync", body: refreshBody(full: full), timeout: 60)
    }

    private static func refreshBody(full: Bool) -> Data {
        Data((full ? #"{"full":true,"mode":"live"}"# : #"{"mode":"live"}"#).utf8)
    }

    /// GET /api/settings/source-display
    public static let sourceDisplay = APIRequest(path: "/api/settings/source-display", timeout: 10)

    /// PATCH /api/settings/source-display with exactly one key, e.g. `{"oura":true}`.
    public static func setSourceDisplay(_ source: SourceDisplay.Source, enabled: Bool) -> APIRequest {
        APIRequest(
            method: .patch, path: "/api/settings/source-display",
            body: Data(#"{"\#(source.rawValue)":\#(enabled ? "true" : "false")}"#.utf8), timeout: 10
        )
    }

    /// GET /api/ask/status
    public static let askStatus = APIRequest(path: "/api/ask/status", timeout: 10)

    /// PUT /api/ask/key `{"key": "..."}`. The key is only ever sent here, never logged or cached.
    public static func saveAskKey(_ key: String) throws -> APIRequest {
        APIRequest(method: .put, path: "/api/ask/key", body: try JSONEncoder().encode(["key": key]), timeout: 30)
    }

    /// DELETE /api/ask/key
    public static let deleteAskKey = APIRequest(method: .delete, path: "/api/ask/key", timeout: 10)

    /// POST /api/ask/stream
    public static func askStream(_ request: AskRequest) throws -> APIRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return APIRequest(method: .post, path: "/api/ask/stream", body: try encoder.encode(request), timeout: 60, cacheable: false)
    }
}
