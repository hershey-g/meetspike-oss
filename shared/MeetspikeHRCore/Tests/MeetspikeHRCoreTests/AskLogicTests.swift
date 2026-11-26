import Foundation
import XCTest
@testable import MeetspikeHRCore

// Ask track: history trimming, mini Markdown, chat session reducer.
// Mirrors cleanTurns, md, applyStep, applyAskEvent and endAskStream in public/ask-logic.js, and the send flow in
// public/ask-panel.js.

private func user(_ text: String) -> AskTurn { AskTurn(role: .user, content: text) }
private func assistant(_ text: String) -> AskTurn { AskTurn(role: .assistant, content: text) }

/// u0, a1, u2, a3 ... n turns, starting with the user.
private func conversation(_ n: Int) -> [AskTurn] {
    (0..<n).map { $0 % 2 == 0 ? user("turn \($0)") : assistant("turn \($0)") }
}

final class AskHistoryTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(AskHistory.maxSentTurns, 12)
        XCTAssertEqual(AskHistory.maxTurnChars, 8000)
        XCTAssertEqual(AskHistory.maxStoredTurns, 30)
    }

    func testShortConversationIsSentAsIs() {
        let turns = [user("hi"), assistant("hello"), user("more")]
        XCTAssertEqual(AskHistory.cleaned(turns), turns)
    }

    func testEmptyHistory() {
        XCTAssertEqual(AskHistory.cleaned([]), [])
    }

    func testOnlyTheLastTwelveTurnsAreSent() {
        let sent = AskHistory.cleaned(conversation(20))
        XCTAssertEqual(sent.count, 12)
        XCTAssertEqual(sent.first?.content, "turn 8")
        XCTAssertEqual(sent.last?.content, "turn 19")
    }

    func testExactlyTwelveTurnsAreAllSent() {
        XCTAssertEqual(AskHistory.cleaned(conversation(12)), conversation(12))
    }

    func testHistoryStartsWithTheUserSoALeadingAnswerIsDropped() {
        // 13 turns: the last 12 would start with an assistant turn.
        let sent = AskHistory.cleaned(conversation(13))
        XCTAssertEqual(sent.count, 11)
        XCTAssertEqual(sent.first?.role, .user)
        XCTAssertEqual(sent.first?.content, "turn 2")
    }

    func testOnlyAssistantTurnsLeaveNothing() {
        XCTAssertEqual(AskHistory.cleaned([assistant("a"), assistant("b")]), [])
    }

    func testBlankTurnsAreDropped() {
        let sent = AskHistory.cleaned([user("hi"), assistant("   "), user(""), assistant("\n\t"), user("again")])
        XCTAssertEqual(sent, [user("hi"), user("again")])
    }

    func testBlankTurnsDoNotUseUpTheTwelveSlots() {
        var turns = conversation(12)
        turns.insert(contentsOf: [user(" "), assistant("")], at: 6)
        XCTAssertEqual(AskHistory.cleaned(turns), conversation(12))
    }

    func testEachTurnIsCutToEightThousandCharacters() {
        let long = String(repeating: "a", count: 9000)
        let sent = AskHistory.cleaned([user(long), assistant(long)])
        XCTAssertEqual(sent.map(\.content.count), [8000, 8000])
        XCTAssertEqual(sent.first?.content, String(repeating: "a", count: 8000))
    }

    func testAnEightThousandCharacterTurnIsKeptWhole() {
        let exact = String(repeating: "b", count: 8000)
        XCTAssertEqual(AskHistory.cleaned([user(exact)]), [user(exact)])
    }

    func testCustomMax() {
        XCTAssertEqual(AskHistory.cleaned(conversation(10), max: 4), [user("turn 6"), assistant("turn 7"), user("turn 8"), assistant("turn 9")])
        XCTAssertEqual(AskHistory.cleaned(conversation(10), max: 3).first?.role, .user)
    }

    func testStoredKeepsTheLastThirty() {
        let stored = AskHistory.stored(conversation(40))
        XCTAssertEqual(stored.count, 30)
        XCTAssertEqual(stored.first?.content, "turn 10")
        XCTAssertEqual(stored.last?.content, "turn 39")
    }

    func testStoredDropsBlankTurnsButDoesNotCut() {
        let long = String(repeating: "c", count: 9000)
        let stored = AskHistory.stored([user("hi"), assistant(" "), assistant(long)])
        XCTAssertEqual(stored, [user("hi"), assistant(long)])
    }

    func testStoredKeepsALeadingAnswer() {
        XCTAssertEqual(AskHistory.stored([assistant("a"), user("b")]), [assistant("a"), user("b")])
    }
}

final class AskMarkdownTests: XCTestCase {
    func testPlainTextIsOneParagraph() {
        XCTAssertEqual(AskMarkdown.blocks("Just words."), [.paragraph([.text("Just words.")])])
    }

    func testEmptyTextHasNoBlocks() {
        XCTAssertEqual(AskMarkdown.blocks(""), [])
        XCTAssertEqual(AskMarkdown.blocks("\n\n  \n"), [])
    }

    func testBoldRuns() {
        XCTAssertEqual(AskMarkdown.blocks("Hello **world**"), [.paragraph([.text("Hello "), .bold("world")])])
        XCTAssertEqual(AskMarkdown.blocks("**Lead** then text"), [.paragraph([.bold("Lead"), .text(" then text")])])
        XCTAssertEqual(
            AskMarkdown.blocks("**a** and **b**"), [.paragraph([.bold("a"), .text(" and "), .bold("b")])])
    }

    func testAnUnclosedBoldMarkerStaysText() {
        XCTAssertEqual(AskMarkdown.blocks("use **carefully"), [.paragraph([.text("use **carefully")])])
    }

    func testLinesInAParagraphAreJoinedWithBreaks() {
        XCTAssertEqual(AskMarkdown.blocks("one\ntwo"), [.paragraph([.text("one"), .lineBreak, .text("two")])])
    }

    func testBlankLinesSeparateParagraphs() {
        XCTAssertEqual(
            AskMarkdown.blocks("first\n\nsecond"), [.paragraph([.text("first")]), .paragraph([.text("second")])])
    }

    func testCarriageReturnsAreIgnored() {
        XCTAssertEqual(AskMarkdown.blocks("one\r\ntwo\r\n\r\nthree"), AskMarkdown.blocks("one\ntwo\n\nthree"))
        XCTAssertEqual(AskMarkdown.blocks("one\r\ntwo"), [.paragraph([.text("one"), .lineBreak, .text("two")])])
    }

    func testDashAndStarBullets() {
        XCTAssertEqual(AskMarkdown.blocks("- one\n- two"), [.bullets([[.text("one")], [.text("two")]])])
        XCTAssertEqual(AskMarkdown.blocks("* one\n* two"), [.bullets([[.text("one")], [.text("two")]])])
        XCTAssertEqual(AskMarkdown.blocks("- one\n* two"), [.bullets([[.text("one")], [.text("two")]])])
    }

    func testBulletsCanBeBold() {
        XCTAssertEqual(
            AskMarkdown.blocks("- **Mon** was rough\n- Tue was fine"),
            [.bullets([[.bold("Mon"), .text(" was rough")], [.text("Tue was fine")]])])
    }

    func testBulletsRightAfterAParagraph() {
        XCTAssertEqual(
            AskMarkdown.blocks("Intro\n- a\n- b\nOutro"),
            [.paragraph([.text("Intro")]), .bullets([[.text("a")], [.text("b")]]), .paragraph([.text("Outro")])])
    }

    func testADashWithoutASpaceIsNotABullet() {
        XCTAssertEqual(AskMarkdown.blocks("-5 points"), [.paragraph([.text("-5 points")])])
    }

    func testPipeTableDropsTheRuleRow() {
        let text = """
        | Day | Score |
        |---|---|
        | Mon | **70** |
        | Tue | 60 |
        """
        XCTAssertEqual(AskMarkdown.blocks(text), [
            .table(
                header: [[.text("Day")], [.text("Score")]],
                rows: [[[.text("Mon")], [.bold("70")]], [[.text("Tue")], [.text("60")]]]),
        ])
    }

    func testAlignedRuleRowIsDroppedToo() {
        let text = "| A | B |\n| :--- | ---: |\n| 1 | 2 |"
        XCTAssertEqual(AskMarkdown.blocks(text), [
            .table(header: [[.text("A")], [.text("B")]], rows: [[[.text("1")], [.text("2")]]]),
        ])
    }

    func testTableBetweenParagraphs() {
        let text = "Here:\n| A | B |\n|---|---|\n| 1 | 2 |\n\nDone."
        XCTAssertEqual(AskMarkdown.blocks(text), [
            .paragraph([.text("Here:")]),
            .table(header: [[.text("A")], [.text("B")]], rows: [[[.text("1")], [.text("2")]]]),
            .paragraph([.text("Done.")]),
        ])
    }

    func testTableWithOnlyAHeader() {
        XCTAssertEqual(AskMarkdown.blocks("| A | B |\n|---|---|"), [.table(header: [[.text("A")], [.text("B")]], rows: [])])
    }

    func testMarkupIsNotInterpretedBeyondBold() {
        XCTAssertEqual(AskMarkdown.blocks("<b>x</b> & *y*"), [.paragraph([.text("<b>x</b> & *y*")])])
    }
}

final class AskSessionTests: XCTestCase {
    /// Safe lookup: a missing turn fails the test instead of crashing the whole run.
    private func turn(_ session: AskChatSession, _ index: Int, line: UInt = #line) -> AskChatTurn {
        guard session.turns.indices.contains(index) else {
            XCTFail("expected a turn at \(index), chat has \(session.turns.count)", line: line)
            return AskChatTurn(id: -1, role: .assistant)
        }
        return session.turns[index]
    }

    private func step(_ id: String, _ label: String, done: Bool = false) -> AskEvent {
        .step(AskStep(id: id, label: label, status: done ? .done : .active))
    }

    /// A session that has asked one question and is waiting on the answer.
    private func streaming(_ question: String = "How was my week?") -> AskChatSession {
        var session = AskChatSession()
        session.send(question)
        return session
    }

    // MARK: send

    func testSendAppendsTheQuestionAndAnEmptyStreamingAnswer() {
        var session = AskChatSession()
        let history = session.send("How was my week?")
        XCTAssertEqual(history, [AskTurn]())
        XCTAssertEqual(session.turns.count, 2)
        XCTAssertEqual(Set(session.turns.map(\.id)).count, 2, "turn ids are unique")
        XCTAssertEqual(turn(session, 0).role, .user)
        XCTAssertEqual(turn(session, 0).content, "How was my week?")
        XCTAssertFalse(turn(session, 0).isStreaming)
        XCTAssertEqual(turn(session, 1).role, .assistant)
        XCTAssertEqual(turn(session, 1).content, "")
        XCTAssertTrue(turn(session, 1).isStreaming)
        XCTAssertTrue(session.isStreaming)
    }

    func testBlankQuestionIsIgnored() {
        var session = AskChatSession()
        XCTAssertNil(session.send(""))
        XCTAssertNil(session.send("   \n "))
        XCTAssertEqual(session.turns, [])
        XCTAssertFalse(session.isStreaming)
    }

    func testQuestionIsTrimmed() {
        var session = AskChatSession()
        session.send("  hello  ")
        XCTAssertEqual(session.turns.first?.content, "hello")
    }

    func testALongQuestionIsShownInFull() {
        // The web never cuts the user's own bubble; the Worker trims what it reads.
        var session = AskChatSession()
        let long = String(repeating: "q", count: 2500)
        session.send("  \(long)  ")
        XCTAssertEqual(session.turns.first?.content, long)
    }

    func testSendWhileStreamingIsIgnored() {
        var session = streaming()
        XCTAssertNil(session.send("another"))
        XCTAssertEqual(session.turns.count, 2)
    }

    func testSecondQuestionSendsTheFinishedExchangeAsHistory() {
        var session = streaming("Q1")
        session.apply(.text("A1"))
        session.apply(.done(AskDone()))
        let history = session.send("Q2")
        XCTAssertEqual(history, [user("Q1"), assistant("A1")])
        XCTAssertEqual(session.turns.count, 4)
        XCTAssertEqual(Set(session.turns.map(\.id)).count, 4, "turn ids are unique")
        XCTAssertTrue(turn(session, 3).isStreaming)
    }

    func testFailedAnswersAreLeftOutOfHistory() {
        var session = streaming("Q1")
        session.apply(.error(AskFailure(message: "Boom")))
        let history = session.send("Q2")
        XCTAssertEqual(history, [user("Q1")])
    }

    func testAnswersWithNoTextAreLeftOutOfHistory() {
        var session = streaming("Q1")
        session.stop()
        XCTAssertEqual(session.send("Q2"), [user("Q1")])
    }

    func testHistorySentIsTrimmedToTwelveTurns() {
        var session = AskChatSession(restoring: conversation(30))
        let history = session.send("next")
        XCTAssertEqual(history?.count, 12)
        XCTAssertEqual(history?.first?.role, .user)
        XCTAssertEqual(history?.last?.content, "turn 29")
    }

    // MARK: events

    func testStepsAreAddedInOrderAndUpdatedInPlace() {
        var session = streaming()
        session.apply(step("s1", "Reading your calendar"))
        session.apply(step("s2", "Checking your sleep"))
        session.apply(step("s1", "Reading your calendar", done: true))
        let steps = turn(session, 1).steps
        XCTAssertEqual(steps.map(\.id), ["s1", "s2"])
        XCTAssertEqual(steps.map(\.status), [.done, .active])
        XCTAssertEqual(steps.map(\.label), ["Reading your calendar", "Checking your sleep"])
    }

    func testTextDeltasAppend() {
        var session = streaming()
        session.apply(.text("Your "))
        session.apply(.text("week "))
        session.apply(.text("was busy."))
        XCTAssertEqual(turn(session, 1).content, "Your week was busy.")
        XCTAssertTrue(turn(session, 1).isStreaming)
        XCTAssertEqual(turn(session, 0).content, "How was my week?")
    }

    func testDoneCopiesTheSummaryAndStops() {
        var session = streaming()
        session.apply(.text("Done text"))
        session.apply(.done(AskDone(
            truncated: true, interrupted: false, refused: false, model: "claude-test", start: "2026-11-01", end: "2026-11-24")))
        let turn = turn(session, 1)
        XCTAssertEqual(turn.content, "Done text")
        XCTAssertFalse(turn.isStreaming)
        XCTAssertTrue(turn.truncated)
        XCTAssertFalse(turn.interrupted)
        XCTAssertFalse(turn.refused)
        XCTAssertEqual(turn.model, "claude-test")
        XCTAssertEqual(turn.start, "2026-11-01")
        XCTAssertEqual(turn.end, "2026-11-24")
        XCTAssertNil(turn.error)
        XCTAssertFalse(session.isStreaming)
    }

    func testDoneCanReportInterruptedAndRefused() {
        var session = streaming()
        session.apply(.done(AskDone(truncated: false, interrupted: true, refused: true)))
        XCTAssertTrue(turn(session, 1).interrupted)
        XCTAssertTrue(turn(session, 1).refused)
        XCTAssertFalse(turn(session, 1).truncated)
    }

    func testErrorKeepsTheTextAndStops() {
        var session = streaming()
        session.apply(.text("Partial answer"))
        session.apply(.error(AskFailure(message: "Rate limited")))
        let turn = turn(session, 1)
        XCTAssertEqual(turn.content, "Partial answer")
        XCTAssertEqual(turn.error, "Rate limited")
        XCTAssertFalse(turn.needsKey)
        XCTAssertFalse(turn.isStreaming)
        XCTAssertFalse(session.isStreaming)
    }

    func testNeedsKeyErrorRemovesTheQuestionAndAnswer() {
        // The web drops both bubbles and returns to the key form (ask-panel.js handleError).
        var session = streaming()
        session.apply(.text("partial"))
        session.apply(.error(AskFailure(message: "Your Claude key was rejected.", needsKey: true)))
        XCTAssertEqual(session.turns, [])
        XCTAssertEqual(session.storedTurns, [])
        XCTAssertFalse(session.isStreaming)
    }

    func testNeedsKeyErrorKeepsEarlierExchanges() {
        var session = streaming("Q1")
        session.apply(.text("A1"))
        session.apply(.done(AskDone()))
        session.send("Q2")
        session.apply(.error(AskFailure(message: "Key rejected", needsKey: true)))
        XCTAssertEqual(session.turns.map(\.content), ["Q1", "A1"])
        XCTAssertEqual(session.storedTurns, [user("Q1"), assistant("A1")])
    }

    func testCutOffMarksTheAnswerInterruptedAndKeepsTheText() {
        var session = streaming()
        session.apply(.text("Half an ans"))
        session.apply(.cutOff)
        let turn = turn(session, 1)
        XCTAssertEqual(turn.content, "Half an ans")
        XCTAssertTrue(turn.interrupted)
        XCTAssertNil(turn.error)
        XCTAssertFalse(turn.isStreaming)
    }

    func testEventsAfterTheEndAreIgnored() {
        var session = streaming()
        session.apply(.text("Final"))
        session.apply(.done(AskDone(model: "m")))
        session.apply(.text(" extra"))
        session.apply(step("late", "Late step"))
        session.apply(.error(AskFailure(message: "late error")))
        session.apply(.cutOff)
        let turn = turn(session, 1)
        XCTAssertEqual(turn.content, "Final")
        XCTAssertEqual(turn.steps, [])
        XCTAssertNil(turn.error)
        XCTAssertFalse(turn.interrupted)
    }

    func testEventsWithNothingStreamingAreIgnored() {
        var session = AskChatSession()
        session.apply(.text("stray"))
        session.apply(.done(AskDone()))
        XCTAssertEqual(session.turns, [])
    }

    func testAnEventNeverTouchesTheQuestion() {
        var session = streaming("Q")
        session.apply(.text("A"))
        XCTAssertEqual(turn(session, 0), AskChatTurn(id: 0, role: .user, content: "Q"))
    }

    // MARK: stop, fail, reset

    func testStopKeepsTheTextAndMarksTheAnswerStopped() {
        var session = streaming()
        session.apply(step("s1", "Reading your calendar"))
        session.apply(.text("So far"))
        session.stop()
        let turn = turn(session, 1)
        XCTAssertEqual(turn.content, "So far")
        XCTAssertTrue(turn.stopped)
        XCTAssertFalse(turn.isStreaming)
        XCTAssertNil(turn.error)
        XCTAssertEqual(turn.steps.map(\.id), ["s1"])
        XCTAssertFalse(session.isStreaming)
    }

    func testEventsAfterStopAreIgnored() {
        var session = streaming()
        session.apply(.text("So far"))
        session.stop()
        session.apply(.text(" more"))
        session.apply(.done(AskDone(model: "m")))
        XCTAssertEqual(turn(session, 1).content, "So far")
        XCTAssertNil(turn(session, 1).model)
    }

    func testStopWithNothingStreamingDoesNothing() {
        var session = streaming()
        session.apply(.text("Answer"))
        session.apply(.done(AskDone()))
        session.stop()
        XCTAssertFalse(turn(session, 1).stopped)
        var fresh = AskChatSession()
        fresh.stop()
        XCTAssertEqual(fresh.turns, [])
    }

    func testFailBeforeAnyEventSetsTheError() {
        var session = streaming()
        session.fail(message: "Offline")
        XCTAssertEqual(turn(session, 1).error, "Offline")
        XCTAssertFalse(turn(session, 1).needsKey)
        XCTAssertFalse(turn(session, 1).isStreaming)
    }

    func testFailWithNeedsKeyRemovesTheQuestionAndAnswer() {
        var session = streaming()
        session.fail(message: "No key", needsKey: true)
        XCTAssertEqual(session.turns, [])
        XCTAssertEqual(session.storedTurns, [])
        XCTAssertFalse(session.isStreaming)
    }

    func testFailWithNothingStreamingDoesNothing() {
        var session = AskChatSession()
        session.fail(message: "Offline")
        XCTAssertEqual(session.turns, [])
    }

    func testResetForgetsTheConversation() {
        var session = streaming()
        session.apply(.text("A"))
        let oldIds = Set(session.turns.map(\.id))
        session.reset()
        XCTAssertEqual(session.turns, [])
        XCTAssertFalse(session.isStreaming)
        XCTAssertEqual(session.send("fresh"), [AskTurn]())
        let newIds = Set(session.turns.map(\.id))
        XCTAssertEqual(newIds.count, 2)
        XCTAssertTrue(oldIds.isDisjoint(with: newIds), "ids are not reused after a reset")
    }

    // MARK: persistence

    func testStoredTurnsAreFinishedAnswersWithText() {
        var session = streaming("Q1")
        session.apply(.text("A1"))
        session.apply(.done(AskDone()))
        session.send("Q2")
        session.apply(.error(AskFailure(message: "Boom")))
        XCTAssertEqual(session.storedTurns, [user("Q1"), assistant("A1"), user("Q2")])
    }

    func testAnAnswerStillStreamingIsNotStored() {
        var session = streaming("Q1")
        session.apply(.text("typing"))
        XCTAssertEqual(session.storedTurns, [user("Q1")])
    }

    func testStoredTurnsKeepTheLastThirty() {
        var session = AskChatSession()
        for i in 0..<20 {
            session.send("Q\(i)")
            session.apply(.text("A\(i)"))
            session.apply(.done(AskDone()))
        }
        let stored = session.storedTurns
        XCTAssertEqual(stored.count, 30)
        XCTAssertEqual(stored.first, user("Q5"))
        XCTAssertEqual(stored.last, assistant("A19"))
    }

    func testRestoringRebuildsFinishedTurns() {
        let session = AskChatSession(restoring: [user("Q1"), assistant("A1")])
        XCTAssertEqual(session.turns.count, 2)
        XCTAssertEqual(Set(session.turns.map(\.id)).count, 2, "turn ids are unique")
        XCTAssertEqual(session.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.turns.map(\.content), ["Q1", "A1"])
        XCTAssertEqual(session.turns.map(\.isStreaming), [false, false])
        XCTAssertEqual(turn(session, 1).steps, [])
        XCTAssertFalse(session.isStreaming)
        XCTAssertEqual(session.storedTurns, [user("Q1"), assistant("A1")])
    }

    func testRestoringNothingIsAnEmptyChat() {
        XCTAssertEqual(AskChatSession(restoring: []).turns, [])
    }
}
