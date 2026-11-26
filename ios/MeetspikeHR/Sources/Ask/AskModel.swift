import Combine
import Foundation
import MeetspikeHRCore
import os
import UIKit

/// What the Ask tab is showing instead of (or around) the chat.
enum AskPhase: Equatable {
    case loading
    /// Status could not be read and nothing is saved to show. `message` is the plain sentence.
    case statusError(String)
    /// The Worker has no AI_KEY_SECRET, so a key cannot be saved yet.
    case unavailable
    /// No key saved, or the person chose Change.
    case keyForm
    case chat
}

/// A question that could not be sent because the key status could not be confirmed. The screen puts it back in
/// the field. `id` changes on every miss so the same question twice still notifies.
struct AskUnsent: Equatable {
    let id: Int
    let question: String
}

/// Owns the Ask tab: status and key, the chat session, the running stream, the captured date range and the
/// saved copy of the chat. The chat rules live in `AskChatSession` (shared core); this class only drives them.
@MainActor
final class AskModel: ObservableObject {
    @Published private(set) var session = AskChatSession()
    @Published private(set) var status: AskStatus?
    @Published private(set) var statusError: String?
    @Published private(set) var isLoadingStatus = false
    @Published var replaceKey = false
    @Published private(set) var keyBusy = false
    @Published private(set) var keyError: String?
    /// The range this chat is asked over: a copy taken when the tab opens, so the header and the request agree.
    @Published private(set) var scope: AskScope?
    /// The All time toggle. Applies to the next question. Off when the tab opens and after New chat.
    @Published private(set) var allTime = false
    /// Start of the answer in progress, for the "Pulling your calendar" ticker.
    @Published private(set) var runStart: Date?
    /// Set when a typed question was not sent. The screen restores it into the field (`AskLogic.restoredDraft`)
    /// and calls `clearUnsent()`.
    @Published private(set) var unsent: AskUnsent?
    /// Why the last question was not sent, when the status read failed. Cleared when a question is sent.
    @Published private(set) var sendError: String?

    private weak var env: AppEnvironment?
    private var sourceDisplay: SourceDisplay?
    private var run: Task<Void, Never>?
    private var runToken = 0
    private var observers: [AnyCancellable] = []
    /// A source-display change arrived while a status read was running: read again when it finishes.
    private var reloadPending = false
    /// Why the last status read failed (nil after a success). Kept even when an older status stays on screen.
    private var lastStatusFailure: String?
    private var unsentCount = 0
    /// The saved chat lives in a file (never UserDefaults). Chosen from the environment when the tab attaches,
    /// so demo data never touches the real chat.
    private var store: AskChatStore?
    private let directory: URL
    private let legacyDefaults: UserDefaults
    private static let log = Logger(subsystem: "com.meetspike.hr", category: "ask")

    init(directory: URL = AskChatStore.defaultDirectory(), legacyDefaults: UserDefaults = .standard) {
        self.directory = directory
        self.legacyDefaults = legacyDefaults
    }

    // MARK: Derived

    var phase: AskPhase {
        if let status {
            if status.available == false { return .unavailable }
            if status.connected != true || replaceKey { return .keyForm }
            return .chat
        }
        if let statusError { return .statusError(statusError) }
        return .loading
    }

    var headerText: String { AskScope.headerText(scope, allTime: allTime) }
    /// The toggle only matters with a scope. With none, all history is already used.
    var showsAllTimeToggle: Bool { scope != nil }

    func setAllTime(_ on: Bool) {
        allTime = on && scope != nil
    }
    var isStreaming: Bool { session.isStreaming }
    var hasSavedKey: Bool { status?.connected == true }
    var keyTail: String { status?.tail ?? "" }

    // MARK: Opening

    /// Hooks the model to the app: moves any old UserDefaults chat into the private file, picks the real or demo
    /// store, and listens for the cross-tab notifications.
    func attach(_ env: AppEnvironment) {
        if self.env === env { return }
        self.env = env
        let moved = AskChatStore.migrateLegacy(from: legacyDefaults, into: directory)
        if moved > 0 { Self.log.info("Moved \(moved) saved chat(s) out of UserDefaults") }
        syncStore(env)
        let center = NotificationCenter.default
        observers = [
            center.publisher(for: .meetspikeDisplaySourcesChanged).sink { [weak self] _ in
                // The shown source changed: read the status again, which clears the chat (applySourceDisplay).
                Task { @MainActor [weak self] in await self?.loadStatus(force: true) }
            },
            center.publisher(for: .meetspikeOpenAskKeyForm).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.consumePendingKeyForm() }
            },
            center.publisher(for: .meetspikeAskKeyRemoved).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.keyRemovedElsewhere() }
            },
        ]
    }

    /// The Ask tab came to the front: take the range, read the key status, drop the chat when the shown source changed.
    func open() async {
        guard let env else { return }
        syncStore(env)
        captureScope(env)
        allTime = false
        consumePendingKeyForm()
        await loadStatus(force: true)
    }

    /// Shows the key form when another tab asked for it (More's AI key row), then clears the flag.
    func consumePendingKeyForm() {
        guard let env, env.pendingAskKeyForm else { return }
        beginReplaceKey()
        env.pendingAskKeyForm = false
    }

    /// Real and demo data each have their own file. If the mode ever differs from the store, start clean.
    private func syncStore(_ env: AppEnvironment) {
        if let store, store.isDemo == env.isDemoData { return }
        let hadStore = store != nil
        store = AskChatStore(directory: directory, isDemo: env.isDemoData)
        if hadStore {
            if session.isStreaming { stop() }
            session = AskChatSession()
            sourceDisplay = nil
            status = nil
        }
    }

    private func captureScope(_ env: AppEnvironment) {
        scope = AskScope.forVisit(
            from: AskOrigin(tabName: env.previousTab?.rawValue),
            dates: (env.datesSpan.start, env.datesSpan.end),
            people: env.peopleSpan.map { ($0.start, $0.end) })
    }

    func loadStatus(force: Bool = false) async {
        if isLoadingStatus {
            if force { reloadPending = true }
            return
        }
        if status != nil && !force { return }
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        repeat {
            reloadPending = false
            await loadStatusOnce()
        } while reloadPending
    }

    private func loadStatusOnce() async {
        guard let env else { return }
        do {
            let loaded = try await env.api.loadAskStatus()
            env.noteLoaded(loaded)
            status = loaded.value
            statusError = nil
            lastStatusFailure = nil
            applySourceDisplay(loaded.value.sourceDisplay ?? SourceDisplay.make(oura: true, whoop: true))
        } catch is CancellationError {
            return
        } catch {
            // Offline or rejected sign-in: the banner explains it. With a status already on screen keep using it.
            env.report(error)
            lastStatusFailure = message(for: error)
            if status == nil { statusError = message(for: error) }
        }
    }

    /// The shown source changed (More toggled it) or this is the first read: restore or clear the chat.
    private func applySourceDisplay(_ display: SourceDisplay) {
        if display == sourceDisplay { return }
        let initial = sourceDisplay == nil
        if session.isStreaming { stop() }
        sourceDisplay = display
        session = initial ? AskChatSession(restoring: loadSaved(for: display)) : AskChatSession()
        save()
    }

    // MARK: Asking

    /// `restoreIfNotSent`: when the key status cannot be confirmed the question is handed back (`unsent`) and the
    /// reason shows (`sendError`, or the status error screen). Retry on an existing turn passes false so it never
    /// touches what the person is typing.
    func ask(
        _ text: String, scope askScope: AskScope? = nil, useCurrentScope: Bool = true, restoreIfNotSent: Bool = true,
        allTime askAllTime: Bool? = nil, ignorePeriod: Bool = false
    ) {
        guard !session.isStreaming else { return }
        let effective = useCurrentScope ? scope : askScope
        let rankAll = askAllTime ?? allTime
        Task {
            if status?.connected != true {
                await loadStatus(force: true)
                guard status?.connected == true else {
                    if restoreIfNotSent {
                        unsentCount += 1
                        unsent = AskUnsent(id: unsentCount, question: text)
                        // A failed read says why. A read that worked but found no key shows the key form instead.
                        sendError = lastStatusFailure
                    }
                    return
                }
            }
            sendError = nil
            start(text, scope: effective, allTime: rankAll, ignorePeriod: ignorePeriod)
        }
    }

    func clearUnsent() { unsent = nil }

    /// Try again: repeat that answer's own question over its own range and its own all time setting.
    func retry(_ turn: AskChatTurn) {
        guard let question = turn.question else { return }
        ask(
            question, scope: turn.scope, useCurrentScope: false, restoreIfNotSent: false,
            allTime: turn.allTime, ignorePeriod: turn.ignorePeriod)
    }

    /// Under an answer that ranked less than all history: the same question again, over everything. The question
    /// goes unchanged, so the phone sends `ignorePeriod` to keep a period in it from winning.
    func askOverAllTime(_ turn: AskChatTurn) {
        guard let question = turn.question else { return }
        ask(
            question, scope: turn.scope, useCurrentScope: false, restoreIfNotSent: false,
            allTime: true, ignorePeriod: true)
    }

    /// Whether "Ask over all time" is offered under this answer: it is finished, it ranked less than all history
    /// (a Worker that sent no range gives no button), and nothing is streaming.
    func offersAskOverAllTime(_ turn: AskChatTurn) -> Bool {
        guard !session.isStreaming, !turn.isStreaming, turn.question != nil, let range = turn.range else { return false }
        return !range.coversAllHistory(today: today)
    }

    /// The server's today (the phone's clock only until the first answer).
    var today: String { env?.today ?? DayMath.today(in: .current) }

    private func start(_ question: String, scope askScope: AskScope?, allTime askAllTime: Bool, ignorePeriod: Bool) {
        guard let env, let display = sourceDisplay else { return }
        guard let history = session.send(question, scope: askScope, allTime: askAllTime, ignorePeriod: ignorePeriod),
              let turnId = session.turns.last?.id else { return }
        save()
        runToken += 1
        let token = runToken
        let began = Date()
        runStart = began
        let request = AskRequest(
            question: session.turns[session.turns.count - 2].content, history: history, sourceDisplay: display,
            start: askScope?.start, end: askScope?.end, allTime: askAllTime, ignorePeriod: ignorePeriod)
        let api = env.api
        run = Task { [weak self] in
            do {
                var sawText = false
                for try await event in api.askStream(request) {
                    guard let self, self.runToken == token else { return }
                    if case .text = event, !sawText {
                        sawText = true
                        self.session.noteThought(seconds: Date().timeIntervalSince(began), forTurn: turnId)
                    }
                    self.session.apply(event)
                    if event.isTerminal { break }
                }
                guard let self, self.runToken == token else { return }
                // The stream ended with nothing terminal (cancelled upstream): keep the text, mark it partial.
                self.session.apply(.cutOff)
                self.finish(turnId: turnId, began: began)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.runToken == token else { return }
                // Another tab is on screen: its banner is not about this answer. The error shows in the chat.
                if self.env?.selectedTab == .ask { self.env?.report(error) }
                self.session.fail(message: self.message(for: error))
                self.finish(turnId: turnId, began: began)
            }
        }
    }

    private func finish(turnId: Int, began: Date) {
        session.noteThought(seconds: Date().timeIntervalSince(began), forTurn: turnId)
        runStart = nil
        run = nil
        let hadKeyProblem = session.keyProblem != nil
        if let problem = session.keyProblem {
            // The Worker said the key is missing or rejected: back to the key form with its sentence.
            session.clearKeyProblem()
            status?.connected = false
            status?.tail = nil
            replaceKey = false
            keyError = problem
        } else if session.turns.last?.error == nil {
            env?.noteOnline()
        }
        save()
        if let text = AskAnnouncement.message(
            for: session.turns.last, hadKeyProblem: hadKeyProblem, askTabSelected: env?.selectedTab == .ask) {
            post(text)
        }
    }

    func stop() {
        guard session.isStreaming, let turn = session.turns.last else { return }
        let seconds = runStart.map { Date().timeIntervalSince($0) } ?? 1
        runToken += 1
        run?.cancel()
        run = nil
        runStart = nil
        session.stop()
        session.noteThought(seconds: seconds, forTurn: turn.id)
        save()
        post("Stopped.")
    }

    func newChat() {
        if session.isStreaming { stop() }
        session.reset()
        sendError = nil
        allTime = false
        if let env { captureScope(env) }
        save()
    }

    // MARK: Key

    func saveKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let env, !keyBusy else { return }
        keyBusy = true
        keyError = nil
        defer { keyBusy = false }
        do {
            let result = try await env.api.saveAskKey(trimmed)
            replaceKey = false
            env.noteOnline()
            if status != nil {
                status?.available = true
                status?.connected = true
                status?.tail = result.tail
            } else {
                await loadStatus(force: true)
            }
        } catch {
            env.report(error)
            keyError = message(for: error)
        }
    }

    func removeKey() async {
        guard let env else { return }
        do {
            _ = try await env.api.deleteAskKey()
            // The saved chat goes with the key.
            if session.isStreaming { stop() }
            session = AskChatSession()
            store?.clear()
            status?.connected = false
            status?.tail = nil
            replaceKey = false
            keyError = nil
            env.noteOnline()
        } catch {
            env.report(error)
            keyError = message(for: error)
        }
    }

    /// The key was removed from the menu (it already deleted the key and the saved chat file): drop the chat shown here.
    func keyRemovedElsewhere() {
        if session.isStreaming { stop() }
        session = AskChatSession()
        store?.clear()
        status?.connected = false
        status?.tail = nil
        replaceKey = false
        keyError = nil
    }

    func beginReplaceKey() {
        keyError = nil
        replaceKey = true
    }

    func cancelReplaceKey() {
        keyError = nil
        replaceKey = false
    }

    // MARK: Saved chat

    private func loadSaved(for display: SourceDisplay) -> [AskTurn] {
        store?.load()?.turns(for: display) ?? []
    }

    private func save() {
        guard let display = sourceDisplay, let store else { return }
        do {
            try store.save(AskSavedChat(sourceDisplay: display, turns: session.storedTurns))
        } catch {
            Self.log.error("Could not save the chat: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    private func message(for error: Error) -> String {
        if let api = error as? APIError { return AskLogic.appCopy(api.message) }
        return "Could not reach Meetspike. Check your connection and try again."
    }

    private func post(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
