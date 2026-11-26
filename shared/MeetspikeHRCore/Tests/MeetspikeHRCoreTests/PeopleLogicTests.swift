import Foundation
import XCTest
@testable import MeetspikeHRCore

// People track: range presets, custom date validation, search cache, sparkline, per-day average, paging.
// Mirrors public/people-ui.js and the people code in public/app.js (findPeople, person page).

final class PeopleRangeTests: XCTestCase {
    func testDefaultIs28Days() {
        XCTAssertEqual(PeopleRange.default, .preset(.days28))
    }

    func testPresetRawValuesAndOrder() {
        XCTAssertEqual(PeopleRangePreset.allCases.map(\.rawValue), ["7d", "28d", "90d", "year"])
    }

    func testMenuLabels() {
        XCTAssertEqual(PeopleRangePreset.allCases.map(\.menuLabel), ["Past 7 days", "Past 28 days", "Past 90 days", "Past year"])
    }

    func testScopeLabels() {
        XCTAssertEqual(PeopleRangePreset.allCases.map(\.scopeLabel), ["Last 7 days", "Last 28 days", "Last 90 days", "Last year"])
    }

    func testDayCounts() {
        XCTAssertEqual(PeopleRangePreset.allCases.map(\.days), [7, 28, 90, 365])
    }

    func testPresetDatesEndTodayAndCountToday() {
        let today = "2026-11-24"
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.days7), today: today), DatesSpan(start: "2026-11-18", end: today))
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.days28), today: today), DatesSpan(start: "2026-10-28", end: today))
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.days90), today: today), DatesSpan(start: "2026-08-27", end: today))
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.year), today: today), DatesSpan(start: "2025-11-25", end: today))
    }

    func testPresetSpansHaveTheRightLength() {
        for preset in PeopleRangePreset.allCases {
            XCTAssertEqual(PeopleLogic.dates(for: .preset(preset), today: "2026-11-24").dayCount, preset.days, preset.rawValue)
        }
    }

    func testPresetDatesAcrossAYearBoundary() {
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.days28), today: "2026-01-10"), DatesSpan(start: "2025-12-14", end: "2026-01-10"))
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.days7), today: "2026-01-03"), DatesSpan(start: "2025-12-28", end: "2026-01-03"))
    }

    func testYearPresetAcrossALeapDay() {
        XCTAssertEqual(PeopleLogic.dates(for: .preset(.year), today: "2028-03-01"), DatesSpan(start: "2027-03-03", end: "2028-03-01"))
    }

    func testCustomReturnsItsOwnDates() {
        let range = PeopleRange.custom(start: "2026-02-01", end: "2026-03-15")
        XCTAssertEqual(PeopleLogic.dates(for: range, today: "2026-11-24"), DatesSpan(start: "2026-02-01", end: "2026-03-15"))
    }
}

final class PeopleCustomDatesTests: XCTestCase {
    func testTwoRealDaysInOrder() {
        XCTAssertTrue(PeopleLogic.validCustomDates(start: "2026-02-01", end: "2026-03-15"))
    }

    func testSameDayIsFine() {
        XCTAssertTrue(PeopleLogic.validCustomDates(start: "2026-02-01", end: "2026-02-01"))
    }

    func testStartAfterEndIsRejected() {
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-03-15", end: "2026-02-01"))
    }

    func testMissingDatesAreRejected() {
        XCTAssertFalse(PeopleLogic.validCustomDates(start: nil, end: "2026-02-01"))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-02-01", end: nil))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: nil, end: nil))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "", end: ""))
    }

    func testImpossibleDaysAreRejected() {
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-02-30", end: "2026-03-01"))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-02-01", end: "2026-13-01"))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-02-29", end: "2026-03-01"))
        XCTAssertTrue(PeopleLogic.validCustomDates(start: "2028-02-29", end: "2028-03-01"))
    }

    func testBadFormatsAreRejected() {
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-2-1", end: "2026-03-01"))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "02/01/2026", end: "03/01/2026"))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-02-01T00:00:00Z", end: "2026-03-01"))
    }

    func testYearBounds() {
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "0099-12-31", end: "2026-03-01"))
        XCTAssertTrue(PeopleLogic.validCustomDates(start: "0100-01-01", end: "2026-03-01"))
        XCTAssertTrue(PeopleLogic.validCustomDates(start: "2026-03-01", end: "9999-12-30"))
        XCTAssertFalse(PeopleLogic.validCustomDates(start: "2026-03-01", end: "9999-12-31"))
    }
}

final class PeopleSearchCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func matches(_ names: String...) -> [PersonMatch] {
        names.map { PersonMatch(email: "\($0.lowercased())@example.com", name: $0) }
    }

    func testMissOnAnEmptyCache() {
        XCTAssertNil(PeopleSearchCache().people(for: "dana", now: t0))
    }

    func testStoredAnswerComesBack() {
        var cache = PeopleSearchCache()
        cache.store(matches("Dana"), for: "dana", now: t0)
        XCTAssertEqual(cache.people(for: "dana", now: t0.addingTimeInterval(5)), matches("Dana"))
        XCTAssertEqual(cache.count, 1)
    }

    func testAnEmptyAnswerIsCachedToo() {
        var cache = PeopleSearchCache()
        cache.store([], for: "nobody", now: t0)
        XCTAssertEqual(cache.people(for: "nobody", now: t0.addingTimeInterval(1)), [])
    }

    func testFreshForUnderFiveMinutes() {
        var cache = PeopleSearchCache()
        cache.store(matches("Dana"), for: "dana", now: t0)
        XCTAssertNotNil(cache.people(for: "dana", now: t0.addingTimeInterval(299)))
    }

    func testStaleAtFiveMinutes() {
        var cache = PeopleSearchCache()
        cache.store(matches("Dana"), for: "dana", now: t0)
        XCTAssertNil(cache.people(for: "dana", now: t0.addingTimeInterval(300)))
        XCTAssertNil(cache.people(for: "dana", now: t0.addingTimeInterval(3600)))
    }

    func testStoringAgainRestartsTheFiveMinutes() {
        var cache = PeopleSearchCache()
        cache.store(matches("Dana"), for: "dana", now: t0)
        cache.store(matches("Dana", "Dan"), for: "dana", now: t0.addingTimeInterval(200))
        XCTAssertEqual(cache.people(for: "dana", now: t0.addingTimeInterval(400)), matches("Dana", "Dan"))
        XCTAssertEqual(cache.count, 1)
    }

    func testKeysIgnoreCase() {
        var cache = PeopleSearchCache()
        cache.store(matches("Dana"), for: "Dana", now: t0)
        XCTAssertNotNil(cache.people(for: "DANA", now: t0))
        XCTAssertNotNil(cache.people(for: "dana", now: t0))
    }

    func testKeysIgnoreUnicodeComposition() {
        var cache = PeopleSearchCache()
        cache.store(matches("Rene"), for: "caf\u{E9}", now: t0)
        XCTAssertNotNil(cache.people(for: "cafe\u{301}", now: t0))
    }

    func testHoldsAtMostFortyQueriesAndDropsTheOldest() {
        var cache = PeopleSearchCache()
        for i in 0...40 { cache.store(matches("P\(i)"), for: "q\(i)", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(cache.count, 40)
        XCTAssertNil(cache.people(for: "q0", now: t0.addingTimeInterval(41)))
        XCTAssertNotNil(cache.people(for: "q1", now: t0.addingTimeInterval(41)))
        XCTAssertNotNil(cache.people(for: "q40", now: t0.addingTimeInterval(41)))
    }

    func testFortyExactlyEvictsNothing() {
        var cache = PeopleSearchCache()
        for i in 0..<40 { cache.store(matches("P\(i)"), for: "q\(i)", now: t0) }
        XCTAssertEqual(cache.count, 40)
        XCTAssertNotNil(cache.people(for: "q0", now: t0))
    }

    func testStoringAnExistingQueryMovesItToTheNewestSlot() {
        var cache = PeopleSearchCache()
        for i in 0..<40 { cache.store(matches("P\(i)"), for: "q\(i)", now: t0) }
        cache.store(matches("Again"), for: "q0", now: t0)
        cache.store(matches("New"), for: "new", now: t0)
        XCTAssertEqual(cache.count, 40)
        XCTAssertNotNil(cache.people(for: "q0", now: t0), "re-stored query is the newest, so it survives")
        XCTAssertNil(cache.people(for: "q1", now: t0), "q1 became the oldest and was dropped")
        XCTAssertNotNil(cache.people(for: "new", now: t0))
    }

    func testRemoveAllForgetsEverything() {
        var cache = PeopleSearchCache()
        cache.store(matches("Dana"), for: "dana", now: t0)
        cache.store(matches("Sam"), for: "sam", now: t0)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.people(for: "dana", now: t0))
    }

    func testLimits() {
        XCTAssertEqual(PeopleLogic.searchCacheSeconds, 300)
        XCTAssertEqual(PeopleLogic.searchCacheLimit, 40)
    }
}

final class PeopleSparklineTests: XCTestCase {
    /// Newest first, like the Worker sends it: value i is its own index.
    private func values(_ n: Int) -> [Double] { (0..<n).map(Double.init) }

    func testEmptyAndSingle() {
        XCTAssertEqual(PeopleLogic.sparkline([]), [])
        XCTAssertEqual(PeopleLogic.sparkline([72]), [72])
    }

    func testShortSeriesIsReversedToRunOldestToNewest() {
        XCTAssertEqual(PeopleLogic.sparkline([5, 4, 3, 2, 1]), [1, 2, 3, 4, 5])
    }

    func testExactlyOneTwentyKeepsEveryPoint() {
        let spark = PeopleLogic.sparkline(values(120))
        XCTAssertEqual(spark.count, 120)
        XCTAssertEqual(spark.first, 119)
        XCTAssertEqual(spark.last, 0)
    }

    func testOneOverOneTwentyTakesEverySecondValue() {
        let spark = PeopleLogic.sparkline(values(121))
        XCTAssertEqual(spark.count, 61)
        XCTAssertEqual(spark.last, 0, "the newest reading is always kept")
        XCTAssertEqual(spark.first, 120)
    }

    func testTwoFortyTakesEverySecondValue() {
        let spark = PeopleLogic.sparkline(values(240))
        XCTAssertEqual(spark.count, 120)
        XCTAssertEqual(spark.first, 238)
        XCTAssertEqual(spark.last, 0)
    }

    func testTwoFortyOneTakesEveryThirdValue() {
        let spark = PeopleLogic.sparkline(values(241))
        XCTAssertEqual(spark.count, 81)
        XCTAssertEqual(spark.first, 240)
        XCTAssertEqual(spark.last, 0)
    }

    func testBigSeriesStaysUnderTheTarget() {
        for n in [500, 1000, 5000] {
            let spark = PeopleLogic.sparkline(values(n))
            XCTAssertLessThanOrEqual(spark.count, 120, "n=\(n)")
            XCTAssertEqual(spark.last, 0, "n=\(n)")
        }
        XCTAssertEqual(PeopleLogic.sparkline(values(1000)).count, 112)
    }

    func testKeptValuesAreInOrderOldestToNewest() {
        let spark = PeopleLogic.sparkline(values(1000))
        XCTAssertEqual(spark.count, 112)
        XCTAssertEqual(spark, spark.sorted(by: >), "values were their own index, so older readings are larger")
    }

    func testCustomTarget() {
        let spark = PeopleLogic.sparkline(values(25), target: 10)
        XCTAssertEqual(spark.count, 9)
        XCTAssertEqual(spark.last, 0)
        XCTAssertEqual(spark.first, 24)
    }

    func testTargetConstant() {
        XCTAssertEqual(PeopleLogic.sparklineTarget, 120)
    }
}

final class PeoplePerDayAverageTests: XCTestCase {
    private func meeting(_ id: String, day: String, score: Double?) -> PersonMeeting {
        PersonMeeting(id: id, day: day, nextReadinessScore: score)
    }

    func testNoMeetings() {
        XCTAssertEqual(PeopleLogic.perDayAverage([]), PeoplePerDayAverage(average: nil, mornings: 0))
    }

    func testMeetingsWithoutScoresGiveNothing() {
        let result = PeopleLogic.perDayAverage([meeting("a", day: "2026-11-01", score: nil)])
        XCTAssertEqual(result, PeoplePerDayAverage(average: nil, mornings: 0))
    }

    func testEachDayCountsOnce() {
        // Three meetings on Nov 1 must weigh the same as one: the morning after is a single score.
        let result = PeopleLogic.perDayAverage([
            meeting("a", day: "2026-11-01", score: 90),
            meeting("b", day: "2026-11-01", score: 90),
            meeting("c", day: "2026-11-01", score: 90),
            meeting("d", day: "2026-11-02", score: 60),
        ])
        XCTAssertEqual(result.mornings, 2)
        XCTAssertEqual(result.average, 75)
    }

    func testTheLastMeetingOfTheDayInListOrderWins() {
        let result = PeopleLogic.perDayAverage([
            meeting("a", day: "2026-11-01", score: 80),
            meeting("b", day: "2026-11-01", score: 60),
        ])
        XCTAssertEqual(result.average, 60)
        XCTAssertEqual(result.mornings, 1)
    }

    func testAMeetingWithoutAScoreDoesNotEraseTheDaysScore() {
        let result = PeopleLogic.perDayAverage([
            meeting("a", day: "2026-11-01", score: 60),
            meeting("b", day: "2026-11-01", score: nil),
        ])
        XCTAssertEqual(result.average, 60)
        XCTAssertEqual(result.mornings, 1)
    }

    func testMeanRoundsToAWholeNumber() {
        let half = PeopleLogic.perDayAverage([
            meeting("a", day: "2026-11-01", score: 70),
            meeting("b", day: "2026-11-02", score: 71),
        ])
        XCTAssertEqual(half.average, 71)
        let third = PeopleLogic.perDayAverage([
            meeting("a", day: "2026-11-01", score: 70),
            meeting("b", day: "2026-11-02", score: 70),
            meeting("c", day: "2026-11-03", score: 71),
        ])
        XCTAssertEqual(third.average, 70)
    }

    func testFewerThanFourMorningsIsOnlyAHint() {
        func result(_ days: Int) -> PeoplePerDayAverage {
            PeopleLogic.perDayAverage((1...max(days, 1)).filter { $0 <= days }.map {
                meeting("m\($0)", day: String(format: "2026-11-%02d", $0), score: 70)
            })
        }
        XCTAssertFalse(result(0).isThin)
        XCTAssertTrue(result(1).isThin)
        XCTAssertTrue(result(3).isThin)
        XCTAssertFalse(result(4).isThin)
        XCTAssertEqual(result(4).mornings, 4)
        XCTAssertEqual(result(4).average, 70)
    }
}

final class PeoplePagerTests: XCTestCase {
    private let items = Array(0..<100)

    func testFirstPageIsForty() {
        let pager = PeoplePager()
        XCTAssertEqual(pager.shown, 40)
        XCTAssertEqual(Array(pager.visible(items)), Array(0..<40))
    }

    func testShortListShowsEverything() {
        let pager = PeoplePager()
        XCTAssertEqual(Array(pager.visible(Array(0..<7))), Array(0..<7))
        XCTAssertEqual(Array(pager.visible([Int]())), [])
    }

    func testHasMoreOnlyWhenThereAreMoreThanShown() {
        let pager = PeoplePager()
        XCTAssertFalse(pager.hasMore(total: 0))
        XCTAssertFalse(pager.hasMore(total: 40))
        XCTAssertTrue(pager.hasMore(total: 41))
    }

    func testShowMoreAddsFortyEachTime() {
        var pager = PeoplePager()
        pager.showMore()
        XCTAssertEqual(pager.shown, 80)
        XCTAssertEqual(Array(pager.visible(items)).count, 80)
        XCTAssertTrue(pager.hasMore(total: 100))
        pager.showMore()
        XCTAssertEqual(pager.shown, 120)
        XCTAssertEqual(Array(pager.visible(items)).count, 100)
        XCTAssertFalse(pager.hasMore(total: 100))
    }

    func testResetGoesBackToTheFirstPage() {
        var pager = PeoplePager()
        pager.showMore()
        pager.showMore()
        pager.reset()
        XCTAssertEqual(pager.shown, 40)
        XCTAssertEqual(Array(pager.visible(items)).count, 40)
    }

    func testPageSizeConstant() {
        XCTAssertEqual(PeopleLogic.pageSize, 40)
    }
}
