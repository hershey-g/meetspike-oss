import Foundation

// Small text helpers and the live-meeting picker for the Today tab. Pure, no clock (pass `now`), no SwiftUI.
// Each one names the web function it mirrors in public/app.js.

public enum TodayFormat {
    /// `${n}` in JavaScript: whole numbers without a decimal point, others as short as they go.
    public static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.10g", value)
        if text.contains("e") { text = String(value) }
        return text
    }

    /// `round(n, places)` in app.js: nil for nil or not finite.
    public static func rounded(_ value: Double?, places: Int = 0) -> Double? {
        guard let value, value.isFinite else { return nil }
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded(.toNearestOrAwayFromZero) / factor
    }

    /// `plural(n, word)`: "1 meeting", "3 meetings".
    public static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    /// `hoursText`: "4 h", "3.5 h".
    public static func hoursText(seconds: Int?) -> String {
        let hours = ((Double(seconds ?? 0) / 3600) * 10).rounded(.toNearestOrAwayFromZero) / 10
        return "\(number(hours)) h"
    }

    /// Sleep length on the sleep ring: "7 h 30 m". Rounds the total minutes first, then splits hours and minutes,
    /// so 28790 s is "8 h 0 m" and never "7 h 60 m".
    public static func sleepText(seconds: Double) -> String {
        let total = Int((seconds / 60).rounded(.toNearestOrAwayFromZero))
        return "\(total / 60) h \(total % 60) m"
    }

    /// `clockFromLocal`: "9:00 am" from "2026-11-24T09:00:00-05:00". Empty when there is no time.
    public static func clockFromLocal(_ iso: String?) -> String {
        guard let iso, let match = iso.range(of: #"T(\d{2}):(\d{2})"#, options: .regularExpression) else { return "" }
        let parts = iso[match].dropFirst().split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]) else { return "" }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(parts[1]) \(hour >= 12 ? "pm" : "am")"
    }

    /// The length on a meeting row when there is no heart rate pill: "30 m", "1 h 15 m".
    public static func lengthText(durationS: Int?) -> String {
        let mins = Int((Double(durationS ?? 0) / 60).rounded(.toNearestOrAwayFromZero))
        if mins >= 60 { return mins % 60 == 0 ? "\(mins / 60) h" : "\(mins / 60) h \(mins % 60) m" }
        return "\(mins) m"
    }

    /// `meetingMeta`: kind, first two people, after hours.
    public static func meetingMeta(_ meeting: Meeting) -> String {
        let people = meeting.attendees.map { ($0.name?.isEmpty == false ? $0.name : nil) ?? $0.email }
        var bits: [String] = []
        if let type = meeting.sourceType, !type.isEmpty, type != "calendar" {
            bits.append(type.hasPrefix("plaud_phone") ? "phone call" : "recording")
        } else if let kind = meeting.kind, !kind.isEmpty {
            bits.append(kind.replacingOccurrences(of: "_", with: " "))
        }
        if !people.isEmpty {
            bits.append(people.count > 2 ? "\(people.prefix(2).joined(separator: ", ")) +\(people.count - 2)" : people.joined(separator: ", "))
        }
        if meeting.afterHours == true { bits.append("after 6 pm") }
        return bits.joined(separator: " \u{B7} ")
    }

    /// `shortSentence`: the first sentence of a hit that says something the pill does not.
    /// Splits where a period is followed by any run of whitespace, newlines included (`/(?<=\.)\s+/`), and trims each part.
    public static func shortSentence(_ hit: InsightHit) -> String {
        let head = trimmedPeriod(hit.hrStress?.headline ?? "")
        let first = sentences(hit.sentence ?? "").first { trimmedPeriod($0) != head } ?? ""
        return first.replacingOccurrences(of: " beats per minute", with: " bpm")
    }

    /// Splits text after each period that is followed by whitespace. Parts are trimmed and empty parts dropped.
    static func sentences(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace, current.last == "." {
                while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
            index = text.index(after: index)
        }
        parts.append(current)
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func trimmedPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// "Tue, Nov 24" (weekday true) or "Nov 24" for a local day, with no time zone shifting.
    public static func dayText(_ day: String, weekday: Bool) -> String {
        guard let date = DayMath.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = weekday ? "EEE, MMM d" : "MMM d"
        return formatter.string(from: date)
    }

    /// `shortDay`: "Nov 18", with the year when it is not the same year as `today`.
    public static func shortDay(_ day: String, today: String) -> String {
        let text = dayText(day, weekday: false)
        guard day.prefix(4) != today.prefix(4) else { return text }
        return "\(text), \(day.prefix(4))"
    }

    /// Which meeting to open on its own (app.js renderToday): among meetings with `now` inside
    /// `[startMs, toMs)`, the latest start, preferring one with `now < endMs`. nil when none.
    public static func liveMeetingID(events: [Meeting], now: Date) -> String? {
        let nowMs = now.timeIntervalSince1970 * 1000
        let started = events
            .compactMap { event -> (id: String, window: LiveWindowMs)? in
                guard let window = TodayLogic.liveWindow(
                    startUtc: event.startUtc, endUtc: event.endUtc, sourceType: event.sourceType) else { return nil }
                return (event.id, window)
            }
            .filter { nowMs >= $0.window.startMs && nowMs < $0.window.toMs }
            .sorted { $0.window.startMs > $1.window.startMs }
        return (started.first { nowMs < $0.window.endMs } ?? started.first)?.id
    }
}

/// What the live heart rate card has seen so far, and how a poll answer or failure changes it
/// (`pollLivePanel` in app.js, window handling from `public/live-hr.js`).
public struct TodayLiveSession: Equatable, Sendable {
    public var window: LiveWindowMs
    public var points: [LivePoint] = []
    public var cursor = 0
    /// Overrides the usual message: "Outside the live window", "Reconnecting...", and so on. Empty means none.
    public var status = ""
    /// Polls that failed in a row. Back to 0 on a good answer.
    public private(set) var failures = 0

    /// Seconds between polls: 5, and 15 after this many failures in a row (a bad token or a down server is not
    /// hammered every 5 seconds).
    public static let pollSeconds = 5.0
    public static let backoffSeconds = 15.0
    public static let backoffAfterFailures = 3

    public init(window: LiveWindowMs) {
        self.window = window
    }

    /// A good answer. `requestedCursor` is the `since` the request used.
    public mutating func apply(_ reply: LiveHRReply, requestedCursor: Int) {
        failures = 0
        let incoming = reply.window ?? window
        let changed = incoming.fromMs != window.fromMs || incoming.toMs != window.toMs
        window = incoming
        status = ""
        if changed && requestedCursor != 0 {
            // A calendar edit can add time on either side of the cursor, so start over.
            points = []
            cursor = 0
        } else if reply.active == true {
            points = TodayLogic.mergeLivePoints(points, reply.points)
            cursor = reply.cursor ?? cursor
        } else {
            points = []
            cursor = 0
            status = "Outside the live window"
        }
    }

    /// How long to wait before the next poll.
    public var pollDelay: Double {
        Self.pollDelay(failures: failures)
    }

    public static func pollDelay(failures: Int) -> Double {
        failures >= backoffAfterFailures ? backoffSeconds : pollSeconds
    }

    /// A failed poll that is not an `APIError`. Counts toward the backoff.
    public mutating func noteFailure() {
        failures += 1
        status = "Reconnecting\u{2026}"
    }

    /// A failed poll. Returns false when polling should stop (sign-in rejected), true to try again.
    public mutating func apply(_ error: APIError) -> Bool {
        failures += 1
        switch error {
        case .accessRejected:
            points = []
            status = "Sign in to resume"
            return false
        case .http(let code, _) where code == 404:
            points = []
            status = "Live heart rate unavailable"
            return true
        default:
            status = "Reconnecting\u{2026}"
            return true
        }
    }

    /// The words in the card header: the status when there is one, else what the readings say.
    public func message(for chart: TodayLiveChart) -> String {
        if !status.isEmpty { return status }
        if chart.current != nil { return "Receiving readings" }
        if chart.last != nil { return "Waiting for new readings" }
        return "Waiting for Meetspike HR on your Mac"
    }
}
