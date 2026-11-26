import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9, shared Swift contract: the Mac's "did you really join" tracker (pure) and the Zoom link check.
//
// NEW API (names fixed here):
//
//   public enum ZoomLink
//       public static func isZoom(text: String) -> Bool
//   public struct TrackedMeeting: Equatable, Sendable
//       public var id: String, title: String, start: Date, end: Date, hasZoom: Bool
//       public init(id: String, title: String, start: Date, end: Date, hasZoom: Bool)
//   public struct AttendanceReport: Equatable, Sendable, Encodable
//       public var id: String               the TrackedMeeting id (not in the body)
//       public var meetingStart: Date       the TrackedMeeting start, the ORIGINAL calendar start (what the Worker matches on)
//       public var title: String
//       public var seenStart: Date?, seenEnd: Date?
//       public var seenNone: Bool
//       public init(id:meetingStart:title:seenStart:seenEnd:seenNone:)
//     `JSONEncoder().encode(report)` (no strategies) is the body of POST /api/whoop-web/app/attendance:
//       { meetingStartUtc: ISO, title: text, seenStartUtc: ISO|null, seenEndUtc: ISO|null, seenNone: bool }
//       all five keys always present (null when there is no time), nothing else.
//   public struct AttendanceTracker: Sendable
//       public init()
//       public mutating func observe(now: Date, zoomRunning: Bool, awake: Bool, meetings: [TrackedMeeting]) -> [AttendanceReport]
//
// The Mac calls observe about every 15 s, always (not only while recording), with the same list of meetings each time.
// Rules ("Attendance rule, corrected" in the build 9 spec), with the readings this file pins:
//   - Only meetings with hasZoom are tracked, and only if end is after start. Others never produce a report.
//   - A Zoom SESSION is a run of samples with zoomRunning true and awake true. A sample with Zoom closed, with
//     awake false, or a gap of more than 60 s since the previous sample (60 itself is fine) ends the session.
//   - Lead: sightings count from the later of (start - 15 min) and the scheduled end of the latest earlier Zoom
//     meeting that ends at or before this meeting's start (so back-to-back calls do not bleed backwards). Fix pass F7:
//     a session before the start counts only if it is still running, unbroken, at the start (Build9FixF7AttendanceLeadTests).
//   - Between lead and the scheduled end every session counts: leaving and rejoining is fine.
//   - Tail: past the scheduled end only the session that was already running at the end counts, and only while it
//     stays unbroken. A session that starts after the end never counts, however soon after.
//   - The tail stops at the start of the next meeting that has a Zoom link (the sighting is clipped to that start, so
//     seenEnd is that start) and at end + 4 h. A next meeting without a Zoom link does not stop it.
//   - seenStart/seenEnd are the first and last counted sample times. Never joined before the end means not seen,
//     even if Zoom opens later. seenNone (true, no times) is sent only when watched time was at least 90 % of the
//     scheduled length. Watching: time between two samples counts only when they are 60 s apart or less and the Mac
//     was awake, only the part inside [start, end], and time before the first sample is not watched.
//   - Reported ONCE, never again: right at the first sample at or after the end if no counted session is running
//     then, otherwise when that session's tail ends (Zoom closed, session broken, the next Zoom meeting starts, or
//     end + 4 h). If the Mac slept over the end, it is reported on wake with the last sighting before the gap as
//     seenEnd.
//   - Two Zoom meetings whose scheduled times overlap (more than touching) get no report at all. Touching meetings do
//     not overlap. A meeting without a Zoom link never counts as an overlap.


final class Build9ZoomLinkTests: XCTestCase {
    func testZoomLinksAreRecognised() {
        let yes = [
            "https://us02web.zoom.us/j/81234567890?pwd=abcDEF123",
            "https://zoom.us/j/123456789",
            "https://company.zoom.us/my/hershey",
            "https://us06web.zoom.us/wc/join/81234567890",
            "https://acme.zoomgov.com/j/1600123456",
            "https://zoomgov.com/j/1600123456",
            "zoom.us/j/123456789",
            "HTTPS://US02WEB.ZOOM.US/J/123456789",
            "Join Zoom Meeting\nhttps://us02web.zoom.us/j/81234567890\nMeeting ID: 812 3456 7890",
            "Dial in or open https://meet.google.com/abc-defg-hij or https://zoom.us/j/55555",
            "<a href=\"https://us02web.zoom.us/j/81234567890\">join</a>",
        ]
        for text in yes { XCTAssertTrue(ZoomLink.isZoom(text: text), text) }
    }

    func testOtherLinksAndPlainWordsAreNotZoom() {
        let no = [
            "",
            "   ",
            "https://meet.google.com/abc-defg-hij",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting",
            "https://acme.webex.com/meet/hershey",
            "Zoom call tomorrow",
            "zoom",
            "Conference room 4, bring a zoom lens",
            "https://notzoom.us/j/123",
            "https://fakezoom.us/j/123",
            "https://zoom.us.evil.example/j/123",
            "https://example.com/redirect?to=zoom.us",
            "https://example.com/zoomgov.com",
        ]
        for text in no { XCTAssertFalse(ZoomLink.isZoom(text: text), text) }
    }
}

// MARK: Tracker

/// Drives the tracker the way the Mac does and remembers when each report came out.
private struct Rig {
    var tracker = AttendanceTracker()
    var emitted: [(at: TimeInterval, report: AttendanceReport)] = []
    var meetings: [TrackedMeeting]

    init(_ meetings: [TrackedMeeting]) { self.meetings = meetings }

    var reports: [AttendanceReport] { emitted.map(\.report) }

    func reports(for id: String) -> [AttendanceReport] { reports.filter { $0.id == id } }

    mutating func run(
        from: TimeInterval, to: TimeInterval, step: TimeInterval = 15,
        zoom: (TimeInterval) -> Bool = { _ in false }, awake: (TimeInterval) -> Bool = { _ in true }
    ) {
        var t = from
        while t <= to {
            for report in tracker.observe(now: B9.at(t), zoomRunning: zoom(t), awake: awake(t), meetings: meetings) {
                emitted.append((t, report))
            }
            t += step
        }
    }
}

final class Build9AttendanceTests: XCTestCase {
    /// 30 minutes starting at the base time, with a Zoom link. Sampling starts 20 minutes early.
    private let meeting = TrackedMeeting(id: "m1", title: "Standup", start: B9.at(0), end: B9.at(1800), hasZoom: true)
    private let hour: TimeInterval = 3600

    // MARK: Nothing seen

    func testAMeetingNobodyJoinedIsReportedAtItsEnd() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 600)
        XCTAssertEqual(rig.emitted.count, 1)
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertEqual(at, 1800, "at the first sample at or after the end")
        XCTAssertEqual(report, AttendanceReport(id: "m1", meetingStart: B9.at(0), title: "Standup",
                                                seenStart: nil, seenEnd: nil, seenNone: true))
    }

    func testNothingIsReportedBeforeTheEnd() {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1785)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testAReportComesOnlyOnce() {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 5 * hour)
        XCTAssertEqual(rig.reports(for: "m1").count, 1)
    }

    func testNoMeetingsAndNoZoomMeansNothing() {
        var rig = Rig([])
        rig.run(from: 0, to: 3600, zoom: { _ in true })
        XCTAssertEqual(rig.emitted.count, 0)
    }

    // MARK: Seen

    func testSeenTimesAreTheFirstAndLastSampleWithZoom() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 600, zoom: { (30...1740).contains($0) })
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(at, 1800)
        XCTAssertEqual(report.seenStart, B9.at(30))
        XCTAssertEqual(report.seenEnd, B9.at(1740))
        XCTAssertFalse(report.seenNone)
        XCTAssertEqual(report.meetingStart, B9.at(0), "the original calendar start")
        XCTAssertEqual(report.title, "Standup")
        XCTAssertEqual(report.id, "m1")
    }

    func testZoomOnForOneSampleIsASighting() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 600, zoom: { $0 == 900 })
        let report = try XCTUnwrap(rig.reports.first)
        XCTAssertEqual(report.seenStart, B9.at(900))
        XCTAssertEqual(report.seenEnd, B9.at(900))
        XCTAssertFalse(report.seenNone)
    }

    func testZoomExactlyFifteenMinutesBeforeTheStartCountsAndOneSampleEarlierDoesNot() throws {
        // Fix pass F7: the session has to be running at the start, so it is open from -900 through the start now
        // (it was a single sample at -900 before, which is a call that ended before the meeting).
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 600, zoom: { (-900...0).contains($0) })
        let report = try XCTUnwrap(rig.reports.first)
        XCTAssertEqual(report.seenStart, B9.at(-900))
        XCTAssertFalse(report.seenNone)

        var early = Rig([meeting])
        early.run(from: -1200, to: 1800 + 600, zoom: { $0 == -915 || $0 == -930 })
        let none = try XCTUnwrap(early.reports.first)
        XCTAssertTrue(none.seenNone, "Zoom 16 minutes early is another call")
        XCTAssertNil(none.seenStart)
        XCTAssertEqual(early.reports.count, 1)
    }


    // MARK: Zoom still open at the end

    func testWithZoomStillRunningAtTheEndTheReportWaitsForItToClose() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 2100 + 600, zoom: { (600...2100).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertEqual(at, 2115, "the first sample with Zoom closed")
        XCTAssertEqual(report.seenStart, B9.at(600))
        XCTAssertEqual(report.seenEnd, B9.at(2100))
        XCTAssertFalse(report.seenNone)
    }

    func testZoomThatNeverClosesIsReportedWhenTheWindowEnds() throws {
        let limit = 1800 + 4 * hour
        var rig = Rig([meeting])
        rig.run(from: -1200, to: limit + 3600, zoom: { $0 >= 600 })
        XCTAssertEqual(rig.emitted.count, 1)
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertGreaterThanOrEqual(at, limit)
        XCTAssertLessThanOrEqual(at, limit + 15)
        XCTAssertEqual(report.seenStart, B9.at(600))
        XCTAssertEqual(report.seenEnd, B9.at(limit))
        XCTAssertFalse(report.seenNone)
    }

    // MARK: Sessions and the tail

    func testACallThatStartsAfterTheEndNeverCounts() throws {
        // Closed at the end, then an unrelated call 15 minutes later and another hours after.
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 5 * hour, zoom: { (2700...3600).contains($0) || (9000...10_000).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertEqual(at, 1800)
        XCTAssertTrue(report.seenNone, "never joined before the end is not seen, even if Zoom opens later")
        XCTAssertNil(report.seenStart)
        XCTAssertNil(report.seenEnd)
    }

    func testACallThatOpensOneSampleAfterTheEndNeverCounts() {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 3 * hour, zoom: { $0 >= 1815 })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertTrue(rig.reports[0].seenNone)
        XCTAssertEqual(rig.emitted[0].at, 1800)
    }

    func testJoiningLateInsideTheMeetingCounts() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 600, zoom: { (1200...1500).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.reports[0].seenStart, B9.at(1200))
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(1500))
        XCTAssertFalse(rig.reports[0].seenNone)
    }

    func testLeavingAndRejoiningInsideTheMeetingCounts() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 600, zoom: { (60...600).contains($0) || (900...1500).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted[0].at, 1800)
        XCTAssertEqual(rig.reports[0].seenStart, B9.at(60))
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(1500), "both sessions count")
    }

    func testAnUnbrokenOverrunCountsUntilItCloses() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 3600 + 600, zoom: { (600...2400).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted[0].at, 2415, "the first sample with Zoom closed")
        XCTAssertEqual(rig.reports[0].seenStart, B9.at(600))
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(2400))
    }

    func testABrokenOverrunStopsAtTheBreakAndTheNextCallIsNotCounted() throws {
        // On Zoom through the end, closed for one sample, a different call straight after.
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { (600...1950).contains($0) || (1980...2400).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted[0].at, 1965)
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(1950))
    }

    func testAMacThatStopsBeingAwakeBreaksTheSession() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { $0 >= 600 && $0 <= 2400 }, awake: { $0 != 1950 })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted[0].at, 1950, "the tail ended when the Mac stopped being awake")
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(1935))
    }

    func testAGapOverSixtySecondsBreaksTheSessionButSixtyDoesNot() throws {
        // 90 s gap across the end, Zoom open on both sides: the first sample back starts a new session after the end.
        var broken = Rig([meeting])
        broken.run(from: -1200, to: 1845, zoom: { $0 >= 600 })
        broken.run(from: 1935, to: 3600 + 5 * hour, zoom: { $0 <= 2400 })
        XCTAssertEqual(broken.emitted.count, 1)
        XCTAssertEqual(broken.emitted[0].at, 1935, "reported as soon as the Mac is back")
        XCTAssertEqual(broken.reports[0].seenEnd, B9.at(1845))

        // 60 s gap: still one session.
        var kept = Rig([meeting])
        kept.run(from: -1200, to: 1830, zoom: { $0 >= 600 })
        kept.run(from: 1890, to: 3600 + 5 * hour, zoom: { (600...2400).contains($0) })
        XCTAssertEqual(kept.emitted.count, 1)
        XCTAssertEqual(kept.emitted[0].at, 2415)
        XCTAssertEqual(kept.reports[0].seenEnd, B9.at(2400))
    }

    func testSleepingOverTheEndReportsOnWakeWithTheLastSightingBeforeTheGap() throws {
        for zoomAtWake in [false, true] {
            var rig = Rig([meeting])
            rig.run(from: -1200, to: 1695, zoom: { $0 >= 600 })
            rig.run(from: 3600, to: 3600 + 5 * hour, zoom: { _ in zoomAtWake })
            XCTAssertEqual(rig.emitted.count, 1, "zoom at wake \(zoomAtWake)")
            XCTAssertEqual(rig.emitted.first?.at, 3600, "on wake")
            XCTAssertEqual(rig.reports.first?.seenStart, B9.at(600))
            XCTAssertEqual(rig.reports.first?.seenEnd, B9.at(1695))
            XCTAssertFalse(rig.reports.first?.seenNone ?? true)
        }
    }

    func testAMeetingIsReportedOnceWhateverHappensLater() throws {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1800 + 6 * hour,
                zoom: { (600...1500).contains($0) || (2010...2295).contains($0) || (12_000...13_000).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(1500))
    }

    func testZoomOpenAtTheEndThenClosedIsOneReportNotTwo() {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 3600, zoom: { (1500...2000).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted[0].at, 2010)
        XCTAssertEqual(rig.reports[0].seenStart, B9.at(1500))
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(1995))
    }


    // MARK: Zoom link and invalid meetings

    func testAMeetingWithoutAZoomLinkIsNeverReported() {
        let plain = TrackedMeeting(id: "p", title: "Lunch", start: B9.at(0), end: B9.at(1800), hasZoom: false)
        var rig = Rig([plain])
        rig.run(from: -1200, to: 1800 + 5 * hour)
        XCTAssertEqual(rig.emitted.count, 0, "nothing seen, fully watched")
        var withZoom = Rig([plain])
        withZoom.run(from: -1200, to: 1800 + 5 * hour, zoom: { (0...1800).contains($0) })
        XCTAssertEqual(withZoom.emitted.count, 0, "Zoom ran, but this meeting has no link")
    }

    func testMeetingsThatEndBeforeTheyStartAreIgnored() {
        let zero = TrackedMeeting(id: "z", title: "Zero", start: B9.at(0), end: B9.at(0), hasZoom: true)
        let reversed = TrackedMeeting(id: "r", title: "Reversed", start: B9.at(100), end: B9.at(50), hasZoom: true)
        var rig = Rig([zero, reversed])
        rig.run(from: -1200, to: 3600, zoom: { _ in true })
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testTwoMeetingsInOneDayAreEachReportedOnceAtTheirOwnEnd() throws {
        let later = TrackedMeeting(id: "m2", title: "Retro", start: B9.at(7200), end: B9.at(9000), hasZoom: true)
        var rig = Rig([meeting, later])
        rig.run(from: -1200, to: 9000 + 600, zoom: { (0...1700).contains($0) })
        XCTAssertEqual(rig.emitted.count, 2)
        XCTAssertEqual(rig.emitted[0].report.id, "m1")
        XCTAssertFalse(rig.emitted[0].report.seenNone)
        XCTAssertEqual(rig.emitted[1].report.id, "m2")
        XCTAssertEqual(rig.emitted[1].at, 9000)
        XCTAssertTrue(rig.emitted[1].report.seenNone)
        XCTAssertEqual(rig.emitted[1].report.title, "Retro")
    }

    // MARK: Overlapping Zoom meetings

    func testOverlappingZoomMeetingsGetNoReportForEither() {
        let other = TrackedMeeting(id: "m2", title: "Planning", start: B9.at(900), end: B9.at(2700), hasZoom: true)
        var joined = Rig([meeting, other])
        joined.run(from: -1200, to: 2700 + 5 * hour, zoom: { (0...2700).contains($0) })
        XCTAssertEqual(joined.emitted.count, 0, "Zoom was open, but it is not known for which of the two")
        var none = Rig([meeting, other])
        none.run(from: -1200, to: 2700 + 5 * hour)
        XCTAssertEqual(none.emitted.count, 0, "and no \"didn't join\" for either")
    }

    func testOneMeetingInsideAnotherIsAnOverlapToo() {
        let inner = TrackedMeeting(id: "in", title: "Inner", start: B9.at(600), end: B9.at(1200), hasZoom: true)
        var rig = Rig([meeting, inner])
        rig.run(from: -1200, to: 1800 + 5 * hour)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testTheSameTimeTwiceIsAnOverlap() {
        let twin = TrackedMeeting(id: "m1b", title: "Standup (copy)", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        var rig = Rig([meeting, twin])
        rig.run(from: -1200, to: 1800 + 5 * hour)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testAMeetingWithNoZoomLinkDoesNotBlockAZoomMeeting() throws {
        let plain = TrackedMeeting(id: "p", title: "Hold", start: B9.at(900), end: B9.at(2700), hasZoom: false)
        var rig = Rig([meeting, plain])
        rig.run(from: -1200, to: 1800 + 600, zoom: { (0...1700).contains($0) })
        XCTAssertEqual(rig.reports(for: "m1").count, 1)
        XCTAssertEqual(rig.reports(for: "p").count, 0)
    }

    func testAnOverlapBlocksOnlyTheMeetingsInIt() throws {
        let overlapA = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let overlapB = TrackedMeeting(id: "b", title: "B", start: B9.at(900), end: B9.at(2700), hasZoom: true)
        let clear = TrackedMeeting(id: "c", title: "C", start: B9.at(20_000), end: B9.at(21_800), hasZoom: true)
        var rig = Rig([overlapA, overlapB, clear])
        rig.run(from: -1200, to: 21_800 + 600, zoom: { (20_010...21_690).contains($0) })
        XCTAssertEqual(rig.reports(for: "a").count, 0)
        XCTAssertEqual(rig.reports(for: "b").count, 0)
        let report = try XCTUnwrap(rig.reports(for: "c").first)
        XCTAssertFalse(report.seenNone)
        XCTAssertEqual(report.seenStart, B9.at(20_010))
        XCTAssertEqual(report.seenEnd, B9.at(21_690))
    }

    // MARK: Back-to-back calls

    func testBackToBackSeparateCallsEachGetTheirOwnSession() throws {
        // A 0:00 to 0:30, B 0:30 to 1:00. The person leaves the first call and opens a second one.
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(1800), end: B9.at(3600), hasZoom: true)
        var rig = Rig([a, b])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { (-300...1785).contains($0) || (1830...3585).contains($0) })
        let ra = rig.reports(for: "a")
        let rb = rig.reports(for: "b")
        XCTAssertEqual(ra.count, 1)
        XCTAssertEqual(rb.count, 1)
        XCTAssertEqual(ra.first?.seenStart, B9.at(-300))
        XCTAssertEqual(ra.first?.seenEnd, B9.at(1785), "the second call starts after A ended: it is not A's")
        XCTAssertEqual(rb.first?.seenStart, B9.at(1830), "the first call ended before B's lead began: it is not B's")
        XCTAssertEqual(rb.first?.seenEnd, B9.at(3585))
        XCTAssertEqual(rig.emitted.first { $0.report.id == "a" }?.at, 1800)
        XCTAssertEqual(rig.emitted.first { $0.report.id == "b" }?.at, 3600)
        XCTAssertFalse(ra.first?.seenNone ?? true)
        XCTAssertFalse(rb.first?.seenNone ?? true)
    }

    func testOneUnbrokenSessionAcrossBackToBackCallsIsSplitAtTheBoundary() throws {
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(1800), end: B9.at(3600), hasZoom: true)
        var rig = Rig([a, b])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { (-300...3585).contains($0) })
        let ra = try XCTUnwrap(rig.reports(for: "a").first)
        let rb = try XCTUnwrap(rig.reports(for: "b").first)
        XCTAssertEqual(rig.reports(for: "a").count, 1)
        XCTAssertEqual(rig.reports(for: "b").count, 1)
        XCTAssertEqual(ra.seenStart, B9.at(-300))
        XCTAssertEqual(ra.seenEnd, B9.at(1800), "A's tail stops where B starts (clipped to that start)")
        XCTAssertEqual(rig.emitted.first { $0.report.id == "a" }?.at, 1800, "A is done the moment B starts")
        let bStart = try XCTUnwrap(rb.seenStart)
        XCTAssertGreaterThanOrEqual(bStart, B9.at(1800), "B's lead starts where A ended")
        XCTAssertLessThanOrEqual(bStart, B9.at(1815))
        XCTAssertEqual(rb.seenEnd, B9.at(3585))
        XCTAssertEqual(rig.emitted.first { $0.report.id == "b" }?.at, 3600)
    }

    func testACallInsideTheFirstMeetingIsNotTheSecondMeetings() throws {
        // Zoom is closed at the end of A. It was open for B's 15 minute lead, but that lead starts at A's end.
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(1800), end: B9.at(3600), hasZoom: true)
        var rig = Rig([a, b])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { (1500...1785).contains($0) })
        let ra = try XCTUnwrap(rig.reports(for: "a").first)
        let rb = try XCTUnwrap(rig.reports(for: "b").first)
        XCTAssertFalse(ra.seenNone)
        XCTAssertEqual(ra.seenStart, B9.at(1500))
        XCTAssertEqual(ra.seenEnd, B9.at(1785))
        XCTAssertTrue(rb.seenNone, "B never saw Zoom: nothing before A's end is B's")
        XCTAssertNil(rb.seenStart)
    }

    func testTheLatestEarlierZoomMeetingSetsTheLead() throws {
        let a1 = TrackedMeeting(id: "a1", title: "A1", start: B9.at(0), end: B9.at(600), hasZoom: true)
        let a2 = TrackedMeeting(id: "a2", title: "A2", start: B9.at(600), end: B9.at(1200), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(1200), end: B9.at(1800), hasZoom: true)
        var rig = Rig([a1, a2, b])
        rig.run(from: -1200, to: 1800 + 5 * hour, zoom: { (1005...1185).contains($0) })
        let rb = try XCTUnwrap(rig.reports(for: "b").first)
        XCTAssertTrue(rb.seenNone)
        let ra2 = try XCTUnwrap(rig.reports(for: "a2").first)
        XCTAssertEqual(ra2.seenStart, B9.at(1005))
        XCTAssertEqual(ra2.seenEnd, B9.at(1185))
    }

    func testAnEarlierMeetingThatEndedLongAgoLeavesTheNormalLead() throws {
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(7200), end: B9.at(9000), hasZoom: true)
        var rig = Rig([a, b])
        rig.run(from: -1200, to: 9000 + 600, zoom: { (6300...7200).contains($0) })
        let rb = try XCTUnwrap(rig.reports(for: "b").first)
        XCTAssertEqual(rb.seenStart, B9.at(6300), "15 minutes before B")
        XCTAssertEqual(rb.seenEnd, B9.at(7200))
        XCTAssertTrue(try XCTUnwrap(rig.reports(for: "a").first).seenNone)
    }

    func testAnEarlierMeetingWithoutAZoomLinkDoesNotCutTheLead() throws {
        let plain = TrackedMeeting(id: "p", title: "Plain", start: B9.at(0), end: B9.at(1800), hasZoom: false)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(1800), end: B9.at(3600), hasZoom: true)
        var rig = Rig([plain, b])
        rig.run(from: -1200, to: 3600 + 600, zoom: { (1500...1800).contains($0) })
        XCTAssertEqual(rig.reports(for: "b").first?.seenStart, B9.at(1500))
        XCTAssertEqual(rig.reports(for: "p").count, 0)
    }

    func testTheTailStopsAtTheNextZoomMeetingEvenWithAGapBetween() throws {
        // A ends 0:30, B starts 0:40. One long session from 0:10 to 0:50.
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(2400), end: B9.at(3600), hasZoom: true)
        var rig = Rig([a, b])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { (600...3000).contains($0) })
        let ra = rig.reports(for: "a")
        XCTAssertEqual(ra.count, 1)
        XCTAssertEqual(ra.first?.seenStart, B9.at(600))
        XCTAssertEqual(ra.first?.seenEnd, B9.at(2400), "clipped to B's start")
        XCTAssertEqual(rig.emitted.first { $0.report.id == "a" }?.at, 2400)
        let rb = rig.reports(for: "b")
        XCTAssertEqual(rb.count, 1)
        let bStart = try XCTUnwrap(rb.first?.seenStart)
        XCTAssertGreaterThanOrEqual(bStart, B9.at(1800), "B's lead is cut at A's end")
        XCTAssertLessThanOrEqual(bStart, B9.at(1815))
        XCTAssertEqual(rb.first?.seenEnd, B9.at(3000))
    }

    func testANextMeetingWithoutAZoomLinkDoesNotStopTheTail() throws {
        let plain = TrackedMeeting(id: "p", title: "Plain", start: B9.at(1800), end: B9.at(3600), hasZoom: false)
        var rig = Rig([meeting, plain])
        rig.run(from: -1200, to: 3600 + 5 * hour, zoom: { (600...2400).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted[0].at, 2415, "when Zoom closed")
        XCTAssertEqual(rig.reports[0].seenEnd, B9.at(2400))
    }

    func testBackToBackMeetingsAreNotAnOverlap() throws {
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(1800), end: B9.at(3600), hasZoom: true)
        var rig = Rig([a, b])
        rig.run(from: -1200, to: 3600 + 600)
        XCTAssertEqual(rig.reports(for: "a").count, 1)
        XCTAssertEqual(rig.reports(for: "b").count, 1, "both are reported (not joined)")
    }


    // MARK: Watching: sleep, quit, gaps

    /// Watches until `before`, then nothing until `after`, then watches again until the end of the day.
    private func rigWithAGap(from before: TimeInterval, to after: TimeInterval, zoom: (TimeInterval) -> Bool = { _ in false }) -> Rig {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: before, zoom: zoom)
        rig.run(from: after, to: 1800 + 5 * hour, zoom: zoom)
        return rig
    }

    func testAShortSleepStillReportsDidntJoin() {
        // 120 s gap: 1680 of 1800 s watched, 93 %.
        let rig = rigWithAGap(from: 600, to: 720)
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
    }

    func testExactlyNinetyPercentIsEnough() {
        // 180 s gap: 1620 of 1800 s watched, exactly 90 %.
        let rig = rigWithAGap(from: 600, to: 780)
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
    }

    func testJustUnderNinetyPercentReportsNothing() {
        // 210 s gap: 1590 of 1800 s watched, 88 %.
        let rig = rigWithAGap(from: 600, to: 810)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testALongSleepReportsNothing() {
        let rig = rigWithAGap(from: 600, to: 1500)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testAGapOfSixtySecondsIsStillWatchingAndOverSixtyIsNot() {
        // The whole meeting sampled once a minute is watched. Once every 75 s it is not, so nothing is reported.
        var sixty = Rig([meeting])
        sixty.run(from: -1200, to: 1800 + 3600, step: 60)
        XCTAssertEqual(sixty.reports.count, 1)
        XCTAssertTrue(sixty.reports.first?.seenNone ?? false)

        var seventyFive = Rig([meeting])
        seventyFive.run(from: -1200, to: 1800 + 3600, step: 75)
        XCTAssertEqual(seventyFive.emitted.count, 0)
    }

    func testTheMacAsleepAtTheStartAndWakingLateReportsNothing() {
        // Awake from 5 minutes in: 1500 of 1800 s, 83 %.
        var rig = Rig([meeting])
        rig.run(from: 300, to: 1800 + 3600)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testWatchingFromTwoMinutesInIsStillEnough() {
        var rig = Rig([meeting])
        rig.run(from: 120, to: 1800 + 3600)
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
    }

    func testTheMacSleepingFromTwentyMinutesInReportsNothingEvenOnWaking() {
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 1200)
        rig.run(from: 1800 + 3600, to: 1800 + 5 * hour)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testNeverWatchingMeansNeverReporting() {
        var rig = Rig([meeting])
        rig.run(from: 1800 + 5 * hour, to: 1800 + 6 * hour)
        XCTAssertEqual(rig.emitted.count, 0)
    }

    func testSleepingThroughTheEndStillReportsWhenItWakesIfTheMeetingWasWatched() throws {
        // Watched to 29:45 of 30:00, then asleep. The first sample after waking is past the end: report then.
        let rig = rigWithAGap(from: 1785, to: 1800 + 2 * hour)
        XCTAssertEqual(rig.emitted.count, 1)
        XCTAssertEqual(rig.emitted.first?.at, 1800 + 2 * hour)
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
    }

    func testNotAwakeIsNotWatching() {
        // Awake false (locked out) for 2 minutes is fine, for 4 minutes is not.
        var short = Rig([meeting])
        short.run(from: -1200, to: 1800 + 3600, awake: { !(600 < $0 && $0 <= 720) })
        XCTAssertEqual(short.emitted.count, 1)
        XCTAssertTrue(short.reports.first?.seenNone ?? false)

        var long = Rig([meeting])
        long.run(from: -1200, to: 1800 + 3600, awake: { !(600 < $0 && $0 <= 840) })
        XCTAssertEqual(long.emitted.count, 0)
    }

    func testAMeetingSeenButNotFullyWatchedIsStillReportedWithWhatWasSeen() throws {
        // Slept 10 to 25 minutes in, Zoom was open when the Mac went to sleep and after it woke.
        var rig = Rig([meeting])
        rig.run(from: -1200, to: 600, zoom: { (300...600).contains($0) })
        rig.run(from: 1500, to: 1800 + 3600, zoom: { (1500...1740).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        let report = try XCTUnwrap(rig.reports.first)
        XCTAssertFalse(report.seenNone)
        XCTAssertEqual(report.seenStart, B9.at(300))
        XCTAssertEqual(report.seenEnd, B9.at(1740))
    }

    // MARK: DST

    func testAMeetingAcrossAFallBackIsWatchedInRealSeconds() throws {
        // One real hour that the wall clock shows as 01:30 to 01:30. Sampled every 15 s the whole time: fully watched.
        B9.inZones(B9.zones) { zone in
            let start = B9.fallBackInstant
            let end = start.addingTimeInterval(3600)
            let night = TrackedMeeting(id: "n", title: "Night shift", start: start, end: end, hasZoom: true)
            var tracker = AttendanceTracker()
            var reports: [AttendanceReport] = []
            var t = start.addingTimeInterval(-1200)
            while t <= end.addingTimeInterval(600) {
                reports += tracker.observe(now: t, zoomRunning: false, awake: true, meetings: [night])
                t = t.addingTimeInterval(15)
            }
            XCTAssertEqual(reports.count, 1, zone)
            XCTAssertTrue(reports.first?.seenNone ?? false, zone)
            XCTAssertEqual(reports.first?.meetingStart, start, zone)
        }
    }

    func testAMeetingAcrossASpringForwardIsWatchedInRealSeconds() throws {
        B9.inZones(B9.zones) { zone in
            let start = B9.springForwardInstant
            let end = start.addingTimeInterval(3600)
            let early = TrackedMeeting(id: "e", title: "Early call", start: start, end: end, hasZoom: true)
            var tracker = AttendanceTracker()
            var reports: [AttendanceReport] = []
            var t = start
            while t <= end.addingTimeInterval(600) {
                // Zoom open for the middle 40 minutes.
                let zoom = t >= start.addingTimeInterval(600) && t <= start.addingTimeInterval(3000)
                reports += tracker.observe(now: t, zoomRunning: zoom, awake: true, meetings: [early])
                t = t.addingTimeInterval(15)
            }
            XCTAssertEqual(reports.count, 1, zone)
            XCTAssertEqual(reports.first?.seenStart, start.addingTimeInterval(600), zone)
            XCTAssertEqual(reports.first?.seenEnd, start.addingTimeInterval(3000), zone)
        }
    }

    // MARK: Time going backwards

    func testAClockSetBackDoesNotReportTheSameMeetingTwice() {
        var tracker = AttendanceTracker()
        var reports: [AttendanceReport] = []
        // The whole meeting and its end, then the clock goes back an hour and the same stretch is sampled again.
        for step in 0...(2000 / 15) {
            reports += tracker.observe(now: B9.at(Double(step) * 15), zoomRunning: false, awake: true, meetings: [meeting])
        }
        XCTAssertEqual(reports.count, 1)
        for step in 0...((2000 + 3600) / 15) {
            reports += tracker.observe(now: B9.at(-3600 + Double(step) * 15), zoomRunning: false, awake: true, meetings: [meeting])
        }
        XCTAssertEqual(reports.count, 1, "already reported: nothing new was seen")
    }
}

// MARK: Report body

final class Build9AttendanceBodyTests: XCTestCase {
    private func body(_ report: AttendanceReport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    }

    func testASeenReportIsTheFiveKeysTheWorkerExpects() throws {
        let report = AttendanceReport(id: "m1", meetingStart: B9.at(0), title: "Standup",
                                      seenStart: B9.at(30), seenEnd: B9.at(1740.5), seenNone: false)
        let object = try body(report)
        XCTAssertEqual(Set(object.keys), ["meetingStartUtc", "title", "seenStartUtc", "seenEndUtc", "seenNone"])
        XCTAssertEqual(APITime.parse(object["meetingStartUtc"] as? String), B9.at(0))
        XCTAssertEqual(APITime.parse(object["seenStartUtc"] as? String), B9.at(30))
        XCTAssertEqual(APITime.parse(object["seenEndUtc"] as? String), B9.at(1740.5))
        XCTAssertEqual(object["title"] as? String, "Standup")
        XCTAssertEqual(object["seenNone"] as? Bool, false)
        for key in ["meetingStartUtc", "seenStartUtc", "seenEndUtc"] {
            XCTAssertTrue((object[key] as? String)?.hasSuffix("Z") ?? false, key)
        }
    }

    func testANotJoinedReportHasNullTimes() throws {
        let report = AttendanceReport(id: "m1", meetingStart: B9.at(0), title: "Standup", seenStart: nil, seenEnd: nil, seenNone: true)
        let object = try body(report)
        XCTAssertEqual(Set(object.keys), ["meetingStartUtc", "title", "seenStartUtc", "seenEndUtc", "seenNone"])
        XCTAssertTrue(object["seenStartUtc"] is NSNull)
        XCTAssertTrue(object["seenEndUtc"] is NSNull)
        XCTAssertEqual(object["seenNone"] as? Bool, true)
    }

    func testTheBodyHasNoMeetingIDAndDoesNotDependOnTheTimeZone() throws {
        var bodies: Set<String> = []
        try B9.inZones(B9.zones) { _ in
            let report = AttendanceReport(id: "secret-id", meetingStart: B9.at(0), title: "Standup", seenStart: B9.at(30), seenEnd: B9.at(60), seenNone: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bodies.insert(String(decoding: try encoder.encode(report), as: UTF8.self))
        }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies.first?.contains("secret-id") ?? true)
    }
}
