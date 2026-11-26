import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 iPhone spec: each meeting row offers "I didn't join", "Don't link this meeting", "Meeting times" (with "Use
// calendar times") and "Undo". For a series: "Just this one" / "All of them". The quiet note under a meeting the Mac never
// saw Zoom for asks "Looks like you didn't join. Unlink it?" with Yes / No (Yes = left out, No = state linked).
// Excluded rows say "Didn't join" or "Not linked". Failure leaves the old state and says so.
//
// Written from the spec, after the code. Pure helpers: MeetingActions, OverrideDelivery.

final class Build9HelpersActionsTests: XCTestCase {
    private let inSeries = MeetingOverride(seriesId: "series-1")
    private let alone = MeetingOverride()

    // MARK: Which question comes first

    func testAMeetingWithNoSeriesIsSavedForJustThatMeeting() {
        for override in [nil, alone] as [MeetingOverride?] {
            XCTAssertEqual(
                MeetingActions.plan(.notJoined, override: override),
                .save(OverrideEdit(scope: .event, state: .set(.notJoined))))
            XCTAssertEqual(
                MeetingActions.plan(.unlinked, override: override),
                .save(OverrideEdit(scope: .event, state: .set(.unlinked))))
        }
    }

    func testAMeetingInASeriesAsksJustThisOneOrAllOfThemFirst() {
        XCTAssertEqual(MeetingActions.plan(.notJoined, override: inSeries), .askScope(.state(.notJoined)))
        XCTAssertEqual(MeetingActions.plan(.unlinked, override: inSeries), .askScope(.state(.unlinked)))
    }

    func testTheScopeAnswerBecomesTheEdit() {
        XCTAssertEqual(
            MeetingActions.answer(.event, to: .state(.notJoined), override: inSeries),
            OverrideEdit(scope: .event, state: .set(.notJoined)))
        XCTAssertEqual(
            MeetingActions.answer(.series, to: .state(.notJoined), override: inSeries),
            OverrideEdit(scope: .series, state: .set(.notJoined)))
        XCTAssertEqual(
            MeetingActions.answer(.series, to: .state(.unlinked), override: inSeries),
            OverrideEdit(scope: .series, state: .set(.unlinked)))
        XCTAssertEqual(
            MeetingActions.answer(.event, to: .state(.unlinked), override: inSeries),
            OverrideEdit(scope: .event, state: .set(.unlinked)))
    }

    func testASeriesChoiceNeverCarriesTimes() throws {
        let edit = MeetingActions.answer(.series, to: .state(.notJoined), override: inSeries)
        let body = try H9.wire(edit)
        XCTAssertEqual(Set(body.keys), ["scope", "state"], "times are for one meeting only")
    }

    // MARK: Times

    func testMeetingTimesOpensTheSheetWhateverTheMeetingIs() {
        let excluded = MeetingOverride(state: .notJoined, scope: .series, seriesId: "series-1")
        for override in [nil, alone, inSeries, excluded] as [MeetingOverride?] {
            XCTAssertEqual(MeetingActions.plan(.times, override: override), .askTimes)
        }
    }

    func testUseCalendarTimesClearsBothTimesAndNothingElse() throws {
        let plan = MeetingActions.plan(.calendarTimes, override: inSeries)
        // No scope question: times only ever belong to one meeting.
        XCTAssertEqual(plan, .save(OverrideEdit(scope: .event, startUtc: .clear, endUtc: .clear)))
        guard case .save(let edit) = plan else { return XCTFail("expected a save") }
        let body = try H9.wire(edit)
        XCTAssertEqual(Set(body.keys), ["scope", "startUtc", "endUtc"], "state is left alone")
        XCTAssertTrue(body["startUtc"] is NSNull)
        XCTAssertTrue(body["endUtc"] is NSNull)
    }

    func testNewTimesNeedTheEndAfterTheStart() {
        let start = B9.at(0)
        XCTAssertEqual(
            MeetingActions.times(start: start, end: start.addingTimeInterval(1)),
            .success(OverrideEdit(scope: .event, startUtc: .set(start), endUtc: .set(start.addingTimeInterval(1)))))
        XCTAssertEqual(MeetingActions.times(start: start, end: start), .failure(.endNotAfterStart))
        XCTAssertEqual(MeetingActions.times(start: start, end: start.addingTimeInterval(-60)), .failure(.endNotAfterStart))
        H9.assertPlainVoice(MeetingActions.TimesProblem.endNotAfterStart.message)
        XCTAssertEqual(MeetingActions.TimesProblem.endNotAfterStart.message, "The end has to be after the start.")
    }

    func testOnlyTheOwnTimesOfTheOwnerOfferUseCalendarTimes() {
        XCTAssertFalse(MeetingActions.hasOwnTimes(nil))
        XCTAssertFalse(MeetingActions.hasOwnTimes(alone))
        XCTAssertTrue(MeetingActions.hasOwnTimes(MeetingOverride(startUtc: B9.at(0))))
        XCTAssertTrue(MeetingActions.hasOwnTimes(MeetingOverride(endUtc: B9.at(60))))
        XCTAssertTrue(MeetingActions.hasOwnTimes(MeetingOverride(startUtc: B9.at(0), endUtc: B9.at(60))))
        // The Mac's sighting and a state are not times the person set.
        XCTAssertFalse(MeetingActions.hasOwnTimes(MeetingOverride(seenStartUtc: B9.at(0), seenEndUtc: B9.at(60))))
        XCTAssertFalse(MeetingActions.hasOwnTimes(MeetingOverride(state: .notJoined, scope: .event)))
    }

    // MARK: Undo

    func testUndoShowsOnlyWhenThereIsAChoiceToUndo() {
        XCTAssertFalse(MeetingActions.canUndo(nil))
        XCTAssertFalse(MeetingActions.canUndo(alone))
        XCTAssertFalse(MeetingActions.canUndo(inSeries), "a series member nobody chose anything for")
        XCTAssertFalse(MeetingActions.canUndo(MeetingOverride(seenNone: true)), "the Mac's guess is not a choice")
        for state in [MeetingOverride.State.notJoined, .unlinked, .linked] {
            XCTAssertTrue(MeetingActions.canUndo(MeetingOverride(state: state, scope: .event)), "\(state)")
            XCTAssertTrue(MeetingActions.canUndo(MeetingOverride(state: state, scope: .series, seriesId: "s")), "\(state)")
        }
    }

    func testUndoOfAChoiceOnThisMeetingClearsItWithoutAsking() {
        for state in [MeetingOverride.State.notJoined, .unlinked, .linked] {
            let override = MeetingOverride(state: state, scope: .event, seriesId: "series-1")
            XCTAssertEqual(MeetingActions.plan(.undo, override: override), .save(OverrideEdit(scope: .event, state: .clear)), "\(state)")
        }
    }

    func testUndoOfARuleFromTheSeriesAsksJustThisOneOrAllOfThem() {
        let rule = MeetingOverride(state: .notJoined, scope: .series, seriesId: "series-1")
        XCTAssertEqual(MeetingActions.plan(.undo, override: rule), .askScope(.undo))
        // All of them: remove the rule.
        XCTAssertEqual(
            MeetingActions.answer(.series, to: .undo, override: rule), OverrideEdit(scope: .series, state: .clear))
        // Just this one: opt this meeting out of the rule, and leave the rule for the others.
        XCTAssertEqual(
            MeetingActions.answer(.event, to: .undo, override: rule), OverrideEdit(scope: .event, state: .set(.linked)))
    }

    func testJustThisOneUndoWithNoRuleToOptOutOfJustClears() {
        let own = MeetingOverride(state: .notJoined, scope: .event, seriesId: "series-1")
        XCTAssertEqual(MeetingActions.answer(.event, to: .undo, override: own), OverrideEdit(scope: .event, state: .clear))
        XCTAssertEqual(MeetingActions.answer(.event, to: .undo, override: nil), OverrideEdit(scope: .event, state: .clear))
    }

    func testUndoRoundTripsThroughTheOverlayForEveryScope() {
        // Three meetings of one series, all left out by a rule on the series.
        let rule = MeetingOverride(state: .notJoined, scope: .series, seriesId: "s")
        let items: [(id: String, override: MeetingOverride?)] = [("s_20261124", rule), ("s_20261125", rule), ("s_20261126", rule)]

        let justThis = H9.item("s_20261125", MeetingActions.answer(.event, to: .undo, override: rule))
        let afterOne = OverrideOverlay.apply([justThis], to: items)
        XCTAssertEqual(afterOne.map(OverrideRules.excluded), [true, false, true], "only this one comes back")

        let all = H9.item("s_20261125", MeetingActions.answer(.series, to: .undo, override: rule))
        let afterAll = OverrideOverlay.apply([all], to: items)
        XCTAssertEqual(afterAll.map(OverrideRules.excluded), [false, false, false])
    }

    // MARK: The note under a meeting the Mac never saw

    func testTheNoteAsksTheSpecQuestion() {
        XCTAssertEqual(MeetingActions.skippedQuestion, "Looks like you didn't join. Unlink it?")
    }

    func testYesLeavesTheMeetingOutAndNoLinksIt() throws {
        let note = MeetingOverride(seenNone: true)
        XCTAssertTrue(OverrideRules.suggestsNotJoined(note))

        XCTAssertEqual(MeetingActions.plan(.skipYes, override: note), .save(OverrideEdit(scope: .event, state: .set(.unlinked))))
        XCTAssertEqual(MeetingActions.plan(.skipNo, override: note), .save(OverrideEdit(scope: .event, state: .set(.linked))))
        // Even in a series: the note is about this meeting.
        let serial = MeetingOverride(seenNone: true, seriesId: "s")
        XCTAssertEqual(MeetingActions.plan(.skipYes, override: serial), .save(OverrideEdit(scope: .event, state: .set(.unlinked))))
        XCTAssertEqual(MeetingActions.plan(.skipNo, override: serial), .save(OverrideEdit(scope: .event, state: .set(.linked))))

        // What the person sees afterwards.
        func after(_ action: MeetingActions.Action) throws -> MeetingOverride? {
            guard case .save(let edit) = MeetingActions.plan(action, override: note) else { throw XCTSkip("not a save") }
            return OverrideOverlay.apply([H9.item("ev", edit)], to: [(id: "ev", override: note)])[0]
        }
        let yes = try after(.skipYes)
        XCTAssertTrue(OverrideRules.excluded(yes), "Yes: left out")
        XCTAssertFalse(OverrideRules.suggestsNotJoined(yes), "the question is answered")
        XCTAssertEqual(MeetingActions.excludedLabel(yes), "Not linked")
        let no = try after(.skipNo)
        XCTAssertFalse(OverrideRules.excluded(no), "No: stays in")
        XCTAssertFalse(OverrideRules.suggestsNotJoined(no), "and the note stops asking")
        XCTAssertEqual(no?.state, .linked)
    }

    func testTheNoteOnlyShowsWhenNoChoiceHasBeenMade() {
        XCTAssertFalse(OverrideRules.suggestsNotJoined(nil))
        XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride()))
        XCTAssertTrue(OverrideRules.suggestsNotJoined(MeetingOverride(seenNone: true)))
        for state in [MeetingOverride.State.notJoined, .unlinked, .linked] {
            XCTAssertFalse(OverrideRules.suggestsNotJoined(MeetingOverride(state: state, scope: .event, seenNone: true)), "\(state)")
        }
    }

    // MARK: Words

    func testExcludedRowsSayDidntJoinOrNotLinked() {
        XCTAssertEqual(MeetingActions.excludedLabel(MeetingOverride(state: .notJoined, scope: .event)), "Didn't join")
        XCTAssertEqual(MeetingActions.excludedLabel(MeetingOverride(state: .unlinked, scope: .event)), "Not linked")
        XCTAssertEqual(MeetingActions.excludedLabel(MeetingOverride(state: .notJoined, scope: .series)), "Didn't join")
        XCTAssertEqual(MeetingActions.excludedLabel(MeetingOverride(state: .unlinked, scope: .series)), "Not linked")
    }

    func testScopeQuestionTitlesMatchTheWeb() {
        XCTAssertEqual(MeetingActions.scopeTitle(.state(.notJoined)), "I didn't join for")
        XCTAssertEqual(MeetingActions.scopeTitle(.state(.unlinked)), "Don't link for")
        XCTAssertEqual(MeetingActions.scopeTitle(.undo), "Put it back for")
    }

    func testCopyHasNoDashes() {
        for text in [
            MeetingActions.skippedQuestion, OverrideDelivery.notAvailable,
            MeetingActions.excludedLabel(nil), MeetingActions.scopeTitle(.undo),
            MeetingActions.scopeTitle(.state(.linked)), MeetingActions.scopeTitle(.state(.notJoined)),
            MeetingActions.scopeTitle(.state(.unlinked)),
        ] { H9.assertPlainVoice(text) }
    }

    // MARK: Failure says so and leaves the old state

    func testWhatHappensToASavedEditByAnswer() {
        func verdict(_ error: Error) -> OverrideDelivery.Verdict { OverrideDelivery.verdict(for: error) }
        // Final: it can never succeed, so it is dropped and the Worker's sentence is shown.
        XCTAssertEqual(verdict(APIError.http(status: 400, message: "Bad shape.")), .drop("Bad shape."))
        XCTAssertEqual(verdict(APIError.http(status: 404, message: "No such meeting.")), .drop("No such meeting."))
        // Not final: kept and sent later.
        XCTAssertEqual(verdict(APIError.http(status: 503, message: "ignored words")), .keep(OverrideDelivery.notAvailable))
        XCTAssertEqual(verdict(APIError.offline), .keep("Saved on this phone. It sends when you are back online."))
        for status in [500, 502, 504, 429, 409] {
            XCTAssertEqual(verdict(APIError.http(status: status, message: "x")), .keep("Couldn't save. Nothing changed."), "\(status)")
        }
        if case .keep = verdict(APIError.accessRejected) {} else { XCTFail("a rejected sign in is retried after signing in") }
        if case .keep = verdict(APIError.decoding("x")) {} else { XCTFail("an answer we could not read is retried") }
        if case .keep = verdict(URLError(.timedOut)) {} else { XCTFail("an unknown error keeps the edit") }
    }

    func testEveryDeliveryMessageIsPlain() {
        let errors: [Error] = [
            APIError.offline, APIError.accessRejected, APIError.decoding("x"), APIError.http(status: 503, message: "x"),
            APIError.http(status: 500, message: "x"), URLError(.timedOut),
        ]
        for error in errors {
            switch OverrideDelivery.verdict(for: error) {
            case .keep(let text), .drop(let text): H9.assertPlainVoice(text)
            }
        }
    }
}
