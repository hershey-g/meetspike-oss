import Foundation

// Pure logic for the People tab. Mirrors public/people-ui.js, public/range-presets.js and the people code in public/app.js.

/// The People date range choices.
public enum PeopleRangePreset: String, CaseIterable, Sendable, Equatable {
    case days7 = "7d", days28 = "28d", days90 = "90d", year

    /// Menu label: "Past 7 days", "Past 28 days", "Past 90 days", "Past year".
    public var menuLabel: String {
        switch self {
        case .days7: return "Past 7 days"
        case .days28: return "Past 28 days"
        case .days90: return "Past 90 days"
        case .year: return "Past year"
        }
    }
    /// Scope label above the list and sent with Ask: "Last 7 days", "Last 28 days", "Last 90 days", "Last year".
    public var scopeLabel: String {
        switch self {
        case .days7: return "Last 7 days"
        case .days28: return "Last 28 days"
        case .days90: return "Last 90 days"
        case .year: return "Last year"
        }
    }
    /// 7, 28, 90, 365.
    public var days: Int {
        switch self {
        case .days7: return 7
        case .days28: return 28
        case .days90: return 90
        case .year: return 365
        }
    }
}

/// The selected People range. 28 days is the default.
public enum PeopleRange: Equatable, Sendable {
    case preset(PeopleRangePreset)
    case custom(start: String, end: String)

    public static let `default` = PeopleRange.preset(.days28)
}

public enum PeopleLogic {
    /// The message to show when a refresh fails with data already on screen. Nil when the connection banner
    /// already covers it (`coveredByBanner`). Otherwise the error's message, or a generic one for a non-API error.
    public static func refreshNotice(error: Error, coveredByBanner: Bool) -> String? {
        if coveredByBanner { return nil }
        return (error as? APIError)?.message ?? "Something went wrong. Try again."
    }

    /// Meetings shown per page on a person screen.
    public static let pageSize = 40
    /// Search answers are reused for 5 minutes, at most 40 queries.
    public static let searchCacheSeconds = 300.0
    public static let searchCacheLimit = 40
    /// A sparkline never draws many more points than this.
    public static let sparklineTarget = 120

    /// A person page must load again when the email or the span differs from what it last loaded (or nothing is
    /// loaded). Keying on the span alone showed the first person's data on the next person's page.
    public static func shouldReloadPerson(
        loadedEmail: String?, loadedSpan: DatesSpan?, email: String, span: DatesSpan
    ) -> Bool {
        guard let loadedEmail, let loadedSpan else { return true }
        return loadedEmail != email || loadedSpan != span
    }

    /// Whether an answer that arrived for `answerEmail` and `answerSpan` may be painted while the page shows
    /// `showingEmail` and `showingSpan`. Anything else is a late answer for another person or range: drop it.
    public static func acceptsPersonAnswer(
        answerEmail: String, answerSpan: DatesSpan, showingEmail: String, showingSpan: DatesSpan
    ) -> Bool {
        answerEmail == showingEmail && answerSpan == showingSpan
    }

    /// Real start and end days for a range. Presets end `today` and start `1 - days` days before it
    /// (28 days: today minus 27 through today). Custom returns its own dates.
    public static func dates(for range: PeopleRange, today: String) -> DatesSpan {
        switch range {
        case .custom(let start, let end):
            return DatesSpan(start: start, end: end)
        case .preset(let preset):
            return DatesSpan(start: DayMath.addDays(today, 1 - preset.days), end: today)
        }
    }

    /// True for two real calendar days with start on or before end (and within years 0100 to 9999).
    public static func validCustomDates(start: String?, end: String?) -> Bool {
        func valid(_ day: String?) -> Bool {
            guard let day, day.utf8.count == 10, day.utf8.allSatisfy({ $0 == 45 || ($0 >= 48 && $0 <= 57) }),
                  DayMath.isValid(day) else { return false }
            return day >= "0100-01-01" && day <= "9999-12-30"
        }
        guard valid(start), valid(end), let start, let end else { return false }
        return start <= end
    }

    /// Downsamples newest-first `spark` values for a sparkline: keeps every Nth value with
    /// `N = max(1, ceil(count / 120))`, starting with the first, then reverses so the line runs oldest to newest.
    public static func sparkline(_ spark: [Double], target: Int = 120) -> [Double] {
        guard !spark.isEmpty else { return [] }
        let step = max(1, Int((Double(spark.count) / Double(max(1, target))).rounded(.up)))
        return stride(from: 0, to: spark.count, by: step).map { spark[$0] }.reversed()
    }

    /// Average next-morning score for a person's meetings: one value per day (the last meeting that day with a
    /// `nextReadinessScore` wins), then the mean rounded to a whole number. `mornings` is how many distinct days
    /// counted. Fewer than 4 mornings is "a hint, not a pattern" (`isThin`).
    public static func perDayAverage(_ meetings: [PersonMeeting]) -> PeoplePerDayAverage {
        var byDay: [String: Double] = [:]
        for meeting in meetings {
            guard let day = meeting.day, let score = meeting.nextReadinessScore else { continue }
            byDay[day] = score
        }
        guard !byDay.isEmpty else { return PeoplePerDayAverage(average: nil, mornings: 0) }
        let mean = byDay.values.reduce(0, +) / Double(byDay.count)
        return PeoplePerDayAverage(average: Int(mean.rounded()), mornings: byDay.count)
    }
}

public struct PeoplePerDayAverage: Equatable, Sendable {
    public var average: Int?
    public var mornings: Int
    public init(average: Int?, mornings: Int) {
        self.average = average
        self.mornings = mornings
    }
    /// Some mornings but under 4.
    public var isThin: Bool { mornings > 0 && mornings < 4 }
}

/// Answers to People search kept in memory: 5 minute lifetime, 40 entries, oldest dropped first.
/// Keys are the query normalised (Unicode NFC, lower case).
public struct PeopleSearchCache: Sendable {
    private struct Entry: Sendable {
        var people: [PersonMatch]
        var storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    /// Keys, oldest first.
    private var order: [String] = []

    public init() {}

    private static func key(_ query: String) -> String {
        query.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A fresh hit, or nil when missing or older than 5 minutes.
    public func people(for query: String, now: Date) -> [PersonMatch]? {
        guard let entry = entries[Self.key(query)] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) < PeopleLogic.searchCacheSeconds else { return nil }
        return entry.people
    }

    /// Stores an answer. Re-storing a query moves it to the newest slot. Going over 40 drops the oldest.
    public mutating func store(_ people: [PersonMatch], for query: String, now: Date) {
        let key = Self.key(query)
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = Entry(people: people, storedAt: now)
        while order.count > PeopleLogic.searchCacheLimit {
            entries[order.removeFirst()] = nil
        }
    }

    /// Forget everything (pull to refresh).
    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    /// Number of entries held.
    public var count: Int { entries.count }
}

/// Paging for a person's meeting list: 40 at first, 40 more each time.
public struct PeoplePager: Equatable, Sendable {
    public private(set) var shown: Int
    public init(shown: Int = PeopleLogic.pageSize) { self.shown = shown }

    /// The slice to draw.
    public func visible<T>(_ items: [T]) -> ArraySlice<T> { items.prefix(max(0, shown)) }
    /// There are more than `shown` items.
    public func hasMore(total: Int) -> Bool { total > shown }
    /// Show 40 more.
    public mutating func showMore() { shown += PeopleLogic.pageSize }
    /// Back to the first page (range or person changed).
    public mutating func reset() { shown = PeopleLogic.pageSize }
}

/// Remembers which span (and which connection) the content on screen was loaded for, so coming back to a screen
/// (pop from a person page, return from another tab) keeps the content and refreshes quietly instead of blanking it
/// with a spinner and resetting the pager. A different span, a different connection (the Meetspike URL or a token
/// changed, so the old server's people must not stay up), or nothing loaded yet, still gets the spinner.
/// `connection` is `AppEnvironment.connectionRevision`; callers that do not care leave it at 0.
public struct PeopleLoadGate: Equatable, Sendable {
    public private(set) var loadedSpan: DatesSpan?
    public private(set) var loadedConnection: Int
    public init(loadedSpan: DatesSpan? = nil, loadedConnection: Int = 0) {
        self.loadedSpan = loadedSpan
        self.loadedConnection = loadedConnection
    }

    /// Content for exactly this span and connection is already on screen.
    public func hasContent(for span: DatesSpan, connection: Int = 0) -> Bool {
        loadedSpan == span && loadedConnection == connection
    }
    /// Show the spinner (and drop what is on screen) only when nothing is loaded for this span and connection.
    public func showsSpinner(for span: DatesSpan, connection: Int = 0) -> Bool { !hasContent(for: span, connection: connection) }
    /// Go back to the first page only when the span or connection changed. A quiet refresh keeps the pager where it is.
    public func resetsPager(for span: DatesSpan, connection: Int = 0) -> Bool { !hasContent(for: span, connection: connection) }

    public mutating func markLoaded(_ span: DatesSpan, connection: Int = 0) {
        loadedSpan = span
        loadedConnection = connection
    }
    /// Forget the loaded span (a failure replaced the content).
    public mutating func clear() { loadedSpan = nil }
}
