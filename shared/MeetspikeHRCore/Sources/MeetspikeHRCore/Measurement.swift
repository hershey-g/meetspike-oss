import Foundation

public enum HeartRateMeasurement {
    public static func bpm(from data: Data) -> Int? {
        var bytes = data.makeIterator()
        guard let flags = bytes.next(), let low = bytes.next() else { return nil }
        var bpm = Int(low)
        if flags & 1 != 0 {
            guard let high = bytes.next() else { return nil }
            bpm |= Int(high) << 8
        }
        if flags & 0x08 != 0 {
            guard bytes.next() != nil, bytes.next() != nil else { return nil }
        }
        if flags & 0x10 != 0 {
            guard bytes.next() != nil, bytes.next() != nil else { return nil }
            while bytes.next() != nil {
                guard bytes.next() != nil else { return nil }
            }
        }
        // Some devices leave contact detection unsupported (bit 2 clear).
        if flags & 0x06 == 0x04 { return nil }
        return bpm
    }
}

public extension Date {
    var unixMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded(.down)) }
}
