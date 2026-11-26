import Foundation

// Pure logic for the Ask tab. STUBS: signatures are final, bodies are placeholders the Ask track replaces.
// Mirrors public/ask-logic.js (cleanTurns, md, applyStep, applyAskEvent, endAskStream) and the send flow in
// public/ask-panel.js. The SSE parser and `askStream` are real and live in API/.

public enum AskLogic {
    /// The field text after a question could not be sent: the question goes back unless the person has already
    /// typed something new (a blank or whitespace-only field counts as empty).
    public static func restoredDraft(question: String, current: String) -> String {
        current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? question : current
    }

    /// Rewrites the Worker's error copy for the phone: the web says "in More", the iPhone sheet is called "Menu".
    /// Replaces "in More" as whole words only ("in Moreover" is left alone). Use it on error and failure text shown
    /// to the person, never on answer text.
    public static func appCopy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\bin More\b"#, with: "in Menu", options: .regularExpression)
    }
}

public enum AskHistory {
    /// Turns sent with a question.
    public static let maxSentTurns = 12
    /// Characters kept of each earlier turn.
    public static let maxTurnChars = 8000
    /// Turns kept on the phone between launches.
    public static let maxStoredTurns = 30

    /// Turns safe to send: drops blank turns, cuts each to 8,000 characters, keeps the last `max` (12), and removes
    /// leading assistant turns so the list starts with the user.
    public static func cleaned(_ turns: [AskTurn], max: Int = AskHistory.maxSentTurns) -> [AskTurn] {
        var kept = turns
            .filter { !isBlank($0.content) }
            .map { AskTurn(role: $0.role, content: String($0.content.prefix(maxTurnChars))) }
        if kept.count > max { kept = Array(kept.suffix(Swift.max(0, max))) }
        while let first = kept.first, first.role != .user { kept.removeFirst() }
        return kept
    }

    /// The last 30 turns, for saving. Same blank-turn rule, no per-turn cut.
    public static func stored(_ turns: [AskTurn]) -> [AskTurn] {
        Array(turns.filter { !isBlank($0.content) }.suffix(maxStoredTurns))
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A run inside a line of an answer.
public enum AskInline: Equatable, Sendable {
    case text(String)
    /// `**bold**`
    case bold(String)
    /// A newline inside a paragraph.
    case lineBreak
}

/// A block of an answer (the small Markdown subset Claude replies with).
public enum AskBlock: Equatable, Sendable {
    case paragraph([AskInline])
    case bullets([[AskInline]])
    /// `header` cells, then rows of cells. The `|---|---|` rule row is dropped.
    case table(header: [[AskInline]], rows: [[[AskInline]]])
}

public enum AskMarkdown {
    /// Paragraphs (consecutive lines joined with `.lineBreak`), `- ` or `* ` bullet lists, pipe tables, and `**bold**`
    /// runs. Everything else is plain text. Blank lines separate blocks. CRs are ignored.
    public static func blocks(_ text: String) -> [AskBlock] {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var out: [AskBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isRow(line) {
                var rows: [String] = []
                while i < lines.count, isRow(lines[i]) {
                    rows.append(lines[i])
                    i += 1
                }
                let cells: [[[AskInline]]] = rows.filter { !isRule($0) }.map { row in
                    let t = row.trimmingCharacters(in: .whitespacesAndNewlines)
                    let inner = t.dropFirst().dropLast()
                    return inner.split(separator: "|", omittingEmptySubsequences: false).map {
                        inlines($0.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                if let head = cells.first { out.append(.table(header: head, rows: Array(cells.dropFirst()))) }
                continue
            }
            if bulletText(line) != nil {
                var items: [[AskInline]] = []
                while i < lines.count, let item = bulletText(lines[i]) {
                    items.append(inlines(item))
                    i += 1
                }
                out.append(.bullets(items))
                continue
            }
            var para: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bulletText(lines[i]) == nil, !isRow(lines[i]) {
                para.append(lines[i])
                i += 1
            }
            if para.isEmpty {
                i += 1
            } else {
                var runs: [AskInline] = []
                for (n, l) in para.enumerated() {
                    if n > 0 { runs.append(.lineBreak) }
                    runs.append(contentsOf: inlines(l))
                }
                out.append(.paragraph(runs))
            }
        }
        return out
    }

    /// `**bold**` runs. A marker with no closing marker (or nothing inside) stays text.
    public static func inlines(_ line: String) -> [AskInline] {
        var out: [AskInline] = []
        var rest = Substring(line)
        func addText(_ t: Substring) {
            guard !t.isEmpty else { return }
            if case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + t)
            } else {
                out.append(.text(String(t)))
            }
        }
        while let open = rest.range(of: "**") {
            let afterOpen = open.upperBound
            // Needs at least one character between the markers.
            guard rest.distance(from: afterOpen, to: rest.endIndex) >= 3,
                  let probe = rest.index(afterOpen, offsetBy: 1, limitedBy: rest.endIndex),
                  let close = rest.range(of: "**", range: probe..<rest.endIndex) else { break }
            addText(rest[..<open.lowerBound])
            out.append(.bold(String(rest[afterOpen..<close.lowerBound])))
            rest = rest[close.upperBound...]
        }
        addText(rest)
        return out
    }

    private static func isRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    private static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        return t.dropFirst().dropLast().allSatisfy { $0 == ":" || $0 == "|" || $0 == "-" || $0.isWhitespace }
    }

    /// The text after a `- ` or `* ` marker, or nil when the line is not a bullet.
    private static func bulletText(_ line: String) -> String? {
        var chars = Substring(line)
        while let c = chars.first, c.isWhitespace { chars.removeFirst() }
        guard let marker = chars.first, marker == "-" || marker == "*" else { return nil }
        chars.removeFirst()
        guard let space = chars.first, space.isWhitespace else { return nil }
        while let c = chars.first, c.isWhitespace { chars.removeFirst() }
        return String(chars)
    }
}

/// One message in the chat as the screen draws it.
public struct AskChatTurn: Identifiable, Equatable, Sendable {
    /// Position in the chat (0 based), stable for the life of the session.
    public var id: Int
    public var role: AskRole
    public var content: String
    /// Progress steps ("Reading your calendar"), in order of first appearance.
    public var steps: [AskStep]
    public var truncated: Bool
    /// Cut short: Anthropic closed early or the connection dropped. The text is partial.
    public var interrupted: Bool
    public var refused: Bool
    /// The person pressed Stop.
    public var stopped: Bool
    /// Stop was pressed before any text arrived.
    public var stoppedEarly: Bool
    public var error: String?
    /// The error is about the Claude key: offer "Open Menu".
    public var needsKey: Bool
    /// Still receiving.
    public var isStreaming: Bool
    public var model: String?
    public var start: String?
    public var end: String?
    /// Assistant turns carry the question they answer and the range it was asked over, so Try again repeats that
    /// question over that range, not the latest one.
    public var question: String?
    public var scope: AskScope?
    /// Seconds spent before the answer started (or before Stop). Drives "Thought for 6s".
    public var thought: Double?
    /// What this answer ranked and what it was compared with. Set by the `range` event or by `done`; nil from an
    /// older Worker, so no line and no "Ask over all time" button.
    public var range: AskRange?
    /// Asked with All time on. Try again repeats it.
    public var allTime: Bool
    /// Asked with the question's own period ignored ("Ask over all time"). Try again repeats it.
    public var ignorePeriod: Bool

    public init(
        id: Int, role: AskRole, content: String = "", steps: [AskStep] = [], truncated: Bool = false,
        interrupted: Bool = false, refused: Bool = false, stopped: Bool = false, error: String? = nil,
        needsKey: Bool = false, isStreaming: Bool = false, model: String? = nil, start: String? = nil, end: String? = nil,
        stoppedEarly: Bool = false, question: String? = nil, scope: AskScope? = nil, thought: Double? = nil,
        range: AskRange? = nil, allTime: Bool = false, ignorePeriod: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.steps = steps
        self.truncated = truncated
        self.interrupted = interrupted
        self.refused = refused
        self.stopped = stopped
        self.stoppedEarly = stoppedEarly
        self.error = error
        self.needsKey = needsKey
        self.isStreaming = isStreaming
        self.model = model
        self.start = start
        self.end = end
        self.question = question
        self.scope = scope
        self.thought = thought
        self.range = range
        self.allTime = allTime
        self.ignorePeriod = ignorePeriod
    }
}

/// The chat as a value: feed it what happens, draw `turns`.
public struct AskChatSession: Equatable, Sendable {
    public private(set) var turns: [AskChatTurn]
    /// Set when the Worker said the Claude key is missing or rejected. The question and its answer were removed from
    /// `turns`; the screen shows the key form with this sentence until `clearKeyProblem()`.
    public private(set) var keyProblem: String?
    private var nextId: Int

    public init(turns: [AskChatTurn] = []) {
        self.turns = turns
        nextId = (turns.map(\.id).max() ?? -1) + 1
    }

    /// An answer is arriving.
    public var isStreaming: Bool { turns.last?.isStreaming ?? false }

    /// Starts a question: appends the user turn and an empty streaming assistant turn. Returns the history to send with
    /// it (`AskHistory.cleaned` over finished, error-free turns that have text, computed BEFORE appending), or nil
    /// when ignored: blank question (after trimming) or an answer is already streaming. The question is shown in full;
    /// the Worker trims what it reads. `scope` is the range this question is asked over, `allTime` and `ignorePeriod`
    /// are the other settings it is asked with (all three kept on the answer turn for Try again).
    @discardableResult
    public mutating func send(_ question: String, scope: AskScope? = nil, allTime: Bool = false, ignorePeriod: Bool = false) -> [AskTurn]? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return nil }
        let history = AskHistory.cleaned(
            turns.filter { $0.error == nil && !$0.isStreaming && !AskHistory.isBlank($0.content) }
                .map { AskTurn(role: $0.role, content: $0.content) })
        keyProblem = nil
        turns.append(AskChatTurn(id: nextId, role: .user, content: q))
        turns.append(AskChatTurn(id: nextId + 1, role: .assistant, isStreaming: true, question: q, scope: scope, allTime: allTime, ignorePeriod: ignorePeriod))
        nextId += 2
        return history
    }

    /// Applies one stream event to the streaming assistant turn.
    /// - `.step`: update the step with that id (keeping its place) or append it. Status other than "done" is active.
    /// - `.text`: append to `content`.
    /// - `.range`: set `range` (a later one replaces it).
    /// - `.done`: copy truncated, interrupted, refused, model, start, end, and `range` when it has one (it never
    ///   clears one already set). Stops streaming.
    /// - `.error`: set `error` and `needsKey`, keep any text, stop streaming. A needsKey error removes the question
    ///   and the answer instead and sets `keyProblem`.
    /// - `.cutOff`: set `interrupted`, keep text, stop streaming.
    /// Events after a terminal event, or with nothing streaming, are ignored.
    public mutating func apply(_ event: AskEvent) {
        guard let index = streamingIndex else { return }
        switch event {
        case .step(let step):
            if let at = turns[index].steps.firstIndex(where: { $0.id == step.id }) {
                var merged = step
                if merged.label.isEmpty { merged.label = turns[index].steps[at].label }
                turns[index].steps[at] = merged
            } else {
                turns[index].steps.append(step)
            }
        case .text(let delta):
            turns[index].content += delta
        case .range(let range):
            turns[index].range = range
        case .done(let done):
            if let range = done.range { turns[index].range = range }
            turns[index].truncated = done.truncated
            turns[index].interrupted = done.interrupted
            turns[index].refused = done.refused
            turns[index].model = done.model
            turns[index].start = done.start
            turns[index].end = done.end
            turns[index].isStreaming = false
        case .error(let failure):
            finishWithError(at: index, message: failure.message, needsKey: failure.needsKey)
        case .cutOff:
            turns[index].interrupted = true
            turns[index].isStreaming = false
        }
    }

    /// The person pressed Stop: keep the text, set `stopped`, stop streaming. No-op when nothing is streaming.
    public mutating func stop() {
        guard let index = streamingIndex else { return }
        turns[index].stopped = true
        turns[index].stoppedEarly = turns[index].content.isEmpty
        turns[index].isStreaming = false
    }

    /// The request failed before any event (offline, sign-in rejected). Sets `error` on the streaming turn and stops it.
    public mutating func fail(message: String, needsKey: Bool = false) {
        guard let index = streamingIndex else { return }
        finishWithError(at: index, message: message, needsKey: needsKey)
    }

    /// Records how long the answer took to start (or to be stopped). Only the first value for a turn counts.
    public mutating func noteThought(seconds: Double, forTurn id: Int) {
        guard let index = turns.firstIndex(where: { $0.id == id }), turns[index].thought == nil else { return }
        turns[index].thought = seconds
    }

    /// The key form has been shown.
    public mutating func clearKeyProblem() { keyProblem = nil }

    /// Forget the conversation.
    public mutating func reset() {
        turns = []
        keyProblem = nil
    }

    /// Turns to keep between launches: finished turns with text and no error, last 30.
    public var storedTurns: [AskTurn] {
        AskHistory.stored(
            turns.filter { $0.error == nil && !$0.isStreaming && !AskHistory.isBlank($0.content) }
                .map { AskTurn(role: $0.role, content: $0.content) })
    }

    /// Rebuilds a session from saved turns (no steps, nothing streaming).
    public init(restoring stored: [AskTurn]) {
        turns = stored.enumerated().map { AskChatTurn(id: $0.offset, role: $0.element.role, content: $0.element.content) }
        nextId = stored.count
    }

    private var streamingIndex: Int? {
        guard let last = turns.indices.last, turns[last].isStreaming else { return nil }
        return last
    }

    private mutating func finishWithError(at index: Int, message: String, needsKey: Bool) {
        if needsKey {
            // Drop the question and its answer, like the web, and go back to the key form.
            let from = index > 0 && turns[index - 1].role == .user ? index - 1 : index
            turns.removeSubrange(from...index)
            keyProblem = AskLogic.appCopy(message)
            return
        }
        turns[index].error = AskLogic.appCopy(message)
        turns[index].isStreaming = false
    }
}

/// How a table in an answer is laid out on a phone. Up to 3 columns share the width and wrap; anything wider, or
/// any accessibility text size, becomes one card per row with the label above the value.
public enum AskTableLayout {
    public enum Style: Equatable, Sendable { case grid, stacked }

    public static let maxGridColumns = 3

    public static func style(columns: Int, rows: Int, accessibilitySize: Bool) -> Style {
        guard !accessibilitySize, (1...maxGridColumns).contains(columns) else { return .stacked }
        return .grid
    }

    /// One card per row, each a list of (header cell, value cell). A cell past the end of a short row gets no entry.
    /// An extra cell (more cells than headers) has an empty label. A blank value is skipped.
    public static func stacked(header: [[AskInline]], rows: [[[AskInline]]]) -> [[(label: [AskInline], value: [AskInline])]] {
        rows.map { row in
            row.enumerated().compactMap { index, value in
                isBlank(value) ? nil : (label: index < header.count ? header[index] : [], value: value)
            }
        }
    }

    static func isBlank(_ cell: [AskInline]) -> Bool {
        cell.allSatisfy {
            switch $0 {
            case .text(let t), .bold(let t): t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .lineBreak: true
            }
        }
    }
}
