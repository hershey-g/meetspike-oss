import Foundation
import XCTest
@testable import MeetspikeHRCore

// Today track: heart rate series segmenting, provider label, partial note and zone pill.
// Mirrors the group loop in the meeting chart, meetingHrLabel (wearable-labels.js), partialNote and zonePill in public/app.js.

private let newYork = TimeZone(identifier: "America/New_York")!

private func hr(_ json: String) throws -> MeetingHR {
    try MobileJSON.decode(MeetingHR.self, json)
}

private func point(_ secondsAfterStart: Double, _ bpm: Double = 70, source: String? = nil) -> HRPoint {
    // 2026-11-24 14:00:00Z plus an offset, written out as a timestamp.
    let base = MobileJSON.ms("2026-11-24T14:00:00Z") + secondsAfterStart * 1000
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return HRPoint(t: formatter.string(from: Date(timeIntervalSince1970: base / 1000)), bpm: bpm, source: source)
}

final class TodayHRSegmentTests: XCTestCase {
    func testEmptySeriesHasNoSegments() throws {
        XCTAssertEqual(TodayLogic.hrSegments([], meetingSource: "WHOOP"), [])
    }

    func testWhoopPointsWithinThreeMinutesJoin() throws {
        let series = [point(0), point(60), point(180)]
        let segments = TodayLogic.hrSegments(series, meetingSource: "WHOOP")
        XCTAssertEqual(segments, [TodayHRSegment(provider: "WHOOP", points: series)])
    }

    func testWhoopGapOverThreeMinutesSplits() throws {
        let series = [point(0), point(60), point(241), point(300)]
        let segments = TodayLogic.hrSegments(series, meetingSource: "WHOOP")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[safe: 0]?.points, [point(0), point(60)])
        XCTAssertEqual(segments[safe: 1]?.points, [point(241), point(300)])
        XCTAssertEqual(segments.map(\.provider), ["WHOOP", "WHOOP"])
    }

    func testWhoopGapJustOverThreeMinutesSplits() throws {
        let segments = TodayLogic.hrSegments([point(0), point(181)], meetingSource: "WHOOP")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.points.count), [1, 1])
    }

    func testOuraPointsWithinTenMinutesJoin() throws {
        let series = [point(0), point(300), point(900), point(1500)]
        let segments = TodayLogic.hrSegments(series, meetingSource: "Oura")
        XCTAssertEqual(segments, [TodayHRSegment(provider: "Oura", points: series)])
    }

    func testOuraGapOverTenMinutesSplits() throws {
        let series = [point(0), point(600), point(1201)]
        let segments = TodayLogic.hrSegments(series, meetingSource: "Oura")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[safe: 0]?.points, [point(0), point(600)])
        XCTAssertEqual(segments[safe: 1]?.points, [point(1201)])
    }

    func testAThreeMinuteGapSplitsWhoopButNotOura() throws {
        let series = [point(0), point(400)]
        XCTAssertEqual(TodayLogic.hrSegments(series, meetingSource: "WHOOP").count, 2)
        XCTAssertEqual(TodayLogic.hrSegments(series, meetingSource: "Oura").count, 1)
    }

    func testAPointsOwnSourceBeatsTheMeetingSource() throws {
        let series = [point(0, source: "Oura"), point(60, source: "Oura")]
        let segments = TodayLogic.hrSegments(series, meetingSource: "WHOOP")
        XCTAssertEqual(segments.map(\.provider), ["Oura"])
        XCTAssertEqual(segments.first?.points.count, 2)
    }

    func testChangingProviderSplitsEvenInsideTheGap() throws {
        let series = [point(0, source: "WHOOP"), point(30, source: "WHOOP"), point(60, source: "Oura"), point(90, source: "Oura")]
        let segments = TodayLogic.hrSegments(series, meetingSource: "WHOOP + Oura")
        XCTAssertEqual(segments.map(\.provider), ["WHOOP", "Oura"])
        XCTAssertEqual(segments.map(\.points.count), [2, 2])
    }

    func testMissingSourcesFallBackToEmptyProviderWithTheWiderGap() throws {
        let series = [point(0), point(500)]
        let segments = TodayLogic.hrSegments(series, meetingSource: nil)
        XCTAssertEqual(segments.map(\.provider), [""])
        XCTAssertEqual(segments.first?.points.count, 2)
    }

    func testSinglePointIsOneSegment() throws {
        XCTAssertEqual(TodayLogic.hrSegments([point(0)], meetingSource: "WHOOP"), [TodayHRSegment(provider: "WHOOP", points: [point(0)])])
    }

    func testGapConstants() throws {
        XCTAssertEqual(TodayLogic.whoopGapSeconds, 180)
        XCTAssertEqual(TodayLogic.ouraGapSeconds, 600)
    }
}

final class TodayHRProviderTests: XCTestCase {
    func testNoSummaryHasNoLabel() throws {
        XCTAssertEqual(TodayLogic.hrProviderLabel(nil), "")
    }

    func testNoCoverageHasNoLabel() throws {
        XCTAssertEqual(TodayLogic.hrProviderLabel(try hr(#"{"coverage":"none","source":"WHOOP"}"#)), "")
    }

    func testSourceWins() throws {
        XCTAssertEqual(TodayLogic.hrProviderLabel(try hr(#"{"coverage":"ok","source":"Oura","methodNote":"WHOOP strap"}"#)), "Oura")
        XCTAssertEqual(TodayLogic.hrProviderLabel(try hr(#"{"coverage":"ok","source":"WHOOP + Oura"}"#)), "WHOOP + Oura")
    }

    func testOldCachedResponseUsesTheMethodNote() throws {
        XCTAssertEqual(TodayLogic.hrProviderLabel(try hr(#"{"coverage":"ok","methodNote":"Heart rate from your WHOOP strap."}"#)), "WHOOP")
    }

    func testOtherwiseOura() throws {
        XCTAssertEqual(TodayLogic.hrProviderLabel(try hr(#"{"coverage":"ok","methodNote":"Heart rate from your ring."}"#)), "Oura")
        XCTAssertEqual(TodayLogic.hrProviderLabel(try hr(#"{"coverage":"ok"}"#)), "Oura")
    }
}

final class TodayPartialNoteTests: XCTestCase {
    private func partial(late: Bool, early: Bool, coverage: String = "ok") throws -> MeetingHR {
        try hr("""
        {"coverage":"\(coverage)","source":"WHOOP","partial":{"fromUtc":"2026-11-24T14:45:00.000Z","toUtc":"2026-11-24T15:20:00.000Z","lateStart":\(late),"earlyEnd":\(early)}}
        """)
    }

    func testLateStart() throws {
        XCTAssertEqual(TodayLogic.partialNote(try partial(late: true, early: false), timeZone: newYork), "HR from 9:45 AM")
    }

    func testEarlyEnd() throws {
        XCTAssertEqual(TodayLogic.partialNote(try partial(late: false, early: true), timeZone: newYork), "HR until 10:20 AM")
    }

    func testLateStartAndEarlyEnd() throws {
        XCTAssertEqual(
            TodayLogic.partialNote(try partial(late: true, early: true), timeZone: newYork), "HR between 9:45 AM and 10:20 AM")
    }

    func testGapsOnly() throws {
        XCTAssertEqual(TodayLogic.partialNote(try partial(late: false, early: false), timeZone: newYork), "Gaps in heart rate")
    }

    func testUsesTheGivenTimeZoneNotTheDevicesOwn() throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(TodayLogic.partialNote(try partial(late: true, early: false), timeZone: la), "HR from 6:45 AM")
    }

    func testNoPartialInfoIsEmpty() throws {
        XCTAssertEqual(TodayLogic.partialNote(try hr(#"{"coverage":"ok","source":"WHOOP"}"#), timeZone: newYork), "")
        XCTAssertEqual(TodayLogic.partialNote(nil, timeZone: newYork), "")
    }

    func testNoCoverageIsEmptyEvenWithPartialInfo() throws {
        XCTAssertEqual(TodayLogic.partialNote(try partial(late: true, early: true, coverage: "none"), timeZone: newYork), "")
    }
}

final class TodayZonePillTests: XCTestCase {
    func testNoSummaryIsNoHR() throws {
        XCTAssertEqual(TodayLogic.zonePill(nil, timeZone: newYork), TodayZonePill(tone: .none, text: "No HR", note: nil))
    }

    func testNoCoverageIsNoHR() throws {
        let pill = TodayLogic.zonePill(try hr(#"{"coverage":"none","zone":"high","headline":"Ran hot"}"#), timeZone: newYork)
        XCTAssertEqual(pill, TodayZonePill(tone: .none, text: "No HR", note: nil))
    }

    func testHighZoneIsBad() throws {
        let pill = TodayLogic.zonePill(try hr(#"{"coverage":"ok","source":"WHOOP","zone":"high","headline":"Ran hot"}"#), timeZone: newYork)
        XCTAssertEqual(pill, TodayZonePill(tone: .bad, text: "Ran hot · WHOOP", note: nil))
    }

    func testModerateZoneIsWarn() throws {
        let pill = TodayLogic.zonePill(try hr(#"{"coverage":"ok","source":"Oura","zone":"moderate","headline":"A bit up"}"#), timeZone: newYork)
        XCTAssertEqual(pill, TodayZonePill(tone: .warn, text: "A bit up · Oura", note: nil))
    }

    func testLowZoneIsGood() throws {
        let pill = TodayLogic.zonePill(try hr(#"{"coverage":"ok","source":"WHOOP","zone":"low","headline":"Calm"}"#), timeZone: newYork)
        XCTAssertEqual(pill, TodayZonePill(tone: .good, text: "Calm · WHOOP", note: nil))
    }

    func testUnknownZoneHasNoTone() throws {
        let pill = TodayLogic.zonePill(try hr(#"{"coverage":"ok","source":"WHOOP","headline":"Steady"}"#), timeZone: newYork)
        XCTAssertEqual(pill.tone, .none)
        XCTAssertEqual(pill.text, "Steady · WHOOP")
    }

    func testPartialCoverageAddsTheNote() throws {
        let json = """
        {"coverage":"ok","source":"WHOOP","zone":"high","headline":"Ran hot",
         "partial":{"fromUtc":"2026-11-24T14:45:00Z","toUtc":"2026-11-24T15:20:00Z","lateStart":true,"earlyEnd":false}}
        """
        let pill = TodayLogic.zonePill(try hr(json), timeZone: newYork)
        XCTAssertEqual(pill, TodayZonePill(tone: .bad, text: "Ran hot · WHOOP", note: "HR from 9:45 AM"))
    }
}
