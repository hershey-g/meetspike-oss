import Foundation

// Pure logic for the More tab (port of public/app.js renderMore).

/// One line in the connections list.
public struct MoreConnectionRow: Equatable, Sendable, Identifiable {
    /// "whoop", "oura" or "google".
    public var id: String
    /// "WHOOP", "Oura" or "Google Calendar".
    public var title: String
    public var isConnected: Bool
    /// Whether Meetspike shows this wearable's data. nil for Google Calendar (no switch).
    public var isDisplayed: Bool?
    /// Newest day with data from this wearable (`YYYY-MM-DD`), nil for Google or when unknown.
    public var lastDataDay: String?

    public init(id: String, title: String, isConnected: Bool, isDisplayed: Bool?, lastDataDay: String?) {
        self.id = id
        self.title = title
        self.isConnected = isConnected
        self.isDisplayed = isDisplayed
        self.lastDataDay = lastDataDay
    }
}

public enum MoreLogic {
    /// The text a Menu sheet row shows for a failed call: the row's prefix, then the error's message. Every error
    /// gets text, including offline and access rejected, because the sheet has no connection banner.
    /// A non-API error gets the generic message. An empty prefix gives just the message.
    public static func sheetError(_ error: Error, prefix: String) -> String {
        let message = (error as? APIError)?.message ?? "Something went wrong. Try again."
        return prefix.isEmpty ? message : "\(prefix) \(message)"
    }

    /// PATCH /api/settings/source-display for one source. The body has exactly one key (`{"oura":true}`): the Worker
    /// refuses anything else, and one key lets two devices change different sources at once.
    public static func sourceToggleRequest(source: SourceDisplay.Source, enabled: Bool) -> APIRequest {
        .setSourceDisplay(source, enabled: enabled)
    }

    /// Rows for the connections card: one per entry of `status.wearables` in the order the Worker sent them
    /// (id = source, title = label, `isDisplayed` = displayEnabled, `lastDataDay` only when the wearable has
    /// history), then Google Calendar (`googleConnected`). The Google row is always there: with no status
    /// (nothing loaded yet) it reads as not connected, so the screen can still offer "Connect".
    public static func connectionRows(status: ViewStatus?) -> [MoreConnectionRow] {
        var rows: [MoreConnectionRow] = []
        for wearable in status?.wearables ?? [] {
            guard let source = wearable.source, !source.isEmpty else { continue }
            let hasHistory = !(wearable.history?.min ?? "").isEmpty
            rows.append(MoreConnectionRow(
                id: source,
                title: wearable.label ?? source,
                isConnected: wearable.connected ?? false,
                isDisplayed: wearable.displayEnabled,
                lastDataDay: hasHistory ? wearable.lastDataDay : nil))
        }
        rows.append(MoreConnectionRow(
            id: "google", title: "Google Calendar", isConnected: status?.googleConnected ?? false,
            isDisplayed: nil, lastDataDay: nil))
        return rows
    }

    /// "Version 1.0 (4)". No build: "Version 1.0". No version: "".
    public static func versionLabel(version: String?, build: String?) -> String {
        guard let version, !version.isEmpty else { return "" }
        guard let build, !build.isEmpty else { return "Version \(version)" }
        return "Version \(version) (\(build))"
    }

    /// "Mon, Nov 24" for a `YYYY-MM-DD` day (the web's fmtDay). Falls back to the input.
    public static func dayLabel(_ day: String) -> String {
        guard let date = DayMath.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
    }

    /// The second line of a connection row, as on the web: "Last data Mon, Nov 24 · History 2026-01-02 to 2026-11-24",
    /// or "No data yet" without history. Google Calendar is "Read-only".
    public static func connectionDetail(for row: MoreConnectionRow, status: ViewStatus?) -> String {
        if row.id == "google" { return "Read-only" }
        let history = status?.wearables.first { $0.source == row.id }?.history
        guard let min = history?.min, !min.isEmpty else { return "No data yet" }
        let max = history?.max ?? min
        guard let last = row.lastDataDay else { return "History \(min) to \(max)" }
        return "Last data \(dayLabel(last)) \u{B7} History \(min) to \(max)"
    }

    /// The web setup page for a row: `/setup?wearable=oura`, or `/setup` for Google Calendar.
    /// Only ever on the configured Worker origin: `origin` must be https with a host, anything else returns nil.
    /// Credentials, an existing path, query or fragment on `origin` are dropped, and `rowID` must be a plain id
    /// (letters, digits, `-`, `_`) so a value from the Worker cannot add query parameters.
    public static func setupURL(origin: URL, rowID: String) -> URL? {
        guard origin.scheme?.lowercased() == "https", let host = origin.host, !host.isEmpty else { return nil }
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        parts.path = "/setup"
        if rowID == "google" || rowID.isEmpty {
            parts.queryItems = nil
        } else {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
            guard rowID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            parts.queryItems = [URLQueryItem(name: "wearable", value: rowID)]
        }
        guard let url = parts.url, url.host == host, url.scheme == "https" else { return nil }
        return url
    }

    // MARK: AI key row

    /// "Key …tail" when a key is saved, "Not set up" when the Worker cannot store one, "Add key" otherwise.
    public static func askKeyStatus(_ status: AskStatus?) -> (text: String, isSet: Bool) {
        if status?.connected == true {
            let tail = status?.tail ?? ""
            return (tail.isEmpty ? "Key set" : "Key \u{2026}\(tail)", true)
        }
        if let status, status.available == false { return ("Not set up", false) }
        return ("Add key", false)
    }

    // MARK: Sync result copy

    /// Meetings written plus removed by the calendar part of a refresh (web `(r.written ?? 0) + (r.removed ?? 0)`).
    public static func changedCount(_ result: RefreshResult) -> Int {
        (result.calendar?.written ?? 0) + (result.calendar?.removed ?? 0)
    }

    /// What the Sync calendar row says after a full refresh (web `syncCalendar` plus the footer's WHOOP and Oura notes).
    /// "Synced just now. N meetings updated." with N = written + removed, "1 meeting" when it is one (web `plural`).
    /// `showWhoop` and `showOura` follow "Show data": a hidden wearable that failed to refresh stays quiet.
    public static func syncMessage(_ result: RefreshResult, showWhoop: Bool = true, showOura: Bool = true) -> String {
        // One decision shared with Today (SyncOutcome): a calendar problem never hides a wearable failure.
        let outcome = SyncOutcome.decide(result, showWhoop: showWhoop, showOura: showOura)
        let first: String
        switch outcome.calendar {
        case .needsGoogle:
            first = "Connect Google Calendar to sync meetings."
        case .failed(let error):
            first = "Calendar sync failed: \(error)"
        case .pending:
            first = "Still syncing in the background. New meetings show up when it finishes."
        case .synced(let changed):
            first = "Synced just now. \(changed) \(changed == 1 ? "meeting" : "meetings") updated."
        }
        return ([first] + outcome.wearableNotes).joined(separator: " ")
    }

    /// Whether a finished refresh changed anything the other tabs show. Not when Google is missing and no wearable
    /// refreshed (web `err.wearableRefreshed`).
    public static func shouldPostDataRefreshed(_ result: RefreshResult) -> Bool {
        !result.needsGoogle || result.wearableRefreshed
    }
}
