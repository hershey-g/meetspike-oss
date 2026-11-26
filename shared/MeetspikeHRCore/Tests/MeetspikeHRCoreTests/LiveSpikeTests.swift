import Foundation
import XCTest
@testable import MeetspikeHRCore

final class LiveSpikeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func meeting(_ title: String, _ start: Double, _ end: Double) throws -> CalendarMeeting {
        try XCTUnwrap(CalendarMeeting(title: title, start: at(start), end: at(end)))
    }

    // MARK: Resting comparison

    func testLevelsFollowDocumentedThresholds() {
        XCTAssertEqual(RestingComparison.level(delta: -12), .normal)
        XCTAssertEqual(RestingComparison.level(delta: 0), .normal)
        XCTAssertEqual(RestingComparison.level(delta: 14), .normal)
        XCTAssertEqual(RestingComparison.level(delta: 15), .elevated)
        XCTAssertEqual(RestingComparison.level(delta: 29), .elevated)
        XCTAssertEqual(RestingComparison.level(delta: 30), .high)
        XCTAssertEqual(RestingComparison.level(delta: 80), .high)
    }

    func testLabelsOverUnderAndAt() throws {
        let over = try XCTUnwrap(RestingComparison(bpm: 72, resting: 58))
        XCTAssertEqual(over.delta, 14)
        XCTAssertEqual(over.label, "+14 over resting")
        XCTAssertEqual(over.level, .normal)
        XCTAssertEqual(over.accessibilityLabel, "14 over your resting rate of 58")

        let under = try XCTUnwrap(RestingComparison(bpm: 52, resting: 58))
        XCTAssertEqual(under.label, "6 under resting")
        XCTAssertEqual(under.accessibilityLabel, "6 under your resting rate of 58")

        let same = try XCTUnwrap(RestingComparison(bpm: 58, resting: 58))
        XCTAssertEqual(same.label, "At resting")

        let high = try XCTUnwrap(RestingComparison(bpm: 99, resting: 58))
        XCTAssertEqual(high.level, .high)
        XCTAssertEqual(high.accessibilityLabel, "41 over your resting rate of 58. High")
        XCTAssertEqual(RestingComparison(bpm: 80, resting: 58)?.accessibilityLabel,
                       "22 over your resting rate of 58. Elevated")
    }

    func testNoComparisonWithoutBothValues() {
        XCTAssertNil(RestingComparison(bpm: 70, resting: nil))
        XCTAssertNil(RestingComparison(bpm: nil, resting: 58))
        XCTAssertNil(RestingComparison(bpm: 0, resting: 58))
    }

    func testLabelsHaveNoDashes() {
        for delta in [-20, -1, 0, 1, 20, 40] {
            let comparison = RestingComparison(bpm: 60 + delta, resting: 60)!
            XCTAssertFalse(comparison.label.contains("\u{2014}"))
            XCTAssertFalse(comparison.label.contains("\u{2013}"))
            XCTAssertFalse(comparison.accessibilityLabel.contains("\u{2014}"))
        }
    }

    // MARK: Baseline

    func testBaselineValueRoundsAndRejectsBadValues() {
        XCTAssertEqual(RestingBaseline.value(fromUsual: 54.4), 54)
        XCTAssertEqual(RestingBaseline.value(fromUsual: 54.5), 55)
        XCTAssertNil(RestingBaseline.value(fromUsual: nil))
        XCTAssertNil(RestingBaseline.value(fromUsual: 0))
        XCTAssertNil(RestingBaseline.value(fromUsual: 240))
        XCTAssertNil(RestingBaseline.value(fromUsual: .nan))
    }

    func testSavedBaselineExpiresAfterTwoWeeks() {
        let now = base
        XCTAssertEqual(RestingBaseline.current(saved: 58, savedAt: now.addingTimeInterval(-86_400), now: now), 58)
        XCTAssertEqual(RestingBaseline.current(saved: 58, savedAt: now.addingTimeInterval(-RestingBaseline.maxAge), now: now), 58)
        XCTAssertNil(RestingBaseline.current(saved: 58, savedAt: now.addingTimeInterval(-RestingBaseline.maxAge - 1), now: now))
        XCTAssertNil(RestingBaseline.current(saved: 58, savedAt: nil, now: now))
        XCTAssertNil(RestingBaseline.current(saved: nil, savedAt: now, now: now))
        XCTAssertNil(RestingBaseline.current(saved: 3, savedAt: now, now: now))
        XCTAssertEqual(RestingBaseline.current(saved: 58, savedAt: now.addingTimeInterval(600), now: now), 58)
    }

    func testOlderAnswerNeverReplacesNewerSave() {
        XCTAssertTrue(RestingBaseline.shouldReplace(savedAt: nil, with: base))
        XCTAssertTrue(RestingBaseline.shouldReplace(savedAt: base, with: base.addingTimeInterval(1)))
        XCTAssertFalse(RestingBaseline.shouldReplace(savedAt: base, with: base.addingTimeInterval(-1)))
    }

    func testRefreshOnlyWhenMissingOrOld() {
        XCTAssertTrue(RestingBaseline.needsRefresh(savedAt: nil, now: base))
        XCTAssertFalse(RestingBaseline.needsRefresh(savedAt: base.addingTimeInterval(-3_600), now: base))
        XCTAssertTrue(RestingBaseline.needsRefresh(savedAt: base.addingTimeInterval(-7 * 3_600), now: base))
    }

    // MARK: Haptic

    func testHapticOncePerSessionNotOnEveryReadingOrReconnect() {
        var gate = LiveHapticGate()
        XCTAssertFalse(gate.update(live: false, listening: true, now: at(0)))
        XCTAssertTrue(gate.update(live: true, listening: true, now: at(0.1)))
        XCTAssertFalse(gate.update(live: true, listening: true, now: at(0.2)))
        // Drop and reconnect in the same session, even much later.
        XCTAssertFalse(gate.update(live: false, listening: true, now: at(1)))
        XCTAssertFalse(gate.update(live: true, listening: true, now: at(1.1)))
        XCTAssertFalse(gate.update(live: false, listening: true, now: at(20)))
        XCTAssertFalse(gate.update(live: true, listening: true, now: at(21)))
    }

    func testHapticAgainInANewSessionOutsideTheQuietPeriod() {
        var gate = LiveHapticGate()
        XCTAssertTrue(gate.update(live: true, listening: true, now: at(0)))
        XCTAssertFalse(gate.update(live: false, listening: false, now: at(30)))
        XCTAssertTrue(gate.update(live: true, listening: true, now: at(60)))
    }

    func testNoHapticWhenSessionFlapsWithinQuietPeriod() {
        var gate = LiveHapticGate()
        XCTAssertTrue(gate.update(live: true, listening: true, now: at(0)))
        XCTAssertFalse(gate.update(live: false, listening: false, now: at(0.5)))
        XCTAssertFalse(gate.update(live: true, listening: true, now: at(1)))
        // Still that session: no catch-up haptic once the quiet period has passed.
        XCTAssertFalse(gate.update(live: true, listening: true, now: at(5)))
    }

    func testNoHapticWhileNotListening() {
        var gate = LiveHapticGate()
        XCTAssertFalse(gate.update(live: true, listening: false, now: at(0)))
        XCTAssertTrue(gate.update(live: true, listening: true, now: at(0.1)))
    }

    // MARK: Stats

    func testStatsTopUpOnlyNewerReadingsInsideWindow() {
        let stored = [HeartRatePoint(bpm: 60, at: at(0)), HeartRatePoint(bpm: 80, at: at(1))]
        let stats = HeartRateStats(stored)
        XCTAssertEqual(stats.through, at(1))
        let recent = [
            HeartRatePoint(bpm: 80, at: at(1)), // already counted
            HeartRatePoint(bpm: 90, at: at(2)),
            HeartRatePoint(bpm: 200, at: at(40)), // after the window
        ]
        let topped = stats.adding(recent, within: at(0)...at(30))
        XCTAssertEqual(topped.count, 3)
        let summary = try? XCTUnwrap(topped.summary)
        XCTAssertEqual(summary?.min, 60)
        XCTAssertEqual(summary?.avg, 77)
        XCTAssertEqual(summary?.max, 90)
        XCTAssertNil(HeartRateStats().summary)
    }

    // MARK: Chart

    func testChartMarksTheMeetingUnderwayOrMostRecentInRange() throws {
        let earlier = try meeting("Earlier", -60, -30)
        let ended = try meeting("Ended", -20, -5)
        let underway = try meeting("Underway", -8, 22)
        let later = try meeting("Later", 30, 60)
        let range = (at(-15))...(at(0))
        XCTAssertEqual(LiveChart.meeting(in: MeetingSchedule([earlier, ended, underway, later]), range: range), underway)
        XCTAssertEqual(LiveChart.meeting(in: MeetingSchedule([earlier, ended, later]), range: range), ended)
        XCTAssertNil(LiveChart.meeting(in: MeetingSchedule([earlier, later]), range: range))
        XCTAssertNil(LiveChart.meeting(in: MeetingSchedule(), range: range))
    }

    func testChartPrefersTheLaterStartWhenMeetingsOverlap() throws {
        let long = try meeting("Long", -40, 20)
        let short = try meeting("Short", -5, 10)
        let range = (at(-15))...(at(0))
        XCTAssertEqual(LiveChart.meeting(in: MeetingSchedule([long, short]), range: range), short)
    }

    func testShadingClipsToRange() throws {
        let range = (at(-15))...(at(0))
        XCTAssertEqual(LiveChart.shaded(try meeting("A", -8, 22), in: range), at(-8)...at(0))
        XCTAssertEqual(LiveChart.shaded(try meeting("B", -40, 20), in: range), at(-15)...at(0))
        XCTAssertEqual(LiveChart.shaded(try meeting("C", -20, -5), in: range), at(-15)...at(-5))
        XCTAssertNil(LiveChart.shaded(try meeting("D", -40, -20), in: range))
    }

    func testStatsWindowAndTitle() throws {
        let range = (at(-15))...(at(0))
        let underway = try meeting("Underway", -40, 20)
        XCTAssertEqual(LiveChart.statsWindow(meeting: underway, range: range), at(-40)...at(0))
        XCTAssertEqual(LiveChart.statsWindow(meeting: try meeting("Ended", -20, -5), range: range), at(-20)...at(-5))
        XCTAssertEqual(LiveChart.statsWindow(meeting: nil, range: range), range)
        XCTAssertTrue(LiveChart.needsStoredReadings(meeting: underway, range: range))
        XCTAssertFalse(LiveChart.needsStoredReadings(meeting: try meeting("Short", -5, 10), range: range))
        XCTAssertEqual(LiveChart.statsTitle(meeting: underway), "This meeting")
        XCTAssertEqual(LiveChart.statsTitle(meeting: nil), "Last 15 min")
    }

    func testHistoryStatsCoverOnlyTheMeetingWindow() {
        let readings = [
            HeartRatePoint(bpm: 60, at: at(-14)),
            HeartRatePoint(bpm: 90, at: at(-4)),
            HeartRatePoint(bpm: 100, at: at(-1)),
        ]
        let range = (at(-15))...(at(0))
        let all = HeartRateHistory(readings: readings, range: range, meetingWindow: nil)
        XCTAssertEqual(all.stats?.min, 60)
        let meeting = HeartRateHistory(readings: readings, range: range, meetingWindow: at(-5)...at(20))
        XCTAssertEqual(meeting.stats?.min, 90)
        XCTAssertEqual(meeting.stats?.max, 100)
        XCTAssertEqual(meeting.meetingWindow, at(-5)...at(20))
        XCTAssertNil(meeting.meeting)
        // The plotted range and y scale still cover every reading.
        XCTAssertEqual(meeting.points.count, 3)
        XCTAssertEqual(meeting.bpmRange, 55...105)
    }

    func testMacMeetingThatEndsBeforeItStartsStillHasNoStats() throws {
        let readings = [HeartRatePoint(bpm: 60, at: at(-14)), HeartRatePoint(bpm: 90, at: at(-4))]
        let json = #"{"id":"m","title":"Bad","startUtc":"2027-01-15T08:00:00Z","endUtc":"2027-01-15T07:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let broken = try decoder.decode(LiveMeeting.self, from: Data(json.utf8))
        let history = HeartRateHistory(readings: readings, range: (at(-15))...(at(0)), meeting: broken)
        XCTAssertNil(history.stats)
        XCTAssertNil(history.meetingWindow)
    }
}
