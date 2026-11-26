import Foundation

/// ISO 8601 UTC text with exactly three millisecond digits, "2026-11-25T05:00:00.125Z". Done by hand with
/// integer math so it is cheap (a crumb is stamped on every add), thread safe, and the same on every platform.
enum DiagnosticTime {
    static func format(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e14 else { return "1970-01-01T00:00:00.000Z" }
        let totalMs = Int64((seconds * 1000).rounded())
        var days = totalMs / 86_400_000
        var msOfDay = totalMs % 86_400_000
        if msOfDay < 0 { msOfDay += 86_400_000; days -= 1 }
        let (year, month, day) = civil(fromDays: days)
        let hour = msOfDay / 3_600_000
        let minute = (msOfDay / 60_000) % 60
        let second = (msOfDay / 1000) % 60
        let ms = msOfDay % 1000
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(ms, 3))Z"
    }

    /// Reads "YYYY-MM-DDTHH:MM:SSZ" and "YYYY-MM-DDTHH:MM:SS.fffZ" (one to nine fraction digits). Anything else is nil.
    static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z") else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            guard start + length <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<start + length] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year),
              hour < 24, minute < 60, second < 60 else { return nil }
        var fraction = 0.0
        if bytes.count != 20 {
            guard bytes[19] == 46, bytes.count >= 22, bytes.count <= 30 else { return nil }
            var scale = 0.1
            for byte in bytes[20..<bytes.count - 1] {
                guard (48...57).contains(byte) else { return nil }
                fraction += Double(byte - 48) * scale
                scale /= 10
            }
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let whole = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)
        // Round to the millisecond so the value is the same Date the text was made from.
        let ms = ((whole + fraction) * 1000).rounded() / 1000
        return Date(timeIntervalSince1970: ms)
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Howard Hinnant's civil date algorithms.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = Int64((month + 9) % 12)
        let doy = (153 * mp + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
