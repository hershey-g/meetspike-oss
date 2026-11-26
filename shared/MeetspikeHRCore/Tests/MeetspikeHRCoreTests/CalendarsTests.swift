import Foundation
import XCTest
@testable import MeetspikeHRCore

/// Google accounts and calendars (GET/PUT/DELETE /api/calendars) and the Apple Calendar listening choice.
final class CalendarsTests: XCTestCase {
    // MARK: Models

    func testFixtureDecodes() throws {
        let reply = try APIFixture.decode(GoogleCalendarsResponse.self, "calendars.json")
        XCTAssertEqual(reply.ok, true)
        XCTAssertEqual(reply.accounts.map(\.email), ["you@example.com", "you@work.example"])
        XCTAssertEqual(reply.connectPath, "/auth/google/start")
        XCTAssertEqual(reply.setupPath, "/setup#calendars")
        let work = reply.accounts[1]
        XCTAssertEqual(work.id, "you@work.example")
        XCTAssertEqual(work.calendars.map(\.id), ["you@work.example", "team@group.calendar.example", "holidays@group.v.calendar.example"])
        XCTAssertEqual(work.calendars.map(\.isSelected), [true, true, false])
        XCTAssertEqual(work.calendars.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(work.calendars[1].color, "#ffad46")
        XCTAssertNil(reply.syncError)
    }

    func testLenientDecodingOfASparseAnswer() throws {
        let data = Data(#"{"accounts":[{"email":"a@example.com","calendars":[{"id":"a@example.com"}]}],"extra":1}"#.utf8)
        let reply = try JSONDecoder().decode(GoogleCalendarsResponse.self, from: data)
        XCTAssertEqual(reply.accounts.first?.calendars.first?.isSelected, false)
        XCTAssertEqual(reply.accounts.first?.calendars.first?.isPrimary, false)
        let empty = try JSONDecoder().decode(GoogleCalendarsResponse.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(empty.accounts, [])
    }

    func testWorkerAnswersAfterAChangeDecode() throws {
        let put = Data(#"{"ok":true,"accounts":[],"changed":1,"hidden":2,"shown":0,"syncError":"google 500: x"}"#.utf8)
        let reply = try JSONDecoder().decode(GoogleCalendarsResponse.self, from: put)
        XCTAssertEqual(reply.changed, 1)
        XCTAssertEqual(reply.hidden, 2)
        XCTAssertEqual(reply.syncError, "google 500: x")
        let delete = try JSONDecoder().decode(GoogleCalendarsResponse.self, from: Data(#"{"accounts":[],"removed":true,"hidden":3}"#.utf8))
        XCTAssertEqual(delete.removed, true)
    }

    // MARK: Requests

    func testRequests() throws {
        let list = APIRequest.calendars()
        XCTAssertEqual(list.method, .get)
        XCTAssertEqual(list.path, "/api/calendars")
        XCTAssertNil(list.encodedQuery)
        XCTAssertFalse(list.cacheable, "a stale switch is worse than an error")
        XCTAssertEqual(APIRequest.calendars(refresh: false).encodedQuery, "refresh=0")

        let put = try APIRequest.setCalendarSelection([CalendarSelection(account: "you@work.example", calendarId: "team@group.calendar.example", selected: true)])
        XCTAssertEqual(put.method, .put)
        XCTAssertEqual(put.path, "/api/calendars/selection")
        XCTAssertEqual(
            String(decoding: put.body ?? Data(), as: UTF8.self),
            #"{"selections":[{"account":"you@work.example","calendarId":"team@group.calendar.example","selected":true}]}"#
        )
        XCTAssertEqual(put.timeout, 60)
        XCTAssertFalse(put.cacheable)

        let delete = APIRequest.disconnectGoogleAccount(email: "you+cal@work.example")
        XCTAssertEqual(delete.method, .delete)
        XCTAssertEqual(delete.path, "/api/calendars/accounts/you%2Bcal%40work.example")
    }

    func testClientSendsTheRequestsAndDecodes() async throws {
        let host = "calendars.example.com"
        let body = try APIFixture.data("calendars.json")
        APIStub.register(host: host) { _ in .json(status: 200, body: body) }
        let client = APIClient.stubbed(host: host, credentials: nil)
        let reply = try await client.googleCalendars(refresh: false)
        XCTAssertEqual(reply.accounts.count, 2)
        _ = try await client.setGoogleCalendar(account: "you@work.example", calendarId: "team@group.calendar.example", selected: false)
        _ = try await client.disconnectGoogleAccount(email: "you@work.example")
        let seen = APIStub.seen(host: host)
        XCTAssertEqual(seen.map(\.httpMethod), ["GET", "PUT", "DELETE"])
        XCTAssertEqual(seen.map { $0.url?.path }, ["/api/calendars", "/api/calendars/selection", "/api/calendars/accounts/you@work.example"])
        XCTAssertEqual(seen.first?.url?.query, "refresh=0")
    }

    func testClientSurfacesTheWorkerSentence() async throws {
        let host = "calendars-404.example.com"
        APIStub.register(host: host) { _ in .json(status: 404, body: Data(#"{"error":"you@work.example is not connected"}"#.utf8)) }
        let client = APIClient.stubbed(host: host, credentials: nil)
        do {
            _ = try await client.disconnectGoogleAccount(email: "you@work.example")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 404, message: "you@work.example is not connected"))
        }
    }

    func testUnconfiguredThrows() async {
        do {
            _ = try await UnconfiguredAPI().googleCalendars(refresh: true)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .notConfigured)
        }
    }

    // MARK: Demo API

    func testDemoKeepsChoicesAndDisconnectsInMemory() async throws {
        let api = DemoAPI(directory: APIFixture.directory)
        let start = try await api.googleCalendars(refresh: true)
        XCTAssertEqual(start.accounts.count, 2)
        let on = try await api.setGoogleCalendar(account: "you@example.com", calendarId: "family@group.calendar.example", selected: true)
        XCTAssertEqual(on.changed, 1)
        XCTAssertEqual(on.accounts[0].calendars[1].isSelected, true)
        let again = try await api.googleCalendars(refresh: false)
        XCTAssertEqual(again.accounts[0].calendars[1].isSelected, true, "kept for the session")
        let gone = try await api.disconnectGoogleAccount(email: "you@work.example")
        XCTAssertEqual(gone.removed, true)
        XCTAssertEqual(gone.accounts.map(\.email), ["you@example.com"])
        do {
            _ = try await api.disconnectGoogleAccount(email: "you@work.example")
            XCTFail("second disconnect must throw")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 404)
        }
        do {
            _ = try await api.setGoogleCalendar(account: "you@example.com", calendarId: "nope", selected: true)
            XCTFail("unknown calendar must throw")
        } catch {
            XCTAssertEqual((error as? APIError)?.status, 404)
        }
    }

    func testDemoFailureToggleCoversCalendars() async {
        let api = DemoAPI(directory: APIFixture.directory)
        api.failure = .offline
        do {
            _ = try await api.googleCalendars(refresh: true)
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
    }

    // MARK: Logic

    func testAddAccountOpensTheSetupPageCalendarSection() {
        XCTAssertEqual(
            CalendarsLogic.addAccountURL(origin: URL(string: "https://stress.example.com")!)?.absoluteString,
            "https://stress.example.com/setup#calendars"
        )
        XCTAssertNil(CalendarsLogic.addAccountURL(origin: URL(string: "http://stress.example.com")!))
    }

    func testSummaryCountsAccountsAndChosenCalendars() throws {
        let reply = try APIFixture.decode(GoogleCalendarsResponse.self, "calendars.json")
        XCTAssertEqual(CalendarsLogic.summary(reply), "2 accounts, 3 calendars")
        XCTAssertNil(CalendarsLogic.summary(nil))
        XCTAssertEqual(CalendarsLogic.summary(GoogleCalendarsResponse()), "No Google account")
        let one = GoogleCalendarsResponse(accounts: [GoogleAccount(email: "a@example.com", calendars: [GoogleCalendar(id: "a@example.com", selected: true)])])
        XCTAssertEqual(CalendarsLogic.summary(one), "1 account, 1 calendar")
    }

    func testOptimisticChanges() throws {
        let reply = try APIFixture.decode(GoogleCalendarsResponse.self, "calendars.json")
        let flipped = CalendarsLogic.applying(reply, account: "you@work.example", calendarId: "holidays@group.v.calendar.example", selected: true)
        XCTAssertEqual(flipped.accounts[1].calendars[2].isSelected, true)
        XCTAssertEqual(CalendarsLogic.applying(reply, account: "x@example.com", calendarId: "y", selected: true), reply)
        XCTAssertEqual(CalendarsLogic.removing(reply, account: "you@example.com").accounts.map(\.email), ["you@work.example"])
    }

    func testDetailsAndFooters() {
        let now = APITime.parse("2026-11-24T16:00:00.000Z")!
        XCTAssertNil(CalendarsLogic.calendarDetail(GoogleCalendar(id: "a", primary: true)))
        XCTAssertNil(CalendarsLogic.calendarDetail(GoogleCalendar(id: "a")))
        // The main calendar is named after the account, which the section header already shows.
        XCTAssertEqual(CalendarsLogic.calendarName(GoogleCalendar(id: "a@x.example", name: "a@x.example", primary: true), account: "a@x.example"), "Main calendar")
        XCTAssertEqual(CalendarsLogic.calendarName(GoogleCalendar(id: "a@x.example", name: "Hershey", primary: true), account: "a@x.example"), "Hershey")
        XCTAssertEqual(CalendarsLogic.calendarName(GoogleCalendar(id: "team@x.example", name: "Team")), "Team")
        XCTAssertEqual(CalendarsLogic.calendarDetail(GoogleCalendar(id: "a", error: "google 403: {\"error\":...}")), "Sync failed. Google answered 403.")
        XCTAssertEqual(CalendarsLogic.calendarName(GoogleCalendar(id: "team@x.example", name: " ")), "team@x.example")

        XCTAssertEqual(CalendarsLogic.syncedText(nil, now: now), "Not synced yet")
        XCTAssertEqual(CalendarsLogic.syncedText("2026-11-24T15:59:30.000Z", now: now), "Synced just now")
        XCTAssertEqual(CalendarsLogic.syncedText("2026-11-24T15:45:00.000Z", now: now), "Synced 15 min ago")
        XCTAssertEqual(CalendarsLogic.syncedText("2026-11-24T13:00:00.000Z", now: now), "Synced 3 hr ago")
        XCTAssertTrue(CalendarsLogic.syncedText("2026-11-20T13:00:00.000Z", now: now).hasPrefix("Synced Nov"))

        let expired = GoogleAccount(email: "a@example.com", error: "google refresh failed 400: invalid_grant")
        XCTAssertEqual(CalendarsLogic.accountFooter(expired, now: now), "Google sign-in expired. Use Add Google account and pick this account again.")
        let failed = GoogleAccount(email: "a@example.com", error: "calendar list: google 500: x")
        XCTAssertEqual(CalendarsLogic.accountFooter(failed, now: now), "Last sync failed. Google answered 500.")
        let fine = GoogleAccount(email: "a@example.com", lastSyncAt: "2026-11-24T15:45:00.000Z")
        XCTAssertEqual(CalendarsLogic.accountFooter(fine, now: now), "Synced 15 min ago")
    }

    func testSavedMessageAndColors() {
        var reply = GoogleCalendarsResponse()
        XCTAssertEqual(CalendarsLogic.savedMessage(reply, selected: true), "Added. Its meetings are in.")
        XCTAssertNil(CalendarsLogic.savedMessage(reply, selected: false))
        reply.syncError = "google 503: down"
        XCTAssertEqual(CalendarsLogic.savedMessage(reply, selected: true), "Saved. Sync failed: Google answered 503.")
        XCTAssertEqual(CalendarsLogic.rgb("#ff0080")?.red, 1)
        XCTAssertEqual(CalendarsLogic.rgb("#f08")?.blue ?? 0, 0x88 / 255, accuracy: 0.0001)
        XCTAssertNil(CalendarsLogic.rgb("red"))
        XCTAssertNil(CalendarsLogic.rgb(nil))
    }

    func testUserFacingCopyHasNoEmDashes() throws {
        let reply = try APIFixture.decode(GoogleCalendarsResponse.self, "calendars.json")
        let now = Date()
        var copy = [CalendarsLogic.disconnectMessage, CalendarsLogic.disconnectTitle("a@example.com")]
        copy += reply.accounts.map { CalendarsLogic.accountFooter($0, now: now) }
        copy += reply.accounts.flatMap(\.calendars).compactMap(CalendarsLogic.calendarDetail)
        copy.append(ListeningCalendarChoice().summary(available: []))
        for text in copy { XCTAssertFalse(text.contains("\u{2014}"), text) }
    }

    // MARK: Listening calendars (Apple Calendar on this iPhone)

    private let cals = [
        DeviceCalendar(id: "w", title: "Work", sourceTitle: "Exchange"),
        DeviceCalendar(id: "h", title: "Home", sourceTitle: "iCloud"),
        DeviceCalendar(id: "b", title: "Birthdays", sourceTitle: "Other"),
        DeviceCalendar(id: "f", title: "family", sourceTitle: "iCloud"),
    ]

    func testEveryCalendarListensByDefault() {
        let choice = ListeningCalendarChoice()
        XCTAssertTrue(choice.listensToAll)
        XCTAssertEqual(choice.query(available: cals.map(\.id)), .all, "same as before the setting existed: calendars nil")
        XCTAssertEqual(choice.summary(available: cals), "All calendars")
    }

    func testTurningCalendarsOffNarrowsTheQuery() {
        var choice = ListeningCalendarChoice()
        choice.set("h", included: false)
        choice.set("b", included: false)
        XCTAssertFalse(choice.includes("h"))
        XCTAssertEqual(choice.query(available: cals.map(\.id)), .some(["w", "f"]))
        XCTAssertEqual(choice.summary(available: cals), "2 of 4 calendars")
        choice.set("h", included: true)
        XCTAssertEqual(choice.query(available: cals.map(\.id)), .some(["w", "h", "f"]))
    }

    func testAllOffMeansNoMeetingsNotEveryCalendar() {
        let choice = cals.reduce(ListeningCalendarChoice()) { $0.setting($1.id, included: false) }
        XCTAssertEqual(choice.query(available: cals.map(\.id)), .none)
        XCTAssertEqual(choice.summary(available: cals), "None")
    }

    func testANewCalendarCountsUntilTurnedOff() {
        let choice = ListeningCalendarChoice(excluded: ["h"])
        XCTAssertEqual(choice.query(available: ["w", "h", "new"]), .some(["w", "new"]))
        XCTAssertEqual(ListeningCalendarChoice(excluded: ["gone"]).query(available: ["w"]), .all, "a removed calendar does not matter")
    }

    func testChoiceIsSavedOnThisDevice() throws {
        let suite = "CalendarsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ListeningCalendarChoice.load(from: defaults), .all)
        ListeningCalendarChoice(excluded: ["b", "a"]).save(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: ListeningCalendarChoice.defaultsKey), ["a", "b"])
        XCTAssertEqual(ListeningCalendarChoice.load(from: defaults), ListeningCalendarChoice(excluded: ["a", "b"]))
        ListeningCalendarChoice.all.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: ListeningCalendarChoice.defaultsKey), "all is stored as nothing")
    }

    func testCalendarsAreGroupedByAccount() {
        let groups = ListeningCalendarChoice.grouped(cals)
        XCTAssertEqual(groups.map(\.source), ["Exchange", "iCloud", "Other"])
        XCTAssertEqual(groups[1].calendars.map(\.title), ["family", "Home"])
        XCTAssertEqual(DeviceCalendar(id: "x", title: "", sourceTitle: "").title, "Untitled calendar")
    }

    func testOnlyChosenCalendarsShapeTheMeetingWindow() {
        // The listening window comes from the meetings EventKit returns for the chosen calendars.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let work = CalendarMeeting(title: "Work sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2_400))!
        let home = CalendarMeeting(title: "Dentist", start: now.addingTimeInterval(60), end: now.addingTimeInterval(1_800))!
        let byCalendar = ["w": [work], "h": [home]]
        let choice = ListeningCalendarChoice(excluded: ["h"])
        let meetings: [CalendarMeeting]
        switch choice.query(available: ["w", "h"]) {
        case .all: meetings = byCalendar.values.flatMap { $0 }
        case .some(let ids): meetings = ids.flatMap { byCalendar[$0] ?? [] }
        case .none: meetings = []
        }
        let schedule = MeetingSchedule(meetings)
        XCTAssertNil(schedule.activeBlock(at: now), "the dentist does not start listening")
        XCTAssertEqual(schedule.activeBlock(at: now.addingTimeInterval(500))?.first.title, "Work sync")
    }
}
