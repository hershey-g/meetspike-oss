import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8, track `app`, D4: the breadcrumb log. Helpers (B8) are in Build8DiagnosticReportTests.swift.
//
// Names the builder must provide:
//
//   public enum Crumb: Equatable, Sendable        a CLOSED set, nothing in it can hold free text
//       case launch(build: Int), active, background, memoryWarning, tab(Tab), menuOpen,
//            dayLoad(ms: Int, ok: Bool), detailLoad(ms: Int, points: Int, ok: Bool),
//            request(route: String, status: Int, ms: Int), bluetooth(BluetoothCrumb), listen(on: Bool)
//       public enum Tab: String, Sendable { today, dates, people, ask, live }
//   public enum BluetoothCrumb: String, Sendable { connected, disconnected, failed }
//   public enum CrumbRoute { public static func name(path: String) -> String }
//   public final class CrumbLog: @unchecked Sendable (thread safe)
//       public init(directory: URL, limit: Int = 150)       creates the directory (and parents) if missing
//       public func add(_ kind: Crumb, at: Date)            never throws, never blocks on anything but a short append
//       public func lines() -> [String]                     the current file's newest `limit` lines, oldest first
//       public func rotate() -> [String]                    returns lines() and starts a fresh, empty file
//
// Text form of a line is "<ISO date with 3 ms digits and Z> <body>", the body being:
//       launch 8 | active | background | memoryWarning | tab today | menuOpen | dayLoad 812ms ok (or fail)
//       detailLoad 1450ms 33135pts ok (or fail) | request /api/meetings/:id/hr 200 95ms
//       bluetooth connected (disconnected, failed) | listen on (off)
//
// `CrumbRoute.name(path:)` maps a request path to one of a fixed set of templates, or "other".

final class Build8CrumbTextTests: XCTestCase {
    private let stamp = "2026-11-25T05:00:00.000Z"

    private func line(_ crumb: Crumb, at date: Date = B8.date(0)) throws -> String {
        let directory = try B8.tempDirectory("crumb-text")
        defer { B8.remove(directory) }
        let log = CrumbLog(directory: directory)
        log.add(crumb, at: date)
        return try XCTUnwrap(log.lines().first)
    }

    func testEveryCaseHasItsExactText() throws {
        let table: [(Crumb, String)] = [
            (.launch(build: 8), "launch 8"),
            (.active, "active"),
            (.background, "background"),
            (.memoryWarning, "memoryWarning"),
            (.tab(.today), "tab today"),
            (.tab(.dates), "tab dates"),
            (.tab(.people), "tab people"),
            (.tab(.ask), "tab ask"),
            (.tab(.live), "tab live"),
            (.menuOpen, "menuOpen"),
            (.dayLoad(ms: 812, ok: true), "dayLoad 812ms ok"),
            (.dayLoad(ms: 30_000, ok: false), "dayLoad 30000ms fail"),
            (.detailLoad(ms: 1450, points: 33_135, ok: true), "detailLoad 1450ms 33135pts ok"),
            (.detailLoad(ms: 9, points: 0, ok: false), "detailLoad 9ms 0pts fail"),
            (.request(route: "/api/meetings/:id/hr", status: 200, ms: 95), "request /api/meetings/:id/hr 200 95ms"),
            (.request(route: "other", status: 503, ms: 12), "request other 503 12ms"),
            (.bluetooth(.connected), "bluetooth connected"),
            (.bluetooth(.disconnected), "bluetooth disconnected"),
            (.bluetooth(.failed), "bluetooth failed"),
            (.listen(on: true), "listen on"),
            (.listen(on: false), "listen off"),
        ]
        for (crumb, body) in table {
            XCTAssertEqual(try line(crumb), "\(stamp) \(body)")
        }
    }

    func testTimestampHasMillisecondsAndZ() throws {
        XCTAssertEqual(try line(.active, at: B8.date(0.5)), "2026-11-25T05:00:00.500Z active")
        XCTAssertEqual(try line(.active, at: B8.date(0.007)), "2026-11-25T05:00:00.007Z active")
        XCTAssertEqual(try line(.active, at: B8.date(3_661)), "2026-11-25T06:01:01.000Z active")
        XCTAssertEqual(try line(.active, at: Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z active")
    }

    func testNoLineHasTheShapeOfPersonalData() throws {
        // Whatever the numbers are, a line is date + a word + words/numbers: no quotes, no @, no URL, no uuid.
        let crumbs: [Crumb] = [
            .launch(build: 8), .tab(.people), .dayLoad(ms: 1, ok: true), .detailLoad(ms: 2, points: 3, ok: false),
            .request(route: CrumbRoute.name(path: "/api/people/dana.cole@example.com/meetings?q=Dentist"), status: 200, ms: 4),
            .bluetooth(.failed), .listen(on: true),
        ]
        for crumb in crumbs {
            let text = try line(crumb)
            XCTAssertFalse(text.contains("@"), text)
            XCTAssertFalse(text.contains("http"), text)
            XCTAssertFalse(text.contains("Dana"), text)
            XCTAssertFalse(text.lowercased().contains("dana"), text)
            XCTAssertFalse(text.contains("?"), text)
            XCTAssertFalse(text.contains("\n"), text)
            XCTAssertNil(text.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-", options: .regularExpression), text)
        }
    }
}

// MARK: CrumbRoute

final class Build8CrumbRouteTests: XCTestCase {
    private let templates: [(String, String)] = [
        ("/api/view", "/api/view"),
        ("/api/meetings/ev_0f9a2c/hr", "/api/meetings/:id/hr"),
        ("/api/meetings/ev_0f9a2c/live-hr", "/api/meetings/:id/live-hr"),
        ("/api/people", "/api/people"),
        ("/api/people/search", "/api/people/search"),
        ("/api/people/dana.cole@example.com/meetings", "/api/people/:id/meetings"),
        ("/api/people/dana.cole%40example.com/meetings", "/api/people/:id/meetings"),
        ("/api/refresh", "/api/refresh"),
        ("/api/calendar/sync", "/api/calendar/sync"),
        ("/api/settings/source-display", "/api/settings/source-display"),
        ("/api/ask/status", "/api/ask/status"),
        ("/api/ask/key", "/api/ask/key"),
        ("/api/ask/stream", "/api/ask/stream"),
    ]

    func testEveryAppEndpointMapsToItsTemplate() {
        for (path, template) in templates {
            XCTAssertEqual(CrumbRoute.name(path: path), template, path)
        }
    }

    func testQueryIsDropped() {
        XCTAssertEqual(CrumbRoute.name(path: "/api/view?date=2026-11-24"), "/api/view")
        XCTAssertEqual(CrumbRoute.name(path: "/api/view?start=2026-11-01&end=2026-11-30"), "/api/view")
        XCTAssertEqual(CrumbRoute.name(path: "/api/people/search?q=Dana%20Cole"), "/api/people/search")
        XCTAssertEqual(CrumbRoute.name(path: "/api/meetings/ev_1/hr?from=2026-11-24T14:00:00Z"), "/api/meetings/:id/hr")
        XCTAssertEqual(CrumbRoute.name(path: "/api/view#frag"), "/api/view")
    }

    func testIDsNeverSurvive() {
        let ids = ["ev_0f9a2c", "5f0c2a60-1b2c-4d3e-8f90-123456789abc", "123456", "dana.cole@example.com", "Dentist%20with%20Dana",
                   "qq9", String(repeating: "z", count: 300), "\u{1F600}", "..", "%2e%2e"]
        for id in ids {
            for path in ["/api/meetings/\(id)/hr", "/api/meetings/\(id)/live-hr", "/api/people/\(id)/meetings"] {
                let name = CrumbRoute.name(path: path)
                XCTAssertFalse(name.contains(id), "\(path) -> \(name)")
                XCTAssertTrue(name.contains(":id") || name == "other", "\(path) -> \(name)")
            }
        }
    }

    func testUnknownPathsAreOtherAndLeakNothing() {
        let unknown = [
            "", "/", "api/view", "/api", "/api/", "/api/secret-feature", "/api/meetings", "/api/meetings/ev_1",
            "/api/meetings/ev_1/hr/extra", "/api/meetings/ev_1/notes", "/api/meetings/ev_1/hr/../notes",
            "/api/people/dana@example.com", "/api/people/dana@example.com/notes", "/api/people/a/b/c",
            "/Dentist with Dana Cole", "/api/Dentist-with-Dana", "/v2/api/view", "/api/ask/stream/Dana",
            "https://evil.example.com/api/view", "\n", "/api/view\n/api/refresh", "/../../etc/passwd", "????",
            "/api/people/search/extra", "/api/refresh/ev_1", "/API/VIEW",
        ]
        for path in unknown {
            XCTAssertEqual(CrumbRoute.name(path: path), "other", path)
        }
    }

    func testResultIsAlwaysATemplateOrOther() {
        // Throw secrets into every position, then check that every segment of the answer is one of the known words.
        let words: Set<String> = ["api", "view", "meetings", "hr", "live-hr", "people", "search", ":id", "refresh", "calendar",
                                  "sync", "settings", "source-display", "ask", "status", "key", "stream", "whoop-web", "app",
                                  "ios", "diagnostics", "ingest", "live", "reminder", "owner"]
        let secrets = ["SECRET1", "dana@example.com", "5f0c2a60-1b2c-4d3e-8f90-123456789abc", "Dentist", "tok_abc123"]
        var seeds: [String] = []
        for s in secrets {
            seeds += ["/api/meetings/\(s)/hr", "/api/meetings/\(s)/\(s)", "/api/people/\(s)/meetings?q=\(s)", "/\(s)/api/view",
                      "/api/\(s)", "/api/\(s)/\(s)/\(s)", "/api/view?\(s)", "/api/ask/\(s)", "/api/settings/\(s)", "/api/calendar/\(s)",
                      "/\(s)", "\(s)", "/api/people/search/\(s)", "/api/whoop-web/\(s)", "/api/whoop-web/app/\(s)"]
        }
        for path in seeds {
            let name = CrumbRoute.name(path: path)
            for s in secrets { XCTAssertFalse(name.contains(s), "\(path) -> \(name)") }
            if name != "other" {
                for segment in name.split(separator: "/") {
                    XCTAssertTrue(words.contains(String(segment)), "\(path) -> \(name): \(segment)")
                }
            }
        }
    }

    func testRunningItTwiceChangesNothing() {
        for (path, _) in templates {
            let once = CrumbRoute.name(path: path)
            XCTAssertEqual(CrumbRoute.name(path: once), once, path)
        }
        XCTAssertEqual(CrumbRoute.name(path: "other"), "other")
    }

    func testIsFastEnoughToCallOnEveryRequest() {
        measure { for i in 0..<2000 { _ = CrumbRoute.name(path: "/api/meetings/ev_\(i)/hr?x=\(i)") } }
    }
}

// MARK: CrumbLog

final class Build8CrumbLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("crumblog") }
    override func tearDown() { B8.remove(directory) }

    private func dayLoads(_ log: CrumbLog, _ range: Range<Int>) {
        for n in range { log.add(.dayLoad(ms: n, ok: true), at: B8.date(Double(n) / 1000)) }
    }

    private func ms(_ lines: [String]) -> [Int] {
        lines.compactMap { line in
            guard let part = line.split(separator: " ").dropFirst(2).first, part.hasSuffix("ms") else { return nil }
            return Int(part.dropLast(2))
        }
    }

    /// Every line in every file under the directory.
    private func diskLines() -> [String] {
        var out: [String] = []
        let manager = FileManager.default
        let names = (try? manager.subpathsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            var isDirectory: ObjCBool = false
            let url = directory.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = try? Data(contentsOf: url) else { continue }
            out += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        return out
    }

    func testStartsEmpty() {
        let log = CrumbLog(directory: directory)
        XCTAssertEqual(log.lines(), [])
        XCTAssertEqual(log.rotate(), [])
        XCTAssertEqual(log.lines(), [])
    }

    func testLinesComeBackOldestFirst() {
        let log = CrumbLog(directory: directory)
        log.add(.launch(build: 8), at: B8.date(0))
        log.add(.active, at: B8.date(1))
        log.add(.tab(.today), at: B8.date(2))
        XCTAssertEqual(log.lines(), [
            "2026-11-25T05:00:00.000Z launch 8",
            "2026-11-25T05:00:01.000Z active",
            "2026-11-25T05:00:02.000Z tab today",
        ])
    }

    func testSurvivesAKillBecauseANewInstanceSeesTheLines() {
        let first = CrumbLog(directory: directory)
        first.add(.launch(build: 8), at: B8.date(0))
        first.add(.dayLoad(ms: 812, ok: true), at: B8.date(1))
        // No close, no flush: the process dies here. A new process opens the same directory.
        let second = CrumbLog(directory: directory)
        XCTAssertEqual(second.lines(), ["2026-11-25T05:00:00.000Z launch 8", "2026-11-25T05:00:01.000Z dayLoad 812ms ok"])
    }

    func testTheFileIsOnDiskAfterEachAddNotOnlyInMemory() {
        let log = CrumbLog(directory: directory)
        log.add(.memoryWarning, at: B8.date(0))
        XCTAssertEqual(diskLines(), ["2026-11-25T05:00:00.000Z memoryWarning"])
        log.add(.background, at: B8.date(1))
        XCTAssertEqual(diskLines().count, 2)
    }

    func testRotateReturnsThePreviousSessionAndStartsAFreshFile() {
        let session1 = CrumbLog(directory: directory)
        session1.add(.launch(build: 7), at: B8.date(0))
        session1.add(.tab(.dates), at: B8.date(1))

        let session2 = CrumbLog(directory: directory)
        XCTAssertEqual(session2.rotate(), ["2026-11-25T05:00:00.000Z launch 7", "2026-11-25T05:00:01.000Z tab dates"])
        XCTAssertEqual(session2.lines(), [], "the new session starts empty")
        session2.add(.launch(build: 8), at: B8.date(100))
        XCTAssertEqual(session2.lines(), ["2026-11-25T05:01:40.000Z launch 8"])

        // A third process sees only the new session's lines, not the old ones.
        let session3 = CrumbLog(directory: directory)
        XCTAssertEqual(session3.lines(), ["2026-11-25T05:01:40.000Z launch 8"])
        XCTAssertEqual(session3.rotate(), ["2026-11-25T05:01:40.000Z launch 8"])
        XCTAssertEqual(session3.rotate(), [])
    }

    func testOnlyTheNewestLimitLinesAreReturned() {
        let log = CrumbLog(directory: directory, limit: 10)
        dayLoads(log, 0..<35)
        XCTAssertEqual(ms(log.lines()), Array(25..<35))
        XCTAssertEqual(ms(CrumbLog(directory: directory, limit: 10).lines()), Array(25..<35), "a new instance agrees")
    }

    func testTheFileIsTrimmedSoItNeverGrowsPastTwiceTheLimit() {
        let log = CrumbLog(directory: directory, limit: 10)
        for n in 0..<500 {
            log.add(.dayLoad(ms: n, ok: true), at: B8.date(Double(n) / 1000))
            XCTAssertLessThanOrEqual(diskLines().count, 20, "after add \(n)")
        }
        XCTAssertGreaterThanOrEqual(diskLines().count, 10)
        XCTAssertEqual(ms(log.lines()), Array(490..<500))
    }

    func testDefaultLimitIs150() {
        let log = CrumbLog(directory: directory)
        dayLoads(log, 0..<400)
        XCTAssertEqual(ms(log.lines()), Array(250..<400))
        XCTAssertLessThanOrEqual(diskLines().count, 300)
    }

    func testALimitOfOneKeepsTheLastLine() {
        let log = CrumbLog(directory: directory, limit: 1)
        dayLoads(log, 0..<7)
        XCTAssertEqual(ms(log.lines()), [6])
        XCTAssertLessThanOrEqual(diskLines().count, 2)
    }

    func testCreatesMissingDirectories() {
        let nested = directory.appendingPathComponent("a/b/c", isDirectory: true)
        let log = CrumbLog(directory: nested)
        log.add(.active, at: B8.date(0))
        XCTAssertEqual(log.lines(), ["2026-11-25T05:00:00.000Z active"])
        XCTAssertEqual(CrumbLog(directory: nested).lines(), ["2026-11-25T05:00:00.000Z active"])
    }

    func testManyThreadsLoseNothingAndTearNothing() {
        let log = CrumbLog(directory: directory, limit: 10_000)
        let threads = 8, each = 250
        DispatchQueue.concurrentPerform(iterations: threads) { thread in
            for n in 0..<each {
                log.add(.dayLoad(ms: thread * 1000 + n, ok: true), at: B8.date(0))
                if n % 50 == 0 { _ = log.lines() }
            }
        }
        let lines = log.lines()
        XCTAssertEqual(lines.count, threads * each)
        XCTAssertEqual(Set(ms(lines)), Set((0..<threads).flatMap { t in (0..<each).map { t * 1000 + $0 } }))
        for line in lines {
            XCTAssertEqual(line.split(separator: " ").count, 4, "torn line: \(line)")
            XCTAssertTrue(line.hasPrefix("2026-11-25T05:00:00.000Z dayLoad "), line)
        }
        XCTAssertEqual(CrumbLog(directory: directory, limit: 10_000).lines().count, threads * each)
    }

    func testRotateWhileOtherThreadsAddNeitherLosesNorDuplicates() {
        let log = CrumbLog(directory: directory, limit: 10_000)
        let collected = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 4) { thread in
            if thread == 0 {
                for _ in 0..<20 {
                    let got = log.rotate()
                    lock.lock(); collected.addObjects(from: got); lock.unlock()
                }
            } else {
                for n in 0..<200 { log.add(.dayLoad(ms: thread * 1000 + n, ok: true), at: B8.date(0)) }
            }
        }
        let all = (collected as! [String]) + log.rotate()
        XCTAssertEqual(all.count, 600, "every add comes out of exactly one rotate")
        XCTAssertEqual(Set(all).count, 600)
    }

    func testWriteFailuresAreHarmless() throws {
        // The directory path is an existing regular file, so nothing can be created or appended under it.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let log = CrumbLog(directory: blocker)
        for n in 0..<20 { log.add(.dayLoad(ms: n, ok: true), at: B8.date(0)) }
        _ = log.lines()
        _ = log.rotate()
        XCTAssertEqual(try Data(contentsOf: blocker), Data("x".utf8), "an unrelated file is left alone")
    }

    func testReadOnlyDirectoryIsHarmless() throws {
        let readOnly = directory.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let log = CrumbLog(directory: readOnly)
        log.add(.launch(build: 8), at: B8.date(0))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        for n in 0..<20 { log.add(.dayLoad(ms: n, ok: true), at: B8.date(0)) }
        _ = log.lines()
        _ = log.rotate()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
        // And it works again once the directory is writable.
        let again = CrumbLog(directory: readOnly)
        again.add(.active, at: B8.date(5))
        XCTAssertTrue(again.lines().contains("2026-11-25T05:00:05.000Z active"), "\(again.lines())")
    }

    func testAddingIsCheap() {
        let log = CrumbLog(directory: directory)
        let started = Date()
        for n in 0..<3000 { log.add(.request(route: "/api/view", status: 200, ms: n), at: B8.date(Double(n))) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "3,000 adds must append, not rewrite the file each time")
    }

    func testTwoLogsOnDifferentDirectoriesDoNotMix() throws {
        let other = try B8.tempDirectory("crumblog-other")
        defer { B8.remove(other) }
        let a = CrumbLog(directory: directory), b = CrumbLog(directory: other)
        a.add(.active, at: B8.date(0))
        b.add(.background, at: B8.date(0))
        XCTAssertEqual(a.lines(), ["2026-11-25T05:00:00.000Z active"])
        XCTAssertEqual(b.lines(), ["2026-11-25T05:00:00.000Z background"])
    }

    func testLogIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        _ = requireSendable(CrumbLog(directory: directory))
        _ = requireSendable(Crumb.active)
    }
}
