import Foundation

/// Everything the iPhone app reads from or writes to the Meetspike Worker. `APIClient` talks to the real
/// Worker, `DemoAPI` serves bundled fixtures, `UnconfiguredAPI` fails with `.notConfigured`. Screens only
/// ever hold a `MeetspikeAPI`, so previews and tests swap it freely.
///
/// Dates are local `YYYY-MM-DD` days as the Worker sees them. All methods throw `APIError` (or
/// `CancellationError` when the task is cancelled), except `askStream`, which reports problems as events.
public protocol MeetspikeAPI: Sendable {
    /// Where good GET answers are kept for offline use. nil for demo and unconfigured.
    var responseCache: ResponseCache? { get }

    /// GET /api/view?date=D. One day.
    func view(date: String) async throws -> ViewResponse
    /// GET /api/view?start=S&end=E. A span (or one day when start == end, still the range shape's sibling).
    func view(start: String, end: String) async throws -> ViewResponse
    /// GET /api/meetings/:id/hr. `fill` lets the Worker ask WHOOP to fill gaps first (slower).
    func meetingHR(id: String, fill: Bool) async throws -> MeetingHRDetail
    /// GET /api/meetings/:id/live-hr?since=N.
    func liveHR(meetingID: String, since: Int) async throws -> LiveHRReply
    /// GET /api/people?start&end.
    func people(start: String, end: String) async throws -> PeopleResponse
    /// GET /api/people/search?q=. Empty query gives an empty list without a request.
    func searchPeople(query: String) async throws -> [PersonMatch]
    /// GET /api/people/:email/meetings?start&end(&compact=1).
    func personMeetings(email: String, start: String, end: String, compact: Bool) async throws -> PersonMeetingsResponse
    /// GET /api/companies?start&end.
    func companies(start: String, end: String) async throws -> CompaniesResponse
    /// GET /api/companies/search?q=. Empty query gives an empty list without a request.
    func searchCompanies(query: String) async throws -> [CompanyMatch]
    /// GET /api/companies/:domain/meetings?start&end(&compact=1).
    func companyMeetings(domain: String, start: String, end: String, compact: Bool) async throws -> CompanyMeetingsResponse
    /// PUT /api/companies/:domain/name. nil or empty goes back to the name from the domain.
    func renameCompany(domain: String, name: String?) async throws -> CompanyNameResult
    /// PUT /api/meetings/:id/override. 400 and 404 arrive as `.http` with the Worker's sentence, 503 when the Worker
    /// has not had its database update yet.
    func saveOverride(meetingID: String, edit: OverrideEdit) async throws -> OverrideSaveResult
    /// POST /api/refresh, falling back to POST /api/calendar/sync on 404. Google not connected is a result, not an error.
    func refresh(full: Bool) async throws -> RefreshResult
    /// GET /api/settings/source-display.
    func sourceDisplay() async throws -> SourceDisplay
    /// PATCH /api/settings/source-display with exactly one key. Returns both flags as the Worker now has them.
    func setSourceDisplay(_ source: SourceDisplay.Source, enabled: Bool) async throws -> SourceDisplay
    /// GET /api/calendars. Google accounts and their calendars. `refresh` re-reads each account's list from Google.
    func googleCalendars(refresh: Bool) async throws -> GoogleCalendarsResponse
    /// PUT /api/calendars/selection with one change. Answers with the new state.
    func setGoogleCalendar(account: String, calendarId: String, selected: Bool) async throws -> GoogleCalendarsResponse
    /// DELETE /api/calendars/accounts/:email. Answers with the accounts that remain.
    func disconnectGoogleAccount(email: String) async throws -> GoogleCalendarsResponse
    /// GET /api/ask/status.
    func askStatus() async throws -> AskStatus
    /// PUT /api/ask/key. 400/503 arrive as `.http` with the Worker's sentence.
    func saveAskKey(_ key: String) async throws -> AskKeyResult
    /// DELETE /api/ask/key.
    func deleteAskKey() async throws -> AskKeyResult
    /// POST /api/ask/stream. Yields steps and text, then exactly one terminal event (`.done`, `.error` or `.cutOff`).
    /// Request problems the Worker reports before streaming (no key, bad range, too long) come out as `.error`.
    /// No network or a rejected sign-in throws `APIError`. Cancelling the consuming task closes the connection.
    func askStream(_ request: AskRequest) -> AsyncThrowingStream<AskEvent, Error>
}

// MARK: Defaults and the offline fallback

extension MeetspikeAPI {
    public func meetingHR(id: String) async throws -> MeetingHRDetail { try await meetingHR(id: id, fill: false) }
    public func liveHR(meetingID: String) async throws -> LiveHRReply { try await liveHR(meetingID: meetingID, since: 0) }
    public func personMeetings(email: String, start: String, end: String) async throws -> PersonMeetingsResponse {
        try await personMeetings(email: email, start: start, end: end, compact: true)
    }
    public func refresh() async throws -> RefreshResult { try await refresh(full: false) }

    /// Fetches fresh data. When the network is unreachable (and only then) falls back to the last good
    /// response for the same request, flagged `isFromCache`. Every other error is thrown as is.
    public func loaded<Value: Decodable & Sendable>(
        _ request: APIRequest, fetch: () async throws -> Value
    ) async throws -> Loaded<Value> {
        do {
            return Loaded(value: try await fetch(), savedAt: Date(), isFromCache: false)
        } catch APIError.offline {
            if let cache = responseCache, let hit = await cache.read(Value.self, for: request) {
                return Loaded(value: hit.value, savedAt: hit.savedAt, isFromCache: true)
            }
            throw APIError.offline
        }
    }

    /// The saved response for a day, without touching the network (for showing something instantly).
    public func cachedView(date: String) async -> CachedValue<ViewResponse>? {
        await responseCache?.read(ViewResponse.self, for: .view(date: date))
    }
    public func cachedView(start: String, end: String) async -> CachedValue<ViewResponse>? {
        await responseCache?.read(ViewResponse.self, for: .view(start: start, end: end))
    }

    public func loadView(date: String) async throws -> Loaded<ViewResponse> {
        try await loaded(.view(date: date)) { try await view(date: date) }
    }
    public func loadView(start: String, end: String) async throws -> Loaded<ViewResponse> {
        try await loaded(.view(start: start, end: end)) { try await view(start: start, end: end) }
    }
    public func loadMeetingHR(id: String, fill: Bool = false) async throws -> Loaded<MeetingHRDetail> {
        try await loaded(.meetingHR(id: id, fill: fill)) { try await meetingHR(id: id, fill: fill) }
    }
    public func loadPeople(start: String, end: String) async throws -> Loaded<PeopleResponse> {
        try await loaded(.people(start: start, end: end)) { try await people(start: start, end: end) }
    }
    public func loadPersonMeetings(email: String, start: String, end: String, compact: Bool = true) async throws -> Loaded<PersonMeetingsResponse> {
        try await loaded(.personMeetings(email: email, start: start, end: end, compact: compact)) {
            try await personMeetings(email: email, start: start, end: end, compact: compact)
        }
    }
    public func loadCompanies(start: String, end: String) async throws -> Loaded<CompaniesResponse> {
        try await loaded(.companies(start: start, end: end)) { try await companies(start: start, end: end) }
    }
    public func loadCompanyMeetings(domain: String, start: String, end: String, compact: Bool = true) async throws -> Loaded<CompanyMeetingsResponse> {
        try await loaded(.companyMeetings(domain: domain, start: start, end: end, compact: compact)) {
            try await companyMeetings(domain: domain, start: start, end: end, compact: compact)
        }
    }
    public func loadAskStatus() async throws -> Loaded<AskStatus> {
        try await loaded(.askStatus) { try await askStatus() }
    }
    public func loadSourceDisplay() async throws -> Loaded<SourceDisplay> {
        try await loaded(.sourceDisplay) { try await sourceDisplay() }
    }
}

/// The API before an origin is saved. Everything throws `.notConfigured`, so screens show their setup state.
public struct UnconfiguredAPI: MeetspikeAPI {
    public init() {}
    public var responseCache: ResponseCache? { nil }

    public func view(date: String) async throws -> ViewResponse { throw APIError.notConfigured }
    public func view(start: String, end: String) async throws -> ViewResponse { throw APIError.notConfigured }
    public func meetingHR(id: String, fill: Bool) async throws -> MeetingHRDetail { throw APIError.notConfigured }
    public func liveHR(meetingID: String, since: Int) async throws -> LiveHRReply { throw APIError.notConfigured }
    public func people(start: String, end: String) async throws -> PeopleResponse { throw APIError.notConfigured }
    public func searchPeople(query: String) async throws -> [PersonMatch] { throw APIError.notConfigured }
    public func personMeetings(email: String, start: String, end: String, compact: Bool) async throws -> PersonMeetingsResponse {
        throw APIError.notConfigured
    }
    public func companies(start: String, end: String) async throws -> CompaniesResponse { throw APIError.notConfigured }
    public func searchCompanies(query: String) async throws -> [CompanyMatch] { throw APIError.notConfigured }
    public func companyMeetings(domain: String, start: String, end: String, compact: Bool) async throws -> CompanyMeetingsResponse {
        throw APIError.notConfigured
    }
    public func renameCompany(domain: String, name: String?) async throws -> CompanyNameResult { throw APIError.notConfigured }
    public func saveOverride(meetingID: String, edit: OverrideEdit) async throws -> OverrideSaveResult {
        throw APIError.notConfigured
    }
    public func refresh(full: Bool) async throws -> RefreshResult { throw APIError.notConfigured }
    public func sourceDisplay() async throws -> SourceDisplay { throw APIError.notConfigured }
    public func setSourceDisplay(_ source: SourceDisplay.Source, enabled: Bool) async throws -> SourceDisplay {
        throw APIError.notConfigured
    }
    public func googleCalendars(refresh: Bool) async throws -> GoogleCalendarsResponse { throw APIError.notConfigured }
    public func setGoogleCalendar(account: String, calendarId: String, selected: Bool) async throws -> GoogleCalendarsResponse {
        throw APIError.notConfigured
    }
    public func disconnectGoogleAccount(email: String) async throws -> GoogleCalendarsResponse { throw APIError.notConfigured }
    public func askStatus() async throws -> AskStatus { throw APIError.notConfigured }
    public func saveAskKey(_ key: String) async throws -> AskKeyResult { throw APIError.notConfigured }
    public func deleteAskKey() async throws -> AskKeyResult { throw APIError.notConfigured }
    public func askStream(_ request: AskRequest) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: APIError.notConfigured) }
    }
}
