import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8 fix pass 2: tests that need the NEW public names from .claude/jobs/92fc823f/tmp/fix8.md. This file does not
// compile until they exist, which is expected; everything that can run on today's API is in the other
// Build8Fix2*Tests.swift files.
//
// New names used here, exactly as the spec gives them:
//
//   public enum DiagnosticStack { public static func run<T>(_ body: () throws -> T) rethrows -> T }      F1
//   DiagnosticQueue.add(_:) is `@discardableResult ... -> Bool`                                          F4
//   public struct DiagnosticAttempts: Sendable {                                                         F5
//       public init(file: URL, maxTries: Int = 2, limit: Int = 200)
//       public func begin(_ id: UUID) -> Bool
//       public func finish(_ id: UUID) }
//   DiagnosticPolicy.attachCrumbs(crashCount: Int, live: Bool) -> Bool                                   F6
//   DiagnosticPolicy.testLine(lastTestID:pendingIDs:refusedIDs:unsavedIDs:sentIDs: Set<UUID>? = nil)      F8

#if canImport(Darwin)
private func stackSizeOfThisThread() -> Int { Int(pthread_get_stacksize_np(pthread_self())) }
private func thisThread() -> UInt { UInt(bitPattern: pthread_self()) }
#endif

// MARK: F1: DiagnosticStack

/// Recursion that needs far more than 512 KB (about 6,000 levels of ~1 KB) and well under 16 MB. It is only ever
/// called inside `DiagnosticStack.run`.
@inline(never)
private func fix2Burn(_ level: Int) -> Int {
    if level == 0 { return 0 }
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1024) { buffer -> Int in
        buffer[0] = UInt8(truncatingIfNeeded: level)
        buffer[1023] = buffer[0]
        return fix2Burn(level - 1) + Int(buffer[1023] & 1)
    }
}

private func fix2OddCount(upTo n: Int) -> Int { (1...n).filter { $0 & 1 == 1 }.count }

extension Fix2Engine {
    func deepRecursionInsideRun() -> Int { DiagnosticStack.run { fix2Burn(6000) } }
}

final class Build8Fix2DiagnosticStackTests: XCTestCase {

    func testRunReturnsTheBodysValue() {
        XCTAssertEqual(DiagnosticStack.run { 41 + 1 }, 42)
        XCTAssertEqual(DiagnosticStack.run { "text" }, "text")
        XCTAssertEqual(DiagnosticStack.run { () -> [Int] in [] }, [])
    }

    func testRunWaitsForTheBodyToFinish() {
        var order: [String] = []
        DiagnosticStack.run {
            Thread.sleep(forTimeInterval: 0.05)
            order.append("body")
        }
        order.append("after")
        XCTAssertEqual(order, ["body", "after"])
    }

    func testRunRethrowsAndAcceptsANonThrowingBodyWithoutTry() {
        struct Boom: Error, Equatable {}
        XCTAssertThrowsError(try DiagnosticStack.run { () throws -> Int in throw Boom() }) { XCTAssertEqual($0 as? Boom, Boom()) }
        XCTAssertEqual(DiagnosticStack.run { 1 }, 1)   // rethrows: no `try` for a body that cannot throw
    }

    func testRunMovesTheBodyToABigStackThread() throws {
        #if canImport(Darwin)
        let caller = thisThread()
        let (inside, bodyThread) = DiagnosticStack.run { (stackSizeOfThisThread(), thisThread()) }
        XCTAssertGreaterThanOrEqual(inside, 15 * 1024 * 1024, "16 MB stack, was \(inside)")
        XCTAssertNotEqual(bodyThread, caller, "the body runs on its own thread")
        #else
        throw XCTSkip("needs pthread_get_stacksize_np")
        #endif
    }

    func testRunFromASmallThreadMakesDeepRecursionSafe() {
        let total = fix2OnSmallThread { DiagnosticStack.run { fix2Burn(6000) } }
        XCTAssertEqual(total, fix2OddCount(upTo: 6000))
    }

    func testRunFromTheMainThreadAndFromAnActorBothWork() async {
        XCTAssertEqual(DiagnosticStack.run { fix2Burn(2000) }, fix2OddCount(upTo: 2000))
        let engine = Fix2Engine()
        let total = await Task.detached(priority: .utility) { await engine.deepRecursionInsideRun() }.value
        XCTAssertEqual(total, fix2OddCount(upTo: 6000))
    }

    func testNestedRunStaysOnTheSameThreadAndNeverStartsAnother() throws {
        #if canImport(Darwin)
        let (outer, inner, innermost) = DiagnosticStack.run { () -> (UInt, UInt, UInt) in
            let first = thisThread()
            let second = DiagnosticStack.run { () -> (UInt, UInt) in
                (thisThread(), DiagnosticStack.run { thisThread() })
            }
            return (first, second.0, second.1)
        }
        XCTAssertEqual(outer, inner, "already on a big-stack thread: run inline")
        XCTAssertEqual(outer, innermost)
        #else
        throw XCTSkip("needs pthread_self")
        #endif
    }

    func testManyCallersAtOnceAllGetTheirOwnAnswer() {
        let results = Mutex2<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let value = DiagnosticStack.run { fix2Burn(500) + index }
            results.update { $0.append(value) }
        }
        XCTAssertEqual(results.value.count, 32)
        XCTAssertEqual(Set(results.value).count, 32)
    }

    func testTheReportTypesStillCompareWithPlainEquality() {
        // Equatable on DiagnosticValue stays as is.
        XCTAssertEqual(DiagnosticValue.object(["a": .array([.number(1)])]), .object(["a": .array([.number(1)])]))
        XCTAssertNotEqual(DiagnosticValue.object(["a": .null]), .object([:]))
    }
}

final class Mutex2<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

// MARK: F4: DiagnosticQueue.add says whether it saved

final class Build8Fix2QueueAddTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try B8.tempDirectory("fix2-add") }
    override func tearDown() { B8.remove(directory) }

    func testAddReturnsTrueWhenTheFileIsSaved() {
        let queue = DiagnosticQueue(directory: directory)
        let saved: Bool = queue.add(B8.report(1))
        XCTAssertTrue(saved)
        XCTAssertEqual(queue.pending().map(\.id), [B8.report(1).id])
    }

    func testAddingTheSameIdAgainIsStillSaved() {
        let queue = DiagnosticQueue(directory: directory)
        XCTAssertTrue(queue.add(B8.report(1)))
        XCTAssertTrue(queue.add(B8.report(1)))
        XCTAssertEqual(queue.pending().count, 1)
    }

    func testAddReturnsFalseWhenTheDirectoryCannotBeMade() throws {
        // A regular file where the directory should be: nothing can be created inside it.
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let queue = DiagnosticQueue(directory: blocker.appendingPathComponent("queue", isDirectory: true))
        XCTAssertFalse(queue.add(B8.report(1)))
        XCTAssertEqual(queue.pending(), [])
    }

    func testAddReturnsFalseWhenTheDirectoryIsReadOnly() throws {
        let queueDirectory = directory.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: queueDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: queueDirectory.path) }
        if FileManager.default.isWritableFile(atPath: queueDirectory.path) { throw XCTSkip("this account can write a mode 500 folder") }
        XCTAssertFalse(DiagnosticQueue(directory: queueDirectory).add(B8.report(1)))
        XCTAssertEqual(B8.files(in: queueDirectory), [])
    }

    func testAddCanBeCalledWithoutUsingTheResult() {
        // @discardableResult: existing call sites keep compiling without `_ =`.
        let queue = DiagnosticQueue(directory: directory)
        queue.add(B8.report(1))
        XCTAssertEqual(queue.pending().count, 1)
    }
}

// MARK: F5: DiagnosticAttempts

final class Build8Fix2AttemptsTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("attempts.txt") }
    private let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
    private let c = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!
    private let d = UUID(uuidString: "DDDDDDDD-0000-4000-8000-000000000004")!

    override func setUpWithError() throws { directory = try B8.tempDirectory("fix2-attempts") }
    override func tearDown() { B8.remove(directory) }

    func testTheDefaultIsTwoTries() {
        let attempts = DiagnosticAttempts(file: file)
        XCTAssertTrue(attempts.begin(a))
        XCTAssertTrue(attempts.begin(a))
        XCTAssertFalse(attempts.begin(a), "a payload that already had two tries is not tried again")
        XCTAssertFalse(attempts.begin(a), "and stays refused")
    }

    func testTriesAreKeptOnDiskAcrossLaunches() {
        XCTAssertTrue(DiagnosticAttempts(file: file).begin(a))      // launch 1: the app dies while building
        XCTAssertTrue(DiagnosticAttempts(file: file).begin(a))      // launch 2: dies again
        XCTAssertFalse(DiagnosticAttempts(file: file).begin(a))     // launch 3: stop
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFinishForgetsTheId() {
        let attempts = DiagnosticAttempts(file: file)
        XCTAssertTrue(attempts.begin(a))
        XCTAssertTrue(attempts.begin(a))
        attempts.finish(a)
        XCTAssertTrue(attempts.begin(a), "finish removed it, so it starts again")
        XCTAssertTrue(attempts.begin(a))
        XCTAssertFalse(attempts.begin(a))
    }

    func testFinishOnAnUnknownIdAndOnAMissingFileDoesNothing() {
        let attempts = DiagnosticAttempts(file: file)
        attempts.finish(a)
        XCTAssertTrue(attempts.begin(a))
        attempts.finish(b)
        XCTAssertTrue(attempts.begin(a))
        XCTAssertFalse(attempts.begin(a))
    }

    func testIdsAreCountedSeparately() {
        let attempts = DiagnosticAttempts(file: file)
        XCTAssertTrue(attempts.begin(a)); XCTAssertTrue(attempts.begin(a)); XCTAssertFalse(attempts.begin(a))
        XCTAssertTrue(attempts.begin(b))
        attempts.finish(a)
        XCTAssertTrue(attempts.begin(a))
        XCTAssertTrue(attempts.begin(b))
        XCTAssertFalse(attempts.begin(b))
    }

    func testMaxTriesIsHonoured() {
        let one = DiagnosticAttempts(file: file, maxTries: 1)
        XCTAssertTrue(one.begin(a))
        XCTAssertFalse(one.begin(a))
        let fileThree = directory.appendingPathComponent("three.txt")
        let three = DiagnosticAttempts(file: fileThree, maxTries: 3)
        XCTAssertTrue(three.begin(a)); XCTAssertTrue(three.begin(a)); XCTAssertTrue(three.begin(a))
        XCTAssertFalse(three.begin(a))
    }

    func testOnlyTheNewestLimitIdsAreRemembered() {
        let attempts = DiagnosticAttempts(file: file, maxTries: 1, limit: 3)
        XCTAssertTrue(attempts.begin(a)); XCTAssertTrue(attempts.begin(b)); XCTAssertTrue(attempts.begin(c))
        XCTAssertTrue(attempts.begin(d), "a fourth id pushes the oldest out")
        XCTAssertFalse(attempts.begin(d), "the newest is still remembered")
        XCTAssertFalse(attempts.begin(c))
        XCTAssertTrue(attempts.begin(a), "the oldest was forgotten, so it counts as new")
    }

    func testFailureToWriteNeverThrowsAndBeginStillSaysYes() throws {
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let attempts = DiagnosticAttempts(file: blocker.appendingPathComponent("inside/attempts.txt"))
        XCTAssertTrue(attempts.begin(a))
        XCTAssertTrue(attempts.begin(a), "it could not be persisted, so it cannot be counted: still true")
        XCTAssertTrue(attempts.begin(a))
        attempts.finish(a)
    }

    func testAGarbageFileIsTreatedAsNothingKnown() throws {
        try Data([0xFF, 0x00, 0xFE, 0x0A, 0x0A]).write(to: file)
        let attempts = DiagnosticAttempts(file: file)
        XCTAssertTrue(attempts.begin(a))
        XCTAssertTrue(attempts.begin(a))
        XCTAssertFalse(attempts.begin(a))
        try Data("not an id\n\n   \n".utf8).write(to: directory.appendingPathComponent("junk.txt"))
        XCTAssertTrue(DiagnosticAttempts(file: directory.appendingPathComponent("junk.txt")).begin(b))
    }

    func testAFolderInPlaceOfTheFileDoesNotThrow() throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let attempts = DiagnosticAttempts(file: file)
        XCTAssertTrue(attempts.begin(a))
        attempts.finish(a)
    }

    func testConcurrentBeginsOfOneIdGiveExactlyMaxTriesYeses() {
        let attempts = DiagnosticAttempts(file: file)
        let yes = Mutex2(0)
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            if attempts.begin(a) { yes.update { $0 += 1 } }
        }
        XCTAssertEqual(yes.value, 2)
    }

    func testItIsSendable() {
        let attempts = DiagnosticAttempts(file: file)
        let sendable: any Sendable = attempts
        _ = sendable
    }
}

// MARK: F5: the engine's order of decisions, over the real primitives
//
// The engine itself is in ios/ (an app target the package tests cannot import), so this walks the spec's sequence
// with the real DiagnosticSeenIDs, DiagnosticAttempts and DiagnosticQueue. It proves the pieces fit as the spec says
// they should: a payload that kills the app is given up on, and a plain save failure costs no tries.
//
//   skip if seen.contains(id); if not allowed, seen.insert and stop; attempts.begin else seen.insert and stop;
//   build; if queue.add { seen.insert; attempts.finish }, else attempts.finish and leave the id unseen.

final class Build8Fix2EngineOrderTests: XCTestCase {
    private var directory: URL!
    private let id = UUID(uuidString: "EEEEEEEE-0000-4000-8000-0000000000EE")!

    override func setUpWithError() throws { directory = try B8.tempDirectory("fix2-engine") }
    override func tearDown() { B8.remove(directory) }

    private enum Step { case skippedSeen, switchedOff, gaveUp, saved, notSaved, died }

    /// One launch handling one payload. `dies` stands for the app being killed while building.
    private func launch(queueDirectory: URL, allowed: Bool = true, dies: Bool = false) -> Step {
        let seen = DiagnosticSeenIDs(file: directory.appendingPathComponent("seen.txt"))
        let attempts = DiagnosticAttempts(file: directory.appendingPathComponent("attempts.txt"))
        let queue = DiagnosticQueue(directory: queueDirectory)
        if seen.contains(id) { return .skippedSeen }
        if !allowed { _ = seen.insert(id); return .switchedOff }
        guard attempts.begin(id) else { _ = seen.insert(id); return .gaveUp }
        if dies { return .died }
        if queue.add(B8.report(1).with(id: id)) {
            _ = seen.insert(id)
            attempts.finish(id)
            return .saved
        }
        attempts.finish(id)
        return .notSaved
    }

    private var goodQueue: URL { directory.appendingPathComponent("queue", isDirectory: true) }

    func testASavedReportIsRememberedAndNotQueuedAgain() {
        XCTAssertEqual(launch(queueDirectory: goodQueue), .saved)
        XCTAssertEqual(launch(queueDirectory: goodQueue), .skippedSeen)
        XCTAssertEqual(DiagnosticQueue(directory: goodQueue).pending().count, 1)
    }

    func testAPayloadThatKillsTheAppIsGivenUpOnAfterTwoLaunches() {
        XCTAssertEqual(launch(queueDirectory: goodQueue, dies: true), .died)
        XCTAssertEqual(launch(queueDirectory: goodQueue, dies: true), .died)
        XCTAssertEqual(launch(queueDirectory: goodQueue, dies: true), .gaveUp)
        XCTAssertEqual(launch(queueDirectory: goodQueue), .skippedSeen, "given up means seen: never tried again")
        XCTAssertEqual(DiagnosticQueue(directory: goodQueue).pending(), [])
    }

    func testAPayloadThatKillsTheAppOnceStillGetsThroughOnTheNextLaunch() {
        XCTAssertEqual(launch(queueDirectory: goodQueue, dies: true), .died)
        XCTAssertEqual(launch(queueDirectory: goodQueue), .saved)
    }

    func testAPlainSaveFailureDoesNotUseUpTriesAndStaysUnseen() throws {
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let broken = blocker.appendingPathComponent("queue", isDirectory: true)
        for _ in 0..<5 { XCTAssertEqual(launch(queueDirectory: broken), .notSaved, "the disk is full, every launch") }
        XCTAssertFalse(DiagnosticSeenIDs(file: directory.appendingPathComponent("seen.txt")).contains(id), "lost for good would be the bug")
        // The disk has room again: the same payload is saved, then remembered.
        XCTAssertEqual(launch(queueDirectory: goodQueue), .saved)
        XCTAssertTrue(DiagnosticSeenIDs(file: directory.appendingPathComponent("seen.txt")).contains(id))
    }

    func testAFinishedPayloadStartsFromZeroTriesIfItIsEverMetAgain() {
        XCTAssertEqual(launch(queueDirectory: goodQueue, dies: true), .died)
        XCTAssertEqual(launch(queueDirectory: goodQueue), .saved)
        let attempts = DiagnosticAttempts(file: directory.appendingPathComponent("attempts.txt"))
        XCTAssertTrue(attempts.begin(id))
        XCTAssertTrue(attempts.begin(id))
        XCTAssertFalse(attempts.begin(id))
    }

    func testWithTheSwitchOffTheIdIsRememberedWithoutATry() {
        XCTAssertEqual(launch(queueDirectory: goodQueue, allowed: false), .switchedOff)
        XCTAssertEqual(launch(queueDirectory: goodQueue), .skippedSeen, "a report that arrived while it was off does not appear later")
        XCTAssertEqual(DiagnosticQueue(directory: goodQueue).pending(), [])
        let attempts = DiagnosticAttempts(file: directory.appendingPathComponent("attempts.txt"), maxTries: 1)
        XCTAssertTrue(attempts.begin(id), "no try was spent")
    }
}

private extension DiagnosticReport {
    func with(id: UUID) -> DiagnosticReport {
        var copy = self
        copy.id = id
        return copy
    }
}

// MARK: F6: crumbs only on the one live crash

final class Build8Fix2CrumbPolicyTests: XCTestCase {
    func testOneLiveCrashGetsTheCrumbs() {
        XCTAssertTrue(DiagnosticPolicy.attachCrumbs(crashCount: 1, live: true))
    }

    func testTwoOrMoreCrashesInOneCallGetNone() {
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 2, live: true))
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 3, live: true))
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 1000, live: true))
    }

    func testAPastPayloadNeverGetsCrumbs() {
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 1, live: false))
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 2, live: false))
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 0, live: false))
    }

    func testNoCrashAtAllMeansNoCrumbsAndNegativeIsNotACrash() {
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: 0, live: true))
        XCTAssertFalse(DiagnosticPolicy.attachCrumbs(crashCount: -1, live: true))
    }

    func testTheWholeTable() {
        for count in -2...5 {
            for live in [true, false] {
                XCTAssertEqual(DiagnosticPolicy.attachCrumbs(crashCount: count, live: live), live && count == 1, "\(count) \(live)")
            }
        }
    }

    func testTheBuilderStillOnlyGivesCrumbsToACrashAndPassesWhatItIsHanded() {
        let json = Data("{\"diagnosticMetaData\":{\"signal\":11}}".utf8)
        let crash = DiagnosticReportBuilder.diagnostic(
            kind: .crash, json: json, id: UUID(), at: B8.date(0), now: B8.date(1), running: .fix2, crumbs: ["a", "b"])
        XCTAssertEqual(crash.crumbs, ["a", "b"])
        let none = DiagnosticReportBuilder.diagnostic(
            kind: .crash, json: json, id: UUID(), at: B8.date(0), now: B8.date(1), running: .fix2, crumbs: [])
        XCTAssertEqual(none.crumbs, [])
        let hang = DiagnosticReportBuilder.diagnostic(
            kind: .hang, json: json, id: UUID(), at: B8.date(0), now: B8.date(1), running: .fix2, crumbs: ["a"])
        XCTAssertEqual(hang.crumbs, [])
    }
}

// MARK: F8: the test line knows what was really sent

final class Build8Fix2TestLineTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "22222222-0000-4000-8000-000000000002")!

    func testNilSentIDsKeepsTodaysBehaviour() {
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: []), .sent)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], sentIDs: nil), .sent)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [other], refusedIDs: [], unsavedIDs: [], sentIDs: nil), .sent)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [id], sentIDs: nil), .waiting)
    }

    func testAnIdThatIsGoneAndWasSentIsSent() {
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], sentIDs: [id]), .sent)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [other], sentIDs: [id, other]), .sent)
    }

    func testAnIdThatIsGoneAndWasNeverSentIsNotSaved() {
        // The report was evicted from a full queue, or removed some other way: it was not sent.
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], sentIDs: []), .notSaved)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [other], sentIDs: [other]), .notSaved)
    }

    func testPendingStillWinsWhateverSentIDsSays() {
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [id], sentIDs: []), .waiting)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [id], sentIDs: [id]), .waiting)
    }

    func testRefusedAndUnsavedStillWinOverSent() {
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], refusedIDs: [id], sentIDs: []), .refused)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], refusedIDs: [id], sentIDs: [id]), .refused)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], unsavedIDs: [id], sentIDs: [id]), .notSaved)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], refusedIDs: [id], unsavedIDs: [id], sentIDs: []), .refused,
                       "refused comes before unsaved, as before")
    }

    func testNoTestMeansNoLineWhateverSentIDsSays() {
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: nil, pendingIDs: [], sentIDs: []), .none)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: nil, pendingIDs: [id], sentIDs: [id]), .none)
    }

    func testTheTextsFollowTheCases() {
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], sentIDs: [id]).text, "Sent.")
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: id, pendingIDs: [], sentIDs: []).text, "Couldn't save the report.")
    }

    func testEvictionFromAFullQueueReadsNotSavedNotSent() {
        // Offline, one test report, then 20 newer reports: the 20-file limit drops the test report.
        let directory = try! B8.tempDirectory("fix2-evict")
        defer { B8.remove(directory) }
        let queue = DiagnosticQueue(directory: directory, maxFiles: 20)
        let test = B8.report(1, at: 1, kind: .test)
        queue.add(test)
        for n in 2...21 { queue.add(B8.report(n, at: TimeInterval(n))) }
        let pending = Set(queue.pending().map(\.id))
        XCTAssertFalse(pending.contains(test.id))
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: test.id, pendingIDs: pending, sentIDs: []), .notSaved)
        XCTAssertEqual(DiagnosticPolicy.testLine(lastTestID: test.id, pendingIDs: pending, sentIDs: [test.id]), .sent)
    }
}
