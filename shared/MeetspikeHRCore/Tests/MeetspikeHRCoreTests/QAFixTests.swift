import Foundation
import XCTest
@testable import MeetspikeHRCore

// QA fix pass (review 6b7204503653). Pins the pure helpers the app screens must call:
// DayState.noting, MoreLogic.sheetError, PeopleLogic.refreshNotice, AskLogic.restoredDraft.

private let generic = "Something went wrong. Try again."

private struct PlainError: Error {}

private func span(_ start: String, _ end: String) -> DatesSpan { DatesSpan(start: start, end: end) }

private func state(today: String, selected: String, _ start: String, _ end: String) -> DayState {
    DayState(today: today, selectedDay: selected, span: span(start, end))
}

private let allErrors: [(String, Error)] = [
    ("offline", APIError.offline),
    ("accessRejected", APIError.accessRejected),
    ("notConfigured", APIError.notConfigured),
    ("http", APIError.http(status: 500, message: "The Worker broke.")),
    ("decoding", APIError.decoding("ViewResponse.days missing")),
    ("invalidRequest", APIError.invalidRequest("bad path")),
    ("plain", PlainError()),
    ("nserror", NSError(domain: "x", code: 1)),
]

private func expectedMessage(_ error: Error) -> String {
    (error as? APIError)?.message ?? generic
}

// MARK: DayState

final class DayStateTests: XCTestCase {
    // The review's offline repro: saved Nov 24, today is Nov 25, offline answer is the Nov 24 copy.
    func testOfflineCachedAnswerDoesNotMoveTodayBackwards() {
        let before = state(today: "2026-11-25", selected: "2026-11-25", "2026-11-19", "2026-11-25")
        XCTAssertEqual(before.noting("2026-11-24", isFromCache: true), before)
    }

    func testCachedAnswerNeverChangesAnything() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-11-18", "2026-11-24")
        XCTAssertEqual(before.noting("2026-11-25", isFromCache: true), before)
        XCTAssertEqual(before.noting("2026-11-20", isFromCache: true), before)
    }

    func testInvalidDayChangesNothing() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-11-18", "2026-11-24")
        for bad in ["", "nope", "2026-13-01", "2026-02-30", "11/25/2026"] {
            XCTAssertEqual(before.noting(bad, isFromCache: false), before, bad)
        }
    }

    func testSameDayLiveAnswerChangesNothing() {
        let before = state(today: "2026-11-24", selected: "2026-11-22", "2026-11-10", "2026-11-17")
        XCTAssertEqual(before.noting("2026-11-24", isFromCache: false), before)
    }

    // Overnight roll: Today and Dates both sat on "today" and follow it.
    func testOvernightRollMovesTodayDayAndSpan() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-11-18", "2026-11-24")
        let after = before.noting("2026-11-25", isFromCache: false)
        XCTAssertEqual(after.today, "2026-11-25")
        XCTAssertEqual(after.selectedDay, "2026-11-25")
        XCTAssertEqual(after.span, span("2026-11-19", "2026-11-25"))
        XCTAssertEqual(after.span.dayCount, 7)
    }

    func testRollKeepsSpanLength() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-10-26", "2026-11-24")
        let after = before.noting("2026-11-25", isFromCache: false)
        XCTAssertEqual(after.span.dayCount, before.span.dayCount)
        XCTAssertEqual(after.span.end, "2026-11-25")
    }

    func testChosenPastDayDoesNotMove() {
        let before = state(today: "2026-11-24", selected: "2026-11-20", "2026-11-18", "2026-11-24")
        let after = before.noting("2026-11-25", isFromCache: false)
        XCTAssertEqual(after.today, "2026-11-25")
        XCTAssertEqual(after.selectedDay, "2026-11-20")
    }

    func testChosenPastSpanDoesNotMove() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-11-03", "2026-11-09")
        let after = before.noting("2026-11-25", isFromCache: false)
        XCTAssertEqual(after.span, span("2026-11-03", "2026-11-09"))
        XCTAssertEqual(after.selectedDay, "2026-11-25")
    }

    func testSpanEndingYesterdayDoesNotMove() {
        let before = state(today: "2026-11-24", selected: "2026-11-23", "2026-11-17", "2026-11-23")
        let after = before.noting("2026-11-25", isFromCache: false)
        XCTAssertEqual(after.span, span("2026-11-17", "2026-11-23"))
        XCTAssertEqual(after.selectedDay, "2026-11-23")
    }

    // Backward fresh server day (for example a time zone change): clamp, never point at the future.
    func testBackwardFreshDayClampsFollowers() {
        let before = state(today: "2026-11-25", selected: "2026-11-25", "2026-11-19", "2026-11-25")
        let after = before.noting("2026-11-24", isFromCache: false)
        XCTAssertEqual(after.today, "2026-11-24")
        XCTAssertEqual(after.selectedDay, "2026-11-24")
        XCTAssertEqual(after.span, span("2026-11-18", "2026-11-24"))
    }

    func testBackwardFreshDayClampsPastSelectionAheadOfIt() {
        let before = state(today: "2026-11-25", selected: "2026-11-24", "2026-11-19", "2026-11-25")
        let after = before.noting("2026-11-23", isFromCache: false)
        XCTAssertEqual(after.selectedDay, "2026-11-23")
    }

    func testBackwardFreshDayKeepsEarlierSelection() {
        let before = state(today: "2026-11-25", selected: "2026-11-20", "2026-11-19", "2026-11-25")
        let after = before.noting("2026-11-24", isFromCache: false)
        XCTAssertEqual(after.selectedDay, "2026-11-20")
    }

    func testBackwardFreshDayClampsSpanEndingPastIt() {
        // End 11-24 is not the old today (11-25) but is later than the new today 11-23: clamp, keep 8 days.
        let before = state(today: "2026-11-25", selected: "2026-11-20", "2026-11-17", "2026-11-24")
        let after = before.noting("2026-11-23", isFromCache: false)
        XCTAssertEqual(after.span, span("2026-11-16", "2026-11-23"))
        XCTAssertEqual(after.span.dayCount, 8)
    }

    func testBackwardFreshDayKeepsEarlierSpan() {
        let before = state(today: "2026-11-25", selected: "2026-11-20", "2026-11-10", "2026-11-17")
        let after = before.noting("2026-11-24", isFromCache: false)
        XCTAssertEqual(after.span, span("2026-11-10", "2026-11-17"))
    }

    func testMonthBoundary() {
        let before = state(today: "2026-11-30", selected: "2026-11-30", "2026-11-24", "2026-11-30")
        let after = before.noting("2026-12-01", isFromCache: false)
        XCTAssertEqual(after.selectedDay, "2026-12-01")
        XCTAssertEqual(after.span, span("2026-11-25", "2026-12-01"))
        XCTAssertEqual(after.span.dayCount, 7)
    }

    func testMonthBoundaryBackwards() {
        let before = state(today: "2026-12-01", selected: "2026-12-01", "2026-11-25", "2026-12-01")
        let after = before.noting("2026-11-30", isFromCache: false)
        XCTAssertEqual(after.selectedDay, "2026-11-30")
        XCTAssertEqual(after.span, span("2026-11-24", "2026-11-30"))
    }

    func testYearBoundary() {
        let before = state(today: "2026-12-31", selected: "2026-12-31", "2026-12-25", "2026-12-31")
        let after = before.noting("2027-01-01", isFromCache: false)
        XCTAssertEqual(after.today, "2027-01-01")
        XCTAssertEqual(after.selectedDay, "2027-01-01")
        XCTAssertEqual(after.span, span("2026-12-26", "2027-01-01"))
        XCTAssertEqual(after.span.dayCount, 7)
    }

    func testSingleDaySpanRolls() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-11-24", "2026-11-24")
        let after = before.noting("2026-11-25", isFromCache: false)
        XCTAssertEqual(after.span, span("2026-11-25", "2026-11-25"))
        XCTAssertTrue(after.span.isSingleDay)
    }

    func testSingleDaySpanRollsBackwards() {
        let before = state(today: "2026-11-25", selected: "2026-11-25", "2026-11-25", "2026-11-25")
        let after = before.noting("2026-11-24", isFromCache: false)
        XCTAssertEqual(after.span, span("2026-11-24", "2026-11-24"))
    }

    func testSingleDayPastSpanStays() {
        let before = state(today: "2026-11-24", selected: "2026-11-24", "2026-11-10", "2026-11-10")
        XCTAssertEqual(before.noting("2026-11-25", isFromCache: false).span, span("2026-11-10", "2026-11-10"))
    }
}

// MARK: MoreLogic.sheetError

final class SheetErrorTests: XCTestCase {
    func testNeverEmptyForAnyError() {
        for (name, error) in allErrors {
            for prefix in ["Couldn't sync.", "", "Couldn't remove the key."] {
                let text = MoreLogic.sheetError(error, prefix: prefix)
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) / '\(prefix)'")
            }
        }
    }

    func testPrefixThenMessage() {
        for (name, error) in allErrors {
            XCTAssertEqual(
                MoreLogic.sheetError(error, prefix: "Couldn't sync."),
                "Couldn't sync. \(expectedMessage(error))", name)
        }
    }

    func testOfflineAndAccessRejectedStillShowText() {
        // These are the two cases the banner used to swallow while the Menu sheet has no banner.
        XCTAssertEqual(MoreLogic.sheetError(APIError.offline, prefix: "Couldn't sync."),
                       "Couldn't sync. Can't reach Meetspike. Check your connection.")
        XCTAssertEqual(MoreLogic.sheetError(APIError.accessRejected, prefix: "Couldn't sync."),
                       "Couldn't sync. Sign-in needed. Check your Access token in Menu.")
    }

    func testHTTPUsesWorkerMessage() {
        XCTAssertEqual(MoreLogic.sheetError(APIError.http(status: 500, message: "The Worker broke."), prefix: "Couldn't load."),
                       "Couldn't load. The Worker broke.")
    }

    func testNonAPIErrorGetsGenericMessage() {
        XCTAssertEqual(MoreLogic.sheetError(PlainError(), prefix: "Couldn't load."), "Couldn't load. \(generic)")
    }

    func testEmptyPrefixGivesJustTheMessage() {
        XCTAssertEqual(MoreLogic.sheetError(APIError.offline, prefix: ""), APIError.offline.message)
        XCTAssertEqual(MoreLogic.sheetError(PlainError(), prefix: ""), generic)
        for (name, error) in allErrors {
            XCTAssertFalse(MoreLogic.sheetError(error, prefix: "").hasPrefix(" "), name)
        }
    }

    func testNoEmDash() {
        for (name, error) in allErrors {
            for prefix in ["Couldn't sync.", ""] {
                let text = MoreLogic.sheetError(error, prefix: prefix)
                XCTAssertFalse(text.contains("\u{2014}"), name)
                XCTAssertFalse(text.contains("\u{2013}"), name)
            }
        }
    }
}

// MARK: PeopleLogic.refreshNotice

final class RefreshNoticeTests: XCTestCase {
    func testCoveredByBannerIsNil() {
        for (name, error) in allErrors {
            XCTAssertNil(PeopleLogic.refreshNotice(error: error, coveredByBanner: true), name)
        }
    }

    func testNotCoveredShowsAPIMessageOrGeneric() {
        for (name, error) in allErrors {
            XCTAssertEqual(PeopleLogic.refreshNotice(error: error, coveredByBanner: false), expectedMessage(error), name)
        }
    }

    func testHTTPFailureWithDataOnScreenIsShown() {
        // Review repro: Worker returns 500 JSON on pull to refresh, no banner covers it.
        XCTAssertEqual(
            PeopleLogic.refreshNotice(error: APIError.http(status: 500, message: "Meetspike hit a snag."), coveredByBanner: false),
            "Meetspike hit a snag.")
    }

    func testDecodingFailureIsShown() {
        XCTAssertEqual(PeopleLogic.refreshNotice(error: APIError.decoding("PeopleResponse"), coveredByBanner: false),
                       APIError.decoding("PeopleResponse").message)
    }

    func testNonAPIErrorGetsGenericMessage() {
        XCTAssertEqual(PeopleLogic.refreshNotice(error: PlainError(), coveredByBanner: false), generic)
    }

    func testNonAPIErrorCoveredIsStillNil() {
        XCTAssertNil(PeopleLogic.refreshNotice(error: PlainError(), coveredByBanner: true))
    }
}

// MARK: AskLogic.restoredDraft

final class RestoredDraftTests: XCTestCase {
    func testBlankCurrentGetsTheQuestionBack() {
        XCTAssertEqual(AskLogic.restoredDraft(question: "How was my sleep?", current: ""), "How was my sleep?")
    }

    func testWhitespaceOnlyCurrentCountsAsBlank() {
        XCTAssertEqual(AskLogic.restoredDraft(question: "How was my sleep?", current: "   "), "How was my sleep?")
        XCTAssertEqual(AskLogic.restoredDraft(question: "How was my sleep?", current: " \n\t "), "How was my sleep?")
    }

    func testNewTypingIsNeverOverwritten() {
        XCTAssertEqual(AskLogic.restoredDraft(question: "How was my sleep?", current: "And my HRV?"), "And my HRV?")
    }

    func testCurrentWithSurroundingSpacesIsReturnedUnchanged() {
        XCTAssertEqual(AskLogic.restoredDraft(question: "Q", current: "  typed  "), "  typed  ")
    }
}
