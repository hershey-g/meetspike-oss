import XCTest
@testable import MeetspikeHRCore

// Build 12: calmer Lock Screen Live Activity with an easy off switch, plus a Dynamic Island that says a meeting is on.
//
// Public API these tests pin (the builder creates it in shared core, for example
// Sources/MeetspikeHRCore/Glance/LiveActivityRule.swift and an extension in LiveGlance.swift):
//
//   public enum LiveActivityMode: String, Codable, CaseIterable, Sendable
//       cases in this order: off, duringMeetings, whenListening
//       raw values "off", "duringMeetings", "whenListening"
//       static let `default`: LiveActivityMode          // .duringMeetings
//       static func stored(_ raw: String?) -> LiveActivityMode   // nil or unknown text gives .default
//       var label: String                               // "Off", "During meetings", "Whenever listening"
//       var liveTabLine: String                         // "Lock Screen: <label>"
//       static let footer: String                       // the picker footer text from the spec
//
//   public enum LiveActivityRule {
//       static func shouldShow(mode:schedule:listening:manualLive:now:) -> Bool
//   }
//       The fix pass removed the "needs a reading first" input: iOS cannot start a Live Activity from the
//       background, so During meetings is on from the lead-in through the end of the last meeting in the block.
//       If a `hasReadingInMeeting` helper stays in core, these tests do not use it.
//
//   public enum CompactLabel: Equatable, Sendable {      // what the compact Dynamic Island trailing slot draws
//       case minutesLeft(Int, end: Date)                  // "12m", the widget keeps it live with a timer to `end`
//       case lessThanAMinute(end: Date)                   // "<1m"
//       case startsIn(minutes: Int)                       // "in 3m", Whenever listening lead-in
//       case live                                         // "Live", Go live now outside a meeting
//       case ring                                         // wrap-up tail: no text, the progress ring
//       var text: String?                                 // nil for .ring
//   }
//   extension LiveGlanceContent {
//       func compactLabel(now: Date) -> CompactLabel
//       var titleLine: String                             // "In meeting · <title>" in .endsIn, else `title`
//       static let inMeetingPrefix: String                // "In meeting · "
//   }
//
// Rule for .duringMeetings (when listening): true from the start of the listening block (the 300 s lead-in)
// up to but not including the END of the last meeting in the block, using the effective (extended or ended)
// times. Back-to-back meetings in one block stay one activity. False in the 10 minute wrap-up tail and for Go live
// now outside a meeting. Waiting for WHOOP shows as state, so there is no reading condition.
//
// Pieces that need ActivityKit, SwiftUI or UserDefaults wiring cannot run in this package. The pure decisions
// are tested here and the app sources are read for the strings the spec fixes.

private enum B12 {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    static func meeting(_ title: String, _ start: Double, _ end: Double) -> CalendarMeeting {
        CalendarMeeting(title: title, start: at(start), end: at(end))!
    }

    static func show(
        _ mode: LiveActivityMode, _ schedule: MeetingSchedule, at minutes: Double,
        listening: Bool = true, manualLive: Bool = false
    ) -> Bool {
        LiveActivityRule.shouldShow(
            mode: mode, schedule: schedule, listening: listening, manualLive: manualLive, now: at(minutes)
        )
    }

    /// The content the activity would show for a 0 to 30 minute meeting called Sync, at `minutes`.
    static func content(at minutes: Double, manualSince: Date? = nil, schedule: MeetingSchedule? = nil) -> LiveGlanceContent {
        let schedule = schedule ?? MeetingSchedule([meeting("Sync", 0, 30)])
        return LiveGlancePlan.content(
            schedule: schedule, listening: true, manualSince: manualSince, bpm: 70, status: .live, now: at(minutes)
        )!
    }

    static func repoRoot(_ file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    static func read(_ path: String, file: String = #filePath) throws -> String {
        let url = repoRoot(file).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: repoRoot(file).appendingPathComponent("ios/MeetspikeHR").path) {
                XCTFail("missing \(path)")
                return ""
            }
            throw XCTSkip("no ios/ folder next to this package")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func swiftSources(under path: String, file: String = #filePath) throws -> String {
        let root = repoRoot(file).appendingPathComponent(path)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no \(path) folder next to this package")
        }
        var text = ""
        for case let url as URL in walker where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += "\n"
        }
        return text
    }
}

// MARK: - The setting itself

final class Build12ModeTests: XCTestCase {
    func testThreeChoicesInPickerOrder() {
        XCTAssertEqual(LiveActivityMode.allCases, [.off, .duringMeetings, .whenListening])
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(LiveActivityMode.off.rawValue, "off")
        XCTAssertEqual(LiveActivityMode.duringMeetings.rawValue, "duringMeetings")
        XCTAssertEqual(LiveActivityMode.whenListening.rawValue, "whenListening")
    }

    func testDefaultIsDuringMeetings() {
        XCTAssertEqual(LiveActivityMode.default, .duringMeetings)
    }

    func testCodableRoundTripUsesTheRawValue() throws {
        for mode in LiveActivityMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(mode.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(LiveActivityMode.self, from: data), mode)
        }
    }

    func testStoredValueFallsBackToTheDefault() {
        XCTAssertEqual(LiveActivityMode.stored(nil), .duringMeetings, "nothing saved yet")
        XCTAssertEqual(LiveActivityMode.stored(""), .duringMeetings)
        XCTAssertEqual(LiveActivityMode.stored("nonsense"), .duringMeetings, "an unknown value never turns it off")
        for mode in LiveActivityMode.allCases {
            XCTAssertEqual(LiveActivityMode.stored(mode.rawValue), mode)
        }
    }

    func testLabelsAndLiveTabLine() {
        XCTAssertEqual(LiveActivityMode.off.label, "Off")
        XCTAssertEqual(LiveActivityMode.duringMeetings.label, "During meetings")
        XCTAssertEqual(LiveActivityMode.whenListening.label, "Whenever listening")
        XCTAssertEqual(LiveActivityMode.duringMeetings.liveTabLine, "Lock Screen: During meetings")
        XCTAssertEqual(LiveActivityMode.off.liveTabLine, "Lock Screen: Off")
        XCTAssertEqual(LiveActivityMode.whenListening.liveTabLine, "Lock Screen: Whenever listening")
    }

    func testFooterIsTheSpecText() {
        XCTAssertEqual(
            LiveActivityMode.footer,
            "Heart rate is still recorded either way. You can also swipe it away on the Lock Screen to hide it until this meeting ends."
        )
    }

    func testCopyHasNoDashes() {
        var words = LiveActivityMode.allCases.flatMap { [$0.label, $0.liveTabLine] }
        words.append(LiveActivityMode.footer)
        for word in words {
            XCTAssertFalse(word.contains("\u{2014}"), "no em dash: \(word)")
            XCTAssertFalse(word.contains("\u{2013}"), "no en dash: \(word)")
        }
    }
}

// MARK: - Off
final class Build12OffTests: XCTestCase {
    func testOffNeverShows() {
        let schedule = MeetingSchedule([B12.meeting("Sync", 0, 30)])
        // Lead-in, inside, tail, after, with and without Go live.
        for minute in [-6.0, -4.0, 0, 10, 29.9, 30, 35, 39.9, 41, 600] {
            for manual in [true, false] {
                XCTAssertFalse(B12.show(.off, schedule, at: minute, manualLive: manual), "off at \(minute) manual \(manual)")
            }
        }
    }

    func testOffNeverShowsForGoLiveWithNoMeetings() {
        XCTAssertFalse(B12.show(.off, MeetingSchedule(), at: 0, manualLive: true))
        XCTAssertFalse(B12.show(.off, MeetingSchedule(), at: 0, manualLive: false))
    }
}

// MARK: - Whenever listening (today's behavior, unchanged)

final class Build12WheneverListeningTests: XCTestCase {
    private let sync = B12.meeting("Sync", 0, 30)
    private var schedule: MeetingSchedule { MeetingSchedule([sync]) }

    func testShowsAcrossTheWholeListeningWindow() {
        // Lead-in is 300 s, the tail is 10 min.
        for minute in [-5.0, -3.0, 0, 15, 29.9, 30, 35, 39.9] {
            XCTAssertTrue(B12.show(.whenListening, schedule, at: minute), "at \(minute)")
        }
    }

    func testShowsForGoLiveOutsideAMeeting() {
        XCTAssertTrue(B12.show(.whenListening, MeetingSchedule(), at: 0, manualLive: true))
        XCTAssertTrue(B12.show(.whenListening, schedule, at: 120, manualLive: true))
    }

    func testNotListeningNeverShows() {
        for minute in [-3.0, 10, 35] {
            XCTAssertFalse(B12.show(.whenListening, schedule, at: minute, listening: false), "at \(minute)")
        }
        XCTAssertFalse(B12.show(.whenListening, MeetingSchedule(), at: 0, listening: false, manualLive: true))
    }

    func testMatchesLiveGlancePlanForEveryMinute() {
        let schedule = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 30, 60), B12.meeting("C", 200, 230)])
        var minute = -10.0
        while minute <= 260 {
            for listening in [true, false] {
                for manual in [true, false] {
                    let content = LiveGlancePlan.content(
                        schedule: schedule, listening: listening, manualSince: manual ? B12.at(minute) : nil,
                        bpm: 70, status: .live, now: B12.at(minute)
                    )
                    XCTAssertEqual(
                        B12.show(.whenListening, schedule, at: minute, listening: listening, manualLive: manual),
                        content != nil,
                        "minute \(minute) listening \(listening) manual \(manual)"
                    )
                }
            }
            minute += 0.5
        }
    }
}

// MARK: - During meetings (the default): lead-in through the end of the last meeting in the block

final class Build12DuringMeetingsTests: XCTestCase {
    private let mode = LiveActivityMode.duringMeetings
    private let sync = B12.meeting("Sync", 0, 30)
    private var schedule: MeetingSchedule { MeetingSchedule([sync]) }

    /// Every quarter minute from `from` up to but not including `to`.
    private func sweep(_ from: Double, _ to: Double) -> [Double] {
        Array(stride(from: from, to: to, by: 0.25))
    }

    // Regression 1: iOS cannot start a Live Activity from the background, so it must be wanted for the whole
    // lead-in, while the app can still be open.
    func testShowsThroughoutTheLeadInWhenListening() {
        for minute in sweep(-5, 0) {
            XCTAssertTrue(B12.show(mode, schedule, at: minute), "lead-in at \(minute)")
        }
        XCTAssertTrue(B12.show(mode, schedule, at: -5), "the first moment of the lead-in")
        XCTAssertTrue(B12.show(mode, schedule, at: -0.01), "just before the start")
    }

    func testDoesNotNeedAReadingFirst() {
        // Waiting for WHOOP still shows as state, so there is no reading input to the rule at all.
        XCTAssertTrue(B12.show(mode, schedule, at: 0))
        XCTAssertTrue(B12.show(mode, schedule, at: 15))
    }

    func testHidesBeforeTheLeadIn() {
        XCTAssertFalse(B12.show(mode, schedule, at: -5.01))
        XCTAssertFalse(B12.show(mode, schedule, at: -30))
        XCTAssertFalse(B12.show(mode, schedule, at: -600))
    }

    func testShowsInsideTheMeeting() {
        for minute in sweep(0, 30) {
            XCTAssertTrue(B12.show(mode, schedule, at: minute), "inside at \(minute)")
        }
    }

    // Regression 3: false right at and after the last meeting end, so there is no 10 minute wrap-up tail.
    func testHidesAtAndAfterTheEnd() {
        XCTAssertFalse(B12.show(mode, schedule, at: 30), "the end itself is outside")
        XCTAssertFalse(B12.show(mode, schedule, at: 30.01))
        for minute in sweep(30, 41) {
            XCTAssertFalse(B12.show(mode, schedule, at: minute), "wrap-up tail at \(minute)")
        }
        XCTAssertFalse(B12.show(mode, schedule, at: 600))
    }

    func testGoLiveOutsideAMeetingNeverShows() {
        XCTAssertFalse(B12.show(mode, MeetingSchedule(), at: 0, manualLive: true))
        XCTAssertFalse(B12.show(mode, MeetingSchedule(), at: 0, manualLive: false))
        // A meeting exists but its block is not on yet, or has ended.
        XCTAssertFalse(B12.show(mode, schedule, at: 120, manualLive: true))
        XCTAssertFalse(B12.show(mode, schedule, at: 35, manualLive: true), "Go live in the tail is outside a meeting")
        XCTAssertFalse(B12.show(mode, schedule, at: 60, manualLive: true))
    }

    func testGoLiveInsideTheBlockFollowsTheBlock() {
        XCTAssertTrue(B12.show(mode, schedule, at: 15, manualLive: true))
        XCTAssertTrue(B12.show(mode, schedule, at: -3, manualLive: true), "the lead-in is part of the block")
    }

    func testNotListeningNeverShows() {
        XCTAssertFalse(B12.show(mode, schedule, at: -3, listening: false))
        XCTAssertFalse(B12.show(mode, schedule, at: 15, listening: false))
        XCTAssertFalse(B12.show(mode, MeetingSchedule(), at: 0, listening: false, manualLive: true))
    }

    func testNoMeetingsNeverShows() {
        for minute in [-60.0, 0, 60, 600] {
            XCTAssertFalse(B12.show(mode, MeetingSchedule(), at: minute), "at \(minute)")
        }
    }

    func testAnExtendedEndKeepsItShowingUntilTheNewEnd() {
        // Still going moved the end from minute 30 to minute 45.
        let original = MeetingSchedule([B12.meeting("Sync", 0, 30)])
        let extended = MeetingSchedule([B12.meeting("Sync", 0, 45)])
        XCTAssertFalse(B12.show(mode, original, at: 40), "without the extension it is the tail")
        for minute in sweep(30, 45) {
            XCTAssertTrue(B12.show(mode, extended, at: minute), "extended at \(minute)")
        }
        XCTAssertFalse(B12.show(mode, extended, at: 45), "the new end is still an end")
        XCTAssertFalse(B12.show(mode, extended, at: 50))
    }

    func testEndedNowHidesRightAway() {
        // Ended now moved the end from minute 30 to minute 20.
        let original = MeetingSchedule([B12.meeting("Sync", 0, 30)])
        let ended = MeetingSchedule([B12.meeting("Sync", 0, 20)])
        XCTAssertTrue(B12.show(mode, original, at: 22))
        XCTAssertFalse(B12.show(mode, ended, at: 22))
        XCTAssertFalse(B12.show(mode, ended, at: 20))
        XCTAssertTrue(B12.show(mode, ended, at: 19.9))
    }

    // Regression 2: back-to-back meetings are one block and one activity, never ended at the boundary.
    func testBackToBackIsContinuousAcrossTheBoundary() {
        let schedule = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 30, 60)])
        for minute in sweep(-5, 60) {
            XCTAssertTrue(B12.show(mode, schedule, at: minute), "back-to-back at \(minute)")
        }
        XCTAssertTrue(B12.show(mode, schedule, at: 29.99))
        XCTAssertTrue(B12.show(mode, schedule, at: 30), "B starts the moment A ends")
        XCTAssertTrue(B12.show(mode, schedule, at: 30.01))
        XCTAssertFalse(B12.show(mode, schedule, at: 60), "the end of the last meeting")
        XCTAssertFalse(B12.show(mode, schedule, at: 65))
    }

    func testAGapInsideOneBlockDoesNotEndIt() {
        // A ends at 30, B starts at 36: B's lead-in overlaps A's tail, so it is one block and one activity.
        let schedule = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 36, 60)])
        for minute in sweep(-5, 60) {
            XCTAssertTrue(B12.show(mode, schedule, at: minute), "one block at \(minute)")
        }
        XCTAssertFalse(B12.show(mode, schedule, at: 60))
    }

    func testExtendingTheLastBackToBackMeetingMovesTheEnd() {
        let extended = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 30, 70)])
        XCTAssertTrue(B12.show(mode, extended, at: 65))
        XCTAssertFalse(B12.show(mode, extended, at: 70))
    }

    func testEndingTheLastBackToBackMeetingEarlyEndsIt() {
        let ended = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 30, 50)])
        XCTAssertTrue(B12.show(mode, ended, at: 49.9))
        XCTAssertFalse(B12.show(mode, ended, at: 50))
        XCTAssertFalse(B12.show(mode, ended, at: 55))
    }

    func testSeparateBlocksEachGetTheirOwnWindowWithAGapBetween() {
        // A's block ends at minute 30, B's lead-in starts at minute 55.
        let schedule = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 60, 90)])
        XCTAssertTrue(B12.show(mode, schedule, at: 29.9))
        XCTAssertFalse(B12.show(mode, schedule, at: 30))
        XCTAssertFalse(B12.show(mode, schedule, at: 45), "between blocks")
        XCTAssertFalse(B12.show(mode, schedule, at: 54.9))
        XCTAssertTrue(B12.show(mode, schedule, at: 55), "B's lead-in")
        XCTAssertTrue(B12.show(mode, schedule, at: 75))
        XCTAssertFalse(B12.show(mode, schedule, at: 90))
    }

    func testOverlappingMeetingsShowUntilTheLatestEnd() {
        let schedule = MeetingSchedule([B12.meeting("A", 0, 40), B12.meeting("B", 20, 30)])
        XCTAssertTrue(B12.show(mode, schedule, at: 35), "A is still on after B ends")
        XCTAssertFalse(B12.show(mode, schedule, at: 40))
    }

    func testDuringMeetingsIsNeverBroaderThanWheneverListening() {
        let schedule = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 36, 60), B12.meeting("C", 300, 330)])
        var minute = -10.0
        while minute <= 400 {
            for listening in [true, false] {
                for manual in [true, false] {
                    if B12.show(mode, schedule, at: minute, listening: listening, manualLive: manual) {
                        XCTAssertTrue(
                            B12.show(.whenListening, schedule, at: minute, listening: listening, manualLive: manual),
                            "minute \(minute)"
                        )
                    }
                }
            }
            minute += 0.5
        }
    }

    func testDuringMeetingsIsTheListeningWindowMinusTheWrapUpTail() {
        // The whole rule in one sweep: on exactly when listening, inside a block, and before that block's last end.
        let schedule = MeetingSchedule([B12.meeting("A", 0, 30), B12.meeting("B", 30, 60), B12.meeting("C", 200, 230)])
        for minute in sweep(-20, 260) {
            let expected = (minute >= -5 && minute < 60) || (minute >= 195 && minute < 230)
            XCTAssertEqual(B12.show(mode, schedule, at: minute), expected, "minute \(minute)")
        }
    }
}

// MARK: - Compact Dynamic Island label and "In meeting" title line

final class Build12CompactLabelTests: XCTestCase {
    private let end = B12.at(30)

    func testMinutesLeftDuringAMeeting() {
        // Minutes round up, like a countdown: 11m30s left reads 12m.
        XCTAssertEqual(B12.content(at: 0).compactLabel(now: B12.at(0)), .minutesLeft(30, end: end))
        XCTAssertEqual(B12.content(at: 18).compactLabel(now: B12.at(18)), .minutesLeft(12, end: end))
        XCTAssertEqual(B12.content(at: 18.5).compactLabel(now: B12.at(18.5)), .minutesLeft(12, end: end))
        XCTAssertEqual(B12.content(at: 18.01).compactLabel(now: B12.at(18.01)), .minutesLeft(12, end: end))
        XCTAssertEqual(B12.content(at: 28.5).compactLabel(now: B12.at(28.5)), .minutesLeft(2, end: end))
        XCTAssertEqual(B12.content(at: 29).compactLabel(now: B12.at(29)), .minutesLeft(1, end: end), "exactly one minute left")
    }

    func testMinutesLeftText() {
        XCTAssertEqual(B12.content(at: 18).compactLabel(now: B12.at(18)).text, "12m")
        XCTAssertEqual(B12.content(at: 29).compactLabel(now: B12.at(29)).text, "1m")
        XCTAssertEqual(B12.content(at: 0).compactLabel(now: B12.at(0)).text, "30m")
    }

    func testLongMeetingStillFitsAboutFourCharacters() {
        let long = MeetingSchedule([B12.meeting("Offsite", 0, 480)])
        let text = B12.content(at: 0, schedule: long).compactLabel(now: B12.at(0)).text
        XCTAssertEqual(text, "480m")
        XCTAssertLessThanOrEqual(text?.count ?? 99, 4)
    }

    func testUnderAMinuteIsLessThanOneMinute() {
        for minute in [29.01, 29.5, 29.99] {
            XCTAssertEqual(
                B12.content(at: minute).compactLabel(now: B12.at(minute)), .lessThanAMinute(end: end), "at \(minute)"
            )
        }
        XCTAssertEqual(B12.content(at: 29.5).compactLabel(now: B12.at(29.5)).text, "<1m")
    }

    func testTheTimerEndIsTheEffectiveEnd() {
        // Still going moved the end to minute 45: the label counts to the new end.
        let extended = MeetingSchedule([B12.meeting("Sync", 0, 45)])
        let label = B12.content(at: 31, schedule: extended).compactLabel(now: B12.at(31))
        XCTAssertEqual(label, .minutesLeft(14, end: B12.at(45)))
    }

    func testLeadInShowsStartsIn() {
        // Whenever listening has a five minute lead-in.
        XCTAssertEqual(B12.content(at: -3).compactLabel(now: B12.at(-3)), .startsIn(minutes: 3))
        XCTAssertEqual(B12.content(at: -3).compactLabel(now: B12.at(-3)).text, "in 3m")
        XCTAssertEqual(B12.content(at: -5).compactLabel(now: B12.at(-5)).text, "in 5m")
        XCTAssertEqual(B12.content(at: -2.5).compactLabel(now: B12.at(-2.5)), .startsIn(minutes: 3), "rounds up")
        XCTAssertEqual(B12.content(at: -1).compactLabel(now: B12.at(-1)).text, "in 1m")
        XCTAssertEqual(B12.content(at: -0.5).compactLabel(now: B12.at(-0.5)).text, "in 1m", "never in 0m")
    }

    func testWrapUpHasNoTextJustTheRing() {
        let label = B12.content(at: 35).compactLabel(now: B12.at(35))
        XCTAssertEqual(label, .ring)
        XCTAssertNil(label.text)
    }

    func testGoLiveOutsideAMeetingSaysLive() {
        let content = B12.content(at: 120, manualSince: B12.at(100))
        XCTAssertEqual(content.phase, .open)
        XCTAssertEqual(content.compactLabel(now: B12.at(120)), .live)
        XCTAssertEqual(content.compactLabel(now: B12.at(120)).text, "Live")
        let alone = B12.content(at: 0, manualSince: B12.at(-1), schedule: MeetingSchedule())
        XCTAssertEqual(alone.compactLabel(now: B12.at(0)), .live)
    }

    func testTheLabelDoesNotDependOnTheBPMOrStatus() {
        var content = B12.content(at: 10)
        let expected = content.compactLabel(now: B12.at(10))
        content.bpm = nil
        content.status = .reconnecting
        XCTAssertEqual(content.compactLabel(now: B12.at(10)), expected)
        content.status = .waiting
        XCTAssertEqual(content.compactLabel(now: B12.at(10)), expected)
    }

    func testTextIsShortAndHasNoDashes() {
        let labels: [CompactLabel] = [
            .minutesLeft(12, end: end), .lessThanAMinute(end: end), .startsIn(minutes: 3), .live,
        ]
        for label in labels {
            let text = label.text ?? ""
            XCTAssertLessThanOrEqual(text.count, 5, text)
            XCTAssertFalse(text.contains("\u{2014}"))
            XCTAssertFalse(text.contains("\u{2013}"))
        }
    }

    // MARK: Title line

    func testTitleLineSaysInMeetingDuringTheMeeting() {
        XCTAssertEqual(LiveGlanceContent.inMeetingPrefix, "In meeting \u{B7} ")
        let line = B12.content(at: 10).titleLine
        XCTAssertEqual(line, "In meeting \u{B7} Sync")
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    func testTitleLineIsThePlainTitleOutsideTheMeeting() {
        XCTAssertEqual(B12.content(at: -3).titleLine, "Sync", "lead-in")
        XCTAssertEqual(B12.content(at: 35).titleLine, "Sync", "wrap-up")
        XCTAssertEqual(B12.content(at: 120, manualSince: B12.at(100)).titleLine, LiveGlancePlan.goLiveTitle)
    }

    func testTitleLineKeepsTheWholeTitleForTheViewToCut() {
        let long = MeetingSchedule([B12.meeting("Quarterly planning review with the whole leadership team", 0, 30)])
        let line = B12.content(at: 5, schedule: long).titleLine
        XCTAssertEqual(line, "In meeting \u{B7} Quarterly planning review with the whole leadership team")
    }

    func testTheTitleFieldItselfIsUnchanged() {
        XCTAssertEqual(B12.content(at: 10).title, "Sync", "the prefix is added on display, not stored in the content state")
    }

    func testTheWidgetUsesTheSharedLabelAndTitleLine() throws {
        let widget = try B12.read("ios/MeetspikeHR/Widgets/MeetspikeWidgets.swift")
        XCTAssertTrue(widget.contains("compactLabel"), "compact trailing draws the shared label")
        XCTAssertTrue(widget.contains("titleLine"), "expanded and Lock Screen use the shared title line")
    }
}

// MARK: - Version and What's new

final class Build12ReleaseTests: XCTestCase {
    func testBuild12IsTheNewestReleaseNote() throws {
        let release = try XCTUnwrap(ReleaseNotes.all.first)
        XCTAssertEqual(release.build, 12)
        XCTAssertFalse(release.items.isEmpty)
        let text = release.items.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("lock screen"), "says what changed")
        XCTAssertTrue(text.contains("during meetings"), "says when it shows now")
        XCTAssertTrue(text.contains("menu"), "says where to change it")
        XCTAssertTrue(text.contains("this iphone"), "says where to change it")
        for item in release.items {
            XCTAssertFalse(item.contains("\u{2014}"), "no em dash: \(item)")
            XCTAssertFalse(item.contains("\u{2013}"), "no en dash: \(item)")
            XCTAssertLessThan(item.count, 120, "short, plain, one line: \(item)")
        }
    }

    func testTheLockScreenNoteIsTheFixPassText() throws {
        let release = try XCTUnwrap(ReleaseNotes.all.first)
        XCTAssertTrue(
            release.items.contains("Lock Screen heart rate is now During meetings: it ends with the meeting. Change it in Menu, This iPhone."),
            "the note says it ends with the meeting"
        )
        let text = release.items.joined(separator: " ")
        XCTAssertFalse(text.contains("once heart rate is coming in"), "the reading condition is gone")
    }

    func testBuilds12And11AreBothListed() {
        XCTAssertEqual(Array(ReleaseNotes.all.map(\.build).prefix(3)), [12, 11, 10])
        XCTAssertEqual(Set(ReleaseNotes.all.map(\.build)).count, ReleaseNotes.all.count, "one note per build")
    }

    func testTestFlightNotesAndWhatsNewForBuild12() throws {
        let text = try XCTUnwrap(ReleaseNotes.notesText(build: 12))
        XCTAssertTrue(text.hasPrefix("- "))
        XCTAssertEqual(text.components(separatedBy: "\n").count, try XCTUnwrap(ReleaseNotes.all.first).items.count)
        let update = WhatsNew.decide(stored: 11, existingInstall: true, current: 12)
        XCTAssertEqual(update.releases.map(\.build), [12])
        XCTAssertEqual(update.store, 12)
        XCTAssertEqual(ReleaseNotes.unseen(lastSeen: nil, current: 12), [], "a fresh install sees nothing")
    }

    func testProjectIsBuild12WithOneBuildNumber() throws {
        let yml = try B12.read("ios/MeetspikeHR/project.yml")
        let values = yml.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "CURRENT_PROJECT_VERSION:") else { return nil }
            return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(Set(values), ["\"12\""], "a single build value, 12, on every target")
    }

    func testNewestNoteMatchesTheProjectVersion() throws {
        let yml = try B12.read("ios/MeetspikeHR/project.yml")
        let release = try XCTUnwrap(ReleaseNotes.all.first)
        XCTAssertTrue(yml.contains("CURRENT_PROJECT_VERSION: \"\(release.build)\""))
        XCTAssertTrue(yml.contains("MARKETING_VERSION: \"\(release.version)\""))
    }
}

// MARK: - App wiring and docs (source reads, the app target cannot build here)

final class Build12AppSourceTests: XCTestCase {
    func testTheControllerAsksTheRuleBeforeBuildingContent() throws {
        let source = try B12.read("ios/MeetspikeHR/Sources/Glance/LiveActivityController.swift")
        XCTAssertTrue(source.contains("LiveActivityRule.shouldShow"), "the controller asks the shared rule")
        XCTAssertTrue(source.contains("LiveActivityMode"), "the controller takes the mode")
    }

    func testSettingTheModeDoesNotWriteDefaultsInDemoMode() throws {
        let source = try B12.read("ios/MeetspikeHR/Sources/PhoneModel.swift")
        let start = try XCTUnwrap(source.range(of: "func setLiveActivityMode"), "PhoneModel has setLiveActivityMode")
        // The body runs to the next function at the same indent.
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    func ", range: rest.index(after: rest.startIndex)..<rest.endIndex)?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        let write = try XCTUnwrap(body.range(of: "defaults.set"), "the choice is saved to defaults")
        let guardRange = try XCTUnwrap(body.range(of: "guard !isDemo"), "there is a demo guard")
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: guardRange.lowerBound),
            body.distance(from: body.startIndex, to: write.lowerBound),
            "the demo guard comes before the defaults write, so demo mode never saves the choice"
        )
    }

    func testTheModelDoesNotSaveTheModeBeforeAnyDemoGuardElsewhere() throws {
        let source = try B12.read("ios/MeetspikeHR/Sources/PhoneModel.swift")
        XCTAssertFalse(
            source.contains("defaults.set(mode.rawValue, forKey: LiveActivityMode.storageKey)\n        guard !isDemo"),
            "the write must not sit above the guard"
        )
    }

    func testTheSettingIsOfferedInTheMenuPhoneSettingsAndLiveTab() throws {
        let all = try B12.swiftSources(under: "ios/MeetspikeHR/Sources")
        XCTAssertTrue(all.contains("Lock Screen heart rate"), "the row and picker title")
        XCTAssertTrue(all.contains("LiveActivityMode.footer"), "the footer text comes from the shared constant")
        XCTAssertTrue(all.contains("liveTabLine"), "the Live tab line")
        let more = try B12.read("ios/MeetspikeHR/Sources/More/MoreScreen.swift")
        XCTAssertTrue(more.contains("Lock Screen heart rate"), "Menu, This iPhone")
        let settings = try B12.read("ios/MeetspikeHR/Sources/SettingsView.swift")
        XCTAssertTrue(settings.contains("Lock Screen heart rate"), "Phone settings, Meetings section")
    }

    func testDocsMentionTheSetting() throws {
        let docs = try B12.read("docs/IPHONE-ONBOARDING.md")
        XCTAssertTrue(docs.contains("Lock Screen heart rate"))
        XCTAssertTrue(docs.contains("During meetings"))
    }
}
