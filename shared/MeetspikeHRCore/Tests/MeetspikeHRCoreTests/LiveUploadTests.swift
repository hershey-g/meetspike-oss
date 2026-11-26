import Foundation
import XCTest
@testable import MeetspikeHRCore

final class LiveUploadTests: XCTestCase {
    func testRetryAndReceiptsPreserveReadingsCapturedDuringUpload() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = LiveUploadQueue()
        queue.record(HeartRatePoint(bpm: 65, at: now.addingTimeInterval(-901)))
        for offset in 0..<62 {
            queue.record(HeartRatePoint(bpm: 70, at: now.addingTimeInterval(Double(offset - 62))))
        }
        let sent = queue.batch(now: now)
        XCTAssertEqual(sent.count, 60)
        XCTAssertEqual(sent.first?.time, now.addingTimeInterval(-62))
        XCTAssertEqual(queue.batch(now: now.addingTimeInterval(5)), sent)

        let corrected = HeartRatePoint(bpm: 82, at: now.addingTimeInterval(-62))
        queue.record(corrected)
        queue.record(HeartRatePoint(bpm: 90, at: now))
        queue.acknowledge(sent)
        let next = queue.batch(now: now)
        XCTAssertEqual(next.first, corrected)
        XCTAssertEqual(next.count, 4)
        XCTAssertEqual(next.last?.bpm, 90)
    }

    func testBatchDrainsMoreThanTwoRequestsInOrderWithoutSendingExpiredPoints() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let edge = HeartRatePoint(bpm: 75, at: now.addingTimeInterval(-900))
        let expected = [edge] + (0..<125).map { second in
            HeartRatePoint(bpm: 75, at: now.addingTimeInterval(Double(second - 125)))
        }
        var queue = LiveUploadQueue()
        expected.reversed().forEach { queue.record($0) }
        queue.record(HeartRatePoint(bpm: 75, at: edge.time.addingTimeInterval(-1)))

        var sent: [HeartRatePoint] = []
        for limit in [60, 60, 6] {
            let batch = queue.batch(now: now)
            XCTAssertEqual(batch.count, limit)
            XCTAssertEqual(queue.batch(now: now), batch)
            sent.append(contentsOf: batch)
            queue.acknowledge(batch)
        }
        XCTAssertEqual(sent, expected)
        XCTAssertTrue(queue.batch(now: now).isEmpty)
    }

    func testLiveWireFormatAndExplicitEmptyMeeting() throws {
        let point = HeartRatePoint(timeMs: 1_800_000_000_000, bpm: 82)
        let data = try JSONEncoder().encode(LiveUploadPayload(points: [point], includeMeeting: true))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["points"] as? [[Int64]], [[1_800_000_000_000, 82]])
        XCTAssertEqual(body["version"] as? Int, 1)
        XCTAssertEqual(body["includeMeeting"] as? Bool, true)

        let decoder = JSONDecoder()
        let omitted = try decoder.decode(LiveUploadResponse.self, from: Data(#"{"ok":true}"#.utf8))
        let empty = try decoder.decode(LiveUploadResponse.self, from: Data(#"{"ok":true,"meeting":null}"#.utf8))
        XCTAssertFalse(omitted.hasMeeting)
        XCTAssertTrue(empty.hasMeeting)
        XCTAssertNil(empty.meeting)
    }
}
