import Foundation

// Pure logic for the Dates tab. STUBS: signatures are final, bodies are placeholders the Dates track replaces.
// Mirrors stepDates, renderPicker, pickDay and recoveryChart in public/app.js. All days are `YYYY-MM-DD`
// strings, and `today` is always the server's today (`ViewResponse.today`), never the phone's clock.

/// An inclusive span of days.
public struct DatesSpan: Equatable, Hashable, Sendable {
    public var start: String
    public var end: String
    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
    /// Inclusive count of days (1 for a single day, 0 when either day is invalid).
    public var dayCount: Int { DayMath.spanDays(start, end) }
    public var isSingleDay: Bool { start == end }
}

/// A quick pick chip in the date picker.
public struct DatesChip: Equatable, Sendable, Identifiable {
    public var label: String
    public var span: DatesSpan
    public var id: String { label }
    public init(label: String, span: DatesSpan) {
        self.label = label
        self.span = span
    }
}

/// One of the lowest next-morning recovery days, for labelling the chart.
public struct DatesLowDay: Equatable, Sendable {
    /// Position in the series (0 based).
    public var index: Int
    public var day: String
    public var value: Double
    public init(index: Int, day: String, value: Double) {
        self.index = index
        self.day = day
        self.value = value
    }
}

/// Where applying the picker should go: a single day opens Today, a span opens Dates.
public enum DatesDestination: Equatable, Sendable {
    case today(String)
    case dates(DatesSpan)
}

public enum DatesLogic {
    /// Whether a loaded answer may move the app's "today". An offline copy carries the day it was saved, which can
    /// be older than the real today, so only a live answer counts.
    public static func shouldNoteToday(isFromCache: Bool) -> Bool { !isFromCache }

    /// A short label for logs: the error case, plus the HTTP status for a Worker error. Never the Worker's message,
    /// a decoding path, or anything that could carry dates or other data.
    public static func logCode(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return "unknown" }
        switch apiError {
        case .accessRejected: return "accessRejected"
        case .http(let status, _): return "http \(status)"
        case .offline: return "offline"
        case .decoding: return "decoding"
        case .invalidRequest: return "invalidRequest"
        case .notConfigured: return "notConfigured"
        }
    }

    /// Moves a span one full span back (`direction < 0`) or forward (`direction > 0`). Going forward never passes
    /// `today`: when the end would, it clamps to `today` and the start keeps the same day count.
    /// Example: Nov 10 to Nov 16, forward, today Nov 18 gives Nov 12 to Nov 18.
    public static func shift(_ span: DatesSpan, direction: Int, today: String) -> DatesSpan {
        let count = span.dayCount
        guard count > 0, direction != 0 else { return span }
        let sign = direction < 0 ? -1 : 1
        var start = DayMath.addDays(span.start, sign * count)
        var end = DayMath.addDays(span.end, sign * count)
        if sign > 0, end > today {
            end = today
            start = DayMath.addDays(end, -(count - 1))
        }
        return DatesSpan(start: start, end: end)
    }

    /// The next-span button is enabled only while the span ends before `today`.
    public static func canGoNext(_ span: DatesSpan, today: String) -> Bool {
        span.end < today
    }

    /// Picker chips in order: Today, Yesterday, Last 7 days, Last 30 days, This month (month to date, never
    /// future days), Last month (whole previous calendar month).
    public static func quickChips(today: String) -> [DatesChip] {
        let yesterday = DayMath.addDays(today, -1)
        let thisMonth = String(today.prefix(7))
        let lastMonth = DayMath.shiftMonth(thisMonth, -1)
        return [
            DatesChip(label: "Today", span: DatesSpan(start: today, end: today)),
            DatesChip(label: "Yesterday", span: DatesSpan(start: yesterday, end: yesterday)),
            DatesChip(label: "Last 7 days", span: DatesSpan(start: DayMath.addDays(today, -6), end: today)),
            DatesChip(label: "Last 30 days", span: DatesSpan(start: DayMath.addDays(today, -29), end: today)),
            DatesChip(label: "This month", span: DatesSpan(start: "\(thisMonth)-01", end: today)),
            DatesChip(label: "Last month", span: DatesSpan(start: "\(lastMonth)-01", end: DayMath.lastDay(ofMonth: lastMonth))),
        ]
    }

    /// The `limit` (default 3) lowest next-morning recovery days among days that have one, lowest first.
    /// Ties keep the earlier day first. Days with nil `nextRecovery` are skipped.
    public static func lowestRecoveryDays(_ series: [SeriesDay], limit: Int = 3) -> [DatesLowDay] {
        guard limit > 0 else { return [] }
        let scored = series.enumerated().compactMap { index, day -> DatesLowDay? in
            day.nextRecovery.map { DatesLowDay(index: index, day: day.day, value: $0) }
        }
        let sorted = scored.sorted { a, b in a.value != b.value ? a.value < b.value : a.index < b.index }
        return Array(sorted.prefix(limit))
    }

    /// Apply button target: one day goes to Today, a span to Dates.
    public static func destination(for span: DatesSpan) -> DatesDestination {
        span.isSingleDay ? .today(span.start) : .dates(span)
    }
}

/// The range picker's state and its tap rules.
public struct DatesPicker: Equatable, Sendable {
    public enum Field: Sendable, Equatable { case start, end }

    /// `YYYY-MM` being shown.
    public var month: String
    public var start: String?
    public var end: String?
    /// Which field the next tap edits, or nil for "start a new pick".
    public var editing: Field?

    /// Opens on the current selection, showing the month of its end.
    public init(start: String?, end: String?, today: String) {
        self.start = start
        self.end = end
        self.month = String((end ?? today).prefix(7))
        self.editing = nil
    }

    /// Both ends chosen.
    public var span: DatesSpan? {
        guard let start, let end else { return nil }
        return DatesSpan(start: start, end: end)
    }

    /// Tap a day (`pickDay` in app.js). While editing the end with a start set: before the start swaps the two,
    /// otherwise sets the end. While editing the start with an end set and the day not after it: sets the start.
    /// Anything else starts over: start = day, end cleared, now editing the end.
    public mutating func pick(_ day: String) {
        if editing == .end, let current = start {
            if day < current {
                end = current
                start = day
            } else {
                end = day
            }
            editing = nil
        } else if editing == .start, let current = end, day <= current {
            start = day
            editing = nil
        } else {
            start = day
            end = nil
            editing = .end
        }
    }

    /// Tap the From or To field. Ignored for To until a start exists. Moves the shown month to that field's day.
    public mutating func select(_ field: Field) {
        if field == .end, start == nil { return }
        editing = field
        let day = field == .start ? start : (end ?? start)
        if let day { month = String(day.prefix(7)) }
    }

    /// Clear both ends and stop editing.
    public mutating func clear() {
        start = nil
        end = nil
        editing = nil
    }

    /// Move the shown month by n months, never past `today`'s month.
    public mutating func moveMonth(_ n: Int, today: String) {
        let limit = String(today.prefix(7))
        let moved = DayMath.shiftMonth(month, n)
        month = moved > limit ? limit : moved
    }

    /// Choose a chip: both ends set at once, month moves to its end.
    public mutating func choose(_ chip: DatesChip) {
        start = chip.span.start
        end = chip.span.end
        editing = nil
        month = String(chip.span.end.prefix(7))
    }
}
