import Foundation
import XCTest
@testable import MeetspikeHRCore

// Regression tests for the company routes in `CrumbRoute` (build 8). A company is addressed by its domain, so the
// domain must never reach the crash breadcrumbs.
//
//   /api/companies                      -> itself
//   /api/companies/search               -> itself (query dropped)
//   /api/companies/<domain>/meetings    -> /api/companies/:id/meetings
//   /api/companies/<domain>/name        -> /api/companies/:id/name
//   anything else under /api/companies  -> other

final class Build8CompanyCrumbTests: XCTestCase {
    private let meetings = "/api/companies/:id/meetings"
    private let nameRoute = "/api/companies/:id/name"

    func testListAndSearchMapToThemselves() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies"), "/api/companies")
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/search"), "/api/companies/search")
    }

    func testQueryIsDropped() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/search?q=x"), "/api/companies/search")
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/search?q=Acme%20Dental"), "/api/companies/search")
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies?limit=10"), "/api/companies")
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies#top"), "/api/companies")
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/acme.example/meetings?from=2026-11-01"), meetings)
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/acme.example/name?x=acme.example"), nameRoute)
    }

    func testDomainBecomesIDForMeetingsAndName() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/acme.example/meetings"), meetings)
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/acme.example/name"), nameRoute)
    }

    func testDomainFormsNeverSurvive() {
        let domains = [
            "acme.example", "ACME.EXAMPLE", "Acme.Example", "mail.acme.co.uk",
            "acme%2Eexample", "acme%2eexample", "%61cme.example", "acme%20dental.example",
            "xn--bcher-kva.example", "xn--80ak6aa92e.example", "b\u{00FC}cher.example",
            "\u{043F}\u{0440}\u{0438}\u{043C}\u{0435}\u{0440}.example",
            "search", "companies", "name", "meetings", "api",
            "123456", String(repeating: "a", count: 250) + ".example",
        ]
        for domain in domains {
            for (suffix, template) in [("meetings", meetings), ("name", nameRoute)] {
                let path = "/api/companies/\(domain)/\(suffix)"
                let result = CrumbRoute.name(path: path)
                XCTAssertEqual(result, template, path)
                XCTAssertFalse(result.lowercased().contains("acme"), path)
                if domain.contains(".") || domain.contains("%") { XCTAssertFalse(result.contains(domain), path) }
            }
        }
    }

    func testDomainNamedSearchOrCompaniesIsStillAnID() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/search/meetings"), meetings)
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/search/name"), nameRoute)
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/companies/meetings"), meetings)
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/companies/name"), nameRoute)
        // Two segments after /api/companies is the only shape the :id routes use, so "search" alone stays the search route.
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/search"), "/api/companies/search")
    }

    func testExtraOrUnknownSegmentsAreOther() {
        let paths = [
            "/api/companies/acme.example",
            "/api/companies/acme.example/",
            "/api/companies/acme.example/unknown",
            "/api/companies/acme.example/meetings/extra",
            "/api/companies/acme.example/name/extra",
            "/api/companies/acme.example/meetings/",
            "/api/companies/acme.example/name/",
            "/api/companies/acme.example/hr",
            "/api/companies//meetings",
            "/api/companies//name",
            "/api/companies/search/extra",
            "/api/companies/search/",
            "/api/companies/",
            "/api/companies/acme.example/Meetings",
            "/api/companies/acme.example/NAME",
            "/api/Companies/acme.example/meetings",
            "/api/companies/acme.example/meetings/acme.example/name",
            "/api/companies/a/b/c/d/e",
            "api/companies/acme.example/meetings",
            "/companies/acme.example/meetings",
        ]
        for path in paths {
            let result = CrumbRoute.name(path: path)
            XCTAssertEqual(result, "other", path)
            XCTAssertFalse(result.contains("acme"), path)
        }
    }

    func testOtherRoutesAreUntouched() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/people/search?q=x"), "/api/people/search")
        XCTAssertEqual(CrumbRoute.name(path: "/api/people/acme.example/meetings"), "/api/people/:id/meetings")
        XCTAssertEqual(CrumbRoute.name(path: "/api/people/acme.example/name"), "other")
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/acme.example/name"), "other")
    }

    func testRequestCrumbLineHasNoDomain() throws {
        let directory = try B8.tempDirectory("company-crumb")
        defer { B8.remove(directory) }
        let log = CrumbLog(directory: directory)
        let paths = [
            "/api/companies", "/api/companies/search?q=acme", "/api/companies/acme.example/meetings",
            "/api/companies/acme.example/name", "/api/companies/acme.example/unknown",
        ]
        for path in paths {
            log.add(.request(route: CrumbRoute.name(path: path), status: 200, ms: 12), at: B8.date(0))
        }
        let lines = log.lines()
        XCTAssertEqual(lines.count, paths.count)
        for line in lines {
            XCTAssertFalse(line.lowercased().contains("acme"), line)
            XCTAssertFalse(line.contains("?"), line)
        }
        XCTAssertTrue(lines[0].hasSuffix("request /api/companies 200 12ms"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("request /api/companies/search 200 12ms"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("request /api/companies/:id/meetings 200 12ms"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("request /api/companies/:id/name 200 12ms"), lines[3])
        XCTAssertTrue(lines[4].hasSuffix("request other 200 12ms"), lines[4])
    }

    func testBuild8ReleaseNotesMentionCompanies() throws {
        let release = try XCTUnwrap(ReleaseNotes.all.first { $0.build == 8 })
        XCTAssertTrue(release.items.contains { $0.contains("Companies") }, "\(release.items)")
        XCTAssertTrue(try XCTUnwrap(ReleaseNotes.notesText(build: 8)).contains("Companies"))
    }
}
