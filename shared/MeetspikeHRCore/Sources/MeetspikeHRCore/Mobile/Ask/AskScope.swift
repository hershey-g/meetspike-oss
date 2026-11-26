import Foundation

// Pieces of the Ask tab that are not the chat itself: the three suggestions, the date scope a chat is asked over,
// the "Thought for 6s" label, and the saved copy of a chat. Ported from public/ask-logic.js and public/ask-panel.js.

public enum AskCopy {
    /// The starter questions.
    public static let suggestions = [
        "Which meetings cost me the most this month?",
        "Which meetings cost me the most, all time?",
        "Is it the number of hours or the people?",
        "How do days with after-hours calls compare?",
    ]

    /// Playful words shown while waiting, one every `verbMilliseconds`.
    public static let verbs = ["Tinkering", "Pulling your calendar", "Counting heartbeats", "Lining up the nights", "Cross-checking", "Mulling it over"]
    public static let verbMilliseconds = 1800

    public static func verb(atMilliseconds ms: Int) -> String {
        verbs[(max(0, ms) / verbMilliseconds) % verbs.count]
    }

    /// The line under an answer: what it ranked, and what it was compared with. "Ranking Nov 1 to Nov 25, compared
    /// with all history", or "Using all history, Jan 3 to Nov 25" when the ranked dates cover all of it.
    /// Day text sorts the same as dates, so plain string comparison is enough. `today` is the day the phone calls
    /// today; a ranked range that runs to it or past it still covers the end of the baseline.
    public static func rangeLine(_ range: AskRange, today: String) -> String {
        if range.coversAllHistory(today: today) {
            return "Using all history, \(AskScope.label(start: range.baselineStart, end: range.baselineEnd))"
        }
        return "Ranking \(AskScope.label(start: range.start, end: range.end)), compared with all history"
    }

    /// "Thought for 6s" / "Stopped after 3s".
    public static func thoughtLabel(seconds: Double, stoppedEarly: Bool) -> String {
        let s = max(1, Int(seconds.rounded()))
        return stoppedEarly ? "Stopped after \(s)s" : "Thought for \(s)s"
    }
}

/// The date range a chat is asked over. A copy taken when the chat opens, so the header and every request agree.
public struct AskScope: Equatable, Hashable, Codable, Sendable {
    public var start: String
    public var end: String
    public var label: String

    /// Nil unless both ends are real days, so the header never shows a range that is not sent.
    public init?(start: String?, end: String?, label: String? = nil) {
        guard let start, let end, DayMath.isValid(start), DayMath.isValid(end) else { return nil }
        self.start = start
        self.end = end
        self.label = label ?? AskScope.label(start: start, end: end)
    }

    /// "Oct 1 to Oct 14", "Nov 24", or with the year when the ends are in different years.
    public static func label(start: String, end: String) -> String {
        func part(_ day: String, year: Bool) -> String {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let pieces = day.split(separator: "-")
            guard pieces.count == 3, let month = Int(pieces[1]), let d = Int(pieces[2]), (1...12).contains(month) else { return day }
            return "\(months[month - 1]) \(d)" + (year ? ", \(pieces[0])" : "")
        }
        if start == end { return part(start, year: false) }
        let crossesYear = start.prefix(4) != end.prefix(4)
        return "\(part(start, year: crossesYear)) to \(part(end, year: crossesYear))"
    }

    /// Header text. All time ranks every day. A scope ranks its dates and compares with all history. With neither,
    /// Ask already uses all history.
    public static func headerText(_ scope: AskScope?, allTime: Bool) -> String {
        if allTime { return "Ranking all history" }
        if let scope { return "Ranking \(scope.label), compared with all history" }
        return "Using all history"
    }
}

/// What the phone keeps of a chat between launches. Restored only when `sourceDisplay` equals the current one
/// (ask-panel.js loadChat), because answers were built from the other source's scores.
public struct AskSavedChat: Codable, Equatable, Sendable {
    public var sourceDisplay: SourceDisplay
    public var turns: [AskTurn]

    public init(sourceDisplay: SourceDisplay, turns: [AskTurn]) {
        self.sourceDisplay = sourceDisplay
        self.turns = AskHistory.stored(turns)
    }

    /// The turns to restore for the current setting, else none.
    public func turns(for current: SourceDisplay) -> [AskTurn] {
        sourceDisplay == current ? turns : []
    }
}
