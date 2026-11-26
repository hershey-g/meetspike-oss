import Foundation

/// One refresh at a time, and a forced one is never lost.
///
/// A periodic request (a timer, a screen coming back) is dropped while a run is going and waits 5 minutes after the
/// last run ended. A forced request (a person just changed a meeting) always starts when idle. When it comes in while
/// a run is going it is remembered, and the run that ends starts one more at once: otherwise the run in flight could
/// end with the old answer and the change would not show.
public struct RefreshGate: Equatable, Sendable {
    public static let periodicInterval: TimeInterval = 300

    public private(set) var isRunning = false
    private var forcedWhileRunning = false
    private var lastEnded: Date?

    public init() {}

    /// True: start a run now (the gate is then running). False: do not start.
    public mutating func request(force: Bool, now: Date) -> Bool {
        if isRunning {
            if force { forcedWhileRunning = true }
            return false
        }
        if !force, let lastEnded, now.timeIntervalSince(lastEnded) <= Self.periodicInterval { return false }
        isRunning = true
        return true
    }

    /// The run ended. True: a forced request came in while it ran, so run again at once (the gate stays running for
    /// that run, call `finished` again when it ends). False: the gate is idle.
    public mutating func finished(now: Date) -> Bool {
        if forcedWhileRunning {
            forcedWhileRunning = false
            isRunning = true
            lastEnded = now
            return true
        }
        isRunning = false
        lastEnded = now
        return false
    }
}

/// Which days the listening read fetches, and when. Today every 5 minutes. Yesterday and tomorrow every 30 minutes,
/// each by its own read time (a day that was tomorrow keeps its time when it becomes today). A forced read takes all
/// three.
public struct ListeningReadSchedule: Equatable, Sendable {
    public static let todayInterval: TimeInterval = 300
    public static let neighbourInterval: TimeInterval = 1_800

    private var lastRead: [String: Date] = [:]

    public init() {}

    /// Ascending: yesterday, today, tomorrow, the ones that are due.
    public func daysToRead(today: String, now: Date, force: Bool) -> [String] {
        let days = [DayMath.addDays(today, -1), today, DayMath.addDays(today, 1)]
        return days.filter { day in
            if force { return true }
            guard let last = lastRead[day] else { return true }
            let interval = day == today ? Self.todayInterval : Self.neighbourInterval
            return now.timeIntervalSince(last) > interval
        }
    }

    /// A day was read. Call it only when the read worked, so a day that failed stays due.
    public mutating func didRead(_ day: String, at now: Date) {
        lastRead[day] = now
        // Only the few most recent days matter.
        if lastRead.count > 8 {
            let oldest = lastRead.sorted { $0.value < $1.value }.prefix(lastRead.count - 8).map(\.key)
            for key in oldest { lastRead[key] = nil }
        }
    }
}

/// The days the forced listening read after a change fetches.
public enum ListeningRefreshDays {
    /// Today in `timeZone` (the Worker's zone, never the device's) and the day each changed meeting starts on in that
    /// zone. Ascending, no repeats.
    public static func forcedDays(now: Date, timeZone: TimeZone, changedMeetingStarts: [Date]) -> [String] {
        var days: Set<String> = [DayMath.today(in: timeZone, now: now)]
        for start in changedMeetingStarts { days.insert(DayMath.today(in: timeZone, now: start)) }
        return days.sorted()
    }
}

/// What to do with one queued attendance report after the Worker answered (or did not).
public enum AttendanceReportDelivery {
    public enum Verdict: Equatable, Sendable {
        /// The Worker has it (200, or 202 when it matched no meeting).
        case done
        /// Try again soon, a few times, then give up (no answer, 5xx, 408, 425, 429).
        case retry
        /// Keep it for later and do not count it: 503 (the Worker is not ready), 401 and 403 (a rotated secret or an
        /// expired Access token) and any redirect (300 to 399: a login page, or a 301 from a host move). Fixing it later
        /// must still send the report.
        case later
        /// Any other 4xx: it can never go through.
        case drop
    }

    /// `status` is nil when there was no answer at all.
    public static func verdict(status: Int?) -> Verdict {
        guard let status else { return .retry }
        switch status {
        case 200..<300: return .done
        case 503, 401, 403, 300..<400: return .later
        case 408, 425, 429, 500..<600: return .retry
        case 400..<500: return .drop
        default: return .retry
        }
    }

    public static let maxAttempts = 5
    public static let maxAge: TimeInterval = 3 * 86_400
    /// The queue never holds more than this many reports.
    public static let queueCap = 100
    /// Waits after the first, second, third and fourth failure.
    public static let backoff: [TimeInterval] = [60, 300, 900, 3_600]
    public static let laterDelay: TimeInterval = 30 * 60
}
