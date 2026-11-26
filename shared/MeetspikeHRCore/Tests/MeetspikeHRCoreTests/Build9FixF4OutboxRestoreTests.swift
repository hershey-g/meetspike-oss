import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 fix pass, F4: a refused edit leaves the earlier pending edit as it was.
//
// NEW API (names fixed here), on `OverrideOutbox`:
//
//   @discardableResult
//   public func enqueueReplacing(eventID: String, edit: OverrideEdit, at: Date) -> (saved: Bool, replaced: OverrideOutbox.Item?)
//       Same as `enqueue` (including the F3 merge) and also answers the item that was stored for this event and scope
//       just before, exactly as `pending()` showed it (nil when there was none). `saved` is `enqueue`'s answer.
//   public func restore(_ replaced: OverrideOutbox.Item?, insteadOf: OverrideOutbox.Item)
//       Puts `replaced` back (its edit and its own `queuedAt`) in place of the entry for `insteadOf`'s event and scope,
//       or removes that entry when `replaced` is nil. It only acts while the stored entry is still `insteadOf`, matched
//       by event id, scope and queuedAt (`isSameEntry`), so something queued meanwhile is left alone.
//
// `enqueue` stays. The callers (iPhone and Mac MeetingChoices) restore when a just-made choice is refused (503 or any
// non-offline failure); that wiring is in the apps and has no test in this package.

final class Build9FixF4OutboxRestoreTests: XCTestCase {
    private func make(_ name: String = "restore") throws -> (OverrideOutbox, URL) {
        let directory = try B9.tempDirectory(self, name).appendingPathComponent("queue", isDirectory: true)
        return (OverrideOutbox(directory: directory), directory)
    }

    private let editA = OverrideEdit(scope: .event, startUtc: .set(B9.at(-600)), endUtc: .set(B9.at(2400)))
    private let editB = OverrideEdit(scope: .event, state: .set(.notJoined))

    /// The item a caller builds for what it just queued (the plain edit, not the stored merge).
    private func item(_ id: String, _ edit: OverrideEdit, at seconds: TimeInterval) -> OverrideOutbox.Item {
        OverrideOutbox.Item(eventID: id, edit: edit, queuedAt: B9.at(seconds))
    }

    // MARK: What enqueueReplacing answers

    func testTheFirstEditReplacesNothing() throws {
        let (outbox, _) = try make()
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editA, at: B9.at(10))
        XCTAssertTrue(result.saved)
        XCTAssertNil(result.replaced)
        XCTAssertEqual(outbox.pending(), [item("ev1", editA, at: 10)])
    }

    func testTheSecondEditAnswersTheFirstExactlyAsItWasStored() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let before = try XCTUnwrap(outbox.pending().first)
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        XCTAssertTrue(result.saved)
        XCTAssertEqual(result.replaced, before)
        XCTAssertEqual(result.replaced?.queuedAt, B9.at(10))
        XCTAssertEqual(result.replaced?.edit, editA, "the older edit as it was, not merged with the new one")
    }

    func testAnotherEventOrScopeReplacesNothing() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        XCTAssertNil(outbox.enqueueReplacing(eventID: "ev2", edit: editB, at: B9.at(20)).replaced)
        XCTAssertNil(outbox.enqueueReplacing(eventID: "ev1", edit: OverrideEdit(scope: .series, state: .set(.unlinked)), at: B9.at(30)).replaced)
        XCTAssertEqual(outbox.pending().count, 3)
    }

    func testReplacingAMergedItemAnswersTheMergedItem() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: editB, at: B9.at(20))
        let merged = try XCTUnwrap(outbox.pending().first)
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(3000))), at: B9.at(30))
        XCTAssertEqual(result.replaced, merged)
    }

    func testEnqueueReplacingMergesLikeEnqueue() throws {
        // F3 applies to both calls.
        let (outbox, _) = try make()
        outbox.enqueueReplacing(eventID: "ev1", edit: editA, at: B9.at(10))
        outbox.enqueueReplacing(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(3300))), at: B9.at(20))
        let pending = outbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.edit, OverrideEdit(scope: .event, startUtc: .set(B9.at(-600)), endUtc: .set(B9.at(3300))))
        XCTAssertEqual(pending.first?.queuedAt, B9.at(20))
    }

    func testAnUnwritableQueueSavesNothingAndKeepsWhatWasThere() throws {
        let parent = try B9.tempDirectory(self, "blocked")
        let file = parent.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        let outbox = OverrideOutbox(directory: file)
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editA, at: B9.at(10))
        XCTAssertFalse(result.saved)
        XCTAssertNil(result.replaced)
        XCTAssertEqual(outbox.pending(), [])
        outbox.restore(nil, insteadOf: item("ev1", editA, at: 10))
    }

    // MARK: Restore

    func testRestoreGoesBackToTheEarlierEditAfterARefusal() throws {
        // Enqueue A, enqueue B replacing A, B is refused: A is pending again, as it was.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let before = try XCTUnwrap(outbox.pending().first)
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        XCTAssertEqual(outbox.pending().first?.edit.state, .set(.notJoined), "B is stored while it is being sent")
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending(), [before], "A with its own edit and its own queuedAt")
        XCTAssertEqual(outbox.pending().first?.edit, editA, "nothing of B is left, not even merged in")
        XCTAssertEqual(outbox.pending().first?.queuedAt, B9.at(10))
    }

    func testRestoreWorksWithTheItemFromPendingToo() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        let stored = try XCTUnwrap(outbox.pending().first)
        outbox.restore(result.replaced, insteadOf: stored)
        XCTAssertEqual(outbox.pending(), [item("ev1", editA, at: 10)])
    }

    func testRestoreSurvivesARelaunch() throws {
        let (outbox, directory) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(OverrideOutbox(directory: directory).pending(), [item("ev1", editA, at: 10)])
    }

    func testRestoreWithNothingBeforeRemovesTheRefusedEdit() throws {
        // The first edit for the meeting is refused: back to an empty queue (what remove did before).
        let (outbox, directory) = try make()
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        XCTAssertNil(result.replaced)
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending(), [])
        XCTAssertEqual(OverrideOutbox(directory: directory).pending(), [])
    }

    func testSomethingNewerQueuedMeanwhileIsLeftAlone() throws {
        // A, then B (refused later), then C queued while B was in flight: restoring A must not undo C.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        let c = OverrideEdit(scope: .event, endUtc: .set(B9.at(3000)))
        outbox.enqueueReplacing(eventID: "ev1", edit: c, at: B9.at(30))
        let stored = try XCTUnwrap(outbox.pending().first)
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending(), [stored], "unchanged")
        XCTAssertEqual(outbox.pending().first?.queuedAt, B9.at(30))
        XCTAssertEqual(outbox.pending().first?.edit.endUtc, .set(B9.at(3000)))
    }

    func testSomethingNewerIsLeftAloneEvenWhenNothingWasBefore() throws {
        let (outbox, _) = try make()
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        outbox.enqueueReplacing(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(3000))), at: B9.at(30))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending().map(\.queuedAt), [B9.at(30)], "the newer edit is not removed")
    }

    func testRestoreMatchesOnQueuedAtSoAnEntryOneMillisecondLaterIsLeftAlone() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20.001))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending().first?.queuedAt, B9.at(20.001))
        XCTAssertEqual(outbox.pending().first?.edit.state, .set(.notJoined))
    }

    func testRestoreTouchesOnlyThatEventAndScope() throws {
        let (outbox, _) = try make()
        let other = OverrideEdit(scope: .event, endUtc: .set(B9.at(900)))
        let series = OverrideEdit(scope: .series, state: .set(.unlinked))
        outbox.enqueue(eventID: "ev2", edit: other, at: B9.at(5))
        outbox.enqueue(eventID: "ev1", edit: series, at: B9.at(6))
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending(), [item("ev2", other, at: 5), item("ev1", series, at: 6), item("ev1", editA, at: 10)])
    }

    func testRestoringAMergedEarlierEditPutsBackTheMergedForm() throws {
        // A and B were already merged into one pending edit. C is refused: the merged A+B comes back whole.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: editB, at: B9.at(20))
        let merged = try XCTUnwrap(outbox.pending().first)
        let c = OverrideEdit(scope: .event, endUtc: .set(B9.at(3000)))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: c, at: B9.at(30))
        outbox.restore(result.replaced, insteadOf: item("ev1", c, at: 30))
        XCTAssertEqual(outbox.pending(), [merged])
        XCTAssertEqual(outbox.pending().first?.edit.startUtc, .set(B9.at(-600)))
        XCTAssertEqual(outbox.pending().first?.edit.state, .set(.notJoined))
        XCTAssertEqual(outbox.pending().first?.edit.endUtc, .set(B9.at(2400)), "C's end is gone")
    }

    func testRestoringTwiceIsHarmless() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending(), [item("ev1", editA, at: 10)])
    }

    func testAnItemThatWasSentAndRemovedIsNotBroughtBackByRestore() throws {
        // B was sent fine and removed; a late restore for it must not bring A back.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        let result = outbox.enqueueReplacing(eventID: "ev1", edit: editB, at: B9.at(20))
        outbox.remove(try XCTUnwrap(outbox.pending().first))
        outbox.restore(result.replaced, insteadOf: item("ev1", editB, at: 20))
        XCTAssertEqual(outbox.pending(), [], "nothing is stored for B any more, so there is nothing to put A in place of")
    }

    func testPlainEnqueueStillWorksAndReturnsABool() throws {
        let (outbox, _) = try make()
        let saved: Bool = outbox.enqueue(eventID: "ev1", edit: editA, at: B9.at(10))
        XCTAssertTrue(saved)
        XCTAssertEqual(outbox.pending().count, 1)
    }
}
