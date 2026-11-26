import Foundation

/// Copy and small formatting helpers for the People screens. Ports of `plural`, `initials`, `clockFromLocal`,
/// `shortDay` and `personHrLine` in public/app.js. Plain strings in, plain strings out.
public enum PeopleFormat {
    /// "1 meeting", "3 meetings".
    public static func plural(_ n: Int, _ word: String, many: String? = nil) -> String {
        "\(n) \(n == 1 ? word : (many ?? "\(word)s"))"
    }

    /// Up to two letters for the avatar: first letters of the first two name parts, or of the email name.
    public static func initials(name: String?, email: String?) -> String {
        let source = [name, email].compactMap { $0 }.first { !$0.isEmpty } ?? "?"
        let local = source.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? source
        let parts = local.split(whereSeparator: { " ._-\t\n".contains($0) })
        let first = parts.first?.first.map(String.init) ?? "?"
        let second = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }

    /// "3:05 pm" from an ISO local time like `2026-11-24T15:05:00-05:00`. Empty when there is no time.
    public static func clock(fromLocal iso: String?) -> String {
        guard let iso, let t = iso.firstIndex(of: "T") else { return "" }
        let digits = Array(iso[iso.index(after: t)...].prefix(5))
        guard digits.count == 5, digits[2] == ":",
              let h = Int(String(digits[0...1])), let m = Int(String(digits[3...4])) else { return "" }
        let hour = h % 12 == 0 ? 12 : h % 12
        return "\(hour):" + (m < 10 ? "0\(m)" : "\(m)") + (h >= 12 ? " pm" : " am")
    }

    /// "Nov 24", or "Nov 24, 2025" when the day is not in the same year as `today`.
    public static func shortDay(_ day: String?, today: String) -> String {
        guard let day, let date = DayMath.date(day) else { return day ?? "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = day.prefix(4) == today.prefix(4) ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// First sentence of a provider's heart rate summary on a person page, for example
    /// "WHOOP heart rate in 5 meetings: median 82 bpm. 2 elevated, 2 worth watching, 1 restored."
    /// The zone counts are left out for the combined "WHOOP + Oura" source.
    public static func hrLine(source: String?, withCoverage: Int, medianBpm: Double?, elevated: Int?, watching: Int?, restored: Int?) -> String {
        let name = source ?? "Heart"
        var bits = ["\(name) heart rate in \(plural(withCoverage, "meeting"))" + (medianBpm.map { ": median \(Int($0.rounded())) bpm" } ?? "")]
        if source != "WHOOP + Oura" {
            bits.append("\(elevated ?? 0) elevated, \(watching ?? 0) worth watching, \(restored ?? 0) restored")
        }
        return bits.joined(separator: ". ") + "."
    }
}
