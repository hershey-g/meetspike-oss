import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 9, shared Swift contract: `OverrideMatch`, which lays the Worker's overrides over the phone's EventKit meetings.
//
// NEW API (names fixed here):
//
//   public struct RemoteMeeting: Equatable, Sendable
//       public var id: String, title: String, calendarStart: Date, calendarEnd: Date, override: MeetingOverride?
//       public init(id: String, title: String, calendarStart: Date, calendarEnd: Date, override: MeetingOverride?)
//   public enum OverrideMatch
//       public static func apply(_ overrides: [RemoteMeeting], to meetings: [CalendarMeeting]) -> [CalendarMeeting]
//
// Rules: a Worker meeting is a candidate for a phone meeting when its calendarStart is within 90 s of the phone
// meeting's start (90 s itself counts) and the titles are equal after trimming spaces and ignoring case. Exactly one
// candidate: its override is applied. Two or more candidates (whatever their overrides say, even nil): the phone meeting
// is left exactly as it is (an ambiguous match never hides or moves a meeting). No candidate: left as it is.
// Applying: excluded (not_joined, unlinked) meetings are dropped, every other one gets `OverrideRules.effective` times.
// Title and the order of the list are kept. The phone's 8 h limit on a CalendarMeeting is for EventKit events; the
// effective window can be up to 12 h, so an override must not make a meeting vanish by growing it past 8 h.
//
// Settled: one Worker meeting that is the single candidate of TWO phone meetings (the same event on two calendars) is
// applied to both. Ambiguity is counted from the phone meeting's side: how many Worker meetings could it be.

final class Build9OverrideMatchTests: XCTestCase {
    /// A Worker meeting, titled "Standup" and 30 minutes long unless a title or times are given.
    private func remote(
        _ override: MeetingOverride?, start: TimeInterval = 0, end: TimeInterval = 1800, id: String = "ev1"
    ) -> RemoteMeeting {
        remote("Standup", start: start, end: end, override, id: id)
    }

    private func remote(
        start: TimeInterval, end: TimeInterval = 1800, _ override: MeetingOverride?, id: String = "ev1"
    ) -> RemoteMeeting {
        remote("Standup", start: start, end: end, override, id: id)
    }

    private func remote(
        _ title: String, start: TimeInterval = 0, end: TimeInterval = 1800, _ override: MeetingOverride?, id: String = "ev1"
    ) -> RemoteMeeting {
        RemoteMeeting(id: id, title: title, calendarStart: B9.at(start), calendarEnd: B9.at(end), override: override)
    }

    private let excludedOverride = MeetingOverride(state: .notJoined, scope: .event)

    // MARK: The basic cases

    func testNothingToApplyChangesNothing() {
        let meetings = [B9.meeting("Standup", 0, 1800)]
        XCTAssertEqual(OverrideMatch.apply([], to: meetings), meetings)
        XCTAssertEqual(OverrideMatch.apply([remote(excludedOverride)], to: []), [])
        XCTAssertEqual(OverrideMatch.apply([], to: []), [])
    }

    func testNotJoinedAndUnlinkedMeetingsAreDropped() {
        for state in [MeetingOverride.State.notJoined, .unlinked] {
            let result = OverrideMatch.apply(
                [remote(MeetingOverride(state: state, scope: .event))], to: [B9.meeting("Standup", 0, 1800)])
            XCTAssertEqual(result, [], "\(state)")
        }
    }

    func testASeriesStateDropsTheMeetingToo() {
        // The Worker has already resolved series against event; scope only says where the state came from.
        let result = OverrideMatch.apply(
            [remote(MeetingOverride(state: .unlinked, scope: .series, seriesId: "s1"))], to: [B9.meeting("Standup", 0, 1800)])
        XCTAssertEqual(result, [])
    }

    func testALinkedMeetingStaysAndAMeetingWithNoOverrideStays() {
        let meeting = B9.meeting("Standup", 0, 1800)
        XCTAssertEqual(OverrideMatch.apply([remote(MeetingOverride(state: .linked, scope: .event))], to: [meeting]), [meeting])
        XCTAssertEqual(OverrideMatch.apply([remote(nil)], to: [meeting]), [meeting])
        XCTAssertEqual(OverrideMatch.apply([remote(MeetingOverride())], to: [meeting]), [meeting])
    }

    func testUserTimesBecomeTheMeetingsTimesAndTheTitleIsKept() throws {
        let override = MeetingOverride(startUtc: B9.at(300), endUtc: B9.at(2400))
        let result = OverrideMatch.apply([remote("Standup", override)], to: [B9.meeting("Standup", 0, 1800)])
        XCTAssertEqual(result, [B9.meeting("Standup", 300, 2400)])
        XCTAssertEqual(result.first?.title, "Standup")
    }

    func testSeenTimesApplyWhenThereAreNoUserTimes() {
        let override = MeetingOverride(seenStartUtc: B9.at(120), seenEndUtc: B9.at(1500))
        let result = OverrideMatch.apply([remote(override)], to: [B9.meeting("Standup", 0, 1800)])
        XCTAssertEqual(result, [B9.meeting("Standup", 120, 1500)])
    }

    func testOutOfBoundsTimesAreIgnoredByTheSameRulesAsTheServer() {
        let override = MeetingOverride(startUtc: B9.at(-8000), endUtc: B9.at(1800 + 15_000))
        let result = OverrideMatch.apply([remote(override)], to: [B9.meeting("Standup", 0, 1800)])
        XCTAssertEqual(result, [B9.meeting("Standup", 0, 1800)])
    }

    func testAWindowPastEightHoursIsKeptNotLost() {
        // 3 h meeting, start 2 h early, end 4 h late: 9 h. CalendarMeeting's own init refuses past 8 h, the override
        // path must not.
        let override = MeetingOverride(startUtc: B9.at(-7200), endUtc: B9.at(3 * 3600 + 14_400))
        let result = OverrideMatch.apply([remote("Workshop", start: 0, end: 3 * 3600, override)],
                                         to: [B9.meeting("Workshop", 0, 3 * 3600)])
        XCTAssertEqual(result.count, 1, "the meeting must not disappear")
        XCTAssertEqual(result.first?.start, B9.at(-7200))
        XCTAssertEqual(result.first?.end, B9.at(3 * 3600 + 14_400))
    }

    func testAnExcludedMeetingWithTimesIsStillDropped() {
        let override = MeetingOverride(state: .notJoined, scope: .event, startUtc: B9.at(300), endUtc: B9.at(1500))
        XCTAssertEqual(OverrideMatch.apply([remote(override)], to: [B9.meeting("Standup", 0, 1800)]), [])
    }

    // MARK: Start within 90 seconds

    func testNinetySecondsApartStillMatches() {
        for delta in [-90.0, -89.5, -1, 0, 1, 89.5, 90] {
            let result = OverrideMatch.apply([remote(start: delta, excludedOverride)], to: [B9.meeting("Standup", 0, 1800)])
            XCTAssertEqual(result, [], "\(delta) s apart")
        }
    }

    func testMoreThanNinetySecondsApartDoesNotMatch() {
        let meeting = B9.meeting("Standup", 0, 1800)
        for delta in [-91.0, -90.001, 90.001, 91, 120, 3600, 86_400] {
            XCTAssertEqual(OverrideMatch.apply([remote(start: delta, excludedOverride)], to: [meeting]), [meeting], "\(delta) s apart")
        }
    }

    func testTheWorkersEndTimeDoesNotHaveToAgree() {
        // Only the original start and the title identify a meeting.
        XCTAssertEqual(OverrideMatch.apply([remote(start: 0, end: 9999, excludedOverride)], to: [B9.meeting("Standup", 0, 1800)]), [])
    }

    func testTheSameTitleOnAnotherDayIsAnotherMeeting() {
        // A weekly standup: the Worker knows next week's too. Only the one that starts at the same time matches.
        let week: TimeInterval = 7 * 86_400
        let thisWeek = B9.meeting("Standup", 0, 1800)
        let nextWeek = B9.meeting("Standup", week, week + 1800)
        let result = OverrideMatch.apply([remote(start: week, end: week + 1800, excludedOverride, id: "next")],
                                         to: [thisWeek, nextWeek])
        XCTAssertEqual(result, [thisWeek])
    }

    func testMatchingUsesTheOriginalStartNotAnEffectiveOne() {
        // The Worker's calendarStart is the original start. A user time that moved the meeting must not be what is
        // compared (the phone's meeting still has its original start).
        let override = MeetingOverride(startUtc: B9.at(1200), endUtc: B9.at(1800))
        let result = OverrideMatch.apply([remote(start: 0, override)], to: [B9.meeting("Standup", 0, 1800)])
        XCTAssertEqual(result, [B9.meeting("Standup", 1200, 1800)])
    }

    // MARK: Titles

    func testTitlesMatchTrimmedAndIgnoringCase() {
        XCTAssertEqual(OverrideMatch.apply([remote("  STANDUP \n", excludedOverride)], to: [B9.meeting("standup", 0, 1800)]), [])
        XCTAssertEqual(OverrideMatch.apply([remote("Standup", excludedOverride)], to: [B9.meeting("  sTaNdUp  ", 0, 1800)]), [])
        XCTAssertEqual(OverrideMatch.apply([remote("Caf\u{00E9} sync", excludedOverride)], to: [B9.meeting("CAF\u{00C9} SYNC", 0, 1800)]), [])
    }

    func testDifferentTitlesDoNotMatch() {
        let meeting = B9.meeting("Standup", 0, 1800)
        for title in ["Stand up", "Standup 2", "Stand", "", "standups"] {
            XCTAssertEqual(OverrideMatch.apply([remote(title, excludedOverride)], to: [meeting]), [meeting], "\"\(title)\"")
        }
    }

    // MARK: Ambiguity

    func testTwoCandidatesMeanNothingIsApplied() {
        let meeting = B9.meeting("Standup", 0, 1800)
        let both = [remote(start: 0, excludedOverride, id: "a"), remote(start: 30, excludedOverride, id: "b")]
        XCTAssertEqual(OverrideMatch.apply(both, to: [meeting]), [meeting], "two exclusions: the meeting stays")
    }

    func testTwoCandidatesWithDifferentOverridesStillApplyNothing() {
        let meeting = B9.meeting("Standup", 0, 1800)
        let moved = MeetingOverride(startUtc: B9.at(600), endUtc: B9.at(1500))
        let result = OverrideMatch.apply(
            [remote(start: 0, excludedOverride, id: "a"), remote(start: 60, moved, id: "b")], to: [meeting])
        XCTAssertEqual(result, [meeting])
    }

    func testACandidateWithNoOverrideStillCountsAsACandidate() {
        let meeting = B9.meeting("Standup", 0, 1800)
        let result = OverrideMatch.apply(
            [remote(start: 0, excludedOverride, id: "a"), remote(start: 10, nil, id: "b")], to: [meeting])
        XCTAssertEqual(result, [meeting], "cannot tell which one the phone's meeting is")
    }

    func testTwoCandidatesWithDifferentTitleCaseAreStillTwo() {
        let meeting = B9.meeting("Standup", 0, 1800)
        let result = OverrideMatch.apply(
            [remote("STANDUP", start: 0, excludedOverride, id: "a"), remote(" standup ", start: 5, excludedOverride, id: "b")],
            to: [meeting])
        XCTAssertEqual(result, [meeting])
    }

    func testACandidateOutsideNinetySecondsOrWithAnotherTitleIsNotACandidate() {
        let meeting = B9.meeting("Standup", 0, 1800)
        let result = OverrideMatch.apply(
            [remote(start: 0, excludedOverride, id: "a"),
             remote(start: 600, nil, id: "later"),
             remote("Retro", start: 0, nil, id: "other title")],
            to: [meeting])
        XCTAssertEqual(result, [], "only one real candidate: its exclusion applies")
    }

    func testAmbiguityOnOneMeetingDoesNotStopTheOthers() {
        let ambiguous = B9.meeting("Standup", 0, 1800)
        let clear = B9.meeting("Retro", 7200, 9000)
        let keep = B9.meeting("Lunch", 12_000, 13_000)
        let result = OverrideMatch.apply(
            [remote("Standup", start: 0, excludedOverride, id: "a"),
             remote("Standup", start: 10, excludedOverride, id: "b"),
             remote("Retro", start: 7200, end: 9000, excludedOverride, id: "c")],
            to: [ambiguous, clear, keep])
        XCTAssertEqual(result, [ambiguous, keep])
    }

    // MARK: Several meetings

    func testOrderIsKeptAndOnlyTheMatchedOnesChange() {
        let first = B9.meeting("A", 0, 1800)
        let second = B9.meeting("B", 3600, 5400)
        let third = B9.meeting("C", 7200, 9000)
        let fourth = B9.meeting("D", 10_800, 12_600)
        let result = OverrideMatch.apply(
            [remote("D", start: 10_800, end: 12_600, MeetingOverride(startUtc: B9.at(10_900)), id: "d"),
             remote("B", start: 3600, end: 5400, excludedOverride, id: "b")],
            to: [first, second, third, fourth])
        XCTAssertEqual(result, [first, third, B9.meeting("D", 10_900, 12_600)])
    }

    func testOneWorkerMeetingAppliesToBothPhoneCopiesOfTheSameEvent() {
        // The same event on two calendars shows up twice in EventKit.
        let first = B9.meeting("Standup", 0, 1800)
        let second = B9.meeting("Standup", 30, 1830)
        XCTAssertEqual(OverrideMatch.apply([remote(excludedOverride)], to: [first, second]), [], "both are dropped")
        let moved = MeetingOverride(startUtc: B9.at(300), endUtc: B9.at(1500))
        XCTAssertEqual(OverrideMatch.apply([remote(moved)], to: [first, second]),
                       [B9.meeting("Standup", 300, 1500), B9.meeting("Standup", 300, 1500)])
    }

    func testOnlyTheMeetingAtTheWorkersStartIsAffected() {
        // Same title twice on the phone, hours apart: the Worker meeting is a candidate for one of them only.
        let early = B9.meeting("Standup", 0, 1800)
        let late = B9.meeting("Standup", 7200, 9000)
        let result = OverrideMatch.apply([remote(start: 7200, end: 9000, excludedOverride)], to: [early, late])
        XCTAssertEqual(result, [early])
    }

    // MARK: Time zones

    func testMatchingIsTheSameInEveryZone() {
        B9.inZones(B9.zones) { zone in
            let meeting = B9.meeting("Standup", 0, 1800)
            XCTAssertEqual(OverrideMatch.apply([remote(start: 90, excludedOverride)], to: [meeting]), [], zone)
            XCTAssertEqual(OverrideMatch.apply([remote(start: 91, excludedOverride)], to: [meeting]), [meeting], zone)
        }
    }

    func testAMeetingAcrossAFallBackKeepsItsRealLength() {
        B9.inZones(B9.zones) { zone in
            // 01:30 EDT to 01:30 EST: one real hour. User end 3 h 30 m after the start is inside every bound.
            let start = B9.fallBackInstant
            let end = start.addingTimeInterval(3600)
            let meeting = CalendarMeeting(title: "Night shift", start: start, end: end)!
            let remote = RemoteMeeting(
                id: "dst", title: "Night shift", calendarStart: start, calendarEnd: end,
                override: MeetingOverride(endUtc: start.addingTimeInterval(3.5 * 3600)))
            let result = OverrideMatch.apply([remote], to: [meeting])
            XCTAssertEqual(result.first?.start, start, zone)
            XCTAssertEqual(result.first?.end, start.addingTimeInterval(3.5 * 3600), zone)
        }
    }

    func testAMeetingAcrossASpringForwardMatchesAndExcludes() {
        B9.inZones(B9.zones) { zone in
            let start = B9.springForwardInstant
            let end = start.addingTimeInterval(3600)
            let meeting = CalendarMeeting(title: "Early call", start: start, end: end)!
            let remote = RemoteMeeting(id: "dst2", title: "Early call", calendarStart: start.addingTimeInterval(-45),
                                       calendarEnd: end, override: MeetingOverride(state: .unlinked, scope: .series))
            XCTAssertEqual(OverrideMatch.apply([remote], to: [meeting]), [], zone)
        }
    }
}
