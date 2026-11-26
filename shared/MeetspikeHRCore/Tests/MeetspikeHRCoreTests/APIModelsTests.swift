import Foundation
import XCTest
@testable import MeetspikeHRCore

final class APIModelsTests: XCTestCase {
    func testViewDayDecodes() throws {
        let view = try APIFixture.decode(ViewResponse.self, "view-day.json")
        XCTAssertEqual(view.today, "2026-11-24")
        XCTAssertEqual(view.start, "2026-11-24")
        XCTAssertEqual(view.spanDays, 1)
        XCTAssertTrue(view.isSingleDay)
        XCTAssertNil(view.range)
        XCTAssertEqual(view.wearable?.kind, .whoop)
        XCTAssertEqual(view.wearable?.scoreLabel, "Recovery (WHOOP)")
        XCTAssertEqual(view.wearable?.hasIntradayHr, true)
        XCTAssertEqual(view.wearable?.strainMax, 21)

        let events = try XCTUnwrap(view.day?.calendar?.events)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(view.day?.calendar?.totalDurationS, 14400)
        let pipeline = try XCTUnwrap(events.first { $0.id == "m-pipeline" })
        XCTAssertEqual(pipeline.hrStress?.zone, "high")
        XCTAssertEqual(pipeline.hrStress?.partial?.lateStart, true)
        XCTAssertEqual(pipeline.hrStress?.series.count, 12)
        XCTAssertEqual(pipeline.attendees.first?.isSelf, true)
        XCTAssertNil(try XCTUnwrap(events.first { $0.id == "m-design" }).hrStress?.zone)
        XCTAssertEqual(try XCTUnwrap(events.first { $0.id == "m-design" }).hrStress?.hasCoverage, false)
        XCTAssertEqual(events.last?.afterHours, true)
        XCTAssertNotNil(APITime.parse(pipeline.startUtc))

        XCTAssertEqual(view.morningScores.count, 2)
        XCTAssertEqual(view.morningScores.first?.morning, 72)
        XCTAssertNil(view.morningScores.first?.nextMorning)
        XCTAssertEqual(view.usual?.meetingHours, 3.5)
        XCTAssertEqual(view.effect?.cost, 15)
        XCTAssertEqual(view.costly.count, 3)
        XCTAssertEqual(view.people.first?.name, "Dana Sample")
        XCTAssertNil(view.people.last?.name)
        XCTAssertEqual(view.series.count, 1)
        XCTAssertEqual(view.hits?.count, 2)
        XCTAssertEqual(view.hits?.first?.compare.first?.worse, true)
        XCTAssertEqual(view.status?.googleConnected, true)
        XCTAssertEqual(view.status?.wearables.count, 2)
        XCTAssertEqual(view.status?.lastSync?.createdAt, "2026-11-24T14:05:00.000Z")
        XCTAssertEqual(view.status?.sourceDisplay, SourceDisplay.make(oura: true, whoop: true))
    }

    func testEmptyDayDecodes() throws {
        let view = try APIFixture.decode(ViewResponse.self, "view-empty-day.json")
        XCTAssertEqual(view.day?.calendar?.eventCount, 0)
        XCTAssertEqual(view.day?.calendar?.events.count, 0)
        XCTAssertEqual(view.day?.summary, "No meetings.")
        XCTAssertEqual(view.hits?.count, 0)
        XCTAssertEqual(view.day?.nextMorning?.readinessScore, 74)
        XCTAssertEqual(view.day?.hr == nil, true)
    }

    func testNoWearableDecodes() throws {
        let view = try APIFixture.decode(ViewResponse.self, "view-day-no-wearable.json")
        XCTAssertNil(view.wearable?.source)
        XCTAssertNil(view.wearable?.kind)
        XCTAssertEqual(view.wearable?.scoreLabel, "Morning score")
        XCTAssertNil(view.hits)
        XCTAssertTrue(view.morningScores.isEmpty)
        XCTAssertNil(view.day?.priorNight)
        XCTAssertEqual(view.status?.sourceDisplay, SourceDisplay.make(oura: false, whoop: false))
    }

    func testRangeDecodes() throws {
        let view = try APIFixture.decode(ViewResponse.self, "view-range.json")
        XCTAssertNil(view.day)
        XCTAssertFalse(view.isSingleDay)
        let range = try XCTUnwrap(view.range)
        XCTAssertEqual(range.spanDays, 7)
        XCTAssertEqual(range.days.count, 7)
        XCTAssertEqual(range.summary?.meetingCount, 20)
        XCTAssertEqual(range.summary?.hardest?.id, "m-pipeline")
        XCTAssertEqual(range.recovery?.avgReadinessScore, 72)
        XCTAssertNil(range.days[2].morning?.readinessScore)
        XCTAssertEqual(range.days[3].meetings.count, 0)
        XCTAssertEqual(range.days[0].meetings.count, 4)
        XCTAssertEqual(range.grain?["range"], "A date range is inclusive local days.")
        XCTAssertEqual(view.series.count, 7)
        XCTAssertNil(view.series[2].recovery)
        XCTAssertNil(view.series[6].nextRecovery)
        XCTAssertEqual(view.series[0].nextRecovery, 71)
    }

    func testMeetingHRDetailDecodes() throws {
        let detail = try APIFixture.decode(MeetingHRDetail.self, "meeting-hr.json")
        XCTAssertEqual(detail.meetingId, "m-pipeline")
        XCTAssertEqual(detail.enabled, true)
        XCTAssertEqual(detail.series.count, 24)
        XCTAssertEqual(detail.baseline?.basis, "meetings")
        XCTAssertEqual(detail.baseline?.lowBpm, 66)
        XCTAssertEqual(detail.stress?.points.count, 3)
        XCTAssertEqual(detail.stress?.peakLevel, 2.6)
        XCTAssertEqual(detail.fill?.hr, "cached")
        XCTAssertNil(detail.message)
        XCTAssertEqual(detail.window?.fetchStartUtc, "2026-11-24T15:20:00.000Z")
    }

    func testLiveHRDecodes() throws {
        let live = try APIFixture.decode(LiveHRReply.self, "live-hr.json")
        XCTAssertEqual(live.active, true)
        XCTAssertEqual(live.points.count, 60)
        XCTAssertEqual(live.points[0].ms, live.window?.startMs)
        XCTAssertGreaterThan(live.points[0].bpm, 70)
        XCTAssertEqual(live.cursor, Int(live.points.last?.ms ?? 0))
        XCTAssertEqual((live.window?.fromMs ?? 0) + 600_000, live.window?.startMs)

        let idle = try APIFixture.decode(LiveHRReply.self, "live-hr-inactive.json")
        XCTAssertEqual(idle.active, false)
        XCTAssertTrue(idle.points.isEmpty)
        XCTAssertEqual(idle.cursor, 0)
    }

    func testPeopleDecode() throws {
        let people = try APIFixture.decode(PeopleResponse.self, "people.json")
        XCTAssertEqual(people.people.count, 4)
        XCTAssertEqual(people.people[0].avg, 58)
        XCTAssertNil(people.people[2].avg)
        XCTAssertNil(people.people[3].name)
        XCTAssertEqual(people.usualRecovery, 68)
        XCTAssertEqual(people.spanDays, 28)

        let search = try APIFixture.decode(PeopleSearchReply.self, "people-search.json")
        XCTAssertEqual(search.people.map(\.email), ["dana.sample@example.com", "jordan.fixture@example.com"])

        let person = try APIFixture.decode(PersonMeetingsResponse.self, "person-meetings.json")
        XCTAssertEqual(person.email, "dana.sample@example.com")
        XCTAssertEqual(person.meetings.count, 5)
        XCTAssertNil(person.meetings[0].nextReadinessScore)
        XCTAssertEqual(person.meetings[1].nextReadinessScore, 52)
        XCTAssertEqual(person.meetings[1].hrStress?.series.count, 0)
        XCTAssertEqual(person.trend?.badge, "often spikes you")
        XCTAssertEqual(person.trend?.spark.count, 8)
        XCTAssertEqual(person.trendsByHrSource.first?.source, "WHOOP")
        XCTAssertEqual(person.trendsByHrSource.first?.withCoverage, 5)
    }

    func testRefreshAndSettingsDecode() throws {
        let refresh = try APIFixture.decode(RefreshReply.self, "refresh.json")
        XCTAssertEqual(refresh.calendar?.ok, true)
        XCTAssertEqual(refresh.oura?.pending, true)
        XCTAssertEqual(refresh.syncedAt, "2026-11-24T14:10:00.000Z")
        XCTAssertEqual(refresh.calendar?.written, 2)
        XCTAssertNil(refresh.calendar?.removed)
        let changed = try APIFixture.decode(RefreshReply.self, "refresh-written-removed.json")
        XCTAssertEqual(changed.calendar?.written, 3)
        XCTAssertEqual(changed.calendar?.removed, 1)
        XCTAssertNil(changed.oura?.written)

        let needs = try APIFixture.decode(RefreshReply.self, "refresh-needs-google.json")
        XCTAssertEqual(needs.calendar?.needsGoogle, true)
        let result = RefreshResult(calendar: needs.calendar, whoop: needs.whoop, oura: needs.oura, needsGoogle: true)
        XCTAssertNil(result.calendarError, "needsGoogle is not an error")
        XCTAssertTrue(result.ouraFailed)
        XCTAssertFalse(result.whoopFailed)
        XCTAssertTrue(result.wearableRefreshed)

        XCTAssertEqual(try APIFixture.decode(SourceDisplay.self, "source-display.json"), SourceDisplay.make(oura: true, whoop: true))
        XCTAssertEqual(try APIFixture.decode(SourceDisplay.self, "source-display-patched.json"), SourceDisplay.make(oura: false, whoop: true))
    }

    func testAskModelsDecode() throws {
        let status = try APIFixture.decode(AskStatus.self, "ask-status.json")
        XCTAssertEqual(status.connected, true)
        XCTAssertEqual(status.tail, "a1b2")
        XCTAssertEqual(status.model, "claude-opus-5-5")
        let none = try APIFixture.decode(AskStatus.self, "ask-status-nokey.json")
        XCTAssertEqual(none.connected, false)
        XCTAssertNil(none.tail)
        XCTAssertEqual(try APIFixture.decode(AskKeyResult.self, "ask-key-saved.json").connected, true)
        XCTAssertEqual(try APIFixture.decode(AskKeyResult.self, "ask-key-deleted.json").connected, false)
        XCTAssertEqual(try APIFixture.decode(ErrorBody.self, "err-needs-key.json").needsKey, true)
        XCTAssertEqual(try APIFixture.decode(ErrorBody.self, "err-needs-google.json").needsGoogle, true)
    }

    func testModelsAreLenient() throws {
        // Nothing is required. Lists default to empty. Unknown keys are ignored.
        let empty = try JSONDecoder().decode(ViewResponse.self, from: Data("{}".utf8))
        XCTAssertNil(empty.today)
        XCTAssertTrue(empty.people.isEmpty)
        XCTAssertTrue(empty.series.isEmpty)
        XCTAssertNil(empty.hits)

        let odd = try JSONDecoder().decode(
            ViewResponse.self,
            from: Data(#"{"today":"2026-11-24","costly":null,"people":"nope","series":[],"somethingNew":{"a":1}}"#.utf8)
        )
        XCTAssertEqual(odd.today, "2026-11-24")
        XCTAssertTrue(odd.costly.isEmpty)
        XCTAssertTrue(odd.people.isEmpty)

        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(#"{"id":"x"}"#.utf8))
        XCTAssertEqual(meeting.id, "x")
        XCTAssertNil(meeting.hrStress)
        XCTAssertTrue(meeting.attendees.isEmpty)
        XCTAssertNil(meeting.sourceType)
    }

    func testTimeParsingAcceptsFractionalSeconds() {
        XCTAssertNotNil(APITime.parse("2026-11-24T15:30:00.000Z"))
        XCTAssertNotNil(APITime.parse("2026-11-24T15:30:00Z"))
        XCTAssertNil(APITime.parse("yesterday"))
        XCTAssertNil(APITime.parse(nil))
    }

    func testDayMath() {
        XCTAssertEqual(DayMath.addDays("2026-11-24", 1), "2026-11-25")
        XCTAssertEqual(DayMath.addDays("2026-03-01", -1), "2026-02-28")
        XCTAssertEqual(DayMath.addDays("2028-02-28", 1), "2028-02-29")
        XCTAssertEqual(DayMath.addDays("2026-11-01", 1), "2026-11-02", "DST end does not skip a day")
        XCTAssertEqual(DayMath.spanDays("2026-11-18", "2026-11-24"), 7)
        XCTAssertEqual(DayMath.spanDays("2026-11-24", "2026-11-24"), 1)
        XCTAssertEqual(DayMath.spanDays("nope", "2026-11-24"), 0)
        XCTAssertTrue(DayMath.isValid("2026-02-28"))
        XCTAssertFalse(DayMath.isValid("2026-02-30"))
        XCTAssertFalse(DayMath.isValid("2026-2-3"))
        XCTAssertEqual(DayMath.shiftMonth("2026-01", -1), "2025-12")
        XCTAssertEqual(DayMath.shiftMonth("2026-12", 1), "2027-01")
        XCTAssertEqual(DayMath.lastDay(ofMonth: "2026-02"), "2026-02-28")
        XCTAssertEqual(DayMath.lastDay(ofMonth: "2026-10"), "2026-10-31")
        let zone = TimeZone(identifier: "America/New_York")!
        // 2026-11-25 03:00 UTC is still Nov 24 evening in New York.
        XCTAssertEqual(DayMath.today(in: zone, now: Date(timeIntervalSince1970: 1_795_575_600)), "2026-11-24")
    }

    func testRequestBuildersEncodeAndSortKeys() throws {
        let person = APIRequest.personMeetings(email: "sam+test@example.com", start: "2026-11-01", end: "2026-11-24")
        XCTAssertEqual(person.path, "/api/people/sam%2Btest%40example.com/meetings")
        XCTAssertEqual(person.encodedQuery, "start=2026-11-01&end=2026-11-24&compact=1")
        XCTAssertEqual(person.cacheKey, "GET /api/people/sam%2Btest%40example.com/meetings?compact=1&end=2026-11-24&start=2026-11-01")
        let url = try XCTUnwrap(person.url(origin: URL(string: "https://example.com")!))
        XCTAssertEqual(url.absoluteString, "https://example.com/api/people/sam%2Btest%40example.com/meetings?start=2026-11-01&end=2026-11-24&compact=1")

        let search = APIRequest.searchPeople(query: "a+b c&d")
        XCTAssertEqual(search.encodedQuery, "q=a%2Bb%20c%26d")
        XCTAssertFalse(search.cacheable)

        XCTAssertEqual(APIRequest.meetingHR(id: "m 1").encodedQuery, "fill=0")
        XCTAssertNil(APIRequest.meetingHR(id: "m1", fill: true).encodedQuery)
        XCTAssertEqual(APIRequest.liveHR(meetingID: "m1", since: 42).encodedQuery, "since=42")
        XCTAssertFalse(APIRequest.liveHR(meetingID: "m1").cacheable)
        XCTAssertEqual(String(decoding: APIRequest.refresh().body ?? Data(), as: UTF8.self), #"{"mode":"live"}"#)
        XCTAssertEqual(String(decoding: APIRequest.refresh(full: true).body ?? Data(), as: UTF8.self), #"{"full":true,"mode":"live"}"#)
        XCTAssertEqual(APIRequest.refresh().method, .post)
        XCTAssertFalse(APIRequest.refresh().cacheable)
    }

    func testSourceDisplayPatchHasExactlyOneKey() throws {
        for (source, key) in [(SourceDisplay.Source.oura, "oura"), (.whoop, "whoop")] {
            for enabled in [true, false] {
                let request = MoreLogic.sourceToggleRequest(source: source, enabled: enabled)
                XCTAssertEqual(request.method, .patch)
                XCTAssertEqual(request.path, "/api/settings/source-display")
                let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Bool]
                XCTAssertEqual(object, [key: enabled])
            }
        }
    }

    func testAskRequestEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let scoped = AskRequest(
            question: "How was my week?", history: [AskTurn(role: .user, content: "hi"), AskTurn(role: .assistant, content: "hello")],
            sourceDisplay: .make(oura: false, whoop: true), start: "2026-11-18", end: "2026-11-24"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(scoped)) as? [String: Any])
        XCTAssertEqual(json["question"] as? String, "How was my week?")
        XCTAssertEqual(json["start"] as? String, "2026-11-18")
        XCTAssertEqual(json["end"] as? String, "2026-11-24")
        XCTAssertEqual((json["sourceDisplay"] as? [String: Bool]), ["oura": false, "whoop": true])
        let history = try XCTUnwrap(json["history"] as? [[String: String]])
        XCTAssertEqual(history, [["role": "user", "content": "hi"], ["role": "assistant", "content": "hello"]])

        // A lone start is dropped: the Worker would treat it as a scoped, invalid range.
        let lone = AskRequest(question: "q", sourceDisplay: .make(oura: true, whoop: true), start: "2026-11-18")
        let loneJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(lone)) as? [String: Any])
        XCTAssertNil(loneJSON["start"])
        XCTAssertNil(loneJSON["end"])
    }
}
