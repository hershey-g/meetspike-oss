import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 10 acceptance tests, shared Swift (spec section D): Ask uses all your history. Pure types only, no UI.
//
// Names and signatures the builder must match (several of these types do not exist yet, so this whole test target
// fails to compile until they do; that is the expected red):
//   AskRange(start:end:baselineStart:baselineEnd:source:)   Equatable, Sendable, Codable; all days are YYYY-MM-DD, source is String?
//   AskEvent.range(AskRange)                                parsed from the SSE event "range" {start,end,baselineStart,baselineEnd,rangeSource}
//   AskDone.range: AskRange?                                set from a `done` that has all four day fields; the init keeps its old arguments
//   AskRequest.allTime: Bool (default false)                public var, encoded only when true
//   AskRequest.ignorePeriod: Bool (default false)           public var, encoded only when true (spec E: "Ask over all time" sends it; D does not list it)
//   AskChatTurn.range: AskRange?, AskChatTurn.allTime: Bool
//   AskChatSession.send(_ question: String, scope: AskScope? = nil, allTime: Bool = false)
//   AskCopy.rangeLine(_ range: AskRange, today: String) -> String
//   AskScope.headerText(_ scope: AskScope?, allTime: Bool) -> String      (the one-argument version goes)
//   AskCopy.suggestions                                     4 items, "Which meetings cost me the most, all time?" second
//   AskTableLayout.style(columns:rows:accessibilitySize:) -> AskTableLayout.Style  (.grid | .stacked)
//   AskTableLayout.stacked(header:rows:) -> [[(label: [AskInline], value: [AskInline])]]

private func range(
    _ start: String = "2026-11-01", _ end: String = "2026-11-25",
    baseline: (String, String) = ("2026-01-03", "2026-11-25"), source: String? = "question"
) -> AskRange {
    AskRange(start: start, end: end, baselineStart: baseline.0, baselineEnd: baseline.1, source: source)
}

private func rangeJSON(
    start: String? = "2026-11-01", end: String? = "2026-11-25",
    baselineStart: String? = "2026-01-03", baselineEnd: String? = "2026-11-25", rangeSource: String? = "question"
) -> String {
    var parts: [String] = []
    if let start { parts.append(#""start":"\#(start)""#) }
    if let end { parts.append(#""end":"\#(end)""#) }
    if let baselineStart { parts.append(#""baselineStart":"\#(baselineStart)""#) }
    if let baselineEnd { parts.append(#""baselineEnd":"\#(baselineEnd)""#) }
    if let rangeSource { parts.append(#""rangeSource":"\#(rangeSource)""#) }
    return "{" + parts.joined(separator: ",") + "}"
}

private func rangeEvent(_ data: String) -> AskEvent? { AskEvent(SSEMessage(event: "range", data: data)) }

// MARK: - the range event and AskRange

final class Build10AskRangeEventTests: XCTestCase {
    func testRangeEventParsesAllFields() {
        XCTAssertEqual(rangeEvent(rangeJSON()), .range(range()))
    }

    func testRangeSourceIsOptional() {
        XCTAssertEqual(rangeEvent(rangeJSON(rangeSource: nil)), .range(range(source: nil)))
    }

    func testEachSourceNameIsKept() {
        for source in ["question", "allTime", "followUp", "tab", "history"] {
            XCTAssertEqual(rangeEvent(rangeJSON(rangeSource: source)), .range(range(source: source)), source)
        }
    }

    func testMissingOrNonDayDatesGiveNoEvent() {
        XCTAssertNil(rangeEvent(rangeJSON(start: nil)), "no start")
        XCTAssertNil(rangeEvent(rangeJSON(end: nil)), "no end")
        XCTAssertNil(rangeEvent(rangeJSON(start: "tomorrow")), "start is not a day")
        XCTAssertNil(rangeEvent(rangeJSON(end: "2026-13-45")), "end is not a day")
        XCTAssertNil(rangeEvent(rangeJSON(end: "2026-02-30")), "end is not a real day")
        XCTAssertNil(rangeEvent(rangeJSON(start: "")), "empty start")
        XCTAssertNil(rangeEvent(rangeJSON(baselineStart: nil)), "no baseline start")
        XCTAssertNil(rangeEvent(rangeJSON(baselineEnd: nil)), "no baseline end")
        XCTAssertNil(rangeEvent(rangeJSON(baselineStart: "all of it")), "baseline start is not a day")
        XCTAssertNil(rangeEvent("{}"))
        XCTAssertNil(rangeEvent("[]"))
        XCTAssertNil(rangeEvent(#""nope""#))
        XCTAssertNil(rangeEvent("not json"))
    }

    func testARangeEventIsNotTerminal() {
        XCTAssertFalse(AskEvent.range(range()).isTerminal)
    }

    func testTheParserPassesItThroughWithoutEndingTheStream() {
        var parser = AskEventParser()
        let events = parser.push("event: range\ndata: \(rangeJSON())\n\nevent: text\ndata: {\"delta\":\"Hi\"}\n\n")
        XCTAssertEqual(events, [.range(range()), .text("Hi")])
        XCTAssertFalse(parser.sawTerminal)
        XCTAssertEqual(parser.finish(), [.cutOff], "a stream that ends after a range event and no done is cut off")
    }

    func testARangeEventBeforeDoneKeepsTheOneTerminalRule() {
        var parser = AskEventParser()
        let events = parser.push("event: range\ndata: \(rangeJSON())\n\nevent: done\ndata: {\"truncated\":false}\n\n") + parser.finish()
        XCTAssertEqual(events.filter(\.isTerminal).count, 1)
        XCTAssertFalse(events.contains(.cutOff))
    }

    func testAnOlderWorkerSendsNoRangeEventAndNothingBreaks() {
        var parser = AskEventParser()
        let events = parser.push("event: step\ndata: {\"id\":\"calendar\",\"label\":\"Reading\",\"status\":\"active\"}\n\nevent: done\ndata: {\"truncated\":false,\"start\":\"2026-10-28\",\"end\":\"2026-11-24\"}\n\n")
        XCTAssertFalse(events.contains { if case .range = $0 { true } else { false } })
    }

    func testAskRangeRoundTripsThroughCodable() throws {
        let original = range()
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AskRange.self, from: data), original)
        let noSource = try JSONDecoder().decode(
            AskRange.self, from: Data(#"{"start":"2026-11-01","end":"2026-11-25","baselineStart":"2026-01-03","baselineEnd":"2026-11-25"}"#.utf8))
        XCTAssertNil(noSource.source)
    }
}

// MARK: - done carries the range

final class Build10AskDoneTests: XCTestCase {
    func testDoneWithAllFourDayFieldsHasARange() {
        var expected = AskDone(truncated: false, model: "claude-opus-5-5", start: "2026-11-01", end: "2026-11-25")
        expected.range = range()
        let json = #"{"truncated":false,"model":"claude-opus-5-5","start":"2026-11-01","end":"2026-11-25","baselineStart":"2026-01-03","baselineEnd":"2026-11-25","rangeSource":"question"}"#
        XCTAssertEqual(AskEvent(SSEMessage(event: "done", data: json)), .done(expected))
    }

    func testDoneFromAnOlderWorkerHasNoRange() {
        let json = #"{"truncated":false,"model":"claude-opus-5-5","start":"2026-10-28","end":"2026-11-24"}"#
        let event = AskEvent(SSEMessage(event: "done", data: json))
        XCTAssertEqual(event, .done(AskDone(truncated: false, model: "claude-opus-5-5", start: "2026-10-28", end: "2026-11-24")))
        if case .done(let done)? = event { XCTAssertNil(done.range) } else { XCTFail("not a done event") }
    }

    func testDoneWithOnlySomeOfTheFieldsHasNoRange() {
        for json in [
            #"{"truncated":false,"start":"2026-11-01","end":"2026-11-25","baselineStart":"2026-01-03"}"#,
            #"{"truncated":false,"start":"2026-11-01","end":"2026-11-25","baselineEnd":"2026-11-25"}"#,
            #"{"truncated":false,"baselineStart":"2026-01-03","baselineEnd":"2026-11-25"}"#,
            #"{"truncated":false,"start":"soon","end":"2026-11-25","baselineStart":"2026-01-03","baselineEnd":"2026-11-25"}"#,
        ] {
            guard case .done(let done)? = AskEvent(SSEMessage(event: "done", data: json)) else { return XCTFail(json) }
            XCTAssertNil(done.range, json)
        }
    }

    func testTheOldDoneInitStillWorks() {
        let done = AskDone(truncated: true, interrupted: true, refused: false, model: "m", start: "2026-10-28", end: "2026-11-24")
        XCTAssertNil(done.range)
        XCTAssertEqual(done, AskDone(truncated: true, interrupted: true, refused: false, model: "m", start: "2026-10-28", end: "2026-11-24"))
    }
}

// MARK: - the chat turn

final class Build10AskTurnTests: XCTestCase {
    private func streaming(_ question: String = "Which meetings cost me the most?", scope: AskScope? = nil, allTime: Bool = false) -> AskChatSession {
        var session = AskChatSession()
        session.send(question, scope: scope, allTime: allTime)
        return session
    }
    private func assistant(_ session: AskChatSession) -> AskChatTurn { session.turns[1] }

    func testARangeEventSetsTheRangeWhileStreaming() {
        var session = streaming()
        XCTAssertNil(assistant(session).range)
        session.apply(.range(range()))
        XCTAssertEqual(assistant(session).range, range())
        XCTAssertTrue(assistant(session).isStreaming, "a range event is not terminal")
        session.apply(.text("Nov 10 "))
        session.apply(.step(AskStep(id: "calendar", label: "Read 3 meetings", status: .done)))
        XCTAssertEqual(assistant(session).content, "Nov 10 ")
        XCTAssertEqual(assistant(session).steps.count, 1)
        XCTAssertEqual(assistant(session).range, range(), "text and steps do not touch it")
    }

    func testADoneWithoutARangeNeverClearsIt() {
        var session = streaming()
        session.apply(.range(range()))
        session.apply(.text("Answer"))
        session.apply(.done(AskDone(truncated: false, model: "m", start: "2026-11-01", end: "2026-11-25")))
        XCTAssertEqual(assistant(session).range, range())
        XCTAssertFalse(assistant(session).isStreaming)
    }

    func testADoneWithARangeSetsItAndOverwrites() {
        var viaDone = streaming()
        var done = AskDone(truncated: false, model: "m", start: "2026-11-01", end: "2026-11-25")
        done.range = range(source: "tab")
        viaDone.apply(.done(done))
        XCTAssertEqual(assistant(viaDone).range, range(source: "tab"))

        var both = streaming()
        both.apply(.range(range(source: "question")))
        both.apply(.done(done))
        XCTAssertEqual(assistant(both).range, range(source: "tab"), "the later one wins")
    }

    func testAnOlderWorkerLeavesNoRange() {
        var session = streaming()
        session.apply(.text("Answer"))
        session.apply(.done(AskDone(truncated: false, model: "m", start: "2026-11-01", end: "2026-11-25")))
        XCTAssertNil(assistant(session).range, "no line and no button")
    }

    func testARangeEventAfterTheEndIsIgnored() {
        var session = streaming()
        session.apply(.done(AskDone()))
        session.apply(.range(range()))
        XCTAssertNil(assistant(session).range)
        var idle = AskChatSession()
        idle.apply(.range(range()))
        XCTAssertEqual(idle.turns, [])
    }

    func testAnErrorKeepsARangeAlreadySeen() {
        var session = streaming()
        session.apply(.range(range()))
        session.apply(.error(AskFailure(message: "Claude is busy. Try again.")))
        XCTAssertEqual(assistant(session).range, range())
        XCTAssertNotNil(assistant(session).error)
    }

    func testRetryKeepsItsQuestionScopeAndAllTimeSetting() {
        let scope = AskScope(start: "2026-10-01", end: "2026-10-14")
        let on = streaming("Which day cost me most?", scope: scope, allTime: true)
        XCTAssertEqual(assistant(on).question, "Which day cost me most?")
        XCTAssertEqual(assistant(on).scope, scope)
        XCTAssertTrue(assistant(on).allTime)
        XCTAssertFalse(on.turns[0].allTime, "only the answer carries the setting")

        let off = streaming("Which day cost me most?", scope: scope)
        XCTAssertFalse(assistant(off).allTime, "off by default")
    }

    func testTheSettingIsPerTurn() {
        var session = streaming("First?", allTime: true)
        session.apply(.done(AskDone()))
        session.send("Second?", allTime: false)
        XCTAssertTrue(session.turns[1].allTime)
        XCTAssertFalse(session.turns[3].allTime)
    }

    func testRestoredTurnsHaveNoRangeAndAllTimeOff() {
        let session = AskChatSession(restoring: [AskTurn(role: .user, content: "q"), AskTurn(role: .assistant, content: "a")])
        XCTAssertEqual(session.turns.count, 2)
        for turn in session.turns {
            XCTAssertNil(turn.range)
            XCTAssertFalse(turn.allTime)
        }
    }

    func testASavedChatFromBuild9StillRestores() throws {
        let old = #"{"sourceDisplay":{"oura":true,"whoop":false},"turns":[{"role":"user","content":"How was my week?"},{"role":"assistant","content":"Busy."}]}"#
        let saved = try JSONDecoder().decode(AskSavedChat.self, from: Data(old.utf8))
        XCTAssertEqual(saved.turns(for: .make(oura: true, whoop: false)).map(\.content), ["How was my week?", "Busy."])
        let session = AskChatSession(restoring: saved.turns)
        XCTAssertEqual(session.turns.count, 2)
    }

    func testTheSavedCopyDoesNotGainFields() throws {
        var session = streaming(allTime: true)
        session.apply(.range(range()))
        session.apply(.text("Answer"))
        session.apply(.done(AskDone()))
        let saved = AskSavedChat(sourceDisplay: .make(oura: true, whoop: true), turns: session.storedTurns)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["sourceDisplay", "turns"])
        let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        XCTAssertFalse(text.contains("baseline"))
        XCTAssertFalse(text.contains("allTime"))
    }
}

// MARK: - the request body

final class Build10AskRequestTests: XCTestCase {
    private func json(_ request: AskRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }
    private func base() -> AskRequest {
        AskRequest(question: "Which day cost me most?", sourceDisplay: .make(oura: true, whoop: true))
    }

    func testAllTimeIsEncodedOnlyWhenTrue() throws {
        XCTAssertFalse(base().allTime)
        XCTAssertNil(try json(base())["allTime"], "off: the key is not sent, so builds 8 and 9 see the body they know")
        var on = base()
        on.allTime = true
        XCTAssertEqual(try json(on)["allTime"] as? Bool, true)
    }

    func testIgnorePeriodIsEncodedOnlyWhenTrue() throws {
        XCTAssertFalse(base().ignorePeriod)
        XCTAssertNil(try json(base())["ignorePeriod"])
        var on = base()
        on.ignorePeriod = true
        XCTAssertEqual(try json(on)["ignorePeriod"] as? Bool, true)
    }

    func testAskOverAllTimeSendsTheQuestionUnchangedWithBothFlags() throws {
        var request = AskRequest(question: "How was this month?", sourceDisplay: .make(oura: true, whoop: true), start: "2026-10-01", end: "2026-10-14")
        request.allTime = true
        request.ignorePeriod = true
        let body = try json(request)
        XCTAssertEqual(body["question"] as? String, "How was this month?")
        XCTAssertEqual(body["allTime"] as? Bool, true)
        XCTAssertEqual(body["ignorePeriod"] as? Bool, true)
    }

    func testTheExistingFieldsAreUnchanged() throws {
        var request = AskRequest(
            question: "q", history: [AskTurn(role: .user, content: "hi")], sourceDisplay: .make(oura: false, whoop: true),
            start: "2026-11-18", end: "2026-11-24")
        request.allTime = true
        let body = try json(request)
        XCTAssertEqual(body["start"] as? String, "2026-11-18")
        XCTAssertEqual(body["end"] as? String, "2026-11-24")
        XCTAssertEqual(body["sourceDisplay"] as? [String: Bool], ["oura": false, "whoop": true])
        XCTAssertEqual((body["history"] as? [[String: String]])?.count, 1)
        let lone = AskRequest(question: "q", sourceDisplay: .make(oura: true, whoop: true), start: "2026-11-18")
        XCTAssertNil(try json(lone)["start"], "a lone start is still dropped")
    }
}

// MARK: - copy

final class Build10AskCopyTests: XCTestCase {
    func testRangeLineWhenRankedIsSmallerThanAllHistory() {
        XCTAssertEqual(
            AskCopy.rangeLine(range(), today: "2026-11-25"),
            "Ranking Nov 1 to Nov 25, compared with all history")
        XCTAssertEqual(
            AskCopy.rangeLine(range("2026-11-24", "2026-11-24"), today: "2026-11-25"),
            "Ranking Nov 24, compared with all history")
        XCTAssertEqual(
            AskCopy.rangeLine(range("2026-01-03", "2026-10-31"), today: "2026-11-25"),
            "Ranking Jan 3 to Oct 31, compared with all history", "same start, earlier end is still smaller")
    }

    func testRangeLineWhenRankedCoversAllHistory() {
        XCTAssertEqual(
            AskCopy.rangeLine(range("2026-01-03", "2026-11-25", source: "allTime"), today: "2026-11-25"),
            "Using all history, Jan 3 to Nov 25")
    }

    func testRangeLineAddsTheYearWhenTheyDiffer() {
        XCTAssertEqual(
            AskCopy.rangeLine(range("2025-12-30", "2026-01-02", baseline: ("2024-03-01", "2026-01-02")), today: "2026-01-02"),
            "Ranking Dec 30, 2025 to Jan 2, 2026, compared with all history")
        XCTAssertEqual(
            AskCopy.rangeLine(range("2025-03-01", "2026-11-25", baseline: ("2025-03-01", "2026-11-25")), today: "2026-11-25"),
            "Using all history, Mar 1, 2025 to Nov 25, 2026")
    }

    func testRangeLineHasNoEmDash() {
        XCTAssertFalse(AskCopy.rangeLine(range(), today: "2026-11-25").contains("\u{2014}"))
    }

    func testHeaderTextWithAScope() {
        let scope = AskScope(start: "2026-10-01", end: "2026-10-14")
        XCTAssertEqual(AskScope.headerText(scope, allTime: false), "Ranking Oct 1 to Oct 14, compared with all history")
        XCTAssertEqual(AskScope.headerText(scope, allTime: true), "Ranking all history")
    }

    func testHeaderTextUsesTheScopesLabel() throws {
        let scope = try XCTUnwrap(AskScope(start: "2026-10-01", end: "2026-10-14", label: "Last 2 weeks"))
        XCTAssertEqual(AskScope.headerText(scope, allTime: false), "Ranking Last 2 weeks, compared with all history")
    }

    func testHeaderTextWithNoScope() {
        XCTAssertEqual(AskScope.headerText(nil, allTime: false), "Using all history")
        XCTAssertEqual(AskScope.headerText(nil, allTime: true), "Ranking all history")
    }

    func testSuggestions() {
        XCTAssertEqual(AskCopy.suggestions.count, 4)
        XCTAssertEqual(AskCopy.suggestions, [
            "Which meetings cost me the most this month?",
            "Which meetings cost me the most, all time?",
            "Is it the number of hours or the people?",
            "How do days with after-hours calls compare?",
        ])
        XCTAssertTrue(AskCopy.suggestions.allSatisfy { !$0.contains("\u{2014}") })
    }
}

// MARK: - tables

private func t(_ s: String) -> [AskInline] { AskMarkdown.inlines(s) }

private struct Pair: Equatable {
    let label: [AskInline]
    let value: [AskInline]
}

private func cards(_ header: [String], _ rows: [[String]]) -> [[Pair]] {
    AskTableLayout.stacked(header: header.map(t), rows: rows.map { $0.map(t) })
        .map { card in card.map { Pair(label: $0.label, value: $0.value) } }
}

final class Build10AskTableLayoutTests: XCTestCase {
    func testGridOnlyForOneToThreeColumnsAtNormalSizes() {
        for columns in 1...3 {
            XCTAssertEqual(AskTableLayout.style(columns: columns, rows: 5, accessibilitySize: false), .grid, "\(columns) columns")
        }
        for columns in [4, 5, 8, 20] {
            XCTAssertEqual(AskTableLayout.style(columns: columns, rows: 5, accessibilitySize: false), .stacked, "\(columns) columns")
        }
    }

    func testAccessibilitySizesAlwaysStack() {
        for columns in 0...6 {
            XCTAssertEqual(AskTableLayout.style(columns: columns, rows: 5, accessibilitySize: true), .stacked, "\(columns) columns")
        }
    }

    func testNoColumnsStacks() {
        XCTAssertEqual(AskTableLayout.style(columns: 0, rows: 3, accessibilitySize: false), .stacked)
    }

    func testRowCountDoesNotChangeTheStyle() {
        for rows in [0, 1, 2, 50, 500] {
            XCTAssertEqual(AskTableLayout.style(columns: 3, rows: rows, accessibilitySize: false), .grid, "\(rows) rows")
            XCTAssertEqual(AskTableLayout.style(columns: 4, rows: rows, accessibilitySize: false), .stacked, "\(rows) rows")
        }
    }

    func testOneCardPerRowWithTheHeaderAsLabels() {
        let result = cards(["Day", "Meetings", "Recovery", "Sleep"], [["Nov 10", "6", "31%", "55"], ["Nov 12", "5", "40%", "61"]])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], [
            Pair(label: t("Day"), value: t("Nov 10")), Pair(label: t("Meetings"), value: t("6")),
            Pair(label: t("Recovery"), value: t("31%")), Pair(label: t("Sleep"), value: t("55")),
        ])
        XCTAssertEqual(result[1].map(\.value), [t("Nov 12"), t("5"), t("40%"), t("61")])
    }

    func testAShortRowGetsNoValueForMissingCells() {
        let result = cards(["A", "B", "C", "D"], [["a1", "b1"]])
        XCTAssertEqual(result, [[Pair(label: t("A"), value: t("a1")), Pair(label: t("B"), value: t("b1"))]])
    }

    func testExtraCellsHaveAnEmptyLabel() {
        let result = cards(["A", "B"], [["a1", "b1", "extra"]])
        XCTAssertEqual(result, [[
            Pair(label: t("A"), value: t("a1")), Pair(label: t("B"), value: t("b1")), Pair(label: [], value: t("extra")),
        ]])
    }

    func testABlankValueIsSkipped() {
        let result = cards(["A", "B", "C", "D"], [["a1", "", "c1", "d1"]])
        XCTAssertEqual(result, [[
            Pair(label: t("A"), value: t("a1")), Pair(label: t("C"), value: t("c1")), Pair(label: t("D"), value: t("d1")),
        ]])
    }

    func testARowOfBlanksIsStillOneCard() {
        let result = cards(["A", "B", "C", "D"], [["", "", "", ""], ["a2", "b2", "c2", "d2"]])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], [])
        XCTAssertEqual(result[1].count, 4)
    }

    func testNoRowsGivesNoCards() {
        XCTAssertEqual(cards(["A", "B", "C", "D"], []), [])
    }

    func testBoldInACellIsKept() {
        let result = cards(["A", "B", "C", "D"], [["**Nov 10**", "6", "7", "8"]])
        XCTAssertEqual(result[0][0].value, [.bold("Nov 10")])
    }

    func testItWorksOnATableParsedFromAnAnswer() {
        let blocks = AskMarkdown.blocks("| Day | Meetings | Recovery | Sleep |\n|---|---|---|---|\n| Nov 10 | 6 | 31% | 55 |")
        guard case .table(let header, let rows)? = blocks.first else { return XCTFail("no table") }
        XCTAssertEqual(AskTableLayout.style(columns: header.count, rows: rows.count, accessibilitySize: false), .stacked)
        XCTAssertEqual(AskTableLayout.stacked(header: header, rows: rows).count, 1)
    }
}
