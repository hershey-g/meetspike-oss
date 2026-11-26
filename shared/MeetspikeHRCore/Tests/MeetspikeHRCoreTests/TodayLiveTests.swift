import Foundation
import XCTest
@testable import MeetspikeHRCore

// Today track: live window, merging, live card numbers, timeline strip, refresh throttle.
// Mirrors public/live-hr.js (meetingLiveWindow, mergeLivePoints, liveChartData) and timeline() in public/app.js.

final class TodayLiveWindowTests: XCTestCase {
    private let start = "2026-11-24T15:00:00Z"

    func testWindowPadsTenMinutesEitherSide() throws {
        let window = try XCTUnwrap(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T16:00:00Z", sourceType: "calendar"))
        let startMs = MobileJSON.ms(start)
        XCTAssertEqual(window.startMs, startMs)
        XCTAssertEqual(window.endMs, startMs + 3_600_000)
        XCTAssertEqual(window.fromMs, startMs - 600_000)
        XCTAssertEqual(window.toMs, startMs + 3_600_000 + 600_000)
    }

    func testMissingSourceTypeCountsAsCalendar() {
        XCTAssertNotNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T16:00:00Z", sourceType: nil))
    }

    func testOnlyCalendarEventsHaveAWindow() {
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T16:00:00Z", sourceType: "plaud"))
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T16:00:00Z", sourceType: "recording"))
    }

    func testEightHoursIsTheLongestMeeting() {
        XCTAssertNotNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T23:00:00Z", sourceType: "calendar"))
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T23:00:01Z", sourceType: "calendar"))
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-25T03:00:00Z", sourceType: "calendar"))
    }

    func testEndMustBeAfterStart() {
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: start, sourceType: "calendar"))
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: "2026-11-24T14:00:00Z", sourceType: "calendar"))
    }

    func testBadOrMissingTimesHaveNoWindow() {
        XCTAssertNil(TodayLogic.liveWindow(startUtc: nil, endUtc: "2026-11-24T16:00:00Z", sourceType: "calendar"))
        XCTAssertNil(TodayLogic.liveWindow(startUtc: start, endUtc: nil, sourceType: "calendar"))
        XCTAssertNil(TodayLogic.liveWindow(startUtc: "soon", endUtc: "later", sourceType: "calendar"))
    }

    func testFractionalSecondTimestampsWork() throws {
        let window = try XCTUnwrap(TodayLogic.liveWindow(
            startUtc: "2026-11-24T15:00:00.000Z", endUtc: "2026-11-24T15:30:00.000Z", sourceType: "calendar"))
        XCTAssertEqual(window.endMs - window.startMs, 1_800_000)
    }

    func testConstants() {
        XCTAssertEqual(TodayLogic.livePadMs, 600_000)
        XCTAssertEqual(TodayLogic.liveMaxMeetingMs, 28_800_000)
        XCTAssertEqual(TodayLogic.liveStaleMs, 45_000)
        XCTAssertEqual(TodayLogic.liveGapMs, 15_000)
    }
}

final class TodayLiveMergeTests: XCTestCase {
    func testBatchIsAddedAndSortedOldestFirst() {
        let merged = TodayLogic.mergeLivePoints(
            [LivePoint(ms: 1000, bpm: 70), LivePoint(ms: 3000, bpm: 72)],
            [LivePoint(ms: 2000, bpm: 71), LivePoint(ms: 4000, bpm: 73)])
        XCTAssertEqual(merged.map(\.ms), [1000, 2000, 3000, 4000])
        XCTAssertEqual(merged.map(\.bpm), [70, 71, 72, 73])
    }

    func testSameTimestampTakesTheBatch() {
        let merged = TodayLogic.mergeLivePoints(
            [LivePoint(ms: 1000, bpm: 70), LivePoint(ms: 2000, bpm: 71)],
            [LivePoint(ms: 2000, bpm: 99)])
        XCTAssertEqual(merged, [LivePoint(ms: 1000, bpm: 70), LivePoint(ms: 2000, bpm: 99)])
    }

    func testEmptyBatchKeepsWhatIsHeld() {
        let held = [LivePoint(ms: 1000, bpm: 70)]
        XCTAssertEqual(TodayLogic.mergeLivePoints(held, []), held)
    }

    func testFirstBatchIntoNothingIsSorted() {
        let merged = TodayLogic.mergeLivePoints([], [LivePoint(ms: 2000, bpm: 71), LivePoint(ms: 1000, bpm: 70)])
        XCTAssertEqual(merged.map(\.ms), [1000, 2000])
    }
}

final class TodayLiveChartTests: XCTestCase {
    // Meeting 10:00 to 11:00 (ms offsets from a fixed base), pads either side.
    private let base = 1_700_000_000_000.0
    private var window: LiveWindowMs {
        LiveWindowMs(startMs: base + 600_000, endMs: base + 4_200_000, fromMs: base, toMs: base + 4_800_000)
    }

    private func p(_ offsetSeconds: Double, _ bpm: Double) -> LivePoint {
        LivePoint(ms: base + offsetSeconds * 1000, bpm: bpm)
    }

    func testNoPointsGivesAnEmptyCard() {
        let chart = TodayLogic.liveChart(points: [], window: window, nowMs: base + 1_000_000)
        XCTAssertEqual(chart, TodayLiveChart(current: nil, last: nil, stats: nil, extent: nil, segments: []))
    }

    func testCurrentIsTheNewestReadingWhenFresh() {
        let points = [p(1000, 80), p(1005, 84)]
        let now = base + 1_005_000 + 44_999
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now)
        XCTAssertEqual(chart.current, 84)
        XCTAssertEqual(chart.last, p(1005, 84))
    }

    func testReadingBecomesStaleAtFortyFiveSeconds() {
        let points = [p(1000, 80), p(1005, 84)]
        let now = base + 1_005_000 + 45_000
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: now)
        XCTAssertNil(chart.current)
        XCTAssertEqual(chart.last, p(1005, 84))
    }

    func testReadingsFifteenSecondsApartStayInOneSegment() {
        let points = [p(1000, 80), p(1015, 82), p(1030, 84)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 1_100_000)
        XCTAssertEqual(chart.segments, [points])
    }

    func testAGapOverFifteenSecondsStartsANewSegment() {
        let points = [p(1000, 80), p(1010, 81), p(1026, 90), p(1030, 91)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 1_100_000)
        XCTAssertEqual(chart.segments, [[p(1000, 80), p(1010, 81)], [p(1026, 90), p(1030, 91)]])
    }

    func testReadingsOutsideThePaddedWindowAreIgnored() {
        let points = [p(-60, 50), p(1000, 80), p(5000, 55)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 6_000_000)
        XCTAssertEqual(chart.segments, [[p(1000, 80)]])
        XCTAssertEqual(chart.last, p(1000, 80))
        XCTAssertEqual(chart.extent, 80...80)
    }

    func testReadingsAfterNowAreIgnored() {
        let points = [p(1000, 80), p(1010, 82), p(1020, 99)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 1_010_000)
        XCTAssertEqual(chart.segments, [[p(1000, 80), p(1010, 82)]])
        XCTAssertEqual(chart.last, p(1010, 82))
        XCTAssertEqual(chart.extent, 80...82)
    }

    func testStatsCoverOnlyTheRealMeetingNotThePads() throws {
        // 100 s into the lead pad, three readings in the meeting, one in the trailing pad.
        let points = [p(100, 120), p(700, 70), p(710, 72), p(720, 74), p(4300, 130)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 4_400_000)
        XCTAssertEqual(chart.stats, TodayLiveStats(min: 70, avg: 72, max: 74))
        XCTAssertEqual(chart.extent, 70...130)
    }

    func testAverageRoundsHalfUpLikeTheWeb() throws {
        let points = [p(700, 70), p(710, 71)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 1_000_000)
        XCTAssertEqual(chart.stats, TodayLiveStats(min: 70, avg: 71, max: 71))
    }

    func testOnlyPadReadingsGiveNoStatsButStillAPlot() {
        let points = [p(100, 90), p(110, 92)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 300_000)
        XCTAssertNil(chart.stats)
        XCTAssertEqual(chart.extent, 90...92)
        XCTAssertEqual(chart.segments.count, 1)
    }

    func testMeetingBoundariesCountInStats() {
        let points = [LivePoint(ms: window.startMs, bpm: 60), LivePoint(ms: window.endMs, bpm: 100)]
        let chart = TodayLogic.liveChart(points: points, window: window, nowMs: base + 5_000_000)
        XCTAssertEqual(chart.stats, TodayLiveStats(min: 60, avg: 80, max: 100))
    }
}

final class TodayTimelineTests: XCTestCase {
    private func assertBar(_ bar: TodayTimelineBar?, left: Double, width: Double, afterHours: Bool, line: UInt = #line) throws {
        let bar = try XCTUnwrap(bar, line: line)
        XCTAssertEqual(bar.left, left, accuracy: 1e-9, line: line)
        XCTAssertEqual(bar.width, width, accuracy: 1e-9, line: line)
        XCTAssertEqual(bar.afterHours, afterHours, line: line)
    }

    func testMorningMeetingPosition() throws {
        // 09:30 for one hour: (9.5 - 7) / 14 from the left, one hour out of 14 wide.
        try assertBar(TodayLogic.timelineBar(startLocal: "2026-11-24T09:30:00-05:00", durationS: 3600),
                      left: 2.5 / 14, width: 1.0 / 14, afterHours: false)
    }

    func testSevenAmIsTheLeftEdge() throws {
        try assertBar(TodayLogic.timelineBar(startLocal: "2026-11-24T07:00:00-05:00", durationS: 1800),
                      left: 0, width: 0.5 / 14, afterHours: false)
    }

    func testBeforeSevenClampsToTheLeftEdge() throws {
        let bar = try XCTUnwrap(TodayLogic.timelineBar(startLocal: "2026-11-24T06:00:00-05:00", durationS: 3600))
        XCTAssertEqual(bar.left, 0, accuracy: 1e-9)
    }

    func testWidthIsCutAtTheRightEdge() throws {
        // 20:30 for two hours: only half an hour fits before 21:00.
        try assertBar(TodayLogic.timelineBar(startLocal: "2026-11-24T20:30:00-05:00", durationS: 7200),
                      left: 13.5 / 14, width: 0.5 / 14, afterHours: true)
    }

    func testStartAfterNinePmClampsToTheRightEdge() throws {
        let bar = try XCTUnwrap(TodayLogic.timelineBar(startLocal: "2026-11-24T22:00:00-05:00", durationS: 3600))
        XCTAssertEqual(bar.left, 1, accuracy: 1e-9)
        XCTAssertTrue(bar.afterHours)
    }

    func testVeryShortMeetingIsStillVisible() throws {
        try assertBar(TodayLogic.timelineBar(startLocal: "2026-11-24T10:00:00-05:00", durationS: 60),
                      left: 3.0 / 14, width: 0.006, afterHours: false)
        try assertBar(TodayLogic.timelineBar(startLocal: "2026-11-24T10:00:00-05:00", durationS: nil),
                      left: 3.0 / 14, width: 0.006, afterHours: false)
        try assertBar(TodayLogic.timelineBar(startLocal: "2026-11-24T10:00:00-05:00", durationS: 0),
                      left: 3.0 / 14, width: 0.006, afterHours: false)
    }

    func testAfterHoursStartsAtSixPm() throws {
        XCTAssertEqual(try XCTUnwrap(TodayLogic.timelineBar(startLocal: "2026-11-24T18:00:00-05:00", durationS: 3600)).afterHours, true)
        XCTAssertEqual(try XCTUnwrap(TodayLogic.timelineBar(startLocal: "2026-11-24T17:59:00-05:00", durationS: 3600)).afterHours, false)
    }

    func testTheWallClockInTheStringIsUsedNotTheDevicesZone() throws {
        // 09:30 local to the meeting, whatever the offset says.
        let bar = try XCTUnwrap(TodayLogic.timelineBar(startLocal: "2026-11-24T09:30:00+09:00", durationS: 3600))
        XCTAssertEqual(bar.left, 2.5 / 14, accuracy: 1e-9)
    }

    func testNoParsableStartHasNoBar() {
        XCTAssertNil(TodayLogic.timelineBar(startLocal: nil, durationS: 3600))
        XCTAssertNil(TodayLogic.timelineBar(startLocal: "", durationS: 3600))
        XCTAssertNil(TodayLogic.timelineBar(startLocal: "whenever", durationS: 3600))
    }

    func testStripHours() {
        XCTAssertEqual(TodayLogic.timelineFromHour, 7)
        XCTAssertEqual(TodayLogic.timelineToHour, 21)
    }
}

final class TodayRefreshThrottleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNeverSyncedRefreshes() {
        XCTAssertTrue(TodayLogic.shouldAutoRefresh(lastSync: nil, now: now))
    }

    func testRecentSyncSkipsTheRefresh() {
        XCTAssertFalse(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-119), now: now))
    }

    func testTwoMinutesOldRefreshes() {
        XCTAssertTrue(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-120), now: now))
        XCTAssertTrue(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-3600), now: now))
    }

    func testThrottleConstant() {
        XCTAssertEqual(TodayLogic.refreshThrottleSeconds, 120)
    }
}
