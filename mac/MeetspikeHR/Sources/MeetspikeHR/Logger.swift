import AppKit
import Combine
import Foundation
import MeetspikeHRCore
import os

@MainActor
final class Logger: ObservableObject {
    struct Reading: Sendable {
        let bpm: Int
        let time: Date
    }

    @Published private(set) var connection: BluetoothStatus = .starting
    @Published private(set) var latestReading: Reading?
    @Published private(set) var readingIsFromConnection = false
    @Published private(set) var storageIssue = false
    @Published private(set) var paused: Bool
    @Published private(set) var paired: Bool
    @Published private(set) var permission: BluetoothPermission
    @Published private(set) var scan = ScanDiagnostics()
    /// A valid reading has arrived at least once. Until then the setup
    /// walkthrough opens at launch.
    @Published private(set) var setupComplete: Bool
    @Published private(set) var meetingOnly: Bool
    @Published private(set) var manualLive: Bool
    @Published private(set) var calendarAccess: MeetingCalendar.Access = .notRequested
    @Published private(set) var meetings = MeetingSchedule()
    /// Each calendar meeting with the Worker meeting it matched, for "Still going", "Ended now" and "I didn't join".
    @Published private(set) var resolved: [ResolvedMeeting] = []

    /// Beats the menu bar heart at the live heart rate.
    let heartbeat = HeartbeatClock()

    var lastUpload: Date? { replay.lastUpload }
    var uploadResult: String { replay.result }
    var lastSuccessfulUpload: Date? { replay.lastSuccessfulUpload }
    var uploadFailed: Bool { replay.failed }
    @Published private(set) var sourceDisplay: SourceDisplay?
    @Published private(set) var sourceDisplaySaving = false
    @Published private(set) var sourceDisplayError: String?

    private let bluetooth = BluetoothReader()
    private let uploader: Uploader
    let liveSync: LiveSync
    private let replay: ReplaySync
    private let calendar = MeetingCalendar()
    /// The meeting choices (listening windows follow them, offline too) and the menu buttons that make them.
    private(set) lazy var choices = MeetingChoices { [weak self] in self?.calendar.setRemote($0) }
    /// Zoom attendance, always on, whether or not the Mac is recording.
    private let attendance = AttendanceWatcher()
    private let reminders: HRReminderController
    private let defaults = UserDefaults.standard
    private let pauseStore = PauseStore()
    /// Set while paused; decides when a pause lifts for a meeting.
    private var pauseRecord: PauseRecord?
    private let store = ReadingStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("MeetspikeHR", isDirectory: true)
    )
    private var nextPrune = Date.distantPast
    private var activityTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var sourceDisplayTask: Task<Void, Never>?
    private var workspaceObservers: Set<AnyCancellable> = []
    private var sleeping = false
    private var lastRunning: Bool?
    private var lastCalendarAccess: MeetingCalendar.Access?
    // log show --last 1h --predicate 'subsystem == "com.meetspike.hr"'
    private static let appLog = os.Logger(subsystem: "com.meetspike.hr", category: "app")

    var origin: String { defaults.string(forKey: "workerOrigin") ?? "" }
    var phoneOwnsReminders: Bool { reminders.phoneOwnsReminders }
    var showsWhoop: Bool { sourceDisplay?.whoop == true }

    init() {
        let uploader = Uploader()
        self.uploader = uploader
        liveSync = LiveSync(uploader: uploader)
        replay = ReplaySync(uploader: uploader, store: store, origin: UserDefaults.standard.string(forKey: "workerOrigin") ?? "")
        reminders = HRReminderController(uploader: uploader)
        let meetingOnly = UserDefaults.standard.object(forKey: "meetingOnly") as? Bool ?? true
        self.meetingOnly = meetingOnly
        let pauseRecord = PauseStore().load(now: .now, meetingOnly: meetingOnly)
        self.pauseRecord = pauseRecord
        paused = pauseRecord != nil
        PauseStore().save(pauseRecord)
        // Go live now survives a relaunch, so a work session keeps recording until it's switched off.
        manualLive = ManualLive.restored(meetingOnly: meetingOnly, saved: UserDefaults.standard.bool(forKey: "manualLive"))
        let preferredID = UserDefaults.standard.string(forKey: "peripheralID").flatMap(UUID.init(uuidString:))
        paired = preferredID != nil
        // A remembered strap means a valid reading already arrived, so people
        // upgrading from an earlier version skip the walkthrough.
        setupComplete = UserDefaults.standard.bool(forKey: "setupComplete") || preferredID != nil
        permission = BluetoothReader.permission
        liveSync.configure(origin: origin)
        let canListen = { [weak self] in self?.canListen(at: .now) ?? false }
        heartbeat.bpm = { [weak self] in self?.liveBPM }
        bluetooth.canListen = canListen
        liveSync.canUpload = canListen
        replay.canUpload = canListen
        replay.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &workspaceObservers)
        bluetooth.preferredID = preferredID
        bluetooth.onPaired = { [weak self] id in
            self?.defaults.set(id.uuidString, forKey: "peripheralID")
            self?.paired = true
        }
        bluetooth.onStatus = { [weak self] in self?.setConnection($0) }
        bluetooth.onPermission = { [weak self] value in
            if self?.permission != value { self?.permission = value }
        }
        bluetooth.onScan = { [weak self] in self?.scan = $0 }

        // One consumer keeps notification order even if SQLite is busy with a
        // snapshot. The stream queues readings until the store can accept them.
        let (readings, input) = AsyncStream<Reading>.makeStream()
        bluetooth.onReading = { [weak self] bpm, time in
            guard self?.canListen(at: time) == true else { return }
            let reading = Reading(bpm: bpm, time: time)
            self?.latestReading = reading
            self?.liveSync.record(bpm: bpm, at: time)
            if let self, !self.readingIsFromConnection { self.readingIsFromConnection = true }
            input.yield(reading)
            if let self, !self.setupComplete {
                self.setupComplete = true
                self.defaults.set(true, forKey: "setupComplete")
                // First-run setup listens regardless of the schedule; return to it now.
                self.updateBluetooth()
            }
        }
        Task { [weak self] in
            for await reading in readings {
                guard let self else { return }
                await self.persist(reading)
            }
        }

        let notifications = NSWorkspace.shared.notificationCenter
        notifications.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setSleeping(true) }
            .store(in: &workspaceObservers)
        notifications.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.setSleeping(false) }
            .store(in: &workspaceObservers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.calendar.refresh() }
            .store(in: &workspaceObservers)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Self.appLog.notice(
            "Meetspike HR \(version, privacy: .public) started: meetingOnly=\(self.meetingOnly, privacy: .public) paused=\(self.paused, privacy: .public) setupComplete=\(self.setupComplete, privacy: .public) strapRemembered=\(self.paired, privacy: .public) workerConfigured=\(!self.origin.isEmpty, privacy: .public)"
        )
        calendar.onChange = { [weak self] in self?.calendarChanged() }
        // Saved choices first, so the very first window already follows them with no network.
        choices.start()
        calendar.refresh()
        attendance.start()
        Task { [weak self] in await self?.choices.refresh(force: true) }
        refreshSourceDisplay()

        if Walkthrough.showsAtLaunch(setupComplete: setupComplete) {
            Task { [weak self] in
                guard let self else { return }
                WalkthroughWindow.show(logger: self)
            }
        }

        Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                // Before the sleep check: a sample while asleep is what keeps a sleep from counting as watching.
                self.attendance.sample()
                guard !self.sleeping else { continue }
                self.resumeForMeetingIfNeeded(now: .now)
                self.refreshSourceDisplay()
                Task { [weak self] in await self?.choices.refresh() }
            }
        }
    }

    func snapshot(now: Date, includeReading: Bool = true) -> HRSnapshot {
        HRSnapshot(
            status: connection, permission: permission, scan: scan,
            latestBPM: includeReading ? latestReading?.bpm : nil,
            latestReadingAt: includeReading ? latestReading?.time : nil,
            readingIsFromConnection: readingIsFromConnection, setupComplete: setupComplete,
            lastSuccessfulUpload: lastSuccessfulUpload, uploadProblem: uploadFailed ? uploadResult : nil, now: now
        )
    }

    func refreshSourceDisplay() {
        if sourceDisplayTask == nil { requestSourceDisplay() }
    }

    func setSourceDisplay(_ source: SourceDisplay.Source, enabled: Bool) {
        guard sourceDisplay != nil, !sourceDisplaySaving else { return }
        sourceDisplayTask?.cancel()
        requestSourceDisplay(update: (source, enabled))
    }

    private func requestSourceDisplay(update: (SourceDisplay.Source, Bool)? = nil) {
        guard let destination = Destination(origin) else { return }
        sourceDisplaySaving = update != nil
        sourceDisplayTask = Task {
            defer {
                if !Task.isCancelled {
                    sourceDisplaySaving = false
                    sourceDisplayTask = nil
                }
            }
            do {
                guard let credentials = try CredentialStore.load() else {
                    sourceDisplay = nil
                    sourceDisplayError = "Save your Meetspike connection settings first."
                    return
                }
                let display = try await uploader.sourceDisplay(at: destination, credentials: credentials, update: update)
                try Task.checkCancellation()
                if update != nil || sourceDisplay == nil { sourceDisplayError = nil }
                if sourceDisplay != display { sourceDisplay = display }
            } catch {
                guard !Task.isCancelled else { return }
                if update == nil {
                    sourceDisplay = nil
                    sourceDisplayError = "Could not load display settings. Check your Meetspike connection and Access credentials."
                } else {
                    sourceDisplayError = "Could not save display setting."
                }
            }
        }
    }

    func togglePause() {
        setPaused(!paused, now: .now)
    }

    private func setPaused(_ value: Bool, now: Date) {
        // A pause set inside a meeting block holds for that block only.
        setPauseRecord(value ? PausePolicy.record(at: now, meetingOnly: meetingOnly, schedule: meetings) : nil)
        paused = value
        updateBluetooth()
        if !paused {
            replay.uploadSoon()
            tick(now: now)
        }
    }

    private func setPauseRecord(_ record: PauseRecord?) {
        guard record != pauseRecord else { return }
        pauseRecord = record
        pauseStore.save(record)
    }

    /// When the pause will lift for a meeting, or nil when it won't on its own.
    func pauseResumesAt(now: Date) -> Date? {
        PausePolicy.nextAutoResume(
            record: pauseRecord, meetingOnly: meetingOnly, calendarAvailable: calendarAccess == .allowed,
            schedule: meetings, now: now
        )
    }

    /// Pause never silently eats a meeting: resume when a block starts that
    /// the pause was not set inside of.
    private func resumeForMeetingIfNeeded(now: Date) {
        guard !sleeping, PausePolicy.shouldAutoResume(
            record: pauseRecord, meetingOnly: meetingOnly, schedule: meetings, now: now
        ), let block = meetings.activeBlock(at: now) else { return }
        let title = meetings.displayedMeeting(at: now)?.title ?? block.first.title
        Self.appLog.notice("Pause lifted for a meeting block")
        // The resume is for this meeting only. Go live would keep recording
        // after the block ends, so it goes off; the user can switch it back on.
        if manualLive { setManualLive(false) }
        setPaused(false, now: now)
        reminders.notifyResumed(meetingTitle: title)
    }

    /// The BPM the menu bar heart beats at, or nil when the reading isn't live.
    private var liveBPM: Int? {
        let icon = MenuBarIcon(snapshot(now: .now), showReading: showsWhoop)
        return icon.style == .live ? latestReading?.bpm : nil
    }

    func setMeetingOnly(_ enabled: Bool) {
        meetingOnly = enabled
        defaults.set(enabled, forKey: "meetingOnly")
        // A pause set with continuous capture doesn't lift just because
        // meeting-only came on mid-block: it holds for that block.
        setPauseRecord(PausePolicy.afterMeetingOnlyChange(pauseRecord, meetingOnly: enabled, schedule: meetings, now: .now))
        let live = ManualLive.afterMeetingOnlyChange(meetingOnly: enabled, current: manualLive)
        // Always write it, so a stale saved Go live can't come back on the next launch.
        setManualLive(live)
        calendar.refresh()
    }

    func setManualLive(_ enabled: Bool) {
        manualLive = enabled
        defaults.set(enabled, forKey: "manualLive")
        updateBluetooth()
    }

    func requestCalendarAccess() {
        Task { await calendar.requestAccess() }
    }

    /// Saves a broadcaster the user picked as the strap and connects to it.
    func useBroadcaster(_ id: UUID) {
        defaults.set(id.uuidString, forKey: "peripheralID")
        paired = true
        bluetooth.use(id)
    }

    func forgetDevice() {
        defaults.removeObject(forKey: "peripheralID")
        paired = false
        bluetooth.forgetDevice()
    }

    func save(destination: Destination, credentials: Credentials) throws {
        try CredentialStore.save(credentials)
        defaults.set(destination.origin.absoluteString, forKey: "workerOrigin")
        sourceDisplayTask?.cancel()
        sourceDisplayTask = nil
        sourceDisplay = nil
        sourceDisplayError = nil
        refreshSourceDisplay()
        liveSync.configure(origin: origin)
        replay.configure(origin: origin)
        reminders.reset()
        tick(now: .now)
    }

    private func setSleeping(_ value: Bool) {
        sleeping = value
        if value { updateBluetooth() }
        else {
            calendar.refresh()
            Task { [weak self] in await self?.choices.refresh(force: true) }
        }
    }

    /// The Worker's meeting behind the one the menu shows, or nil when it did not match exactly one.
    func liveTarget(at now: Date) -> LiveAdjustTarget? {
        LiveAdjust.target(displayed: meetings.displayedMeeting(at: now), resolved: resolved)
    }

    private func calendarChanged() {
        calendarAccess = calendar.access
        meetings = calendar.schedule
        resolved = calendar.resolved
        if lastCalendarAccess != calendarAccess {
            lastCalendarAccess = calendarAccess
            Self.appLog.notice("Calendar access: \(String(describing: self.calendarAccess), privacy: .public)")
        }
        if let pauseRecord { setPauseRecord(PausePolicy.anchored(pauseRecord, schedule: meetings)) }
        // The calendar refreshes at each block boundary, so a block start lands
        // here. Not while asleep, same as the 15 s loop; wake refreshes again.
        resumeForMeetingIfNeeded(now: .now)
        updateBluetooth()
        if !sleeping { prune(now: .now) }
    }

    /// Meeting-only mode is on but Calendar access was denied, so the app
    /// cannot see meetings and listens continuously instead.
    var calendarAccessNeeded: Bool { meetingOnly && calendarAccess == .denied }
    var canToggleManualLive: Bool {
        ManualLive.canToggle(isOn: manualLive, paused: paused, calendarAccessNeeded: calendarAccessNeeded)
    }

    private func canListen(at now: Date) -> Bool {
        ListenGate.shouldListen(
            paused: paused, sleeping: sleeping, meetingOnly: meetingOnly, calendarDenied: calendarAccess == .denied,
            manualLive: manualLive, setupComplete: setupComplete, inMeetingWindow: meetings.activeBlock(at: now) != nil
        )
    }

    private func updateBluetooth() {
        let running = canListen(at: .now)
        if lastRunning != running {
            lastRunning = running
            let reason = paused ? "paused" : sleeping ? "sleeping" : manualLive ? "go live" : !meetingOnly ? "continuous"
                : calendarAccessNeeded ? "calendar access needed" : !setupComplete ? "first-run setup"
                : running ? "meeting window" : "outside meeting"
            Self.appLog.notice("Listening \(running ? "on" : "off", privacy: .public) (\(reason, privacy: .public))")
        }
        if !running {
            activityTask?.cancel()
            activityTask = nil
            setConnection(paused ? .paused : sleeping ? .sleeping : .outsideMeeting)
        } else if activityTask == nil {
            setConnection(.starting)
            activityTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.tick(now: .now)
                }
            }
        }
        liveSync.setRunning(running)
        replay.setRunning(running)
        bluetooth.setRunning(running)
        if running { tick(now: .now) }
    }

    private func tick(now: Date) {
        guard canListen(at: now) else { return }
        let closingAt = meetingOnly && !manualLive ? meetings.activeBlock(at: now)?.end : nil
        liveSync.tick(now: now)
        replay.tick(now: now, closingAt: closingAt)
        // Runs only while listening (canListen implies not paused or asleep).
        reminders.tick(
            now: now, lastReadingAt: latestReading?.time, origin: origin,
            meetingOnlyMeetings: meetingOnly && !manualLive ? meetings.meetings : nil
        )
        prune(now: now)
    }

    private func prune(now: Date) {
        guard maintenanceTask == nil, now >= nextPrune else { return }
        nextPrune = now.addingTimeInterval(3_600)
        maintenanceTask = Task {
            defer { maintenanceTask = nil }
            do {
                try await store.prune(now: now)
                storageIssue = false
            } catch {
                storageIssue = true
            }
        }
    }

    func readings(in window: ClosedRange<Date>) async throws -> [HeartRatePoint] {
        try await store.readings(from: window.lowerBound, through: window.upperBound)
    }

    private func setConnection(_ status: BluetoothStatus) {
        connection = status
        if status != .connected, readingIsFromConnection { readingIsFromConnection = false }
    }

    private func persist(_ reading: Reading) async {
        while !Task.isCancelled {
            do {
                try await store.record(bpm: reading.bpm, at: reading.time)
                if storageIssue { storageIssue = false }
                return
            } catch {
                storageIssue = true
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
