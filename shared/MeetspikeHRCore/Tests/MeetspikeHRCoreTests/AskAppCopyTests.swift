import XCTest
@testable import MeetspikeHRCore

/// The Worker says "in More" (the web tab). The iPhone calls it "Menu". Error and failure text is rewritten on the
/// way to the screen; answer text never is.
final class AskAppCopyTests: XCTestCase {
    private let keyText = "Add your Claude API key in More, then ask again."
    private let keyTextMenu = "Add your Claude API key in Menu, then ask again."

    // MARK: appCopy

    func testAppCopyRewritesInMoreToInMenu() {
        XCTAssertEqual(AskLogic.appCopy(keyText), keyTextMenu)
    }

    func testAppCopyRewritesEveryOccurrence() {
        XCTAssertEqual(
            AskLogic.appCopy("Set the key in More. Still stuck? Look in More again."),
            "Set the key in Menu. Still stuck? Look in Menu again.")
    }

    func testAppCopyRewritesAtStartAndEnd() {
        XCTAssertEqual(AskLogic.appCopy("in More"), "in Menu")
        XCTAssertEqual(AskLogic.appCopy("Fix it in More"), "Fix it in Menu")
        XCTAssertEqual(AskLogic.appCopy("in More, now"), "in Menu, now")
    }

    func testAppCopyLeavesLongerWordsAlone() {
        XCTAssertEqual(AskLogic.appCopy("It was in Moreover a test"), "It was in Moreover a test")
        XCTAssertEqual(AskLogic.appCopy("Flights to Morelia"), "Flights to Morelia")
        XCTAssertEqual(AskLogic.appCopy("He lives in Morelia"), "He lives in Morelia")
        XCTAssertEqual(AskLogic.appCopy("Ask in more detail"), "Ask in more detail")
    }

    func testAppCopyBoundaryBlocksOnlyTheLongerWord() {
        XCTAssertEqual(AskLogic.appCopy("in Moreover and in More"), "in Moreover and in Menu")
    }

    func testAppCopyEmptyStaysEmpty() {
        XCTAssertEqual(AskLogic.appCopy(""), "")
    }

    func testAppCopyLeavesTextWithoutTheWordsAlone() {
        XCTAssertEqual(AskLogic.appCopy("Something went wrong (500)."), "Something went wrong (500).")
    }

    // MARK: session

    private func streaming(_ question: String = "How was my week?") -> AskChatSession {
        var session = AskChatSession()
        session.send(question)
        return session
    }

    func testStreamErrorEndsWithMenuCopy() {
        var session = streaming()
        session.apply(.error(AskFailure(message: keyText)))
        let turn = session.turns.last
        XCTAssertEqual(turn?.error, keyTextMenu)
        XCTAssertTrue(turn?.error?.contains("in Menu") ?? false)
        XCTAssertFalse(turn?.error?.contains("in More") ?? true)
        XCTAssertEqual(turn?.isStreaming, false)
        XCTAssertNil(session.keyProblem)
    }

    func testStreamErrorNeedsKeySetsKeyProblemWithMenuCopy() {
        var session = streaming()
        session.apply(.error(AskFailure(message: keyText, needsKey: true)))
        XCTAssertEqual(session.keyProblem, keyTextMenu)
        XCTAssertTrue(session.turns.isEmpty, "question and answer are removed on a key problem")
    }

    func testFailEndsWithMenuCopy() {
        var session = streaming()
        session.fail(message: keyText)
        XCTAssertEqual(session.turns.last?.error, keyTextMenu)
        XCTAssertEqual(session.turns.last?.isStreaming, false)
    }

    func testFailNeedsKeySetsKeyProblemWithMenuCopy() {
        var session = streaming()
        session.fail(message: keyText, needsKey: true)
        XCTAssertEqual(session.keyProblem, keyTextMenu)
        XCTAssertTrue(session.turns.isEmpty)
    }

    func testErrorKeepsAlreadyStreamedTextUnchanged() {
        var session = streaming()
        session.apply(.text("Partial answer in More detail, or in More"))
        session.apply(.error(AskFailure(message: "Check it in More.")))
        XCTAssertEqual(session.turns.last?.content, "Partial answer in More detail, or in More")
        XCTAssertEqual(session.turns.last?.error, "Check it in Menu.")
    }

    func testAnswerTextIsNeverRewritten() {
        var session = streaming("Where do I set the key?")
        session.apply(.text("Open the web app and look in More"))
        session.apply(.text(", then in More again."))
        session.apply(.done(AskDone()))
        XCTAssertEqual(session.turns.last?.content, "Open the web app and look in More, then in More again.")
        XCTAssertNil(session.turns.last?.error)
    }

    // MARK: announcement

    func testAnnouncementSaysMenuForAnError() {
        var session = streaming()
        session.apply(.error(AskFailure(message: keyText)))
        XCTAssertEqual(
            AskAnnouncement.message(for: session.turns.last, hadKeyProblem: false, askTabSelected: true),
            keyTextMenu)
    }

    func testAnnouncementRewritesRawWorkerErrorText() {
        let turn = AskChatTurn(id: 1, role: .assistant, error: "Open it in More and in More.")
        XCTAssertEqual(
            AskAnnouncement.message(for: turn, hadKeyProblem: false, askTabSelected: true),
            "Open it in Menu and in Menu.")
    }

    func testAnnouncementForAnswerIsNotItsText() {
        let turn = AskChatTurn(id: 1, role: .assistant, content: "Look in More")
        XCTAssertEqual(
            AskAnnouncement.message(for: turn, hadKeyProblem: false, askTabSelected: true), "Answer ready.")
    }
}

/// User-facing API error copy names the phone's tab: Menu, never More.
final class APIErrorCopyTests: XCTestCase {
    func testAccessRejectedSaysMenu() {
        let text = APIError.accessRejected.message
        XCTAssertTrue(text.contains("Menu"), text)
        XCTAssertFalse(text.contains("More"), text)
    }

    func testNotConfiguredSaysMenu() {
        let text = APIError.notConfigured.message
        XCTAssertTrue(text.contains("Menu"), text)
        XCTAssertFalse(text.contains("More"), text)
    }

    func testNoFixedAPIErrorMessageSaysMore() {
        let all: [APIError] = [.accessRejected, .offline, .decoding("x"), .invalidRequest("x"), .notConfigured]
        for error in all { XCTAssertFalse(error.message.contains("More"), error.message) }
    }
}
