import Foundation
import XCTest
@testable import MeetspikeHRCore

final class ActivityTickerTests: XCTestCase {
    @MainActor
    func testBufferedUploadRetriesWithoutAnotherBluetoothReading() async throws {
        var queue = LiveUploadQueue()
        let point = HeartRatePoint(bpm: 74, at: .now)
        queue.record(point)
        var attempts = 0
        let retried = expectation(description: "Buffered upload retried after a simulated failure and disconnect")
        let ticker = ActivityTicker(interval: .milliseconds(10)) {
            let batch = queue.batch(now: .now)
            guard !batch.isEmpty else { return }
            attempts += 1
            // First request fails. No more Bluetooth readings arrive.
            if attempts == 2 {
                XCTAssertEqual(batch, [point])
                queue.acknowledge(batch)
                retried.fulfill()
            }
        }
        ticker.setRunning(true)
        ticker.setRunning(true) // Repeated activity refreshes must not create another loop.
        await fulfillment(of: [retried], timeout: 3)
        ticker.setRunning(false)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(queue.batch(now: .now).isEmpty)
    }

    @MainActor
    func testBackgroundOrListeningCutoffCancelsAndCanRestart() async throws {
        var ticks = 0
        let first = expectation(description: "First active tick")
        let resumed = expectation(description: "Resumed foreground tick")
        var restarting = false
        let ticker = ActivityTicker(interval: .milliseconds(20)) {
            ticks += 1
            if ticks == 1 { first.fulfill() }
            if restarting { restarting = false; resumed.fulfill() }
        }
        ticker.setRunning(true)
        await fulfillment(of: [first], timeout: 3)
        ticker.setRunning(false)
        let stoppedAt = ticks
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(ticks, stoppedAt)
        restarting = true
        ticker.setRunning(true)
        await fulfillment(of: [resumed], timeout: 3)
        ticker.setRunning(false)
    }
}
