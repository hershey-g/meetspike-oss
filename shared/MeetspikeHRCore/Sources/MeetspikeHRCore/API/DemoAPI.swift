import Foundation

/// A `MeetspikeAPI` that answers from bundled fixture JSON: the iPhone app's `-demo data` mode and UI previews.
/// Fake people and data only (example.com addresses). Works fully offline.
///
/// - The fixture "today" is `DemoAPI.demoToday`. That day shows five meetings, a heavy day with heart rate.
///   Any other single day shows the empty-day fixture (no meetings), so the empty state is one tap away.
/// - `failure` makes every call throw, to preview error and offline states. Set it back to nil to recover.
/// - Source display and the Claude key keep state in memory, so toggles and Ask setup behave.
public final class DemoAPI: MeetspikeAPI, @unchecked Sendable {
    /// The day the full fixture is dated.
    public static let demoToday = "2026-11-24"

    public let responseCache: ResponseCache? = nil

    private let directory: URL
    private let latency: TimeInterval
    private let streamPacing: TimeInterval
    private let lock = NSLock()
    private var currentFailure: APIError?
    private var currentEmptyDays: Bool
    /// The app's demo day also shows meeting choices (see `DemoMeetingChoices`). Off for the plain fixtures.
    private let seedsMeetingChoices: Bool
    private var display: SourceDisplay
    private var askConnected: Bool
    /// Company renames made in this session, by domain.
    private var companyNames: [String: String] = [:]
    /// Meeting choices made in this session. They are laid over the fixture day, newest last.
    private var overrideEdits: [OverrideOutbox.Item] = []
    /// Google accounts and calendar choices changed in this session (nil until the first change).
    private var calendarState: GoogleCalendarsResponse?

    /// - Parameters:
    ///   - directory: folder holding the fixture files (the app's bundled `DemoData`, or the test `Fixtures`).
    ///   - latency: seconds to wait before each answer, to make loading states visible. 0 for tests.
    ///   - streamPacing: seconds between streamed Ask events. 0 for tests.
    ///   - emptyDays: when true every day is the empty-day fixture.
    ///   - askKeySaved: whether Ask starts with a saved key.
    public init(
        directory: URL, latency: TimeInterval = 0, streamPacing: TimeInterval = 0, emptyDays: Bool = false,
        askKeySaved: Bool = true, seedsMeetingChoices: Bool = false
    ) {
        self.directory = directory
        self.seedsMeetingChoices = seedsMeetingChoices
        self.latency = latency
        self.streamPacing = streamPacing
        currentEmptyDays = emptyDays
        askConnected = askKeySaved
        display = SourceDisplay.make(oura: true, whoop: true)
    }

    /// The `DemoData` folder inside an app bundle, or nil when it is not bundled.
    public static func bundled(in bundle: Bundle = .main, latency: TimeInterval = 0.25, streamPacing: TimeInterval = 0.04) -> DemoAPI? {
        guard let url = bundle.url(forResource: "DemoData", withExtension: nil) else { return nil }
        return DemoAPI(directory: url, latency: latency, streamPacing: streamPacing, seedsMeetingChoices: true)
    }

    /// When set, every call throws this error (askStream throws it too).
    public var failure: APIError? {
        get { lock.withLock { currentFailure } }
        set { lock.withLock { currentFailure = newValue } }
    }

    /// When true every day is the empty-day fixture.
    public var showsEmptyDays: Bool {
        get { lock.withLock { currentEmptyDays } }
        set { lock.withLock { currentEmptyDays = newValue } }
    }

    // MARK: Fixtures

    private func fixture<Value: Decodable>(_ name: String, as type: Value.Type = Value.self) throws -> Value {
        let data = try rawFixture(name)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding("fixture \(name) does not match \(type)")
        }
    }

    private func rawFixture(_ name: String) throws -> Data {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            throw APIError.decoding("missing fixture \(name)")
        }
        return data
    }

    private func gate() async throws {
        if let failure { throw failure }
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        if let failure { throw failure }
    }

    // MARK: MeetspikeAPI

    public func view(date: String) async throws -> ViewResponse {
        try await gate()
        if date == Self.demoToday && !showsEmptyDays {
            var view: ViewResponse = try fixture("view-day.json")
            if seedsMeetingChoices, var calendar = view.day?.calendar {
                calendar.events = DemoMeetingChoices.seed(calendar.events)
                DemoMeetingChoices.recount(&calendar)
                view.day?.calendar = calendar
            }
            let edits = lock.withLock { overrideEdits }
            if !edits.isEmpty, let events = view.day?.calendar?.events {
                view.day?.calendar?.events = OverrideOverlay.apply(edits, to: events)
            }
            return view
        }
        var view: ViewResponse = try fixture("view-empty-day.json")
        view.start = date
        view.end = date
        view.day?.date = date
        view.day?.calendar?.day = date
        if !view.series.isEmpty { view.series[0].day = date }
        return view
    }

    public func view(start: String, end: String) async throws -> ViewResponse {
        if start == end { return try await view(date: start) }
        try await gate()
        var view: ViewResponse = try fixture("view-range.json")
        view.start = start
        view.end = end
        view.spanDays = DayMath.spanDays(start, end)
        view.range?.start = start
        view.range?.end = end
        view.range?.spanDays = view.spanDays
        return view
    }

    public func meetingHR(id: String, fill: Bool) async throws -> MeetingHRDetail {
        try await gate()
        var detail: MeetingHRDetail = try fixture("meeting-hr.json")
        detail.meetingId = id
        return detail
    }

    public func liveHR(meetingID: String, since: Int) async throws -> LiveHRReply {
        try await gate()
        return try fixture("live-hr.json")
    }

    public func people(start: String, end: String) async throws -> PeopleResponse {
        try await gate()
        var reply: PeopleResponse = try fixture("people.json")
        reply.start = start
        reply.end = end
        reply.spanDays = DayMath.spanDays(start, end)
        return reply
    }

    public func searchPeople(query: String) async throws -> [PersonMatch] {
        try await gate()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let all: PeopleSearchReply = try fixture("people-search.json")
        return all.people.filter { ($0.name ?? "").lowercased().contains(needle) || $0.email.lowercased().contains(needle) }
    }

    public func personMeetings(email: String, start: String, end: String, compact: Bool) async throws -> PersonMeetingsResponse {
        try await gate()
        var reply: PersonMeetingsResponse = try fixture("person-meetings.json")
        reply.email = email
        reply.from = start
        reply.to = end
        return reply
    }

    public func companies(start: String, end: String) async throws -> CompaniesResponse {
        try await gate()
        var reply: CompaniesResponse = try fixture("companies.json")
        reply.start = start
        reply.end = end
        reply.spanDays = DayMath.spanDays(start, end)
        let renamed = lock.withLock { companyNames }
        for index in reply.companies.indices {
            if let name = renamed[reply.companies[index].domain] { reply.companies[index].name = name }
        }
        return reply
    }

    public func searchCompanies(query: String) async throws -> [CompanyMatch] {
        try await gate()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let all: CompanySearchReply = try fixture("company-search.json")
        let renamed = lock.withLock { companyNames }
        return all.companies
            .map { CompanyTag(domain: $0.domain, name: renamed[$0.domain] ?? $0.name) }
            .filter { ($0.name ?? "").lowercased().contains(needle) || $0.domain.contains(needle) }
    }

    public func companyMeetings(domain: String, start: String, end: String, compact: Bool) async throws -> CompanyMeetingsResponse {
        try await gate()
        var reply: CompanyMeetingsResponse = try fixture("company-meetings.json")
        let listed: CompaniesResponse? = try? fixture("companies.json")
        if reply.domain != domain {
            reply.name = listed?.companies.first { $0.domain == domain }?.name ?? domain
        }
        reply.domain = domain
        if let name = lock.withLock({ companyNames[domain] }) { reply.name = name }
        reply.from = start
        reply.to = end
        return reply
    }

    public func saveOverride(meetingID: String, edit: OverrideEdit) async throws -> OverrideSaveResult {
        try await gate()
        lock.withLock {
            overrideEdits.append(OverrideOutbox.Item(eventID: meetingID, edit: edit, queuedAt: Date()))
        }
        return OverrideSaveResult(ok: true, id: meetingID, scope: edit.scope.rawValue)
    }

    public func renameCompany(domain: String, name: String?) async throws -> CompanyNameResult {
        try await gate()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed: CompaniesResponse? = try? fixture("companies.json")
        return lock.withLock {
            if let trimmed, !trimmed.isEmpty { companyNames[domain] = trimmed } else { companyNames[domain] = nil }
            let fallback = listed?.companies.first { $0.domain == domain }?.name ?? domain
            return CompanyNameResult(ok: true, domain: domain, name: companyNames[domain] ?? fallback)
        }
    }

    public func refresh(full: Bool) async throws -> RefreshResult {
        try await gate()
        let reply: RefreshReply = try fixture("refresh.json")
        return RefreshResult(calendar: reply.calendar, whoop: reply.whoop, oura: reply.oura, syncedAt: reply.syncedAt)
    }

    public func sourceDisplay() async throws -> SourceDisplay {
        try await gate()
        return lock.withLock { display }
    }

    public func setSourceDisplay(_ source: SourceDisplay.Source, enabled: Bool) async throws -> SourceDisplay {
        try await gate()
        return lock.withLock {
            display = source == .oura
                ? SourceDisplay.make(oura: enabled, whoop: display.whoop)
                : SourceDisplay.make(oura: display.oura, whoop: enabled)
            return display
        }
    }

    private func currentCalendars() throws -> GoogleCalendarsResponse {
        if let held = lock.withLock({ calendarState }) { return held }
        let loaded: GoogleCalendarsResponse = try fixture("calendars.json")
        return lock.withLock {
            if calendarState == nil { calendarState = loaded }
            return calendarState ?? loaded
        }
    }

    public func googleCalendars(refresh: Bool) async throws -> GoogleCalendarsResponse {
        try await gate()
        return try currentCalendars()
    }

    public func setGoogleCalendar(account: String, calendarId: String, selected: Bool) async throws -> GoogleCalendarsResponse {
        try await gate()
        var state = try currentCalendars()
        guard let a = state.accounts.firstIndex(where: { $0.email == account }),
              let c = state.accounts[a].calendars.firstIndex(where: { $0.id == calendarId }) else {
            throw APIError.http(status: 404, message: "no calendar \(calendarId) on \(account)")
        }
        let changed = state.accounts[a].calendars[c].isSelected != selected
        state.accounts[a].calendars[c].selected = selected
        state.changed = changed ? 1 : 0
        state.syncError = nil
        lock.withLock { calendarState = state }
        return state
    }

    public func disconnectGoogleAccount(email: String) async throws -> GoogleCalendarsResponse {
        try await gate()
        var state = try currentCalendars()
        guard state.accounts.contains(where: { $0.email == email }) else {
            throw APIError.http(status: 404, message: "\(email) is not connected")
        }
        state.accounts.removeAll { $0.email == email }
        state.removed = true
        lock.withLock { calendarState = state }
        return state
    }

    public func askStatus() async throws -> AskStatus {
        try await gate()
        let connected = lock.withLock { askConnected }
        var status: AskStatus = try fixture(connected ? "ask-status.json" : "ask-status-nokey.json")
        status.sourceDisplay = lock.withLock { display }
        return status
    }

    public func saveAskKey(_ key: String) async throws -> AskKeyResult {
        try await gate()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.invalidRequest("empty key") }
        lock.withLock { askConnected = true }
        return try fixture("ask-key-saved.json")
    }

    public func deleteAskKey() async throws -> AskKeyResult {
        try await gate()
        lock.withLock { askConnected = false }
        return try fixture("ask-key-deleted.json")
    }

    public func askStream(_ request: AskRequest) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await gate()
                    guard lock.withLock({ askConnected }) else {
                        continuation.yield(.error(AskFailure(message: "Add your Claude API key in More, then ask again.", needsKey: true)))
                        continuation.finish()
                        return
                    }
                    var parser = AskEventParser()
                    let events = Self.demoAskEvents(fixture: parser.push(try rawFixture("ask-stream.sse")) + parser.finish(), request: request)
                    for event in events {
                        try Task.checkCancellation()
                        if streamPacing > 0 { try await Task.sleep(nanoseconds: UInt64(streamPacing * 1_000_000_000)) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension DemoAPI {
    /// The first day all demo history covers.
    static let demoBaselineStart = "2026-01-03"

    /// The fixture stream plus what build 10 adds, so the Ask screen can be checked in demo mode: a `range` event
    /// first, and a 5 column table (the fixture already has a 3 column one) before the last step. The `done` event
    /// stays as the fixture has it.
    static func demoAskEvents(fixture: [AskEvent], request: AskRequest) -> [AskEvent] {
        let today = demoToday
        let ranked = request.allTime
            ? AskRange(start: demoBaselineStart, end: today, baselineStart: demoBaselineStart, baselineEnd: today, source: "allTime")
            : AskRange(start: "2026-10-28", end: today, baselineStart: demoBaselineStart, baselineEnd: today, source: "question")
        var events = fixture
        let table = "\n| Day | Meetings | Hours | Recovery | Sleep |\n|---|---|---|---|---|\n"
            + "| Nov 12 | 6 | 4.5 | 31% | 55 |\n| Nov 5 | 5 | 4 | 38% | 61 |\n"
        if let lastText = events.lastIndex(where: { if case .text = $0 { true } else { false } }) {
            events.insert(.text(table), at: lastText + 1)
        }
        events.insert(.range(ranked), at: 0)
        return events
    }
}
