import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 helpers shared by the Build9* test files. This file uses no new API, so it compiles today.
//
// Fixed clock for every Build9 test: `B9.base` is 2026-11-25T14:00:00Z (a Wednesday). Offsets are in seconds.

enum B9 {
    /// 2026-11-25T14:00:00Z
    static let base = Date(timeIntervalSince1970: 1_795_615_200)

    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600

    static func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    static func iso(_ seconds: TimeInterval) -> String { iso(at(seconds)) }

    /// "2026-11-25T14:00:00.000Z"
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func meeting(_ title: String, _ start: TimeInterval, _ end: TimeInterval) -> CalendarMeeting {
        guard let meeting = CalendarMeeting(title: title, start: at(start), end: at(end)) else {
            preconditionFailure("test fixture is not a valid CalendarMeeting: \(title) \(start)...\(end)")
        }
        return meeting
    }

    /// Runs `body` once for each zone with the process default time zone switched to it, then puts it back.
    /// Pure date code must not care which zone the phone or the Mac is in.
    static func inZones(_ zones: [String], _ body: (String) throws -> Void) rethrows {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for name in zones {
            guard let zone = TimeZone(identifier: name) else { XCTFail("unknown zone \(name)"); continue }
            NSTimeZone.default = zone
            try body(name)
        }
    }

    /// Zones with a DST change inside the dates the DST tests use, a half hour zone, and one east of the date line.
    static let zones = ["UTC", "America/New_York", "America/Los_Angeles", "Pacific/Auckland", "Asia/Kolkata"]

    /// 2026-11-01T05:30:00Z. 01:30 EDT in New York, and one real hour before the clocks fall back to 01:30 EST.
    static let fallBackInstant = Date(timeIntervalSince1970: 1_793_511_000)
    /// 2026-03-08T06:30:00Z. 01:30 EST in New York, 30 real minutes before the clocks jump to 03:00 EDT.
    static let springForwardInstant = Date(timeIntervalSince1970: 1_772_951_400)

    /// A fresh temp directory that is removed when the test ends.
    static func tempDirectory(_ test: XCTestCase, _ name: String) throws -> URL {
        let url = try B8.tempDirectory(name)
        test.addTeardownBlock { B8.remove(url) }
        return url
    }
}
