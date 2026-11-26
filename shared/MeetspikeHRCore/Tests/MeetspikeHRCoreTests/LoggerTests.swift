import CSQLite
import Foundation
import XCTest
@testable import MeetspikeHRCore

final class LoggerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testHeartRateMeasurement() {
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0, 72])), 72)
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([1, 0x2C, 0x01])), 300)
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0, 80, 0xCC])), 80)
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([1, 0x2C, 0x01, 0xCC])), 300)
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x08, 80, 0, 0, 0xCC])), 80)
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x1F, 92, 0, 0, 0, 0, 4, 0, 4])), 92)
        let malformed: [[UInt8]] = [[], [0], [1, 80], [0x08, 80, 2], [0x10, 80], [0x10, 80, 2], [0x04, 80]]
        for bytes in malformed {
            XCTAssertNil(HeartRateMeasurement.bpm(from: Data(bytes)))
        }
    }

    func testAllFiveMinutesOfPerSecondReadingsPersistAndMatchWirePoints() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReadingStore(directory: directory)
        let expected = (0..<300).map { HeartRatePoint(timeMs: date($0).unixMilliseconds, bpm: 61 + $0 % 53) }
        for (index, point) in expected.enumerated() {
            try await store.record(bpm: point.bpm, at: date(index))
        }

        let reopened = ReadingStore(directory: directory)
        let batch = try await pendingBatch(reopened, now: date(300))
        let payload = try decode(batch)
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.source, "ble")
        XCTAssertEqual(payload.fetchedAt, date(300))
        XCTAssertEqual(payload.hr.points, expected)
        XCTAssertTrue(payload.hr.spans.isEmpty)
        XCTAssertEqual(batch.pending.count, expected.count)
    }

    func testMonthsOldBacklogUploadsOldestFirstInBoundedBatches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReadingStore(directory: directory)
        let now = date(90 * 86_400)
        let limit = UploadBatch.maxPoints
        try await store.prune(now: base)
        try seedRows(directory: directory, count: limit * 2 + 1, firstMs: base.unixMilliseconds, spacingMs: 1_000)
        try await store.record(bpm: 82, at: now)
        try await store.record(bpm: 83, at: now.addingTimeInterval(1))
        try await store.prune(now: now)

        let first = try await pendingBatch(store, now: now)
        let firstPayload = try decode(first)
        XCTAssertEqual(firstPayload.fetchedAt, now)
        XCTAssertEqual(firstPayload.hr.points, (0..<limit).map { .init(bpm: 65 + $0 % 40, at: date($0)) })
        try await store.acknowledge(first, httpStatus: 200, at: now)

        let reopened = ReadingStore(directory: directory)
        let second = try await pendingBatch(reopened, now: now)
        XCTAssertEqual(try decode(second).hr.points.map(\.timeMs), (limit..<limit * 2).map { date($0).unixMilliseconds })
        try await reopened.acknowledge(second, httpStatus: 200, at: now)

        let last = try await pendingBatch(reopened, now: now)
        XCTAssertEqual(try decode(last).hr.points.map(\.timeMs), [date(limit * 2).unixMilliseconds, now.unixMilliseconds])
        try await reopened.acknowledge(last, httpStatus: 200, at: now)
        let drained = try await reopened.prepare(through: now)
        XCTAssertNil(drained)
    }

    func testFailuresAndNewRevisionsStayPendingAcrossRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReadingStore(directory: directory)
        try await store.record(bpm: 75, at: date(0))
        try await store.record(bpm: 76, at: date(1))
        try await store.record(bpm: 77, at: date(2))
        let sent = try await pendingBatch(store, now: date(3))
        for status in [401, 202, 429, 500] {
            try await store.acknowledge(sent, httpStatus: status)
        }
        let afterFailure = try await pendingBatch(store, now: date(3))
        XCTAssertEqual(afterFailure.pending.count, 3)

        try await store.record(bpm: 88, at: date(1)) // A revised timestamp while the request is in flight.
        try await store.record(bpm: 89, at: date(3)) // A new reading within the snapshot's time range.
        try await store.acknowledge(sent, httpStatus: 200)

        let reopened = ReadingStore(directory: directory)
        let retry = try await pendingBatch(reopened, now: date(4))
        XCTAssertEqual(retry.pending.map(\.timeMs), [1, 3].map { date($0).unixMilliseconds })
        XCTAssertEqual(try decode(retry).hr.points.map(\.bpm), [88, 89])
        try await reopened.acknowledge(retry, httpStatus: 200)

        let afterSuccess = try await reopened.prepare(through: date(5))
        XCTAssertNil(afterSuccess)
    }

    func testOldReceiptsAreReplayedOnceAndPrunedThirtyDaysAfterRawAcknowledgement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try executeFixture("""
            CREATE TABLE samples (time_ms INTEGER PRIMARY KEY, bpm INTEGER NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1, acknowledged_revision INTEGER NOT NULL DEFAULT 0);
            INSERT INTO samples VALUES (\(date(0).unixMilliseconds), 72, 1, 1);
            """, directory: directory)
        let store = ReadingStore(directory: directory)
        let ackTime = date(45 * 86_400)
        try await store.prune(now: ackTime)
        let old = try await pendingBatch(store, now: ackTime)
        XCTAssertEqual(try decode(old).hr.points, [.init(bpm: 72, at: date(0))])
        try await store.acknowledge(old, httpStatus: 200, at: ackTime)

        let reopened = ReadingStore(directory: directory)
        try await reopened.record(bpm: 73, at: date(1))
        let pending = try await pendingBatch(reopened, now: ackTime)
        XCTAssertEqual(try decode(pending).hr.points, [.init(bpm: 73, at: date(1))])
        try await reopened.prune(now: date(74 * 86_400))
        let retained = try await reopened.readings(from: base, through: ackTime)
        XCTAssertEqual(retained.map(\.bpm), [72, 73])
        try await reopened.prune(now: date(76 * 86_400))
        let afterPrune = try await reopened.readings(from: base, through: ackTime)
        XCTAssertEqual(afterPrune.map(\.bpm), [73])
    }

    func testStrapMatchUsesPairedIdentifierOrWhoopName() {
        let paired = UUID()
        let other = UUID()
        XCTAssertTrue(StrapMatch.accepts(id: paired, names: [], preferredID: paired))
        XCTAssertFalse(StrapMatch.accepts(id: other, names: ["WHOOP 4C1234"], preferredID: paired))
        XCTAssertTrue(StrapMatch.accepts(id: other, names: ["Polar H10", "whoop 4C1234"], preferredID: nil))
        XCTAssertFalse(StrapMatch.accepts(id: other, names: ["Polar H10"], preferredID: nil))
        XCTAssertFalse(StrapMatch.accepts(id: other, names: [], preferredID: nil))
    }

    func testPriorFormatImportsAvailableObservationsAsPending() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try executeFixture("""
            CREATE TABLE readings (first_ms, first_bpm, last_ms, last_bpm);
            INSERT INTO readings VALUES (\(date(0).unixMilliseconds), 73, \(date(59).unixMilliseconds), 81);
            """, directory: directory)

        let store = ReadingStore(directory: directory)
        let batch = try await pendingBatch(store, now: date(60))
        XCTAssertEqual(try decode(batch).hr.points.map(\.bpm), [73, 81])
        XCTAssertEqual(batch.pending.count, 2)
    }

    func testReadingAgeMarksDisconnectAndTimeout() {
        XCTAssertFalse(ReadingAge(readAt: base, now: date(44), connected: true).isStale)
        XCTAssertTrue(ReadingAge(readAt: base, now: date(45), connected: true).isStale)
        let disconnected = ReadingAge(readAt: base, now: date(1), connected: false)
        XCTAssertTrue(disconnected.isStale)
        XCTAssertEqual(disconnected.seconds, 1)
        XCTAssertEqual(ReadingAge(readAt: base, now: date(-1), connected: true).seconds, 0)
    }

    func testFullUploadsEveryThirtyMinutesAndBackoffResetsAfterSuccess() {
        var schedule = UploadSchedule(now: base)
        XCTAssertEqual(schedule.nextAttempt, date(300))
        for seconds in [300, 600, 1_200, 2_400, 3_600, 3_600] {
            schedule.complete(success: false, now: base)
            XCTAssertEqual(schedule.nextAttempt, date(seconds))
        }
        schedule.complete(success: true, now: base)
        XCTAssertEqual(schedule.nextAttempt, date(1_800))
        schedule.complete(success: true, now: date(1_800))
        XCTAssertEqual(schedule.nextAttempt, date(3_600))
        schedule.complete(success: false, now: date(3_600))
        XCTAssertEqual(schedule.nextAttempt, date(3_900))
    }

    private func date(_ seconds: Int) -> Date { base.addingTimeInterval(Double(seconds)) }

    private func decode(_ batch: UploadBatch) throws -> IngestPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IngestPayload.self, from: batch.body)
    }

    private func pendingBatch(_ store: ReadingStore, now: Date) async throws -> UploadBatch {
        let batch = try await store.prepare(through: now, fetchedAt: now)
        return try XCTUnwrap(batch)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func seedRows(directory: URL, count: Int, firstMs: Int64, spacingMs: Int) throws {
        try executeFixture("""
            WITH RECURSIVE fixture(n) AS (
                SELECT 0 UNION ALL SELECT n + 1 FROM fixture WHERE n + 1 < \(count)
            )
            INSERT INTO samples (time_ms, bpm)
            SELECT \(firstMs) + n * \(spacingMs), 65 + n % 40 FROM fixture;
            """, directory: directory)
    }

    private func executeFixture(_ sql: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open(directory.appendingPathComponent("readings.sqlite3").path, &handle)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(status, SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }
}
