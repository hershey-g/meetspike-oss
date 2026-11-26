import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 regression: an `OverrideOutbox.Item` read back from disk must equal the item that was enqueued.
//
// Bug found in the simulator: the outbox stores `queuedAt` as `timeIntervalSince1970`, while `Date` keeps
// `timeIntervalSinceReferenceDate`. Converting there and back can move a Date by an ulp, so `remove(item)` (which
// compares the stored item with the one it was given) never matched, and a sent edit stayed in the queue and was
// sent again.
//
// Spec: for any Date, after `enqueue(eventID:edit:at: d)`, `pending().first == Item(eventID:edit:queuedAt: d)`,
// and `remove` of that item empties the outbox. Removing an older item must still not remove a newer edit for the
// same event and scope queued a few milliseconds later.

/// A small seeded generator (SplitMix64), so a failure reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class Build9OutboxIdentityTests: XCTestCase {
    private let edit = OverrideEdit(scope: .event, state: .set(.notJoined))

    private func make(_ name: String) throws -> OverrideOutbox {
        let directory = try B9.tempDirectory(self, name).appendingPathComponent("queue", isDirectory: true)
        return OverrideOutbox(directory: directory)
    }

    /// Dates within three days of 2026-11-25T14:00Z with arbitrary sub-microsecond fractions.
    private func randomDates(_ count: Int, seed: UInt64) -> [Date] {
        var generator = SeededGenerator(seed: seed)
        let center = B9.base.timeIntervalSinceReferenceDate
        return (0..<count).map { _ in
            let offset = Double.random(in: -259_200...259_200, using: &generator)
            return Date(timeIntervalSinceReferenceDate: center + offset)
        }
    }

    func testAQueuedDateComesBackBitForBitAndRemovingItEmptiesTheOutbox() throws {
        let outbox = try make("identity")
        var notEqual: [Date] = []
        var notEmptied: [Date] = []
        for date in randomDates(2_000, seed: 20_261_125) {
            XCTAssertTrue(outbox.enqueue(eventID: "ev1", edit: edit, at: date))
            let expected = OverrideOutbox.Item(eventID: "ev1", edit: edit, queuedAt: date)
            let first = outbox.pending().first
            if first != expected { notEqual.append(date) }
            if let first { outbox.remove(first) }
            if !outbox.pending().isEmpty {
                notEmptied.append(date)
                // Clean up so the next round starts empty.
                try? FileManager.default.removeItem(at: outbox.directory)
            }
        }
        XCTAssertEqual(notEqual.count, 0,
                       "\(notEqual.count) of 2000 dates changed on disk, first: \(String(describing: notEqual.first?.timeIntervalSinceReferenceDate))")
        XCTAssertEqual(notEmptied.count, 0, "\(notEmptied.count) of 2000 sent edits were still queued after remove")
    }

    func testRemovingTheExpectedItemEmptiesTheOutboxForEveryDate() throws {
        // The same, but removing the Item built from the original Date (what a sender that kept the date would do).
        let outbox = try make("expected")
        var notEmptied = 0
        for date in randomDates(2_000, seed: 3) {
            outbox.enqueue(eventID: "ev1", edit: edit, at: date)
            outbox.remove(OverrideOutbox.Item(eventID: "ev1", edit: edit, queuedAt: date))
            if !outbox.pending().isEmpty {
                notEmptied += 1
                try? FileManager.default.removeItem(at: outbox.directory)
            }
        }
        XCTAssertEqual(notEmptied, 0, "\(notEmptied) of 2000 edits were still queued after remove")
    }

    func testTheSameHoldsAcrossARelaunch() throws {
        let outbox = try make("relaunch")
        var mismatches = 0
        for date in randomDates(500, seed: 7) {
            outbox.enqueue(eventID: "ev1", edit: edit, at: date)
            let relaunched = OverrideOutbox(directory: outbox.directory)
            if relaunched.pending() != [OverrideOutbox.Item(eventID: "ev1", edit: edit, queuedAt: date)] { mismatches += 1 }
            try? FileManager.default.removeItem(at: outbox.directory)
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches) of 500 dates were not equal after a relaunch")
    }

    func testRemovingTheOldItemKeepsANewerEditQueuedAFewMillisecondsLater() throws {
        let outbox = try make("newer")
        let newer = OverrideEdit(scope: .event, state: .set(.linked))
        var generator = SeededGenerator(seed: 99)
        var erased = 0
        var notQueued = 0
        for date in randomDates(500, seed: 11) {
            outbox.enqueue(eventID: "ev1", edit: edit, at: date)
            guard let inFlight = outbox.pending().first else { notQueued += 1; continue }
            let later = date.addingTimeInterval(Double.random(in: 0.001...0.005, using: &generator))
            outbox.enqueue(eventID: "ev1", edit: newer, at: later)
            outbox.remove(inFlight)
            if outbox.pending() != [OverrideOutbox.Item(eventID: "ev1", edit: newer, queuedAt: later)] { erased += 1 }
            try? FileManager.default.removeItem(at: outbox.directory)
        }
        XCTAssertEqual(notQueued, 0)
        XCTAssertEqual(erased, 0, "\(erased) of 500 newer edits were lost or changed when an older one was removed")
    }

    func testTheOlderItemIsNotRemovedWhenTheNewerOneIsOneMillisecondLater() throws {
        // Tolerance edge a fix must respect: one millisecond apart is a different edit.
        let outbox = try make("one-ms")
        let base = B9.at(0.123_456_789)
        outbox.enqueue(eventID: "ev1", edit: edit, at: base)
        let inFlight = try XCTUnwrap(outbox.pending().first)
        let newer = OverrideEdit(scope: .event, state: .set(.unlinked))
        let later = base.addingTimeInterval(0.001)
        outbox.enqueue(eventID: "ev1", edit: newer, at: later)
        outbox.remove(inFlight)
        XCTAssertEqual(outbox.pending(), [OverrideOutbox.Item(eventID: "ev1", edit: newer, queuedAt: later)])
    }

    // MARK: The times inside an edit (found on screen)
    //
    // `OverrideEdit` carries Dates too (startUtc / endUtc). The PUT body keeps its ISO text, but an edit that goes
    // through JSON (the outbox file) must come back equal to itself, or `Item` equality fails the same way.

    /// "Now" values with arbitrary sub-microsecond fractions, inside a meeting that runs B9.at(0) to B9.at(3600).
    private func randomNows(_ count: Int, seed: UInt64) -> [Date] {
        var generator = SeededGenerator(seed: seed)
        let center = B9.at(0).timeIntervalSinceReferenceDate
        return (0..<count).map { _ in
            Date(timeIntervalSinceReferenceDate: center + Double.random(in: 600...4_000, using: &generator))
        }
    }

    private var target: LiveAdjustTarget {
        LiveAdjustTarget(meetingID: "ev1", title: "Standup", start: B9.at(0), end: B9.at(3600), calendarEnd: B9.at(3600))
    }

    func testAnEditEqualsItselfAfterJSONForEveryDate() throws {
        var endOnly: [Date] = []
        var both: [Date] = []
        for date in randomNows(1_000, seed: 41) {
            let single = OverrideEdit(scope: .event, endUtc: .set(date))
            if try JSONDecoder().decode(OverrideEdit.self, from: JSONEncoder().encode(single)) != single { endOnly.append(date) }
            let pair = OverrideEdit(scope: .event, startUtc: .set(date.addingTimeInterval(-1_234.567_891)), endUtc: .set(date))
            if try JSONDecoder().decode(OverrideEdit.self, from: JSONEncoder().encode(pair)) != pair { both.append(date) }
        }
        XCTAssertEqual(endOnly.count, 0, "\(endOnly.count) of 1000 end-only edits changed through JSON, first: \(String(describing: endOnly.first?.timeIntervalSinceReferenceDate))")
        XCTAssertEqual(both.count, 0, "\(both.count) of 1000 start+end edits changed through JSON")
    }

    private func liveEdits(_ now: Date) throws -> [(String, OverrideEdit)] {
        [("stillGoing", try XCTUnwrap(LiveAdjust.stillGoing(target, now: now))),
         ("endedNow", try XCTUnwrap(LiveAdjust.endedNow(target, now: now)))]
    }

    func testLiveAdjustEditsQueueAndComeBackEqualAndRemovable() throws {
        let outbox = try make("live")
        var notEqual: [String] = []
        var notEmptied: [String] = []
        for now in randomNows(1_000, seed: 52) {
            for (name, edit) in try liveEdits(now) {
                XCTAssertTrue(outbox.enqueue(eventID: "ev1", edit: edit, at: now))
                let expected = OverrideOutbox.Item(eventID: "ev1", edit: edit, queuedAt: now)
                let first = outbox.pending().first
                if first != expected { notEqual.append(name) }
                if let first { outbox.remove(first) }
                if !outbox.pending().isEmpty {
                    notEmptied.append(name)
                    try? FileManager.default.removeItem(at: outbox.directory)
                }
            }
        }
        XCTAssertEqual(notEqual.count, 0, "\(notEqual.count) of 2000 live edits were not equal to what was queued")
        XCTAssertEqual(notEmptied.count, 0, "\(notEmptied.count) of 2000 live edits were still queued after remove")
    }

    func testLiveAdjustEditsAreEqualAndRemovableAfterARelaunch() throws {
        let outbox = try make("live-relaunch")
        var notEqual = 0
        var notEmptied = 0
        for now in randomNows(1_000, seed: 63) {
            for (_, edit) in try liveEdits(now) {
                outbox.enqueue(eventID: "ev1", edit: edit, at: now)
                let relaunched = OverrideOutbox(directory: outbox.directory)
                let expected = OverrideOutbox.Item(eventID: "ev1", edit: edit, queuedAt: now)
                let first = relaunched.pending().first
                if first != expected { notEqual += 1 }
                if let first { relaunched.remove(first) }
                if !OverrideOutbox(directory: outbox.directory).pending().isEmpty {
                    notEmptied += 1
                    try? FileManager.default.removeItem(at: outbox.directory)
                }
            }
        }
        XCTAssertEqual(notEqual, 0, "\(notEqual) of 2000 live edits were not equal after a relaunch")
        XCTAssertEqual(notEmptied, 0, "\(notEmptied) of 2000 live edits were still queued after a relaunch and remove")
    }
}
