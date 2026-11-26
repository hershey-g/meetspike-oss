import Foundation
import MeetspikeHRCore
import SwiftUI

/// Which meeting is open. `auto` lets a live meeting open itself (app.js `state.openMeeting === undefined`).
enum TodayMeetingSelection: Equatable {
    case auto
    case closed
    case meeting(String)
}

/// A calendar and wearable refresh in progress, done or failed (`state.calSync` in app.js).
enum TodaySyncState: Equatable {
    case idle
    case running
    /// A refresh answered. `SyncOutcome.decide` turns the result into the footer text, so Today and the Menu say
    /// the same thing: calendar done, still syncing, needs Google or failed, plus any wearable that did not refresh.
    case finished(at: Date, result: RefreshResult)
    /// The refresh call itself failed (not a part of it).
    case failed(String)
}

/// Why the screen has nothing to show.
struct TodayFailure: Equatable {
    enum Kind: Equatable { case generic, offline, accessRejected, notConfigured }
    var kind: Kind
    var message: String
}

/// What an open meeting shows under its row, made once from the answer (`hrDetails` in app.js). The raw series (tens of
/// thousands of points for a long meeting) is not kept: the chart is a `MeetingChartModel` thinned for drawing, and the
/// facts and the story are plain text, so a redraw of Today does no work proportional to the recording.
struct TodayMeetingDetail: Equatable, Sendable {
    /// nil when the answer had no heart rate points.
    var chart: MeetingChartModel?
    var zone: TimeZone
    var facts: [String]
    var story: String

    /// Pure and `nonisolated`: `TodayModel` runs it off the main actor.
    static func make(from data: MeetingHRDetail, fallbackZone: TimeZone) -> TodayMeetingDetail {
        let zone = data.timeZone.flatMap(TimeZone.init(identifier:)) ?? fallbackZone
        let hr = data.hrStress
        var facts: [String] = []
        if hr?.coverage == "ok" {
            let label = TodayLogic.hrProviderLabel(hr)
            if let mean = hr?.meanBpm { facts.append("\(label) avg \(Int(mean.rounded())) bpm") }
            if let peak = hr?.maxBpm { facts.append("\(label) peak \(Int(peak.rounded())) bpm") }
        }
        if let mean = data.stress?.meanLevel {
            facts.append("WHOOP stress \(todayLevel(mean)) avg, \(todayLevel(data.stress?.peakLevel)) peak")
        }
        let note = TodayLogic.partialNote(hr, timeZone: zone)
        if !note.isEmpty { facts.insert(note, at: 0) }
        let story = hr?.coverage == "ok" ? (hr?.story ?? "") : (data.message ?? "No heart rate for this meeting.")
        return TodayMeetingDetail(
            chart: data.series.isEmpty ? nil : MeetingChartModel(detail: data),
            zone: zone, facts: facts, story: story)
    }
}

/// Loads and holds what the Today tab shows. The screen owns one and passes `AppEnvironment` in on each call,
/// so a rebuilt API (new settings) is picked up without rebuilding the model.
@MainActor
final class TodayModel: ObservableObject {
    static let detailCacheSeconds: TimeInterval = 60

    @Published private(set) var view: ViewResponse?
    /// The day `view` is for.
    @Published private(set) var shownDay: String?
    @Published private(set) var failure: TodayFailure?
    /// A non-blocking problem (for example a failed reload while older data is on screen).
    @Published private(set) var notice: String?
    @Published private(set) var isLoading = false
    /// Set when the data on screen came from the offline cache.
    @Published private(set) var offlineSavedAt: Date?
    @Published private(set) var sync: TodaySyncState = .idle
    /// One state per meeting. A refresh marks them stale (the chart stays up while it reloads); a day or connection
    /// change drops them all.
    @Published private(set) var details: [String: MeetingDetailState<TodayMeetingDetail>] = [:]
    /// The small line shown while a meeting's detail loads, built off the main actor when the day loads.
    @Published private(set) var sparklines: [String: MeetingSparklineModel] = [:]
    /// Bumped whenever `details` is cleared or marked stale. An open meeting keys its load on id plus this, so it
    /// loads again.
    @Published private(set) var detailEpoch = 0
    @Published var selection: TodayMeetingSelection = .auto

    private var lastRefresh: Date?
    private var prefetched: Set<String> = []
    private var quietReload: Task<Void, Never>?
    /// Bumped when the details are dropped (new day, new connection). A load or a chart build that started under an
    /// older number is discarded when it finishes, so another day's or server's answer never lands.
    private var detailGeneration = 0
    /// Bumped when the details are marked stale. A load that started before it asks again once, because its answer may
    /// predate the refresh.
    private var staleGeneration = 0
    private var detailTasks: [String: Task<Void, Never>] = [:]
    private var sparklineTask: Task<Void, Never>?

    // MARK: Loading a day

    /// Paints the saved answer first, then loads fresh. Safe to cancel.
    func load(day: String, env: AppEnvironment) async {
        let api = env.api
        if shownDay != day {
            // Another day: nothing held for the last one may show or land here.
            clearDetails()
            if let cached = await api.cachedView(date: day), !Task.isCancelled, cached.value.day != nil {
                view = cached.value
                shownDay = day
                offlineSavedAt = nil
                buildSparklines(from: cached.value)
            } else if !Task.isCancelled {
                view = nil
                shownDay = nil
            }
            selection = .auto
            notice = nil
            // A failure belongs to the day it happened on: the new day shows loading, not the old error.
            failure = nil
        }
        if Task.isCancelled { return }
        isLoading = true
        defer { isLoading = false }
        let timer = CrumbTimer()
        do {
            let loaded = try await api.loadView(date: day)
            Crumbs.shared.record(.dayLoad(ms: timer.milliseconds, ok: true))
            if Task.isCancelled || TodayLogic.isStaleLoad(requested: day, selected: env.selectedDay) { return }
            guard loaded.value.day != nil else {
                fail(TodayFailure(kind: .generic, message: APIError.decoding("ViewResponse.day").message))
                return
            }
            view = loaded.value
            shownDay = day
            buildSparklines(from: loaded.value)
            failure = nil
            notice = nil
            offlineSavedAt = loaded.isFromCache ? loaded.savedAt : nil
            // Listening follows what the Worker says about these meetings, kept for when there is no network.
            if !loaded.isFromCache, !env.isDemoData, let events = loaded.value.day?.calendar?.events {
                env.choices.noteLoaded(events: events)
            }
            env.noteLoaded(loaded)
            if let today = loaded.value.today { env.noteToday(today, isFromCache: loaded.isFromCache, timeZone: loaded.value.timeZone) }
            prefetchPrevious(of: day, env: env)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { Crumbs.shared.record(.dayLoad(ms: timer.milliseconds, ok: false)) }
            if Task.isCancelled || TodayLogic.isStaleLoad(requested: day, selected: env.selectedDay) { return }
            let covered = env.report(error)
            let apiError = error as? APIError
            let kind: TodayFailure.Kind
            switch apiError {
            case .offline: kind = .offline
            case .accessRejected: kind = .accessRejected
            case .notConfigured: kind = .notConfigured
            default: kind = .generic
            }
            let message = apiError?.message ?? "Something went wrong. Try again."
            if view != nil && shownDay == day {
                // Older data stays up. Only say something the banner does not already say.
                if !covered { notice = message }
            } else {
                fail(TodayFailure(kind: kind, message: message))
            }
        }
    }

    private func fail(_ value: TodayFailure) {
        failure = value
        view = nil
        shownDay = nil
    }

    /// Warms the cache for the day before, so stepping back is instant.
    private func prefetchPrevious(of day: String, env: AppEnvironment) {
        let previous = DayMath.addDays(day, -1)
        guard !prefetched.contains(previous) else { return }
        prefetched.insert(previous)
        let api = env.api
        Task.detached(priority: .utility) {
            _ = try? await api.view(date: previous)
        }
    }

    // MARK: Refresh

    /// Pull to refresh and the Refresh button: sync, then reload. Always runs.
    func pullRefresh(day: String, env: AppEnvironment) async {
        await refresh(day: day, env: env, automatic: false)
    }

    /// Automatic refresh on open and on coming back: skipped when the last sync was under 2 minutes ago.
    func autoRefresh(day: String, env: AppEnvironment) async {
        await refresh(day: day, env: env, automatic: true)
    }

    private func refresh(day: String, env: AppEnvironment, automatic: Bool) async {
        if sync == .running { return }
        // Only this phone's own last sync counts, like the web's autoSync. The server's last sync time may be
        // someone else's, or the Mac's.
        if automatic, !TodayLogic.shouldAutoRefresh(lastSync: lastRefresh, now: Date()) { return }
        sync = .running
        do {
            let result = try await env.api.refresh(full: false)
            env.noteOnline()
            lastRefresh = Date()
            prefetched = []
            refreshDetails(.sameSources)
            sync = .finished(at: Date(), result: result)
            // The person may have moved to another day while the sync ran: reload the one they are on now.
            await load(day: env.selectedDay, env: env)
        } catch is CancellationError {
            sync = .idle
        } catch {
            let covered = env.report(error)
            sync = covered ? .idle : .failed((error as? APIError)?.message ?? "Sync failed")
        }
    }

    // MARK: Meeting heart rate

    /// Starts loading one meeting's heart rate detail unless it is loading, fresh (under 60 seconds old) and not stale.
    /// The load belongs to the model, not to the view's task, so a redraw or a changed `detailEpoch` cannot cancel it
    /// half way. Old data stays on screen while it runs.
    ///
    /// Threads: the API call and the JSON decode of the answer run off the main actor (`APIClient` methods are
    /// nonisolated async, the response cache is its own actor). The chart model is built in a detached task. Only the
    /// small state change happens here on the main actor.
    func loadDetail(id: String, zone: TimeZone, env: AppEnvironment) {
        let have = details[id] ?? MeetingDetailState()
        guard have.needsLoad(now: Date(), maxAge: Self.detailCacheSeconds) else { return }
        details[id] = have.beginLoad()
        let generation = detailGeneration
        detailTasks[id] = Task { [weak self] in
            await self?.runDetailLoad(id: id, zone: zone, env: env, generation: generation)
        }
    }

    private func runDetailLoad(id: String, zone: TimeZone, env: AppEnvironment, generation: Int) async {
        var attempt = 0
        while true {
            attempt += 1
            let staleAtStart = staleGeneration
            let timer = CrumbTimer()
            do {
                let loaded = try await env.api.loadMeetingHR(id: id, fill: false)
                Crumbs.shared.record(.detailLoad(ms: timer.milliseconds, points: loaded.value.series.count, ok: true))
                let built = await Task.detached(priority: .userInitiated) {
                    TodayMeetingDetail.make(from: loaded.value, fallbackZone: zone)
                }.value
                guard generation == detailGeneration, !Task.isCancelled else { return }
                details[id] = (details[id] ?? MeetingDetailState()).finishLoad(built, at: Date())
                if MeetingDetailState<TodayMeetingDetail>.retriesLoad(
                    refreshedWhileLoading: staleGeneration != staleAtStart, attempt: attempt)
                {
                    // A refresh landed while this was in flight: the answer may be older than it. Ask once more, still
                    // showing what we have.
                    details[id] = details[id]?.markStale().beginLoad()
                    continue
                }
            } catch is CancellationError {
                guard generation == detailGeneration else { return }
                // Not dropped by a clear: let the next visit start the load again. Never retried.
                details[id]?.loading = false
            } catch {
                if !Task.isCancelled { Crumbs.shared.record(.detailLoad(ms: timer.milliseconds, points: 0, ok: false)) }
                guard generation == detailGeneration else { return }
                if Task.isCancelled {
                    // A cancelled call can surface as another error type. Same as cancellation: no report, no retry.
                    details[id]?.loading = false
                } else if MeetingDetailState<TodayMeetingDetail>.retriesLoad(
                    refreshedWhileLoading: staleGeneration != staleAtStart, attempt: attempt)
                {
                    // A refresh landed during this load and it failed: try once more. Data stays, loading stays on, no
                    // error shown or reported for an attempt that is being retried.
                    details[id] = (details[id] ?? MeetingDetailState()).markStale().beginLoad()
                    continue
                } else {
                    env.report(error)
                    let message = (error as? APIError)?.message ?? "No heart rate for this meeting."
                    details[id] = (details[id] ?? MeetingDetailState()).failLoad(message, at: Date())
                }
            }
            break
        }
        if generation == detailGeneration { detailTasks[id] = nil }
    }

    /// Another day or another server: every held detail, and any load still running, is dropped.
    private func clearDetails() {
        detailGeneration += 1
        for task in detailTasks.values { task.cancel() }
        detailTasks = [:]
        sparklineTask?.cancel()
        sparklineTask = nil
        details = [:]
        sparklines = [:]
        detailEpoch += 1
    }

    /// The same day refreshed. Same sources: keep every chart on screen and load each again when it is next asked for.
    /// Sources changed: drop every held detail and any load in flight (as `clearDetails()`), so no chart of a source
    /// that is now off stays up, even if the reload fails. The open meeting loads again on the new epoch.
    private func refreshDetails(_ change: MeetingDetailRefresh) {
        let kept = details.compactMapValues { $0.refreshed(change) }
        if change == .sourcesChanged || kept.count < details.count {
            clearDetails()
            return
        }
        staleGeneration += 1
        details = kept
        detailEpoch += 1
    }

    /// Thins each meeting's own series (sent with the day) for the loading placeholder, off the main actor.
    private func buildSparklines(from view: ViewResponse) {
        sparklineTask?.cancel()
        let inputs = (view.day?.calendar?.events ?? []).compactMap { event -> (String, [HRPoint])? in
            guard let series = event.hrStress?.series, series.count > 1 else { return nil }
            return (event.id, series)
        }
        guard !inputs.isEmpty else {
            if !sparklines.isEmpty { sparklines = [:] }
            return
        }
        let generation = detailGeneration
        sparklineTask = Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                var models: [String: MeetingSparklineModel] = [:]
                for (id, series) in inputs { models[id] = MeetingSparklineModel(series: series) }
                return models
            }.value
            guard let self, !Task.isCancelled, generation == self.detailGeneration else { return }
            self.sparklines = built
        }
    }

    // MARK: Cross-tab reloads

    /// Another tab synced or toggled a source, or a live window ended: show fresh data without clearing the
    /// screen. Never posts `.meetspikeDataRefreshed` (Today only listens), so it cannot loop. Replaces any
    /// earlier quiet reload. `syncedElsewhere` counts as this phone's own last sync for the auto refresh throttle.
    /// `sourcesChanged` is for a display source toggle: held details are dropped, not kept.
    func reloadQuietly(env: AppEnvironment, syncedElsewhere: Bool, sourcesChanged: Bool = false) {
        if syncedElsewhere { lastRefresh = Date() }
        prefetched = []
        refreshDetails(sourcesChanged ? .sourcesChanged : .sameSources)
        quietReload?.cancel()
        quietReload = Task { [weak self] in
            guard let self else { return }
            await self.load(day: env.selectedDay, env: env)
        }
    }

    /// Called when the API is rebuilt (new settings): nothing held belongs to the old one.
    func reset() {
        view = nil
        shownDay = nil
        failure = nil
        notice = nil
        clearDetails()
        prefetched = []
        quietReload?.cancel()
        lastRefresh = nil
        sync = .idle
        selection = .auto
    }
}
