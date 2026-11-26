import Foundation

/// Meeting choices for the app's demo day, so screenshots show every state: a series, a meeting left out as "Didn't
/// join", one left out as "Not linked", and the quiet "Looks like you didn't join" note. The bundled demo JSON has to
/// stay the same as the test fixtures, so these are laid over it when the app's demo API reads the day.
enum DemoMeetingChoices {
    /// - m-standup: in a daily series, so "All of them" is offered.
    /// - m-design: left out, "Not linked".
    /// - m-1on1: the Mac never saw Zoom, so the note asks.
    /// - m-board: left out, "Didn't join", in a weekly series.
    static func seed(_ events: [Meeting]) -> [Meeting] {
        var kept: [Meeting] = []
        var left: [Meeting] = []
        for var event in events {
            func override(_ state: MeetingOverride.State? = nil, seenNone: Bool = false, series: String?) -> MeetingOverride {
                MeetingOverride(
                    state: state, scope: state == nil ? nil : .event, seenNone: seenNone, seriesId: series,
                    calendarStartUtc: APITime.parse(event.startUtc), calendarEndUtc: APITime.parse(event.endUtc))
            }
            switch event.id {
            case "m-standup":
                event.override = override(series: "standup-daily")
            case "m-1on1":
                event.override = override(seenNone: true, series: "dana-weekly")
            case "m-design":
                event.override = override(.unlinked, series: nil)
            case "m-board":
                event.override = override(.notJoined, series: "board-weekly")
            default:
                break
            }
            if OverrideRules.excluded(event.override) {
                event.excluded = true
                event.score = nil
                event.flags = []
                event.hrStress = nil
                left.append(event)
            } else {
                kept.append(event)
            }
        }
        // Left out meetings come after the others, like the Worker's day list.
        return kept + left
    }

    /// The day's totals without the meetings left out.
    static func recount(_ calendar: inout DayCalendar) {
        let counted = calendar.events.filter { $0.excluded != true }
        calendar.eventCount = counted.count
        calendar.totalDurationS = counted.reduce(0) { $0 + ($1.durationS ?? 0) }
        calendar.afterHoursCount = counted.filter { $0.afterHours == true }.count
    }
}
