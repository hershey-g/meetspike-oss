import Foundation

/// Edits that are saved on the phone but not yet on the Worker (the outbox) laid over what the Worker last said, so
/// the phone behaves as the person chose while offline: the row shows the choice, and listening follows it.
/// The Worker's answer replaces all of this the next time it is reached.
public enum OverrideOverlay {
    /// The series an event id belongs to: the id without `_YYYYMMDD` or `_YYYYMMDDTHHMMSSZ`. Same rule as the Worker
    /// (`seriesIdOf`). Nil when there is no such suffix.
    public static func seriesID(of eventID: String) -> String? {
        let range = NSRange(eventID.startIndex..., in: eventID)
        guard let match = instanceSuffix?.firstMatch(in: eventID, range: range), match.numberOfRanges == 5,
              let base = Range(match.range(at: 1), in: eventID),
              let month = Range(match.range(at: 3), in: eventID).flatMap({ Int(eventID[$0]) }),
              let day = Range(match.range(at: 4), in: eventID).flatMap({ Int(eventID[$0]) }),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return String(eventID[base])
    }

    private static let instanceSuffix: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(.+)_(\d{4})(\d{2})(\d{2})(?:T\d{6}Z)?\z"#)

    /// The overrides after the pending edits, one per entry of `items` in the same order. An event edit changes that
    /// meeting. A series edit changes every meeting of the same series that does not have a choice of its own.
    public static func apply(
        _ pending: [OverrideOutbox.Item], to items: [(id: String, override: MeetingOverride?)]
    ) -> [MeetingOverride?] {
        var result = items.map(\.override)
        for item in pending {
            let edit = item.edit
            switch edit.scope {
            case .event:
                for index in items.indices where items[index].id == item.eventID {
                    result[index] = patched(result[index], edit)
                    // Clearing the meeting's own choice (an opt-out) lets the series rule apply again, when the list
                    // shows a meeting of the same series that carries it.
                    if edit.state == .clear, result[index]?.state == nil,
                       let rule = seriesRule(for: index, items: items, result: result) {
                        result[index]?.state = rule.state
                        result[index]?.scope = rule.scope
                    }
                }
            case .series:
                let series = items.first { $0.id == item.eventID }?.override?.seriesId ?? seriesID(of: item.eventID)
                guard let series else { continue }
                for index in items.indices {
                    let sameSeries = (result[index]?.seriesId ?? seriesID(of: items[index].id)) == series
                    // A choice on the meeting itself beats the series, with one exception: "all of them" sent for a
                    // meeting whose own state is `linked` (and says not joined or don't link) clears that own state
                    // too, so the tapped meeting goes out with the rest. The Worker does the same in the same request.
                    let ownChoice = result[index]?.scope == .event && result[index]?.state != nil
                    let clearsOwnLinked = items[index].id == item.eventID && result[index]?.state == .linked
                        && (edit.state == .set(.notJoined) || edit.state == .set(.unlinked))
                    guard sameSeries, !ownChoice || clearsOwnLinked else { continue }
                    result[index] = patched(result[index], edit, seriesID: series)
                }
            }
        }
        return result
    }

    /// The series rule (state and scope) a sibling of `items[index]` carries, if any.
    private static func seriesRule(
        for index: Int, items: [(id: String, override: MeetingOverride?)], result: [MeetingOverride?]
    ) -> (state: MeetingOverride.State, scope: MeetingOverride.Scope)? {
        guard let series = result[index]?.seriesId ?? seriesID(of: items[index].id) else { return nil }
        for other in items.indices where other != index {
            guard (result[other]?.seriesId ?? seriesID(of: items[other].id)) == series,
                  result[other]?.scope == .series, let state = result[other]?.state else { continue }
            return (state, .series)
        }
        return nil
    }

    /// `RemoteMeeting`s with the pending edits applied.
    public static func apply(_ pending: [OverrideOutbox.Item], to remote: [RemoteMeeting]) -> [RemoteMeeting] {
        guard !pending.isEmpty else { return remote }
        let changed = apply(pending, to: remote.map { (id: $0.id, override: $0.override) })
        return zip(remote, changed).map { meeting, override in
            var copy = meeting
            copy.override = override
            return copy
        }
    }

    /// The Worker's own answer to a save laid on the stored meetings at once: the meeting `meetingID` gets
    /// `answer.override` (nil clears it, the Worker sends null when nothing is overridden). Nothing else changes.
    /// Applied the moment the save succeeds, it covers the gap until the stored meetings are refreshed. It does not
    /// touch other meetings of a series (a series answer's effect on them waits for that refresh).
    public static func applying(
        _ answer: OverrideSaveResult, meetingID: String, to remote: [RemoteMeeting]
    ) -> [RemoteMeeting] {
        remote.map { meeting in
            guard meeting.id == meetingID else { return meeting }
            var copy = meeting
            copy.override = answer.override
            return copy
        }
    }

    /// A day's meetings with the pending edits applied, for the rows: left out, put back, asked and answered.
    /// Times are not moved on the row (they need the Worker's local time text); the listening windows do move.
    public static func apply(_ pending: [OverrideOutbox.Item], to meetings: [Meeting]) -> [Meeting] {
        guard !pending.isEmpty else { return meetings }
        let changed = apply(pending, to: meetings.map { (id: $0.id, override: $0.override) })
        return zip(meetings, changed).map { meeting, override in
            guard override != meeting.override else { return meeting }
            var copy = meeting
            copy.override = override
            copy.excluded = OverrideRules.excluded(override) ? true : nil
            return copy
        }
    }

    private static func patched(_ current: MeetingOverride?, _ edit: OverrideEdit, seriesID: String? = nil) -> MeetingOverride? {
        var value = current ?? MeetingOverride()
        switch (edit.scope, edit.state) {
        case (_, .unchanged): break
        case (.event, .set(let state)): value.state = state; value.scope = .event
        case (.event, .clear): value.state = nil; value.scope = nil
        case (.series, .set(let state)): value.state = state; value.scope = .series
        case (.series, .clear):
            if value.scope == .series { value.state = nil; value.scope = nil }
        }
        if edit.scope == .event {
            switch edit.startUtc {
            case .set(let date): value.startUtc = date
            case .clear: value.startUtc = nil
            case .unchanged: break
            }
            switch edit.endUtc {
            case .set(let date): value.endUtc = date
            case .clear: value.endUtc = nil
            case .unchanged: break
            }
        }
        if value.seriesId == nil { value.seriesId = seriesID }
        return value
    }
}
