import Foundation
import XCTest
@testable import MeetspikeHRCore

// Today track: recovery bands, heavy day, trend rows. Mirrors band(), metricRow() and the heavy check in public/app.js.

final class TodayRecoveryBandTests: XCTestCase {
    func testWhoopTopBand() {
        for score in [67.0, 67.5, 80, 100] {
            XCTAssertEqual(TodayLogic.recoveryBand(score: score, wearable: .whoop), TodayBand(tone: .good, word: "Good"), "\(score)")
        }
    }

    func testWhoopMiddleBand() {
        for score in [34.0, 50, 66, 66.9] {
            XCTAssertEqual(TodayLogic.recoveryBand(score: score, wearable: .whoop), TodayBand(tone: .warn, word: "Fair"), "\(score)")
        }
    }

    func testWhoopLowBand() {
        for score in [33.9, 20, 0] {
            XCTAssertEqual(TodayLogic.recoveryBand(score: score, wearable: .whoop), TodayBand(tone: .bad, word: "Low"), "\(score)")
        }
    }

    func testOuraTopBand() {
        for score in [85.0, 90, 100] {
            XCTAssertEqual(TodayLogic.recoveryBand(score: score, wearable: .oura), TodayBand(tone: .good, word: "Optimal"), "\(score)")
        }
    }

    func testOuraMiddleBand() {
        for score in [70.0, 77, 84, 84.9] {
            XCTAssertEqual(TodayLogic.recoveryBand(score: score, wearable: .oura), TodayBand(tone: .warn, word: "Fair"), "\(score)")
        }
    }

    func testOuraLowBand() {
        for score in [69.9, 40, 0] {
            XCTAssertEqual(TodayLogic.recoveryBand(score: score, wearable: .oura), TodayBand(tone: .bad, word: "Low"), "\(score)")
        }
    }

    func testSameScoreReadsDifferentlyPerWearable() {
        XCTAssertEqual(TodayLogic.recoveryBand(score: 72, wearable: .whoop)?.tone, .good)
        XCTAssertEqual(TodayLogic.recoveryBand(score: 72, wearable: .oura)?.tone, .warn)
    }

    func testNilScoreHasNoBand() {
        XCTAssertNil(TodayLogic.recoveryBand(score: nil, wearable: .whoop))
        XCTAssertNil(TodayLogic.recoveryBand(score: nil, wearable: .oura))
        XCTAssertNil(TodayLogic.recoveryBand(score: nil, wearable: nil))
    }

    func testNilWearableReadsAsWhoop() {
        XCTAssertEqual(TodayLogic.recoveryBand(score: 67, wearable: nil), TodayBand(tone: .good, word: "Good"))
        XCTAssertEqual(TodayLogic.recoveryBand(score: 66, wearable: nil), TodayBand(tone: .warn, word: "Fair"))
        XCTAssertEqual(TodayLogic.recoveryBand(score: 33, wearable: nil), TodayBand(tone: .bad, word: "Low"))
    }
}

final class TodayHeavyDayTests: XCTestCase {
    func testFourHoursIsHeavy() {
        XCTAssertTrue(TodayLogic.isHeavyDay(totalDurationS: 14_400, eventCount: 1))
        XCTAssertTrue(TodayLogic.isHeavyDay(totalDurationS: 20_000, eventCount: 2))
    }

    func testJustUnderFourHoursIsNotHeavy() {
        XCTAssertFalse(TodayLogic.isHeavyDay(totalDurationS: 14_399, eventCount: 4))
    }

    func testFiveMeetingsIsHeavy() {
        XCTAssertTrue(TodayLogic.isHeavyDay(totalDurationS: 1_500, eventCount: 5))
        XCTAssertTrue(TodayLogic.isHeavyDay(totalDurationS: 0, eventCount: 9))
    }

    func testFourShortMeetingsIsNotHeavy() {
        XCTAssertFalse(TodayLogic.isHeavyDay(totalDurationS: 3_600, eventCount: 4))
    }

    func testNilCountsAsZero() {
        XCTAssertFalse(TodayLogic.isHeavyDay(totalDurationS: nil, eventCount: nil))
        XCTAssertTrue(TodayLogic.isHeavyDay(totalDurationS: nil, eventCount: 5))
        XCTAssertTrue(TodayLogic.isHeavyDay(totalDurationS: 14_400, eventCount: nil))
        XCTAssertFalse(TodayLogic.isHeavyDay(totalDurationS: nil, eventCount: 4))
    }

    func testConstantsMatchTheWeb() {
        XCTAssertEqual(TodayLogic.heavyDurationS, 14_400)
        XCTAssertEqual(TodayLogic.heavyMeetingCount, 5)
    }
}

final class TodayTrendTests: XCTestCase {
    func testStepConstantsMatchTheWeb() {
        XCTAssertEqual(TodayLogic.recoveryStep, 3)
        XCTAssertEqual(TodayLogic.hrvStep, 2)
        XCTAssertEqual(TodayLogic.restingHrStep, 1)
        XCTAssertEqual(TodayLogic.meetingHoursStep, 0.5)
    }

    // MARK: Hidden rows

    func testNoValueHidesTheRow() {
        XCTAssertNil(TodayLogic.metricTrend(value: nil, usual: 60, step: 3, higherIs: .better))
        XCTAssertNil(TodayLogic.metricTrend(value: nil, usual: nil, step: 3, higherIs: .better))
    }

    func testZeroWithNoUsualHidesTheRow() {
        XCTAssertNil(TodayLogic.metricTrend(value: 0, usual: nil, step: 1, higherIs: .worse))
        XCTAssertNil(TodayLogic.metricTrend(value: 0, usual: 0, step: 1, higherIs: .worse))
    }

    func testZeroAgainstARealUsualStillShows() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 0, usual: 4, step: 0.5, higherIs: .worse, words: .moreFewer))
        XCTAssertEqual(trend, TodayTrend(direction: .down, tone: .good, text: "fewer"))
    }

    func testNoUsualShowsNoComparison() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 72, usual: nil, step: 3, higherIs: .better))
        XCTAssertEqual(trend, TodayTrend(direction: .none, tone: .flat, text: ""))
    }

    // MARK: Recovery, step 3, higher is better

    func testRecoveryAboveUsualByTheStepIsUpAndGood() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 70, usual: 67, step: TodayLogic.recoveryStep, higherIs: .better))
        XCTAssertEqual(trend, TodayTrend(direction: .up, tone: .good, text: "higher"))
    }

    func testRecoveryBelowUsualByTheStepIsDownAndBad() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 64, usual: 67, step: TodayLogic.recoveryStep, higherIs: .better))
        XCTAssertEqual(trend, TodayTrend(direction: .down, tone: .bad, text: "lower"))
    }

    func testRecoveryInsideTheStepReadsUsual() throws {
        for value in [65.0, 66.5, 67, 69.9] {
            let trend = try XCTUnwrap(TodayLogic.metricTrend(value: value, usual: 67, step: TodayLogic.recoveryStep, higherIs: .better))
            XCTAssertEqual(trend, TodayTrend(direction: .usual, tone: .flat, text: "usual"), "\(value)")
        }
    }

    // MARK: HRV, step 2

    func testHrvStep() throws {
        XCTAssertEqual(
            try XCTUnwrap(TodayLogic.metricTrend(value: 52, usual: 50, step: TodayLogic.hrvStep, higherIs: .better)),
            TodayTrend(direction: .up, tone: .good, text: "higher"))
        XCTAssertEqual(
            try XCTUnwrap(TodayLogic.metricTrend(value: 48, usual: 50, step: TodayLogic.hrvStep, higherIs: .better)),
            TodayTrend(direction: .down, tone: .bad, text: "lower"))
        XCTAssertEqual(
            try XCTUnwrap(TodayLogic.metricTrend(value: 51.9, usual: 50, step: TodayLogic.hrvStep, higherIs: .better)).text, "usual")
    }

    // MARK: Resting heart rate, step 1, lower is better

    func testRestingHrAboveUsualIsBad() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 60, usual: 58, step: TodayLogic.restingHrStep, higherIs: .worse))
        XCTAssertEqual(trend, TodayTrend(direction: .up, tone: .bad, text: "higher"))
    }

    func testRestingHrBelowUsualIsGood() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 57, usual: 58, step: TodayLogic.restingHrStep, higherIs: .worse))
        XCTAssertEqual(trend, TodayTrend(direction: .down, tone: .good, text: "lower"))
    }

    func testRestingHrWithinOneBpmReadsUsual() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(value: 58.9, usual: 58, step: TodayLogic.restingHrStep, higherIs: .worse))
        XCTAssertEqual(trend, TodayTrend(direction: .usual, tone: .flat, text: "usual"))
    }

    // MARK: Meeting hours, step 0.5, more/fewer

    func testMeetingHoursMoreThanUsualIsBad() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(
            value: 4.5, usual: 4, step: TodayLogic.meetingHoursStep, higherIs: .worse, words: .moreFewer))
        XCTAssertEqual(trend, TodayTrend(direction: .up, tone: .bad, text: "more"))
    }

    func testMeetingHoursFewerThanUsualIsGood() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(
            value: 3.5, usual: 4, step: TodayLogic.meetingHoursStep, higherIs: .worse, words: .moreFewer))
        XCTAssertEqual(trend, TodayTrend(direction: .down, tone: .good, text: "fewer"))
    }

    func testMeetingHoursWithinHalfAnHourReadsUsual() throws {
        let trend = try XCTUnwrap(TodayLogic.metricTrend(
            value: 4.4, usual: 4, step: TodayLogic.meetingHoursStep, higherIs: .worse, words: .moreFewer))
        XCTAssertEqual(trend.text, "usual")
        XCTAssertEqual(trend.direction, .usual)
    }

    // MARK: Neutral

    func testNeutralMetricIsNeverGoodOrBad() throws {
        let up = try XCTUnwrap(TodayLogic.metricTrend(value: 20, usual: 10, step: 1, higherIs: .neutral))
        let down = try XCTUnwrap(TodayLogic.metricTrend(value: 5, usual: 10, step: 1, higherIs: .neutral))
        XCTAssertEqual(up, TodayTrend(direction: .up, tone: .flat, text: "higher"))
        XCTAssertEqual(down, TodayTrend(direction: .down, tone: .flat, text: "lower"))
    }

    func testWordsPresets() {
        XCTAssertEqual(TodayTrendWords.higherLower, TodayTrendWords(up: "higher", down: "lower"))
        XCTAssertEqual(TodayTrendWords.moreFewer, TodayTrendWords(up: "more", down: "fewer"))
    }
}
