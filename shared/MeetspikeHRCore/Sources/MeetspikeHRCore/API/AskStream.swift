import Foundation

// POST /api/ask/stream: request body, server-sent events, and the parser.
// Ported from createSseParser and applyAskEvent in public/ask-logic.js.

public enum AskRole: String, Codable, Equatable, Sendable {
    case user, assistant
}

/// One earlier turn sent as history.
public struct AskTurn: Codable, Equatable, Sendable {
    public var role: AskRole
    public var content: String
    public init(role: AskRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Body of POST /api/ask/stream. `start` and `end` scope the question to dates; both nil lets the Worker
/// work the range out from the question. `sourceDisplay` must match the Worker's current setting or it drops `history`.
public struct AskRequest: Encodable, Equatable, Sendable {
    public var question: String
    public var history: [AskTurn]
    public var sourceDisplay: SourceDisplay
    public var start: String?
    public var end: String?
    /// Rank over all history. Sent only when true, so builds 8 and 9 of the Worker see the body they know.
    public var allTime: Bool
    /// Ignore a period in the question (and in earlier turns). "Ask over all time" sets it together with `allTime`.
    /// Sent only when true.
    public var ignorePeriod: Bool

    public init(
        question: String, history: [AskTurn] = [], sourceDisplay: SourceDisplay, start: String? = nil, end: String? = nil,
        allTime: Bool = false, ignorePeriod: Bool = false
    ) {
        self.question = question
        self.history = history
        self.sourceDisplay = sourceDisplay
        self.start = start
        self.end = end
        self.allTime = allTime
        self.ignorePeriod = ignorePeriod
    }

    private enum CodingKeys: String, CodingKey { case question, history, sourceDisplay, start, end, allTime, ignorePeriod }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(history, forKey: .history)
        try container.encode(sourceDisplay, forKey: .sourceDisplay)
        // Both or neither: the Worker treats a lone start or end as a scoped (and invalid) range.
        if let start, let end {
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        }
        if allTime { try container.encode(true, forKey: .allTime) }
        if ignorePeriod { try container.encode(true, forKey: .ignorePeriod) }
    }
}

extension SourceDisplay {
    /// A public way to build one (the memberwise init is module-internal).
    public static func make(oura: Bool, whoop: Bool) -> SourceDisplay {
        SourceDisplay(oura: oura, whoop: whoop)
    }
}

extension SourceDisplay: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DisplayKeys.self)
        try container.encode(oura, forKey: .oura)
        try container.encode(whoop, forKey: .whoop)
    }
    private enum DisplayKeys: String, CodingKey { case oura, whoop }
}

public struct AskStep: Equatable, Sendable, Identifiable {
    public enum Status: String, Sendable { case active, done }
    public var id: String
    public var label: String
    public var status: Status
    public init(id: String, label: String, status: Status) {
        self.id = id
        self.label = label
        self.status = status
    }
}

/// The dates an answer was ranked over (`range` event, and `done` from a Worker that knows build 10), and the
/// all-history dates it was compared with. Every day is YYYY-MM-DD.
public struct AskRange: Equatable, Sendable, Codable {
    public var start: String
    public var end: String
    public var baselineStart: String
    public var baselineEnd: String
    /// "question", "allTime", "followUp", "tab" or "history". Nil from a Worker that does not say.
    public var source: String?

    public init(start: String, end: String, baselineStart: String, baselineEnd: String, source: String? = nil) {
        self.start = start
        self.end = end
        self.baselineStart = baselineStart
        self.baselineEnd = baselineEnd
        self.source = source
    }

    /// The ranked dates cover all history (so there is nothing more to ask over). Day text sorts like dates. A ranked
    /// end at or past `today` still covers the end of the baseline.
    public func coversAllHistory(today: String) -> Bool {
        start <= baselineStart && (end >= baselineEnd || end >= today)
    }

    /// Nil unless all four days are real days.
    init?(json object: [String: Any]?) {
        guard let start = object?["start"] as? String, let end = object?["end"] as? String,
              let baselineStart = object?["baselineStart"] as? String, let baselineEnd = object?["baselineEnd"] as? String,
              [start, end, baselineStart, baselineEnd].allSatisfy(DayMath.isValid) else { return nil }
        self.init(start: start, end: end, baselineStart: baselineStart, baselineEnd: baselineEnd, source: object?["rangeSource"] as? String)
    }
}

public struct AskDone: Equatable, Sendable {
    public var truncated: Bool
    /// Anthropic's stream closed early: the text so far is partial.
    public var interrupted: Bool
    public var refused: Bool
    public var model: String?
    public var start: String?
    public var end: String?
    /// What the answer was ranked over. Nil from an older Worker.
    public var range: AskRange?
    public init(truncated: Bool = false, interrupted: Bool = false, refused: Bool = false, model: String? = nil, start: String? = nil, end: String? = nil) {
        self.truncated = truncated
        self.interrupted = interrupted
        self.refused = refused
        self.model = model
        self.start = start
        self.end = end
    }
}

public struct AskFailure: Equatable, Sendable {
    public var message: String
    /// The saved Claude key is missing or no longer accepted. Send the person to More.
    public var needsKey: Bool
    public init(message: String, needsKey: Bool = false) {
        self.message = message
        self.needsKey = needsKey
    }
}

/// One thing that happens while an answer streams. Exactly one terminal event ends a stream:
/// `.done`, `.error` or `.cutOff`.
public enum AskEvent: Equatable, Sendable {
    case step(AskStep)
    case text(String)
    /// The dates the answer will rank, sent once before the first step.
    case range(AskRange)
    case done(AskDone)
    case error(AskFailure)
    /// The stream ended with neither done nor error (connection dropped). Keep the text, mark it partial.
    case cutOff

    public var isTerminal: Bool {
        switch self {
        case .done, .error, .cutOff: true
        case .step, .text, .range: false
        }
    }
}

/// A raw server-sent event: its name (`message` when none) and data lines joined by `\n`.
public struct SSEMessage: Equatable, Sendable {
    public var event: String
    public var data: String
    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental server-sent events parser. Feed bytes or text in any split (chunk edges can fall
/// inside a line, inside a UTF-8 character, or between the CR and LF of CRLF). Comment lines
/// (": ping") and events without data are ignored.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var pendingCR = false
    private var event = ""
    private var data: [String] = []
    private var out: [SSEMessage] = []

    public init() {}

    /// Feed text. Returns the events completed by it.
    public mutating func push(_ chunk: String) -> [SSEMessage] {
        push(Data(chunk.utf8))
    }

    /// Feed raw bytes. Returns the events completed by them.
    public mutating func push(_ chunk: Data) -> [SSEMessage] {
        for byte in chunk { feed(byte) }
        return drain()
    }

    /// Feed one byte (used when streaming from `URLSession.AsyncBytes`).
    public mutating func push(byte: UInt8) -> [SSEMessage] {
        feed(byte)
        return drain()
    }

    /// The input ended: flush a last unterminated line and any open event.
    public mutating func finish() -> [SSEMessage] {
        pendingCR = false
        if !line.isEmpty { endLine() }
        dispatch()
        return drain()
    }

    private mutating func drain() -> [SSEMessage] {
        defer { out.removeAll(keepingCapacity: true) }
        return out
    }

    private mutating func feed(_ byte: UInt8) {
        if pendingCR {
            pendingCR = false
            if byte == 0x0A { return }
        }
        switch byte {
        case 0x0D:
            endLine()
            pendingCR = true
        case 0x0A:
            endLine()
        default:
            line.append(byte)
        }
    }

    private mutating func endLine() {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return }
        let field: String
        var value: String
        if let colon = text.firstIndex(of: ":") {
            field = String(text[..<colon])
            value = String(text[text.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = text
            value = ""
        }
        if field == "event" { event = value } else if field == "data" { data.append(value) }
    }

    private mutating func dispatch() {
        if !data.isEmpty { out.append(SSEMessage(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))) }
        event = ""
        data = []
    }
}

extension AskEvent {
    /// Turns a raw server event into an `AskEvent`. Unknown events and unreadable data give nil.
    public init?(_ message: SSEMessage) {
        let json = try? JSONSerialization.jsonObject(with: Data(message.data.utf8), options: [.fragmentsAllowed])
        let object = json as? [String: Any]
        switch message.event {
        case "step":
            guard let id = object?["id"] as? String else { return nil }
            let status = (object?["status"] as? String) == "done" ? AskStep.Status.done : .active
            self = .step(AskStep(id: id, label: object?["label"] as? String ?? "", status: status))
        case "text":
            let delta = (json as? String) ?? (object?["delta"] as? String) ?? ""
            if delta.isEmpty { return nil }
            self = .text(delta)
        case "range":
            guard let range = AskRange(json: object) else { return nil }
            self = .range(range)
        case "done":
            var done = AskDone(
                truncated: object?["truncated"] as? Bool ?? false,
                interrupted: object?["interrupted"] as? Bool ?? false,
                refused: object?["refused"] as? Bool ?? false,
                model: object?["model"] as? String,
                start: object?["start"] as? String,
                end: object?["end"] as? String
            )
            done.range = AskRange(json: object)
            self = .done(done)
        case "error":
            let text = (object?["error"] as? String) ?? (json as? String) ?? "Something went wrong. Try again."
            self = .error(AskFailure(message: text, needsKey: object?["needsKey"] as? Bool ?? false))
        default:
            return nil
        }
    }
}

/// Bytes to `AskEvent`s, with the cut-off rule: when `finish()` is called and no terminal event was
/// seen, one `.cutOff` comes out.
public struct AskEventParser: Sendable {
    private var sse = SSEParser()
    public private(set) var sawTerminal = false

    public init() {}

    public mutating func push(_ chunk: Data) -> [AskEvent] { events(sse.push(chunk)) }
    public mutating func push(_ chunk: String) -> [AskEvent] { events(sse.push(chunk)) }
    public mutating func push(byte: UInt8) -> [AskEvent] { events(sse.push(byte: byte)) }

    public mutating func finish() -> [AskEvent] {
        var result = events(sse.finish())
        if !sawTerminal {
            sawTerminal = true
            result.append(.cutOff)
        }
        return result
    }

    private mutating func events(_ messages: [SSEMessage]) -> [AskEvent] {
        var result: [AskEvent] = []
        for message in messages {
            // Nothing after a terminal event counts.
            guard !sawTerminal, let event = AskEvent(message) else { continue }
            if event.isTerminal { sawTerminal = true }
            result.append(event)
        }
        return result
    }
}
