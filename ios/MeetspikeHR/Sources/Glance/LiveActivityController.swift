import ActivityKit
import Foundation
import MeetspikeHRCore
import UIKit
import WidgetKit

/// Runs the Lock Screen / Dynamic Island Live Activity while the phone is
/// listening, and keeps the widgets' shared snapshot current. PhoneModel calls
/// `refresh` whenever listening, the connection or the latest reading changes;
/// the throttles here decide what actually goes out.
@MainActor
final class LiveActivityController {
    typealias GlanceActivity = Activity<MeetspikeActivityAttributes>

    /// What PhoneModel knows right now.
    struct Input {
        var schedule: MeetingSchedule
        var listening: Bool
        var manualLive: Bool
        var connection: BluetoothStatus
        var latest: HeartRatePoint?
        var hasCurrentReading: Bool
        /// The Lock Screen heart rate setting.
        var mode: LiveActivityMode = .default
        /// Whether the activity offers "Still going" and "Ended now" right now.
        var adjust: LiveAdjust.Offer = .none
    }

    /// Called just after the listening window ends, so PhoneModel can stop.
    var onWindowEnd: (() -> Void)?

    private var activity: GlanceActivity?
    private var throttle = LiveGlanceThrottle()
    private var peaks: MeetingPeakTracker
    private var manualSince: Date?
    /// The listening window (block start, or when Go live started) of the last refresh.
    private var currentWindow: Date?
    /// The window the person swiped the activity away in; not restarted until the next one.
    private var dismissedWindow: Date?
    /// After a refused start, wait before asking again: refresh runs on every reading.
    private var nextStartAttempt = Date.distantPast
    private var endTimer: Task<Void, Never>?
    private var endTimerDate: Date?
    private var stateTask: Task<Void, Never>?
    private let store: GlanceStore
    private var saved: GlanceSnapshot?
    private var lastReload = Date.distantPast

    /// A reading this old with no newer one marks the activity as stale.
    private static let staleAfter: TimeInterval = 75
    /// How long to wait after Live Activities are off or a start fails.
    private static let startRetry: TimeInterval = 30

    init(store: GlanceStore = GlanceStore()) {
        self.store = store
        saved = store.load()
        peaks = MeetingPeakTracker(peak: saved?.lastPeak)
        // Adopt an activity left from a previous launch (or a Bluetooth
        // restoration launch); refresh ends it if not listening. Only one is
        // ever updated, so end any extras rather than leave them frozen.
        let running = GlanceActivity.activities
        if let existing = running.first { adopt(existing) }
        let extras = Array(running.dropFirst())
        if !extras.isEmpty {
            Task { for item in extras { await item.end(nil, dismissalPolicy: .immediate) } }
        }
    }

    func refresh(_ input: Input, now: Date = .now) {
        manualSince = input.manualLive ? (manualSince ?? now) : nil
        let block = input.schedule.activeBlock(at: now)
        let fresh = input.latest.map {
            !ReadingAge(readAt: $0.time, now: now, connected: input.hasCurrentReading).isStale
        } ?? false
        if input.listening, fresh, let block, let latest = input.latest, latest.time >= block.start {
            let title = input.schedule.displayedMeeting(at: now)?.title ?? block.first.title
            peaks.record(bpm: latest.bpm, title: title, blockStart: block.start, blockEnd: block.end)
        }
        updateWidgets(input, now: now)

        let status = LiveGlanceStatus(connection: input.connection, hasFreshReading: fresh)
        let windowEnd = LiveGlancePlan.windowEnd(schedule: input.schedule, now: now)
        let window = block?.start ?? manualSince
        // The setting decides first: it may keep the activity away while the phone still listens and records.
        let show = LiveActivityRule.shouldShow(
            mode: input.mode, schedule: input.schedule, listening: input.listening, manualLive: input.manualLive,
            now: now
        )
        guard input.listening else {
            endActivity()
            return
        }
        guard show, let content = LiveGlancePlan.content(
            schedule: input.schedule, listening: input.listening, manualSince: manualSince,
            bpm: fresh ? input.latest?.bpm : nil, status: status, now: now, adjust: input.adjust
        ) else {
            // Still listening, so the window-end timer stays; only the activity goes.
            scheduleEnd(at: windowEnd)
            currentWindow = window
            hideActivity()
            return
        }
        // During meetings it also ends when the last meeting in the block does, even if no reading arrives then.
        // The boundary between back-to-back meetings is not an end: the block's last end is.
        var endAt = windowEnd
        if input.mode == .duringMeetings, let meetingsEnd = LiveActivityRule.meetingsEnd(schedule: input.schedule, now: now) {
            endAt = windowEnd.map { min($0, meetingsEnd) } ?? meetingsEnd
        }
        scheduleEnd(at: endAt)
        currentWindow = window
        if let dismissedWindow, dismissedWindow != window { self.dismissedWindow = nil }
        let stale = staleDate(for: content, windowEnd: windowEnd, now: now)
        if let activity {
            guard throttle.shouldSend(content, now: now) else { return }
            throttle.markSent(content, at: now)
            Task { await activity.update(ActivityContent(state: content, staleDate: stale)) }
        } else if dismissedWindow == nil {
            start(content, staleDate: stale, now: now)
        }
    }

    private func start(_ content: LiveGlanceContent, staleDate: Date?, now: Date) {
        // iOS only starts a Live Activity from the foreground; a background
        // attempt would fail, so wait for the app to become active. The cheap
        // checks come first because this runs on every reading until it starts.
        guard now >= nextStartAttempt,
              UIApplication.shared.applicationState != .background else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            nextStartAttempt = now.addingTimeInterval(Self.startRetry)
            return
        }
        do {
            let started = try GlanceActivity.request(
                attributes: MeetspikeActivityAttributes(),
                content: ActivityContent(state: content, staleDate: staleDate),
                pushType: nil
            )
            adopt(started)
            throttle.markSent(content, at: now)
        } catch {
            // Not allowed right now (too many activities, background). Retried shortly.
            nextStartAttempt = now.addingTimeInterval(Self.startRetry)
        }
    }

    /// Watches for the person ending the activity from the Lock Screen.
    private func adopt(_ started: GlanceActivity) {
        activity = started
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in started.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                if state == .dismissed || state == .ended {
                    if self.activity?.id == started.id {
                        self.activity = nil
                        self.throttle.reset()
                        // The current window, not the one at start: an activity adopted
                        // from a previous launch has no start window of its own.
                        if state == .dismissed { self.dismissedWindow = self.currentWindow }
                    }
                    return
                }
            }
        }
    }

    private func endActivity() {
        endTimer?.cancel()
        endTimer = nil
        endTimerDate = nil
        stateTask?.cancel()
        stateTask = nil
        throttle.reset()
        dismissedWindow = nil
        currentWindow = nil
        nextStartAttempt = .distantPast
        activity = nil
        let running = GlanceActivity.activities
        guard !running.isEmpty else { return }
        Task {
            for item in running { await item.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ends the running activity because the setting says not to show it right now, while the phone keeps
    /// listening. A swipe-away stays remembered for its window.
    private func hideActivity() {
        stateTask?.cancel()
        stateTask = nil
        throttle.reset()
        activity = nil
        if let dismissedWindow, dismissedWindow != currentWindow { self.dismissedWindow = nil }
        let running = GlanceActivity.activities
        guard !running.isEmpty else { return }
        Task {
            for item in running { await item.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// While live, a missed update marks the activity stale; it never outlives the window.
    private func staleDate(for content: LiveGlanceContent, windowEnd: Date?, now: Date) -> Date? {
        let liveLimit = content.status == .live ? now.addingTimeInterval(Self.staleAfter) : nil
        switch (liveLimit, windowEnd) {
        case let (live?, end?): return min(live, end)
        case let (live?, nil): return live
        case let (nil, end?): return end
        case (nil, nil): return nil
        }
    }

    /// Ends the activity at the window end even if no reading arrives then.
    private func scheduleEnd(at date: Date?) {
        guard date != endTimerDate else { return }
        endTimer?.cancel()
        endTimerDate = date
        guard let date else {
            endTimer = nil
            return
        }
        endTimer = Task { [weak self] in
            let wait = max(0, date.timeIntervalSinceNow) + 1
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self else { return }
            self.endTimerDate = nil
            self.onWindowEnd?()
        }
    }

    private func updateWidgets(_ input: Input, now: Date) {
        var latestBPM = saved?.latestBPM
        var latestAt = saved?.latestAt
        if let latest = input.latest, latest.time >= (latestAt ?? .distantPast) {
            latestBPM = latest.bpm
            latestAt = latest.time
        }
        let snapshot = GlanceSnapshot(
            meetings: GlanceSnapshot.upcoming(input.schedule, now: now), latestBPM: latestBPM,
            latestAt: latestAt, lastPeak: peaks.peak, listening: input.listening
        )
        guard GlanceReload.needed(old: saved, new: snapshot, lastReload: lastReload, now: now) else { return }
        store.save(snapshot)
        saved = snapshot
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension PhoneModel {
    var glanceInput: LiveActivityController.Input {
        LiveActivityController.Input(
            schedule: schedule, listening: isListening(at: .now), manualLive: manualLive,
            connection: connection, latest: latest, hasCurrentReading: hasCurrentReading,
            mode: liveActivityMode,
            adjust: LiveAdjust.offer(liveAdjustTarget(), now: .now)
        )
    }
}
