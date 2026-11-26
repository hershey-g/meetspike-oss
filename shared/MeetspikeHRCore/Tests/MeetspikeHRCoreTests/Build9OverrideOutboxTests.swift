import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9, shared Swift contract: `OverrideEdit` (the PUT body) and `OverrideOutbox` (edits waiting to be sent).
//
// NEW API (names fixed here):
//
//   public struct OverrideEdit: Codable, Equatable, Sendable
//       public enum Change<Value: Codable & Equatable & Sendable>: Equatable, Sendable { case unchanged, clear, set(Value) }
//       public var scope: MeetingOverride.Scope
//       public var state: Change<MeetingOverride.State>
//       public var startUtc: Change<Date>
//       public var endUtc: Change<Date>
//       public init(scope: MeetingOverride.Scope, state: Change<MeetingOverride.State> = .unchanged,
//                   startUtc: Change<Date> = .unchanged, endUtc: Change<Date> = .unchanged)
//     `JSONEncoder().encode(edit)` (no strategies) IS the body of PUT /api/meetings/:id/override:
//       { "scope": "event"|"series", "state"?: "not_joined"|"unlinked"|"linked"|null, "startUtc"?: ISO|null, "endUtc"?: ISO|null }
//       .unchanged leaves the key out (the Worker leaves that part alone), .clear writes null (the Worker clears it),
//       .set writes the value. Dates are ISO 8601 UTC text ending in Z. No other keys: not the event id (it is in the
//       path), not a timestamp. Times are only for scope event: a series edit never writes startUtc or endUtc, even if
//       the caller set them (the Worker would answer 400).
//     JSONDecoder reads that body back to an equal value.
//
//   public struct OverrideOutbox: Sendable
//       public struct Item: Equatable, Sendable { public let eventID: String; public let edit: OverrideEdit; public let queuedAt: Date
//                                                    public init(eventID: String, edit: OverrideEdit, queuedAt: Date) }
//       public init(directory: URL)
//       @discardableResult public func enqueue(eventID: String, edit: OverrideEdit, at: Date) -> Bool
//       public func pending() -> [Item]                 oldest `queuedAt` first (ties by event id then scope)
//       public func remove(_ item: Item)                removes the stored edit only if it is still this item
//
// One pending edit per (eventID, scope): enqueuing again merges per field into it (fix pass F3: the newer edit keeps
// the older edit's fields it does not touch, its own fields win, `.clear` counts as touched; see
// Build9FixF3OutboxMergeTests). This was "newest wins, the older edit is gone, it is not merged". The queue is files in `directory`, so it survives the app being killed and relaunched. Nothing
// here throws or crashes: a directory that cannot be written makes enqueue return false, a file that is junk is
// skipped. Any event id is safe: slashes, dots, case differences, 400 characters, non-ASCII.

final class Build9OverrideEditTests: XCTestCase {
    private func body(_ edit: OverrideEdit) throws -> [String: Any] {
        let data = try JSONEncoder().encode(edit)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isNull(_ value: Any?) -> Bool { value is NSNull }

    func testAnEditWithOnlyAScopeIsJustTheScope() throws {
        let object = try body(OverrideEdit(scope: .event))
        XCTAssertEqual(Set(object.keys), ["scope"])
        XCTAssertEqual(object["scope"] as? String, "event")
        XCTAssertEqual(try body(OverrideEdit(scope: .series))["scope"] as? String, "series")
    }

    func testEachStateIsWrittenWithItsWireName() throws {
        for (state, text) in [(MeetingOverride.State.notJoined, "not_joined"), (.unlinked, "unlinked"), (.linked, "linked")] {
            let object = try body(OverrideEdit(scope: .series, state: .set(state)))
            XCTAssertEqual(Set(object.keys), ["scope", "state"], text)
            XCTAssertEqual(object["state"] as? String, text)
        }
    }

    func testClearingAStateWritesNullNotAnAbsentKey() throws {
        let object = try body(OverrideEdit(scope: .event, state: .clear))
        XCTAssertEqual(Set(object.keys), ["scope", "state"])
        XCTAssertTrue(isNull(object["state"]), "null clears, a missing key would leave it")
    }

    func testTimesAreIsoUtcTextOnTheEventScope() throws {
        let edit = OverrideEdit(scope: .event, startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400.5)))
        let object = try body(edit)
        XCTAssertEqual(Set(object.keys), ["scope", "startUtc", "endUtc"])
        let start = try XCTUnwrap(object["startUtc"] as? String)
        let end = try XCTUnwrap(object["endUtc"] as? String)
        XCTAssertTrue(start.hasSuffix("Z"), start)
        XCTAssertTrue(end.hasSuffix("Z"), end)
        XCTAssertEqual(APITime.parse(start), B9.at(300))
        XCTAssertEqual(APITime.parse(end), B9.at(2400.5))
    }

    func testUseCalendarTimesClearsBothTimes() throws {
        let object = try body(OverrideEdit(scope: .event, startUtc: .clear, endUtc: .clear))
        XCTAssertEqual(Set(object.keys), ["scope", "startUtc", "endUtc"])
        XCTAssertTrue(isNull(object["startUtc"]))
        XCTAssertTrue(isNull(object["endUtc"]))
    }

    func testOneTimeCanBeSetWhileTheOtherIsLeftAlone() throws {
        let object = try body(OverrideEdit(scope: .event, endUtc: .set(B9.at(2400))))
        XCTAssertEqual(Set(object.keys), ["scope", "endUtc"])
    }

    func testAStateAndTimesTravelTogether() throws {
        let object = try body(OverrideEdit(scope: .event, state: .set(.linked), startUtc: .set(B9.at(60)), endUtc: .clear))
        XCTAssertEqual(Set(object.keys), ["scope", "state", "startUtc", "endUtc"])
        XCTAssertEqual(object["state"] as? String, "linked")
        XCTAssertTrue(isNull(object["endUtc"]))
    }

    func testASeriesEditNeverCarriesTimes() throws {
        let object = try body(OverrideEdit(scope: .series, state: .set(.notJoined), startUtc: .set(B9.at(60)), endUtc: .clear))
        XCTAssertEqual(Set(object.keys), ["scope", "state"], "times are only for the event scope")
    }

    func testNoOtherKeysAreEverWritten() throws {
        let edits = [
            OverrideEdit(scope: .event), OverrideEdit(scope: .series, state: .clear),
            OverrideEdit(scope: .event, state: .set(.unlinked), startUtc: .set(B9.at(0)), endUtc: .set(B9.at(60))),
        ]
        for edit in edits {
            XCTAssertTrue(Set(try body(edit).keys).isSubset(of: ["scope", "state", "startUtc", "endUtc"]))
        }
    }

    func testTheBodyReadsBackToTheSameEdit() throws {
        let edits = [
            OverrideEdit(scope: .event),
            OverrideEdit(scope: .series, state: .set(.unlinked)),
            OverrideEdit(scope: .event, state: .clear, startUtc: .clear, endUtc: .clear),
            OverrideEdit(scope: .event, state: .set(.notJoined), startUtc: .set(B9.at(300.125)), endUtc: .set(B9.at(2400))),
        ]
        for edit in edits {
            let data = try JSONEncoder().encode(edit)
            XCTAssertEqual(try JSONDecoder().decode(OverrideEdit.self, from: data), edit)
        }
    }

    func testClearAndUnchangedAreNotTheSameEdit() {
        XCTAssertNotEqual(OverrideEdit(scope: .event, state: .clear), OverrideEdit(scope: .event, state: .unchanged))
        XCTAssertNotEqual(OverrideEdit(scope: .event, startUtc: .clear), OverrideEdit(scope: .event))
    }

    func testTheBodyDoesNotDependOnTheDeviceTimeZone() throws {
        var bodies: Set<String> = []
        try B9.inZones(B9.zones) { _ in
            let edit = OverrideEdit(scope: .event, startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400)))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bodies.insert(String(decoding: try encoder.encode(edit), as: UTF8.self))
        }
        XCTAssertEqual(bodies.count, 1, "\(bodies)")
    }
}

final class Build9OverrideOutboxTests: XCTestCase {
    private func make(_ name: String = "outbox") throws -> (OverrideOutbox, URL) {
        let directory = try B9.tempDirectory(self, name).appendingPathComponent("queue", isDirectory: true)
        return (OverrideOutbox(directory: directory), directory)
    }

    private let notJoined = OverrideEdit(scope: .event, state: .set(.notJoined))

    func testAnEmptyOrMissingDirectoryHasNothingPending() throws {
        let (outbox, directory) = try make()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(outbox.pending(), [])
    }

    func testAQueuedEditComesBackExactly() throws {
        let (outbox, _) = try make()
        XCTAssertTrue(outbox.enqueue(eventID: "ev1", edit: notJoined, at: B9.at(10)))
        XCTAssertEqual(outbox.pending(), [OverrideOutbox.Item(eventID: "ev1", edit: notJoined, queuedAt: B9.at(10))])
    }

    func testItSurvivesARelaunch() throws {
        let (outbox, directory) = try make()
        let edit = OverrideEdit(scope: .event, state: .clear, startUtc: .set(B9.at(300.5)), endUtc: .clear)
        XCTAssertTrue(outbox.enqueue(eventID: "ev1", edit: edit, at: B9.at(10)))
        let relaunched = OverrideOutbox(directory: directory)
        XCTAssertEqual(relaunched.pending(), [OverrideOutbox.Item(eventID: "ev1", edit: edit, queuedAt: B9.at(10))])
        XCTAssertEqual(relaunched.pending().first?.edit.state, .clear, "clear is not turned into unchanged on disk")
        XCTAssertEqual(relaunched.pending().first?.edit.endUtc, .clear)
    }

    func testTheNewestEditForTheSameEventAndScopeWins() throws {
        let (outbox, _) = try make()
        let newer = OverrideEdit(scope: .event, state: .set(.unlinked))
        outbox.enqueue(eventID: "ev1", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: newer, at: B9.at(20))
        XCTAssertEqual(outbox.pending(), [OverrideOutbox.Item(eventID: "ev1", edit: newer, queuedAt: B9.at(20))])
    }

    func testNewerEditIsMergedIntoTheOlderOneAcrossARelaunch() throws {
        // Fix pass F3 replaces "newest wins, whole, not merged": the older state is kept, the newer times are added.
        let (outbox, directory) = try make()
        outbox.enqueue(eventID: "ev1", edit: OverrideEdit(scope: .event, state: .set(.notJoined)), at: B9.at(10))
        let relaunched = OverrideOutbox(directory: directory)
        let times = OverrideEdit(scope: .event, startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400)))
        relaunched.enqueue(eventID: "ev1", edit: times, at: B9.at(20))
        let pending = OverrideOutbox(directory: directory).pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.edit, OverrideEdit(scope: .event, state: .set(.notJoined), startUtc: .set(B9.at(300)), endUtc: .set(B9.at(2400))))
        XCTAssertEqual(pending.first?.edit.state, .set(.notJoined), "the older state is kept, merged in")
        XCTAssertEqual(pending.first?.queuedAt, B9.at(20))
    }

    func testTheSameEventWithAnotherScopeIsAnotherEdit() throws {
        let (outbox, _) = try make()
        let series = OverrideEdit(scope: .series, state: .set(.unlinked))
        outbox.enqueue(eventID: "ev1", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "ev1", edit: series, at: B9.at(20))
        XCTAssertEqual(outbox.pending().map(\.edit), [notJoined, series])
    }

    func testDifferentEventsAreDifferentEdits() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "ev2", edit: notJoined, at: B9.at(20))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["ev1", "ev2"])
    }

    func testPendingIsOldestFirstWhateverTheOrderTheyWereWritten() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "c", edit: notJoined, at: B9.at(30))
        outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "b", edit: notJoined, at: B9.at(20))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["a", "b", "c"])
    }

    func testReplacingAnEditMovesItToTheBack() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "b", edit: notJoined, at: B9.at(20))
        outbox.enqueue(eventID: "a", edit: OverrideEdit(scope: .event, state: .set(.linked)), at: B9.at(30))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["b", "a"])
    }

    func testRemovingASentEditLeavesTheRest() throws {
        let (outbox, directory) = try make()
        outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "b", edit: notJoined, at: B9.at(20))
        outbox.remove(try XCTUnwrap(outbox.pending().first))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["b"])
        XCTAssertEqual(OverrideOutbox(directory: directory).pending().map(\.eventID), ["b"], "gone on disk too")
    }

    func testASentEditDoesNotRemoveANewerOneQueuedWhileItWasSending() throws {
        // The send of the old edit was in flight when the person changed their mind. Its success must not erase the new one.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: notJoined, at: B9.at(10))
        let inFlight = try XCTUnwrap(outbox.pending().first)
        let newer = OverrideEdit(scope: .event, state: .set(.linked))
        outbox.enqueue(eventID: "ev1", edit: newer, at: B9.at(20))
        outbox.remove(inFlight)
        XCTAssertEqual(outbox.pending(), [OverrideOutbox.Item(eventID: "ev1", edit: newer, queuedAt: B9.at(20))])
    }

    func testRemovingSomethingThatIsNotThereIsHarmless() throws {
        let (outbox, _) = try make()
        outbox.remove(OverrideOutbox.Item(eventID: "ghost", edit: notJoined, queuedAt: B9.at(0)))
        outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10))
        outbox.remove(OverrideOutbox.Item(eventID: "ghost", edit: notJoined, queuedAt: B9.at(0)))
        XCTAssertEqual(outbox.pending().count, 1)
    }

    func testAnEditCanBeEnqueuedAgainAfterItWasRemoved() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10))
        outbox.remove(try XCTUnwrap(outbox.pending().first))
        XCTAssertEqual(outbox.pending(), [])
        XCTAssertTrue(outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(20)))
        XCTAssertEqual(outbox.pending().count, 1)
    }

    // MARK: Never throws, never crashes

    func testAJunkFileIsSkippedAndTheRestStillComesBack() throws {
        let (outbox, directory) = try make()
        outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10))
        try Data("this is not json".utf8).write(to: directory.appendingPathComponent("junk.json"))
        try Data().write(to: directory.appendingPathComponent("empty.json"))
        try Data(#"{"eventID":7}"#.utf8).write(to: directory.appendingPathComponent("wrong-shape.json"))
        outbox.enqueue(eventID: "b", edit: notJoined, at: B9.at(20))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["a", "b"])
    }

    func testADirectoryThatCannotBeWrittenMakesEnqueueFalseNotACrash() throws {
        let parent = try B9.tempDirectory(self, "blocked")
        let file = parent.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        let outbox = OverrideOutbox(directory: file)
        XCTAssertFalse(outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10)))
        XCTAssertEqual(outbox.pending(), [])
        outbox.remove(OverrideOutbox.Item(eventID: "a", edit: notJoined, queuedAt: B9.at(10)))
    }

    func testAReadOnlyDirectoryMakesEnqueueFalseAndKeepsWhatWasThere() throws {
        let (outbox, directory) = try make("readonly")
        XCTAssertTrue(outbox.enqueue(eventID: "a", edit: notJoined, at: B9.at(10)))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        if getuid() == 0 { throw XCTSkip("root ignores directory permissions") }
        XCTAssertFalse(outbox.enqueue(eventID: "b", edit: notJoined, at: B9.at(20)))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["a"])
    }

    // MARK: Any event id

    func testHostileEventIDsStayInsideTheQueueDirectory() throws {
        let root = try B9.tempDirectory(self, "hostile")
        let directory = root.appendingPathComponent("queue", isDirectory: true)
        let outbox = OverrideOutbox(directory: directory)
        let ids = ["../../escape", "a/b/c", "..", ".", "/etc/passwd", "name with spaces", "emoji-\u{1F4C5}", "caf\u{00E9}", "100%", "a:b*c?"]
        for (index, id) in ids.enumerated() {
            outbox.enqueue(eventID: id, edit: notJoined, at: B9.at(Double(index)))
        }
        XCTAssertEqual(Set(outbox.pending().map(\.eventID)), Set(ids), "every id is kept exactly")
        XCTAssertEqual(B8.files(in: root), ["queue"], "nothing was written next to the queue directory")
        let inside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in inside { XCTAssertFalse(name.contains("/"), name) }
    }

    func testAVeryLongEventIDWorks() throws {
        let (outbox, _) = try make()
        let long = String(repeating: "abcdefghij", count: 40) + "_20261125T140000Z"
        XCTAssertTrue(outbox.enqueue(eventID: long, edit: notJoined, at: B9.at(10)), "file names are limited to 255 bytes")
        XCTAssertEqual(outbox.pending().map(\.eventID), [long])
    }

    func testIDsThatDifferOnlyByCaseAreDifferentEdits() throws {
        // macOS file systems ignore case by default, ids do not.
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "AbC123", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "abc123", edit: OverrideEdit(scope: .event, state: .set(.unlinked)), at: B9.at(20))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["AbC123", "abc123"])
    }

    func testAnIDThatLooksLikeAnotherIDsFileNameIsNotConfusedWithIt() throws {
        let (outbox, _) = try make()
        outbox.enqueue(eventID: "ev1", edit: notJoined, at: B9.at(10))
        outbox.enqueue(eventID: "ev1.json", edit: notJoined, at: B9.at(20))
        outbox.enqueue(eventID: "ev1_event", edit: notJoined, at: B9.at(30))
        XCTAssertEqual(outbox.pending().map(\.eventID), ["ev1", "ev1.json", "ev1_event"])
    }

    func testSeriesInstanceIDsKeepTheirSuffix() throws {
        let (outbox, _) = try make()
        let id = "7sf8ahq90d3k2j4_20261125T140000Z"
        outbox.enqueue(eventID: id, edit: OverrideEdit(scope: .series, state: .set(.unlinked)), at: B9.at(10))
        XCTAssertEqual(outbox.pending().first?.eventID, id)
    }

    // MARK: Many at once

    func testConcurrentEnqueuesAreAllKept() throws {
        let (outbox, _) = try make()
        let count = 40
        DispatchQueue.concurrentPerform(iterations: count) { index in
            outbox.enqueue(eventID: "event-\(index)", edit: notJoined, at: B9.at(Double(index)))
        }
        XCTAssertEqual(Set(outbox.pending().map(\.eventID)), Set((0..<count).map { "event-\($0)" }))
    }

    func testConcurrentEditsToTheSameEventLeaveExactlyOne() throws {
        let (outbox, directory) = try make()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            outbox.enqueue(eventID: "same", edit: OverrideEdit(scope: .event, state: .set(index.isMultiple(of: 2) ? .linked : .unlinked)),
                           at: B9.at(Double(index)))
        }
        XCTAssertEqual(outbox.pending().count, 1)
        XCTAssertEqual(OverrideOutbox(directory: directory).pending().count, 1)
    }
}
