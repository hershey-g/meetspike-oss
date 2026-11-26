import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The live `MeetspikeAPI`. Same rules as `Uploader`: ephemeral session, no cookies, no cache, redirects
/// refused, https only (http only for localhost). Sends the Cloudflare Access service token headers from
/// `Credentials` when both parts are valid header values. Never logs or caches headers or the Claude key.
public final class APIClient: MeetspikeAPI {
    public let origin: URL
    public let responseCache: ResponseCache?

    private let accessID: String?
    private let accessSecret: String?
    private let userAgent: String
    private let session: URLSession
    private let streamSession: URLSession
    private let observer: RequestObserver?

    /// Called after every request with the URL path (no query), the HTTP status (0 when there was no answer) and the
    /// milliseconds it took. For the crash breadcrumbs: the app maps the path to a template with `CrumbRoute`, so
    /// nothing from a path ever gets logged. It runs on whatever thread the request finished on and must be quick.
    public typealias RequestObserver = @Sendable (_ path: String, _ status: Int, _ milliseconds: Int) -> Void

    /// Fails (nil) unless `origin` is a bare https origin, or http on localhost. Pass a `URLSessionConfiguration`
    /// with `protocolClasses` set to stub the network in tests.
    public convenience init?(
        origin: String, credentials: Credentials?, userAgent: String = "MeetspikeHR",
        configuration: URLSessionConfiguration = .ephemeral, cache: ResponseCache? = nil, observer: RequestObserver? = nil
    ) {
        guard let destination = Destination(origin) else { return nil }
        self.init(
            destination: destination, credentials: credentials, userAgent: userAgent, configuration: configuration,
            cache: cache, observer: observer
        )
    }

    public init(
        destination: Destination, credentials: Credentials?, userAgent: String = "MeetspikeHR",
        configuration: URLSessionConfiguration = .ephemeral, cache: ResponseCache? = nil, observer: RequestObserver? = nil
    ) {
        origin = destination.origin
        responseCache = cache
        self.observer = observer
        self.userAgent = userAgent
        if let id = credentials?.accessID, let secret = credentials?.accessSecret,
           Credentials.isHeaderValue(id), Credentials.isHeaderValue(secret) {
            accessID = id
            accessSecret = secret
        } else {
            accessID = nil
            accessSecret = nil
        }
        // A copy keeps the injected protocol classes for the long-lived answer stream.
        let streaming = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        for config in [configuration, streaming] {
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
        }
        configuration.timeoutIntervalForResource = 90
        // Pings keep the stream alive every 15 s; an answer can take minutes.
        streaming.timeoutIntervalForRequest = 60
        streaming.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        streamSession = URLSession(configuration: streaming, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    // MARK: Request building

    /// The exact URLRequest sent for `request`. Public so tests can check headers without a network.
    public func urlRequest(for request: APIRequest) throws -> URLRequest {
        guard let url = request.url(origin: origin) else { throw APIError.invalidRequest("bad path") }
        // Every request stays on the saved origin.
        guard url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
            throw APIError.invalidRequest("wrong host")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessID, let accessSecret {
            urlRequest.setValue(accessID, forHTTPHeaderField: "CF-Access-Client-Id")
            urlRequest.setValue(accessSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return urlRequest
    }

    // MARK: Transport

    private struct Raw {
        var status: Int
        var data: Data
    }

    static func isAccessProblem(_ response: HTTPURLResponse) -> Bool {
        let status = response.statusCode
        if (300..<400).contains(status) || status == 401 || status == 403 { return true }
        return (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html")
    }

    static func transportError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? CancellationError() : APIError.offline
        }
        return error
    }

    /// One round trip. Throws for transport trouble and Access problems; any other status comes back to the caller.
    private func raw(_ request: APIRequest) async throws -> Raw {
        let urlRequest = try urlRequest(for: request)
        let started = DispatchTime.now().uptimeNanoseconds
        let path = urlRequest.url?.path ?? ""
        func milliseconds() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            observer?(path, 0, milliseconds())
            throw Self.transportError(error)
        }
        observer?(path, (response as? HTTPURLResponse)?.statusCode ?? 0, milliseconds())
        guard let http = response as? HTTPURLResponse else { throw APIError.decoding("not an HTTP answer") }
        if Self.isAccessProblem(http) { throw APIError.accessRejected }
        return Raw(status: http.statusCode, data: data)
    }

    private static func failure(status: Int, data: Data) -> APIError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let text = body?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(status: status, message: (text?.isEmpty == false ? text : nil) ?? "Something went wrong (\(status)).")
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from raw: Raw) throws -> Value {
        guard (200..<300).contains(raw.status) else { throw Self.failure(status: raw.status, data: raw.data) }
        do {
            return try JSONDecoder().decode(type, from: raw.data)
        } catch {
            throw APIError.decoding("\(type): \(Self.shortReason(error))")
        }
    }

    /// Key path and kind only: a decoding error must never carry response values into a log.
    private static func shortReason(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "unreadable" }
        func path(_ context: DecodingError.Context) -> String { context.codingPath.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(path(context)).\(key.stringValue)"
        case .typeMismatch(_, let context): return "wrong type at \(path(context))"
        case .valueNotFound(_, let context): return "empty value at \(path(context))"
        case .dataCorrupted: return "not JSON"
        @unknown default: return "unreadable"
        }
    }

    /// Fetch, decode, and keep the answer for offline use when the request is cacheable.
    private func get<Value: Decodable & Sendable>(_ request: APIRequest, as type: Value.Type) async throws -> Value {
        let answer = try await raw(request)
        let value = try decode(type, from: answer)
        if request.cacheable, let cache = responseCache {
            // Best effort: the caller still has its answer. The cache counts failed writes.
            try? await cache.write(answer.data, for: request)
        }
        return value
    }

    // MARK: Typed endpoints

    public func view(date: String) async throws -> ViewResponse {
        try await get(.view(date: date), as: ViewResponse.self)
    }

    public func view(start: String, end: String) async throws -> ViewResponse {
        try await get(.view(start: start, end: end), as: ViewResponse.self)
    }

    public func meetingHR(id: String, fill: Bool) async throws -> MeetingHRDetail {
        try await get(.meetingHR(id: id, fill: fill), as: MeetingHRDetail.self)
    }

    public func liveHR(meetingID: String, since: Int) async throws -> LiveHRReply {
        try await get(.liveHR(meetingID: meetingID, since: since), as: LiveHRReply.self)
    }

    public func people(start: String, end: String) async throws -> PeopleResponse {
        try await get(.people(start: start, end: end), as: PeopleResponse.self)
    }

    public func searchPeople(query: String) async throws -> [PersonMatch] {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !text.isEmpty else { return [] }
        return try await get(.searchPeople(query: text), as: PeopleSearchReply.self).people
    }

    public func personMeetings(email: String, start: String, end: String, compact: Bool) async throws -> PersonMeetingsResponse {
        try await get(.personMeetings(email: email, start: start, end: end, compact: compact), as: PersonMeetingsResponse.self)
    }

    public func companies(start: String, end: String) async throws -> CompaniesResponse {
        try await get(.companies(start: start, end: end), as: CompaniesResponse.self)
    }

    public func searchCompanies(query: String) async throws -> [CompanyMatch] {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !text.isEmpty else { return [] }
        return try await get(.searchCompanies(query: text), as: CompanySearchReply.self).companies
    }

    public func companyMeetings(domain: String, start: String, end: String, compact: Bool) async throws -> CompanyMeetingsResponse {
        try await get(.companyMeetings(domain: domain, start: start, end: end, compact: compact), as: CompanyMeetingsResponse.self)
    }

    public func renameCompany(domain: String, name: String?) async throws -> CompanyNameResult {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await get(try .renameCompany(domain: domain, name: trimmed?.isEmpty == false ? trimmed : nil), as: CompanyNameResult.self)
    }

    public func saveOverride(meetingID: String, edit: OverrideEdit) async throws -> OverrideSaveResult {
        try await get(try .putOverride(meetingID: meetingID, edit: edit), as: OverrideSaveResult.self)
    }

    public func refresh(full: Bool) async throws -> RefreshResult {
        let first = try await raw(.refresh(full: full))
        if first.status == 404 { return try await calendarOnlyRefresh(full: full) }
        if first.status == 409, let body = try? JSONDecoder().decode(ErrorBody.self, from: first.data), body.needsGoogle == true {
            return RefreshResult(calendar: RefreshPart(ok: false, error: body.error, needsGoogle: true), needsGoogle: true)
        }
        let reply = try decode(RefreshReply.self, from: first)
        return RefreshResult(
            calendar: reply.calendar, whoop: reply.whoop, oura: reply.oura, syncedAt: reply.syncedAt,
            needsGoogle: reply.calendar?.needsGoogle == true
        )
    }

    /// An older Worker has no /api/refresh: sync the calendar only.
    private func calendarOnlyRefresh(full: Bool) async throws -> RefreshResult {
        let answer = try await raw(.calendarSync(full: full))
        if answer.status == 409, let body = try? JSONDecoder().decode(ErrorBody.self, from: answer.data), body.needsGoogle == true {
            return RefreshResult(
                calendar: RefreshPart(ok: false, error: body.error, needsGoogle: true),
                usedCalendarFallback: true, needsGoogle: true
            )
        }
        guard (200..<300).contains(answer.status) else { throw Self.failure(status: answer.status, data: answer.data) }
        return RefreshResult(calendar: RefreshPart(ok: true), usedCalendarFallback: true)
    }

    public func sourceDisplay() async throws -> SourceDisplay {
        try await get(.sourceDisplay, as: SourceDisplay.self)
    }

    public func setSourceDisplay(_ source: SourceDisplay.Source, enabled: Bool) async throws -> SourceDisplay {
        try await get(.setSourceDisplay(source, enabled: enabled), as: SourceDisplay.self)
    }

    public func googleCalendars(refresh: Bool) async throws -> GoogleCalendarsResponse {
        try await get(.calendars(refresh: refresh), as: GoogleCalendarsResponse.self)
    }

    public func setGoogleCalendar(account: String, calendarId: String, selected: Bool) async throws -> GoogleCalendarsResponse {
        try await get(try .setCalendarSelection([CalendarSelection(account: account, calendarId: calendarId, selected: selected)]),
                      as: GoogleCalendarsResponse.self)
    }

    public func disconnectGoogleAccount(email: String) async throws -> GoogleCalendarsResponse {
        try await get(.disconnectGoogleAccount(email: email), as: GoogleCalendarsResponse.self)
    }

    public func askStatus() async throws -> AskStatus {
        try await get(.askStatus, as: AskStatus.self)
    }

    public func saveAskKey(_ key: String) async throws -> AskKeyResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.invalidRequest("empty key") }
        return try await get(try .saveAskKey(trimmed), as: AskKeyResult.self)
    }

    public func deleteAskKey() async throws -> AskKeyResult {
        try await get(.deleteAskKey, as: AskKeyResult.self)
    }

    // MARK: Ask stream

    #if canImport(FoundationNetworking)
    // swift-corelibs has no streaming bytes API. The apps only build for Apple platforms.
    public func askStream(_ request: AskRequest) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: APIError.invalidRequest("streaming is not available on this platform")) }
    }
    #else
    public func askStream(_ request: AskRequest) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var started = false
                var parser = AskEventParser()
                // One crumb per stream request: the real status when the headers arrive, 0 when there was no answer.
                // `observed` keeps it to once, so a cancel or a drop later in the body adds nothing.
                var observed = false
                var requestSent = false
                var requestPath = ""
                var requestBegan: UInt64 = 0
                func observe(_ status: Int) {
                    guard requestSent, !observed else { return }
                    observed = true
                    let ms = Int((DispatchTime.now().uptimeNanoseconds &- requestBegan) / 1_000_000)
                    observer?(requestPath, status, ms)
                }
                do {
                    var urlRequest = try urlRequest(for: try .askStream(request))
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    requestPath = urlRequest.url?.path ?? ""
                    requestBegan = DispatchTime.now().uptimeNanoseconds
                    requestSent = true
                    let (bytes, response) = try await streamSession.bytes(for: urlRequest)
                    observe((response as? HTTPURLResponse)?.statusCode ?? 0)
                    guard let http = response as? HTTPURLResponse else { throw APIError.decoding("not an HTTP answer") }
                    if Self.isAccessProblem(http) { throw APIError.accessRejected }
                    guard (200..<300).contains(http.statusCode) else {
                        // Problems found before streaming are plain JSON with the Worker's sentence.
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 65_536 { break }
                        }
                        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
                        let message = body?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.yield(.error(AskFailure(
                            message: (message?.isEmpty == false ? message : nil) ?? "Something went wrong (\(http.statusCode)).",
                            needsKey: body?.needsKey ?? false
                        )))
                        continuation.finish()
                        return
                    }
                    started = true
                    for try await byte in bytes {
                        for event in parser.push(byte: byte) { continuation.yield(event) }
                        if parser.sawTerminal { break }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    observe(0)   // does nothing when the headers already arrived
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish()
                    } else if started {
                        // The connection dropped mid-answer: keep what arrived and mark it cut off.
                        for event in parser.finish() { continuation.yield(event) }
                        continuation.finish()
                    } else {
                        let mapped = Self.transportError(error)
                        if mapped is CancellationError { continuation.finish() } else { continuation.finish(throwing: mapped) }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif
}
