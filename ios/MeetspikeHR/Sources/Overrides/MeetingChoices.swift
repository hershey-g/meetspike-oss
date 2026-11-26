import Foundation
import MeetspikeHRCore
import SwiftUI

extension Notification.Name {
    /// A meeting choice was saved (or a waiting one was sent). Today, Dates and People load again. Not a sync.
    static let meetspikeMeetingsChanged = Notification.Name("com.meetspike.meetingsChanged")
}

/// What happened to one choice.
enum ChoiceResult: Equatable {
    /// The Worker has it.
    case saved
    /// Saved on this phone, sends when the phone is back online.
    case queued(String)
    /// Nothing changed. The text says why.
    case failed(String)

    var message: String? {
        switch self {
        case .saved: nil
        case .queued(let text), .failed(let text): text
        }
    }
}

/// Sends the person's meeting choices to the Worker and keeps what the phone needs when it cannot.
///
/// Every edit goes through the outbox on disk first, then out: one path, so an edit made offline, killed mid-send or
/// refused for now is never lost and never sent out of order. A newer edit for the same meeting and scope is merged
/// into the older one, field by field.
///
/// Two cases, decided by `OverrideDelivery`. A choice that fails at the moment it is made (`outcomeWhenMade`): only
/// offline waits (saved on the phone, it sends later). Anything else (503, 500, a rejected sign-in, a bad request, a
/// meeting that is gone) is refused: the old state stays, the person is told, and it is not queued. An edit that is
/// already waiting (`verdict`) stays in the outbox on offline, 503, a rejected sign-in and server errors, and is
/// dropped and said on 400 and 404.
@MainActor
final class MeetingChoices: ObservableObject {
    /// Meetings with an edit waiting to be sent (shown as "Sends when online").
    @Published private(set) var waiting: Set<String> = []
    /// The last thing to say about a meeting's choice, by meeting id.
    @Published private(set) var notes: [String: String] = [:]
    /// Edits the Worker refused for good, since the last time the person saw them.
    @Published private(set) var dropped: [String] = []
    /// Meeting ids with a save in flight.
    @Published private(set) var busy: Set<String> = []

    private let outbox: OverrideOutbox
    private let api: () -> MeetspikeAPI
    private let apply: ([RemoteMeeting]) -> Void
    private let report: (Error) -> Void
    private let timeZone: () -> TimeZone
    private var tail: Task<Void, Never>?
    private var lastListeningRefresh = Date.distantPast
    private var noteTasks: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - api: the current API (it changes when settings change).
    ///   - apply: hands the phone its meetings with the choices laid over them.
    ///   - report: tells the connection banner about a failed call.
    ///   - timeZone: the Worker's time zone, which names the day of a meeting.
    init(
        outbox: OverrideOutbox = ListeningOverrides.outbox, api: @escaping () -> MeetspikeAPI,
        apply: @escaping ([RemoteMeeting]) -> Void, report: @escaping (Error) -> Void,
        timeZone: @escaping () -> TimeZone
    ) {
        self.timeZone = timeZone
        self.outbox = outbox
        self.api = api
        self.apply = apply
        self.report = report
        waiting = Set(outbox.pending().map(\.eventID))
    }

    // MARK: Making a choice

    /// Saves one edit. The phone follows it at once when it is queued, and the Worker's answer replaces that.
    @discardableResult
    func submit(_ edit: OverrideEdit, meetingID: String, days: Set<String> = []) async -> ChoiceResult {
        guard !edit.isEmpty else { return .failed("Nothing to change.") }
        busy.insert(meetingID)
        defer { busy.remove(meetingID) }
        setNote(nil, for: meetingID)
        let now = Date()
        let queued = outbox.enqueueReplacing(eventID: meetingID, edit: edit, at: now)
        if !queued.saved {
            // The queue could not be written. Send it straight, with no promise to try again.
            return await sendWithoutQueue(edit, meetingID: meetingID, days: days)
        }
        refreshWaiting()
        pushListening()
        let item = OverrideOutbox.Item(eventID: meetingID, edit: edit, queuedAt: now)
        // If this one is refused, the edit it replaced (or merged into) comes back as it was.
        restoreOnDrop.append((item, queued.replaced))
        defer { restoreOnDrop.removeAll { $0.item.isSameEntry(as: item) } }
        let outcome = await flush(focus: item, days: days)
        switch outcome {
        case .sent:
            setNote(nil, for: meetingID)
            return .saved
        case .waiting(let text):
            setNote(text, for: meetingID)
            return .queued(text)
        case .refused(let text):
            // Leaves the old state, and says so. The earlier waiting edit goes back; something newer stays.
            outbox.restore(queued.replaced, insteadOf: item)
            refreshWaiting()
            pushListening()
            setNote(text, for: meetingID)
            return .failed(text)
        }
    }

    /// The Live Activity buttons and the Live card. Reads the meeting the phone is on, builds the edit, submits it.
    @discardableResult
    func liveAdjust(_ target: LiveAdjustTarget?, _ kind: LiveAdjustKind, now: Date = .now) async -> ChoiceResult {
        guard let target else { return .failed("Couldn't tell which meeting this is.") }
        let edit: OverrideEdit?
        switch kind {
        case .stillGoing: edit = LiveAdjust.stillGoing(target, now: now)
        case .endedNow: edit = LiveAdjust.endedNow(target, now: now)
        }
        guard let edit else {
            return .failed(kind == .stillGoing ? "That's as long as a meeting can run." : "It hasn't started yet.")
        }
        // A button on a Lock Screen that was not redrawn can be tapped after the listening window closed.
        let offer = LiveAdjust.offer(target, now: now)
        guard kind == .stillGoing ? offer.stillGoing : offer.endedNow else {
            return .failed("That meeting is over.")
        }
        return await submit(edit, meetingID: target.meetingID, days: days(of: target))
    }

    // MARK: Sending what is waiting

    /// Sends the waiting edits, oldest first. Stops at the first one that has to wait. Safe to call any time.
    func sendWaiting(force: Bool = false) async {
        // Polls and loads call this often: one pass at a time, and not more than every 30 seconds after a pass that
        // had to leave something waiting.
        guard !sendingWaiting, force || Date().timeIntervalSince(lastWaitingAttempt) > 30,
              !outbox.pending().isEmpty else { return }
        sendingWaiting = true
        defer {
            sendingWaiting = false
            lastWaitingAttempt = Date()
        }
        _ = await flush(focus: nil, days: [])
    }

    /// Edits just made by `submit`, with the edit each one replaced. A 400 or 404 on one of them puts the replaced edit
    /// back instead of leaving the meeting with nothing.
    private var restoreOnDrop: [(item: OverrideOutbox.Item, replaced: OverrideOutbox.Item?)] = []

    /// The day (and the day it ends on) of the meeting a live button is for, in the Worker's time zone.
    private func days(of target: LiveAdjustTarget) -> Set<String> {
        [dayName(target.start), dayName(target.end)]
    }

    private func dayName(_ date: Date) -> String { DayMath.today(in: timeZone(), now: date) }

    /// The day of a meeting whose edit was just sent, from the meetings the phone last saw. Today when it is not known.
    private func day(ofMeeting id: String) -> String {
        if let known = ListeningOverrides.stored().first(where: { $0.id == id }) { return dayName(known.calendarStart) }
        return DayMath.today(in: timeZone())
    }

    private var sendingWaiting = false
    private var lastWaitingAttempt = Date.distantPast

    private enum Outcome {
        case sent
        case waiting(String)
        case refused(String)
    }

    private func flush(focus: OverrideOutbox.Item?, days: Set<String>) async -> Outcome {
        await serial { [self] in
            var focusOutcome: Outcome? = focus == nil ? .sent : nil
            var changedIDs: [String] = []
            var movedStarts: [Date] = []
            var stopped: Outcome?
            for item in outbox.pending() {
                if let stopped {
                    if let focus, item.isSameEntry(as: focus) { focusOutcome = stopped }
                    continue
                }
                do {
                    _ = try await api().saveOverride(meetingID: item.eventID, edit: item.edit)
                    outbox.remove(item)
                    recentlySent.append((item, Date()))
                    settle(item, .sent)
                    changedIDs.append(item.eventID)
                    // Times the person moved the meeting to: its new day is read too.
                    if case .set(let moved) = item.edit.startUtc { movedStarts.append(moved) }
                    if focus.map(item.isSameEntry) == true { focusOutcome = .sent }
                } catch is CancellationError {
                    stopped = .waiting("Saved on this phone. It sends when you are back online.")
                    if focus.map(item.isSameEntry) == true { focusOutcome = stopped ?? focusOutcome }
                } catch {
                    let verdict = OverrideDelivery.verdict(for: error)
                    switch verdict {
                    case .drop(let text):
                        if let entry = restoreOnDrop.first(where: { $0.item.isSameEntry(as: item) }) {
                            outbox.restore(entry.replaced, insteadOf: item)
                        } else {
                            outbox.remove(item)
                        }
                        settle(item, .refused(text))
                        if focus.map(item.isSameEntry) == true {
                            focusOutcome = .refused(text)
                        } else {
                            dropped.append(text)
                            setNote(text, for: item.eventID)
                        }
                        changedIDs.append(item.eventID)
                    case .keep(let text):
                        report(error)
                        // The edit that was just made: only offline waits, the rest is refused and the old state stays.
                        // An edit that was already waiting stays in the outbox either way (the verdict above).
                        let outcome: Outcome
                        let isOffline: Bool
                        switch OverrideDelivery.outcomeWhenMade(for: error) {
                        case .waiting(let words): outcome = .waiting(words); isOffline = true
                        case .refused(let words): outcome = .refused(words); isOffline = false
                        }
                        stopped = outcome
                        if focus.map(item.isSameEntry) == true { focusOutcome = outcome }
                        if !isOffline, focus.map(item.isSameEntry) != true { setNote(text, for: item.eventID) }
                    }
                }
            }
            refreshWaiting()
            if !changedIDs.isEmpty {
                let all = days.union(changedIDs.map { day(ofMeeting: $0) })
                await didChange(days: all, meetingIDs: changedIDs, movedStarts: movedStarts)
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
        return .waiting("Saved on this phone. It sends when you are back online.")
    }

    private func settle(_ item: OverrideOutbox.Item, _ outcome: Outcome) {
        settled.append((item, outcome))
        if settled.count > 40 { settled.removeFirst(settled.count - 40) }
    }

    private var settled: [(item: OverrideOutbox.Item, outcome: Outcome)] = []

    private func sendWithoutQueue(_ edit: OverrideEdit, meetingID: String, days: Set<String>) async -> ChoiceResult {
        do {
            _ = try await api().saveOverride(meetingID: meetingID, edit: edit)
            // Like flush: a moved start names the day the meeting now starts on, so that day is read back too.
            var movedStarts: [Date] = []
            if case .set(let moved) = edit.startUtc { movedStarts.append(moved) }
            await didChange(days: days.isEmpty ? [day(ofMeeting: meetingID)] : days, meetingIDs: [meetingID], movedStarts: movedStarts)
            return .saved
        } catch {
            report(error)
            let text: String
            // The queue could not be written, so nothing can wait: offline says so plainly, the rest is refused.
            switch OverrideDelivery.outcomeWhenMade(for: error) {
            case .waiting: text = "Can't reach Meetspike. Nothing changed."
            case .refused(let message): text = message
            }
            setNote(text, for: meetingID)
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

    // MARK: After a change

    /// Something reached the Worker: forget the saved answers for those days, load the screens again, and read the
    /// meetings back so listening follows what the Worker now says.
    private func didChange(days: Set<String>, meetingIDs: [String], movedStarts: [Date] = []) async {
        let cache = api().responseCache
        // The forced read below fetches today and the day each changed meeting starts on, in the Worker's zone.
        // Those saved answers go too, so the read is not served from the cache.
        let starts = changedStarts(meetingIDs: meetingIDs) + movedStarts
        let readDays = ListeningRefreshDays.forcedDays(now: Date(), timeZone: timeZone(), changedMeetingStarts: starts)
        let affected = days.union(readDays).flatMap { [DayMath.addDays($0, -1), $0, DayMath.addDays($0, 1)] }
        if let cache {
            await cache.invalidate(days: Set(affected), meetingID: meetingIDs.first)
            for id in meetingIDs.dropFirst() { await cache.invalidate(days: [], meetingID: id) }
        }
        NotificationCenter.default.post(name: .meetspikeMeetingsChanged, object: nil)
        await refreshListening(force: true, changedMeetingStarts: starts)
    }

    /// When the meetings with these ids start, from the meetings the phone last saw.
    private func changedStarts(meetingIDs: [String]) -> [Date] {
        let known = ListeningOverrides.stored()
        return meetingIDs.compactMap { id in known.first { $0.id == id }?.calendarStart }
    }

    /// Reads meetings from the Worker for the listening windows, and hands the phone the result. A failed read keeps
    /// what the phone had. At most once a minute unless forced.
    ///
    /// The day is named in the Worker's time zone, never the device's. A forced read (after a change) takes today and
    /// the day each changed meeting starts on, since a meeting from yesterday can still be running or moved to
    /// another day.
    func refreshListening(today: String? = nil, force: Bool = false, changedMeetingStarts: [Date] = []) async {
        guard force || Date().timeIntervalSince(lastListeningRefresh) > 60 else { return }
        lastListeningRefresh = Date()
        let zone = timeZone()
        let days: [String]
        if force {
            days = ListeningRefreshDays.forcedDays(now: Date(), timeZone: zone, changedMeetingStarts: changedMeetingStarts)
        } else {
            days = [today ?? DayMath.today(in: zone)]
        }
        for day in days {
            do {
                let view = try await api().view(date: day)
                if let events = view.day?.calendar?.events { ListeningOverrides.remember(events) }
            } catch {
                // Offline or not signed in: listening keeps the meetings it already has.
            }
        }
        pushListening()
    }

    /// A day's meetings were loaded by a screen: remember them for listening, then hand the phone the result.
    func noteLoaded(events: [Meeting]) {
        ListeningOverrides.remember(events)
        pushListening()
    }

    /// Gives the phone the saved Worker meetings with the waiting edits laid over them.
    func pushListening() {
        apply(ListeningOverrides.current())
    }

    private func refreshWaiting() {
        let ids = Set(outbox.pending().map(\.eventID))
        if ids != waiting { waiting = ids }
    }

    // MARK: Notes

    private func setNote(_ text: String?, for id: String) {
        noteTasks[id]?.cancel()
        noteTasks[id] = nil
        if notes[id] != text { notes[id] = text }
        guard text != nil else { return }
        noteTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.notes[id] = nil
        }
    }

    func clearDropped() { dropped = [] }

    /// A meeting's waiting edits overlaid on a day's list, for the rows.
    /// Edits that just went out stay laid over the rows for a few seconds, so a row does not flick back to what it was
    /// while the screen loads the Worker's answer.
    func overlaid(_ events: [Meeting]) -> [Meeting] {
        recentlySent.removeAll { Date().timeIntervalSince($0.at) > 15 }
        return OverrideOverlay.apply(recentlySent.map(\.item) + outbox.pending(), to: events)
    }

    private var recentlySent: [(item: OverrideOutbox.Item, at: Date)] = []
}

/// Demo mode has no calendar to match, so the shown meeting stands in for its own Worker meeting. That lets the Lock
/// Screen and card buttons show in screenshots.
enum DemoAdjust {
    static func target(schedule: MeetingSchedule, now: Date) -> LiveAdjustTarget? {
        guard let meeting = schedule.displayedMeeting(at: now) else { return nil }
        return LiveAdjustTarget(
            meetingID: "demo-live", title: meeting.title, start: meeting.start, end: meeting.end, calendarEnd: meeting.end)
    }
}
