import Foundation
import XCTest
@testable import MeetspikeHRCore

final class APIDemoTests: XCTestCase {
    private func demo(emptyDays: Bool = false, askKeySaved: Bool = true) -> DemoAPI {
        DemoAPI(directory: APIFixture.directory, emptyDays: emptyDays, askKeySaved: askKeySaved)
    }

    func testDemoTodayIsTheFullDay() async throws {
        let view = try await demo().view(date: DemoAPI.demoToday)
        XCTAssertEqual(view.day?.calendar?.events.count, 5)
        XCTAssertEqual(view.today, DemoAPI.demoToday)
    }

    func testOtherDaysAreTheEmptyDayWithTheRequestedDate() async throws {
        let view = try await demo().view(date: "2026-11-10")
        XCTAssertEqual(view.start, "2026-11-10")
        XCTAssertEqual(view.end, "2026-11-10")
        XCTAssertEqual(view.day?.date, "2026-11-10")
        XCTAssertEqual(view.day?.calendar?.day, "2026-11-10")
        XCTAssertEqual(view.series.first?.day, "2026-11-10")
        XCTAssertEqual(view.day?.calendar?.events.count, 0)
        XCTAssertEqual(view.today, DemoAPI.demoToday, "today stays the server's today")

        let allEmpty = try await demo(emptyDays: true).view(date: DemoAPI.demoToday)
        XCTAssertEqual(allEmpty.day?.calendar?.events.count, 0)
    }

    func testRangesAreServedWithTheRequestedSpan() async throws {
        let view = try await demo().view(start: "2026-11-01", end: "2026-11-14")
        XCTAssertEqual(view.range?.start, "2026-11-01")
        XCTAssertEqual(view.range?.end, "2026-11-14")
        XCTAssertEqual(view.spanDays, 14)
        XCTAssertEqual(view.range?.spanDays, 14)
        XCTAssertNotNil(view.range?.summary)
        // Start equal to end is the day shape.
        let single = try await demo().view(start: DemoAPI.demoToday, end: DemoAPI.demoToday)
        XCTAssertNotNil(single.day)
    }

    func testErrorToggleFailsEveryCallUntilCleared() async throws {
        let api = demo()
        api.failure = .offline
        do {
            _ = try await api.view(date: DemoAPI.demoToday)
            XCTFail("failure toggle should throw")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
        do {
            _ = try await api.people(start: "2026-11-01", end: "2026-11-24")
            XCTFail("failure toggle should throw")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
        do {
            for try await _ in api.askStream(AskRequest(question: "q", sourceDisplay: .make(oura: true, whoop: true))) {}
            XCTFail("failure toggle should throw")
        } catch {
            XCTAssertEqual(error as? APIError, .offline)
        }
        api.failure = .accessRejected
        do {
            _ = try await api.refresh()
            XCTFail("failure toggle should throw")
        } catch {
            XCTAssertEqual(error as? APIError, .accessRejected)
        }
        api.failure = nil
        let view = try await api.view(date: DemoAPI.demoToday)
        XCTAssertNotNil(view.day)
    }

    func testPeopleSearchAndDetail() async throws {
        let api = demo()
        let people = try await api.people(start: "2026-10-28", end: "2026-11-24")
        XCTAssertEqual(people.people.count, 4)
        let found = try await api.searchPeople(query: "DANA")
        XCTAssertEqual(found.map(\.email), ["dana.sample@example.com"])
        let none = try await api.searchPeople(query: "zzz")
        XCTAssertTrue(none.isEmpty)
        let blank = try await api.searchPeople(query: " ")
        XCTAssertTrue(blank.isEmpty)
        let person = try await api.personMeetings(email: "dana.sample@example.com", start: "2026-10-28", end: "2026-11-24")
        XCTAssertEqual(person.meetings.count, 5)
        let detail = try await api.meetingHR(id: "m-pipeline")
        XCTAssertEqual(detail.meetingId, "m-pipeline")
        let live = try await api.liveHR(meetingID: "m-pipeline")
        XCTAssertEqual(live.points.count, 60)
    }

    func testRefreshAndSourceDisplayKeepState() async throws {
        let api = demo()
        let refresh = try await api.refresh()
        XCTAssertEqual(refresh.calendar?.ok, true)
        XCTAssertFalse(refresh.needsGoogle)
        let before = try await api.sourceDisplay()
        XCTAssertEqual(before, .make(oura: true, whoop: true))
        let after = try await api.setSourceDisplay(.oura, enabled: false)
        XCTAssertEqual(after, .make(oura: false, whoop: true))
        let reread = try await api.sourceDisplay()
        XCTAssertEqual(reread, after)
        let status = try await api.askStatus()
        XCTAssertEqual(status.sourceDisplay, after)
    }

    func testAskFlowWithAndWithoutKey() async throws {
        let api = demo(askKeySaved: false)
        let none = try await api.askStatus()
        XCTAssertEqual(none.connected, false)
        var events: [AskEvent] = []
        for try await event in api.askStream(AskRequest(question: "q", sourceDisplay: .make(oura: true, whoop: true))) { events.append(event) }
        XCTAssertEqual(events, [.error(AskFailure(message: "Add your Claude API key in More, then ask again.", needsKey: true))])

        let saved = try await api.saveAskKey("sk-ant-dummy")
        XCTAssertEqual(saved.connected, true)
        let status = try await api.askStatus()
        XCTAssertEqual(status.connected, true)
        events = []
        for try await event in api.askStream(AskRequest(question: "q", sourceDisplay: .make(oura: true, whoop: true))) { events.append(event) }
        XCTAssertEqual(events.last, .done(AskDone(truncated: false, model: "claude-opus-5-5", start: "2026-10-28", end: "2026-11-24")))
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)

        let removed = try await api.deleteAskKey()
        XCTAssertEqual(removed.connected, false)
    }

    func testMissingFixturesFailLoudly() async {
        let api = DemoAPI(directory: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-folder"))
        do {
            _ = try await api.view(date: DemoAPI.demoToday)
            XCTFail("a missing fixture must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .decoding("missing fixture view-day.json"))
        }
    }

    /// The iPhone app bundles ios/MeetspikeHR/Resources/DemoData. It must be the same JSON as these fixtures.
    func testBundledDemoDataMatchesTheFixtures() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let demoData = url.appendingPathComponent("ios/MeetspikeHR/Resources/DemoData", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: demoData.path).filter { !$0.hasPrefix(".") }
        XCTAssertGreaterThanOrEqual(files.count, 12, "demo data folder is missing or empty")
        for name in files {
            XCTAssertEqual(
                try Data(contentsOf: demoData.appendingPathComponent(name)),
                try APIFixture.data(name),
                "\(name) differs from the test fixture. Copy it over."
            )
        }
        // Every file the demo API reads is bundled.
        for name in ["view-day.json", "view-empty-day.json", "view-range.json", "meeting-hr.json", "live-hr.json", "people.json",
                     "people-search.json", "person-meetings.json", "refresh.json", "ask-status.json", "ask-status-nokey.json",
                     "ask-key-saved.json", "ask-key-deleted.json", "ask-stream.sse",
                     "companies.json", "company-meetings.json", "company-search.json"] {
            XCTAssertTrue(files.contains(name), "\(name) is not in DemoData")
        }
    }

    func testBundledDemoAPIWorksOnTheDemoDataFolder() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let demoData = url.appendingPathComponent("ios/MeetspikeHR/Resources/DemoData", isDirectory: true)
        let api = DemoAPI(directory: demoData)
        let view = try await api.view(date: DemoAPI.demoToday)
        XCTAssertEqual(view.day?.calendar?.events.count, 5)
        _ = try await api.view(start: "2026-11-18", end: "2026-11-24")
        _ = try await api.people(start: "2026-10-28", end: "2026-11-24")
        _ = try await api.askStatus()
    }
}
