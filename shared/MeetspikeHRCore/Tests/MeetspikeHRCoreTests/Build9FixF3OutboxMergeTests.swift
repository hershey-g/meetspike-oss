import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 fix pass, F3: the outbox merges per field.
//
// A newer edit for the same event and scope keeps the older pending edit's fields it does not touch, and its own
// fields win. `.clear` counts as touched. Different events or scopes are never merged. The merged item is stored under
// the newer `queuedAt`. This replaces "newest wins, nothing is merged".
//
// Uses only the existing `enqueue` here (it compiles today); the same merge through `enqueueReplacing` is in
// Build9FixF4OutboxRestoreTests.

final class Build9FixF3OutboxMergeTests: XCTestCase {
    private func make(_ name: String = "merge") throws -> (OverrideOutbox, URL) {
        let directory = try B9.tempDirectory(self, name).appendingPathComponent("queue", isDirectory: true)
        return (OverrideOutbox(directory: directory), directory)
    }

    private func only(_ outbox: OverrideOutbox, file: StaticString = #filePath, line: UInt = #line) throws -> OverrideOutbox.Item {
        let pending = outbox.pending()
        XCTAssertEqual(pending.count, 1, "one pending edit per event and scope", file: file, line: line)
        return try XCTUnwrap(pending.first, file: file, line: line)
    }

    func testAnOfflineTimesEditThenStillGoingKeepsTheStart() throws {
        // The review's repro: save Meeting times (start and end), then tap Still going (end only).
        let (outbox, _) = try make()
        let times = OverrideEdit(scope: .event, startUtc: .set(B9.at(-600)), endUtc: .set(B9.at(2400)))
        let stillGoing = OverrideEdit(scope: .event, endUtc: .set(B9.at(3300)))
        outbox.enqueue(eventID: "ev1", edit: times, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: stillGoing, at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit.startUtc, .set(B9.at(-600)), "the start is still sent")
        XCTAssertEqual(item.edit.endUtc, .set(B9.at(3300)), "the newer end wins")
        XCTAssertEqual(item.edit.state, .unchanged)
        XCTAssertEqual(item.edit.scope, .event)
        XCTAssertEqual(item.queuedAt, B9.at(20))
    }

    func testEndedNowThenNoOnTheNotJoinedNoteKeepsBoth() throws {
        let (outbox, _) = try make()
        let target = LiveAdjustTarget(meetingID: "ev1", title: "Standup", start: B9.at(0), end: B9.at(1800), calendarEnd: B9.at(1800))
        let ended = try XCTUnwrap(LiveAdjust.endedNow(target, now: B9.at(1200)))
        guard case .save(let no) = MeetingActions.plan(.skipNo, override: MeetingOverride(seenNone: true)) else {
            return XCTFail("the note's No saves right away")
        }
        outbox.enqueue(eventID: "ev1", edit: ended, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: no, at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit.endUtc, .set(B9.at(1200)), "the end from Ended now is not lost")
        XCTAssertEqual(item.edit.state, .set(.linked))
    }

    func testTheNewerFieldWinsWhenBothTouchIt() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.notJoined), endUtc: .set(B9.at(2000))), at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.unlinked), endUtc: .set(B9.at(2600))), at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit, OverrideEdit(scope: .event, state: .set(.unlinked), endUtc: .set(B9.at(2600))))
    }

    func testAnOlderStateSurvivesANewerTimesEdit() throws {
        // Replaces the pin "the older state is gone, not merged in".
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)), at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400))), at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit, OverrideEdit(scope: .event, state: .set(.notJoined), startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400))))
    }

    func testClearInTheNewerEditCountsAsTouchedAndWinsOverAnOlderSet() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.notJoined), startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400))), at: B9.at(10))
        // "Use calendar times" clears both times; the state is left alone.
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, startUtc: .clear, endUtc: .clear), at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit.startUtc, .clear, "clear is not turned back into the older set")
        XCTAssertEqual(item.edit.endUtc, .clear)
        XCTAssertEqual(item.edit.state, .set(.notJoined), "the older state is kept")
        // And Undo (state clear) over an older state.
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .clear), at: B9.at(30))
        XCTAssertEqual(try only(outbox).edit, OverrideEdit(scope: .event, state: .clear, startUtc: .clear, endUtc: .clear))
    }

    func testAnOlderClearSurvivesANewerEditThatLeavesThatFieldAlone() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .clear), at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))), at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit.state, .clear, "an older clear is still a pending change, not an absent one")
        XCTAssertEqual(item.edit.endUtc, .set(B9.at(2400)))
    }

    func testANewerEditWithNothingToSayChangesNothingButTheTime() throws {
        let (outbox, _) = try make()
        let older = OverrideEdit(scope: .event, state: .set(.linked), endUtc: .set(B9.at(2400)))
        outbox.enqueue(eventID: "ev1", edit: older, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event), at: B9.at(20))
        XCTAssertEqual(try only(outbox), OverrideOutbox.Item(eventID: "ev1", edit: older, queuedAt: B9.at(20)))
    }

    func testTheMergedEditIsTheWireBodyWithEveryPendingField() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, startUtc: .set(B9.at(-600))), at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .clear, endUtc: .set(B9.at(2400))), at: B9.at(20))
        let body = try H9.wire(try only(outbox).edit)
        XCTAssertEqual(Set(body.keys), ["scope", "state", "startUtc", "endUtc"])
        XCTAssertTrue(body["state"] is NSNull)
        XCTAssertEqual(body["startUtc"] as? String, B9.iso(-600))
        XCTAssertEqual(body["endUtc"] as? String, B9.iso(2400))
    }

    func testTheMergeSurvivesARelaunchAndKeepsMerging() throws {
        let (outbox, directory) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)), at: B9.at(10))
        let relaunched = OverrideOutbox(directory: directory)
        relaunched.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, startUtc: .set(B9.at(300))), at: B9.at(20))
        let again = OverrideOutbox(directory: directory)
        again.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))), at: B9.at(30))
        let item = try only(OverrideOutbox(directory: directory))
        XCTAssertEqual(item.edit, OverrideEdit(scope: .event, state: .set(.notJoined), startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400))))
        XCTAssertEqual(item.queuedAt, B9.at(30))
    }

    func testAnEditThatWasAlreadySentIsNotMergedBack() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, startUtc: .set(B9.at(300))), at: B9.at(10))
        outbox.remove(try only(outbox))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))), at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit.startUtc, .unchanged, "a sent edit is not sent a second time")
        XCTAssertEqual(item.edit.endUtc, .set(B9.at(2400)))
    }

    func testAnotherScopeOrAnotherEventIsNeverMerged() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)), at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .series, state: .set(.unlinked)), at: B9.at(20))
        outbox.enqueue(eventID: "ev2", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))), at: B9.at(30))
        let pending = outbox.pending()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(pending[0].edit, OverrideEdit(scope: .event, state: .set(.notJoined)))
        XCTAssertEqual(pending[1].edit, OverrideEdit(scope: .series, state: .set(.unlinked)))
        XCTAssertEqual(pending[2].edit, OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))))
    }

    func testASeriesEditMergesItsOwnStateAndStillNeverCarriesTimes() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "s_20261125", edit: OverrideEdit(scope: .series, state: .set(.notJoined)), at: B9.at(10))
        outbox.enqueue(eventID: "s_20261125", edit: OverrideEdit(scope: .series, state: .clear), at: B9.at(20))
        let item = try only(outbox)
        XCTAssertEqual(item.edit.state, .clear, "the newer series choice wins")
        let body = try H9.wire(item.edit)
        XCTAssertNil(body["startUtc"])
        XCTAssertNil(body["endUtc"])
    }

    func testAMergedEditCanBeRemovedByTheItemTheSenderHolds() throws {
        // The sender reads pending() and removes that item once it is sent; a merged edit must still be removable,
        // and a newer edit queued while it was in flight must stay.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, startUtc: .set(B9.at(300))), at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))), at: B9.at(20))
        let inFlight = try only(outbox)
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.linked)), at: B9.at(30))
        outbox.remove(inFlight)
        XCTAssertEqual(outbox.pending().count, 1, "the edit queued while sending stays")
        XCTAssertEqual(outbox.pending().first?.queuedAt, B9.at(30))
        outbox.remove(try only(outbox))
        XCTAssertEqual(outbox.pending(), [])
    }

    func testConcurrentEditsToOneMeetingLoseNoField() throws {
        let (outbox, directory) = try make()
        DispatchQueue.concurrentPerform(iterations: 3) { index in
            let edit: OverrideEdit
            switch index {
            case 0: edit = OverrideEdit(scope: .event, state: .set(.notJoined))
            case 1: edit = OverrideEdit(scope: .event, startUtc: .set(B9.at(300)))
            default: edit = OverrideEdit(scope: .event, endUtc: .set(B9.at(2400)))
            }
            outbox.enqueue(eventID: "same", edit: edit, at: B9.at(Double(10 + index)))
        }
        let item = try only(OverrideOutbox(directory: directory))
        XCTAssertEqual(item.edit.state, .set(.notJoined))
        XCTAssertEqual(item.edit.startUtc, .set(B9.at(300)))
        XCTAssertEqual(item.edit.endUtc, .set(B9.at(2400)))
    }
}
