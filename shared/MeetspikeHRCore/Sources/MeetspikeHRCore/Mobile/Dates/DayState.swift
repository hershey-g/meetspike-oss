import Foundation

/// The app's shared date state: the server's today, the day Today shows, and the span Dates shows.
/// `noting(_:isFromCache:)` is the one place that decides how a new server day moves them, so no screen can
/// forget the offline rule.
public struct DayState: Equatable, Sendable {
    public var today: String
    public var selectedDay: String
    public var span: DatesSpan

    public init(today: String, selectedDay: String, span: DatesSpan) {
        self.today = today
        self.selectedDay = selectedDay
        self.span = span
    }

    /// The state after the server says today is `day`.
    ///
    /// - An offline copy carries the day it was saved, which may be old, so it never changes anything.
    /// - An invalid day or the same day changes nothing.
    /// - A later day (the overnight roll): the selected day and the span follow when they were on the old today
    ///   (the span keeps its length). A chosen past day or span stays put.
    /// - An earlier fresh day (for example a time zone change): `today` moves back and anything later than it is
    ///   clamped, so nothing points at the future.
    public func noting(_ day: String, isFromCache: Bool) -> DayState {
        guard !isFromCache, DayMath.isValid(day), day != today else { return self }
        var next = self
        if day > today {
            if selectedDay == today { next.selectedDay = day }
            if span.end == today {
                let count = max(1, span.dayCount)
                next.span = DatesSpan(start: DayMath.addDays(day, -(count - 1)), end: day)
            }
        }
        next.today = day
        if next.selectedDay > day { next.selectedDay = day }
        if next.span.end > day {
            let count = max(1, next.span.dayCount)
            next.span = DatesSpan(start: DayMath.addDays(day, -(count - 1)), end: day)
        }
        return next
    }
}
