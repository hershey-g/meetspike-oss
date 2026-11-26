import XCTest
@testable import MeetspikeHRCore

final class HeartbeatTests: XCTestCase {
    func testPeriodFollowsBPMAndClamps() {
        XCTAssertEqual(Heartbeat.period(bpm: 60), 1, accuracy: 1e-9)
        XCTAssertEqual(Heartbeat.period(bpm: 120), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Heartbeat.period(bpm: 0), 2, accuracy: 1e-9)
        XCTAssertEqual(Heartbeat.period(bpm: 400), 60.0 / 220, accuracy: 1e-9)
    }

    func testOneFullBeatPerPeriod() {
        for bpm in [45, 72, 150] {
            let period = Heartbeat.period(bpm: bpm)
            let samples = stride(from: 0.0, to: period * 3, by: 0.002).map { Heartbeat.intensity(bpm: bpm, at: $0) }
            // Count rising crossings of 0.9: only the main pulse reaches it.
            var beats = 0
            for (a, b) in zip(samples, samples.dropFirst()) where a < 0.9 && b >= 0.9 { beats += 1 }
            XCTAssertEqual(beats, 3, "bpm \(bpm)")
        }
    }

    func testRestsBetweenBeatsAndStaysInRange() {
        XCTAssertEqual(Heartbeat.intensity(bpm: 60, at: 0.6), 0)
        XCTAssertGreaterThan(Heartbeat.intensity(bpm: 60, at: 0.05), 0.99)
        XCTAssertGreaterThan(Heartbeat.intensity(bpm: 60, at: 0.22), 0.5)
        for t in stride(from: -2.0, to: 2.0, by: 0.013) {
            let value = Heartbeat.intensity(bpm: 90, at: t)
            XCTAssert((0...1).contains(value))
        }
    }

    func testNextBeat() {
        XCTAssertEqual(Heartbeat.nextBeat(bpm: 60, after: 10.2), 11, accuracy: 1e-9)
        XCTAssertEqual(Heartbeat.nextBeat(bpm: 120, after: 10.2), 10.5, accuracy: 1e-9)
    }
}
