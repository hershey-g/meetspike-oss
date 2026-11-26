import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 fix pass, F7: the attendance lead only counts a Zoom session that is still running at the scheduled start.
//
// A Zoom session before the scheduled start counts only if it is still running, unbroken, at the scheduled start (then
// seenStart is when it began, clipped to the lead as before: never earlier than start - 15 min, or the end of the
// latest earlier Zoom meeting). A session that ended before the start is not a sighting and does not stop seenNone.
// A session is broken by a sample with Zoom closed, with the Mac not awake, or a gap of more than 60 s. Everything
// from the start to the end, and the tail, is unchanged.
//
// Drives the tracker as the Mac does: a sample every 15 s, from 20 minutes before the start.

private struct FixRig {
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

final class Build9FixF7AttendanceLeadTests: XCTestCase {
    private let meeting = TrackedMeeting(id: "m1", title: "Standup", start: B9.at(0), end: B9.at(1800), hasZoom: true)
    private let hour: TimeInterval = 3600

    private func run(
        zoom: @escaping (TimeInterval) -> Bool, awake: @escaping (TimeInterval) -> Bool = { _ in true }
    ) -> FixRig {
        var rig = FixRig([meeting])
        rig.run(from: -1200, to: 1800 + 600, zoom: zoom, awake: awake)
        return rig
    }

    // MARK: A session that ended before the start is not a sighting

    func testAnAdHocCallThatEndedBeforeTheMeetingIsNotAttendance() throws {
        // The review's repro: Zoom open 9:45 to 9:50 for another call, never again; the meeting is at 10:00.
        let rig = run(zoom: { ((-900)...(-600)).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertEqual(at, 1800, "reported at the end, like a meeting nobody joined")
        XCTAssertEqual(report, AttendanceReport(id: "m1", meetingStart: B9.at(0), title: "Standup",
                                                seenStart: nil, seenEnd: nil, seenNone: true))
    }

    func testAOneSampleCallInTheLeadIsNotAttendanceEither() {
        let rig = run(zoom: { $0 == -900 })
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
        XCTAssertNil(rig.reports.first?.seenStart)
        XCTAssertEqual(rig.reports.count, 1)
    }

    func testASessionClosedOneSampleBeforeTheStartDoesNotCount() {
        // Open to -15, closed at the sample at the start.
        let rig = run(zoom: { (-600...(-15)).contains($0) })
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
        XCTAssertNil(rig.reports.first?.seenStart)
        XCTAssertNil(rig.reports.first?.seenEnd)
    }

    func testAnEndedLeadSessionDoesNotStopSeenNoneWhenTheMeetingWasFullyWatched() {
        // Zoom was open to -300, then the Mac was awake and watching the whole meeting with Zoom closed.
        let rig = run(zoom: { (-900...(-300)).contains($0) })
        XCTAssertTrue(rig.reports.first?.seenNone ?? false, "watched time is what counts for seenNone, and it is full")
        XCTAssertEqual(rig.emitted.first?.at, 1800)
    }

    func testTheSessionBeforeTheStartDoesNotLeakIntoALaterJoin() throws {
        // A call at -600 to -300, then joining the meeting at 600: the first call is not part of it.
        let rig = run(zoom: { (-600...(-300)).contains($0) || (600...900).contains($0) })
        let report = try XCTUnwrap(rig.reports.first)
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertEqual(report.seenStart, B9.at(600))
        XCTAssertEqual(report.seenEnd, B9.at(900))
        XCTAssertFalse(report.seenNone)
    }

    // MARK: A session still running at the start counts, from when it began

    func testASessionRunningAtTheStartCountsFromWhenItBegan() throws {
        let rig = run(zoom: { (-600...300).contains($0) })
        XCTAssertEqual(rig.emitted.count, 1)
        let (at, report) = try XCTUnwrap(rig.emitted.first)
        XCTAssertEqual(at, 1800)
        XCTAssertEqual(report.seenStart, B9.at(-600))
        XCTAssertEqual(report.seenEnd, B9.at(300))
        XCTAssertFalse(report.seenNone)
    }

    func testTheLeadStillStartsFifteenMinutesBeforeTheStart() throws {
        // Open from 20 minutes before: the sighting starts at the lead, not earlier.
        let rig = run(zoom: { (-1200...300).contains($0) })
        XCTAssertEqual(rig.reports.first?.seenStart, B9.at(-900))
        XCTAssertEqual(rig.reports.first?.seenEnd, B9.at(300))
        XCTAssertFalse(rig.reports.first?.seenNone ?? true)
    }

    func testZoomOpenExactlyAtTheStartCountsAsRunningAtTheStart() throws {
        // The sample at the start has Zoom open; the next one does not.
        let rig = run(zoom: { (-300...0).contains($0) })
        let report = try XCTUnwrap(rig.reports.first)
        XCTAssertEqual(report.seenStart, B9.at(-300))
        XCTAssertEqual(report.seenEnd, B9.at(0))
        XCTAssertFalse(report.seenNone)
    }

    func testARunningSessionThatCarriesOnThroughTheMeetingKeepsItsEnd() throws {
        let rig = run(zoom: { (-300...1500).contains($0) })
        let report = try XCTUnwrap(rig.reports.first)
        XCTAssertEqual(report.seenStart, B9.at(-300))
        XCTAssertEqual(report.seenEnd, B9.at(1500))
        XCTAssertEqual(rig.emitted.first?.at, 1800)
    }

    func testAnEarlierEndedSessionDoesNotMoveTheStartOfALaterOneThatIsRunning() throws {
        let rig = run(zoom: { (-800...(-500)).contains($0) || (-300...300).contains($0) })
        XCTAssertEqual(rig.reports.count, 1)
        XCTAssertEqual(rig.reports.first?.seenStart, B9.at(-300), "the session running at the start began here")
        XCTAssertEqual(rig.reports.first?.seenEnd, B9.at(300))
    }

    // MARK: What breaks a session before the start

    func testAClosedSampleBeforeTheStartBreaksTheSession() throws {
        // Open, closed for one sample at -300, open again and running at the start: the second session counts.
        let rig = run(zoom: { (-600...300).contains($0) && $0 != -300 })
        XCTAssertEqual(rig.reports.first?.seenStart, B9.at(-285))
        XCTAssertEqual(rig.reports.first?.seenEnd, B9.at(300))
    }

    func testTheMacNotAwakeBreaksTheSessionToo() throws {
        let rig = run(zoom: { (-600...300).contains($0) }, awake: { $0 != -300 })
        XCTAssertEqual(rig.reports.first?.seenStart, B9.at(-285))
    }

    func testAGapOverSixtySecondsBreaksTheSessionButSixtyDoesNot() throws {
        // 100 s without samples with Zoom open on both sides: two sessions, the second begins at -300.
        var broken = FixRig([meeting])
        broken.run(from: -1200, to: -400, zoom: { $0 >= -600 })
        broken.run(from: -300, to: 1800 + 600, zoom: { $0 <= 300 })
        XCTAssertEqual(broken.reports.count, 1)
        XCTAssertEqual(broken.reports.first?.seenStart, B9.at(-300), "the session before the gap ended before the start")
        XCTAssertEqual(broken.reports.first?.seenEnd, B9.at(300))

        // 60 s without samples is still one session.
        var kept = FixRig([meeting])
        kept.run(from: -1200, to: -360, zoom: { $0 >= -600 })
        kept.run(from: -300, to: 1800 + 600, zoom: { $0 <= 300 })
        XCTAssertEqual(kept.reports.first?.seenStart, B9.at(-600))
    }

    // MARK: Back-to-back and spaced meetings

    func testACallThatEndedBeforeASecondMeetingStartsIsNotThatMeetings() throws {
        // A 0:00 to 0:30, B 50:00 to 80:00. The lead for B opens at 35:00 (15 min before). Zoom runs 36:40 to 40:00 only.
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(3000), end: B9.at(4800), hasZoom: true)
        var rig = FixRig([a, b])
        rig.run(from: -1200, to: 4800 + 600, zoom: { (2200...2400).contains($0) })
        let rb = try XCTUnwrap(rig.reports(for: "b").first)
        XCTAssertEqual(rig.reports(for: "b").count, 1)
        XCTAssertTrue(rb.seenNone, "that call ended before B began")
        XCTAssertNil(rb.seenStart)
    }

    func testASecondMeetingsLeadSessionStillRunningAtItsStartCountsFromWhenItBegan() throws {
        let a = TrackedMeeting(id: "a", title: "A", start: B9.at(0), end: B9.at(1800), hasZoom: true)
        let b = TrackedMeeting(id: "b", title: "B", start: B9.at(3000), end: B9.at(4800), hasZoom: true)
        var rig = FixRig([a, b])
        rig.run(from: -1200, to: 4800 + 600, zoom: { (2205...3300).contains($0) })
        let rb = try XCTUnwrap(rig.reports(for: "b").first)
        XCTAssertEqual(rb.seenStart, B9.at(2205))
        XCTAssertEqual(rb.seenEnd, B9.at(3300))
        XCTAssertFalse(rb.seenNone)
        let ra = try XCTUnwrap(rig.reports(for: "a").first)
        XCTAssertTrue(ra.seenNone, "that session started after A ended: it is not A's")
    }

    // MARK: The report is still one report with the same shape

    func testAMeetingIsStillReportedOnceWhateverHappensAround() {
        var rig = FixRig([meeting])
        rig.run(from: -1200, to: 1800 + 6 * hour,
                zoom: { (-900...(-600)).contains($0) || (12_000...13_000).contains($0) })
        XCTAssertEqual(rig.reports(for: "m1").count, 1)
        XCTAssertTrue(rig.reports.first?.seenNone ?? false)
    }
}
