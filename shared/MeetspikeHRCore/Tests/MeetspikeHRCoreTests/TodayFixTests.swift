import Foundation
import XCTest
@testable import MeetspikeHRCore

// Today track fix pass, regression tests: shortSentence whitespace handling, live session window change and backoff,
// error handling in the live card, the live meeting picker, live window end detection, refresh throttle, stale load guard.

final class TodayFixTests: XCTestCase {
    // MARK: Helpers

    private func date(_ iso: String) -> Date {
        Date(timeIntervalSince1970: MobileJSON.ms(iso) / 1000)
    }

    private func meeting(
        _ id: String, _ start: String, _ end: String, sourceType: String? = "calendar"
    ) throws -> Meeting {
        var object: [String: Any] = ["id": id, "startUtc": start, "endUtc": end]
        if let sourceType { object["sourceType"] = sourceType }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Meeting.self, from: data)
    }

    private func hit(sentence: String?, headline: String?) throws -> InsightHit {
        var object: [String: Any] = ["id": "m1"]
        if let sentence { object["sentence"] = sentence }
        if let headline { object["hrStress"] = ["headline": headline] }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(InsightHit.self, from: data)
    }

    private let window = LiveWindowMs(
        startMs: MobileJSON.ms("2026-11-24T15:00:00Z"), endMs: MobileJSON.ms("2026-11-24T16:00:00Z"),
        fromMs: MobileJSON.ms("2026-11-24T14:50:00Z"), toMs: MobileJSON.ms("2026-11-24T16:10:00Z"))

    /// A poll answer. `window` nil keeps the session's window; `shiftedTo` moves the end of the padded window.
    private func reply(
        active: Bool? = true, points: [[Double]] = [], cursor: Int? = nil, shiftToMs: Double? = nil
    ) throws -> LiveHRReply {
        var object: [String: Any] = ["points": points]
        if let active { object["active"] = active }
        if let cursor { object["cursor"] = cursor }
        object["window"] = [
            "startMs": window.startMs, "endMs": window.endMs, "fromMs": window.fromMs,
            "toMs": shiftToMs ?? window.toMs,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(LiveHRReply.self, from: data)
    }

    private var t0: Double { window.startMs }

    // MARK: shortSentence

    func testShortSentenceDropsTheSentenceThePillAlreadySaysAndShortensBpm() throws {
        let h = try hit(
            sentence: "Your heart averaged about 87 beats per minute.\nIt peaked at 120 beats per minute.",
            headline: nil)
        XCTAssertEqual(TodayFormat.shortSentence(h), "Your heart averaged about 87 bpm.")
    }

    func testShortSentenceSkipsTheHeadlineAcrossABlankLine() throws {
        let h = try hit(sentence: "Headline.\n\nSecond one. Third.", headline: "Headline.")
        XCTAssertEqual(TodayFormat.shortSentence(h), "Second one.")
    }

    func testShortSentenceHandlesMixedWhitespaceAfterAPeriod() throws {
        let h = try hit(sentence: "A.  \r\n B.", headline: "A")
        XCTAssertEqual(TodayFormat.shortSentence(h), "B.")
    }

    func testShortSentenceIsEmptyWithNoSentence() throws {
        XCTAssertEqual(TodayFormat.shortSentence(try hit(sentence: nil, headline: "Headline.")), "")
        XCTAssertEqual(TodayFormat.shortSentence(try hit(sentence: "", headline: nil)), "")
        XCTAssertEqual(TodayFormat.shortSentence(try hit(sentence: "Only the headline.", headline: "Only the headline.")), "")
    }

    func testSentencesSplitCleanlyWithNoLeadingWhitespace() {
        XCTAssertEqual(TodayFormat.sentences(" A.\n B. "), ["A.", "B."])
        XCTAssertEqual(TodayFormat.sentences("A.  B."), ["A.", "B."])
        XCTAssertEqual(TodayFormat.sentences("A.\nB"), ["A.", "B"])
        XCTAssertEqual(TodayFormat.sentences("A.\tB."), ["A.", "B."])
        XCTAssertEqual(TodayFormat.sentences(""), [])
        XCTAssertEqual(TodayFormat.sentences("   "), [])
    }

    func testSentencesDoNotSplitInsideANumber() {
        XCTAssertEqual(TodayFormat.sentences("It was 3.5 hours. Fine."), ["It was 3.5 hours.", "Fine."])
    }

    // MARK: TodayLiveSession.apply(reply)

    func testWindowChangeWithAnOldCursorStartsOver() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(points: [[t0, 80], [t0 + 5000, 82]], cursor: 5), requestedCursor: 0)
        XCTAssertEqual(session.points.count, 2)
        XCTAssertEqual(session.cursor, 5)

        // The calendar edit moved the end of the window while we polled with since=5.
        let moved = window.toMs + 600_000
        session.apply(try reply(points: [[t0 + 10_000, 90]], cursor: 9, shiftToMs: moved), requestedCursor: 5)

        XCTAssertEqual(session.points, [], "the held points could be stale after a window change")
        XCTAssertEqual(session.cursor, 0, "next poll asks for everything again")
        XCTAssertEqual(session.status, "")
        XCTAssertEqual(session.window.toMs, moved)
    }

    func testWindowChangeWithCursorZeroTakesTheNormalPath() throws {
        var session = TodayLiveSession(window: window)
        let moved = window.toMs + 600_000
        session.apply(try reply(points: [[t0, 80], [t0 + 5000, 82]], cursor: 7, shiftToMs: moved), requestedCursor: 0)
        XCTAssertEqual(session.points.map(\.bpm), [80, 82])
        XCTAssertEqual(session.cursor, 7)
        XCTAssertEqual(session.status, "")
        XCTAssertEqual(session.window.toMs, moved)
    }

    func testSameWindowMergesPointsAndTakesTheReplyCursor() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        session.apply(try reply(points: [[t0 + 5000, 82]], cursor: 2), requestedCursor: 1)
        XCTAssertEqual(session.points.map(\.bpm), [80, 82])
        XCTAssertEqual(session.cursor, 2)
        XCTAssertEqual(session.status, "")
    }

    func testInactiveReplyClearsEverythingAndSaysOutsideTheWindow() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        session.apply(try reply(active: false, cursor: 4), requestedCursor: 1)
        XCTAssertEqual(session.status, "Outside the live window")
        XCTAssertEqual(session.points, [])
        XCTAssertEqual(session.cursor, 0)
    }

    func testReplyWithNoActiveFlagCountsAsInactive() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(active: nil, points: [[t0, 80]]), requestedCursor: 0)
        XCTAssertEqual(session.status, "Outside the live window")
        XCTAssertEqual(session.points, [])
    }

    func testMessageShowsOutsideTheLiveWindowWhenNothingIsPlotted() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(active: false), requestedCursor: 0)
        let chart = TodayLogic.liveChart(points: session.points, window: session.window, nowMs: t0)
        XCTAssertNil(chart.last)
        XCTAssertEqual(session.message(for: chart), "Outside the live window")
    }

    func testMessageFallsBackToWhatTheReadingsSay() throws {
        var session = TodayLiveSession(window: window)
        let empty = TodayLogic.liveChart(points: [], window: window, nowMs: t0)
        XCTAssertEqual(session.message(for: empty), "Waiting for Meetspike HR on your Mac")
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        let fresh = TodayLogic.liveChart(points: session.points, window: window, nowMs: t0 + 10_000)
        XCTAssertEqual(session.message(for: fresh), "Receiving readings")
        let stale = TodayLogic.liveChart(points: session.points, window: window, nowMs: t0 + 60_000)
        XCTAssertEqual(session.message(for: stale), "Waiting for new readings")
    }

    // MARK: TodayLiveSession.apply(error)

    func testAccessRejectedStopsPollingAndClearsPoints() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        XCTAssertFalse(session.apply(APIError.accessRejected))
        XCTAssertEqual(session.status, "Sign in to resume")
        XCTAssertEqual(session.points, [])
    }

    func testNotFoundKeepsPollingWithAnUnavailableNote() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        XCTAssertTrue(session.apply(APIError.http(status: 404, message: "not found")))
        XCTAssertEqual(session.status, "Live heart rate unavailable")
        XCTAssertEqual(session.points, [])
    }

    func testOtherFailuresKeepPollingAndKeepTheChart() throws {
        var session = TodayLiveSession(window: window)
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        XCTAssertTrue(session.apply(APIError.http(status: 403, message: "forbidden")))
        XCTAssertEqual(session.status, "Reconnecting\u{2026}")
        XCTAssertTrue(session.apply(APIError.offline))
        XCTAssertEqual(session.status, "Reconnecting\u{2026}")
        XCTAssertTrue(session.apply(APIError.http(status: 500, message: "boom")))
        XCTAssertEqual(session.points.count, 1, "a blip keeps what is already drawn")
    }

    // MARK: Poll backoff

    func testPollDelayByFailureCount() {
        for failures in [0, 1, 2] { XCTAssertEqual(TodayLiveSession.pollDelay(failures: failures), 5, "failures \(failures)") }
        for failures in [3, 4, 10] { XCTAssertEqual(TodayLiveSession.pollDelay(failures: failures), 15, "failures \(failures)") }
    }

    func testThreeOfflineFailuresBackOffTo15Seconds() {
        var session = TodayLiveSession(window: window)
        XCTAssertEqual(session.pollDelay, 5)
        _ = session.apply(APIError.offline)
        _ = session.apply(APIError.offline)
        XCTAssertEqual(session.pollDelay, 5, "two in a row is not enough")
        _ = session.apply(APIError.offline)
        XCTAssertEqual(session.failures, 3)
        XCTAssertEqual(session.pollDelay, 15)
    }

    func testNoteFailureCountsAndSetsReconnecting() {
        var session = TodayLiveSession(window: window)
        session.noteFailure()
        XCTAssertEqual(session.failures, 1)
        XCTAssertEqual(session.status, "Reconnecting\u{2026}")
        session.noteFailure()
        session.noteFailure()
        XCTAssertEqual(session.pollDelay, 15)
    }

    func testAGoodReplyResetsTheBackoff() throws {
        var session = TodayLiveSession(window: window)
        session.noteFailure()
        session.noteFailure()
        session.noteFailure()
        XCTAssertEqual(session.pollDelay, 15)
        session.apply(try reply(points: [[t0, 80]], cursor: 1), requestedCursor: 0)
        XCTAssertEqual(session.failures, 0)
        XCTAssertEqual(session.pollDelay, 5)
        XCTAssertEqual(session.status, "", "Reconnecting is cleared by a good answer")
    }

    func testBackoffConstants() {
        XCTAssertEqual(TodayLiveSession.pollSeconds, 5)
        XCTAssertEqual(TodayLiveSession.backoffSeconds, 15)
        XCTAssertEqual(TodayLiveSession.backoffAfterFailures, 3)
    }

    // MARK: liveMeetingID

    func testLatestStartWins() throws {
        let events = [
            try meeting("early", "2026-11-24T14:00:00Z", "2026-11-24T16:00:00Z"),
            try meeting("late", "2026-11-24T14:30:00Z", "2026-11-24T16:00:00Z"),
        ]
        XCTAssertEqual(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:00:00Z")), "late")
        XCTAssertEqual(TodayFormat.liveMeetingID(events: events.reversed(), now: date("2026-11-24T15:00:00Z")), "late")
    }

    func testAMeetingStillRunningBeatsOneThatOnlyHasPadLeft() throws {
        let events = [
            try meeting("long", "2026-11-24T14:00:00Z", "2026-11-24T16:00:00Z"),
            try meeting("short", "2026-11-24T14:30:00Z", "2026-11-24T15:00:00Z"),
        ]
        // 15:05: "short" ended but its pad runs to 15:10 and it started later; "long" is still going.
        XCTAssertEqual(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:05:00Z")), "long")
    }

    func testAMeetingInItsPadIsPickedWhenNothingIsRunning() throws {
        let events = [try meeting("only", "2026-11-24T14:00:00Z", "2026-11-24T15:00:00Z")]
        XCTAssertEqual(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:05:00Z")), "only")
        XCTAssertNil(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T13:55:00Z")), "not before the meeting starts")
    }

    func testNoMeetingAtOrAfterTheEndOfTheWindow() throws {
        let events = [try meeting("only", "2026-11-24T14:00:00Z", "2026-11-24T15:00:00Z")]
        XCTAssertEqual(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:09:59Z")), "only")
        XCTAssertNil(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:10:00Z")), "toMs is exclusive")
        XCTAssertNil(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T16:00:00Z")))
        XCTAssertNil(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T13:49:59Z")))
    }

    func testRecordingsAndLongMeetingsAreNeverPicked() throws {
        let events = [
            try meeting("plaud", "2026-11-24T14:30:00Z", "2026-11-24T16:00:00Z", sourceType: "plaud_phone"),
            try meeting("all-day", "2026-11-24T08:00:00Z", "2026-11-24T20:00:00Z"),
        ]
        XCTAssertNil(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:00:00Z")))
        XCTAssertNil(TodayFormat.liveMeetingID(events: [], now: date("2026-11-24T15:00:00Z")))
    }

    func testARecordingDoesNotStealThePickFromACalendarMeeting() throws {
        let events = [
            try meeting("cal", "2026-11-24T14:00:00Z", "2026-11-24T16:00:00Z"),
            try meeting("plaud", "2026-11-24T14:30:00Z", "2026-11-24T16:00:00Z", sourceType: "plaud"),
        ]
        XCTAssertEqual(TodayFormat.liveMeetingID(events: events, now: date("2026-11-24T15:00:00Z")), "cal")
    }

    // MARK: liveWindowEnded

    // A meeting that ends at 10:00 local-agnostic UTC has its window end (toMs) at 10:10.
    private func tenOClock(sourceType: String? = "calendar", start: String = "2026-11-24T09:00:00Z", end: String = "2026-11-24T10:00:00Z") throws -> [Meeting] {
        [try meeting("m", start, end, sourceType: sourceType)]
    }

    func testWindowEndedWhenItPassedBetweenTwoChecks() throws {
        let events = try tenOClock()
        XCTAssertTrue(TodayLogic.liveWindowEnded(events: events, previous: date("2026-11-24T10:09:50Z"), now: date("2026-11-24T10:10:05Z")))
    }

    func testWindowEndedIsTrueExactlyAtTheEndAndOnlyOnce() throws {
        let events = try tenOClock()
        XCTAssertTrue(TodayLogic.liveWindowEnded(events: events, previous: date("2026-11-24T10:09:00Z"), now: date("2026-11-24T10:10:00Z")), "now == toMs counts")
        XCTAssertFalse(TodayLogic.liveWindowEnded(events: events, previous: date("2026-11-24T10:10:00Z"), now: date("2026-11-24T10:10:20Z")), "previous == toMs already reloaded")
    }

    func testWindowEndedIsFalseWhenItEndedBeforeThePreviousCheck() throws {
        let events = try tenOClock()
        XCTAssertFalse(TodayLogic.liveWindowEnded(events: events, previous: date("2026-11-24T10:10:01Z"), now: date("2026-11-24T10:10:20Z")))
    }

    func testWindowEndedIsFalseWhileTheWindowIsStillOpen() throws {
        let events = try tenOClock()
        XCTAssertFalse(TodayLogic.liveWindowEnded(events: events, previous: date("2026-11-24T10:08:00Z"), now: date("2026-11-24T10:09:00Z")))
    }

    func testWindowEndedIgnoresRecordingsAndLongMeetings() throws {
        XCTAssertFalse(TodayLogic.liveWindowEnded(
            events: try tenOClock(sourceType: "plaud"), previous: date("2026-11-24T10:09:50Z"), now: date("2026-11-24T10:10:05Z")))
        XCTAssertFalse(TodayLogic.liveWindowEnded(
            events: try tenOClock(start: "2026-11-24T01:00:00Z"), previous: date("2026-11-24T10:09:50Z"), now: date("2026-11-24T10:10:05Z")))
        XCTAssertFalse(TodayLogic.liveWindowEnded(events: [], previous: date("2026-11-24T10:09:50Z"), now: date("2026-11-24T10:10:05Z")))
    }

    func testWindowEndedFiresWhenAnyOfSeveralMeetingsEnds() throws {
        let events = try tenOClock() + [try meeting("later", "2026-11-24T13:00:00Z", "2026-11-24T14:00:00Z")]
        XCTAssertTrue(TodayLogic.liveWindowEnded(events: events, previous: date("2026-11-24T14:09:50Z"), now: date("2026-11-24T14:10:05Z")))
    }

    // MARK: Auto refresh throttle and stale load

    func testAutoRefreshThrottleUsesTheLocalLastSync() {
        let now = date("2026-11-24T15:00:00Z")
        XCTAssertTrue(TodayLogic.shouldAutoRefresh(lastSync: nil, now: now))
        XCTAssertFalse(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-119), now: now))
        XCTAssertTrue(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-120), now: now))
        XCTAssertTrue(TodayLogic.shouldAutoRefresh(lastSync: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(TodayLogic.shouldAutoRefresh(lastSync: now, now: now))
        XCTAssertEqual(TodayLogic.refreshThrottleSeconds, 120)
    }

    func testStaleLoadIsDroppedWhenTheDayChanged() {
        XCTAssertTrue(TodayLogic.isStaleLoad(requested: "2026-11-23", selected: "2026-11-24"))
        XCTAssertFalse(TodayLogic.isStaleLoad(requested: "2026-11-24", selected: "2026-11-24"))
    }
}
