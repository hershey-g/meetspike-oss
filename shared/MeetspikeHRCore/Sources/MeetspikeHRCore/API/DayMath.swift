import Foundation

/// Calendar-day arithmetic on `YYYY-MM-DD` strings, the same way the web app does it
/// (noon UTC, so DST never shifts a day). No time zones are involved: a "day" here is
/// already a local day chosen by the Worker.
public enum DayMath {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Noon UTC on that day, or nil when `day` is not a real `YYYY-MM-DD` date.
    public static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = 12
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == d, calendar.component(.month, from: date) == m else { return nil }
        return date
    }

    /// `YYYY-MM-DD` for an instant, read in UTC (used with the noon-UTC dates above).
    public static func string(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// True for a real calendar day.
    public static func isValid(_ day: String) -> Bool { date(day) != nil }

    /// `day` plus `n` days (n may be negative). Returns `day` unchanged when it is not a valid day.
    public static func addDays(_ day: String, _ n: Int) -> String {
        guard let base = date(day), let moved = calendar.date(byAdding: .day, value: n, to: base) else { return day }
        return string(moved)
    }

    /// Inclusive number of days from start to end (1 for the same day). 0 when either is invalid.
    public static func spanDays(_ start: String, _ end: String) -> Int {
        guard let a = date(start), let b = date(end) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded()) + 1
    }

    /// Today's local day in the given time zone.
    public static func today(in zone: TimeZone, now: Date = Date()) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let c = local.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `YYYY-MM` shifted by n months.
    public static func shiftMonth(_ month: String, _ n: Int) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2, var y = Int(parts[0]), let m0 = Int(parts[1]) else { return month }
        var m = m0 - 1 + n
        y += Int((Double(m) / 12).rounded(.down))
        m = ((m % 12) + 12) % 12
        return String(format: "%04d-%02d", y, m + 1)
    }

    /// Last day of a `YYYY-MM` month as `YYYY-MM-DD`.
    public static func lastDay(ofMonth month: String) -> String {
        addDays("\(shiftMonth(month, 1))-01", -1)
    }
}
