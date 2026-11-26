import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9 iPhone spec: "Listening windows use effective times and skip excluded meetings. Overrides from the Worker
// are matched to EventKit meetings by original start (+-90 s) and title; ambiguous = not applied." And "Must not
// break: live listening when overrides can't load (use the calendar)". Settled: CalendarMeeting has an internal init
// that allows up to 12 h for effective windows; the public 8 h limit stays. One Worker meeting that is the single
// candidate for two phone copies applies to both.
//
// These tests build the schedule the way MeetingCalendar.rebuild does (OverrideMatch.resolve, then MeetingSchedule of
// the effective meetings). MeetingCalendar itself needs EventKit and cannot run here; see the report.
// A listening window is 5 minutes before the start (build 11, was 2) to 10 minutes after the end.

final class Build9HelpersWindowTests: XCTestCase {
    private let lead: TimeInterval = 300
    private let tail: TimeInterval = 600

    /// What MeetingCalendar builds from the phone's meetings and the Worker's list.
    private func schedule(_ phone: [CalendarMeeting], _ remote: [RemoteMeeting]) -> MeetingSchedule {
        MeetingSchedule(OverrideMatch.resolve(remote, to: MeetingSchedule(phone).meetings).compactMap(\.effective))
    }

    // MARK: No overrides loaded is the calendar exactly as before

    func testNoOverridesLoadedGivesTheCalendarExactly() {
        let phone = [B9.meeting("Standup", 0, 1800), B9.meeting("Review", 3600, 7200), B9.meeting("Late", 9000, 9600)]
        let before = MeetingSchedule(phone)
        let after = schedule(phone, [])
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.blocks, before.blocks)
        for offset in stride(from: -600.0, through: 11_000.0, by: 90.0) {
            XCTAssertEqual(after.activeBlock(at: B9.at(offset)), before.activeBlock(at: B9.at(offset)), "\(offset)")
            XCTAssertEqual(after.displayedMeeting(at: B9.at(offset)), before.displayedMeeting(at: B9.at(offset)), "\(offset)")
            XCTAssertEqual(after.nextBoundary(after: B9.at(offset)), before.nextBoundary(after: B9.at(offset)), "\(offset)")
        }
        for resolved in OverrideMatch.resolve([], to: phone) {
            XCTAssertEqual(resolved.effective, resolved.original)
            XCTAssertNil(resolved.remote, "nothing matched, so a button has no meeting to change")
        }
    }

    func testAWorkerListWithNothingChosenAlsoChangesNothing() {
        // The Worker lists a meeting only to say which series it is in.
        let phone = [B9.meeting("Standup", 0, 1800)]
        let remote = [H9.remote("s_20261125", override: MeetingOverride(seriesId: "s"))]
        XCTAssertEqual(schedule(phone, remote), MeetingSchedule(phone))
        // And the Mac's guess alone changes nothing.
        let guess = [H9.remote("s_20261125", override: MeetingOverride(seenNone: true, seriesId: "s"))]
        XCTAssertEqual(schedule(phone, guess), MeetingSchedule(phone))
    }

    // MARK: Effective times

    func testListeningFollowsALaterEnd() throws {
        let phone = [B9.meeting("Standup", 0, 1800)]
        let remote = [H9.remote(override: MeetingOverride(endUtc: B9.at(3600)))]
        let result = schedule(phone, remote)
        let block = try XCTUnwrap(result.blocks.first)
        XCTAssertEqual(block.start, B9.at(-lead))
        XCTAssertEqual(block.end, B9.at(3600 + tail))
        // 45 minutes in: past the calendar's end and its cooldown, but inside the real meeting.
        XCTAssertNotNil(result.activeBlock(at: B9.at(2700)))
        XCTAssertNil(MeetingSchedule(phone).activeBlock(at: B9.at(2700)))
        XCTAssertEqual(result.displayedMeeting(at: B9.at(2700))?.end, B9.at(3600))
        XCTAssertEqual(result.nextBoundary(after: B9.at(0)), B9.at(3600 + tail))
    }

    func testListeningFollowsAnEarlierStartAndTheMacsSighting() throws {
        let phone = [B9.meeting("Standup", 0, 1800)]
        let byPerson = schedule(phone, [H9.remote(override: MeetingOverride(startUtc: B9.at(-1200)))])
        XCTAssertEqual(byPerson.blocks.first?.start, B9.at(-1200 - lead))
        XCTAssertNotNil(byPerson.activeBlock(at: B9.at(-1300)))

        let seen = MeetingOverride(seenStartUtc: B9.at(-300), seenEndUtc: B9.at(2100))
        let byMac = schedule(phone, [H9.remote(override: seen)])
        XCTAssertEqual(byMac.blocks.first?.start, B9.at(-300 - lead))
        XCTAssertEqual(byMac.blocks.first?.end, B9.at(2100 + tail))

        let both = MeetingOverride(startUtc: B9.at(-600), endUtc: B9.at(2400), seenStartUtc: B9.at(-300), seenEndUtc: B9.at(2100))
        let chosen = try XCTUnwrap(schedule(phone, [H9.remote(override: both)]).meetings.first)
        XCTAssertEqual(chosen.start, B9.at(-600), "the person's time beats the Mac's")
        XCTAssertEqual(chosen.end, B9.at(2400))
    }

    func testTimesOutsideTheLimitsAreIgnoredSoTheWindowIsTheCalendars() {
        let phone = [B9.meeting("Standup", 0, 1800)]
        let tooEarly = MeetingOverride(startUtc: B9.at(-2 * 3600 - 1))
        let tooLate = MeetingOverride(endUtc: B9.at(1800 + 4 * 3600 + 1))
        for override in [tooEarly, tooLate] {
            XCTAssertEqual(schedule(phone, [H9.remote(override: override)]), MeetingSchedule(phone), "\(override)")
        }
        // A start after the end cannot be a window: that pair is skipped and the next source is used for the start.
        let inverted = schedule(phone, [H9.remote(override: MeetingOverride(startUtc: B9.at(2000), endUtc: B9.at(1000)))])
        let window = inverted.meetings.first
        XCTAssertNotNil(window)
        XCTAssertTrue((window?.end ?? .distantPast) > (window?.start ?? .distantFuture), "always a valid window")
        // The limits themselves are allowed.
        let edge = schedule(phone, [H9.remote(override: MeetingOverride(startUtc: B9.at(-2 * 3600), endUtc: B9.at(1800 + 4 * 3600)))])
        XCTAssertEqual(edge.meetings.first?.start, B9.at(-2 * 3600))
        XCTAssertEqual(edge.meetings.first?.end, B9.at(1800 + 4 * 3600))
    }

    func testTheEffectiveWindowCanBeTwelveHoursButAPhoneEventStillCannot() throws {
        // The public init keeps its 8 hour limit for EventKit events.
        XCTAssertNotNil(CalendarMeeting(title: "Day", start: B9.at(0), end: B9.at(8 * 3600)))
        XCTAssertNil(CalendarMeeting(title: "Day", start: B9.at(0), end: B9.at(8 * 3600 + 1)))
        // An 8 hour meeting that the person says ran 4 hours longer is a 12 hour window, and it must not vanish.
        let phone = [B9.meeting("Workshop", 0, 8 * 3600)]
        let remote = [H9.remote(title: "Workshop", start: 0, end: 8 * 3600, override: MeetingOverride(endUtc: B9.at(12 * 3600)))]
        let result = try XCTUnwrap(schedule(phone, remote).meetings.first)
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 12 * 3600)
        XCTAssertEqual(result.title, "Workshop")
    }

    func testAnOverrideThatEqualsTheCalendarChangesNothing() throws {
        let phone = [B9.meeting("Workshop", 0, 8 * 3600)]
        let result = try XCTUnwrap(schedule(phone, [H9.remote(title: "Workshop", start: 0, end: 8 * 3600, override: MeetingOverride(startUtc: B9.at(0)))]).meetings.first)
        XCTAssertEqual(result, phone[0])
    }

    func testEffectiveTimesAreRealElapsedTimeInEveryZone() {
        B9.inZones(B9.zones) { zone in
            let start = B9.fallBackInstant.addingTimeInterval(-600)
            let end = start.addingTimeInterval(3600)
            let phone = [CalendarMeeting(title: "Standup", start: start, end: end)].compactMap { $0 }
            let override = MeetingOverride(endUtc: end.addingTimeInterval(1800))
            let remote = [RemoteMeeting(id: "e", title: "Standup", calendarStart: start, calendarEnd: end, override: override)]
            let moved = MeetingSchedule(OverrideMatch.apply(remote, to: phone)).meetings.first
            XCTAssertEqual(moved?.start, start, zone)
            XCTAssertEqual(moved?.end, end.addingTimeInterval(1800), zone)
            XCTAssertEqual(moved?.listenUntil, end.addingTimeInterval(1800 + 600), zone)
        }
    }

    // MARK: Exclusions

    func testLeftOutMeetingsHaveNoWindow() {
        for state in [MeetingOverride.State.notJoined, .unlinked] {
            let phone = [B9.meeting("Standup", 0, 1800)]
            let result = schedule(phone, [H9.remote(override: MeetingOverride(state: state, scope: .event))])
            XCTAssertTrue(result.meetings.isEmpty, "\(state)")
            XCTAssertTrue(result.blocks.isEmpty, "\(state)")
            XCTAssertNil(result.activeBlock(at: B9.at(600)), "\(state)")
            XCTAssertNil(result.displayedMeeting(at: B9.at(600)), "\(state)")
            XCTAssertNil(result.nextBoundary(after: B9.at(-3600)), "\(state): the phone has no reason to wake")
        }
    }

    func testASeriesRuleLeavesOutMeetingsTheWorkerMarkedSo() {
        // The Worker puts the resolved state on each meeting (scope series), so the phone only has to read it.
        let rule = MeetingOverride(state: .notJoined, scope: .series, seriesId: "s")
        let phone = [B9.meeting("Standup", 0, 1800)]
        XCTAssertTrue(schedule(phone, [H9.remote("s_20261125", override: rule)]).meetings.isEmpty)
    }

    func testLinkedOnAMeetingKeepsItEvenInAnExcludedSeries() {
        let optedOut = MeetingOverride(state: .linked, scope: .event, seriesId: "s")
        let phone = [B9.meeting("Standup", 0, 1800)]
        XCTAssertEqual(schedule(phone, [H9.remote("s_20261125", override: optedOut)]), MeetingSchedule(phone))
    }

    func testLeavingOutTheMiddleMeetingSplitsTheBlock() {
        let phone = [B9.meeting("A", 0, 1800), B9.meeting("B", 1800, 3600), B9.meeting("C", 3600, 5400)]
        XCTAssertEqual(MeetingSchedule(phone).blocks.count, 1, "back to back is one block")
        let remote = [H9.remote("b", title: "B", start: 1800, end: 3600, override: MeetingOverride(state: .notJoined, scope: .event))]
        let result = schedule(phone, remote)
        XCTAssertEqual(result.meetings.map(\.title), ["A", "C"])
        // A ends at 1800 + 600 of cooldown, C starts listening at 3600 - 300: a gap of 900 s.
        XCTAssertEqual(result.blocks.count, 2)
        XCTAssertNil(result.activeBlock(at: B9.at(2700)), "not listening in the middle of the left out meeting")
        XCTAssertNotNil(result.activeBlock(at: B9.at(900)))
        XCTAssertNotNil(result.activeBlock(at: B9.at(4000)))
    }

    func testOnlyTheNamedMeetingIsLeftOut() {
        let phone = [B9.meeting("Standup", 0, 1800), B9.meeting("Standup", 86_400, 88_200)]
        let remote = [
            H9.remote("d1", start: 0, end: 1800, override: MeetingOverride(state: .notJoined, scope: .event)),
            H9.remote("d2", start: 86_400, end: 88_200),
        ]
        XCTAssertEqual(schedule(phone, remote).meetings, [phone[1]])
    }

    // MARK: Matching and ambiguity

    func testMatchesByOriginalStartWithin90SecondsAndTheSameTitle() {
        let excluded = MeetingOverride(state: .notJoined, scope: .event)
        let phone = [B9.meeting("Standup", 0, 1800)]
        // The Worker's start may differ by up to 90 s (inclusive), either way.
        for shift in [-90.0, -45, 0, 45, 90] {
            XCTAssertTrue(schedule(phone, [H9.remote(start: shift, end: shift + 1800, override: excluded)]).meetings.isEmpty, "\(shift)")
        }
        for shift in [-91.0, 91, 3600] {
            XCTAssertEqual(schedule(phone, [H9.remote(start: shift, end: shift + 1800, override: excluded)]), MeetingSchedule(phone), "\(shift)")
        }
        // Title: trimmed and case-insensitive, nothing more.
        XCTAssertTrue(schedule(phone, [H9.remote(title: "  STANDUP \n", override: excluded)]).meetings.isEmpty)
        XCTAssertEqual(schedule(phone, [H9.remote(title: "Standup 2", override: excluded)]), MeetingSchedule(phone))
        XCTAssertEqual(schedule(phone, [H9.remote(title: "", override: excluded)]), MeetingSchedule(phone))
    }

    func testMatchingUsesTheOriginalStartNotTheMovedOne() {
        // The phone has the calendar's start. The person moved this meeting an hour later on the Worker.
        let phone = [B9.meeting("Standup", 0, 1800)]
        let override = MeetingOverride(startUtc: B9.at(3600), endUtc: B9.at(5400), calendarStartUtc: B9.at(0), calendarEndUtc: B9.at(1800))
        let remote = [H9.remote("e", start: 0, end: 1800, override: override)]
        let result = schedule(phone, remote).meetings.first
        XCTAssertEqual(result?.start, B9.at(3600))
        XCTAssertEqual(result?.end, B9.at(5400))
    }

    func testTwoCandidatesMeanNothingIsApplied() {
        let excluded = MeetingOverride(state: .notJoined, scope: .event)
        let phone = [B9.meeting("Standup", 0, 1800)]
        let twin = [H9.remote("a", override: excluded), H9.remote("b", start: 30, end: 1830, override: nil)]
        XCTAssertEqual(schedule(phone, twin), MeetingSchedule(phone), "an ambiguous match never hides a meeting")
        XCTAssertNil(OverrideMatch.resolve(twin, to: phone)[0].remote, "and gives a button nothing to act on")
        // Moved times are not applied either.
        let moved = [
            H9.remote("a", override: MeetingOverride(endUtc: B9.at(3600))),
            H9.remote("b", override: MeetingOverride(endUtc: B9.at(3000))),
        ]
        XCTAssertEqual(schedule(phone, moved), MeetingSchedule(phone))
    }

    func testOneWorkerMeetingForTwoPhoneCopiesAppliesToBoth() {
        let phone = [B9.meeting("Standup", 0, 1800), B9.meeting("Standup", 20, 1820)]
        let remote = [H9.remote(override: MeetingOverride(state: .notJoined, scope: .event))]
        XCTAssertTrue(schedule(phone, remote).meetings.isEmpty)
        let moved = schedule(phone, [H9.remote(override: MeetingOverride(endUtc: B9.at(2400)))])
        XCTAssertEqual(moved.meetings.map(\.end), [B9.at(2400), B9.at(2400)])
    }

    func testTheListKeepsItsOrderWhenOneMeetingIsDropped() {
        let phone = [B9.meeting("A", 0, 600), B9.meeting("B", 7200, 7800), B9.meeting("C", 14_400, 15_000)]
        let remote = [H9.remote("b", title: "B", start: 7200, end: 7800, override: MeetingOverride(state: .unlinked, scope: .event))]
        XCTAssertEqual(OverrideMatch.apply(remote, to: phone).map(\.title), ["A", "C"])
    }

    // MARK: Which Worker meeting a button changes

    func testLiveButtonsNameTheWorkerMeetingTheDisplayedOneMatched() throws {
        let phone = [B9.meeting("Standup", 0, 1800)]
        let override = MeetingOverride(endUtc: B9.at(2400), calendarStartUtc: B9.at(0), calendarEndUtc: B9.at(1800))
        let remote = [H9.remote("ev-42", start: 0, end: 1800, override: override)]
        let resolved = OverrideMatch.resolve(remote, to: phone)
        let shown = try XCTUnwrap(schedule(phone, remote).displayedMeeting(at: B9.at(900)))

        let target = try XCTUnwrap(LiveAdjust.target(displayed: shown, resolved: resolved))
        XCTAssertEqual(target.meetingID, "ev-42")
        XCTAssertEqual(target.title, "Standup")
        XCTAssertEqual(target.start, B9.at(0))
        XCTAssertEqual(target.end, B9.at(2400), "the times the phone is using now")
        XCTAssertEqual(target.calendarEnd, B9.at(1800), "the cap counts from the calendar's end")
    }

    func testLiveButtonsHaveNoTargetWhenTheMatchIsNotExactlyOne() throws {
        let phone = [B9.meeting("Standup", 0, 1800)]
        let shown = try XCTUnwrap(MeetingSchedule(phone).displayedMeeting(at: B9.at(900)))
        XCTAssertNil(LiveAdjust.target(displayed: shown, resolved: OverrideMatch.resolve([], to: phone)), "nothing loaded")
        let twin = [H9.remote("a"), H9.remote("b")]
        XCTAssertNil(LiveAdjust.target(displayed: shown, resolved: OverrideMatch.resolve(twin, to: phone)), "ambiguous")
        let none = [H9.remote("x", title: "Other")]
        XCTAssertNil(LiveAdjust.target(displayed: shown, resolved: OverrideMatch.resolve(none, to: phone)), "no match")
        XCTAssertNil(LiveAdjust.target(displayed: nil, resolved: OverrideMatch.resolve([H9.remote()], to: phone)), "nothing shown")
    }
}
