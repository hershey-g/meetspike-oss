import XCTest
@testable import MeetspikeHRCore

final class GlanceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ title: String, at minutes: Double, for length: Double) -> CalendarMeeting {
        CalendarMeeting(title: title, start: t0.addingTimeInterval(minutes * 60),
                        end: t0.addingTimeInterval((minutes + length) * 60))!
    }

    private func content(bpm: Int?, status: LiveGlanceStatus = .live, title: String = "Sync") -> LiveGlanceContent {
        LiveGlanceContent(bpm: bpm, status: status, title: title, phase: .endsIn, timerFrom: t0,
                          timerTo: t0.addingTimeInterval(1_800), meetingStart: t0, meetingEnd: t0.addingTimeInterval(1_800))
    }

    // MARK: Status

    func testStatusMapping() {
        XCTAssertEqual(LiveGlanceStatus(connection: .connected, hasFreshReading: true), .live)
        XCTAssertEqual(LiveGlanceStatus(connection: .connected, hasFreshReading: false), .waiting)
        XCTAssertEqual(LiveGlanceStatus(connection: .reconnecting, hasFreshReading: false), .reconnecting)
        XCTAssertEqual(LiveGlanceStatus(connection: .reconnecting, hasFreshReading: true), .reconnecting)
        for status in [BluetoothStatus.searching, .starting, .connecting, .waiting, .poweredOff, .unauthorized] {
            XCTAssertEqual(LiveGlanceStatus(connection: status, hasFreshReading: false), .waiting)
        }
        XCTAssertEqual(LiveGlanceStatus.live.label, "Live")
        XCTAssertEqual(LiveGlanceStatus.reconnecting.label, "Reconnecting")
        XCTAssertEqual(LiveGlanceStatus.waiting.label, "Waiting for WHOOP")
    }

    func testCopyHasNoEmDashes() {
        let words = [LiveGlanceStatus.live.label, LiveGlanceStatus.reconnecting.label, LiveGlanceStatus.waiting.label,
                     LiveGlancePlan.goLiveTitle] + [LiveGlanceContent.Phase.startsIn, .endsIn, .wrapUp, .open].map {
            var c = content(bpm: 1)
            c.phase = $0
            return c.timerLabel
        }
        for word in words { XCTAssertFalse(word.contains("\u{2014}"), word) }
    }

    // MARK: Plan

    func testNoContentWhenNotListening() {
        let schedule = MeetingSchedule([meeting("Sync", at: 0, for: 30)])
        XCTAssertNil(LiveGlancePlan.content(schedule: schedule, listening: false, manualSince: nil,
                                            bpm: 70, status: .live, now: t0.addingTimeInterval(60)))
    }

    func testPhasesFollowTheMeeting() {
        let sync = meeting("Sync", at: 0, for: 30)
        let schedule = MeetingSchedule([sync])
        func plan(_ minutes: Double) -> LiveGlanceContent? {
            LiveGlancePlan.content(schedule: schedule, listening: true, manualSince: nil, bpm: 70, status: .live,
                                   now: t0.addingTimeInterval(minutes * 60))
        }
        let lead = plan(-1)!
        XCTAssertEqual(lead.phase, .startsIn)
        XCTAssertEqual(lead.timerTo, sync.start)
        XCTAssertEqual(lead.timerFrom, sync.listenFrom)
        XCTAssertEqual(lead.timerLabel, "Starts in")

        let during = plan(17)!
        XCTAssertEqual(during.phase, .endsIn)
        XCTAssertEqual(during.timerTo, sync.end)
        XCTAssertEqual(during.title, "Sync")
        XCTAssertEqual(during.progress(at: t0.addingTimeInterval(15 * 60)), 0.5, accuracy: 0.0001)

        let after = plan(35)!
        XCTAssertEqual(after.phase, .wrapUp)
        XCTAssertEqual(after.timerTo, sync.listenUntil)
        XCTAssertEqual(LiveGlancePlan.windowEnd(schedule: schedule, now: t0.addingTimeInterval(35 * 60)), sync.listenUntil)
    }

    func testGoLiveOutsideAMeetingCountsUp() {
        let since = t0.addingTimeInterval(-300)
        let plan = LiveGlancePlan.content(schedule: MeetingSchedule(), listening: true, manualSince: since,
                                          bpm: nil, status: .waiting, now: t0)!
        XCTAssertEqual(plan.phase, .open)
        XCTAssertEqual(plan.title, LiveGlancePlan.goLiveTitle)
        XCTAssertEqual(plan.timerFrom, since)
        XCTAssertNil(plan.timerTo)
        XCTAssertNil(LiveGlancePlan.windowEnd(schedule: MeetingSchedule(), now: t0))
    }

    func testGoLiveInsideAMeetingUsesTheMeeting() {
        let schedule = MeetingSchedule([meeting("Board", at: -5, for: 60)])
        let plan = LiveGlancePlan.content(schedule: schedule, listening: true, manualSince: t0, bpm: 80,
                                          status: .live, now: t0)!
        XCTAssertEqual(plan.phase, .endsIn)
        XCTAssertEqual(plan.title, "Board")
    }

    // MARK: Throttle

    func testThrottleSendsFirstUpdate() {
        XCTAssertTrue(LiveGlanceThrottle().shouldSend(content(bpm: 70), now: t0))
    }

    func testThrottleHoldsSmallChanges() {
        var throttle = LiveGlanceThrottle()
        throttle.markSent(content(bpm: 70), at: t0)
        XCTAssertFalse(throttle.shouldSend(content(bpm: 71), now: t0.addingTimeInterval(2)))
        XCTAssertFalse(throttle.shouldSend(content(bpm: 75), now: t0.addingTimeInterval(4)), "too soon even for a big change")
        XCTAssertFalse(throttle.shouldSend(content(bpm: 71), now: t0.addingTimeInterval(6)), "small change waits for 10 s")
        XCTAssertTrue(throttle.shouldSend(content(bpm: 73), now: t0.addingTimeInterval(6)), "big change after 5 s")
        XCTAssertTrue(throttle.shouldSend(content(bpm: 71), now: t0.addingTimeInterval(10)))
        XCTAssertFalse(throttle.shouldSend(content(bpm: 70), now: t0.addingTimeInterval(20)), "no change, no update")
        XCTAssertTrue(throttle.shouldSend(content(bpm: 70), now: t0.addingTimeInterval(30)), "keep-alive")
    }

    func testThrottleSendsLayoutChangesRightAway() {
        var throttle = LiveGlanceThrottle()
        throttle.markSent(content(bpm: 70), at: t0)
        XCTAssertFalse(throttle.shouldSend(content(bpm: 70, status: .reconnecting), now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(throttle.shouldSend(content(bpm: 70, status: .reconnecting), now: t0.addingTimeInterval(1)))
        XCTAssertTrue(throttle.shouldSend(content(bpm: 70, title: "Other"), now: t0.addingTimeInterval(1.5)))
        XCTAssertTrue(throttle.shouldSend(content(bpm: nil), now: t0.addingTimeInterval(6)), "losing the BPM counts")
        throttle.reset()
        XCTAssertNil(throttle.sent)
        XCTAssertTrue(throttle.shouldSend(content(bpm: 70), now: t0))
    }

    // MARK: Peak

    func testPeakTrackerKeepsTheHighestPerBlock() {
        var tracker = MeetingPeakTracker()
        let end = t0.addingTimeInterval(2_400)
        XCTAssertTrue(tracker.record(bpm: 70, title: "A", blockStart: t0, blockEnd: end))
        XCTAssertTrue(tracker.record(bpm: 88, title: "A", blockStart: t0, blockEnd: end))
        XCTAssertFalse(tracker.record(bpm: 80, title: "A", blockStart: t0, blockEnd: end))
        XCTAssertEqual(tracker.peak?.bpm, 88)
        XCTAssertTrue(tracker.record(bpm: 60, title: "B", blockStart: end, blockEnd: end.addingTimeInterval(600)))
        XCTAssertEqual(tracker.peak?.bpm, 60, "a new block starts over")
        XCTAssertEqual(tracker.peak?.title, "B")
        XCTAssertFalse(tracker.record(bpm: 0, title: "B", blockStart: end, blockEnd: end.addingTimeInterval(600)))
    }

    // MARK: Widgets

    private func snapshot(latestAt: Date? = nil, peak: GlancePeak? = nil) -> GlanceSnapshot {
        GlanceSnapshot(
            meetings: [
                .init(title: "Standup", start: t0, end: t0.addingTimeInterval(900)),
                .init(title: "Review", start: t0.addingTimeInterval(7_200), end: t0.addingTimeInterval(9_000)),
            ],
            latestBPM: latestAt == nil ? nil : 74, latestAt: latestAt, lastPeak: peak, listening: latestAt != nil
        )
    }

    func testEntryCountdowns() {
        let snap = snapshot()
        let during = GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(450))
        XCTAssertEqual(during.meeting?.title, "Standup")
        XCTAssertEqual(during.countdown, .endsIn(t0.addingTimeInterval(900)))
        XCTAssertEqual(during.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(during.countdownLabel, "Ends in")

        let gap = GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(1_000))
        XCTAssertEqual(gap.meeting?.title, "Review")
        XCTAssertEqual(gap.countdown, .later(t0.addingTimeInterval(7_200)))

        let soon = GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(4_000))
        XCTAssertEqual(soon.countdown, .startsIn(t0.addingTimeInterval(7_200)))

        let done = GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(10_000))
        XCTAssertNil(done.meeting)
        XCTAssertEqual(done.countdown, .none)
        XCTAssertEqual(GlanceEntry(snapshot: nil, at: t0).heart, .none)
    }

    func testEntryPrefersAFreshReadingThenThePeak() {
        let peak = GlancePeak(title: "Standup", bpm: 96, blockStart: t0, end: t0.addingTimeInterval(1_500))
        let snap = snapshot(latestAt: t0.addingTimeInterval(800), peak: peak)
        XCTAssertEqual(GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(900)).heart, .latest(74))
        XCTAssertEqual(GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(900)).heartCaption, "Now")
        let later = GlanceEntry(snapshot: snap, at: t0.addingTimeInterval(800 + 600))
        XCTAssertEqual(later.heart, .peak(96, title: "Standup"))
        XCTAssertEqual(later.bpm, 96)
        XCTAssertEqual(later.heartCaption, "Last peak")
    }

    func testTimelineDatesCoverBoundaries() {
        let snap = snapshot(latestAt: t0.addingTimeInterval(-60))
        let now = t0.addingTimeInterval(-120)
        let dates = GlanceTimeline.dates(for: snap, from: now)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates, dates.sorted())
        for expected in [t0, t0.addingTimeInterval(300), t0.addingTimeInterval(600), t0.addingTimeInterval(900),
                         t0.addingTimeInterval(3_600), t0.addingTimeInterval(7_200), t0.addingTimeInterval(9_000),
                         t0.addingTimeInterval(540)] {
            XCTAssertTrue(dates.contains(expected), "missing \(expected.timeIntervalSince(t0))")
        }
        XCTAssertFalse(dates.contains { $0 < now })
        XCTAssertLessThanOrEqual(dates.count, GlanceTimeline.maxEntries)
        XCTAssertEqual(GlanceTimeline.entries(for: snap, from: now).count, dates.count)
    }

    func testReloadOnlyOnMeaningfulChanges() {
        let base = snapshot(latestAt: t0)
        XCTAssertTrue(GlanceReload.needed(old: nil, new: base, lastReload: t0, now: t0))
        XCTAssertFalse(GlanceReload.needed(old: base, new: base, lastReload: t0, now: t0.addingTimeInterval(3_600)))
        var bpm = base
        bpm.latestBPM = 90
        XCTAssertFalse(GlanceReload.needed(old: base, new: bpm, lastReload: t0, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(GlanceReload.needed(old: base, new: bpm, lastReload: t0, now: t0.addingTimeInterval(300)))
        var stopped = base
        stopped.listening = false
        XCTAssertTrue(GlanceReload.needed(old: base, new: stopped, lastReload: t0, now: t0.addingTimeInterval(1)))
        var moved = base
        moved.meetings.removeFirst()
        XCTAssertTrue(GlanceReload.needed(old: base, new: moved, lastReload: t0, now: t0.addingTimeInterval(1)))
        var newPeak = base
        newPeak.lastPeak = GlancePeak(title: "X", bpm: 80, blockStart: t0, end: t0)
        XCTAssertTrue(GlanceReload.needed(old: base, new: newPeak, lastReload: t0, now: t0.addingTimeInterval(1)))
    }

    func testUpcomingDropsEndedMeetingsAndCaps() {
        let meetings = (0..<20).map { meeting("M\($0)", at: Double($0) * 60, for: 30) }
        let upcoming = GlanceSnapshot.upcoming(MeetingSchedule(meetings), now: t0.addingTimeInterval(45 * 60))
        XCTAssertEqual(upcoming.first?.title, "M1")
        XCTAssertEqual(upcoming.count, GlanceSnapshot.maxMeetings)
    }

    func testStoreRoundTrip() throws {
        let suite = "glance-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlanceStore(defaults: defaults)
        XCTAssertNil(store.load())
        let snap = snapshot(latestAt: t0)
        store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testContentStateRoundTrips() throws {
        let original = content(bpm: 72)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LiveGlanceContent.self, from: data), original)
    }
}
