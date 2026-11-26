import Foundation

/// ISO 8601 text for the override calls: UTC, a fraction of a second, ending in Z, whatever the device time zone is.
/// Reading goes through `APITime`, which takes every form the Worker sends.
enum OverrideTime {
    private final class Formatter: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: ISO8601DateFormatter

        init() {
            formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        }

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return formatter.string(from: date)
        }
    }

    private static let shared = Formatter()

    static func format(_ date: Date) -> String { shared.string(from: date) }

    /// The Date that writing `date` and reading it back gives, so a time that was sent and read again is the same
    /// value. Sub-millisecond parts are dropped (the text has milliseconds), and the result is a fixed point: writing
    /// and reading it again changes nothing.
    static func canonical(_ date: Date) -> Date {
        var current = date
        for _ in 0..<4 {
            let text = format(current)
            guard let parsed = APITime.parse(text) else { return current }
            if format(parsed) == text { return parsed }
            current = parsed
        }
        return current
    }
}
