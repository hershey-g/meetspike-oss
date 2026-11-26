import Foundation

/// Whether calendar text (a location, a description, a URL field) holds a Zoom link: a host that is `zoom.us` or
/// `zoomgov.com`, or a subdomain of them. The word "zoom" alone is not a link, and neither is a look-alike host.
public enum ZoomLink {
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:^|[\s"'<>(\[]|//)(?:[a-z0-9-]+\.)*(?:zoom\.us|zoomgov\.com)(?=[/:?#\s"'<>)\]]|$)"#,
        options: [.caseInsensitive])

    public static func isZoom(text: String) -> Bool {
        guard let pattern, !text.isEmpty else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// A calendar meeting as the Mac tracks it. `start` and `end` are the original calendar times (what the Worker matches
/// on), `hasZoom` is whether a Zoom link was found on it.
public struct TrackedMeeting: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var hasZoom: Bool

    public init(id: String, title: String, start: Date, end: Date, hasZoom: Bool) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.hasZoom = hasZoom
    }
}

/// What the Mac tells the Worker about a meeting once it is over. Encodes to the body of
/// `POST /api/whoop-web/app/attendance`: all five keys, null for a time that is not there. `id` is not in the body.
public struct AttendanceReport: Equatable, Sendable, Encodable {
    public var id: String
    public var meetingStart: Date
    public var title: String
    public var seenStart: Date?
    public var seenEnd: Date?
    public var seenNone: Bool

    public init(id: String, meetingStart: Date, title: String, seenStart: Date?, seenEnd: Date?, seenNone: Bool) {
        self.id = id
        self.meetingStart = meetingStart
        self.title = title
        self.seenStart = seenStart
        self.seenEnd = seenEnd
        self.seenNone = seenNone
    }

    private enum Key: String, CodingKey {
        case meetingStartUtc, title, seenStartUtc, seenEndUtc, seenNone
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(OverrideTime.format(meetingStart), forKey: .meetingStartUtc)
        try container.encode(title, forKey: .title)
        if let seenStart { try container.encode(OverrideTime.format(seenStart), forKey: .seenStartUtc) } else {
            try container.encodeNil(forKey: .seenStartUtc)
        }
        if let seenEnd { try container.encode(OverrideTime.format(seenEnd), forKey: .seenEndUtc) } else {
            try container.encodeNil(forKey: .seenEndUtc)
        }
        try container.encode(seenNone, forKey: .seenNone)
    }
}

/// The Mac's "did you really join" tracker. Pure: the Mac calls `observe` about every 15 s, always (not only while
/// recording), with the same list of meetings each time.
///
/// A Zoom session is a run of samples with Zoom running, broken by a sample with Zoom closed, with the Mac not awake,
/// or by a gap of more than 60 s between samples. For a meeting that starts at S and ends at E:
///   - Lead: sightings count from the later of S - 15 min and the end of the latest earlier Zoom meeting that ends at
///     or before S, so back-to-back calls do not bleed into each other. A session in the lead counts only if it is
///     still running, unbroken, at S (it counts from when it began); one that ended before S is not a sighting.
///   - From the lead to E, every session counts (leaving and rejoining is fine).
///   - Past E, only the session that was already running at E counts, and only while it stays unbroken. A session
///     that starts after E never counts. The tail stops at the start of the next meeting with a Zoom link (the
///     sighting is clipped to that start) and at E + 4 h.
///   - Never joined before the end means not seen, even if Zoom opens later. `seenNone` also needs the Mac to have been
///     awake and watching for 90 % of the scheduled time.
///   - Each meeting is reported once: when the counted tail ends (Zoom closed, session broken, next Zoom meeting
///     starts, E + 4 h) or right at E when Zoom was not running. If the Mac slept over E, the last sighting before the
///     gap is the end, reported on wake.
///   - Two Zoom meetings whose times overlap (more than touching) get no report at all.
public struct AttendanceTracker: Sendable {
    public init() {}

    /// The longest gap between two samples that still counts as watching and as one session.
    static let maxGap: TimeInterval = 60
    static let lead: TimeInterval = 15 * 60
    static let tail: TimeInterval = 4 * 3_600
    static let coverage = 0.9

    private struct Previous: Sendable {
        var time: Date
        var zoom: Bool
        var awake: Bool
    }

    private struct State: Sendable {
        var seenStart: Date?
        var seenEnd: Date?
        var watched: TimeInterval = 0
        var tailOpen = false
        var done = false
        /// Where the Zoom session that is running in the lead began (clipped to the lead). Only a session still running
        /// and unbroken at the scheduled start becomes a sighting.
        var leadSession: Date?
    }

    private var previous: Previous?
    private var states: [String: State] = [:]

    public mutating func observe(now: Date, zoomRunning: Bool, awake: Bool, meetings: [TrackedMeeting]) -> [AttendanceReport] {
        if let last = previous, now == last.time { return [] }
        let zoom = zoomRunning && awake
        // Time going backwards (a clock set back): this sample starts over. Nothing is credited across it.
        let before = previous.flatMap { $0.time < now ? $0 : nil }
        let gap = before.map { now.timeIntervalSince($0.time) }
        let steady = gap.map { $0 <= Self.maxGap } ?? false
        let continues = zoom && steady && (before?.zoom ?? false)
        let watching = steady && awake && (before?.awake ?? false)
        defer { previous = Previous(time: now, zoom: zoom, awake: awake) }

        let zoomMeetings = meetings.filter { $0.hasZoom && $0.end > $0.start }
        var reports: [AttendanceReport] = []
        for meeting in zoomMeetings.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let overlapped = zoomMeetings.contains {
                $0.id != meeting.id && $0.start < meeting.end && meeting.start < $0.end
            }
            if overlapped { continue }
            let key = "\(meeting.id)|\(meeting.start.timeIntervalSince1970)|\(meeting.end.timeIntervalSince1970)"
            var state = states[key] ?? State()
            if state.done { continue }
            defer { states[key] = state }

            let start = meeting.start
            let end = meeting.end
            let earlierEnd = zoomMeetings.filter { $0.id != meeting.id && $0.end <= start }.map(\.end).max()
            let leadFrom = max(start.addingTimeInterval(-Self.lead), earlierEnd ?? .distantPast)
            let nextStart = zoomMeetings.filter { $0.id != meeting.id && $0.start >= end }.map(\.start).min()
            let cap = min(end.addingTimeInterval(Self.tail), nextStart ?? .distantFuture)

            if let before, watching {
                let from = max(before.time, start)
                let to = min(now, end)
                if to > from { state.watched += to.timeIntervalSince(from) }
            }

            if now < start {
                // In the lead the sample is only remembered. It counts if the session is still running at the start.
                if zoom, now >= leadFrom {
                    if !(continues && state.leadSession != nil) { state.leadSession = now }
                } else {
                    state.leadSession = nil
                }
            } else {
                if let session = state.leadSession {
                    state.leadSession = nil
                    if zoom, continues { sight(&state, session) }
                }
                if zoom, now <= end { sight(&state, now) }
            }

            guard now >= end else { continue }
            // At or past the scheduled end. Was a session already running at the end?
            if !state.tailOpen, zoom, now == end || (continues && (before?.time ?? .distantFuture) <= end) {
                state.tailOpen = true
            }
            var finished = !state.tailOpen
            if state.tailOpen {
                if now > end, !continues {
                    finished = true
                } else if now >= cap {
                    if let seenEnd = state.seenEnd { state.seenEnd = max(seenEnd, cap) } else { state.seenEnd = cap }
                    if state.seenStart == nil { state.seenStart = cap }
                    finished = true
                } else if now > end {
                    sight(&state, now)
                }
            }
            guard finished else { continue }
            state.done = true
            if let seenStart = state.seenStart {
                reports.append(AttendanceReport(
                    id: meeting.id, meetingStart: start, title: meeting.title,
                    seenStart: seenStart, seenEnd: state.seenEnd ?? seenStart, seenNone: false))
            } else if state.watched >= Self.coverage * end.timeIntervalSince(start) {
                reports.append(AttendanceReport(
                    id: meeting.id, meetingStart: start, title: meeting.title,
                    seenStart: nil, seenEnd: nil, seenNone: true))
            }
        }
        forget(before: now)
        return reports
    }

    private func sight(_ state: inout State, _ time: Date) {
        if state.seenStart == nil { state.seenStart = time }
        if let seenEnd = state.seenEnd { state.seenEnd = max(seenEnd, time) } else { state.seenEnd = time }
    }

    /// Meetings long gone are dropped from memory. Anything still inside its window (or a day after) stays.
    private mutating func forget(before now: Date) {
        guard states.count > 200 else { return }
        let keep = now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970
        states = states.filter { key, _ in
            let parts = key.split(separator: "|")
            guard parts.count >= 3, let end = Double(parts[parts.count - 1]) else { return true }
            return end > keep
        }
    }
}
