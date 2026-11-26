import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9: the crumb route for the new endpoint, and the release notes (build 9, version 1.2).
//
// Everything in this file compiles against today's API and fails on its assertions until build 9 is written.
//
// Crumb routes. The new phone endpoint is PUT /api/meetings/:id/override (the id is a calendar event id and can carry a
// date, so it must never reach the crumbs). `CrumbRoute.name(path:)` maps it to the template
// "/api/meetings/:id/override", and `Crumb.request` writes that template, not "other". The Mac's
// POST /api/whoop-web/app/attendance has no :id and is not sent by the phone, so the phone's route list does not
// need it (not tested either way).
//
// Release notes. `ReleaseNotes.all` gets a build 9 release, version "1.2", at the top, so the list is 9, 8, 7, 6, 5, 4.

final class Build9CrumbRouteTests: XCTestCase {
    private let route = "/api/meetings/:id/override"

    func testTheOverridePathIsATemplate() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/7sf8ahq90d3k2j4/override"), route)
    }

    func testASeriesInstanceIDStillMapsToTheTemplate() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/7sf8ahq90d3k2j4_20261125T140000Z/override"), route)
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/7sf8ahq90d3k2j4_20261125/override"), route)
    }

    func testTheQueryAndFragmentAreDropped() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/abc/override?x=1"), route)
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/abc/override#top"), route)
    }

    func testAnyIDBecomesTheTemplate() {
        for id in ["abc", "a%2Fb", "ev.with.dots", "x@example.com", "A1B2", "100", "caf%C3%A9", "search", "hr", "override", "live-hr"] {
            XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/\(id)/override"), route, id)
        }
    }

    func testNothingFromThePathReachesTheRoute() {
        let result = CrumbRoute.name(path: "/api/meetings/secret-event-id_20261125T140000Z/override?title=Private")
        XCTAssertFalse(result.contains("secret"))
        XCTAssertFalse(result.contains("2026"))
        XCTAssertFalse(result.contains("Private"))
    }

    func testShapesThatAreNotTheEndpointAreOther() {
        for path in [
            "/api/meetings//override", "/api/meetings/override", "/api/meetings/abc/override/extra",
            "/api/meetings/abc/overrides", "/api/meetings/abc/override/", "/api/meetings/abc/Override",
            "/api/people/abc/override", "/api/companies/abc/override", "/api/settings/abc/override",
            "/api/override", "api/meetings/abc/override", "/other/meetings/abc/override",
        ] {
            XCTAssertEqual(CrumbRoute.name(path: path), "other", path)
        }
    }

    func testTheOtherMeetingRoutesAreUntouched() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/abc/hr"), "/api/meetings/:id/hr")
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/abc/live-hr"), "/api/meetings/:id/live-hr")
        XCTAssertEqual(CrumbRoute.name(path: "/api/view?date=2026-11-25"), "/api/view")
        XCTAssertEqual(CrumbRoute.name(path: "/api/companies/acme.example/name"), "/api/companies/:id/name")
    }

    func testARequestCrumbKeepsTheTemplate() throws {
        let directory = try B9.tempDirectory(self, "crumb-override")
        let log = CrumbLog(directory: directory)
        let path = "/api/meetings/7sf8ahq90d3k2j4_20261125T140000Z/override"
        log.add(.request(route: CrumbRoute.name(path: path), status: 200, ms: 87), at: B8.date(0))
        log.add(.request(route: CrumbRoute.name(path: path), status: 503, ms: 40), at: B8.date(1))
        let lines = log.lines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" request /api/meetings/:id/override 200 87ms"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" request /api/meetings/:id/override 503 40ms"), lines[1])
        XCTAssertFalse(lines.joined().contains("7sf8ahq90d3k2j4"))
    }

    func testEveryOverrideRequestIsWritten() {
        // It is a tap, not a poll: the crumb filter must not thin it out.
        let filter = RequestCrumbFilter()
        XCTAssertTrue(filter.shouldRecord(route: route, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: route, status: 200))
        XCTAssertTrue(filter.shouldRecord(route: route, status: 200))
        XCTAssertFalse(RequestCrumbFilter.defaultPollingRoutes.contains(route))
    }
}

final class Build9ReleaseNotesTests: XCTestCase {
    private var build9: ReleaseNotes.Release? { ReleaseNotes.all.first { $0.build == 9 } }

    func testBuild9IsStillListedAndIsVersion1Point2() throws {
        XCTAssertEqual(ReleaseNotes.all.map(\.build), [12, 11, 10, 9, 8, 7, 6, 5, 4])
        let release = try XCTUnwrap(build9)
        XCTAssertEqual(release.version, "1.2")
        XCTAssertEqual(ReleaseNotes.all.first?.build, 12)
    }

    func testEarlierReleasesKeepTheirVersions() {
        let versions = Dictionary(uniqueKeysWithValues: ReleaseNotes.all.map { ($0.build, $0.version) })
        XCTAssertEqual(versions[8], "1.1")
        for build in 4...7 { XCTAssertEqual(versions[build], "1.0", "build \(build)") }
    }

    func testBuild9HasARealDayNotBeforeBuild8() throws {
        let release = try XCTUnwrap(build9)
        XCTAssertNotNil(release.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression), release.date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = try XCTUnwrap(formatter.date(from: release.date))
        XCTAssertEqual(formatter.string(from: day), release.date, "a real calendar day")
        let previous = try XCTUnwrap(formatter.date(from: try XCTUnwrap(ReleaseNotes.all.first { $0.build == 8 }).date))
        XCTAssertGreaterThanOrEqual(day, previous)
        XCTAssertNotEqual(release.displayDate, release.date, "displayDate formats a real day")
    }

    func testBuild9ItemsAreShortPlainAndInTheAppsVoice() throws {
        let release = try XCTUnwrap(build9)
        XCTAssertFalse(release.items.isEmpty)
        XCTAssertLessThanOrEqual(release.items.count, 12)
        for item in release.items {
            XCTAssertEqual(item, item.trimmingCharacters(in: .whitespacesAndNewlines), item)
            XCTAssertFalse(item.isEmpty)
            XCTAssertLessThan(item.count, 120, item)
            XCTAssertFalse(item.contains("\u{2014}"), "no em dash: \(item)")
            XCTAssertFalse(item.contains("\u{2013}"), "no en dash: \(item)")
            XCTAssertFalse(item.contains("\n"), item)
        }
    }

    func testBuild9TellsAboutTheNewThings() throws {
        let release = try XCTUnwrap(build9)
        let text = release.items.joined(separator: " ").lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        XCTAssertTrue(text.contains("didn't join"), "the I didn't join action: \(text)")
        XCTAssertTrue(text.contains("still going"), "the Still going button: \(text)")
        XCTAssertTrue(text.contains("meeting times") || text.contains("start and end"), "changing a meeting's times: \(text)")
    }

    func testTestFlightNotesForBuild9AreDashBullets() throws {
        let release = try XCTUnwrap(build9)
        let text = try XCTUnwrap(ReleaseNotes.notesText(build: 9))
        XCTAssertEqual(text, release.items.map { "- \($0)" }.joined(separator: "\n"))
        XCTAssertLessThan(text.count, 4000)
    }

    func testAFreshBuild10InstallSeesNothingAndAnUpdateFromBuild9SeesOnlyBuild10() {
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: nil, current: 10), [])
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 9, current: 10).map(\.build), [10])
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 8, current: 10).map(\.build), [10, 9])
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 10, current: 10), [])
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 3, current: 12), ReleaseNotes.all, "build 12 is the newest note now")
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: 3, current: 10), ReleaseNotes.all.filter { $0.build <= 10 })
    }

    func testWhatsNewAfterTheUpdate() {
        let update = WhatsNew.decide(stored: 9, existingInstall: true, current: 10)
        XCTAssertEqual(update.releases.map(\.build), [10])
        XCTAssertEqual(update.store, 10)
        let fromSeven = WhatsNew.decide(stored: nil, existingInstall: true, current: 10)
        XCTAssertEqual(fromSeven.releases.map(\.build), [10, 9, 8])
        XCTAssertEqual(fromSeven.store, 10)
        let fresh = WhatsNew.decide(stored: nil, existingInstall: false, current: 10)
        XCTAssertEqual(fresh.releases, [])
        XCTAssertEqual(fresh.store, 10)
    }

    func testNotesTextIsStillNilForABuildWithoutANote() {
        for build in [-1, 0, 1, 3, 99] { XCTAssertNil(ReleaseNotes.notesText(build: build), "build \(build)") }
    }
}
