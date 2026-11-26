import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 7, track `app`: the freeze fix. A 4.5 h meeting returned 33,135 HR points and the main thread sat at 100% CPU
// for minutes (a new ISO8601DateFormatter per point, three passes, rerun on every redraw), and the live chart redraws
// about 4,800 points every poll.
//
// Names the builder must provide (a missing type stops this whole test target compiling, so these are fixed here):
//
//   APITime.parse(_:)                                  fast path, same results as before, 40,000 parses < 1 s
//   MeetingChartModel(detail:maxPoints:)               public, Sendable, Equatable, maxPoints defaults to 400
//     .sourceLabel: String                             == TodayLogic.hrProviderLabel(detail.hrStress)
//     .segments: [MeetingChartSegment]                 .provider: String, .points: [MeetingChartPoint]
//     .from, .to: Date    .meetingStart, .meetingEnd: Date?    .low, .high: Double    .band: ClosedRange<Double>?
//     .stress: [MeetingChartStressPoint]               .date: Date, .level: Double
//     .minBpm, .maxBpm: Double?                        the spoken min and max, nil for an empty series
//   MeetingChartPoint(date: Date, bpm: Double)         public memberwise init, Equatable, Sendable
//   MeetingDetailState<Value>                          see Build7SpeedTestsDetailState
//   TodayLogic.liveChart                               same signature, downsampled `segments`
//
// Where a test is already green today it is a guard (parity with today's behaviour), and it says so.

// MARK: Shared helpers

/// 2026-11-24T14:00:00Z, so a test can use small negative offsets from a meeting that starts at `hour`.
private let epoch0 = 1_795_528_800.0
private let hour = 3_600_000

/// "2026-11-24T14:00:00.000Z" plus `offsetMs` (under 10 hours).
private func iso(_ offsetMs: Int) -> String {
    let total = offsetMs / 1000
    return String(format: "2026-11-24T%02d:%02d:%02d.%03dZ", 14 + total / 3600, (total % 3600) / 60, total % 60, offsetMs % 1000)
}

private func date(_ offsetMs: Int) -> Date { Date(timeIntervalSince1970: epoch0 + Double(offsetMs) / 1000) }

private struct SamplePoint {
    var ms: Int
    var bpm: Double
    var source: String?
}

/// Builds a MeetingHRDetail the way the app does, by decoding Worker-shaped JSON.
private func detail(
    points: [SamplePoint], label: String? = "WHOOP", window: (Int, Int, Int?, Int?)? = nil,
    baseline: (Double, Double)? = nil, stress: [(Int, Double)] = []
) throws -> MeetingHRDetail {
    var parts: [String] = ["\"ok\":true", "\"enabled\":true"]
    if let label { parts.append("\"hrStress\":{\"coverage\":\"ok\",\"source\":\"\(label)\"}") }
    if let window {
        var w = "\"startUtc\":\"\(iso(window.0))\",\"endUtc\":\"\(iso(window.1))\""
        if let fetchStart = window.2 { w += ",\"fetchStartUtc\":\"\(iso(fetchStart))\"" }
        if let fetchEnd = window.3 { w += ",\"fetchEndUtc\":\"\(iso(fetchEnd))\"" }
        parts.append("\"window\":{\(w)}")
    }
    let rows = points.map { point -> String in
        let source = point.source.map { ",\"source\":\"\($0)\"" } ?? ""
        return "{\"t\":\"\(iso(point.ms))\",\"bpm\":\(point.bpm)\(source)}"
    }
    parts.append("\"series\":[\(rows.joined(separator: ","))]")
    if let baseline { parts.append("\"baseline\":{\"lowBpm\":\(baseline.0),\"highBpm\":\(baseline.1),\"meanBpm\":70}") }
    if !stress.isEmpty {
        let rows = stress.map { "{\"t\":\"\(iso($0.0))\",\"level\":\($0.1)}" }
        parts.append("\"stress\":{\"points\":[\(rows.joined(separator: ","))],\"peakLevel\":\(stress.map(\.1).max() ?? 0)}")
    }
    return try MobileJSON.decode(MeetingHRDetail.self, "{" + parts.joined(separator: ",") + "}")
}

/// A believable heart rate: a slow wave between 62 and 78, a spike every 500 points (100 to 139) and a dip 250 points
/// later (46 to 55). Every spike is the highest point within 249 points either side, every dip the lowest, so a
/// downsampler that keeps each bucket's min and max (buckets under 500 points) keeps all of them.
private func bpm(at index: Int, spikeAt: Int? = nil, dipAt: Int? = nil) -> Double {
    if index == spikeAt { return 190 }
    if index == dipAt { return 41 }
    if index % 500 == 250 { return Double(100 + (index / 500) % 40) }
    if index > 0 && index % 500 == 0 { return Double(55 - (index / 500) % 10) }
    return ((70 + 8 * sin(Double(index) / 200)) * 10).rounded() / 10
}

private func key(_ date: Date) -> Int { Int(((date.timeIntervalSince1970 - epoch0) * 1000).rounded()) }

private func requireSendable<T: Sendable>(_ value: T) -> T { value }

// MARK: 1. APITime

/// The code APITime.parse has today, kept here as the oracle.
private func referenceParse(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

final class Build7SpeedTestsAPITime: XCTestCase {
    private func assertParity(_ input: String?, file: StaticString = #filePath, line: UInt = #line) {
        let expected = referenceParse(input)
        let actual = APITime.parse(input)
        switch (expected, actual) {
        case (nil, nil): break
        case let (expected?, actual?):
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001,
                           "\(input ?? "nil")", file: file, line: line)
        case (nil, _?): XCTFail("\(input ?? "nil") parsed but the formatter rejects it", file: file, line: line)
        case (_?, nil): XCTFail("\(input ?? "nil") rejected but the formatter accepts it", file: file, line: line)
        }
    }

    // Anchors that do not depend on the oracle. Green today.
    func testKnownValues() throws {
        XCTAssertEqual(try XCTUnwrap(APITime.parse("1970-01-01T00:00:00Z")).timeIntervalSince1970, 0, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("1999-12-31T23:59:59Z")).timeIntervalSince1970, 946_684_799, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2000-02-29T12:00:00Z")).timeIntervalSince1970, 951_825_600, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2024-02-29T00:00:00Z")).timeIntervalSince1970, 1_709_164_800, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2026-11-24T15:00:00Z")).timeIntervalSince1970, 1_795_532_400, accuracy: 0.0005)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2026-11-24T15:00:00.250Z")).timeIntervalSince1970, 1_795_532_400.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2100-03-01T00:00:00Z")).timeIntervalSince1970, 4_107_542_400, accuracy: 0.0005)
    }

    func testOffsetsShiftTheInstant() throws {
        let utc = try XCTUnwrap(APITime.parse("2026-11-24T15:00:00Z")).timeIntervalSince1970
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2026-11-24T20:30:00+05:30")).timeIntervalSince1970, utc, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2026-11-24T07:00:00-08:00")).timeIntervalSince1970, utc, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2026-11-24T15:00:00+00:00")).timeIntervalSince1970, utc, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2026-11-24T15:00:00.500+00:00")).timeIntervalSince1970, utc + 0.5, accuracy: 0.001)
        // An offset can move the instant across a day, a month and a year.
        XCTAssertEqual(try XCTUnwrap(APITime.parse("2027-01-01T01:00:00+02:00")).timeIntervalSince1970,
                       try XCTUnwrap(APITime.parse("2026-12-31T23:00:00Z")).timeIntervalSince1970, accuracy: 0.001)
    }

    func testFractionsOfOneToNineDigits() throws {
        let whole = try XCTUnwrap(APITime.parse("2026-11-24T15:00:00Z")).timeIntervalSince1970
        for digits in 1...9 {
            let fraction = String(repeating: "5", count: digits)
            let text = "2026-11-24T15:00:00.\(fraction)Z"
            let parsed = try XCTUnwrap(APITime.parse(text), text).timeIntervalSince1970
            XCTAssertEqual(parsed, whole + Double("0.\(fraction)")!, accuracy: 0.001, text)
            assertParity(text)
            assertParity("2026-11-24T15:00:00.\(fraction)+05:30")
            assertParity("2026-11-24T15:00:00.\(fraction)-08:00")
        }
    }

    /// The table of everything the Worker sends plus everything it should never send. Each row must give what the old
    /// formatter code gave: a date within 1 ms, or nil. Green today (the code under test is the oracle); red if a
    /// fast path accepts or rejects something differently.
    func testParityTable() {
        let valid = [
            "2026-11-24T15:00:00Z", "2026-11-24T15:00:00.000Z", "2026-11-24T15:00:00.5Z", "2026-11-24T15:00:00.123456Z",
            "2026-11-24T15:00:00+05:30", "2026-11-24T15:00:00-08:00", "2026-11-24T15:00:00+00:00", "2026-11-24T15:00:00-00:00",
            "2026-11-24T15:00:00+14:00", "2026-11-24T15:00:00-12:00", "2026-11-24T15:00:00.007+01:00",
            "2024-02-29T00:00:00Z", "2000-02-29T12:00:00Z", "2024-02-29T23:59:59.999Z", "2024-12-31T23:59:59Z",
            "2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z", "1970-01-01T00:00:00Z", "1969-12-31T23:59:59Z",
            "1900-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "2026-03-08T02:30:00Z",
            "2026-11-01T01:30:00-04:00", "2026-11-01T01:30:00-05:00",
        ]
        let nonsense = [
            "2026-02-30T10:00:00Z", "2026-02-29T10:00:00Z", "2023-02-29T00:00:00Z", "2100-02-29T00:00:00Z",
            "1900-02-29T00:00:00Z", "2026-04-31T10:00:00Z", "2026-06-31T10:00:00Z", "2026-13-01T10:00:00Z",
            "2026-00-10T10:00:00Z", "2026-11-00T10:00:00Z", "2026-11-32T10:00:00Z", "2026-11-24T25:00:00Z",
            "2026-11-24T24:00:00Z", "2026-11-24T24:00:01Z", "2026-11-24T23:60:00Z", "2026-11-24T23:59:60Z",
            "2026-11-24T23:59:61Z", "2026-11-24T15:00:00+25:00", "2026-11-24T15:00:00+05:60", "2026-11-24T15:00:00+99:99",
        ]
        let shapes = [
            "2026-11-24T15:00:00", "2026-11-24T15:00:00.123", "2026-11-24T15:00Z", "2026-11-24T15Z", "2026-11-24",
            "2026-11-24T", "2026-11-24Z", "2026-11-24 15:00:00Z", "2026-11-24T15:00:00 Z", "2026-11-24T15:00:00 +05:30",
            " 2026-11-24T15:00:00Z", "2026-11-24T15:00:00Z ", "\n2026-11-24T15:00:00Z", "2026-11-24T15:00:00Z\n",
            "2026-11-24T15:00:00Zjunk", "2026-11-24T15:00:00ZZ", "2026-11-24T15:00:00.Z", "2026-11-24T15:00:00,5Z",
            "2026-11-24T15:00:00.5", "2026-11-24T15:00:00.5.5Z", "2026-11-24T15:00:00+5:30", "2026-11-24T15:00:00+0530",
            "2026-11-24T15:00:00+05", "2026-11-24T15:00:00+05:3", "2026-11-24T15:00:00+05:30:00", "2026-11-24T15:00:00 05:30",
            "2026-11-24T15:00:00.1234567890Z", "2026-11-24T15:00:00.123456789012345Z", "20261124T150000Z",
            "2026-11-24T15:00:00z", "2026-11-24t15:00:00Z", "2026-11-24t15:00:00z", "2026-1-24T15:00:00Z", "2026-11-4T15:00:00Z",
            "2026-11-24T5:00:00Z", "2026-11-24T15:0:00Z", "2026-11-24T15:00:0Z", "26-11-24T15:00:00Z", "02026-11-24T15:00:00Z",
            "-2026-11-24T15:00:00Z", "+2026-11-24T15:00:00Z", "2026/11/24T15:00:00Z", "2026-11-24T15-00-00Z", "2026-W48-2T15:00:00Z",
            "2026-328T15:00:00Z", "2026-11-24T15:00:00-", "2026-11-24T15:00:00+", "2026-11-24T15:00:00Z+01:00",
        ]
        let garbage = [
            "", " ", "garbage", "null", "nil", "undefined", "NaN", "0", "1795532400", "1795532400000", "now", "Z", "T", "-",
            "2026", "2026-11", "15:00:00", "15:00:00Z", "Tue, 24 Nov 2026 15:00:00 GMT", "11/24/2026", "2026-11-24T15:00:00Z\u{0}",
            "\u{0}", String(repeating: "x", count: 5000), String(repeating: "2026-11-24T15:00:00Z", count: 50),
        ]
        let unicode = [
            "\u{FF12}\u{FF10}\u{FF12}\u{FF16}-11-24T15:00:00Z",           // fullwidth digits
            "\u{0662}\u{0660}\u{0662}\u{0666}-11-24T15:00:00Z",           // Arabic-Indic digits
            "2026\u{2013}11\u{2013}24T15:00:00Z",                         // en dashes
            "2026\u{2212}11\u{2212}24T15:00:00Z",                         // minus signs
            "2026-11-24T15:00:00\u{2212}08:00",                           // minus sign in the offset
            "2026-11-24T15:00:00\u{FF3A}",                                // fullwidth Z
            "2026-11-24T15:00:00Z\u{200B}", "\u{200B}2026-11-24T15:00:00Z", "\u{FEFF}2026-11-24T15:00:00Z",
            "2026-11-24T15:00:00Z\u{1F600}", "\u{1F600}", "2026-11-24T15:00:00.\u{FF15}Z",
            "2026-11-24T15:00:00Z\u{0301}", "2026-11-24T15:00:00\u{00A0}Z", "\u{00A0}2026-11-24T15:00:00Z",
            "caf\u{00E9}", "\u{65E5}\u{672C}\u{8A9E}",
        ]
        for text in valid + nonsense + shapes + garbage + unicode { assertParity(text) }
        assertParity(nil)
        XCTAssertNil(APITime.parse(nil))
        XCTAssertNil(APITime.parse(""))
    }

    func testTheCommonFormsAreAccepted() {
        for text in valid1 { XCTAssertNotNil(APITime.parse(text), text) }
    }

    func testMissingZoneIsNil() {
        for text in ["2026-11-24T15:00:00", "2026-11-24T15:00:00.123", "2026-11-24T15:00:00.123456789"] {
            XCTAssertNil(APITime.parse(text), text)
        }
    }

    func testNonsenseDatesAreNilWhereTheFormatterSaysNil() {
        // Whatever the old formatter rejected stays rejected: the fast path must not turn Feb 30 into Mar 2.
        for text in ["2026-02-30T10:00:00Z", "2023-02-29T00:00:00Z", "2026-04-31T10:00:00Z", "2026-11-24T25:00:00Z", "2026-13-01T10:00:00Z"]
        where referenceParse(text) == nil {
            XCTAssertNil(APITime.parse(text), text)
        }
        XCTAssertNotNil(APITime.parse("2024-02-29T00:00:00Z"))   // leap day exists
    }

    func testGarbageAndEmptyAreNil() {
        for text in ["", " ", "garbage", "null", "0", "2026", "2026-11-24", "15:00:00Z", "\u{1F600}"] {
            XCTAssertNil(APITime.parse(text), text)
        }
    }

    /// 4,000 strings built from random parts, most of them slightly wrong (month 13, hour 25, minute 61, a fraction of
    /// 0 to 11 digits, odd zones). Green today.
    func testRandomizedParity() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let zones = ["Z", "Z", "Z", "+00:00", "-00:00", "+05:30", "-08:00", "+14:00", "-12:00", "", "+0530", "z", "+25:00", " Z", "+05:3"]
        var checked = 0
        for _ in 0..<4000 {
            let year = [1969, 1970, 1999, 2000, 2023, 2024, 2026, 2027, 2100, 9999][next(10)]
            let month = next(15)                 // 0 to 14
            let day = next(34)                   // 0 to 33
            let hourPart = next(27)
            let minute = next(63)
            let second = next(63)
            let fractionDigits = next(12)
            let fraction = fractionDigits == 0 ? "" : "." + String((0..<fractionDigits).map { _ in Character(String(next(10))) })
            let text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hourPart, minute, second)
                + fraction + zones[next(zones.count)]
            assertParity(text)
            checked += 1
        }
        XCTAssertEqual(checked, 4000)
    }

    /// Red today: 40,000 parses of what the Worker sends take about 14 s with a new formatter per call.
    func testFortyThousandParsesUnderOneSecond() {
        let inputs = [
            "2026-11-24T15:00:00Z", "2026-11-24T15:00:00.000Z", "2026-11-24T15:00:00.500Z", "2026-11-24T15:30:12.123Z",
            "2026-11-24T10:00:00-05:00", "2026-11-24T10:00:00.250-05:00", "2026-11-24T20:30:00+05:30", "2026-11-24T19:59:59.999Z",
        ]
        var sum = 0.0
        let started = Date()
        for index in 0..<40_000 {
            if let value = APITime.parse(inputs[index % inputs.count]) { sum += value.timeIntervalSince1970 }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(sum, 0)
        XCTAssertLessThan(elapsed, 1.0, "40,000 parses took \(elapsed) s")
    }

    /// The fast path and the fallback together: odd strings in the mix must not make it slow either.
    func testMixedValidAndOddInputsStayFast() {
        let inputs = ["2026-11-24T15:00:00.500Z", "2026-11-24T15:00:00", "2026-11-24T15:00:00+0530", "garbage", "", "2026-02-30T10:00:00Z"]
        let started = Date()
        var parsed = 0
        for index in 0..<2_000 where APITime.parse(inputs[index % inputs.count]) != nil { parsed += 1 }
        XCTAssertGreaterThan(parsed, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    /// Chart models are built off the main actor while the main thread parses too. Green today.
    func testParsingFromManyThreadsGivesTheSameAnswer() {
        let expected = APITime.parse("2026-11-24T15:00:00.250Z")?.timeIntervalSince1970
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<200 {
                let value = APITime.parse("2026-11-24T15:00:00.250Z")?.timeIntervalSince1970
                let other = APITime.parse("2026-11-24T15:00:00-05:00")?.timeIntervalSince1970
                if value != expected || other != 1_795_550_400 { counter.bump() }
            }
        }
        XCTAssertEqual(counter.value, 0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private let valid1 = [
        "2026-11-24T15:00:00Z", "2026-11-24T15:00:00.000Z", "2026-11-24T15:00:00.5Z", "2026-11-24T15:00:00+05:30",
        "2026-11-24T15:00:00-08:00", "2026-11-24T15:00:00.123+01:00",
    ]
}

// MARK: 2. MeetingChartModel

final class Build7SpeedTestsChartModel: XCTestCase {
    /// 33,000 points at 2 per second (4.58 h): the shape of the real meeting that froze the app.
    private static let bigPoints: [SamplePoint] = (0..<33_000).map {
        SamplePoint(ms: hour + $0 * 500, bpm: bpm(at: $0, spikeAt: 16_250, dipAt: 20_000), source: "WHOOP")
    }
    private static let big: MeetingHRDetail = {
        // swiftlint:disable:next force_try
        try! detail(points: bigPoints, label: "WHOOP", window: (hour, hour + 33_000 * 500, nil, nil))
    }()

    private func drawn(_ model: MeetingChartModel) -> [MeetingChartPoint] { model.segments.flatMap(\.points) }

    private func assertChronological(_ points: [MeetingChartPoint], file: StaticString = #filePath, line: UInt = #line) {
        for (before, after) in zip(points, points.dropFirst()) where !(before.date < after.date) {
            XCTFail("not strictly chronological at \(before.date) then \(after.date)", file: file, line: line)
            return
        }
    }

    // MARK: Parity with what MeetingHRChart.init computes today (small series)

    private var mixed: [SamplePoint] {
        [
            SamplePoint(ms: hour + 0, bpm: 72, source: "WHOOP"),
            SamplePoint(ms: hour + 10_000, bpm: 74, source: "WHOOP"),
            SamplePoint(ms: hour + 20_000, bpm: 71, source: "WHOOP"),
            SamplePoint(ms: hour + 200_000, bpm: 90, source: "WHOOP"),     // exactly 180 s after the last: same segment
            SamplePoint(ms: hour + 381_000, bpm: 95, source: "WHOOP"),     // 181 s: new segment
            SamplePoint(ms: hour + 390_000, bpm: 60, source: "Oura"),      // provider change: new segment
            SamplePoint(ms: hour + 990_000, bpm: 62, source: "Oura"),      // exactly 600 s: same segment
            SamplePoint(ms: hour + 1_591_000, bpm: 64, source: "Oura"),    // 601 s: new segment
        ]
    }

    func testSmallSeriesGivesTheSameValuesAsTheViewInitDid() throws {
        let input = try detail(
            points: mixed, label: "WHOOP + Oura", window: (hour, hour + hour, hour - 600_000, hour + hour + 600_000),
            baseline: (55, 100), stress: [(hour, 1.2), (hour + 300_000, 2.5)])
        let model = MeetingChartModel(detail: input)
        XCTAssertEqual(model.sourceLabel, "WHOOP + Oura")
        XCTAssertEqual(model.segments.map(\.provider), ["WHOOP", "WHOOP", "Oura", "Oura"])
        XCTAssertEqual(model.segments.map { $0.points.map { key($0.date) } }, [
            [hour, hour + 10_000, hour + 20_000, hour + 200_000], [hour + 381_000], [hour + 390_000, hour + 990_000], [hour + 1_591_000],
        ])
        XCTAssertEqual(model.segments.map { $0.points.map(\.bpm) }, [[72, 74, 71, 90], [95], [60, 62], [64]])
        XCTAssertEqual(model.from, date(hour - 600_000))
        XCTAssertEqual(model.to, date(hour + hour + 600_000))
        XCTAssertEqual(model.meetingStart, date(hour))
        XCTAssertEqual(model.meetingEnd, date(hour + hour))
        XCTAssertEqual(model.band, 55...100)
        XCTAssertEqual(model.low, 51)       // min(60, band 55) - 4
        XCTAssertEqual(model.high, 104)     // max(95, band 100) + 4
        XCTAssertEqual(model.minBpm, 60)
        XCTAssertEqual(model.maxBpm, 95)
        XCTAssertEqual(model.stress.map { key($0.date) }, [hour, hour + 300_000])
        XCTAssertEqual(model.stress.map(\.level), [1.2, 2.5])
    }

    func testWithoutABandTheDomainIsTheDataPlusFour() throws {
        let model = MeetingChartModel(detail: try detail(points: mixed, label: "WHOOP + Oura", window: (hour, hour + hour, nil, nil)))
        XCTAssertNil(model.band)
        XCTAssertEqual(model.low, 56)
        XCTAssertEqual(model.high, 99)
        XCTAssertTrue(model.stress.isEmpty)
    }

    func testBandOutsideTheDataStretchesTheDomain() throws {
        let points = [SamplePoint(ms: hour, bpm: 80, source: nil), SamplePoint(ms: hour + 5000, bpm: 82, source: nil)]
        let model = MeetingChartModel(detail: try detail(points: points, label: "WHOOP", window: (hour, hour + 60_000, nil, nil), baseline: (60, 120)))
        XCTAssertEqual(model.band, 60...120)
        XCTAssertEqual(model.low, 56)
        XCTAssertEqual(model.high, 124)
    }

    func testAnInvertedBaselineGivesNoBand() throws {
        let points = [SamplePoint(ms: hour, bpm: 80, source: nil), SamplePoint(ms: hour + 5000, bpm: 82, source: nil)]
        let model = MeetingChartModel(detail: try detail(points: points, label: "WHOOP", window: (hour, hour + 60_000, nil, nil), baseline: (100, 60)))
        XCTAssertNil(model.band)
        XCTAssertEqual(model.low, 76)
        XCTAssertEqual(model.high, 86)
    }

    func testPointsWithoutASourceTakeTheMeetingLabel() throws {
        let points = (0..<4).map { SamplePoint(ms: hour + $0 * 10_000, bpm: 70 + Double($0), source: nil) }
        let model = MeetingChartModel(detail: try detail(points: points, label: "Oura", window: (hour, hour + 60_000, nil, nil)))
        XCTAssertEqual(model.sourceLabel, "Oura")
        XCTAssertEqual(model.segments.map(\.provider), ["Oura"])
        XCTAssertEqual(model.segments.first?.points.count, 4)
    }

    func testTheLabelIsEmptyWithoutCoverage() throws {
        let points = [SamplePoint(ms: hour, bpm: 70, source: nil)]
        let model = MeetingChartModel(detail: try detail(points: points, label: nil, window: (hour, hour + 60_000, nil, nil)))
        XCTAssertEqual(model.sourceLabel, "")
        XCTAssertEqual(model.sourceLabel, TodayLogic.hrProviderLabel(nil))
    }

    func testWithoutAFetchWindowTheMeetingIsTheDomainUnlessDataStartsEarlier() throws {
        let points = [SamplePoint(ms: hour - 120_000, bpm: 70, source: nil), SamplePoint(ms: hour + 1000, bpm: 72, source: nil),
                      SamplePoint(ms: hour + hour + 900_000, bpm: 75, source: nil)]
        let model = MeetingChartModel(detail: try detail(points: points, label: "WHOOP", window: (hour, hour + hour, nil, nil)))
        XCTAssertEqual(model.from, date(hour - 120_000))       // earlier data pulls the left edge back
        XCTAssertEqual(model.to, date(hour + hour))            // later data does not push the right edge out
        XCTAssertEqual(model.meetingStart, date(hour))
        XCTAssertEqual(model.meetingEnd, date(hour + hour))
    }

    func testWithoutAWindowTheDataIsTheDomain() throws {
        let points = [SamplePoint(ms: hour + 30_000, bpm: 70, source: nil), SamplePoint(ms: hour + 90_000, bpm: 72, source: nil)]
        let model = MeetingChartModel(detail: try detail(points: points, label: "WHOOP"))
        XCTAssertEqual(model.from, date(hour + 30_000))
        XCTAssertEqual(model.to, date(hour + 90_000))
        XCTAssertNil(model.meetingStart)
        XCTAssertNil(model.meetingEnd)
    }

    func testASinglePointGetsAMinuteOfDomain() throws {
        let model = MeetingChartModel(detail: try detail(points: [SamplePoint(ms: hour, bpm: 70, source: nil)], label: "WHOOP"))
        XCTAssertEqual(model.from, date(hour))
        XCTAssertEqual(model.to, date(hour + 60_000))
        XCTAssertEqual(model.segments.map { $0.points.count }, [1])
        XCTAssertEqual(model.low, 66)
        XCTAssertEqual(model.high, 74)
    }

    func testAnEmptySeriesHasNoSegmentsAndTheDefaultDomain() throws {
        let model = MeetingChartModel(detail: try detail(points: [], label: "WHOOP", window: (hour, hour + hour, hour - 600_000, hour + hour + 600_000)))
        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertEqual(model.low, 50)
        XCTAssertEqual(model.high, 100)
        XCTAssertNil(model.minBpm)
        XCTAssertNil(model.maxBpm)
        XCTAssertEqual(model.from, date(hour - 600_000))
        XCTAssertEqual(model.to, date(hour + hour + 600_000))
    }

    func testASeriesUnderTheLimitIsDrawnUntouched() throws {
        for count in [2, 50, 399, 400] {
            let points = (0..<count).map { SamplePoint(ms: hour + $0 * 1000, bpm: bpm(at: $0), source: "WHOOP") }
            let model = MeetingChartModel(detail: try detail(points: points, window: (hour, hour + count * 1000, nil, nil)))
            XCTAssertEqual(model.segments.count, 1, "\(count) points")
            XCTAssertEqual(model.segments[0].points.map { key($0.date) }, points.map(\.ms), "\(count) points")
            XCTAssertEqual(model.segments[0].points.map(\.bpm), points.map(\.bpm), "\(count) points")
        }
    }

    func testTheLimitIsAParameterAndDefaultsTo400() throws {
        let points = (0..<2_000).map { SamplePoint(ms: hour + $0 * 1000, bpm: bpm(at: $0), source: "WHOOP") }
        let input = try detail(points: points, window: (hour, hour + 2_000_000, nil, nil))
        XCTAssertEqual(MeetingChartModel(detail: input), MeetingChartModel(detail: input, maxPoints: 400))
        let tight = MeetingChartModel(detail: input, maxPoints: 50)
        XCTAssertLessThanOrEqual(drawn(tight).count, 50 + 2 * tight.segments.count)
        XCTAssertLessThan(drawn(tight).count, drawn(MeetingChartModel(detail: input)).count)
        let roomy = MeetingChartModel(detail: input, maxPoints: 5_000)
        XCTAssertEqual(drawn(roomy).count, 2_000)
    }

    func testEquatableAndSendable() throws {
        let one = MeetingChartModel(detail: try detail(points: mixed, label: "WHOOP + Oura", window: (hour, hour + hour, nil, nil)))
        let same = MeetingChartModel(detail: try detail(points: mixed, label: "WHOOP + Oura", window: (hour, hour + hour, nil, nil)))
        var changed = mixed
        changed[3].bpm = 91
        let other = MeetingChartModel(detail: try detail(points: changed, label: "WHOOP + Oura", window: (hour, hour + hour, nil, nil)))
        XCTAssertEqual(one, same)
        XCTAssertNotEqual(one, other)
        _ = requireSendable(one)
        _ = requireSendable(MeetingChartPoint(date: date(0), bpm: 70))
        XCTAssertEqual(MeetingChartPoint(date: date(0), bpm: 70), MeetingChartPoint(date: date(0), bpm: 70))
        XCTAssertNotEqual(MeetingChartPoint(date: date(0), bpm: 70), MeetingChartPoint(date: date(0), bpm: 71))
    }

    // MARK: The real meeting: 33,000 points

    /// Red today as a compile failure; once built, red unless parsing is one fast pass (about 12 s per pass before).
    func testBuildingA33000PointModelIsFast() {
        let input = Self.big
        let started = Date()
        let model = MeetingChartModel(detail: input)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertLessThan(elapsed, 1.5, "building the model took \(elapsed) s")
    }

    func testBigSeriesDrawsAtMost400PointsPlusTwoPerSegment() {
        let model = MeetingChartModel(detail: Self.big)
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertLessThanOrEqual(drawn(model).count, 400 + 2 * model.segments.count)
        XCTAssertGreaterThan(drawn(model).count, 100, "it must still be a line, not a dot")
    }

    func testBigSeriesKeepsFirstLastMinAndMax() throws {
        let model = MeetingChartModel(detail: Self.big)
        let points = drawn(model)
        XCTAssertEqual(key(try XCTUnwrap(points.first).date), hour)
        XCTAssertEqual(key(try XCTUnwrap(points.last).date), hour + 32_999 * 500)
        XCTAssertTrue(points.contains { $0.bpm == 190 && key($0.date) == hour + 16_250 * 500 }, "the highest point survives")
        XCTAssertTrue(points.contains { $0.bpm == 41 && key($0.date) == hour + 20_000 * 500 }, "the lowest point survives")
    }

    func testBigSeriesKeepsEverySpikeAndDip() {
        // Each spike is the max of its 500 point neighbourhood, each dip the min, so each bucket's min and max keeps it.
        let points = drawn(MeetingChartModel(detail: Self.big))
        let kept = Set(points.map { key($0.date) })
        var missing: [Int] = []
        for index in stride(from: 250, to: 33_000, by: 250) where index != 16_250 && index != 20_000 {
            if !kept.contains(hour + index * 500) { missing.append(index) }
        }
        XCTAssertTrue(missing.isEmpty, "spikes and dips dropped at indexes \(missing.prefix(10))")
    }

    func testBigSeriesIsAChronologicalSubsetOfTheInput() {
        let model = MeetingChartModel(detail: Self.big)
        let points = drawn(model)
        assertChronological(points)
        let input = Dictionary(uniqueKeysWithValues: Self.bigPoints.map { ($0.ms, $0.bpm) })
        for point in points {
            XCTAssertEqual(input[key(point.date)], point.bpm, "\(point.date) is not a recorded point")
        }
    }

    func testBigSeriesDomainAndSpokenNumbersComeFromAllTheData() {
        let model = MeetingChartModel(detail: Self.big)
        XCTAssertEqual(model.minBpm, 41)
        XCTAssertEqual(model.maxBpm, 190)
        XCTAssertEqual(model.low, 37)
        XCTAssertEqual(model.high, 194)
        XCTAssertEqual(model.from, date(hour))
        XCTAssertEqual(model.to, date(hour + 33_000 * 500))
        XCTAssertEqual(model.sourceLabel, "WHOOP")
    }

    func testBigSeriesStillSplitsOnGapsAndProviderChanges() throws {
        var points: [SamplePoint] = []
        // 12,000 WHOOP points, a 400 s hole, 12,000 more WHOOP points, then 9,000 Oura points with no hole at all.
        for index in 0..<12_000 { points.append(SamplePoint(ms: hour + index * 500, bpm: bpm(at: index), source: "WHOOP")) }
        let secondStart = hour + 11_999 * 500 + 400_000
        for index in 0..<12_000 { points.append(SamplePoint(ms: secondStart + index * 500, bpm: bpm(at: index), source: "WHOOP")) }
        let ouraStart = secondStart + 12_000 * 500
        for index in 0..<9_000 { points.append(SamplePoint(ms: ouraStart + index * 500, bpm: bpm(at: index), source: "Oura")) }
        let model = MeetingChartModel(detail: try detail(points: points, label: "WHOOP + Oura", window: (hour, ouraStart + 9_000 * 500, nil, nil)))
        XCTAssertEqual(model.segments.map(\.provider), ["WHOOP", "WHOOP", "Oura"])
        XCTAssertLessThanOrEqual(drawn(model).count, 400 + 2 * 3)
        let ranges = [(hour, hour + 11_999 * 500), (secondStart, secondStart + 11_999 * 500), (ouraStart, ouraStart + 8_999 * 500)]
        for (segment, range) in zip(model.segments, ranges) {
            XCTAssertEqual(segment.points.first.map { key($0.date) }, range.0)
            XCTAssertEqual(segment.points.last.map { key($0.date) }, range.1)
            XCTAssertGreaterThan(segment.points.count, 20)
            assertChronological(segment.points)
        }
        assertChronological(drawn(model))
        XCTAssertEqual(model.minBpm, 46)
        XCTAssertEqual(model.maxBpm, 123)
    }

    func testManySmallSegmentsAreNotMergedAndNeverLoseAnEnd() throws {
        // 60 segments of 300 points each, 200 s apart (the WHOOP gap is 180 s).
        var points: [SamplePoint] = []
        var cursor = hour
        var ends: [(Int, Int)] = []
        for _ in 0..<60 {
            let first = cursor
            for index in 0..<300 { points.append(SamplePoint(ms: cursor + index * 500, bpm: bpm(at: index), source: "WHOOP")) }
            cursor += 299 * 500
            ends.append((first, cursor))
            cursor += 200_000
        }
        let model = MeetingChartModel(detail: try detail(points: points, label: "WHOOP", window: (hour, cursor, nil, nil)))
        XCTAssertEqual(model.segments.count, 60)
        XCTAssertLessThanOrEqual(drawn(model).count, 400 + 2 * 60)
        for (segment, end) in zip(model.segments, ends) {
            XCTAssertEqual(segment.points.first.map { key($0.date) }, end.0)
            XCTAssertEqual(segment.points.last.map { key($0.date) }, end.1)
            XCTAssertGreaterThanOrEqual(segment.points.count, 2)
        }
    }
}

// MARK: 3. Live chart downsampling

final class Build7SpeedTestsLiveChart: XCTestCase {
    private let t0 = 1_795_528_800_000.0                    // 14:00:00Z
    /// A 2 h meeting 10 minutes in, with 10 minute pads: the window spans 8,400 s.
    private var window: LiveWindowMs {
        LiveWindowMs(startMs: t0 + 600_000, endMs: t0 + 7_800_000, fromMs: t0, toMs: t0 + 8_400_000)
    }

    private func point(_ index: Int, spikeAt: Int? = nil, dipAt: Int? = nil, from offset: Double = 300_000) -> LivePoint {
        LivePoint(ms: t0 + offset + Double(index) * 500, bpm: bpm(at: index, spikeAt: spikeAt, dipAt: dipAt))
    }

    /// 15,000 readings, 2 per second, from 5 minutes into the lead pad to minute 130.
    private var big: [LivePoint] { (0..<15_000).map { point($0, spikeAt: 6_250, dipAt: 11_000) } }
    private func now(after points: [LivePoint]) -> Double { (points.last?.ms ?? t0) + 1_000 }

    private func drawn(_ chart: TodayLiveChart) -> [LivePoint] { chart.segments.flatMap { $0 } }

    func testABigSeriesDrawsAtMost400PointsPlusTwoPerSegment() {
        let points = big
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now(after: points))
        XCTAssertEqual(chart.segments.count, 1)
        XCTAssertLessThanOrEqual(drawn(chart).count, 400 + 2 * chart.segments.count)
        XCTAssertGreaterThan(drawn(chart).count, 100, "it must still be a line")
    }

    func testTheNumbersStillComeFromEveryPoint() throws {
        let points = big
        let nowMs = now(after: points)
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: nowMs)
        let inMeeting = points.filter { $0.ms >= window.startMs && $0.ms <= window.endMs }
        let sum = inMeeting.reduce(0) { $0 + $1.bpm }
        XCTAssertEqual(chart.stats, TodayLiveStats(
            min: Int(inMeeting.map(\.bpm).min()!.rounded()),
            avg: Int((sum / Double(inMeeting.count)).rounded(.toNearestOrAwayFromZero)),
            max: Int(inMeeting.map(\.bpm).max()!.rounded())))
        XCTAssertEqual(chart.stats?.max, 190)
        XCTAssertEqual(chart.stats?.min, 41)
        XCTAssertEqual(chart.extent, 41...190)
        XCTAssertEqual(chart.last, points.last)
        XCTAssertEqual(chart.current, Int(try XCTUnwrap(points.last).bpm.rounded()))
        // Stale clock still reads the newest reading, with no current.
        let stale = TodayLogic.liveChart(points: points, window: window, nowMs: nowMs + 60_000)
        XCTAssertNil(stale.current)
        XCTAssertEqual(stale.last, points.last)
        XCTAssertEqual(stale.stats, chart.stats)
        XCTAssertEqual(stale.extent, chart.extent)
    }

    func testDrawnPointsAreChronologicalRealReadingsAndKeepFirstLastMinMax() throws {
        let points = big
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now(after: points))
        let shown = drawn(chart)
        for (before, after) in zip(shown, shown.dropFirst()) where !(before.ms < after.ms) {
            XCTFail("not chronological at \(before.ms), \(after.ms)")
            return
        }
        let real = Dictionary(uniqueKeysWithValues: points.map { ($0.ms, $0.bpm) })
        for reading in shown { XCTAssertEqual(real[reading.ms], reading.bpm, "\(reading.ms) is not a received reading") }
        XCTAssertEqual(shown.first, points.first)
        XCTAssertEqual(shown.last, points.last, "the last reading is drawn")
        XCTAssertTrue(shown.contains(point(6_250, spikeAt: 6_250)), "highest reading kept")
        XCTAssertTrue(shown.contains(point(11_000, dipAt: 11_000)), "lowest reading kept")
    }

    func testEverySpikeAndDipSurvives() {
        let points = big
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now(after: points))
        let kept = Set(drawn(chart).map(\.ms))
        var missing: [Int] = []
        for index in stride(from: 250, to: 15_000, by: 250) where !kept.contains(points[index].ms) { missing.append(index) }
        XCTAssertTrue(missing.isEmpty, "spikes and dips dropped at indexes \(missing.prefix(10))")
    }

    func testOldBucketsStayPutWhenPointsArrive() {
        let all = big
        let early = Array(all.prefix(10_000))
        let first = TodayLogic.liveChart(points: early, window: window, nowMs: now(after: early))
        let later = TodayLogic.liveChart(points: all, window: window, nowMs: now(after: all))
        // Everything except the newest few minutes (still filling) must be exactly what it was a minute ago.
        let cutoff = (early.last?.ms ?? 0) - (window.toMs - window.fromMs) / 20
        let before = drawn(first).filter { $0.ms < cutoff }
        let after = drawn(later).filter { $0.ms < cutoff }
        XCTAssertGreaterThan(before.count, 50)
        XCTAssertEqual(before, after, "old points moved when new readings arrived")
    }

    func testOldBucketsStayPutOneReadingAtATime() {
        let all = Array(big.prefix(6_000))
        let cutoff = all[4_000].ms
        var previous: [LivePoint]?
        for count in stride(from: 4_100, through: 4_140, by: 1) {
            let slice = Array(all.prefix(count))
            let chart = TodayLogic.liveChart(points: slice, window: window, nowMs: now(after: slice))
            let settled = drawn(chart).filter { $0.ms < cutoff - 300_000 }
            if let previous { XCTAssertEqual(settled, previous, "settled points changed at \(count) readings") }
            previous = settled
        }
    }

    func testGapsStillSplitABigSeries() {
        var points = (0..<7_000).map { point($0) }
        let resume = (points.last?.ms ?? 0) + 20_000          // over the 15 s limit
        points += (0..<7_000).map { LivePoint(ms: resume + Double($0) * 500, bpm: bpm(at: $0)) }
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now(after: points))
        XCTAssertEqual(chart.segments.count, 2)
        XCTAssertLessThanOrEqual(drawn(chart).count, 400 + 2 * 2)
        XCTAssertEqual(chart.segments[0].first, points.first)
        XCTAssertEqual(chart.segments[0].last, points[6_999])
        XCTAssertEqual(chart.segments[1].first, points[7_000])
        XCTAssertEqual(chart.segments[1].last, points.last)
        XCTAssertGreaterThan(chart.segments[0].count, 20)
        XCTAssertGreaterThan(chart.segments[1].count, 20)
    }

    func testManyShortSegmentsKeepEveryEnd() {
        // 100 runs of 300 readings with a 20 s hole between them: 30,000 readings over an 8 h meeting window.
        let long = LiveWindowMs(startMs: t0 + 600_000, endMs: t0 + 28_800_000 + 600_000, fromMs: t0, toMs: t0 + 28_800_000 + 1_200_000)
        var points: [LivePoint] = []
        var runs: [(LivePoint, LivePoint)] = []
        var cursor = t0 + 300_000
        for _ in 0..<100 {
            let run = (0..<300).map { LivePoint(ms: cursor + Double($0) * 500, bpm: bpm(at: $0)) }
            runs.append((run[0], run[299]))
            points += run
            cursor = run[299].ms + 20_000
        }
        let chart = TodayLogic.liveChart(points: points, window: long, nowMs: now(after: points))
        XCTAssertEqual(chart.segments.count, 100)
        XCTAssertLessThanOrEqual(drawn(chart).count, 400 + 2 * 100)
        for (segment, run) in zip(chart.segments, runs) {
            XCTAssertEqual(segment.first, run.0)
            XCTAssertEqual(segment.last, run.1)
            XCTAssertGreaterThanOrEqual(segment.count, 2)
        }
    }

    func testReadingsOutsideTheWindowOrAfterNowAreStillIgnored() {
        var points = big
        points.insert(LivePoint(ms: t0 - 5_000, bpm: 250), at: 0)                      // before the pad
        points.append(LivePoint(ms: window.toMs + 5_000, bpm: 251))                    // after the pad
        let nowMs = points[9_000].ms
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: nowMs)
        XCTAssertFalse(drawn(chart).contains { $0.bpm >= 250 })
        XCTAssertFalse(drawn(chart).contains { $0.ms > nowMs })
        XCTAssertEqual(chart.last, points[9_000])
        XCTAssertEqual(chart.extent?.upperBound, points[0...9_000].dropFirst().map(\.bpm).max())
        XCTAssertEqual(chart.segments.first?.first, points[1])
    }

    func testASeriesUnderTheLimitIsUnchanged() {
        for count in [1, 2, 40, 399, 400] {
            let points = (0..<count).map { LivePoint(ms: t0 + 300_000 + Double($0) * 1000, bpm: bpm(at: $0)) }
            let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now(after: points))
            XCTAssertEqual(chart.segments, [points], "\(count) readings")
        }
    }

    func testSmallSeriesWithAGapKeepsEveryReading() {
        let points = [LivePoint(ms: t0 + 1000, bpm: 80), LivePoint(ms: t0 + 11_000, bpm: 81),
                      LivePoint(ms: t0 + 27_000, bpm: 90), LivePoint(ms: t0 + 31_000, bpm: 91)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: t0 + 40_000)
        XCTAssertEqual(chart.segments, [Array(points[0...1]), Array(points[2...3])])
    }
}

// MARK: 4. Keep showing the old detail while a reload runs

/// The decision lives in core as a small pure type so it can be tested. TodayModel holds one per meeting in place
/// of TodayHRDetailEntry, and the chart shows `data` whenever it is non-nil.
///
///   public struct MeetingDetailState<Value>: Equatable (when Value: Equatable), Sendable (when Value: Sendable)
///     data: Value?   error: String?   loading: Bool   loadedAt: Date?   stale: Bool
///     public init(data:error:loading:loadedAt:stale:)           every argument defaulted: nil, nil, false, nil, false
///     beginLoad() -> Self                          loading on, error cleared, data / loadedAt / stale kept
///     finishLoad(_ value: Value, at: Date) -> Self data replaced, error nil, loading off, loadedAt = at, stale off
///     failLoad(_ message: String, at: Date) -> Self data kept, error = message, loading off, loadedAt = at
///     markStale() -> Self                          data kept and still shown, stale on, nothing else changes
///     needsLoad(now: Date, maxAge: TimeInterval) -> Bool
///     showsLoadingPlaceholder: Bool                loading with nothing to show
///
/// `needsLoad`: false while loading; true when stale; true when never loaded; true once `now - loadedAt >= maxAge`.
/// Switching day or connection does not use this type: TodayModel drops every entry (a new empty dictionary).
final class Build7SpeedTestsDetailState: XCTestCase {
    private typealias State = MeetingDetailState<Int>
    private let loadedAt = Date(timeIntervalSince1970: 1_000)

    func testAFreshStateIsEmptyAndNeedsALoad() {
        let state = State()
        XCTAssertNil(state.data)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.loadedAt)
        XCTAssertFalse(state.stale)
        XCTAssertTrue(state.needsLoad(now: loadedAt, maxAge: 60))
        XCTAssertFalse(state.showsLoadingPlaceholder)
    }

    func testTheFirstLoadShowsThePlaceholderThenTheData() {
        let loading = State().beginLoad()
        XCTAssertTrue(loading.loading)
        XCTAssertTrue(loading.showsLoadingPlaceholder)
        XCTAssertFalse(loading.needsLoad(now: loadedAt, maxAge: 60), "already loading")
        let done = loading.finishLoad(7, at: loadedAt)
        XCTAssertEqual(done.data, 7)
        XCTAssertNil(done.error)
        XCTAssertFalse(done.loading)
        XCTAssertEqual(done.loadedAt, loadedAt)
        XCTAssertFalse(done.stale)
        XCTAssertFalse(done.showsLoadingPlaceholder)
    }

    func testAFreshCopyIsNotReloadedUntilItIsMaxAgeOld() {
        let state = State().finishLoad(7, at: loadedAt)
        XCTAssertFalse(state.needsLoad(now: loadedAt.addingTimeInterval(59.9), maxAge: 60))
        XCTAssertTrue(state.needsLoad(now: loadedAt.addingTimeInterval(60), maxAge: 60))
        XCTAssertTrue(state.needsLoad(now: loadedAt.addingTimeInterval(600), maxAge: 60))
    }

    /// The bug: Today refreshed, the entry was cleared and the open chart blinked to "Loading heart rate".
    func testMarkingStaleKeepsTheDataOnScreen() {
        let state = State().finishLoad(7, at: loadedAt).markStale()
        XCTAssertEqual(state.data, 7)
        XCTAssertTrue(state.stale)
        XCTAssertFalse(state.showsLoadingPlaceholder)
        XCTAssertTrue(state.needsLoad(now: loadedAt.addingTimeInterval(1), maxAge: 60), "stale data reloads even when young")
    }

    func testReloadingStaleDataKeepsItShowingTheWholeTime() {
        let reloading = State().finishLoad(7, at: loadedAt).markStale().beginLoad()
        XCTAssertEqual(reloading.data, 7)
        XCTAssertTrue(reloading.loading)
        XCTAssertFalse(reloading.showsLoadingPlaceholder, "no blink to Loading heart rate")
        XCTAssertFalse(reloading.needsLoad(now: loadedAt.addingTimeInterval(1), maxAge: 60), "one load at a time")
        XCTAssertTrue(reloading.stale, "still stale until the new answer lands")
    }

    func testTheReloadReplacesTheDataAndClearsStale() {
        let later = loadedAt.addingTimeInterval(120)
        let done = State().finishLoad(7, at: loadedAt).markStale().beginLoad().finishLoad(9, at: later)
        XCTAssertEqual(done.data, 9)
        XCTAssertFalse(done.stale)
        XCTAssertFalse(done.loading)
        XCTAssertNil(done.error)
        XCTAssertEqual(done.loadedAt, later)
        XCTAssertFalse(done.needsLoad(now: later.addingTimeInterval(10), maxAge: 60))
    }

    func testAFailedReloadKeepsTheOldDataAndSaysWhy() {
        let failedAt = loadedAt.addingTimeInterval(130)
        let state = State().finishLoad(7, at: loadedAt).markStale().beginLoad().failLoad("No heart rate for this meeting.", at: failedAt)
        XCTAssertEqual(state.data, 7)
        XCTAssertEqual(state.error, "No heart rate for this meeting.")
        XCTAssertFalse(state.loading)
        XCTAssertEqual(state.loadedAt, failedAt)
        XCTAssertFalse(state.showsLoadingPlaceholder)
    }

    func testAFailedFirstLoadHasNoDataAndAnError() {
        let state = State().beginLoad().failLoad("Offline", at: loadedAt)
        XCTAssertNil(state.data)
        XCTAssertEqual(state.error, "Offline")
        XCTAssertFalse(state.loading)
        XCTAssertFalse(state.showsLoadingPlaceholder)
        XCTAssertFalse(state.needsLoad(now: loadedAt.addingTimeInterval(5), maxAge: 60), "do not hammer a failing call")
        XCTAssertTrue(state.needsLoad(now: loadedAt.addingTimeInterval(60), maxAge: 60))
    }

    func testABeginLoadClearsTheLastError() {
        let state = State().beginLoad().failLoad("Offline", at: loadedAt).beginLoad()
        XCTAssertNil(state.error)
        XCTAssertTrue(state.loading)
    }

    func testTheTransitionsArePureAndTheTypeIsEquatableAndSendable() {
        let original = State().finishLoad(7, at: loadedAt)
        let copy = original
        _ = original.markStale()
        _ = original.beginLoad()
        _ = original.failLoad("x", at: loadedAt)
        XCTAssertEqual(original, copy)
        XCTAssertNotEqual(original, original.markStale())
        _ = requireSendable(original)
    }

    func testMarkingStaleOnAnEmptyOrLoadingStateChangesNothingElse() {
        let empty = State().markStale()
        XCTAssertNil(empty.data)
        XCTAssertFalse(empty.loading)
        XCTAssertFalse(empty.showsLoadingPlaceholder)
        let loading = State().beginLoad().markStale()
        XCTAssertTrue(loading.loading)
        XCTAssertTrue(loading.showsLoadingPlaceholder, "nothing to keep showing yet")
    }
}
