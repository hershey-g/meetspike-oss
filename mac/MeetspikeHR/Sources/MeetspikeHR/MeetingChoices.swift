import Foundation
import MeetspikeHRCore
import os

/// What the Mac remembers about meeting choices, on disk, so listening follows them with no network and right after a
/// launch: the Worker's meetings with their overrides as last seen, and the edits not yet sent. Nothing depends on
/// this loading: with nothing saved, or a file that cannot be read, the Mac listens to the calendar.
enum ListeningOverrides {
    private static let lock = NSLock()

    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MeetspikeHR", isDirectory: true)
            .appendingPathComponent("Overrides", isDirectory: true)
    }

    static var outbox: OverrideOutbox {
        OverrideOutbox(directory: directory.appendingPathComponent("Outbox", isDirectory: true))
    }

    private static var file: URL { directory.appendingPathComponent("remote-meetings.json", isDirectory: false) }

    static func stored() -> [RemoteMeeting] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let meetings = try? JSONDecoder().decode([RemoteMeeting].self, from: data) else { return [] }
        return meetings
    }

    /// The saved Worker meetings with the waiting edits laid over them: what listening uses.
    static func current() -> [RemoteMeeting] {
        OverrideOverlay.apply(outbox.pending(), to: stored())
    }

    /// Lays the answer of a successful save on the saved meetings at once, so the choice shows with no wait for the
    /// next read. False when it could not be saved (the old copy stays; the next read has the answer anyway).
    @discardableResult
    static func remember(_ answer: OverrideSaveResult, meetingID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([RemoteMeeting].self, from: $0) } ?? []
        let all = OverrideOverlay.applying(answer, meetingID: meetingID, to: old)
        guard all != old else { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Remembers what the Worker just said about some meetings, replacing earlier copies of the same ones and
    /// dropping the ones long past. False when it could not be saved (the old copy stays).
    @discardableResult
    static func remember(_ events: [Meeting], now: Date = .now) -> Bool {
        let fresh = remoteMeetings(from: events)
        lock.lock()
        defer { lock.unlock() }
        let old = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([RemoteMeeting].self, from: $0) } ?? []
        let ids = Set(fresh.map(\.id))
        let kept = old.filter {
            !ids.contains($0.id) && $0.calendarEnd > now.addingTimeInterval(-36 * 3_600)
                && $0.calendarStart < now.addingTimeInterval(10 * 86_400)
        }
        let all = (kept + fresh).sorted { ($0.calendarStart, $0.id) < ($1.calendarStart, $1.id) }
        guard all != old else { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Calendar meetings only: a recording of a meeting is another row with the same title and start, and would make
    /// the match look ambiguous.
    static func remoteMeetings(from events: [Meeting]) -> [RemoteMeeting] {
        events.compactMap { event in
            if let source = event.sourceType, !source.isEmpty, source != "calendar" { return nil }
            let override = event.override
            guard let start = override?.calendarStartUtc ?? APITime.parse(event.startUtc),
                  let end = override?.calendarEndUtc ?? APITime.parse(event.endUtc), end > start else { return nil }
            return RemoteMeeting(id: event.id, title: event.title ?? "", calendarStart: start, calendarEnd: end, override: override)
        }
    }
}

/// How one choice ended, for the menu.
enum ChoiceResult: Equatable {
    case saved
    /// Saved on this Mac, sends when it can reach the Worker.
    case queued(String)
    /// Nothing changed. The text says why.
    case failed(String)
}

/// The Mac's "Still going", "Ended now" and "I didn't join" for the meeting it is listening to.
///
/// Every edit goes through the outbox on disk first, then out, so a choice made offline is never lost and never sent
/// out of order. The Mac follows a waiting edit at once (listening windows read the outbox laid over the last Worker
/// answer), and the Worker's answer replaces that the moment the save succeeds. A choice that is refused when it is
/// made (a bad request, a Worker that is not ready, a server error, a rejected sign-in) leaves the old state, says so
/// and is not queued. Only "offline" waits. See `OverrideDelivery.outcomeWhenMade`.
@MainActor
final class MeetingChoices: ObservableObject {
    private static let log = os.Logger(subsystem: "com.meetspike.hr", category: "choices")

    /// The last thing to say, shown under the buttons. Clears itself.
    @Published private(set) var note: String?
    @Published private(set) var noteIsProblem = false
    @Published private(set) var busy = false
    /// The meeting "I didn't join" was last used on, so the menu can show the choice with Undo for that meeting.
    @Published private(set) var lastDidntJoin: DidntJoinUse?

    /// A use of "I didn't join": the meeting it was for (by id, so nothing else is ever touched), its title, when the
    /// buttons for it would have stopped (the end of its cooldown) and when it was used.
    struct DidntJoinUse: Equatable {
        var meetingID: String
        var title: String
        var until: Date
        var usedAt: Date
    }

    private let outbox: OverrideOutbox
    private let apply: ([RemoteMeeting]) -> Void
    private var noteTask: Task<Void, Never>?
    private var gate = RefreshGate()
    private var schedule = ListeningReadSchedule()
    /// When the Worker last answered a save, per meeting. A read that started before that answer may carry the old
    /// state, so it must not overwrite the answer.
    private var answeredAt: [String: Date] = [:]
    private var tail: Task<Void, Never>?

    /// - Parameter apply: hands the calendar the Worker's meetings with the waiting edits laid over them.
    init(outbox: OverrideOutbox = ListeningOverrides.outbox, apply: @escaping ([RemoteMeeting]) -> Void) {
        self.outbox = outbox
        self.apply = apply
    }

    /// Lays what was saved last time over the calendar, before any network. Call once at launch.
    func start() {
        pushListening()
    }

    func pushListening() {
        apply(ListeningOverrides.current())
    }

    var hasWaiting: Bool { !outbox.pending().isEmpty }

    // MARK: Choosing

    @discardableResult
    func submit(_ edit: OverrideEdit, meetingID: String) async -> ChoiceResult {
        guard !edit.isEmpty, !busy else { return .failed("Nothing to change.") }
        busy = true
        defer { busy = false }
        setNote(nil, problem: false)
        let queuedAt = Date()
        let queued = outbox.enqueueReplacing(eventID: meetingID, edit: edit, at: queuedAt)
        guard queued.saved else {
            // The queue could not be written: send straight, with no promise to try again.
            return await sendWithoutQueue(edit, meetingID: meetingID)
        }
        pushListening()
        let item = OverrideOutbox.Item(eventID: meetingID, edit: edit, queuedAt: queuedAt)
        // If this one is refused, the edit it replaced (or merged into) comes back as it was.
        restoreOnDrop.append((item, queued.replaced))
        defer { restoreOnDrop.removeAll { $0.item.isSameEntry(as: item) } }
        let outcome = await flush(focus: item)
        switch outcome {
        case .sent:
            await refresh(force: true)
            return .saved
        case .waiting(let text):
            setNote(text, problem: false)
            return .queued(text)
        case .refused(let text):
            // Leaves the old state, and says so. The earlier waiting edit goes back; something newer stays.
            outbox.restore(queued.replaced, insteadOf: item)
            pushListening()
            setNote(text, problem: true)
            return .failed(text)
        }
    }

    /// "Still going" for a meeting the Mac is listening to: 15 minutes more.
    func stillGoing(_ target: LiveAdjustTarget?, now: Date = .now) async {
        guard let target else { setNote("Can't tell which meeting this is.", problem: true); return }
        guard let edit = LiveAdjust.stillGoing(target, now: now) else {
            setNote("That's as long as a meeting can run.", problem: true)
            return
        }
        guard LiveAdjust.offer(target, now: now).stillGoing else { setNote("That meeting is over.", problem: true); return }
        await submit(edit, meetingID: target.meetingID)
    }

    /// "Ended now": the meeting ends at this moment.
    func endedNow(_ target: LiveAdjustTarget?, now: Date = .now) async {
        guard let target else { setNote("Can't tell which meeting this is.", problem: true); return }
        guard let edit = LiveAdjust.endedNow(target, now: now) else {
            setNote("It hasn't started yet.", problem: true)
            return
        }
        guard LiveAdjust.offer(target, now: now).endedNow else { setNote("That meeting is over.", problem: true); return }
        await submit(edit, meetingID: target.meetingID)
    }

    /// "I didn't join". For a meeting in a series it is only this one. Only while the meeting is current, and the
    /// target is the one that was on screen when the button was drawn: a second click right after cannot reach another
    /// meeting.
    func didntJoin(_ target: LiveAdjustTarget?, now: Date = .now) async {
        guard let target else { setNote("Can't tell which meeting this is.", problem: true); return }
        guard LiveAdjust.offer(target, now: now).didntJoin else {
            setNote("That meeting isn't on right now.", problem: true)
            return
        }
        if let last = lastDidntJoin, last.meetingID != target.meetingID, now.timeIntervalSince(last.usedAt) < 3 { return }
        let result = await submit(OverrideEdit(scope: .event, state: .set(.notJoined)), meetingID: target.meetingID)
        switch result {
        case .saved, .queued:
            lastDidntJoin = DidntJoinUse(
                meetingID: target.meetingID, title: target.title,
                until: target.end.addingTimeInterval(CalendarMeeting.cooldown), usedAt: now)
        case .failed: break
        }
    }

    /// Undo for the meeting "I didn't join" was used on. A series rule that also leaves it out needs "linked".
    func undoDidntJoin() async {
        guard let used = lastDidntJoin else { return }
        let override = ListeningOverrides.stored().first { $0.id == used.meetingID }?.override
        let edit: OverrideEdit
        if case .save(let planned) = MeetingActions.plan(.undo, override: override ?? MeetingOverride(state: .notJoined, scope: .event)) {
            edit = planned
        } else {
            edit = OverrideEdit(scope: .event, state: .clear)
        }
        switch await submit(edit, meetingID: used.meetingID) {
        case .saved, .queued: lastDidntJoin = nil
        case .failed: break
        }
    }

    // MARK: Sending

    private enum Outcome {
        case sent
        case waiting(String)
        case refused(String)
    }

    /// Sends the waiting edits, oldest first, and stops at the first that has to wait. `focus` is the one the caller
    /// cares about.
    private func flush(focus: OverrideOutbox.Item?) async -> Outcome {
        await serial { [self] in
            var focusOutcome: Outcome? = focus == nil ? .sent : nil
            var stopped: Outcome?
            for item in outbox.pending() {
                if let stopped {
                    if let focus, item.isSameEntry(as: focus) { focusOutcome = stopped }
                    continue
                }
                guard let api = Self.api() else {
                    let text = "Add your Meetspike connection in Settings first."
                    // Nothing to send to: the edit waits, nothing was refused.
                    stopped = .waiting(text)
                    if focus.map(item.isSameEntry) == true { focusOutcome = stopped ?? focusOutcome }
                    continue
                }
                do {
                    let answer = try await api.saveOverride(meetingID: item.eventID, edit: item.edit)
                    noteAnswer(answer, meetingID: item.eventID)
                    outbox.remove(item)
                    settle(item, .sent)
                    if focus.map(item.isSameEntry) == true { focusOutcome = .sent }
                } catch is CancellationError {
                    stopped = .waiting("Saved. It sends when Meetspike is reachable.")
                    if focus.map(item.isSameEntry) == true { focusOutcome = stopped ?? focusOutcome }
                } catch {
                    Self.log.notice("Saving a choice failed: \(Self.describe(error), privacy: .public)")
                    switch OverrideDelivery.verdict(for: error) {
                    case .drop(let text):
                        if let entry = restoreOnDrop.first(where: { $0.item.isSameEntry(as: item) }) {
                            outbox.restore(entry.replaced, insteadOf: item)
                        } else {
                            outbox.remove(item)
                        }
                        settle(item, .refused(text))
                        if focus.map(item.isSameEntry) == true { focusOutcome = .refused(text) } else { setNote(text, problem: true) }
                    case .keep:
                        let outcome: Outcome
                        switch OverrideDelivery.outcomeWhenMade(for: error) {
                        case .waiting: outcome = .waiting(Self.macOffline)
                        case .refused(let text): outcome = .refused(Self.macText(error, text))
                        }
                        stopped = outcome
                        if focus.map(item.isSameEntry) == true { focusOutcome = outcome }
                    }
                }
            }
            // A pass that ran ahead of this one may already have sent or dropped the item: say what happened to it.
            return focusOutcome ?? resolved(focus)
        }
    }

    /// What happened to an item that this pass did not reach because it was no longer waiting.
    private func resolved(_ focus: OverrideOutbox.Item?) -> Outcome {
        guard let focus else { return .sent }
        if let done = settled.last(where: { $0.item.isSameEntry(as: focus) }) { return done.outcome }
        let newer = outbox.pending().contains { $0.eventID == focus.eventID && $0.edit.scope == focus.edit.scope }
        // A newer edit replaced this one: it has its own result. This one did not fail.
        if newer { return .sent }
        return .waiting("Saved. It sends when Meetspike is reachable.")
    }

    private func settle(_ item: OverrideOutbox.Item, _ outcome: Outcome) {
        settled.append((item, outcome))
        if settled.count > 40 { settled.removeFirst(settled.count - 40) }
    }

    private var settled: [(item: OverrideOutbox.Item, outcome: Outcome)] = []

    /// Edits just made by `submit`, with the edit each one replaced. A 400 or 404 on one of them puts the replaced edit
    /// back instead of leaving the meeting with nothing.
    private var restoreOnDrop: [(item: OverrideOutbox.Item, replaced: OverrideOutbox.Item?)] = []

    /// The phone's wording points at its Menu tab. The Mac has Settings.
    private static func macText(_ error: Error, _ text: String) -> String {
        (error as? APIError) == .accessRejected ? "Sign-in needed. Check your Access token in Settings." : text
    }

    private static let macOffline = "Can't reach Meetspike. Saved here, it sends when you're back online."

    private func sendWithoutQueue(_ edit: OverrideEdit, meetingID: String) async -> ChoiceResult {
        guard let api = Self.api() else {
            setNote("Add your Meetspike connection in Settings first.", problem: true)
            return .failed("Not set up.")
        }
        do {
            let answer = try await api.saveOverride(meetingID: meetingID, edit: edit)
            noteAnswer(answer, meetingID: meetingID)
            pushListening()
            await refresh(force: true)
            return .saved
        } catch {
            Self.log.notice("Saving a choice failed: \(Self.describe(error), privacy: .public)")
            // Not queued here (the outbox could not be written), so even offline nothing waits.
            let text: String
            switch OverrideDelivery.outcomeWhenMade(for: error) {
            case .waiting: text = "Can't reach Meetspike. Nothing changed."
            case .refused(let reason): text = Self.macText(error, reason)
            }
            setNote(text, problem: true)
            return .failed(text)
        }
    }

    /// Runs the closures one after the other, so two sends never overlap and edits go out in order.
    private func serial<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: Reading

    /// Reads yesterday, today and tomorrow from the Worker and keeps the meetings with their choices, then lays the
    /// waiting edits over them. A failed read keeps what the Mac had (so listening follows the calendar plus whatever
    /// was saved). Today is read at most every five minutes, yesterday and tomorrow every 30, unless forced; waiting
    /// edits are sent first.
    ///
    /// One read at a time (`RefreshGate`). A forced one that comes in during a run runs once more right after it, so a
    /// run that started before a change cannot be the last word.
    func refresh(force: Bool = false, now: Date = .now) async {
        guard gate.request(force: force, now: now) else { return }
        var runForced = force
        var runNow = now
        // `run` never throws, so the gate is always told the run ended, on an error or a cancelled task too.
        while true {
            await run(force: runForced, now: runNow)
            guard gate.finished(now: .now) else { break }
            // The follow-up exists because of a forced request.
            runForced = true
            runNow = .now
        }
    }

    private func run(force: Bool, now: Date) async {
        if !outbox.pending().isEmpty { _ = await flush(focus: nil) }
        if let api = Self.api() {
            let today = DayMath.today(in: .current, now: now)
            for day in schedule.daysToRead(today: today, now: now, force: force) {
                let startedAt = Date()
                do {
                    let view = try await api.view(date: day)
                    if let events = view.day?.calendar?.events {
                        // A meeting whose save was answered after this read began may be old here: leave it be.
                        let current = events.filter { (answeredAt[$0.id] ?? .distantPast) <= startedAt }
                        ListeningOverrides.remember(current, now: now)
                    }
                    schedule.didRead(day, at: Date())
                } catch {
                    // Offline, not signed in, an older Worker: listening keeps the meetings it already has. The days
                    // not read stay due for the next run.
                    Self.log.notice("Reading meeting choices failed: \(Self.describe(error), privacy: .public)")
                    break
                }
            }
        }
        pushListening()
    }

    /// The Worker answered a save: show it now, and remember when, so an older read cannot put the old state back.
    private func noteAnswer(_ answer: OverrideSaveResult, meetingID: String) {
        let at = Date()
        answeredAt[meetingID] = at
        // A read is long over within ten minutes, so older entries can never matter.
        answeredAt = answeredAt.filter { at.timeIntervalSince($0.value) < 600 }
        if !ListeningOverrides.remember(answer, meetingID: meetingID) {
            Self.log.error("A saved choice could not be remembered on this Mac")
        }
    }

    // MARK: Helpers

    private static func api() -> APIClient? {
        guard let destination = Destination(UserDefaults.standard.string(forKey: "workerOrigin") ?? "") else { return nil }
        let credentials = try? CredentialStore.load()
        return APIClient(destination: destination, credentials: credentials, userAgent: "MeetspikeHR-Mac")
    }

    /// A short reason with no text from the Worker (nothing from a meeting ends up in a log).
    private static func describe(_ error: Error) -> String {
        guard let error = error as? APIError else { return "error" }
        switch error {
        case .accessRejected: return "access rejected"
        case .http(let status, _): return "status \(status)"
        case .offline: return "offline"
        case .decoding: return "unreadable answer"
        case .invalidRequest: return "bad request"
        case .notConfigured: return "not configured"
        }
    }

    private func setNote(_ text: String?, problem: Bool) {
        noteTask?.cancel()
        noteTask = nil
        note = text
        noteIsProblem = problem && text != nil
        guard text != nil else { return }
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.note = nil
            self?.noteIsProblem = false
        }
    }
}
