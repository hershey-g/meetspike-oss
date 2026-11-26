import Foundation
import XCTest
@testable import MeetspikeHRCore

// Ask track fix pass, regression tests: saved chat lives in files (one per mode) instead of UserDefaults, the one-time
// migration of the old UserDefaults copy, the date scope a chat opens with, and what is announced when an answer ends.

final class AskFixTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ask-fix-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        // Restore permissions first so cleanup can delete anything a test locked.
        if let root {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if let walker = FileManager.default.enumerator(atPath: root.path) {
                for case let sub as String in walker {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(sub).path)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        defaults?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Helpers

    private let display = SourceDisplay.make(oura: true, whoop: true)

    private func chat(_ answer: String = "You had 4 meetings.") -> AskSavedChat {
        AskSavedChat(sourceDisplay: display, turns: [
            AskTurn(role: .user, content: "How was Tuesday?"),
            AskTurn(role: .assistant, content: answer),
        ])
    }

    private func store(demo: Bool, in dir: URL? = nil) -> AskChatStore {
        AskChatStore(directory: dir ?? root, isDemo: demo)
    }

    private func encoded(_ saved: AskSavedChat) throws -> Data { try JSONEncoder().encode(saved) }

    // MARK: Store round trip

    func testSaveThenLoadReturnsTheSameTurns() throws {
        let real = store(demo: false)
        let saved = chat()
        try real.save(saved)
        let loaded = try XCTUnwrap(real.load())
        XCTAssertEqual(loaded.turns, saved.turns)
        XCTAssertEqual(loaded.sourceDisplay, display)
    }

    func testFileNamesDifferByMode() {
        XCTAssertEqual(store(demo: false).fileURL.lastPathComponent, "ask-chat.json")
        XCTAssertEqual(store(demo: true).fileURL.lastPathComponent, "ask-chat-demo.json")
    }

    func testRealAndDemoDoNotShareAFile() throws {
        let real = store(demo: false)
        let demo = store(demo: true)
        try real.save(chat("real answer"))
        XCTAssertNil(demo.load(), "saving the real chat must not show up in demo mode")
        try demo.save(chat("demo answer"))
        XCTAssertEqual(real.load()?.turns.last?.content, "real answer")
        XCTAssertEqual(demo.load()?.turns.last?.content, "demo answer")
    }

    func testClearRemovesOnlyThatModesChat() throws {
        let real = store(demo: false)
        let demo = store(demo: true)
        try real.save(chat("real answer"))
        try demo.save(chat("demo answer"))
        real.clear()
        XCTAssertNil(real.load())
        XCTAssertEqual(demo.load()?.turns.last?.content, "demo answer")
        real.clear() // a missing file is fine
        XCTAssertNil(real.load())
    }

    func testLoadWithNoFileOrACorruptFileIsNil() throws {
        let real = store(demo: false)
        XCTAssertNil(real.load())
        try Data("not json".utf8).write(to: real.fileURL)
        XCTAssertNil(real.load())
    }

    // MARK: Migration

    func testMigrationMovesBothChatsOutOfDefaults() throws {
        let dir = root.appendingPathComponent("Meetspike", isDirectory: true)
        defaults.set(try encoded(chat("real answer")), forKey: AskChatStore.realKey)
        defaults.set(try encoded(chat("demo answer")), forKey: AskChatStore.demoKey)

        let removed = AskChatStore.migrateLegacy(from: defaults, into: dir)

        XCTAssertEqual(removed, 2)
        XCTAssertNil(defaults.object(forKey: AskChatStore.realKey), "the plaintext copy must not stay in defaults")
        XCTAssertNil(defaults.object(forKey: AskChatStore.demoKey))
        let real = store(demo: false, in: dir)
        let demo = store(demo: true, in: dir)
        XCTAssertEqual(real.load()?.turns, chat("real answer").turns)
        XCTAssertEqual(demo.load()?.turns, chat("demo answer").turns)
        XCTAssertFalse(real.load()?.turns.contains { $0.content == "demo answer" } ?? true, "demo data must not land in the real file")
    }

    func testMigrationRemovesGarbageAndCreatesNoFile() {
        let dir = root.appendingPathComponent("Meetspike", isDirectory: true)
        defaults.set(Data("garbage, not a chat".utf8), forKey: AskChatStore.realKey)

        let removed = AskChatStore.migrateLegacy(from: defaults, into: dir)

        XCTAssertEqual(removed, 1)
        XCTAssertNil(defaults.object(forKey: AskChatStore.realKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store(demo: false, in: dir).fileURL.path))
        XCTAssertNil(store(demo: false, in: dir).load())
    }

    func testMigrationWithNothingInDefaultsDoesNothing() {
        let dir = root.appendingPathComponent("Meetspike", isDirectory: true)
        XCTAssertEqual(AskChatStore.migrateLegacy(from: defaults, into: dir), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testMigrationRemovesAValueOfTheWrongType() {
        let dir = root.appendingPathComponent("Meetspike", isDirectory: true)
        defaults.set("a string, not Data", forKey: AskChatStore.realKey)
        XCTAssertEqual(AskChatStore.migrateLegacy(from: defaults, into: dir), 1)
        XCTAssertNil(defaults.object(forKey: AskChatStore.realKey))
    }

    func testMigrationNeverOverwritesAnExistingFile() throws {
        let dir = root.appendingPathComponent("Meetspike", isDirectory: true)
        let real = store(demo: false, in: dir)
        try real.save(chat("newer answer from the file"))
        defaults.set(try encoded(chat("older answer from defaults")), forKey: AskChatStore.realKey)

        let removed = AskChatStore.migrateLegacy(from: defaults, into: dir)

        XCTAssertEqual(removed, 1)
        XCTAssertNil(defaults.object(forKey: AskChatStore.realKey), "the old copy is still removed")
        XCTAssertEqual(real.load()?.turns.last?.content, "newer answer from the file")
    }

    func testMigrationKeepsTheOldCopyWhenTheFileCannotBeWritten() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions")
        let dir = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defaults.set(try encoded(chat("do not lose me")), forKey: AskChatStore.realKey)

        let removed = AskChatStore.migrateLegacy(from: defaults, into: dir)

        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(defaults.data(forKey: AskChatStore.realKey), "no chat is lost when the write fails")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store(demo: false, in: dir).fileURL.path))
    }

    func testMigrationRunTwiceIsHarmless() throws {
        let dir = root.appendingPathComponent("Meetspike", isDirectory: true)
        defaults.set(try encoded(chat()), forKey: AskChatStore.realKey)
        XCTAssertEqual(AskChatStore.migrateLegacy(from: defaults, into: dir), 1)
        XCTAssertEqual(AskChatStore.migrateLegacy(from: defaults, into: dir), 0)
        XCTAssertEqual(store(demo: false, in: dir).load()?.turns, chat().turns)
    }

    // MARK: Scope

    private let dates = (start: "2026-11-01", end: "2026-11-14")
    private let people = (start: "2026-10-01", end: "2026-10-07")

    func testScopeFromDatesTabUsesTheDatesRange() {
        let scope = AskScope.forVisit(from: .dates, dates: dates, people: people)
        XCTAssertEqual(scope?.start, "2026-11-01")
        XCTAssertEqual(scope?.end, "2026-11-14")
    }

    func testScopeFromPeopleTabUsesThePeopleRange() {
        let scope = AskScope.forVisit(from: .people, dates: dates, people: people)
        XCTAssertEqual(scope?.start, "2026-10-01")
        XCTAssertEqual(scope?.end, "2026-10-07")
    }

    func testScopeFromPeopleTabWithNoPeopleRangeIsNil() {
        XCTAssertNil(AskScope.forVisit(from: .people, dates: dates, people: nil))
    }

    func testScopeFromAnyOtherTabIsNil() {
        XCTAssertNil(AskScope.forVisit(from: .other, dates: dates, people: people))
    }

    func testScopeIsNilForARangeThatIsNotRealDays() {
        XCTAssertNil(AskScope.forVisit(from: .dates, dates: (start: "nope", end: "2026-11-14"), people: nil))
    }

    func testOriginFromTabName() {
        XCTAssertEqual(AskOrigin(tabName: "dates"), .dates)
        XCTAssertEqual(AskOrigin(tabName: "people"), .people)
        XCTAssertEqual(AskOrigin(tabName: "more"), .other)
        XCTAssertEqual(AskOrigin(tabName: nil), .other)
        XCTAssertEqual(AskOrigin(tabName: "ask"), .other)
    }

    // MARK: Announcement

    private func answer(_ content: String = "Four meetings.", error: String? = nil, interrupted: Bool = false) -> AskChatTurn {
        AskChatTurn(id: 1, role: .assistant, content: content, interrupted: interrupted, error: error)
    }

    func testNormalAnswerIsAnnounced() {
        XCTAssertEqual(AskAnnouncement.message(for: answer(), hadKeyProblem: false, askTabSelected: true), "Answer ready.")
    }

    func testKeyProblemIsQuiet() {
        XCTAssertNil(AskAnnouncement.message(for: answer(), hadKeyProblem: true, askTabSelected: true))
    }

    func testAnotherTabOnScreenIsQuiet() {
        XCTAssertNil(AskAnnouncement.message(for: answer(), hadKeyProblem: false, askTabSelected: false))
    }

    func testErrorTurnAnnouncesItsError() {
        let turn = answer("", error: "Claude is busy. Try again.")
        XCTAssertEqual(AskAnnouncement.message(for: turn, hadKeyProblem: false, askTabSelected: true), "Claude is busy. Try again.")
    }

    func testInterruptedTurnAnnouncesTheDroppedConnection() {
        let turn = answer("Partial", interrupted: true)
        XCTAssertEqual(
            AskAnnouncement.message(for: turn, hadKeyProblem: false, askTabSelected: true),
            "The connection dropped. The answer is incomplete. You can try again.")
    }

    func testNothingToAnnounceForNoTurnAUserTurnOrEmptyText() {
        XCTAssertNil(AskAnnouncement.message(for: nil, hadKeyProblem: false, askTabSelected: true))
        let user = AskChatTurn(id: 0, role: .user, content: "Hi")
        XCTAssertNil(AskAnnouncement.message(for: user, hadKeyProblem: false, askTabSelected: true))
        XCTAssertNil(AskAnnouncement.message(for: answer(""), hadKeyProblem: false, askTabSelected: true))
    }
}
