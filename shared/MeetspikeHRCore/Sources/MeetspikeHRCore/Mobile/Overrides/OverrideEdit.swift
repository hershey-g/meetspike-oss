import Foundation

/// One change to a meeting's override, exactly the body of `PUT /api/meetings/:id/override`:
/// `{ "scope", "state"?, "startUtc"?, "endUtc"? }`. `.unchanged` leaves the key out (the Worker leaves that part
/// alone), `.clear` writes null (the Worker clears it), `.set` writes the value. Times are only for the event scope:
/// a series edit never carries them (the Worker would answer 400).
public struct OverrideEdit: Codable, Equatable, Sendable {
    public enum Change<Value: Codable & Equatable & Sendable>: Equatable, Sendable {
        case unchanged
        case clear
        case set(Value)
    }

    public var scope: MeetingOverride.Scope
    public var state: Change<MeetingOverride.State>
    public var startUtc: Change<Date>
    public var endUtc: Change<Date>

    public init(
        scope: MeetingOverride.Scope, state: Change<MeetingOverride.State> = .unchanged,
        startUtc: Change<Date> = .unchanged, endUtc: Change<Date> = .unchanged
    ) {
        self.scope = scope
        self.state = state
        // A time is kept exactly as it is written on the wire, so an edit equals itself after encode and decode.
        self.startUtc = scope == .event ? Self.canonical(startUtc) : .unchanged
        self.endUtc = scope == .event ? Self.canonical(endUtc) : .unchanged
    }

    private static func canonical(_ change: Change<Date>) -> Change<Date> {
        if case .set(let date) = change { return .set(OverrideTime.canonical(date)) }
        return change
    }

    /// Nothing to change. The Worker answers 400 to that, so it is never sent.
    public var isEmpty: Bool {
        state == .unchanged && startUtc == .unchanged && endUtc == .unchanged
    }

    private enum Key: String, CodingKey {
        case scope, state, startUtc, endUtc
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(scope, forKey: .scope)
        try Self.write(state, forKey: .state, to: &container) { $0.rawValue }
        if scope == .event {
            try Self.write(startUtc, forKey: .startUtc, to: &container, OverrideTime.format)
            try Self.write(endUtc, forKey: .endUtc, to: &container, OverrideTime.format)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let scope = try container.decode(MeetingOverride.Scope.self, forKey: .scope)
        let state: Change<MeetingOverride.State> = try Self.read(container, .state) { text in
            MeetingOverride.State(rawValue: text)
        }
        let start: Change<Date> = try Self.read(container, .startUtc) { APITime.parse($0) }
        let end: Change<Date> = try Self.read(container, .endUtc) { APITime.parse($0) }
        self.init(scope: scope, state: state, startUtc: start, endUtc: end)
    }

    private static func write<Value: Codable & Equatable & Sendable>(
        _ change: Change<Value>, forKey key: Key, to container: inout KeyedEncodingContainer<Key>,
        _ text: (Value) -> String
    ) throws {
        switch change {
        case .unchanged: break
        case .clear: try container.encodeNil(forKey: key)
        case .set(let value): try container.encode(text(value), forKey: key)
        }
    }

    private static func read<Value: Codable & Equatable & Sendable>(
        _ container: KeyedDecodingContainer<Key>, _ key: Key, _ parse: (String) -> Value?
    ) throws -> Change<Value> {
        guard container.contains(key) else { return .unchanged }
        if try container.decodeNil(forKey: key) { return .clear }
        let text = try container.decode(String.self, forKey: key)
        guard let value = parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "unreadable value")
        }
        return .set(value)
    }
}
