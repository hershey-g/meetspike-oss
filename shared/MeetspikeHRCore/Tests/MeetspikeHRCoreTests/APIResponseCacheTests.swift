import Foundation
import XCTest
@testable import MeetspikeHRCore

final class APIResponseCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripKeepsBodyAndSavedAtTime() async throws {
        let saved = Date(timeIntervalSince1970: 1_795_000_000)
        let cache = ResponseCache(directory: directory, now: { saved })
        let request = APIRequest.view(date: "2026-11-24")
        let body = try APIFixture.data("view-day.json")
        let nothing = await cache.readData(for: request)
        XCTAssertNil(nothing)
        try await cache.write(body, for: request)

        let hit = await cache.readData(for: request)
        XCTAssertEqual(hit?.body, body)
        XCTAssertEqual(hit?.savedAt, saved)
        let decoded = await cache.read(ViewResponse.self, for: request)
        XCTAssertEqual(decoded?.value.today, "2026-11-24")
        XCTAssertEqual(decoded?.savedAt, saved)
    }

    func testDifferentRequestsDoNotCollideAndQueryOrderDoesNotMatter() async throws {
        let cache = ResponseCache(directory: directory)
        let a = APIRequest.view(date: "2026-11-24")
        let b = APIRequest.view(date: "2026-11-23")
        try await cache.write(Data("{\"a\":1}".utf8), for: a)
        try await cache.write(Data("{\"b\":2}".utf8), for: b)
        let readA = await cache.readData(for: a)
        let readB = await cache.readData(for: b)
        XCTAssertEqual(readA?.body, Data("{\"a\":1}".utf8))
        XCTAssertEqual(readB?.body, Data("{\"b\":2}".utf8))

        let one = APIRequest(path: "/api/x", query: [.init(name: "a", value: "1"), .init(name: "b", value: "2")])
        let two = APIRequest(path: "/api/x", query: [.init(name: "b", value: "2"), .init(name: "a", value: "1")])
        XCTAssertEqual(one.cacheKey, two.cacheKey)
    }

    func testNewerAnswerReplacesOlder() async throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 100))
        let cache = ResponseCache(directory: directory, now: { clock.now })
        let request = APIRequest.askStatus
        try await cache.write(Data("{\"connected\":false}".utf8), for: request)
        clock.now = Date(timeIntervalSince1970: 200)
        try await cache.write(Data("{\"connected\":true}".utf8), for: request)
        let hit = await cache.read(AskStatus.self, for: request)
        XCTAssertEqual(hit?.value.connected, true)
        XCTAssertEqual(hit?.savedAt, Date(timeIntervalSince1970: 200))
    }

    func testCorruptOrUndecodableFilesReadAsNothing() async throws {
        let cache = ResponseCache(directory: directory)
        let request = APIRequest.view(date: "2026-11-24")
        try await cache.write(Data("not json at all".utf8), for: request)
        let raw = await cache.readData(for: request)
        XCTAssertNotNil(raw, "the raw bytes were stored as given")
        let decoded = await cache.read(ViewResponse.self, for: request)
        XCTAssertNil(decoded, "bytes that no longer decode are not served")

        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try Data("garbage".utf8).write(to: file)
        }
        let afterGarbage = await cache.readData(for: request)
        XCTAssertNil(afterGarbage)
    }

    func testClearForgetsEverything() async throws {
        let cache = ResponseCache(directory: directory)
        let request = APIRequest.view(date: "2026-11-24")
        try await cache.write(Data("{}".utf8), for: request)
        await cache.clear()
        let hit = await cache.readData(for: request)
        XCTAssertNil(hit)
        // And it still works afterwards.
        try await cache.write(Data("{}".utf8), for: request)
        let again = await cache.readData(for: request)
        XCTAssertNotNil(again)
    }

    func testOldestEntriesArePrunedPastTheLimit() async throws {
        let cache = ResponseCache(directory: directory, maxEntries: 3)
        for index in 0..<6 {
            try await cache.write(Data("{\"i\":\(index)}".utf8), for: .view(date: "2026-11-0\(index + 1)"))
            // File times have limited resolution; keep the order clear.
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        let oldest = await cache.readData(for: .view(date: "2026-11-01"))
        let newest = await cache.readData(for: .view(date: "2026-11-06"))
        XCTAssertNil(oldest)
        XCTAssertNotNil(newest)
    }

    func testFailedWritesAreCountedNotHidden() async throws {
        // A file where the folder should be makes every write fail.
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let cache = ResponseCache(directory: blocker)
        do {
            try await cache.write(Data("{}".utf8), for: .askStatus)
            XCTFail("the write should fail")
        } catch {}
        let failures = await cache.writeFailures
        XCTAssertEqual(failures, 1)
    }

    func testStandardCacheFoldersAreSeparatePerOrigin() async throws {
        let a = ResponseCache.standard(origin: URL(string: "https://a.example.com")!)
        let b = ResponseCache.standard(origin: URL(string: "https://b.example.com")!)
        let request = APIRequest.askStatus
        try await a.write(Data("{\"ok\":true}".utf8), for: request)
        let fromA = await a.readData(for: request)
        let fromB = await b.readData(for: request)
        XCTAssertNotNil(fromA)
        XCTAssertNil(fromB)
        await a.clear()
    }
}

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
