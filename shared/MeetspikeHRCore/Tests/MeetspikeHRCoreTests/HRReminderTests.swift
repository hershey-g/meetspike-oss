import Foundation
import XCTest
@testable import MeetspikeHRCore

final class HRReminderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// Starts two minutes after t0, the moment the Mac starts listening.
    private var meeting: ReminderMeeting { ReminderMeeting(id: "evt1", title: "Weekly sync", start: t0.addingTimeInterval(120)) }

    func testCalendarMeetingAlertsTwoMinutesBeforeThenFollowsUpOneMinuteIn() {
        var policy = HRReminderPolicy()
        let first = policy.evaluate(now: t0, lastReadingAt: nil, zoomActive: false, meeting: meeting)
        XCTAssertEqual(first, HRReminderAlert(key: "calendar:evt1", title: "Weekly sync", isRepeat: false))
        XCTAssertEqual(first?.message, "“Weekly sync” is starting. Turn on HR Broadcast in the WHOOP app.")
        XCTAssertEqual(first?.heading, "Turn on HR Broadcast in the WHOOP app")
        // Start is t0 + 120; the follow-up waits for the first minute of the meeting.
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(120), lastReadingAt: nil, zoomActive: false, meeting: meeting))
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(179), lastReadingAt: nil, zoomActive: false, meeting: meeting))
        let again = policy.evaluate(now: t0.addingTimeInterval(180), lastReadingAt: nil, zoomActive: false, meeting: meeting)
        XCTAssertEqual(again?.isRepeat, true)
        XCTAssertEqual(again?.message, "Still no heart rate for “Weekly sync”. Turn on HR Broadcast in the WHOOP app.")
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(900), lastReadingAt: nil, zoomActive: false, meeting: meeting))
    }

    func testNoFollowUpWhenHeartRateArrivedInTheFirstMinute() {
        var policy = HRReminderPolicy()
        XCTAssertNotNil(policy.evaluate(now: t0, lastReadingAt: nil, zoomActive: false, meeting: meeting))
        // One reading 30 s into the meeting, then the strap drops.
        let reading = t0.addingTimeInterval(150)
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(180), lastReadingAt: reading, zoomActive: false, meeting: meeting))
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(600), lastReadingAt: reading, zoomActive: false, meeting: meeting))
    }

    func testFollowUpWhenOnlyReadingsBeforeTheStart() {
        var policy = HRReminderPolicy()
        XCTAssertNotNil(policy.evaluate(now: t0, lastReadingAt: nil, zoomActive: false, meeting: meeting))
        let before = t0.addingTimeInterval(30)
        XCTAssertEqual(policy.evaluate(now: t0.addingTimeInterval(180), lastReadingAt: before, zoomActive: false, meeting: meeting)?.isRepeat, true)
    }

    func testNoAlertWhileReadingsArriveOrWithoutAMeeting() {
        var policy = HRReminderPolicy()
        XCTAssertNil(policy.evaluate(now: t0, lastReadingAt: t0.addingTimeInterval(-59), zoomActive: true, meeting: meeting))
        XCTAssertNil(policy.evaluate(now: t0, lastReadingAt: nil, zoomActive: false, meeting: nil))
        XCTAssertNotNil(policy.evaluate(now: t0.addingTimeInterval(1), lastReadingAt: t0.addingTimeInterval(-59), zoomActive: false, meeting: meeting))
    }

    func testMeetingWithoutStartFromAnOlderWorkerUsesTheFirstAlert() {
        var policy = HRReminderPolicy()
        let old = ReminderMeeting(id: "evt2", title: nil)
        XCTAssertEqual(policy.evaluate(now: t0, lastReadingAt: nil, zoomActive: false, meeting: old)?.message,
                       "A meeting is starting. Turn on HR Broadcast in the WHOOP app.")
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(119), lastReadingAt: nil, zoomActive: false, meeting: old))
        XCTAssertEqual(policy.evaluate(now: t0.addingTimeInterval(120), lastReadingAt: nil, zoomActive: false, meeting: old)?.message,
                       "Still no heart rate for your meeting. Turn on HR Broadcast in the WHOOP app.")
    }

    func testZoomMeetingWithoutCalendarAndNoDoubleAlertWhenCalendarAppears() {
        var policy = HRReminderPolicy()
        let zoom = policy.evaluate(now: t0, lastReadingAt: nil, zoomActive: true, meeting: nil)
        XCTAssertEqual(zoom?.title, "Zoom meeting")
        XCTAssertEqual(zoom?.isRepeat, false)
        // The calendar lookup finds the same meeting a minute later: still one meeting.
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(60), lastReadingAt: nil, zoomActive: true, meeting: meeting))
        XCTAssertEqual(policy.evaluate(now: t0.addingTimeInterval(120), lastReadingAt: nil, zoomActive: true, meeting: meeting)?.isRepeat, true)

        // Zoom closes and a new call opens later: a new meeting.
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(1_000), lastReadingAt: nil, zoomActive: false, meeting: nil))
        XCTAssertEqual(policy.evaluate(now: t0.addingTimeInterval(1_100), lastReadingAt: nil, zoomActive: true, meeting: nil)?.isRepeat, false)
    }

    func testReminderWireFormat() throws {
        let body = try Uploader.reminderBody(HRReminderAlert(key: "calendar:evt1", title: "Weekly sync", isRepeat: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Weekly sync")
        XCTAssertEqual(json["repeat"] as? Bool, true)

        let reply = try JSONDecoder().decode(
            ReminderLookup.self,
            from: Data(#"{"ok":true,"meeting":{"id":"evt1","title":"Weekly sync","startUtc":"2026-11-20T14:30:00.000Z","endUtc":"2026-11-20T15:30:00.000Z"},"pushover":false,"owner":"phone","ownerUntil":"2026-11-27T14:00:00.000Z"}"#.utf8)
        )
        XCTAssertEqual(reply.meeting?.id, "evt1")
        XCTAssertEqual(reply.meeting?.start, ISO8601DateFormatter().date(from: "2026-11-20T14:30:00Z"))
        XCTAssertFalse(reply.pushover)
        XCTAssertEqual(reply.owner, .phone)
        let checkedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z"))
        XCTAssertTrue(reply.phoneOwnsMeeting(at: checkedAt))
        XCTAssertFalse(reply.phoneOwnsMeeting(at: checkedAt.addingTimeInterval(8 * 86_400)), "an expired check-in hands back to the Mac")

        // An older Worker: no owner and no start. The Mac owns reminders.
        let none = try JSONDecoder().decode(ReminderLookup.self, from: Data(#"{"ok":true,"meeting":null,"pushover":true}"#.utf8))
        XCTAssertNil(none.meeting)
        XCTAssertEqual(none.owner, .mac)
        XCTAssertFalse(none.phoneOwnsMeeting(at: checkedAt))

        let owner = try JSONDecoder().decode(ReminderOwnerReply.self, from: Data(#"{"ok":true,"owner":"mac","ownerUntil":null}"#.utf8))
        XCTAssertEqual(owner.owner, .mac)
        XCTAssertNil(owner.ownerUntil)

        let destination = try XCTUnwrap(Destination("https://hg-biometrics.example.workers.dev"))
        XCTAssertEqual(destination.reminderEndpoint.absoluteString, "https://hg-biometrics.example.workers.dev/api/whoop-web/reminder")
        XCTAssertEqual(destination.reminderOwnerEndpoint.absoluteString, "https://hg-biometrics.example.workers.dev/api/whoop-web/reminder/owner")
    }
}

final class BroadcastPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(_ title: String, in minutes: Double, length: Double = 30) -> CalendarMeeting {
        CalendarMeeting(title: title, start: now.addingTimeInterval(minutes * 60),
                        end: now.addingTimeInterval((minutes + length) * 60))!
    }

    func testEachMeetingGetsAReminderTwoMinutesBeforeAndAFollowUpOneMinuteIn() {
        let schedule = MeetingSchedule([meeting("Design sync", in: 30), meeting("1:1", in: 60)])
        let plan = BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(86_400))
        let on = plan.filter { $0.kind == .on }
        XCTAssertEqual(on.map(\.fireAt), [now.addingTimeInterval(28 * 60), now.addingTimeInterval(58 * 60)])
        XCTAssertEqual(on.first?.title, "Turn on HR Broadcast in the WHOOP app")
        XCTAssertTrue(on.first!.body.hasPrefix("“Design sync” starts in 2 minutes."))
        let followUps = plan.filter { $0.kind == .followUp }
        XCTAssertEqual(followUps.map(\.fireAt), [now.addingTimeInterval(31 * 60), now.addingTimeInterval(61 * 60)])
        // Back-to-back meetings share one listening block, so one "turn off" at its end.
        XCTAssertEqual(plan.filter { $0.kind == .off }.map(\.fireAt), [now.addingTimeInterval(100 * 60)])
        XCTAssertEqual(plan.map(\.fireAt), plan.map(\.fireAt).sorted())
        XCTAssertFalse(plan.contains { $0.body.contains("—") || $0.title.contains("—") })
    }

    func testNothingUnlessThePhoneOwnsRemindersAndNothingPastTheCheckIn() {
        let schedule = MeetingSchedule([meeting("Soon", in: 30), meeting("Next week", in: 8 * 24 * 60)])
        XCTAssertEqual(BroadcastPlan.plan(schedule, now: now, ownerUntil: nil), [])
        XCTAssertEqual(BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(-1)), [])
        let plan = BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(7 * 86_400))
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(plan.allSatisfy { $0.fireAt < now.addingTimeInterval(7 * 86_400) }, "the Mac owns anything after the check-in expires")
    }

    func testPastRemindersAreSkippedAndPendingIsCapped() {
        let started = MeetingSchedule([meeting("Running", in: -0.5)])
        let plan = BroadcastPlan.plan(started, now: now, ownerUntil: now.addingTimeInterval(86_400))
        XCTAssertEqual(plan.map(\.kind), [.followUp, .off])

        let many = MeetingSchedule((0..<80).map { meeting("M\($0)", in: Double($0) * 60 + 10, length: 20) })
        XCTAssertEqual(BroadcastPlan.plan(many, now: now, ownerUntil: now.addingTimeInterval(7 * 86_400)).count, BroadcastPlan.maxPending)
    }

    func testHeartRateNearTheStartRemovesThatMeetingsReminders() {
        let schedule = MeetingSchedule([meeting("Design sync", in: 30), meeting("Later", in: 120)])
        let plan = BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(86_400))
        let start = now.addingTimeInterval(30 * 60)
        let ids = BroadcastPlan.satisfied(byReadingAt: start.addingTimeInterval(20), in: plan)
        XCTAssertEqual(Set(ids), Set(plan.filter { $0.kind != .off && $0.anchor == start }.map(\.id)))
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(BroadcastPlan.satisfied(byReadingAt: start.addingTimeInterval(-4 * 60), in: plan).count, 2, "broadcast already on before the meeting")
        XCTAssertEqual(BroadcastPlan.satisfied(byReadingAt: start.addingTimeInterval(61), in: plan), [], "too late to count")
        XCTAssertEqual(BroadcastPlan.satisfied(byReadingAt: start.addingTimeInterval(-6 * 60), in: plan), [])

        let replanned = BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(86_400), satisfied: Set(ids))
        XCTAssertEqual(replanned.count, plan.count - 2, "a satisfied reminder is not rescheduled")
        XCTAssertEqual(BroadcastPlan.anchor(of: ids[0]), start)
    }

    /// QA S1: the phone may only vouch for meetings it actually scheduled.
    /// 25 meetings over 3 days overflow the 60-request cap, so the later ones
    /// are not covered and the Mac reminds about them.
    func testCoveredIsOnlyTheMeetingsThePhoneScheduled() {
        let many = MeetingSchedule((0..<25).map { meeting("M\($0)", in: Double($0) * 170 + 10, length: 20) })
        let plan = BroadcastPlan.plan(many, now: now, ownerUntil: now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(plan.count, BroadcastPlan.maxPending)
        let covered = BroadcastPlan.covered(plan: plan, satisfied: [], previous: [], now: now)
        let scheduledStarts = Set(plan.filter { $0.kind == .on }.map(\.anchor))
        XCTAssertEqual(Set(covered), scheduledStarts)
        XCTAssertLessThan(covered.count, many.meetings.count)
        let last = many.meetings.last!.start
        XCTAssertFalse(covered.contains(last), "a meeting past the phone's plan is the Mac's")
        XCTAssertEqual(covered, covered.sorted())
    }

    func testCoveredKeepsFiredAndSatisfiedMeetingsAndDropsRemovedOnes() {
        let running = now.addingTimeInterval(-10 * 60)
        let imminent = now.addingTimeInterval(60)        // its on reminder fired a minute ago
        let removedLater = now.addingTimeInterval(3_600) // no longer in the calendar
        let longAgo = now.addingTimeInterval(-13 * 3_600)
        let satisfiedStart = now.addingTimeInterval(4 * 60)
        let satisfied: Set<String> = [
            "\(BroadcastPlan.prefix)on.\(satisfiedStart.unixMilliseconds)",
            "\(BroadcastPlan.prefix)followUp.\(satisfiedStart.unixMilliseconds)",
        ]
        let schedule = MeetingSchedule([meeting("Later", in: 120)])
        let plan = BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(86_400))
        let covered = BroadcastPlan.covered(
            plan: plan, satisfied: satisfied, previous: [running, imminent, removedLater, longAgo], now: now
        )
        XCTAssertEqual(covered, [running, imminent, satisfiedStart, now.addingTimeInterval(120 * 60)])
    }

    /// The check-in body: sorted, unique ISO UTC starts, capped, and none when stepping down.
    func testCheckInBodySendsCoveredStarts() throws {
        let a = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T14:00:00Z"))
        let b = a.addingTimeInterval(3_600.5)
        let body = try Uploader.reminderOwnerBody(active: true, covered: [b, a, a], push: nil)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"active":true,"covered":["2026-11-24T14:00:00.000Z","2026-11-24T15:00:00.500Z"]}"#)
        let lots = (0..<70).map { a.addingTimeInterval(Double($0) * 60) }
        let capped = try JSONSerialization.jsonObject(with: Uploader.reminderOwnerBody(active: true, covered: lots, push: nil)) as? [String: Any]
        XCTAssertEqual((capped?["covered"] as? [String])?.count, BroadcastPlan.maxPending)
        XCTAssertEqual(String(decoding: try Uploader.reminderOwnerBody(active: false, covered: [a], push: nil), as: UTF8.self),
                       #"{"active":false,"covered":[]}"#)
    }

    /// QA S3: a renamed meeting keeps its id, so the pending text is replaced.
    func testChangedReminderTextIsReplaced() {
        let schedule = MeetingSchedule([meeting("Renamed sync", in: 30)])
        let plan = BroadcastPlan.plan(schedule, now: now, ownerUntil: now.addingTimeInterval(86_400))
        let on = plan.first { $0.kind == .on }!
        let off = plan.first { $0.kind == .off }!
        let pending: [BroadcastPlan.Pending] = [
            .init(id: on.id, title: on.title, body: on.body.replacingOccurrences(of: "Renamed sync", with: "Old sync")),
            .init(id: off.id, title: off.title, body: off.body),
            .init(id: "\(BroadcastPlan.prefix)on.1", title: "x", body: "y"),
            .init(id: "someone-else", title: "x", body: "y"),
        ]
        let changes = BroadcastPlan.changes(pending: pending, plan: plan)
        XCTAssertEqual(Set(changes.remove), [on.id, "\(BroadcastPlan.prefix)on.1"])
        XCTAssertEqual(Set(changes.add.map(\.id)), Set(plan.map(\.id)).subtracting([off.id]))
        XCTAssertTrue(changes.add.contains { $0.id == on.id && $0.body.contains("Renamed sync") })
        let settled = BroadcastPlan.changes(pending: plan.map { .init(id: $0.id, title: $0.title, body: $0.body) }, plan: plan)
        XCTAssertTrue(settled.remove.isEmpty && settled.add.isEmpty)
    }
}

final class ReminderOwnerLookupTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_795_000_000)

    private func lookup(_ json: String) throws -> ReminderLookup {
        try JSONDecoder().decode(ReminderLookup.self, from: Data(json.utf8))
    }

    /// QA S1: a fresh phone check-in alone never silences the Mac. Only a
    /// lookup that says "phone" for its meeting does.
    func testMacStaysQuietOnlyForAMeetingThePhoneCovers() throws {
        let uncovered = try lookup(#"{"ok":true,"meeting":{"id":"evt2","title":"Booked on the web","startUtc":"2026-11-20T14:00:00.000Z"},"pushover":false,"owner":"mac","ownerUntil":"2026-11-27T14:00:00.000Z"}"#)
        XCTAssertTrue(uncovered.phoneCheckedIn(at: at))
        XCTAssertFalse(uncovered.phoneOwnsMeeting(at: at), "checked in, but this meeting is the Mac's")
        let zoomOnly = try lookup(#"{"ok":true,"meeting":null,"pushover":false,"owner":"phone","ownerUntil":"2026-11-27T14:00:00.000Z"}"#)
        XCTAssertFalse(zoomOnly.phoneOwnsMeeting(at: at), "no calendar meeting is the Mac's")
        let covered = try lookup(#"{"ok":true,"meeting":{"id":"evt1","title":"Weekly sync","startUtc":"2026-11-20T14:00:00.000Z"},"pushover":false,"owner":"phone","ownerUntil":"2026-11-27T14:00:00.000Z"}"#)
        XCTAssertTrue(covered.phoneOwnsMeeting(at: at))
        let signedOut = try lookup(#"{"ok":true,"meeting":null,"pushover":false,"owner":"mac","ownerUntil":null}"#)
        XCTAssertFalse(signedOut.phoneCheckedIn(at: at))
    }
}

#if canImport(Combine) && canImport(Security)
@MainActor
final class ReplaySendTests: XCTestCase {
    @MainActor private final class Log { var acknowledged: [Int] = [] }

    /// QA S2: cancellation after the Worker confirmed raw storage still
    /// acknowledges the batch, so it is not uploaded twice.
    func testConfirmedUploadIsAcknowledgedEvenWhenCancelledMidFlight() async {
        let log = Log()
        let task = Task { @MainActor in
            try await ReplaySync.send({
                withUnsafeCurrentTask { $0?.cancel() }
                return 200
            }, acknowledge: { log.acknowledged.append($0) })
        }
        let result = await task.result
        XCTAssertEqual(log.acknowledged, [200])
        guard case .failure(let error) = result else { return XCTFail("cancellation is still reported") }
        XCTAssertTrue(error is CancellationError)
    }

    func testFailedUploadIsNotAcknowledged() async {
        let log = Log()
        let result = await Task { @MainActor in
            try await ReplaySync.send({ 500 }, acknowledge: { log.acknowledged.append($0) })
        }.result
        XCTAssertEqual(log.acknowledged, [])
        guard case .failure = result else { return XCTFail("HTTP 500 fails") }
    }
}
#endif
