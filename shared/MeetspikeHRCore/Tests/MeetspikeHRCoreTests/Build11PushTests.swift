import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 11, track B (Swift): broadcast reminders come as a server push only when heart rate is not coming in.
//
// NEW API the builder creates (names come from the spec):
//   PushRegistration(token: Data, environment: .production / .development)   lowercase hex token on the wire
//   Uploader.checkInReminderOwner(active:covered:push:to:credentials:)         push is PushRegistration?
//   Uploader.reminderOwnerBody(active:covered:push:)                           internal, same as before plus push
//   ReminderOwnerReply.push: Bool            (missing, null or malformed is false)
//   ReminderLookup.live: Bool?               (missing, null or malformed is nil)
//   HRReminderPolicy.effectiveLastReading(local:serverLiveAt:) -> Date?   the later of the two
//   ReminderDelivery.pending(plan:pushActive:) -> [PlannedReminder]      [] while push is active, else the plan
//   CalendarMeeting.leadIn == 300, while LiveAdjust.didntJoin keeps its own 120 s
//   ReleaseNotes build 11, project.yml build 11, aps-environment entitlement, Settings copy.
//
// Pieces that need UIKit, EventKit or the Mac app target (token registration, pushActive persistence, the Mac
// HRReminderController wiring) cannot run in this package. The pure decisions behind them are tested here, and
// the source files are read for the strings the spec fixes.

private enum B11 {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func repoRoot(_ file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    static func read(_ path: String, file: String = #filePath) throws -> String {
        let url = repoRoot(file).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: repoRoot(file).appendingPathComponent("ios/MeetspikeHR").path) {
                XCTFail("missing \(path)")
                return ""
            }
            throw XCTSkip("no ios/ folder next to this package")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every Swift file under a folder, joined.
    static func swiftSources(under path: String, file: String = #filePath) throws -> String {
        let root = repoRoot(file).appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no \(path) folder next to this package")
        }
        var text = ""
        for case let url as URL in walker where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += "\n"
        }
        return text
    }

    static func plist(_ path: String, file: String = #filePath) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(try read(path, file: file).utf8), format: nil)
        return try XCTUnwrap(object as? [String: Any], path)
    }
}

// MARK: Lead-in

final class Build11LeadInTests: XCTestCase {
    private let start = B11.t0.addingTimeInterval(3_600)

    func testListeningStartsFiveMinutesBeforeAMeeting() throws {
        XCTAssertEqual(CalendarMeeting.leadIn, 300)
        let meeting = try XCTUnwrap(CalendarMeeting(title: "Call", start: start, end: start.addingTimeInterval(1_800)))
        XCTAssertEqual(meeting.listenFrom, start.addingTimeInterval(-300))
        XCTAssertEqual(meeting.listenUntil, start.addingTimeInterval(1_800 + 600), "the ten minute cooldown is unchanged")
        let schedule = MeetingSchedule([meeting])
        XCTAssertNil(schedule.activeBlock(at: start.addingTimeInterval(-301)))
        XCTAssertNotNil(schedule.activeBlock(at: start.addingTimeInterval(-300)))
    }

    /// The reminder plan still fires at T-120 for local scheduling (old Worker, old behavior).
    func testLocalReminderPlanKeepsItsTwoMinuteLead() throws {
        XCTAssertEqual(BroadcastPlan.lead, 120)
        let meeting = try XCTUnwrap(CalendarMeeting(title: "Call", start: start, end: start.addingTimeInterval(1_800)))
        let plan = BroadcastPlan.plan(MeetingSchedule([meeting]), now: B11.t0, ownerUntil: B11.t0.addingTimeInterval(86_400))
        XCTAssertEqual(plan.first { $0.kind == .on }?.fireAt, start.addingTimeInterval(-120))
        XCTAssertEqual(plan.first { $0.kind == .followUp }?.fireAt, start.addingTimeInterval(60))
        XCTAssertEqual(plan.first { $0.kind == .off }?.fireAt, start.addingTimeInterval(1_800 + 600))
    }

    /// "I didn't join" keeps showing from two minutes before the start, not five.
    func testDidntJoinStillOpensTwoMinutesBeforeTheStart() {
        let target = LiveAdjustTarget(meetingID: "ev1", title: "Standup", start: start, end: start.addingTimeInterval(3_600),
                                      calendarEnd: start.addingTimeInterval(3_600))
        XCTAssertFalse(LiveAdjust.offer(target, now: start.addingTimeInterval(-300)).didntJoin, "five minutes out is not it")
        XCTAssertFalse(LiveAdjust.offer(target, now: start.addingTimeInterval(-121)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(target, now: start.addingTimeInterval(-120)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(target, now: start.addingTimeInterval(0)).didntJoin)
        XCTAssertTrue(LiveAdjust.offer(target, now: start.addingTimeInterval(3_600 + 599)).didntJoin)
        XCTAssertFalse(LiveAdjust.offer(target, now: start.addingTimeInterval(3_600 + 600)).didntJoin)
    }

    /// A reading five minutes early already means the broadcast is on, so the on reminder is not needed.
    func testAReadingFiveMinutesBeforeStillSatisfiesTheReminders() throws {
        let meeting = try XCTUnwrap(CalendarMeeting(title: "Call", start: start, end: start.addingTimeInterval(1_800)))
        let plan = BroadcastPlan.plan(MeetingSchedule([meeting]), now: B11.t0, ownerUntil: B11.t0.addingTimeInterval(86_400))
        let ids = BroadcastPlan.satisfied(byReadingAt: start.addingTimeInterval(-300), in: plan)
        XCTAssertEqual(Set(ids), Set(plan.filter { $0.kind != .off }.map(\.id)))
    }
}

// MARK: Push registration

final class Build11PushRegistrationTests: XCTestCase {
    private let bytes = Data([0x00, 0x0A, 0xAB, 0xCD, 0xEF, 0xFF, 0x12, 0x34])
    private let hex = "000aabcdefff1234"
    private let covered = [B11.t0, B11.t0.addingTimeInterval(3_600)]
    private let coveredJSON = #""covered":["2027-01-15T08:00:00.000Z","2027-01-15T09:00:00.000Z"]"#

    private func body(active: Bool, push: PushRegistration?) throws -> [String: Any] {
        let data = try Uploader.reminderOwnerBody(active: active, covered: covered, push: push)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTokenIsSentAsLowercaseHexWithItsEnvironment() throws {
        let production = try body(active: true, push: PushRegistration(token: bytes, environment: .production))
        let push = try XCTUnwrap(production["push"] as? [String: Any])
        XCTAssertEqual(push["token"] as? String, hex, "lowercase hex, leading zeros kept")
        XCTAssertEqual(push["environment"] as? String, "production")
        XCTAssertEqual(Set(push.keys), ["token", "environment"])
        let development = try body(active: true, push: PushRegistration(token: bytes, environment: .development))
        XCTAssertEqual((development["push"] as? [String: Any])?["environment"] as? String, "development")
    }

    func testRealisticTokenLengthsStayWithinWhatTheWorkerAccepts() throws {
        // APNs tokens are 32 bytes today (64 hex). The Worker accepts 64 to 200 hex characters.
        let token = Data((0..<32).map { UInt8(255 - $0) })
        let sent = try body(active: true, push: PushRegistration(token: token, environment: .production))
        let text = try XCTUnwrap((sent["push"] as? [String: Any])?["token"] as? String)
        XCTAssertEqual(text.count, 64)
        XCTAssertNotNil(text.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    }

    func testPushIsAbsentWhenInactiveOrWhenThereIsNoToken() throws {
        let registration = PushRegistration(token: bytes, environment: .production)
        XCTAssertNil(try body(active: false, push: registration)["push"], "stepping down never sends a token")
        XCTAssertNil(try body(active: true, push: nil)["push"], "no token yet")
        XCTAssertEqual(try body(active: false, push: registration)["covered"] as? [String], [], "inactive still sends no covered starts")
    }

    func testLegacyBodyShapeIsUnchanged() throws {
        let a = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T14:00:00Z"))
        let b = a.addingTimeInterval(3_600.5)
        XCTAssertEqual(
            String(decoding: try Uploader.reminderOwnerBody(active: true, covered: [b, a, a], push: nil), as: UTF8.self),
            #"{"active":true,"covered":["2026-11-24T14:00:00.000Z","2026-11-24T15:00:00.500Z"]}"#
        )
        XCTAssertEqual(
            String(decoding: try Uploader.reminderOwnerBody(active: false, covered: [a], push: nil), as: UTF8.self),
            #"{"active":false,"covered":[]}"#
        )
    }

    func testBodyWithPushIsTheLegacyBodyPlusOneKey() throws {
        let registration = PushRegistration(token: bytes, environment: .production)
        let withPush = String(decoding: try Uploader.reminderOwnerBody(active: true, covered: covered, push: registration), as: UTF8.self)
        XCTAssertEqual(
            withPush,
            #"{"active":true,\#(coveredJSON),"push":{"environment":"production","token":"\#(hex)"}}"#
        )
        // 60 starts plus a long token must stay far below the Worker's 4 KB body limit.
        let lots = (0..<80).map { B11.t0.addingTimeInterval(Double($0) * 60) }
        let longToken = PushRegistration(token: Data(repeating: 0xAB, count: 100), environment: .production)
        let big = try Uploader.reminderOwnerBody(active: true, covered: lots, push: longToken)
        XCTAssertLessThan(big.count, 4_096)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: big) as? [String: Any])
        XCTAssertEqual((object["covered"] as? [String])?.count, BroadcastPlan.maxPending)
    }

    /// The public call sends the push registration to the Worker and reads `push` back.
    func testCheckInSendsThePushRegistrationAndReadsTheReply() async throws {
        let host = "push-checkin.example.invalid"
        APIStub.register(host: host) { _ in
            .json(status: 200, body: Data(#"{"ok":true,"owner":"phone","ownerUntil":"2027-01-22T08:00:00.000Z","covered":2,"push":true}"#.utf8))
        }
        let uploader = Uploader(configuration: APIStub.configuration())
        let destination = try XCTUnwrap(Destination("https://\(host)"))
        let reply = try await uploader.checkInReminderOwner(
            active: true, covered: covered, push: PushRegistration(token: bytes, environment: .development),
            to: destination, credentials: Credentials(ingestSecret: "fixture-ingest")
        )
        XCTAssertTrue(reply.push)
        XCTAssertEqual(reply.owner, .phone)
        let sent = try XCTUnwrap(APIStub.seen(host: host).first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/api/whoop-web/reminder/owner")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: APIStub.body(of: sent)) as? [String: Any])
        XCTAssertEqual((json["push"] as? [String: Any])?["token"] as? String, hex)
        XCTAssertEqual((json["push"] as? [String: Any])?["environment"] as? String, "development")
    }

    func testCheckInWithoutPushSendsTheOldBodyAndAnOldWorkerAnswersPushFalse() async throws {
        let host = "push-none.example.invalid"
        APIStub.register(host: host) { _ in
            .json(status: 200, body: Data(#"{"ok":true,"owner":"phone","ownerUntil":"2027-01-22T08:00:00.000Z","covered":2}"#.utf8))
        }
        let reply = try await Uploader(configuration: APIStub.configuration()).checkInReminderOwner(
            active: true, covered: covered, push: nil,
            to: try XCTUnwrap(Destination("https://\(host)")), credentials: Credentials(ingestSecret: "fixture-ingest")
        )
        XCTAssertFalse(reply.push, "an older Worker has no push field")
        let sent = try XCTUnwrap(APIStub.seen(host: host).first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: APIStub.body(of: sent)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["active", "covered"])
    }
}

// MARK: Reply decoding

final class Build11ReplyDecodingTests: XCTestCase {
    private func owner(_ json: String) throws -> ReminderOwnerReply {
        try JSONDecoder().decode(ReminderOwnerReply.self, from: Data(json.utf8))
    }

    private func lookup(_ json: String) throws -> ReminderLookup {
        try JSONDecoder().decode(ReminderLookup.self, from: Data(json.utf8))
    }

    func testOwnerReplyPushIsFalseUnlessTheWorkerSaysTrue() throws {
        XCTAssertTrue(try owner(#"{"ok":true,"owner":"phone","ownerUntil":null,"push":true}"#).push)
        XCTAssertFalse(try owner(#"{"ok":true,"owner":"phone","ownerUntil":null,"push":false}"#).push)
        XCTAssertFalse(try owner(#"{"ok":true,"owner":"phone","ownerUntil":null}"#).push, "older Worker: field missing")
        XCTAssertFalse(try owner(#"{"ok":true,"owner":"phone","ownerUntil":null,"push":null}"#).push)
        XCTAssertFalse(try owner(#"{"ok":true,"owner":"phone","ownerUntil":null,"push":"yes"}"#).push, "a wrong type never throws")
        XCTAssertFalse(try owner(#"{"ok":true,"owner":"phone","ownerUntil":null,"push":1}"#).push)
    }

    func testOwnerReplyKeepsItsOtherFields() throws {
        let reply = try owner(#"{"ok":true,"owner":"phone","ownerUntil":"2026-11-27T14:00:00.000Z","covered":3,"push":true}"#)
        XCTAssertEqual(reply.owner, .phone)
        XCTAssertEqual(reply.ownerUntil, ISO8601DateFormatter().date(from: "2026-11-27T14:00:00Z"))
    }

    func testLookupLiveIsATriState() throws {
        let base = #""ok":true,"meeting":null,"pushover":false,"owner":"mac","ownerUntil":null"#
        XCTAssertEqual(try lookup("{\(base),\"live\":true}").live, true)
        XCTAssertEqual(try lookup("{\(base),\"live\":false}").live, false)
        XCTAssertNil(try lookup("{\(base),\"live\":null}").live, "the Worker could not check")
        XCTAssertNil(try lookup("{\(base)}").live, "older Worker: field missing")
        XCTAssertNil(try lookup("{\(base),\"live\":\"true\"}").live, "a wrong type never throws")
        XCTAssertNil(try lookup("{\(base),\"live\":1}").live)
    }

    func testLookupLiveDoesNotChangeTheOtherFields() throws {
        let reply = try lookup(#"{"ok":true,"meeting":{"id":"evt1","title":"Weekly sync","startUtc":"2026-11-20T14:30:00.000Z"},"pushover":true,"owner":"phone","ownerUntil":"2026-11-27T14:00:00.000Z","live":true}"#)
        XCTAssertEqual(reply.meeting?.id, "evt1")
        XCTAssertTrue(reply.pushover)
        XCTAssertEqual(reply.owner, .phone)
        XCTAssertEqual(reply.live, true)
        let checkedAt = ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z")!
        XCTAssertTrue(reply.phoneOwnsMeeting(at: checkedAt))
    }
}

// MARK: Mac policy with the server's word

final class Build11EffectiveReadingTests: XCTestCase {
    private let t0 = B11.t0
    private var meeting: ReminderMeeting { ReminderMeeting(id: "evt1", title: "Weekly sync", start: t0.addingTimeInterval(120)) }

    func testTheLaterOfTheTwoWins() {
        let early = t0
        let late = t0.addingTimeInterval(30)
        XCTAssertEqual(HRReminderPolicy.effectiveLastReading(local: early, serverLiveAt: late), late)
        XCTAssertEqual(HRReminderPolicy.effectiveLastReading(local: late, serverLiveAt: early), late)
        XCTAssertEqual(HRReminderPolicy.effectiveLastReading(local: early, serverLiveAt: early), early)
        XCTAssertEqual(HRReminderPolicy.effectiveLastReading(local: early, serverLiveAt: nil), early)
        XCTAssertEqual(HRReminderPolicy.effectiveLastReading(local: nil, serverLiveAt: late), late)
        XCTAssertNil(HRReminderPolicy.effectiveLastReading(local: nil, serverLiveAt: nil))
    }

    /// The Mac asked the server at t0 and was told heart rate is live. Nothing alerts until 60 s later, and then it does.
    func testNothingAlertsWhileTheServerSaysLiveAndItAlertsAgainSixtySecondsAfter() {
        var policy = HRReminderPolicy()
        let serverLiveAt = t0
        func evaluate(at seconds: TimeInterval) -> HRReminderAlert? {
            policy.evaluate(
                now: t0.addingTimeInterval(seconds),
                lastReadingAt: HRReminderPolicy.effectiveLastReading(local: nil, serverLiveAt: serverLiveAt),
                zoomActive: false, meeting: meeting
            )
        }
        XCTAssertNil(evaluate(at: 0))
        XCTAssertNil(evaluate(at: 30))
        XCTAssertNil(evaluate(at: 59))
        let alert = evaluate(at: 60)
        XCTAssertEqual(alert?.key, "calendar:evt1")
        XCTAssertEqual(alert?.isRepeat, false)
    }

    func testALocalReadingNewerThanTheServersKeepsItQuiet() {
        var policy = HRReminderPolicy()
        let local = t0.addingTimeInterval(50)
        let last = HRReminderPolicy.effectiveLastReading(local: local, serverLiveAt: t0)
        XCTAssertNil(policy.evaluate(now: t0.addingTimeInterval(100), lastReadingAt: last, zoomActive: false, meeting: meeting))
        XCTAssertNotNil(policy.evaluate(now: t0.addingTimeInterval(110), lastReadingAt: last, zoomActive: false, meeting: meeting))
    }

    func testWithNoServerAnswerThePolicyBehavesAsBefore() {
        var a = HRReminderPolicy()
        var b = HRReminderPolicy()
        for seconds in stride(from: 0.0, through: 400, by: 20) {
            let now = t0.addingTimeInterval(seconds)
            let old = a.evaluate(now: now, lastReadingAt: nil, zoomActive: false, meeting: meeting)
            let new = b.evaluate(now: now, lastReadingAt: HRReminderPolicy.effectiveLastReading(local: nil, serverLiveAt: nil),
                                 zoomActive: false, meeting: meeting)
            XCTAssertEqual(old, new, "\(seconds) s")
        }
    }
}

// MARK: Phone delivery

final class Build11DeliveryTests: XCTestCase {
    private func plan() throws -> [PlannedReminder] {
        let start = B11.t0.addingTimeInterval(3_600)
        let meeting = try XCTUnwrap(CalendarMeeting(title: "Call", start: start, end: start.addingTimeInterval(1_800)))
        return BroadcastPlan.plan(MeetingSchedule([meeting]), now: B11.t0, ownerUntil: B11.t0.addingTimeInterval(86_400))
    }

    func testNoLocalRemindersWhileServerPushWorks() throws {
        XCTAssertFalse(try plan().isEmpty)
        XCTAssertEqual(ReminderDelivery.pending(plan: try plan(), pushActive: true), [])
    }

    func testTheWholePlanWhenPushIsNotActive() throws {
        XCTAssertEqual(ReminderDelivery.pending(plan: try plan(), pushActive: false), try plan(), "old Worker, no token, or push rejected")
        XCTAssertEqual(ReminderDelivery.pending(plan: [], pushActive: false), [])
        XCTAssertEqual(ReminderDelivery.pending(plan: [], pushActive: true), [])
    }

    /// `covered` does not depend on local scheduling: the check-in still tells the Worker which meetings the phone covers.
    func testCoveredIsStillComputedFromThePlanNotFromWhatIsScheduled() throws {
        let planned = try plan()
        let covered = BroadcastPlan.covered(plan: planned, satisfied: [], previous: [], now: B11.t0)
        XCTAssertEqual(covered, [B11.t0.addingTimeInterval(3_600)])
        // Nothing is scheduled with iOS while push is active, yet covered is the same.
        XCTAssertEqual(ReminderDelivery.pending(plan: planned, pushActive: true), [])
        XCTAssertEqual(BroadcastPlan.covered(plan: planned, satisfied: [], previous: [], now: B11.t0), covered)
    }

    /// With push active nothing is pending, so every pending local reminder of ours is removed and nothing else is.
    func testGoingToPushRemovesOurPendingRemindersOnly() throws {
        let planned = try plan()
        let pending = planned.map { BroadcastPlan.Pending(id: $0.id, title: $0.title, body: $0.body) }
            + [BroadcastPlan.Pending(id: "someone-else", title: "x", body: "y")]
        let changes = BroadcastPlan.changes(
            pending: pending, plan: ReminderDelivery.pending(plan: planned, pushActive: true)
        )
        XCTAssertEqual(Set(changes.remove), Set(planned.map(\.id)))
        XCTAssertTrue(changes.add.isEmpty)
        // And back: a reply that says push false brings the local reminders back.
        let back = BroadcastPlan.changes(pending: [], plan: ReminderDelivery.pending(plan: planned, pushActive: false))
        XCTAssertEqual(Set(back.add.map(\.id)), Set(planned.map(\.id)))
    }
}

// MARK: Release, project and copy

final class Build11ReleaseTests: XCTestCase {
    func testBuild11ReleaseNoteIsKept() throws {
        let release = try XCTUnwrap(ReleaseNotes.all.first { $0.build == 11 })
        XCTAssertEqual(release.version, "1.2")
        XCTAssertEqual(release.date, "2026-11-25")
        XCTAssertEqual(release.items, [
            "Broadcast reminders only come when no heart rate is coming in.",
            "Your server checks first, so nothing is sent while you are live on your iPhone or Mac.",
            "The note to turn off HR Broadcast comes only if it is still on.",
            "Listening starts five minutes before a meeting.",
        ])
        for item in release.items {
            XCTAssertFalse(item.contains("\u{2014}"), "no em dash: \(item)")
            XCTAssertFalse(item.contains("\u{2013}"), "no en dash: \(item)")
        }
    }

    func testTestFlightNotesAndWhatsNewForBuild11() throws {
        let text = try XCTUnwrap(ReleaseNotes.notesText(build: 11))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(text.hasPrefix("- Broadcast reminders only come when no heart rate is coming in."))
        let update = WhatsNew.decide(stored: 10, existingInstall: true, current: 11)
        XCTAssertEqual(update.releases.map(\.build), [11])
        XCTAssertEqual(update.store, 11)
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: nil, current: 11), [], "a fresh install sees nothing")
    }

    func testProjectIsStillVersion1Point2() throws {
        let yml = try B11.read("ios/MeetspikeHR/project.yml")
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"1.2\""))
    }
}

final class Build11AppFilesTests: XCTestCase {
    func testAppHasThePushEntitlementAndTheWidgetDoesNot() throws {
        let app = try B11.plist("ios/MeetspikeHR/MeetspikeHR.entitlements")
        XCTAssertEqual(app["aps-environment"] as? String, "development", "distribution signing makes it production")
        XCTAssertEqual(app["com.apple.developer.usernotifications.time-sensitive"] as? Bool, true, "existing entitlement stays")
        XCTAssertNotNil(app["com.apple.security.application-groups"], "existing entitlement stays")
        let widget = try B11.plist("ios/MeetspikeHR/Widgets/MeetspikeHRWidgets.entitlements")
        XCTAssertNil(widget["aps-environment"], "not on the widget target")
    }

    func testNoNewBackgroundModes() throws {
        let info = try B11.plist("ios/MeetspikeHR/Info.plist")
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["bluetooth-central"])
    }

    func testPhoneRegistersForRemoteNotificationsAndKeepsItsToken() throws {
        let sources = try B11.swiftSources(under: "ios/MeetspikeHR/Sources")
        XCTAssertTrue(sources.contains("registerForRemoteNotifications"))
        XCTAssertTrue(sources.contains("didRegisterForRemoteNotificationsWithDeviceToken"))
        XCTAssertTrue(sources.contains("didFailToRegisterForRemoteNotificationsWithError"))
        XCTAssertTrue(sources.contains("PushRegistration"))
        XCTAssertTrue(sources.contains("ReminderDelivery.pending"), "the phone decides through the pure function")
        XCTAssertTrue(sources.contains("#if DEBUG"), "development environment in debug builds")
    }

    func testSettingsAndDashboardCopy() throws {
        let sources = try B11.swiftSources(under: "ios/MeetspikeHR/Sources")
        XCTAssertTrue(sources.contains("On, from your server"))
        XCTAssertTrue(sources.contains("Your server checks first, so nothing is sent while you are live."))
        XCTAssertTrue(sources.contains("you get a reminder to turn on HR Broadcast, and one more a minute in."))
        XCTAssertTrue(sources.contains("if no heart rate is coming in."), "dashboard hint: Reminder at 2:28 PM if no heart rate is coming in.")
        XCTAssertFalse(sources.contains("On, from your server \u{2014}"))
    }

    func testReadmesSayFiveMinutes() throws {
        let ios = try B11.read("ios/README.md")
        XCTAssertTrue(ios.contains("five minutes before"), "ios/README.md listening window")
        XCTAssertFalse(ios.contains("runs from two minutes before the meeting"))
        XCTAssertFalse(ios.contains("Each window runs from two minutes before a meeting"))
        let mac = try B11.read("mac/MeetspikeHR/README.md")
        XCTAssertTrue(mac.contains("five minutes before"), "mac README listening window")
        XCTAssertFalse(mac.contains("run from two minutes before a meeting until ten minutes after it"))
        XCTAssertFalse(mac.contains("capture starts two minutes before a calendar meeting"))
    }

    func testMacControllerUsesTheServersWord() throws {
        let sources = try B11.swiftSources(under: "mac/MeetspikeHR/Sources")
        XCTAssertTrue(sources.contains("effectiveLastReading"))
        XCTAssertTrue(sources.contains(".live"))
    }
}
