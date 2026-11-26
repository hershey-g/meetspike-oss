import Foundation

/// What the Worker says about one meeting beyond the calendar: whether the person joined or wants it linked, the times
/// they set, and the times the Mac saw Zoom. This is the `override` object `GET /api/view` puts on a meeting.
///
/// Decoding is lenient on purpose. A value this app does not know (a state a newer Worker added, a date in a shape it
/// cannot read) is read as "not set", and everything else on the object is still read. A day of meetings never fails
/// to load because of one field.
public struct MeetingOverride: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case notJoined = "not_joined"
        case unlinked
        case linked
    }

    public enum Scope: String, Codable, Sendable {
        case event
        case series
    }

    public var state: State?
    public var scope: Scope?
    public var startUtc: Date?
    public var endUtc: Date?
    public var seenStartUtc: Date?
    public var seenEndUtc: Date?
    public var seenNone: Bool
    public var seriesId: String?
    /// The state the series' own rule gives, even when the meeting's own choice wins. Nil when the series has none (or
    /// an older Worker did not send it). Undo reads it: clearing a choice does not bring a meeting back when the series
    /// rule also leaves it out.
    public var seriesState: State?
    /// The calendar's own times, before any change. The meeting's `startUtc` and `endUtc` on the same JSON object are
    /// the effective ones, so matching a phone meeting (which has the calendar's) uses these. Nil from an older Worker.
    public var calendarStartUtc: Date?
    public var calendarEndUtc: Date?

    public init(
        state: State? = nil, scope: Scope? = nil, startUtc: Date? = nil, endUtc: Date? = nil,
        seenStartUtc: Date? = nil, seenEndUtc: Date? = nil, seenNone: Bool = false, seriesId: String? = nil,
        seriesState: State? = nil, calendarStartUtc: Date? = nil, calendarEndUtc: Date? = nil
    ) {
        self.state = state
        self.scope = scope
        self.startUtc = startUtc
        self.endUtc = endUtc
        self.seenStartUtc = seenStartUtc
        self.seenEndUtc = seenEndUtc
        self.seenNone = seenNone
        self.seriesId = seriesId
        self.seriesState = seriesState
        self.calendarStartUtc = calendarStartUtc
        self.calendarEndUtc = calendarEndUtc
    }

    private enum Key: String, CodingKey {
        case state, scope, startUtc, endUtc, seenStartUtc, seenEndUtc, seenNone, seriesId, seriesState, calendarStartUtc, calendarEndUtc
    }

    public init(from decoder: Decoder) throws {
        // Not an object at all: nothing is set, and the caller still gets its meeting.
        guard let container = try? decoder.container(keyedBy: Key.self) else {
            self.init()
            return
        }
        func text(_ key: Key) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func date(_ key: Key) -> Date? { APITime.parse(text(key)) }
        self.init(
            state: text(.state).flatMap(State.init(rawValue:)),
            scope: text(.scope).flatMap(Scope.init(rawValue:)),
            startUtc: date(.startUtc), endUtc: date(.endUtc),
            seenStartUtc: date(.seenStartUtc), seenEndUtc: date(.seenEndUtc),
            seenNone: ((try? container.decodeIfPresent(Bool.self, forKey: .seenNone)) ?? nil) ?? false,
            seriesId: text(.seriesId), seriesState: text(.seriesState).flatMap(State.init(rawValue:)),
            calendarStartUtc: date(.calendarStartUtc), calendarEndUtc: date(.calendarEndUtc))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encodeIfPresent(startUtc.map(OverrideTime.format), forKey: .startUtc)
        try container.encodeIfPresent(endUtc.map(OverrideTime.format), forKey: .endUtc)
        try container.encodeIfPresent(seenStartUtc.map(OverrideTime.format), forKey: .seenStartUtc)
        try container.encodeIfPresent(seenEndUtc.map(OverrideTime.format), forKey: .seenEndUtc)
        try container.encode(seenNone, forKey: .seenNone)
        try container.encodeIfPresent(seriesId, forKey: .seriesId)
        try container.encodeIfPresent(seriesState, forKey: .seriesState)
        try container.encodeIfPresent(calendarStartUtc.map(OverrideTime.format), forKey: .calendarStartUtc)
        try container.encodeIfPresent(calendarEndUtc.map(OverrideTime.format), forKey: .calendarEndUtc)
    }
}
