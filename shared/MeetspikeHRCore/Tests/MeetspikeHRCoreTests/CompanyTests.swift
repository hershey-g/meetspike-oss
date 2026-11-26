import Foundation
import XCTest
@testable import MeetspikeHRCore

/// Companies tagged from attendee email domains: models, requests, the demo API and the list logic.
final class CompanyTests: XCTestCase {
    // MARK: Models

    func testCompaniesDecode() throws {
        let list = try APIFixture.decode(CompaniesResponse.self, "companies.json")
        XCTAssertEqual(list.companies.count, 4)
        let first = try XCTUnwrap(list.companies.first)
        XCTAssertEqual(first.domain, "northwind.example")
        XCTAssertEqual(first.displayName, "Northwind")
        XCTAssertEqual(first.meetings, 11)
        XCTAssertEqual(first.people, 3)
        XCTAssertEqual(first.avg, 57)
        XCTAssertEqual(first.trend?.badge, "often spikes you")
        XCTAssertEqual(first.trend?.spark.count, 9)
        XCTAssertNil(list.companies[2].avg)
        XCTAssertEqual(list.usualRecovery, 68)
        XCTAssertEqual(list.wearable?.source, "whoop")
    }

    func testCompanyMeetingsDecode() throws {
        let company = try APIFixture.decode(CompanyMeetingsResponse.self, "company-meetings.json")
        XCTAssertEqual(company.domain, "northwind.example")
        XCTAssertEqual(company.name, "Northwind")
        XCTAssertEqual(company.people.map(\.email), ["dana.sample@example.com", "riley.demo@example.com", "jordan.fixture@example.com"])
        XCTAssertEqual(company.people[0].meetings, 4)
        XCTAssertNil(company.people[2].name)
        XCTAssertEqual(company.meetings.count, 5)
        XCTAssertEqual(company.meetings[1].companyAttendees.map(\.email), ["dana.sample@example.com", "jordan.fixture@example.com"])
        XCTAssertEqual(company.meetings[2].companies.map(\.domain), ["northwind.example", "globex.example"])
        XCTAssertEqual(company.trendsByHrSource.first?.source, "WHOOP")
        XCTAssertEqual(company.trend?.withCoverage, 9)
    }

    func testCompanySearchDecodes() throws {
        let reply = try APIFixture.decode(CompanySearchReply.self, "company-search.json")
        XCTAssertEqual(reply.companies.first, CompanyTag(domain: "northwind.example", name: "Northwind"))
    }

    func testMeetingsCarryCompanyTags() throws {
        let view = try APIFixture.decode(ViewResponse.self, "view-day.json")
        let events = try XCTUnwrap(view.day?.calendar?.events)
        XCTAssertEqual(events.map { $0.companies.map(\.domain) }, [
            [], ["northwind.example", "globex.example"], [], ["northwind.example"], ["initech.example"],
        ])
        XCTAssertEqual(view.hits?.first?.companies.map(\.name), ["Northwind", "Globex"])
        let person = try APIFixture.decode(PersonMeetingsResponse.self, "person-meetings.json")
        XCTAssertEqual(person.meetings.first?.companies.first?.displayName, "Northwind")
        XCTAssertEqual(person.meetings.first?.companyAttendees, [])
    }

    func testCompanyModelsAreLenient() throws {
        // An older Worker sends no `companies`: the lists are empty, never a decoding failure.
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(#"{"id":"m1","attendees":[{"email":"a@b.co"}]}"#.utf8))
        XCTAssertEqual(meeting.companies, [])
        let personMeeting = try JSONDecoder().decode(PersonMeeting.self, from: Data(#"{"id":"m1","companies":null}"#.utf8))
        XCTAssertEqual(personMeeting.companies, [])
        let empty = try JSONDecoder().decode(CompaniesResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.companies.count, 0)
        let bare = try JSONDecoder().decode(CompanyMeetingsResponse.self, from: Data("{}".utf8))
        XCTAssertEqual(bare.people.count, 0)
        XCTAssertEqual(CompanyTag(domain: "acme.com", name: nil).displayName, "acme.com")
        XCTAssertEqual(CompanyTag(domain: "acme.com", name: "").displayName, "acme.com")
    }

    // MARK: Requests

    func testCompanyRequests() throws {
        let list = APIRequest.companies(start: "2026-11-01", end: "2026-11-24")
        XCTAssertEqual(list.path, "/api/companies")
        XCTAssertEqual(list.encodedQuery, "start=2026-11-01&end=2026-11-24")
        XCTAssertTrue(list.cacheable)

        let search = APIRequest.searchCompanies(query: "acme corp")
        XCTAssertEqual(search.path, "/api/companies/search")
        XCTAssertEqual(search.encodedQuery, "q=acme%20corp")
        XCTAssertFalse(search.cacheable)

        let meetings = APIRequest.companyMeetings(domain: "acme.co.uk", start: "2026-11-01", end: "2026-11-24")
        XCTAssertEqual(meetings.path, "/api/companies/acme.co.uk/meetings")
        XCTAssertEqual(meetings.encodedQuery, "start=2026-11-01&end=2026-11-24&compact=1")

        let rename = try APIRequest.renameCompany(domain: "acme.com", name: "Acme Corp")
        XCTAssertEqual(rename.method, .put)
        XCTAssertEqual(rename.path, "/api/companies/acme.com/name")
        XCTAssertEqual(String(decoding: rename.body ?? Data(), as: UTF8.self), #"{"name":"Acme Corp"}"#)
        XCTAssertFalse(rename.cacheable)
        let reset = try APIRequest.renameCompany(domain: "acme.com", name: nil)
        XCTAssertEqual(String(decoding: reset.body ?? Data(), as: UTF8.self), #"{"name":null}"#)
    }

    // MARK: Demo API

    private func demo() -> DemoAPI { DemoAPI(directory: APIFixture.directory) }

    func testDemoCompaniesUseTheRequestedRange() async throws {
        let list = try await demo().companies(start: "2026-11-01", end: "2026-11-14")
        XCTAssertEqual(list.start, "2026-11-01")
        XCTAssertEqual(list.spanDays, 14)
        XCTAssertEqual(list.companies.count, 4)
    }

    func testDemoCompanySearchFilters() async throws {
        let api = demo()
        let hits = try await api.searchCompanies(query: "glob")
        XCTAssertEqual(hits.map(\.domain), ["globex.example"])
        let byDomain = try await api.searchCompanies(query: "initech.ex")
        XCTAssertEqual(byDomain.map(\.name), ["Initech"])
        let none = try await api.searchCompanies(query: "  ")
        XCTAssertEqual(none, [])
    }

    func testDemoCompanyPageUsesTheRequestedCompany() async throws {
        let api = demo()
        let northwind = try await api.companyMeetings(domain: "northwind.example", start: "2026-11-01", end: "2026-11-24", compact: true)
        XCTAssertEqual(northwind.name, "Northwind")
        XCTAssertEqual(northwind.from, "2026-11-01")
        let globex = try await api.companyMeetings(domain: "globex.example", start: "2026-11-01", end: "2026-11-24", compact: true)
        XCTAssertEqual(globex.domain, "globex.example")
        XCTAssertEqual(globex.name, "Globex")
    }

    func testDemoRenameShowsEverywhereAndResets() async throws {
        let api = demo()
        let saved = try await api.renameCompany(domain: "globex.example", name: "  Globex Corporation ")
        XCTAssertEqual(saved.name, "Globex Corporation")
        let list = try await api.companies(start: "2026-11-01", end: "2026-11-24")
        XCTAssertEqual(list.companies.first { $0.domain == "globex.example" }?.name, "Globex Corporation")
        let page = try await api.companyMeetings(domain: "globex.example", start: "2026-11-01", end: "2026-11-24", compact: true)
        XCTAssertEqual(page.name, "Globex Corporation")
        let found = try await api.searchCompanies(query: "corporation")
        XCTAssertEqual(found.map(\.domain), ["globex.example"])
        let reset = try await api.renameCompany(domain: "globex.example", name: "")
        XCTAssertEqual(reset.name, "Globex")
    }

    func testUnconfiguredCompaniesThrow() async {
        do {
            _ = try await UnconfiguredAPI().companies(start: "2026-11-01", end: "2026-11-24")
            XCTFail("must throw")
        } catch {
            XCTAssertEqual(error as? APIError, .notConfigured)
        }
    }

    // MARK: Logic

    private func company(_ domain: String, _ name: String?, meetings: Int, people: Int, avg: Double?) throws -> CompanySummary {
        var object: [String: Any] = ["domain": domain, "meetings": meetings, "people": people]
        if let name { object["name"] = name }
        if let avg { object["avg"] = avg }
        return try JSONDecoder().decode(CompanySummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testSortOrders() throws {
        let list = [
            try company("b.com", "Beta", meetings: 3, people: 5, avg: 70),
            try company("a.com", "Alpha", meetings: 3, people: 1, avg: nil),
            try company("c.com", "Gamma", meetings: 8, people: 2, avg: 41),
            try company("d.com", nil, meetings: 1, people: 1, avg: 55),
        ]
        XCTAssertEqual(CompanyLogic.sorted(list, by: .meetings).map(\.domain), ["c.com", "a.com", "b.com", "d.com"])
        XCTAssertEqual(CompanyLogic.sorted(list, by: .people).map(\.domain), ["b.com", "c.com", "a.com", "d.com"])
        XCTAssertEqual(CompanyLogic.sorted(list, by: .score).map(\.domain), ["c.com", "d.com", "b.com", "a.com"])
        XCTAssertEqual(CompanyLogic.sorted(list, by: .name).map(\.domain), ["a.com", "b.com", "d.com", "c.com"])
        XCTAssertEqual(CompanySort.allCases.map(\.label), ["Most meetings", "Most people", "Lowest score", "Name"])
        XCTAssertEqual(PeopleMode.allCases.map(\.label), ["People", "Companies"])
    }

    func testRowText() throws {
        XCTAssertEqual(CompanyLogic.detail(try company("a.com", "A", meetings: 1, people: 1, avg: nil)), "1 meeting \u{B7} 1 person")
        XCTAssertEqual(CompanyLogic.detail(try company("a.com", "A", meetings: 3, people: 2, avg: nil)), "3 meetings \u{B7} 2 people")
        let list = try APIFixture.decode(CompaniesResponse.self, "companies.json")
        XCTAssertEqual(list.companies.map { CompanyLogic.hrSummary($0.trend) }, [
            "Often spikes you", "Usually restored", "Elevated in 1 of 3", nil,
        ])
        XCTAssertNil(CompanyLogic.hrSummary(nil))
        XCTAssertEqual(CompanyLogic.initials("Umbrella Health", domain: "x.com"), "UH")
        XCTAssertEqual(CompanyLogic.initials(nil, domain: "globex.io"), "G")
        XCTAssertEqual(CompanyLogic.initials("", domain: "acme-corp.com"), "AC")
        let company = try APIFixture.decode(CompanyMeetingsResponse.self, "company-meetings.json")
        XCTAssertEqual(CompanyLogic.attendeeLine(company.meetings[1].companyAttendees), "Dana Sample, jordan.fixture@example.com")
        XCTAssertEqual(CompanyLogic.attendeeLine([]), "")
    }

    func testNoEmDashesInCompanyCopy() throws {
        var copy = CompanySort.allCases.map(\.label) + PeopleMode.allCases.map(\.label)
        let list = try APIFixture.decode(CompaniesResponse.self, "companies.json")
        copy += list.companies.compactMap { CompanyLogic.hrSummary($0.trend) }
        copy += list.companies.compactMap { $0.trend?.badgeNote }
        for text in copy { XCTAssertFalse(text.contains("\u{2014}"), text) }
    }

    func testSearchCacheKeepsAnswersForFiveMinutes() {
        var cache = CompanySearchCache()
        let now = Date(timeIntervalSince1970: 1_000)
        let hits = [CompanyTag(domain: "acme.com", name: "Acme")]
        cache.store(hits, for: "ACME", now: now)
        XCTAssertEqual(cache.companies(for: "acme", now: now.addingTimeInterval(299)), hits)
        XCTAssertNil(cache.companies(for: "acme", now: now.addingTimeInterval(301)))
        for i in 0..<45 { cache.store([], for: "q\(i)", now: now) }
        XCTAssertEqual(cache.count, PeopleLogic.searchCacheLimit)
        XCTAssertNil(cache.companies(for: "acme", now: now))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }
}
