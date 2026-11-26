import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 follow-up (fix9b.md), the shared and pure parts of G2, G3, G4, G5, G8 and G9. The server and web halves
// (G1, G4, G6, G7) are in test/override-followup.test.ts.
//
// The decisions below live in the Mac and iPhone app code today, which has no tests. Each one moves into this package
// as a small pure helper, with the names and signatures fixed here. The app code calls the helper and keeps no copy of
// the rule. None of these exist yet, so this file does not compile until they do.
//
// NEW API (all `public`, in MeetspikeHRCore):
//
//   G2  struct RefreshGate: Equatable, Sendable
//         static let periodicInterval: TimeInterval            300
//         init()
//         var isRunning: Bool { get }
//         mutating func request(force: Bool, now: Date) -> Bool
//             true: start a run now (the gate is then running). false: do not start. While a run is going a forced
//             request is remembered (one is enough) and a periodic one is dropped. Not running: forced always starts,
//             a periodic one starts only when more than `periodicInterval` has passed since the last run ended.
//         mutating func finished(now: Date) -> Bool
//             The run ended. true: a forced request came in while it ran, so run again at once (the gate stays
//             running for that run, call `finished` again when it ends). false: the gate is idle.
//
//       extension OverrideOverlay {
//         static func applying(_ answer: OverrideSaveResult, meetingID: String, to remote: [RemoteMeeting]) -> [RemoteMeeting]
//       }
//         The PUT's own answer laid on the stored meetings at once: the meeting with `meetingID` gets
//         `answer.override` (nil clears it, the Worker sends null when nothing is overridden). Nothing else changes.
//
//   G3  enum AttendanceReportDelivery
//         enum Verdict: Equatable { case done, retry, later, drop }
//         static func verdict(status: Int?) -> Verdict         (same meanings as the Mac's AttendanceDelivery today)
//         static let maxAttempts: Int, maxAge: TimeInterval, queueCap: Int, laterDelay: TimeInterval, backoff: [TimeInterval]
//         The Mac's AttendanceDelivery and AttendanceQueue use these (their own copies go away).
//
//   G4  behavior of the existing `OverrideOverlay.apply`: a pending series edit lays its state on the meeting it was
//       sent for even when that meeting's own state is `linked` (see the tests).
//
//   G5  extension OverrideDelivery {
//         enum MadeOutcome: Equatable, Sendable { case waiting(String), refused(String) }
//         static func outcomeWhenMade(for error: Error) -> MadeOutcome
//       }
//         What the caller does with a failure of a choice that was just made: offline waits (saved on the device, it
//         sends later); everything else is refused, leaves the old state and says so (not queued). `verdict(for:)` is
//         unchanged and keeps describing an edit that is already waiting.
//
//   G8  struct ListeningReadSchedule: Equatable, Sendable
//         static let todayInterval: TimeInterval               300
//         static let neighbourInterval: TimeInterval           1800
//         init()
//         func daysToRead(today: String, now: Date, force: Bool) -> [String]   ascending: yesterday, today, tomorrow
//         mutating func didRead(_ day: String, at now: Date)
//         Today is due when more than 5 minutes passed since it was last read, yesterday and tomorrow when more than 30
//         minutes passed since that day was read (per day, so a day that was tomorrow keeps its time). Never read is
//         due. `force` makes all three due (a person just changed a meeting).
//
//   G9  enum ListeningRefreshDays
//         static func forcedDays(now: Date, timeZone: TimeZone, changedMeetingStarts: [Date]) -> [String]
//         The days the forced read after a change fetches: today in `timeZone` (the Worker's zone, never the device
//         default) and the day each changed meeting starts on in that zone. Ascending, no repeats.

// MARK: - G2

final class Build9FollowupG2Tests: XCTestCase {
    private var gate = RefreshGate()

    func testAPeriodicRefreshStartsAtFirstAndThenWaitsFiveMinutes() {
        XCTAssertEqual(RefreshGate.periodicInterval, 300)
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.finished(now: B9.at(2)))
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(gate.request(force: false, now: B9.at(2 + 299)), "5 minutes have not passed since the run ended")
        XCTAssertTrue(gate.request(force: false, now: B9.at(2 + 301)))
    }

    func testAForcedRefreshAlwaysStartsWhenIdle() {
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        XCTAssertFalse(gate.finished(now: B9.at(1)))
        XCTAssertTrue(gate.request(force: true, now: B9.at(2)), "just after a run, forced still starts")
    }

    func testAForcedRefreshWhileOneRunsRunsAgainAfterIt() {
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        XCTAssertFalse(gate.request(force: true, now: B9.at(1)), "it cannot start while one is running")
        XCTAssertTrue(gate.finished(now: B9.at(3)), "but it is not lost: run again at once")
        XCTAssertTrue(gate.isRunning, "the follow-up run holds the gate")
        XCTAssertFalse(gate.finished(now: B9.at(5)), "one follow-up is enough")
        XCTAssertFalse(gate.isRunning)
    }

    func testSeveralForcedRequestsWhileRunningMakeOneFollowUp() {
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        for second in 1...5 { XCTAssertFalse(gate.request(force: true, now: B9.at(Double(second)))) }
        XCTAssertTrue(gate.finished(now: B9.at(6)))
        XCTAssertFalse(gate.finished(now: B9.at(7)))
    }

    func testAPeriodicRequestWhileRunningIsDroppedAndNeverRunsAgain() {
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        XCTAssertFalse(gate.request(force: false, now: B9.at(1)))
        XCTAssertFalse(gate.finished(now: B9.at(2)), "only a forced request asks for another run")
    }

    func testAForcedRequestMadeAfterTheRunEndedStartsOnItsOwnAndLeavesNothingBehind() {
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        XCTAssertFalse(gate.finished(now: B9.at(1)))
        XCTAssertTrue(gate.request(force: true, now: B9.at(2)))
        XCTAssertFalse(gate.finished(now: B9.at(3)))
        XCTAssertFalse(gate.isRunning)
    }

    func testTheFiveMinutesCountFromTheEndOfTheLastRunIncludingAFollowUp() {
        XCTAssertTrue(gate.request(force: false, now: B9.at(0)))
        XCTAssertFalse(gate.request(force: true, now: B9.at(1)))
        XCTAssertTrue(gate.finished(now: B9.at(10)))
        XCTAssertFalse(gate.finished(now: B9.at(20)))
        XCTAssertFalse(gate.request(force: false, now: B9.at(20 + 299)))
        XCTAssertTrue(gate.request(force: false, now: B9.at(20 + 301)))
    }

    // The PUT's own answer.

    private func remote(_ id: String, _ override: MeetingOverride?) -> RemoteMeeting {
        H9.remote(id, override: override)
    }

    func testTheAnswerIsAppliedToTheMeetingItWasSentFor() {
        let old = MeetingOverride(startUtc: B9.at(0), endUtc: B9.at(1800), seriesId: "s")
        let new = MeetingOverride(state: .notJoined, scope: .event, startUtc: B9.at(0), endUtc: B9.at(3600), seriesId: "s")
        let meetings = [remote("a", old), remote("b", old)]
        let result = OverrideOverlay.applying(OverrideSaveResult(id: "a", scope: "event", override: new), meetingID: "a", to: meetings)
        XCTAssertEqual(result[0].override, new)
        XCTAssertEqual(result[1], meetings[1], "no other meeting changes")
        XCTAssertEqual(result.map(\.id), ["a", "b"], "same meetings, same order")
        XCTAssertEqual(result[0].title, meetings[0].title)
        XCTAssertEqual(result[0].calendarStart, meetings[0].calendarStart)
        XCTAssertEqual(result[0].calendarEnd, meetings[0].calendarEnd)
    }

    func testAnAnswerWithNoOverrideClearsIt() {
        let had = MeetingOverride(state: .notJoined, scope: .event)
        let result = OverrideOverlay.applying(
            OverrideSaveResult(id: "a", scope: "event", override: nil), meetingID: "a", to: [remote("a", had)])
        XCTAssertNil(result[0].override, "the Worker sends null when nothing is overridden any more")
    }

    func testAnAnswerForAMeetingTheMacDoesNotHaveChangesNothing() {
        let meetings = [remote("a", nil)]
        let answer = OverrideSaveResult(id: "zzz", scope: "event", override: MeetingOverride(state: .notJoined, scope: .event))
        XCTAssertEqual(OverrideOverlay.applying(answer, meetingID: "zzz", to: meetings), meetings)
        XCTAssertEqual(OverrideOverlay.applying(answer, meetingID: "zzz", to: []), [])
    }

    func testASavedChoiceDoesNotRevertWhenTheOutboxIsEmpty() {
        // The sequence the review found: the edit was sent, the outbox item is gone, the stored meeting is still the
        // old one. With the answer applied there is nothing left to revert.
        let stored = [remote("a", MeetingOverride(endUtc: B9.at(1800)))]
        let answer = OverrideSaveResult(
            id: "a", scope: "event", override: MeetingOverride(endUtc: B9.at(600)), startUtc: nil, endUtc: B9.iso(600))
        let current = OverrideOverlay.apply([], to: OverrideOverlay.applying(answer, meetingID: "a", to: stored))
        XCTAssertEqual(current[0].override?.endUtc, B9.at(600))
    }
}

// MARK: - G3

final class Build9FollowupG3Tests: XCTestCase {
    private func verdict(_ status: Int?) -> AttendanceReportDelivery.Verdict { AttendanceReportDelivery.verdict(status: status) }

    func testSuccessIsDone() {
        for status in [200, 201, 202, 204] { XCTAssertEqual(verdict(status), .done, "\(status)") }
    }

    func testNoAnswerAndTransientFailuresRetry() {
        XCTAssertEqual(verdict(nil), .retry)
        for status in [408, 425, 429, 500, 502, 504, 599] { XCTAssertEqual(verdict(status), .retry, "\(status)") }
    }

    func testTheWorkerNotReadyIsLaterAndNotCounted() {
        XCTAssertEqual(verdict(503), .later)
    }

    func testAuthFailuresAndRedirectsKeepTheReportForLater() {
        // A rotated secret, an expired Access token or a redirect to a login page: fixing it later must still send the
        // report, so it is kept, not dropped.
        for status in [401, 403, 302, 303, 307, 308] { XCTAssertEqual(verdict(status), .later, "\(status)") }
    }

    func testOtherClientErrorsAreDropped() {
        for status in [400, 404, 405, 410, 413, 415, 422] { XCTAssertEqual(verdict(status), .drop, "\(status)") }
    }

    func testKeptReportsAreBounded() {
        // The existing limits stay: a report is never kept forever and the queue has a cap.
        XCTAssertEqual(AttendanceReportDelivery.maxAge, 3 * 86_400)
        XCTAssertEqual(AttendanceReportDelivery.queueCap, 100)
        XCTAssertEqual(AttendanceReportDelivery.maxAttempts, 5)
        XCTAssertEqual(AttendanceReportDelivery.laterDelay, 30 * 60)
        XCTAssertEqual(AttendanceReportDelivery.backoff, [60, 300, 900, 3_600])
    }
}

// MARK: - G4

final class Build9FollowupG4Tests: XCTestCase {
    private typealias Items = [(id: String, override: MeetingOverride?)]

    func testAllOfThemOnAMeetingThatSaidLinkedLeavesTheTappedMeetingOutToo() {
        let linked = MeetingOverride(state: .linked, scope: .event, startUtc: B9.at(-300), endUtc: B9.at(2000), seriesId: "s")
        let plain = MeetingOverride(seriesId: "s")
        let items: Items = [("s_20261124", plain), ("s_20261125", linked), ("s_20261126", plain)]
        for state in [MeetingOverride.State.notJoined, .unlinked] {
            let result = OverrideOverlay.apply(
                [H9.item("s_20261125", OverrideEdit(scope: .series, state: .set(state)))], to: items)
            XCTAssertEqual(result.map(OverrideRules.excluded), [true, true, true], "\(state): the tapped meeting goes out too")
            XCTAssertEqual(result[1]?.state, state)
            XCTAssertEqual(result[1]?.scope, .series, "the series rule decides now, as the Worker answers")
            XCTAssertEqual(result[1]?.startUtc, B9.at(-300), "its times stay")
            XCTAssertEqual(result[1]?.endUtc, B9.at(2000))
        }
    }

    func testOnlyTheMeetingTheEditWasSentForLosesItsLinked() {
        let linked = MeetingOverride(state: .linked, scope: .event, seriesId: "s")
        let items: Items = [("s_20261125", linked), ("s_20261126", linked)]
        let result = OverrideOverlay.apply(
            [H9.item("s_20261125", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: items)
        XCTAssertEqual(result.map(OverrideRules.excluded), [true, false], "another meeting's own choice still beats the series")
        XCTAssertEqual(result[1], linked)
    }

    func testAnOwnExclusionIsLeftAsItIs() {
        let own = MeetingOverride(state: .unlinked, scope: .event, seriesId: "s")
        let result = OverrideOverlay.apply(
            [H9.item("s_20261125", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: [(id: "s_20261125", override: own)])
        XCTAssertEqual(result[0], own)
    }

    func testTheRowsAndListeningSeeTheTappedMeetingLeftOut() throws {
        let linked = MeetingOverride(state: .linked, scope: .event, seriesId: "s")
        let row = try H9.row("s_20261125", override: linked)
        let rows = OverrideOverlay.apply(
            [H9.item("s_20261125", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: [row])
        XCTAssertEqual(rows[0].excluded, true)
        let remote = [H9.remote("s_20261125", override: linked)]
        let after = OverrideOverlay.apply(
            [H9.item("s_20261125", OverrideEdit(scope: .series, state: .set(.notJoined)))], to: remote)
        XCTAssertEqual(OverrideMatch.apply(after, to: [B9.meeting("Standup", 0, 1800)]), [], "no listening window")
    }

    func testTheMenuAnswerIsOneSeriesEditThatTheWorkerCompletes() {
        // The phone sends one series PUT and relies on the Worker to clear the tapped meeting's own `linked`.
        let linked = MeetingOverride(state: .linked, scope: .event, seriesId: "s")
        XCTAssertEqual(MeetingActions.plan(.notJoined, override: linked), .askScope(.state(.notJoined)))
        XCTAssertEqual(
            MeetingActions.answer(.series, to: .state(.notJoined), override: linked),
            OverrideEdit(scope: .series, state: .set(.notJoined)))
    }
}

// MARK: - G5

final class Build9FollowupG5Tests: XCTestCase {
    private func made(_ error: Error) -> OverrideDelivery.MadeOutcome { OverrideDelivery.outcomeWhenMade(for: error) }

    func testOfflineIsSavedOnTheDeviceAndWaits() {
        guard case .keep(let words) = OverrideDelivery.verdict(for: APIError.offline) else { return XCTFail("offline keeps the edit") }
        XCTAssertEqual(made(APIError.offline), .waiting(words))
    }

    func testAFailureWhenTheChoiceIsMadeIsRefusedAndNotQueued() {
        let cases: [(String, Error, String)] = [
            ("503", APIError.http(status: 503, message: "x"), OverrideDelivery.notAvailable),
            ("500", APIError.http(status: 500, message: "x"), "Couldn't save. Nothing changed."),
            ("502", APIError.http(status: 502, message: "x"), "Couldn't save. Nothing changed."),
            ("429", APIError.http(status: 429, message: "x"), "Couldn't save. Nothing changed."),
            ("rejected sign-in", APIError.accessRejected, APIError.accessRejected.message),
            ("unreadable answer", APIError.decoding("x"), "Couldn't save. Nothing changed."),
            ("not an API error", URLError(.timedOut), "Couldn't save. Nothing changed."),
        ]
        for (label, error, text) in cases {
            XCTAssertEqual(made(error), .refused(text), label)
        }
    }

    func testAFinalRefusalIsRefusedWithTheWorkersWords() {
        XCTAssertEqual(made(APIError.http(status: 400, message: "The end has to be after the start.")), .refused("The end has to be after the start."))
        XCTAssertEqual(made(APIError.http(status: 404, message: "No meeting with that id.")), .refused("No meeting with that id."))
        XCTAssertEqual(made(APIError.invalidRequest("bad")), .refused(APIError.invalidRequest("bad").message))
        XCTAssertEqual(made(APIError.notConfigured), .refused(APIError.notConfigured.message))
    }

    func testOnlyOfflineEverWaits() {
        let errors: [Error] = [
            APIError.http(status: 503, message: ""), APIError.http(status: 500, message: ""), APIError.accessRejected,
            APIError.decoding(""), APIError.http(status: 400, message: "no"), APIError.notConfigured, URLError(.notConnectedToInternet),
        ]
        for error in errors {
            if case .waiting = made(error) { XCTFail("\(error) must not be queued: the choice leaves the old state") }
        }
    }

    func testTheWordsArePlain() {
        for error in [APIError.offline, APIError.http(status: 503, message: ""), APIError.accessRejected, APIError.http(status: 500, message: "")] {
            switch made(error) {
            case .waiting(let text), .refused(let text): H9.assertPlainVoice(text)
            }
        }
    }

    func testTheVerdictForAnEditThatIsAlreadyWaitingIsUnchanged() {
        // `outcomeWhenMade` is for a choice made just now. A waiting edit is still kept on 503 and the rest.
        XCTAssertEqual(OverrideDelivery.verdict(for: APIError.http(status: 503, message: "")), .keep(OverrideDelivery.notAvailable))
        XCTAssertEqual(OverrideDelivery.verdict(for: APIError.http(status: 500, message: "")), .keep("Couldn't save. Nothing changed."))
        XCTAssertEqual(OverrideDelivery.verdict(for: APIError.http(status: 404, message: "gone")), .drop("gone"))
    }
}

// MARK: - G8

final class Build9FollowupG8Tests: XCTestCase {
    private let today = "2026-11-25"
    private let yesterday = "2026-11-24"
    private let tomorrow = "2026-11-26"

    private func readAll(_ schedule: inout ListeningReadSchedule, at seconds: TimeInterval, days: [String]? = nil) {
        for day in days ?? [yesterday, today, tomorrow] { schedule.didRead(day, at: B9.at(seconds)) }
    }

    func testTheIntervals() {
        XCTAssertEqual(ListeningReadSchedule.todayInterval, 300)
        XCTAssertEqual(ListeningReadSchedule.neighbourInterval, 1_800)
    }

    func testNothingReadYetReadsThreeDaysInOrder() {
        let schedule = ListeningReadSchedule()
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(0), force: false), [yesterday, today, tomorrow])
    }

    func testTodayEveryFiveMinutesAndTheNeighboursEveryThirtyMinutes() {
        var schedule = ListeningReadSchedule()
        readAll(&schedule, at: 0)
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(299), force: false), [])
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(301), force: false), [today])
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(1_799), force: false), [today])
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(1_801), force: false), [yesterday, today, tomorrow])
    }

    func testEachDayKeepsItsOwnReadTime() {
        var schedule = ListeningReadSchedule()
        readAll(&schedule, at: 0)
        schedule.didRead(today, at: B9.at(400))
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(1_801), force: false), [yesterday, tomorrow, today].sorted(),
                       "today was read at 400 and is due again after 5 minutes; the others after 30 from 0")
        schedule.didRead(yesterday, at: B9.at(1_900))
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(2_000), force: false), [tomorrow, today].sorted())
    }

    func testAForcedReadTakesAllThreeDaysAtOnce() {
        var schedule = ListeningReadSchedule()
        readAll(&schedule, at: 0)
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(1), force: true), [yesterday, today, tomorrow])
    }

    func testADayThatFailedToReadStaysDue() {
        var schedule = ListeningReadSchedule()
        readAll(&schedule, at: 0, days: [today, tomorrow])
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(60), force: false), [yesterday])
    }

    func testAcrossMidnightEachNewDayIsJudgedByItsOwnHistory() {
        var schedule = ListeningReadSchedule()
        readAll(&schedule, at: 0) // read yesterday, today and tomorrow on the 25th
        // Six minutes later it is the 26th. The 26th was read as "tomorrow" 6 minutes ago, so as today it is due.
        // The 25th was read 6 minutes ago as today, so as yesterday it is not due. The 27th was never read.
        XCTAssertEqual(schedule.daysToRead(today: tomorrow, now: B9.at(360), force: false), [tomorrow, "2026-11-27"])
    }

    func testReadingIsRecordedPerCall() {
        var schedule = ListeningReadSchedule()
        let before = schedule
        schedule.didRead(today, at: B9.at(5))
        XCTAssertNotEqual(schedule, before)
        XCTAssertEqual(schedule.daysToRead(today: today, now: B9.at(10), force: false), [yesterday, tomorrow])
    }
}

// MARK: - G9

final class Build9FollowupG9Tests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let auckland = TimeZone(identifier: "Pacific/Auckland")!
    /// 2026-11-26T02:00:00Z: 21:00 on the 25th in New York, 15:00 on the 26th in Auckland.
    private var now: Date { B9.at(12 * 3_600) }

    func testWithNothingChangedItIsTodayInTheWorkerZone() {
        XCTAssertEqual(ListeningRefreshDays.forcedDays(now: now, timeZone: newYork, changedMeetingStarts: []), ["2026-11-25"])
        XCTAssertEqual(ListeningRefreshDays.forcedDays(now: now, timeZone: auckland, changedMeetingStarts: []), ["2026-11-26"])
    }

    func testTheDeviceTimeZoneNeverMatters() {
        B9.inZones(B9.zones) { _ in
            XCTAssertEqual(ListeningRefreshDays.forcedDays(now: now, timeZone: newYork, changedMeetingStarts: []), ["2026-11-25"])
            XCTAssertEqual(ListeningRefreshDays.forcedDays(now: now, timeZone: auckland, changedMeetingStarts: []), ["2026-11-26"])
        }
    }

    func testTheChangedMeetingsOwnDayIsReadToo() {
        // Started 2026-11-24T18:00Z: 13:00 on the 24th in New York. A meeting still running from yesterday.
        let yesterdays = B9.at(-20 * 3_600)
        XCTAssertEqual(
            ListeningRefreshDays.forcedDays(now: now, timeZone: newYork, changedMeetingStarts: [yesterdays]),
            ["2026-11-24", "2026-11-25"])
    }

    func testTheMeetingsDayIsTakenInTheWorkerZone() {
        // 2026-11-25T10:00Z is 05:00 on the 25th in New York and 23:00 on the 25th in Auckland.
        let start = B9.at(-4 * 3_600)
        XCTAssertEqual(ListeningRefreshDays.forcedDays(now: now, timeZone: newYork, changedMeetingStarts: [start]), ["2026-11-25"])
        XCTAssertEqual(
            ListeningRefreshDays.forcedDays(now: now, timeZone: auckland, changedMeetingStarts: [start]), ["2026-11-25", "2026-11-26"])
    }

    func testSeveralMeetingsGiveSortedDaysWithNoRepeats() {
        let starts = [B9.at(-20 * 3_600), B9.at(-19 * 3_600), B9.at(2 * 3_600), B9.at(30 * 3_600)]
        XCTAssertEqual(
            ListeningRefreshDays.forcedDays(now: now, timeZone: newYork, changedMeetingStarts: starts),
            ["2026-11-24", "2026-11-25", "2026-11-26"])
    }
}
