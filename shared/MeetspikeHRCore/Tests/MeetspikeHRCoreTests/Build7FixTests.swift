import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 7 fix pass, track `app`: review findings on the held meeting detail (MeetingDetailState).
//
// Names the builder must add, all in MeetingChartModel.swift next to MeetingDetailState (a missing name stops this
// whole test target compiling, so they are fixed here):
//
//   public enum MeetingDetailRefresh: Sendable { case sameSources, sourcesChanged }
//
//   extension MeetingDetailState:
//     public func refreshed(_ change: MeetingDetailRefresh) -> Self?
//         .sameSources    -> markStale()                         (data stays on screen, reloads on next ask)
//         .sourcesChanged -> nil                                 (the held chart may show a source that is now off: drop it)
//     public static func retriesLoad(refreshedWhileLoading: Bool, attempt: Int) -> Bool
//         true only when refreshedWhileLoading && attempt < 2    (attempt is 1-based: the one that just ended)
//     public var refreshFailed: Bool
//         data != nil && error != nil && !loading
//
// What is NOT covered here, because TodayModel and TodayScreen live in the iOS target, which has no test target:
//   - TodayModel dropping every held detail and any load in flight on `.meetspikeDisplaySourcesChanged`
//     (clearDetails(), so no chart of a now-off source stays up even if the reload fails), while other quiet
//     reloads keep charts (markDetailsStale()).
//   - runDetailLoad calling `retriesLoad` on both the success and the failure path, and not retrying cancellation.
//   - TodayScreen showing "Couldn't refresh. Showing the last one." under the heart rate facts when
//     `refreshFailed` is true, and nothing otherwise.
// Those are checked in code review. The pure decisions they rest on are tested below.
//
// Every test in this file fails to compile today. After the names exist, the tests that only exercise already
// existing behavior (marked "guard") are green; the rest are red until the behavior is right.

private typealias State = MeetingDetailState<Int>
private let t0 = Date(timeIntervalSince1970: 1_000)
private let t1 = Date(timeIntervalSince1970: 1_130)

/// One state per combination of data, error, loading and stale that a held detail can be in.
private struct Case {
    var name: String
    var state: State
}

private func everyState() -> [Case] {
    var cases: [Case] = []
    for hasData in [false, true] {
        for hasError in [false, true] {
            for loading in [false, true] {
                for stale in [false, true] {
                    let name = "data=\(hasData) error=\(hasError) loading=\(loading) stale=\(stale)"
                    cases.append(Case(
                        name: name,
                        state: State(
                            data: hasData ? 7 : nil, error: hasError ? "Offline" : nil, loading: loading,
                            loadedAt: hasData ? t0 : nil, stale: stale)))
                }
            }
        }
    }
    return cases
}

// MARK: A1. A refresh either keeps the chart (same sources) or drops it (sources changed)

final class Build7FixRefreshTests: XCTestCase {
    func testTheRefreshKindIsSendableAndHasTwoCases() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        let kinds: [MeetingDetailRefresh] = [.sameSources, .sourcesChanged]
        XCTAssertEqual(kinds.count, 2)
        _ = requireSendable(MeetingDetailRefresh.sameSources)
    }

    /// Same sources behaves exactly as markStale() for every state a held detail can be in.
    func testSameSourcesIsMarkStaleForEveryState() {
        for c in everyState() {
            let next = c.state.refreshed(.sameSources)
            XCTAssertNotNil(next, c.name)
            XCTAssertEqual(next, c.state.markStale(), c.name)
            XCTAssertEqual(next?.stale, true, c.name)
        }
    }

    func testSameSourcesKeepsTheChartOnScreenAndReloadsOnTheNextAsk() throws {
        let held = State().finishLoad(7, at: t0)
        let next = try XCTUnwrap(held.refreshed(.sameSources))
        XCTAssertEqual(next.data, 7, "the chart stays")
        XCTAssertFalse(next.showsLoadingPlaceholder, "no blink to Loading heart rate")
        XCTAssertTrue(next.needsLoad(now: t0.addingTimeInterval(1), maxAge: 60), "young data still reloads once stale")
        XCTAssertEqual(next.loadedAt, t0)
        XCTAssertNil(next.error)
        XCTAssertFalse(next.loading)
    }

    func testSameSourcesDuringALoadKeepsItRunningAndStale() throws {
        let inFlight = State().finishLoad(7, at: t0).markStale().beginLoad()
        let next = try XCTUnwrap(inFlight.refreshed(.sameSources))
        XCTAssertTrue(next.loading, "the load in flight is not stopped by the state")
        XCTAssertTrue(next.stale)
        XCTAssertEqual(next.data, 7)
        XCTAssertFalse(next.showsLoadingPlaceholder)
        XCTAssertFalse(next.needsLoad(now: t0.addingTimeInterval(1), maxAge: 60), "one load at a time")
    }

    func testSameSourcesOnAFailedReloadKeepsTheDataAndTheError() throws {
        let failed = State().finishLoad(7, at: t0).markStale().beginLoad().failLoad("Offline", at: t1)
        let next = try XCTUnwrap(failed.refreshed(.sameSources))
        XCTAssertEqual(next.data, 7)
        XCTAssertEqual(next.error, "Offline")
        XCTAssertTrue(next.stale)
    }

    func testSameSourcesWithNothingHeldHoldsNothing() throws {
        let next = try XCTUnwrap(State().refreshed(.sameSources))
        XCTAssertNil(next.data)
        XCTAssertFalse(next.loading)
        XCTAssertFalse(next.showsLoadingPlaceholder)
    }

    /// The bug: a source toggle kept the old chart, which could show a source that is now off.
    func testSourcesChangedDropsEveryState() {
        for c in everyState() {
            XCTAssertNil(c.state.refreshed(.sourcesChanged), c.name)
        }
    }

    func testSourcesChangedDropsAChartEvenWhenItIsFreshAndHasNoError() {
        let fresh = State().finishLoad(7, at: t0)
        XCTAssertFalse(fresh.needsLoad(now: t0.addingTimeInterval(1), maxAge: 60), "precondition: a young chart")
        XCTAssertNil(fresh.refreshed(.sourcesChanged))
    }

    func testSourcesChangedDropsALoadInFlightsState() {
        XCTAssertNil(State().beginLoad().refreshed(.sourcesChanged), "first load")
        XCTAssertNil(State().finishLoad(7, at: t0).markStale().beginLoad().refreshed(.sourcesChanged), "reload over data")
    }

    func testRefreshingDoesNotChangeTheOriginal() {
        let original = State().finishLoad(7, at: t0)
        let copy = original
        _ = original.refreshed(.sameSources)
        _ = original.refreshed(.sourcesChanged)
        XCTAssertEqual(original, copy)
    }

    /// The two kinds give different answers for the same state: this is what a toggle needs to tell apart.
    func testTheTwoKindsDisagree() {
        let held = State().finishLoad(7, at: t0)
        XCTAssertNotNil(held.refreshed(.sameSources))
        XCTAssertNil(held.refreshed(.sourcesChanged))
    }
}

// MARK: A2. Retry once when a refresh lands during a load, on success and on failure

final class Build7FixRetryTests: XCTestCase {
    func testRetriesOnlyWhenARefreshLandedAndItWasTheFirstAttempt() {
        XCTAssertTrue(State.retriesLoad(refreshedWhileLoading: true, attempt: 1))
        XCTAssertFalse(State.retriesLoad(refreshedWhileLoading: true, attempt: 2), "one extra try only")
        XCTAssertFalse(State.retriesLoad(refreshedWhileLoading: true, attempt: 3))
        XCTAssertFalse(State.retriesLoad(refreshedWhileLoading: true, attempt: 100))
    }

    func testNeverRetriesWithoutARefresh() {
        for attempt in 1...4 {
            XCTAssertFalse(State.retriesLoad(refreshedWhileLoading: false, attempt: attempt), "attempt \(attempt)")
        }
    }

    func testTheAnswerDoesNotDependOnTheHeldValueType() {
        for refreshed in [false, true] {
            for attempt in 1...3 {
                XCTAssertEqual(
                    MeetingDetailState<String>.retriesLoad(refreshedWhileLoading: refreshed, attempt: attempt),
                    State.retriesLoad(refreshedWhileLoading: refreshed, attempt: attempt))
            }
        }
    }

    // The loop in TodayModel.runDetailLoad, as a plain driver over the pure pieces. Each step is one attempt:
    // whether it succeeds and whether a refresh landed while it was in flight. Cancellation is not a step: the
    // model stops without calling `retriesLoad` and does not retry.
    private struct Step {
        var succeeds: Bool
        var refreshLanded: Bool
    }

    private struct Run {
        var final: State
        var attempts: Int
        /// What a person could see between attempts: no error flash, no loading placeholder while data is held.
        var sawErrorWhileRetrying = false
        var sawPlaceholderWhileRetrying = false
    }

    private func drive(from start: State, _ steps: [Step], reload: Int = 9) -> Run {
        var state = start.beginLoad()
        var run = Run(final: state, attempts: 0)
        var attempt = 0
        while attempt < steps.count {
            let step = steps[attempt]
            attempt += 1
            run.attempts = attempt
            if step.succeeds {
                state = state.finishLoad(reload + attempt, at: t1)
            } else {
                state = state.failLoad("Offline", at: t1)
            }
            if State.retriesLoad(refreshedWhileLoading: step.refreshLanded, attempt: attempt) {
                // Success path: the answer may predate the refresh. Failure path: the data is kept and tried again.
                state = state.markStale().beginLoad()
                if state.error != nil { run.sawErrorWhileRetrying = true }
                if state.showsLoadingPlaceholder { run.sawPlaceholderWhileRetrying = true }
                continue
            }
            break
        }
        run.final = state
        return run
    }

    private let held = State().finishLoad(7, at: t0).markStale()

    /// The bug: a refresh landed during a load that then failed. The old code showed the error and stopped.
    func testAFailureAfterARefreshIsTriedOnceMoreWithoutAnErrorFlash() {
        let run = drive(from: held, [Step(succeeds: false, refreshLanded: true), Step(succeeds: true, refreshLanded: false)])
        XCTAssertEqual(run.attempts, 2)
        XCTAssertFalse(run.sawErrorWhileRetrying, "no error flash between the tries")
        XCTAssertFalse(run.sawPlaceholderWhileRetrying, "the old chart stays")
        XCTAssertEqual(run.final.data, 11, "the second try's answer lands")
        XCTAssertNil(run.final.error)
        XCTAssertFalse(run.final.loading)
        XCTAssertFalse(run.final.stale)
    }

    func testTheRetryKeepsDataAndLoadingOnWhileItRuns() {
        let failed = held.beginLoad().failLoad("Offline", at: t1)
        XCTAssertTrue(State.retriesLoad(refreshedWhileLoading: true, attempt: 1))
        let retrying = failed.markStale().beginLoad()
        XCTAssertEqual(retrying.data, 7, "data kept")
        XCTAssertTrue(retrying.loading, "loading stays on")
        XCTAssertNil(retrying.error, "no error flash")
        XCTAssertFalse(retrying.showsLoadingPlaceholder)
    }

    func testASuccessAfterARefreshIsTriedOnceMoreAndThenSettles() {
        let run = drive(from: held, [Step(succeeds: true, refreshLanded: true), Step(succeeds: true, refreshLanded: true)])
        XCTAssertEqual(run.attempts, 2, "a second refresh does not buy a third try")
        XCTAssertEqual(run.final.data, 11)
        XCTAssertFalse(run.final.loading)
    }

    func testTwoFailuresEndWithTheOldDataAndTheError() {
        let run = drive(from: held, [Step(succeeds: false, refreshLanded: true), Step(succeeds: false, refreshLanded: true)])
        XCTAssertEqual(run.attempts, 2)
        XCTAssertEqual(run.final.data, 7, "old data kept")
        XCTAssertEqual(run.final.error, "Offline")
        XCTAssertFalse(run.final.loading)
        XCTAssertTrue(run.final.refreshFailed)
    }

    func testAFailureWithoutARefreshIsNotRetried() {
        let run = drive(from: held, [Step(succeeds: false, refreshLanded: false), Step(succeeds: true, refreshLanded: false)])
        XCTAssertEqual(run.attempts, 1)
        XCTAssertEqual(run.final.error, "Offline")
        XCTAssertEqual(run.final.data, 7)
    }

    func testASuccessWithoutARefreshIsNotRetried() {
        let run = drive(from: held, [Step(succeeds: true, refreshLanded: false)])
        XCTAssertEqual(run.attempts, 1)
        XCTAssertEqual(run.final.data, 10)
        XCTAssertNil(run.final.error)
    }

    func testAFailedFirstLoadWithARefreshIsTriedOnceMoreAndKeepsThePlaceholderMeanwhile() {
        let run = drive(from: State(), [Step(succeeds: false, refreshLanded: true), Step(succeeds: true, refreshLanded: false)])
        XCTAssertEqual(run.attempts, 2)
        XCTAssertFalse(run.sawErrorWhileRetrying)
        XCTAssertEqual(run.final.data, 11)
        XCTAssertNil(run.final.error)
    }
}

// MARK: A3. A failed refresh over data that is still shown

final class Build7FixRefreshFailedTests: XCTestCase {
    func testTruthTableForEveryCombination() {
        for c in everyState() {
            let expected = c.state.data != nil && c.state.error != nil && !c.state.loading
            XCTAssertEqual(c.state.refreshFailed, expected, c.name)
        }
    }

    func testAFreshStateHasNotFailed() {
        XCTAssertFalse(State().refreshFailed)
        XCTAssertFalse(State().beginLoad().refreshFailed)
    }

    func testALoadedChartHasNotFailed() {
        XCTAssertFalse(State().finishLoad(7, at: t0).refreshFailed)
        XCTAssertFalse(State().finishLoad(7, at: t0).markStale().refreshFailed)
    }

    func testAFailedReloadOverDataIsAFailedRefresh() {
        let failed = State().finishLoad(7, at: t0).markStale().beginLoad().failLoad("Offline", at: t1)
        XCTAssertEqual(failed.data, 7, "precondition: the old chart is still shown")
        XCTAssertTrue(failed.refreshFailed)
    }

    func testAFailedFirstLoadIsNotAFailedRefresh() {
        // No old data to show: the error view handles it, not the small caption.
        let failed = State().beginLoad().failLoad("Offline", at: t0)
        XCTAssertNil(failed.data)
        XCTAssertNotNil(failed.error)
        XCTAssertFalse(failed.refreshFailed)
    }

    func testTheCaptionGoesAwayWhileTryingAgain() {
        let failed = State().finishLoad(7, at: t0).failLoad("Offline", at: t1)
        XCTAssertTrue(failed.refreshFailed)
        let again = failed.beginLoad()
        XCTAssertFalse(again.refreshFailed, "loading is on and the error is cleared")
        XCTAssertEqual(again.data, 7)
    }

    func testTheCaptionGoesAwayWhenTheReloadLands() {
        let failed = State().finishLoad(7, at: t0).failLoad("Offline", at: t1)
        XCTAssertFalse(failed.beginLoad().finishLoad(9, at: t1).refreshFailed)
    }

    func testAnErrorStillHeldWhileLoadingIsNotShownAsFailed() {
        // Loading with an error left over: it is being tried again, so no caption.
        let state = State(data: 7, error: "Offline", loading: true, loadedAt: t0, stale: false)
        XCTAssertFalse(state.refreshFailed)
    }

    func testStaleDoesNotChangeIt() throws {
        let failed = State().finishLoad(7, at: t0).failLoad("Offline", at: t1)
        XCTAssertTrue(failed.markStale().refreshFailed)
        XCTAssertTrue(try XCTUnwrap(failed.refreshed(.sameSources)).refreshFailed)
    }

    func testADroppedDetailHasNoCaption() {
        let failed = State().finishLoad(7, at: t0).failLoad("Offline", at: t1)
        XCTAssertNil(failed.refreshed(.sourcesChanged), "the whole entry goes, so there is nothing to caption")
    }
}
