import Foundation

// Pure copy and chart math for the Dates tab, ported from renderDates, recoveryChart and hoursChart in
// public/app.js. No UI here, so it stays testable and the SwiftUI screen only lays things out.

/// Plain-text formatting shared by the Dates screen and the date picker.
public enum DatesFormat {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let longMonths = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let longWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let narrowWeekdays = ["S", "M", "T", "W", "T", "F", "S"]

    private static func parts(_ day: String) -> (year: Int, month: Int, day: Int)? {
        guard DayMath.isValid(day) else { return nil }
        let p = day.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return (y, m, d)
    }

    /// 0 = Sunday ... 6 = Saturday.
    public static func weekdayIndex(_ day: String) -> Int? {
        guard let date = DayMath.date(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.weekday, from: date) - 1
    }

    /// "Tue, Nov 17".
    public static func weekdayDay(_ day: String) -> String {
        guard let p = parts(day), let w = weekdayIndex(day) else { return day }
        return "\(weekdays[w]), \(months[p.month - 1]) \(p.day)"
    }

    /// "Tuesday, November 17" for spoken labels.
    public static func longDay(_ day: String) -> String {
        guard let p = parts(day), let w = weekdayIndex(day) else { return day }
        return "\(longWeekdays[w]), \(longMonths[p.month - 1]) \(p.day)"
    }

    /// "Nov 17", or "Nov 17, 2025" when the year is not `today`'s year.
    public static func shortDay(_ day: String, today: String) -> String {
        guard let p = parts(day) else { return day }
        let base = "\(months[p.month - 1]) \(p.day)"
        return today.prefix(4) == day.prefix(4) ? base : "\(base), \(p.year)"
    }

    /// "Nov 12 – Nov 18", or one day.
    public static func rangeLabel(_ start: String, _ end: String, today: String) -> String {
        start == end ? shortDay(start, today: today) : "\(shortDay(start, today: today)) – \(shortDay(end, today: today))"
    }

    /// "November 2026" for a `YYYY-MM` month.
    public static func monthTitle(_ month: String) -> String {
        let p = month.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return month }
        return "\(longMonths[m - 1]) \(y)"
    }

    /// "M", "T" ... for the hours chart axis.
    public static func narrowWeekday(_ day: String) -> String {
        weekdayIndex(day).map { narrowWeekdays[$0] } ?? ""
    }

    /// Day of the month as a number string ("5").
    public static func dayNumber(_ day: String) -> String {
        parts(day).map { String($0.day) } ?? ""
    }

    public static func plural(_ n: Int, _ word: String, many: String? = nil) -> String {
        "\(n) \(n == 1 ? word : (many ?? "\(word)s"))"
    }

    /// Number as the web prints it: whole numbers without a decimal, otherwise up to two places.
    public static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Whole percent, rounded half up ("72").
    public static func percent(_ value: Double) -> String { String(Int(value.rounded())) }

    /// "5.3 h" (one decimal, none when whole).
    public static func hoursText(seconds: Int) -> String {
        let h = (Double(seconds) / 3600 * 10).rounded() / 10
        return "\(number(h)) h"
    }

    /// Initials for an avatar: two letters of the name, or of the email's local part.
    public static func initials(name: String?, email: String?) -> String {
        let source = (name.flatMap { $0.isEmpty ? nil : $0 } ?? email.flatMap { $0.isEmpty ? nil : $0 } ?? "?")
        let local = source.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? source
        let words = local.components(separatedBy: CharacterSet(charactersIn: " ._-")).filter { !$0.isEmpty }
        let first = words.first?.first.map(String.init) ?? "?"
        let second = words.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }
}

/// Headline, lead and stat tiles for a range view.
public enum DatesCopy {
    public struct Stat: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The card headline and its lead sentence (lead is empty when there is nothing to add).
    public static func headline(_ view: ViewResponse) -> (headline: String, lead: String) {
        let wearable = view.wearable
        let label = wearable?.scoreLabel ?? ""
        let summary = view.range?.summary
        if let e = view.effect, let cost = e.cost, (e.heavy?.days ?? 0) >= 1, (e.lighter?.days ?? 0) >= 1 {
            let heavyDays = e.heavy?.days ?? 0
            let lighterDays = e.lighter?.days ?? 0
            let headline: String
            if cost >= 3 {
                let who = heavyDays == 1 ? "heavy day" : "\(heavyDays) heavy days"
                headline = "Your \(who) cost you \(DatesFormat.number(cost)) points of \(label)."
            } else if cost <= -3 {
                headline = "You recovered better after heavy days here, by \(DatesFormat.number(-cost)) points."
            } else {
                headline = "Heavy days barely moved your \(label) here."
            }
            let hours = e.heavyHours.map(DatesFormat.number) ?? "?"
            let meetings = e.heavyMeetings.map(DatesFormat.number) ?? "?"
            let heavyAvg = e.heavy?.nextRecovery.map(DatesFormat.number) ?? "n/a"
            let lighterAvg = e.lighter?.nextRecovery.map(DatesFormat.number) ?? "n/a"
            var lead = "After \(hours)+ hours or \(meetings)+ meetings, the next morning averaged \(heavyAvg)% \(label). After lighter days it averaged \(lighterAvg)%."
            if heavyDays < 3 || lighterDays < 3 { lead += " Only a few days, so treat this as a hint." }
            return (headline, lead)
        }
        if let summary, let meetingCount = summary.meetingCount, meetingCount > 0 {
            let headline = "\(DatesFormat.plural(meetingCount, "meeting")) across \(DatesFormat.plural(summary.daysWithMeetings ?? 0, "day"))."
            var lead = ""
            if let source = wearable?.source, !source.isEmpty {
                lead = (view.range?.recovery?.nReadiness ?? 0) > 0
                    ? "No heavy days to compare in this range."
                    : "No \(wearable?.label ?? "wearable") scores in this range yet."
            }
            return (headline, lead)
        }
        return ("No meetings in this range.", "")
    }

    /// Stat tiles: Meetings, After 6 pm, one Avg per wearable score, then Avg sleep.
    public static func stats(_ view: ViewResponse) -> [Stat] {
        let summary = view.range?.summary
        var stats = [
            Stat(label: "Meetings", value: "\(summary?.meetingCount ?? 0) · \(DatesFormat.hoursText(seconds: summary?.totalDurationS ?? 0))"),
            Stat(label: "After 6 pm", value: String(summary?.afterHoursCount ?? 0)),
        ]
        for score in view.morningScores {
            let value: String
            if let average = score.average {
                let usual = score.usual?.recovery.map { " · usual \(DatesFormat.number($0))%" } ?? ""
                value = "\(DatesFormat.percent(average))%\(usual)"
            } else {
                value = "n/a"
            }
            stats.append(Stat(label: "Avg \(score.scoreLabel)", value: value))
        }
        if let wearable = view.wearable, let source = wearable.source, !source.isEmpty {
            let sleep = view.range?.recovery?.avgSleepScore.map { "\(DatesFormat.percent($0))%" } ?? "n/a"
            stats.append(Stat(label: "Avg sleep (\(wearable.label ?? ""))", value: sleep))
        }
        return stats
    }

    /// Second line of a "days that cost you" row.
    public static func costlySubtitle(_ day: CostlyDay) -> String {
        var text = "\(DatesFormat.plural(day.meetingCount ?? 0, "meeting")) · \(DatesFormat.number(day.meetingHours ?? 0)) h"
        if let after = day.afterHours, after > 0 { text += " · \(after) after 6 pm" }
        return text
    }

    /// Second line of a "people on your heaviest days" row.
    public static func personSubtitle(_ person: HeavyDayPerson) -> String {
        "On \(DatesFormat.plural(person.heavyDays ?? 0, "heavy day")) · \(DatesFormat.plural(person.meetings ?? 0, "meeting"))"
    }

    /// The first sentence of a hit that says something the pill does not.
    public static func shortSentence(_ hit: InsightHit) -> String {
        let sentences = splitSentences(hit.sentence ?? "")
        var head = hit.hrStress?.headline ?? ""
        if head.hasSuffix(".") { head.removeLast() }
        let first = sentences.first { sentence in
            var trimmed = sentence
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
            return trimmed != head
        } ?? ""
        return first.replacingOccurrences(of: " beats per minute", with: " bpm")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if chars[i] == ".", i + 1 < chars.count, chars[i + 1].isWhitespace {
                result.append(current)
                current = ""
                while i + 1 < chars.count, chars[i + 1].isWhitespace { i += 1 }
            }
            i += 1
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.isEmpty }
    }

    /// Hits worth listing: meeting hits only (whole-day hits are skipped), at most five.
    public static func meetingHits(_ hits: [InsightHit]?) -> [InsightHit] {
        Array((hits ?? []).filter { $0.kind != "day" }.prefix(5))
    }
}

/// One scored day on the recovery line.
public struct DatesChartPoint: Equatable, Sendable, Identifiable {
    public var index: Int
    public var day: String
    public var value: Double
    public var id: Int { index }
    public init(index: Int, day: String, value: Double) {
        self.index = index
        self.day = day
        self.value = value
    }
}

public enum DatesChartMath {
    /// Runs of consecutive scored days. A day without a score ends the run, so the line breaks there.
    public static func segments(_ series: [SeriesDay]) -> [[DatesChartPoint]] {
        var runs: [[DatesChartPoint]] = []
        var current: [DatesChartPoint] = []
        for (index, day) in series.enumerated() {
            if let value = day.nextRecovery {
                current.append(DatesChartPoint(index: index, day: day.day, value: value))
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Show a day label on every Nth bar: every day up to 14 days, every 3rd up to 31, else weekly.
    public static func labelEvery(count: Int) -> Int {
        count <= 14 ? 1 : count <= 31 ? 3 : 7
    }

    /// Top of the hours chart: at least 6, or the busiest day.
    public static func hoursMax(_ series: [SeriesDay]) -> Double {
        max(6, series.compactMap(\.meetingHours).max() ?? 0)
    }

    /// Bar width in points, as the web draws it (60 percent of the slot, 2 to 16).
    public static func barWidth(count: Int, width: Double = 358) -> Double {
        guard count > 0 else { return 2 }
        let step = (width - 26 - 4) / Double(count)
        return max(2, min(16, step * 0.6))
    }

    /// Days that get an axis label.
    public static func labelledDays(_ series: [SeriesDay]) -> [String] {
        let every = labelEvery(count: series.count)
        return series.enumerated().compactMap { index, day in index % every == 0 ? day.day : nil }
    }

    /// Marker diameter in points: smaller beyond a month.
    public static func markerSize(count: Int) -> Double { count > 31 ? 5 : 8 }
}

/// Month grid for the date picker.
public enum DatesCalendar {
    /// Cells for a `YYYY-MM` month, Monday first: nil for leading blanks, then each `YYYY-MM-DD`.
    public static func cells(month: String) -> [String?] {
        let first = "\(month)-01"
        guard let weekday = DatesFormat.weekdayIndex(first) else { return [] }
        let offset = (weekday + 6) % 7
        let last = DayMath.lastDay(ofMonth: month)
        guard let count = Int(last.suffix(2)) else { return [] }
        let days: [String?] = (1...count).map { "\(month)-" + String(format: "%02d", $0) }
        return Array<String?>(repeating: nil, count: offset) + days
    }

    /// The note under the grid.
    public static func note(_ picker: DatesPicker, today: String) -> String {
        guard let start = picker.start else { return "Tap a start day, then an end day." }
        guard let end = picker.end else { return "Now tap the end day." }
        return "\(DatesFormat.rangeLabel(start, end, today: today)) · \(DatesFormat.plural(DayMath.spanDays(start, end), "day"))"
    }

    /// The apply button's title.
    public static func applyTitle(_ picker: DatesPicker, today: String) -> String {
        guard let span = picker.span else { return "Pick an end date" }
        return span.isSingleDay
            ? "Show \(DatesFormat.shortDay(span.start, today: today))"
            : "Show \(DatesFormat.plural(span.dayCount, "day"))"
    }
}
