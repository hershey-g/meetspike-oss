import XCTest
@testable import MeetspikeHRCore

final class PeopleFixTests: XCTestCase {
    private let spanA = DatesSpan(start: "2026-10-28", end: "2026-11-24")
    private let spanB = DatesSpan(start: "2026-08-27", end: "2026-11-24")

    func testNothingLoadedShowsSpinnerAndResetsPager() {
        let gate = PeopleLoadGate()
        XCTAssertTrue(gate.showsSpinner(for: spanA))
        XCTAssertTrue(gate.resetsPager(for: spanA))
    }

    func testSameSpanAfterMarkLoadedKeepsContentAndPager() {
        var gate = PeopleLoadGate()
        gate.markLoaded(spanA)
        XCTAssertFalse(gate.showsSpinner(for: spanA))
        XCTAssertFalse(gate.resetsPager(for: spanA))
    }

    func testDifferentSpanShowsSpinnerAndResetsPager() {
        var gate = PeopleLoadGate()
        gate.markLoaded(spanA)
        XCTAssertTrue(gate.showsSpinner(for: spanB))
        XCTAssertTrue(gate.resetsPager(for: spanB))
    }

    func testClearAfterFailureShowsSpinnerAgain() {
        var gate = PeopleLoadGate()
        gate.markLoaded(spanA)
        gate.clear()
        XCTAssertTrue(gate.showsSpinner(for: spanA))
        XCTAssertTrue(gate.resetsPager(for: spanA))
    }
}
