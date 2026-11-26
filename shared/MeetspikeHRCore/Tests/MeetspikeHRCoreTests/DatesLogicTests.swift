import Foundation
import XCTest
@testable import MeetspikeHRCore

// Dates track: span shifting, quick chips, lowest days, picker. Mirrors stepDates, renderPicker, pickDay and
// recoveryChart in public/app.js and range-presets.js. `today` is always the server's today.

private func span(_ start: String, _ end: String) -> DatesSpan { DatesSpan(start: start, end: end) }

final class DatesShiftTests: XCTestCase {
    func testBackMovesOneFullSpan() {
        XCTAssertEqual(DatesLogic.shift(span("2026-11-10", "2026-11-16"), direction: -1, today: "2026-11-24"), span("2026-11-03", "2026-11-09"))
    }

    func testForwardMovesOneFullSpan() {
        XCTAssertEqual(DatesLogic.shift(span("2026-11-03", "2026-11-09"), direction: 1, today: "2026-11-24"), span("2026-11-10", "2026-11-16"))
    }

    func testForwardNeverPassesToday() {
        // Nov 10 to 16 forward would end Nov 23, but today is Nov 18: clamp, keep seven days.
        let shifted = DatesLogic.shift(span("2026-11-10", "2026-11-16"), direction: 1, today: "2026-11-18")
        XCTAssertEqual(shifted, span("2026-11-12", "2026-11-18"))
        XCTAssertEqual(shifted.dayCount, 7)
    }

    func testForwardLandingExactlyOnTodayIsNotClamped() {
        XCTAssertEqual(DatesLogic.shift(span("2026-11-10", "2026-11-16"), direction: 1, today: "2026-11-23"), span("2026-11-17", "2026-11-23"))
    }

    func testForwardFromASpanEndingTodayStaysPut() {
        XCTAssertEqual(DatesLogic.shift(span("2026-11-18", "2026-11-24"), direction: 1, today: "2026-11-24"), span("2026-11-18", "2026-11-24"))
    }

    func testSingleDayStepsByOneDay() {
        XCTAssertEqual(DatesLogic.shift(span("2026-11-24", "2026-11-24"), direction: -1, today: "2026-11-24"), span("2026-11-23", "2026-11-23"))
        XCTAssertEqual(DatesLogic.shift(span("2026-11-22", "2026-11-22"), direction: 1, today: "2026-11-24"), span("2026-11-23", "2026-11-23"))
        XCTAssertEqual(DatesLogic.shift(span("2026-11-24", "2026-11-24"), direction: 1, today: "2026-11-24"), span("2026-11-24", "2026-11-24"))
    }

    func testBackAcrossAYearBoundary() {
        XCTAssertEqual(DatesLogic.shift(span("2026-01-01", "2026-01-07"), direction: -1, today: "2026-06-01"), span("2025-12-25", "2025-12-31"))
    }

    func testBackAcrossALeapDay() {
        XCTAssertEqual(DatesLogic.shift(span("2028-03-01", "2028-03-01"), direction: -1, today: "2028-06-01"), span("2028-02-29", "2028-02-29"))
    }

    func testForwardAcrossAMonthBoundary() {
        XCTAssertEqual(DatesLogic.shift(span("2026-10-25", "2026-10-31"), direction: 1, today: "2026-12-01"), span("2026-11-01", "2026-11-07"))
    }

    func testBackIsNotClampedToAnything() {
        // The span may already end after "today" only through a bad URL, but going back keeps its length.
        let shifted = DatesLogic.shift(span("2026-11-10", "2026-11-12"), direction: -1, today: "2026-11-24")
        XCTAssertEqual(shifted, span("2026-11-07", "2026-11-09"))
        XCTAssertEqual(shifted.dayCount, 3)
    }

    func testCanGoNextOnlyWhileTheSpanEndsBeforeToday() {
        XCTAssertTrue(DatesLogic.canGoNext(span("2026-11-10", "2026-11-16"), today: "2026-11-24"))
        XCTAssertTrue(DatesLogic.canGoNext(span("2026-11-17", "2026-11-23"), today: "2026-11-24"))
        XCTAssertFalse(DatesLogic.canGoNext(span("2026-11-18", "2026-11-24"), today: "2026-11-24"))
        XCTAssertFalse(DatesLogic.canGoNext(span("2026-11-24", "2026-11-24"), today: "2026-11-24"))
    }
}

final class DatesQuickChipTests: XCTestCase {
    private func chips(_ today: String) -> [String: DatesSpan] {
        Dictionary(uniqueKeysWithValues: DatesLogic.quickChips(today: today).map { ($0.label, $0.span) })
    }

    func testChipOrderAndLabels() {
        XCTAssertEqual(
            DatesLogic.quickChips(today: "2026-11-24").map(\.label),
            ["Today", "Yesterday", "Last 7 days", "Last 30 days", "This month", "Last month"])
    }

    func testRangesForAMidMonthDay() {
        let c = chips("2026-11-24")
        XCTAssertEqual(c["Today"], span("2026-11-24", "2026-11-24"))
        XCTAssertEqual(c["Yesterday"], span("2026-11-23", "2026-11-23"))
        XCTAssertEqual(c["Last 7 days"], span("2026-11-18", "2026-11-24"))
        XCTAssertEqual(c["Last 30 days"], span("2026-10-26", "2026-11-24"))
        XCTAssertEqual(c["This month"], span("2026-11-01", "2026-11-24"))
        XCTAssertEqual(c["Last month"], span("2026-10-01", "2026-10-31"))
    }

    func testLastMonthAcrossAYearBoundary() {
        let c = chips("2026-01-15")
        XCTAssertEqual(c["Last month"], span("2025-12-01", "2025-12-31"))
        XCTAssertEqual(c["Yesterday"], span("2026-01-14", "2026-01-14"))
        XCTAssertEqual(c["Last 7 days"], span("2026-01-09", "2026-01-15"))
        XCTAssertEqual(c["Last 30 days"], span("2025-12-17", "2026-01-15"))
        XCTAssertEqual(c["This month"], span("2026-01-01", "2026-01-15"))
    }

    func testYesterdayAcrossAYearBoundary() {
        XCTAssertEqual(chips("2026-01-01")["Yesterday"], span("2025-12-31", "2025-12-31"))
    }

    func testThisMonthOnTheFirstIsOneDayNeverFuture() {
        XCTAssertEqual(chips("2026-03-01")["This month"], span("2026-03-01", "2026-03-01"))
    }

    func testLastMonthKnowsMonthLengths() {
        XCTAssertEqual(chips("2026-03-10")["Last month"], span("2026-02-01", "2026-02-28"))
        XCTAssertEqual(chips("2028-03-10")["Last month"], span("2028-02-01", "2028-02-29"))
        XCTAssertEqual(chips("2026-05-10")["Last month"], span("2026-04-01", "2026-04-30"))
    }

    func testNoChipEndsAfterToday() {
        for today in ["2026-01-15", "2026-03-01", "2026-11-24", "2028-02-29"] {
            for chip in DatesLogic.quickChips(today: today) {
                XCTAssertLessThanOrEqual(chip.span.end, today, "\(chip.label) \(today)")
                XCTAssertLessThanOrEqual(chip.span.start, chip.span.end, "\(chip.label) \(today)")
            }
        }
    }
}

final class DatesLowestDaysTests: XCTestCase {
    private func series(_ values: [Double?]) throws -> [SeriesDay] {
        let rows = values.enumerated().map { index, value -> String in
            let day = String(format: "2026-11-%02d", index + 1)
            return value.map { #"{"day":"\#(day)","nextRecovery":\#($0)}"# } ?? #"{"day":"\#(day)"}"#
        }
        return try MobileJSON.decode([SeriesDay].self, "[" + rows.joined(separator: ",") + "]")
    }

    func testThreeLowestFirst() throws {
        let lows = DatesLogic.lowestRecoveryDays(try series([50, 40, 60, 45, 30]))
        XCTAssertEqual(lows, [
            DatesLowDay(index: 4, day: "2026-11-05", value: 30),
            DatesLowDay(index: 1, day: "2026-11-02", value: 40),
            DatesLowDay(index: 3, day: "2026-11-04", value: 45),
        ])
    }

    func testDaysWithoutAScoreAreSkippedButKeepTheirPosition() throws {
        let lows = DatesLogic.lowestRecoveryDays(try series([nil, 70, nil, 20, 55]))
        XCTAssertEqual(lows.map(\.index), [3, 4, 1])
        XCTAssertEqual(lows.map(\.value), [20, 55, 70])
    }

    func testTiesKeepTheEarlierDayFirst() throws {
        let lows = DatesLogic.lowestRecoveryDays(try series([40, 30, 40, 40, 90]))
        XCTAssertEqual(lows.map(\.index), [1, 0, 2])
    }

    func testFewerThanThreeScoredDays() throws {
        XCTAssertEqual(DatesLogic.lowestRecoveryDays(try series([nil, 80, nil, 60])).map(\.value), [60, 80])
        XCTAssertEqual(DatesLogic.lowestRecoveryDays(try series([55])).map(\.value), [55])
    }

    func testNothingScored() throws {
        XCTAssertEqual(DatesLogic.lowestRecoveryDays(try series([nil, nil])), [])
        XCTAssertEqual(DatesLogic.lowestRecoveryDays([]), [])
    }

    func testCustomLimit() throws {
        let values: [Double?] = [50, 40, 60, 45, 30]
        XCTAssertEqual(DatesLogic.lowestRecoveryDays(try series(values), limit: 1).map(\.value), [30])
        XCTAssertEqual(DatesLogic.lowestRecoveryDays(try series(values), limit: 5).map(\.value), [30, 40, 45, 50, 60])
    }

    func testZeroIsAScore() throws {
        XCTAssertEqual(DatesLogic.lowestRecoveryDays(try series([10, 0, 5])).map(\.value), [0, 5, 10])
    }
}

final class DatesDestinationTests: XCTestCase {
    func testOneDayGoesToToday() {
        XCTAssertEqual(DatesLogic.destination(for: span("2026-11-05", "2026-11-05")), .today("2026-11-05"))
    }

    func testARangeGoesToDates() {
        XCTAssertEqual(DatesLogic.destination(for: span("2026-11-05", "2026-11-10")), .dates(span("2026-11-05", "2026-11-10")))
    }

    func testSpanDayCount() {
        XCTAssertEqual(span("2026-11-05", "2026-11-05").dayCount, 1)
        XCTAssertEqual(span("2026-11-05", "2026-11-11").dayCount, 7)
        XCTAssertTrue(span("2026-11-05", "2026-11-05").isSingleDay)
    }
}

final class DatesPickerTests: XCTestCase {
    private let today = "2026-11-24"

    private func empty() -> DatesPicker { DatesPicker(start: nil, end: nil, today: "2026-11-24") }

    func testOpensOnTheMonthOfTheEnd() {
        XCTAssertEqual(DatesPicker(start: "2026-10-01", end: "2026-10-31", today: today).month, "2026-10")
        XCTAssertEqual(DatesPicker(start: nil, end: nil, today: today).month, "2026-11")
    }

    func testFirstTapStartsARangeAndWaitsForTheEnd() {
        var picker = empty()
        picker.pick("2026-11-05")
        XCTAssertEqual(picker.start, "2026-11-05")
        XCTAssertNil(picker.end)
        XCTAssertEqual(picker.editing, .end)
        XCTAssertNil(picker.span)
    }

    func testSecondTapSetsTheEnd() {
        var picker = empty()
        picker.pick("2026-11-05")
        picker.pick("2026-11-10")
        XCTAssertEqual(picker.span, span("2026-11-05", "2026-11-10"))
        XCTAssertNil(picker.editing)
    }

    func testSecondTapOnTheSameDayIsASingleDay() {
        var picker = empty()
        picker.pick("2026-11-05")
        picker.pick("2026-11-05")
        XCTAssertEqual(picker.span, span("2026-11-05", "2026-11-05"))
    }

    func testEndBeforeStartSwapsThem() {
        var picker = empty()
        picker.pick("2026-11-10")
        picker.pick("2026-11-05")
        XCTAssertEqual(picker.span, span("2026-11-05", "2026-11-10"))
        XCTAssertNil(picker.editing)
    }

    func testTappingAfterACompleteRangeStartsOver() {
        var picker = empty()
        picker.pick("2026-11-05")
        picker.pick("2026-11-10")
        picker.pick("2026-11-12")
        XCTAssertEqual(picker.start, "2026-11-12")
        XCTAssertNil(picker.end)
        XCTAssertEqual(picker.editing, .end)
    }

    func testEditingFromSetsTheStartWhenNotAfterTheEnd() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.start)
        XCTAssertEqual(picker.editing, .start)
        picker.pick("2026-11-08")
        XCTAssertEqual(picker.span, span("2026-11-08", "2026-11-10"))
        XCTAssertNil(picker.editing)
    }

    func testEditingFromOnTheEndDayIsAllowed() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.start)
        picker.pick("2026-11-10")
        XCTAssertEqual(picker.span, span("2026-11-10", "2026-11-10"))
    }

    func testEditingFromWithADayAfterTheEndStartsOver() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.start)
        picker.pick("2026-11-15")
        XCTAssertEqual(picker.start, "2026-11-15")
        XCTAssertNil(picker.end)
        XCTAssertEqual(picker.editing, .end)
    }

    func testEditingToSetsTheEnd() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.end)
        XCTAssertEqual(picker.editing, .end)
        picker.pick("2026-11-20")
        XCTAssertEqual(picker.span, span("2026-11-05", "2026-11-20"))
    }

    func testEditingToBeforeTheStartSwaps() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.end)
        picker.pick("2026-11-01")
        XCTAssertEqual(picker.span, span("2026-11-01", "2026-11-05"))
    }

    func testToFieldIsIgnoredUntilThereIsAStart() {
        var picker = empty()
        picker.select(.end)
        XCTAssertNil(picker.editing)
    }

    func testSelectingAFieldShowsThatDaysMonth() {
        var picker = DatesPicker(start: "2026-09-05", end: "2026-11-10", today: today)
        XCTAssertEqual(picker.month, "2026-11")
        picker.select(.start)
        XCTAssertEqual(picker.month, "2026-09")
        picker.select(.end)
        XCTAssertEqual(picker.month, "2026-11")
    }

    func testClearEmptiesBothEnds() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.start)
        picker.clear()
        XCTAssertNil(picker.start)
        XCTAssertNil(picker.end)
        XCTAssertNil(picker.editing)
        XCTAssertNil(picker.span)
    }

    func testMonthMovesBackAndForward() {
        var picker = DatesPicker(start: nil, end: nil, today: today)
        picker.moveMonth(-1, today: today)
        XCTAssertEqual(picker.month, "2026-10")
        picker.moveMonth(1, today: today)
        XCTAssertEqual(picker.month, "2026-11")
    }

    func testMonthCrossesTheYearBoundary() {
        var picker = DatesPicker(start: "2026-01-10", end: "2026-01-12", today: today)
        picker.moveMonth(-1, today: today)
        XCTAssertEqual(picker.month, "2025-12")
        picker.moveMonth(2, today: today)
        XCTAssertEqual(picker.month, "2026-02")
    }

    func testMonthNeverPassesTodaysMonth() {
        var picker = DatesPicker(start: nil, end: nil, today: today)
        picker.moveMonth(1, today: today)
        XCTAssertEqual(picker.month, "2026-11")
        picker.moveMonth(-3, today: today)
        XCTAssertEqual(picker.month, "2026-08")
        picker.moveMonth(5, today: today)
        XCTAssertEqual(picker.month, "2026-11")
    }

    func testChoosingAChipSetsBothEndsAndShowsItsMonth() {
        var picker = DatesPicker(start: "2026-11-05", end: "2026-11-10", today: today)
        picker.select(.start)
        let chip = DatesChip(label: "Last month", span: span("2026-10-01", "2026-10-31"))
        picker.choose(chip)
        XCTAssertEqual(picker.span, span("2026-10-01", "2026-10-31"))
        XCTAssertEqual(picker.month, "2026-10")
        XCTAssertNil(picker.editing)
    }
}
