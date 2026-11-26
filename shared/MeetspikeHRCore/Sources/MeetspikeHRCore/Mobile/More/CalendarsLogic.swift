import Foundation

/// Words and rules for the Calendars screen (Menu > Calendars): connected Google accounts with a switch per
/// calendar, Add Google account, Disconnect, and the Apple Calendar calendars that start listening.
public enum CalendarsLogic {
    /// "Add Google account" opens the setup page's calendar section in Safari. Google sign-in has to happen in a
    /// browser, behind the same Cloudflare Access sign-in as the rest of the site.
    public static func addAccountURL(origin: URL) -> URL? {
        guard let setup = MoreLogic.setupURL(origin: origin, rowID: ""),
              var parts = URLComponents(url: setup, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = "calendars"
        return parts.url
    }

    /// Second line under a calendar's name, or nil.
    public static func calendarDetail(_ calendar: GoogleCalendar) -> String? {
        if let error = calendar.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return "Sync failed. \(shortError(error))"
        }
        return nil
    }

    /// The calendar's name, or its id when Google gave none. Google names the main calendar after the account
    /// address, which the section already shows, so it reads "Main calendar" instead.
    public static func calendarName(_ calendar: GoogleCalendar, account: String? = nil) -> String {
        let name = calendar.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if calendar.isPrimary && (name.isEmpty || name == calendar.id || name.lowercased() == account?.lowercased()) {
            return "Main calendar"
        }
        return name.isEmpty ? calendar.id : name
    }

    /// Under each account: its sync state.
    public static func accountFooter(_ account: GoogleAccount, now: Date = .now) -> String {
        if let error = account.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            if error.contains("refresh failed") || error.contains("401") || error.contains("no refresh_token") {
                return "Google sign-in expired. Use Add Google account and pick this account again."
            }
            return "Last sync failed. \(shortError(error))"
        }
        return syncedText(account.lastSyncAt, now: now)
    }

    /// "Synced just now", "Synced 5 min ago", "Synced 3 hr ago", "Synced Nov 20", "Not synced yet".
    public static func syncedText(_ iso: String?, now: Date = .now) -> String {
        guard let when = APITime.parse(iso) else { return "Not synced yet" }
        let seconds = max(0, now.timeIntervalSince(when))
        if seconds < 90 { return "Synced just now" }
        if seconds < 3_600 { return "Synced \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "Synced \(Int(seconds / 3_600)) hr ago" }
        let format = Date.FormatStyle().month(.abbreviated).day()
        return "Synced \(when.formatted(format))"
    }

    /// One short sentence from a Worker error, without the raw Google body.
    public static func shortError(_ error: String) -> String {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: #"google (\d{3})"#, options: .regularExpression) {
            let status = text[match].split(separator: " ").last.map(String.init) ?? ""
            return "Google answered \(status)."
        }
        return text.count > 120 ? String(text.prefix(117)) + "..." : text
    }

    /// Title and message for the Disconnect confirmation.
    public static func disconnectTitle(_ email: String) -> String { "Disconnect \(email)?" }
    public static let disconnectMessage =
        "Its meetings leave Meetspike unless another connected calendar has them. You can add it again later."

    /// "2 accounts, 3 calendars" for the Menu row. Nil before anything has loaded.
    public static func summary(_ response: GoogleCalendarsResponse?) -> String? {
        guard let response else { return nil }
        let accounts = response.accounts.count
        if accounts == 0 { return "No Google account" }
        let chosen = response.accounts.reduce(0) { $0 + $1.calendars.filter(\.isSelected).count }
        let a = accounts == 1 ? "1 account" : "\(accounts) accounts"
        let c = chosen == 1 ? "1 calendar" : "\(chosen) calendars"
        return "\(a), \(c)"
    }

    /// The state with one switch flipped, shown at once while the change is saved.
    public static func applying(
        _ response: GoogleCalendarsResponse, account: String, calendarId: String, selected: Bool
    ) -> GoogleCalendarsResponse {
        var copy = response
        guard let a = copy.accounts.firstIndex(where: { $0.email == account }),
              let c = copy.accounts[a].calendars.firstIndex(where: { $0.id == calendarId }) else { return response }
        copy.accounts[a].calendars[c].selected = selected
        return copy
    }

    /// The state without one account, shown at once while it is disconnected.
    public static func removing(_ response: GoogleCalendarsResponse, account: String) -> GoogleCalendarsResponse {
        var copy = response
        copy.accounts.removeAll { $0.email == account }
        return copy
    }

    /// Words after a switch is saved, or nil when there is nothing to say.
    public static func savedMessage(_ response: GoogleCalendarsResponse, selected: Bool) -> String? {
        if let error = response.syncError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return "Saved. Sync failed: \(shortError(error))"
        }
        return selected ? "Added. Its meetings are in." : nil
    }

    /// "#rrggbb" to 0...1 red, green, blue. Nil for anything else.
    public static func rgb(_ hex: String?) -> (red: Double, green: Double, blue: Double)? {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
