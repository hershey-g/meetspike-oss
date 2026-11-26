import Combine
import Foundation
import MeetspikeHRCore
import UIKit
import UserNotifications

@MainActor
final class PhoneModel: ObservableObject {
    @Published private(set) var connection: BluetoothStatus = .outsideMeeting
    @Published private(set) var latest: HeartRatePoint?
    @Published private(set) var hasCurrentReading = false
    @Published private(set) var recent: [HeartRatePoint] = []
    @Published private(set) var schedule = MeetingSchedule()
    @Published private(set) var calendarAccess: MeetingCalendar.Access = .notRequested
    /// Apple Calendar calendars on this iPhone, and which of them start listening (saved on this iPhone).
    @Published private(set) var deviceCalendars: [DeviceCalendar] = []
    @Published private(set) var listening = ListeningCalendarChoice.load()
    @Published private(set) var reminderAccess: UNAuthorizationStatus = .notDetermined
    @Published private(set) var manualLive = false
    /// When the Lock Screen heart rate (Live Activity) may show. Saved on this iPhone; default During meetings.
    @Published private(set) var liveActivityMode = LiveActivityMode.stored(
        UserDefaults.standard.string(forKey: LiveActivityMode.storageKey))
    /// Until when the Worker confirmed this phone as reminder owner. Nil means
    /// the Mac sends reminders and this phone schedules none.
    @Published private(set) var ownerUntil: Date?
    /// The last check-in reply said the Worker will push the broadcast reminders to this phone (and only when no heart
    /// rate is coming in). Saved, so the phone does not schedule its own for a moment after a relaunch.
    @Published private(set) var pushConfirmed: Bool
    @Published private(set) var storageIssue = false
    @Published private(set) var scan = ScanDiagnostics()
    @Published private(set) var rememberedStrap: Bool
    @Published private(set) var bluetoothPermission: BluetoothPermission
    @Published private(set) var onboardingComplete: Bool
    /// Set only by demo launch arguments in Debug builds, for screenshots.
    @Published private(set) var demoSync: SyncDisplay?
    /// A newer TestFlight build to offer, or nil.
    @Published private(set) var availableUpdate: Int?
    /// Counts up each time sync settings are saved, so `AppEnvironment` rebuilds its API from them.
    @Published private(set) var settingsRevision = 0
    /// The usual resting heart rate (`usual.restingHr` from the Worker's day view), saved on the phone so the
    /// Live tab can compare against it offline and before Today loads. Nil when none is known or it is too old.
    @Published private(set) var restingHr: Int?
    private static let restingKey = "usualRestingHr"
    private static let restingAtKey = "usualRestingHrAt"
    private var updateCheckedAt = Date.distantPast
    private var updateCheckInFlight = false
    private(set) var isDemo = false
    private var demoOrigin: String?

    let liveSync: LiveSync
    let replay: ReplaySync
    private let uploader: Uploader
    private var ownerTask: Task<Void, Never>?
    /// Another check-in was asked for while one was in flight.
    private var ownerRecheck = false
    private var ownerCheckedAt = Date.distantPast
    private static let coveredSentKey = "reminderCoveredSent"
    /// Check in again once the confirmation has less than this left.
    private static let ownerRefresh: TimeInterval = 6.5 * 86_400
    private static let ownerUntilKey = "reminderOwnerUntil"
    private static let pushConfirmedKey = "reminderPushConfirmed"
    /// The device token iOS last handed over, as "<environment>:<hex>". Kept so a check-in at launch, before iOS hands
    /// it over again, still sends it (the Worker drops the device on an active check-in without one).
    private static let pushTokenKey = "reminderPushToken"
    /// The token the last successful check-in carried, so a changed token checks in even mid-flight.
    private static let pushTokenSentKey = "reminderPushTokenSent"
    private let reader = BluetoothReader()
    private lazy var calendar = MeetingCalendar()
    private lazy var activityTicker = ActivityTicker { [weak self] in self?.tickActivity() }
    private var isForeground = false
    /// For the crash crumbs: listening start and stop are logged when it changes, not on every tick.
    private var lastListening = false
    private let reminders = BroadcastReminders()
    /// Lock Screen Live Activity and widget data.
    let glance = LiveActivityController()
    private let store = ReadingStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("MeetspikeHR", isDirectory: true)
    )
    private var nextPrune = Date.distantPast
    private var maintenanceTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var hasLoadedHistory = false
    private let defaults = UserDefaults.standard

    var origin: String { demoOrigin ?? defaults.string(forKey: "workerOrigin") ?? "" }
    var syncConfigured: Bool { Destination(origin) != nil }

    init() {
        let uploader = Uploader()
        self.uploader = uploader
        ownerUntil = UserDefaults.standard.object(forKey: Self.ownerUntilKey) as? Date
        pushConfirmed = UserDefaults.standard.bool(forKey: Self.pushConfirmedKey)
        liveSync = LiveSync(uploader: uploader)
        replay = ReplaySync(uploader: uploader, store: store, origin: UserDefaults.standard.string(forKey: "workerOrigin") ?? "")
        let preferredID = UserDefaults.standard.string(forKey: "peripheralID").flatMap(UUID.init(uuidString:))
        rememberedStrap = preferredID != nil
        bluetoothPermission = BluetoothReader.permission
        onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        restingHr = RestingBaseline.current(
            saved: UserDefaults.standard.object(forKey: Self.restingKey) as? Int,
            savedAt: UserDefaults.standard.object(forKey: Self.restingAtKey) as? Date, now: .now
        )
        #if DEBUG
        if let scenario = DemoScenario.current {
            applyDemo(scenario)
            return
        }
        #endif
        reader.preferredID = preferredID
        reader.setDiscoveryAllowed(false)
        // Tell the Worker right away when the meetings this phone covers change.
        reminders.onCoveredChange = { [weak self] in self?.checkInReminderOwner() }
        liveSync.configure(origin: origin)

        let canListen = { [weak self] in self?.canListen(at: .now) ?? false }
        reader.canListen = canListen
        liveSync.canUpload = canListen
        replay.canUpload = canListen
        reader.onStatus = { [weak self] in self?.setConnection($0) }
        reader.onScan = { [weak self] in self?.scan = $0 }
        reader.onPaired = { [weak self] in self?.rememberStrap($0) }
        reader.onPermission = { [weak self] value in
            if self?.bluetoothPermission != value { self?.bluetoothPermission = value }
        }
        calendar.onChange = { [weak self] in self?.calendarChanged() }
        glance.onWindowEnd = { [weak self] in self?.updateActivity() }

        // The person's meeting choices as last saved (and edits not yet sent), so listening follows them from the first
        // moment, even at a background launch with no network. Without any, listening follows the calendar.
        calendar.setRemote(ListeningOverrides.current())

        let (readings, input) = AsyncStream<HeartRatePoint>.makeStream()
        reader.onReading = { [weak self] bpm, now in
            guard let self, self.canListen(at: now) else { return }
            let point = HeartRatePoint(bpm: bpm, at: now)
            self.latest = point
            if !self.hasCurrentReading { self.hasCurrentReading = true }
            self.recent.removeAll { $0.time < now.addingTimeInterval(-900) || $0.id == point.id }
            self.recent.append(point)
            input.yield(point)
            self.reminders.heartRateArrived(at: now)
            self.liveSync.record(bpm: bpm, at: now)
            self.liveSync.tick(now: now)
            self.glance.refresh(self.glanceInput, now: now)
        }
        Task { [weak self] in
            for await point in readings {
                guard let self else { return }
                await self.persist(point)
                self.tickReplay(now: .now)
                self.prune(now: .now)
            }
        }
    }

    func becameActive() {
        #if DEBUG
        if isDemo { showDemoGlance() }
        #endif
        guard !isDemo else { return }
        isForeground = true
        bluetoothPermission = BluetoothReader.permission
        calendar.refresh()
        reader.setDiscoveryAllowed(true)
        loadHistory()
        prune(now: .now)
        registerForPush()
        checkInReminderOwner()
        checkForUpdate()
        glance.refresh(glanceInput)
    }

    /// Asks the Worker for the newest TestFlight build, at most every 30 minutes
    /// when the app becomes active. A failed check keeps the last answer and
    /// does not start the 30-minute wait, so the next activation retries.
    /// force skips the wait (used right after saving new settings).
    func checkForUpdate(force: Bool = false) {
        guard !isDemo, !updateCheckInFlight, force || Date.now.timeIntervalSince(updateCheckedAt) > 1_800,
              let destination = Destination(origin), let credentials = try? CredentialStore.load(),
              Credentials.isHeaderValue(credentials.ingestSecret) else { return }
        updateCheckInFlight = true
        Task {
            defer { updateCheckInFlight = false }
            guard let latest = try? await uploader.latestIOSBuild(at: destination, credentials: credentials) else { return }
            updateCheckedAt = .now
            availableUpdate = AppUpdate.availableBuild(
                current: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, latest: latest
            )
        }
    }

    func enteredBackground() {
        guard !isDemo else { return }
        isForeground = false
        activityTicker.setRunning(false)
        reader.setDiscoveryAllowed(false)
    }

    func restoreBluetooth() {
        guard !isDemo else { return }
        calendar.refresh()
        reader.restore()
        registerForPush()
        checkInReminderOwner()
    }

    func requestCalendar() async {
        guard !isDemo else { return }
        await calendar.requestAccess()
    }

    /// Shows the iOS Bluetooth prompt now. The answer arrives through onPermission.
    func requestBluetooth() {
        guard !isDemo else { return }
        reader.requestPermission()
    }

    func finishOnboarding() {
        onboardingComplete = true
        if !isDemo { defaults.set(true, forKey: "onboardingComplete") }
        updateActivity()
        checkInReminderOwner(force: true)
    }

    func isListening(at now: Date) -> Bool { canListen(at: now) }

    // MARK: Resting heart rate

    /// True when the saved resting value is missing or old enough to ask the Worker again.
    var restingNeedsRefresh: Bool {
        guard !isDemo else { return false }
        return RestingBaseline.needsRefresh(savedAt: restingSavedAt, now: .now)
    }

    /// When the saved resting value was saved. A date after now (the clock was ahead when it was saved) counts as
    /// unknown, so the Worker is asked again and its answer replaces the value instead of losing to it until then.
    private var restingSavedAt: Date? {
        (defaults.object(forKey: Self.restingAtKey) as? Date).flatMap { $0 <= .now ? $0 : nil }
    }

    /// Records `usual.restingHr` from a day view answer saved at `savedAt`. An answer without a usable value
    /// keeps the last known one (it expires on its own), and an older copy never replaces a newer one.
    func noteUsualResting(_ usual: Double?, savedAt: Date) {
        guard !isDemo, let value = RestingBaseline.value(fromUsual: usual),
              RestingBaseline.shouldReplace(savedAt: restingSavedAt, with: savedAt)
        else { return }
        defaults.set(value, forKey: Self.restingKey)
        defaults.set(savedAt, forKey: Self.restingAtKey)
        let current = RestingBaseline.current(saved: value, savedAt: savedAt, now: .now)
        if restingHr != current { restingHr = current }
    }

    /// Stored readings for a window, for meeting stats longer than the 15 minutes held in memory. Empty when
    /// storage is unavailable.
    func storedReadings(from start: Date, through end: Date) async -> [HeartRatePoint] {
        if isDemo { return recent.filter { $0.time >= start && $0.time <= end } }
        return (try? await store.readings(from: start, through: end)) ?? []
    }

    func requestReminders() async {
        guard !isDemo else { return }
        await reminders.requestPermission()
        reminderAccess = await reminders.authorization()
        registerForPush()
        checkInReminderOwner(force: true)
    }

    func setManualLive(_ value: Bool) {
        manualLive = value
        updateActivity()
    }

    /// Saves the Lock Screen heart rate choice and applies it at once: a running activity that should not show ends,
    /// and one that should starts only while the app is in the foreground (the controller checks).
    func setLiveActivityMode(_ mode: LiveActivityMode) {
        guard mode != liveActivityMode else { return }
        liveActivityMode = mode
        guard !isDemo else { return }
        defaults.set(mode.rawValue, forKey: LiveActivityMode.storageKey)
        glance.refresh(glanceInput)
    }

    func useBroadcaster(_ id: UUID) {
        guard !isDemo else { return }
        rememberStrap(id)
        reader.use(id)
    }

    private func rememberStrap(_ id: UUID) {
        defaults.set(id.uuidString, forKey: "peripheralID")
        rememberedStrap = true
    }

    func forgetStrap() {
        guard !isDemo else { return }
        defaults.removeObject(forKey: "peripheralID")
        rememberedStrap = false
        reader.forgetDevice()
    }

    func save(destination: Destination, credentials: Credentials) throws {
        guard !isDemo else { return }
        try CredentialStore.save(credentials)
        defaults.set(destination.origin.absoluteString, forKey: "workerOrigin")
        settingsRevision += 1
        liveSync.configure(origin: origin)
        replay.configure(origin: origin)
        updateActivity()
        checkInReminderOwner(force: true)
        checkForUpdate(force: true)
    }

    // MARK: Pairing and connection test

    /// Whether Keychain holds an ingest secret and an Access token. Never the values.
    func savedSecrets() -> (ingest: Bool, access: Bool) {
        #if DEBUG
        if isDemo { return (true, UserDefaults.standard.string(forKey: "demoSettingsState") != "noAccess") }
        #endif
        guard let saved = try? CredentialStore.load() else { return (false, false) }
        return (Credentials.isHeaderValue(saved.ingestSecret), saved.accessID != nil && saved.accessSecret != nil)
    }

    /// Calls the Worker with the saved credentials, the same way uploads do. Nil before sync is set up.
    func testConnection() async -> ConnectionCheck? {
        #if DEBUG
        if isDemo {
            try? await Task.sleep(for: .milliseconds(700))
            return .connected
        }
        #endif
        guard let destination = Destination(origin), let credentials = try? CredentialStore.load(),
              Credentials.isHeaderValue(credentials.ingestSecret) else { return nil }
        return await uploader.testConnection(at: destination, credentials: credentials)
    }

    /// Trades a setup code for the sync keys, saves them in Keychain, then tests them.
    func pair(_ link: PairingLink) async throws -> ConnectionCheck {
        #if DEBUG
        if isDemo {
            try? await Task.sleep(for: .milliseconds(700))
            return .connected
        }
        #endif
        guard let destination = link.destination else { throw PairingError.unexpected(nil) }
        // Read Keychain before spending the code: a read error must not look like "nothing saved"
        // and quietly drop a saved Access token.
        let saved: Credentials?
        do { saved = try CredentialStore.load() } catch { throw PairingKeychainError(stage: .read) }
        let reply = try await uploader.redeemPairing(link)
        let sameOrigin = Destination(origin)?.origin.absoluteString == link.origin
        let credentials = reply.credentials(keeping: saved, sameOrigin: sameOrigin)
        do {
            try save(destination: destination, credentials: credentials)
        } catch {
            throw PairingKeychainError(stage: .save)
        }
        return await uploader.testConnection(at: destination, credentials: credentials)
    }

    /// Clears the saved Access client ID and secret and keeps the ingest secret.
    func removeAccessToken() throws {
        guard !isDemo else { return }
        guard var saved = try CredentialStore.load() else { return }
        saved.accessID = nil
        saved.accessSecret = nil
        if let destination = Destination(origin) {
            try save(destination: destination, credentials: saved)
        } else {
            try CredentialStore.save(saved)
            settingsRevision += 1
        }
    }

    /// Turn one Apple Calendar calendar on or off for listening. The meeting window is rebuilt at once.
    func setListening(_ id: String, included: Bool) {
        guard !isDemo else {
            listening.set(id, included: included)
            return
        }
        calendar.listening = listening.setting(id, included: included)
        listening = calendar.listening
    }

    private func calendarChanged() {
        guard !isDemo else { return }
        calendarAccess = calendar.access
        schedule = calendar.schedule
        if deviceCalendars != calendar.calendars { deviceCalendars = calendar.calendars }
        if listening != calendar.listening { listening = calendar.listening }
        updateReminders()
        updateActivity()
    }

    /// The Worker's meetings with the person's choices laid over them (and edits not yet sent). Listening windows
    /// move to the effective times and skip meetings left out. Reminders keep the calendar's starts.
    func setRemoteMeetings(_ meetings: [RemoteMeeting]) {
        guard !isDemo else { return }
        calendar.setRemote(meetings)
    }

    /// The Worker meeting behind the meeting shown now, for "Still going" and "Ended now". Nil when it is not known
    /// which one it is.
    func liveAdjustTarget(at now: Date = .now) -> LiveAdjustTarget? {
        guard !isDemo else { return DemoAdjust.target(schedule: schedule, now: now) }
        return LiveAdjust.target(displayed: schedule.displayedMeeting(at: now), resolved: calendar.resolved)
    }

    /// True while this phone sends the broadcast reminders.
    var ownsReminders: Bool { ownerUntil.map { $0 > .now } ?? false }

    /// True while the Worker pushes the reminders to this phone instead of the phone scheduling them. Only while the
    /// check-in is still good: once it lapses the Mac takes over and this is false again.
    var pushActive: Bool { pushConfirmed && ownsReminders }

    private func updateReminders() {
        reminders.update(for: calendar.reminderSchedule, ownerUntil: ownerUntil, pushActive: pushActive)
    }

    // MARK: Push

    private static var pushEnvironment: PushRegistration.Environment {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }

    /// The token to send with a check-in, from the saved copy. Nil before iOS has ever handed one over, or when it was
    /// handed over for the other environment (a debug build over a TestFlight one).
    private var pushRegistration: PushRegistration? {
        guard let saved = defaults.string(forKey: Self.pushTokenKey) else { return nil }
        let parts = saved.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == Self.pushEnvironment.rawValue else { return nil }
        return PushRegistration(hex: parts[1], environment: Self.pushEnvironment)
    }

    /// Asks iOS for the push token when notifications are allowed. Cheap to repeat, and iOS may hand over a new token.
    private func registerForPush() {
        guard !isDemo else { return }
        Task {
            let access = await reminders.authorization()
            guard access == .authorized || access == .provisional else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// iOS handed over the token. A changed one checks in at once.
    func pushTokenArrived(_ token: Data) {
        guard !isDemo else { return }
        let registration = PushRegistration(token: token, environment: Self.pushEnvironment)
        let saved = "\(registration.environment.rawValue):\(registration.token)"
        guard defaults.string(forKey: Self.pushTokenKey) != saved else { return }
        defaults.set(saved, forKey: Self.pushTokenKey)
        checkInReminderOwner(force: true)
    }

    /// iOS could not register. The saved token stays, and local reminders stay unless the Worker says it pushes.
    func pushRegistrationFailed() {}

    private func setPushConfirmed(_ value: Bool) {
        guard pushConfirmed != value else { return }
        pushConfirmed = value
        defaults.set(value, forKey: Self.pushConfirmedKey)
    }

    /// The phone owns reminders while it is signed in, past onboarding and
    /// allowed to notify. It tells the Worker which meeting starts it
    /// scheduled a reminder for, and the Mac stays quiet about those only. It
    /// checks in again whenever that set changes. Otherwise it steps down and
    /// schedules nothing. Without a network answer it keeps its last
    /// confirmation, which expires on its own.
    func checkInReminderOwner(force: Bool = false) {
        guard !isDemo else { return }
        guard ownerTask == nil else {
            ownerRecheck = true
            return
        }
        ownerTask = Task {
            defer {
                ownerTask = nil
                if ownerRecheck {
                    ownerRecheck = false
                    checkInReminderOwner()
                }
            }
            let access = await reminders.authorization()
            reminderAccess = access
            let active = onboardingComplete && (access == .authorized || access == .provisional)
            guard let destination = Destination(origin), let credentials = try? CredentialStore.load(),
                  Credentials.isHeaderValue(credentials.ingestSecret) else {
                defaults.removeObject(forKey: Self.pushTokenSentKey)
                setOwnerUntil(nil)
                return
            }
            let now = Date.now
            let covered = active ? reminders.covered : []
            // Taken now, with the covered starts: a token that arrives while this check-in is out is not in it, so the
            // check-in after this one (ownerRecheck) sees it as changed.
            let registration = active ? pushRegistration : nil
            let tokenChanged = registration != nil && registration?.token != defaults.string(forKey: Self.pushTokenSentKey)
            // A saved token the Worker did not take: try again on the hourly cadence, not at every activation.
            let pushRetry = registration != nil && !pushConfirmed
            let sentCovered = defaults.array(forKey: Self.coveredSentKey) as? [Double] ?? []
            let coveredChanged = active && covered.map(\.timeIntervalSince1970) != sentCovered
            let hourly = now.timeIntervalSince(ownerCheckedAt) > 3_600 && (
                // Step down once per launch too: a reinstall forgets a check-in the Worker still holds.
                active ? (pushRetry || (ownerUntil.map { $0.timeIntervalSince(now) < Self.ownerRefresh } ?? true))
                    : ownerUntil != nil || ownerCheckedAt == .distantPast
            )
            let due = force || coveredChanged || tokenChanged || hourly
            guard due else {
                if !active { setOwnerUntil(nil) } else { updateReminders() }
                return
            }
            ownerCheckedAt = now
            do {
                let reply = try await uploader.checkInReminderOwner(
                    active: active, covered: covered, push: registration, to: destination, credentials: credentials
                )
                defaults.set(covered.map(\.timeIntervalSince1970), forKey: Self.coveredSentKey)
                if let registration { defaults.set(registration.token, forKey: Self.pushTokenSentKey) }
                else { defaults.removeObject(forKey: Self.pushTokenSentKey) }
                let owns = active && reply.owner == .phone
                setOwnerUntil(owns ? reply.ownerUntil : nil, push: owns && registration != nil && reply.push)
            } catch {
                // A failed check keeps the last state, push included. Stepping down never waits for the network.
                if !active { setOwnerUntil(nil) } else { updateReminders() }
            }
        }
    }

    /// `push` is the reply's word. Without a check-in (nil) it is always false.
    private func setOwnerUntil(_ value: Date?, push: Bool = false) {
        if ownerUntil != value {
            ownerUntil = value
            if let value { defaults.set(value, forKey: Self.ownerUntilKey) } else { defaults.removeObject(forKey: Self.ownerUntilKey) }
        }
        setPushConfirmed(value != nil && push)
        updateReminders()
    }

    private func canListen(at now: Date) -> Bool {
        ListenGate.shouldListenOnPhone(
            onboardingComplete: onboardingComplete, manualLive: manualLive,
            inMeetingWindow: schedule.activeBlock(at: now) != nil
        )
    }

    private func updateActivity() {
        guard !isDemo else { return }
        let now = Date.now
        let running = canListen(at: now)
        if lastListening != running {
            lastListening = running
            Crumbs.shared.record(.listen(on: running))
        }
        activityTicker.setRunning(running && isForeground)
        if !running { setConnection(.outsideMeeting) }
        else if connection == .outsideMeeting { setConnection(.starting) }
        liveSync.setRunning(running)
        replay.setRunning(running)
        reader.setRunning(running)
        if running {
            liveSync.tick(now: now)
            tickReplay(now: now)
        }
        glance.refresh(glanceInput, now: now)
    }

    private func tickActivity() {
        let now = Date.now
        guard isForeground, canListen(at: now) else {
            updateActivity()
            return
        }
        liveSync.tick(now: now)
        tickReplay(now: now)
    }

    private func tickReplay(now: Date) {
        guard canListen(at: now) else { return }
        replay.tick(now: now, closingAt: manualLive ? nil : schedule.activeBlock(at: now)?.end)
    }

    private func setConnection(_ status: BluetoothStatus) {
        if let crumb = BluetoothCrumb.transition(from: connection, to: status) { Crumbs.shared.record(.bluetooth(crumb)) }
        // A @Published property publishes on every assignment, equal or not, and every screen observes this model.
        let changed = connection != status
        if changed { connection = status }
        if status != .connected, hasCurrentReading { hasCurrentReading = false }
        if changed, !isDemo { glance.refresh(glanceInput) }
    }

    /// Only assigns when the value changes: this runs on every stored reading.
    private func setStorageIssue(_ value: Bool) {
        if storageIssue != value { storageIssue = value }
    }

    private func loadHistory() {
        guard !hasLoadedHistory, historyTask == nil else { return }
        historyTask = Task {
            defer { historyTask = nil }
            let now = Date.now
            do {
                let cutoff = now.addingTimeInterval(-900)
                let stored = try await store.readings(from: cutoff, through: now)
                var byTime = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                for point in recent where point.time >= cutoff { byTime[point.id] = point }
                recent = byTime.values.sorted { $0.id < $1.id }
                hasLoadedHistory = true
                setStorageIssue(false)
            } catch {
                setStorageIssue(true)
            }
        }
    }

    private func persist(_ point: HeartRatePoint) async {
        while !Task.isCancelled {
            do {
                try await store.record(bpm: point.bpm, at: point.time)
                setStorageIssue(false)
                return
            } catch {
                setStorageIssue(true)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func prune(now: Date) {
        guard maintenanceTask == nil, now >= nextPrune else { return }
        nextPrune = now.addingTimeInterval(3_600)
        maintenanceTask = Task {
            defer { maintenanceTask = nil }
            do {
                try await store.prune(now: now)
            } catch {
                setStorageIssue(true)
            }
        }
    }
}

/// Keychain failed during pairing. After a save failure the code is spent, so the copy asks for a new one.
struct PairingKeychainError: LocalizedError {
    enum Stage { case read, save }
    let stage: Stage
    var errorDescription: String? {
        switch stage {
        case .read: "Could not read Keychain. Unlock your iPhone and try again."
        case .save: "Could not save the keys in Keychain. Make a new code on the setup page and scan again."
        }
    }
}

/// What the sync card shows, read from LiveSync and ReplaySync.
struct SyncDisplay: Equatable {
    var liveStatus: String
    var lastLiveSync: Date?
    var replayResult: String
    var replayFailed: Bool
    var lastReplay: Date?

    @MainActor init(live: LiveSync, replay: ReplaySync) {
        liveStatus = live.status
        lastLiveSync = live.lastSync
        replayResult = replay.result
        replayFailed = replay.failed
        lastReplay = replay.lastSuccessfulUpload
    }

    init(liveStatus: String, lastLiveSync: Date?, replayResult: String, replayFailed: Bool, lastReplay: Date?) {
        self.liveStatus = liveStatus
        self.lastLiveSync = lastLiveSync
        self.replayResult = replayResult
        self.replayFailed = replayFailed
        self.lastReplay = lastReplay
    }
}

#if DEBUG
/// Fixed states for simulator screenshots: launch with `-demo <name>`.
/// Demo mode never touches Bluetooth, Calendar, notifications or the network.
enum DemoScenario: String, CaseIterable {
    case live, countdown, disconnected, searching, calendarDenied, calendarRequest, bluetoothDenied, setup, onboarding
    case empty, cooldown, connectedWaiting, storageError
    /// Live tab against resting (58): amber, red, a meeting that started 6 minutes ago, and no resting value
    /// while Go live now runs outside a meeting.
    case liveElevated, liveHigh, liveMeeting, noResting
    /// The tab screens (Today, Dates, People, Ask, More) read bundled fixture data. Live is the same as `.live`.
    case data

    static var current: DemoScenario? {
        UserDefaults.standard.string(forKey: "demo").flatMap(DemoScenario.init(rawValue:))
    }
}

extension PhoneModel {
    func applyDemo(_ scenario: DemoScenario) {
        isDemo = true
        let now = Date.now
        demoOrigin = "https://your-worker.example.com"
        onboardingComplete = scenario != .onboarding
        bluetoothPermission = .allowed
        calendarAccess = .allowed
        reminderAccess = .authorized
        ownerUntil = now.addingTimeInterval(7 * 86_400)
        rememberedStrap = true
        manualLive = false
        restingHr = 58
        deviceCalendars = [
            DeviceCalendar(id: "demo-work", title: "Work", sourceTitle: "you@work.example", colorHex: "#16a765"),
            DeviceCalendar(id: "demo-home", title: "Home", sourceTitle: "iCloud", colorHex: "#1badf8"),
            DeviceCalendar(id: "demo-family", title: "Family", sourceTitle: "iCloud", colorHex: "#f691b2"),
            DeviceCalendar(id: "demo-holidays", title: "US Holidays", sourceTitle: "Other", colorHex: "#cca6ac"),
        ]
        listening = ListeningCalendarChoice(excluded: ["demo-holidays"])
        if UserDefaults.standard.bool(forKey: "demoUpdate") { availableUpdate = 3 }
        func meeting(_ title: String, startsIn: TimeInterval, minutes: Double) -> CalendarMeeting {
            CalendarMeeting(title: title, start: now.addingTimeInterval(startsIn),
                            end: now.addingTimeInterval(startsIn + minutes * 60))!
        }
        let current = meeting("Weekly pipeline review", startsIn: -12 * 60, minutes: 30)
        let next = meeting("1:1 with Dana", startsIn: 26 * 3_600, minutes: 30)
        let synced = SyncDisplay(liveStatus: "Live syncing", lastLiveSync: now.addingTimeInterval(-3),
                                 replayResult: "Uploaded", replayFailed: false, lastReplay: now.addingTimeInterval(-540))

        switch scenario {
        case .live, .storageError, .connectedWaiting, .data:
            schedule = MeetingSchedule([current, next])
            connection = .connected
            recent = Self.demoTrace(now: now, until: now)
            latest = recent.last
            hasCurrentReading = true
            demoSync = synced
            if scenario == .storageError { storageIssue = true }
            if scenario == .connectedWaiting {
                latest = nil
                recent = []
                hasCurrentReading = false
            }
        case .liveElevated, .liveHigh, .liveMeeting, .noResting:
            connection = .connected
            hasCurrentReading = true
            demoSync = synced
            switch scenario {
            case .liveElevated:
                schedule = MeetingSchedule([current, next])
                recent = Self.demoTrace(now: now, until: now, lift: 12)
            case .liveHigh:
                schedule = MeetingSchedule([current, next])
                recent = Self.demoTrace(now: now, until: now, lift: 28)
            case .liveMeeting:
                // Calm before the meeting, a rise once it starts.
                schedule = MeetingSchedule([meeting("Board prep with Sam", startsIn: -6 * 60, minutes: 45), next])
                recent = Self.demoTrace(now: now, until: now, lift: 8, liftFrom: 540, speakingAt: 760)
            default:
                schedule = MeetingSchedule([next])
                manualLive = true
                restingHr = nil
                recent = Self.demoTrace(now: now, until: now)
            }
            latest = recent.last
        case .countdown:
            schedule = MeetingSchedule([meeting("Design sync with Olive", startsIn: 12 * 60, minutes: 45), next])
            connection = .outsideMeeting
            demoSync = SyncDisplay(liveStatus: "Live sync paused", lastLiveSync: nil, replayResult: "Uploaded",
                                   replayFailed: false, lastReplay: now.addingTimeInterval(-3 * 3_600))
        case .disconnected:
            schedule = MeetingSchedule([current, next])
            connection = .reconnecting
            recent = Self.demoTrace(now: now, until: now.addingTimeInterval(-170))
            latest = recent.last
            demoSync = SyncDisplay(liveStatus: "Live sync retrying · HTTP 503", lastLiveSync: now.addingTimeInterval(-175),
                                   replayResult: "Upload failed. Will retry.", replayFailed: true,
                                   lastReplay: now.addingTimeInterval(-1_900))
        case .searching:
            schedule = MeetingSchedule([meeting("Investor update", startsIn: 60, minutes: 30)])
            connection = .searching
            demoSync = SyncDisplay(liveStatus: "Waiting for readings", lastLiveSync: nil, replayResult: "Uploaded",
                                   replayFailed: false, lastReplay: now.addingTimeInterval(-7_200))
        case .calendarDenied:
            calendarAccess = .denied
            schedule = MeetingSchedule()
            connection = .outsideMeeting
            demoSync = SyncDisplay(liveStatus: "Live sync paused", lastLiveSync: nil,
                                   replayResult: "No replay attempts", replayFailed: false, lastReplay: nil)
        case .calendarRequest:
            calendarAccess = .notRequested
            reminderAccess = .notDetermined
            schedule = MeetingSchedule()
            connection = .outsideMeeting
            demoSync = SyncDisplay(liveStatus: "Waiting for readings", lastLiveSync: nil,
                                   replayResult: "No replay attempts", replayFailed: false, lastReplay: nil)
        case .bluetoothDenied:
            bluetoothPermission = .denied
            schedule = MeetingSchedule([current])
            connection = .unauthorized
            demoSync = synced
        case .empty:
            schedule = MeetingSchedule()
            connection = .outsideMeeting
            demoSync = SyncDisplay(liveStatus: "Live sync paused", lastLiveSync: nil,
                                   replayResult: "No replay attempts", replayFailed: false, lastReplay: nil)
        case .cooldown:
            schedule = MeetingSchedule([meeting("Weekly pipeline review", startsIn: -33 * 60, minutes: 30)])
            connection = .connected
            recent = Self.demoTrace(now: now, until: now)
            latest = recent.last
            hasCurrentReading = true
            demoSync = synced
        case .setup, .onboarding:
            demoOrigin = ""
            rememberedStrap = false
            schedule = MeetingSchedule([next])
            connection = .outsideMeeting
            demoSync = SyncDisplay(liveStatus: "Waiting for readings", lastLiveSync: nil,
                                   replayResult: "Set the Meetspike URL in Settings", replayFailed: true, lastReplay: nil)
            if scenario == .onboarding {
                calendarAccess = .notRequested
                reminderAccess = .notDetermined
                bluetoothPermission = .notDetermined
            }
        }
    }

    /// A plausible meeting trace: around 70 with a rise while talking. `lift` raises the trace smoothly over the
    /// two minutes from `liftFrom` seconds into the 15 minutes, for the elevated and high fixtures.
    private static func demoTrace(
        now: Date, until end: Date, lift: Double = 0, liftFrom: Double = 600, speakingAt: Double = 520
    ) -> [HeartRatePoint] {
        stride(from: 900.0, through: 0, by: -1).compactMap { secondsAgo -> HeartRatePoint? in
            let time = now.addingTimeInterval(-secondsAgo)
            guard time <= end else { return nil }
            let t = 900 - secondsAgo
            let speaking = 18 * exp(-pow((t - speakingAt) / 110, 2))
            let ramp = min(1, max(0, (t - liftFrom) / 120))
            let bpm = 69 + 4 * sin(t / 47) + 2 * sin(t / 9.3) + speaking + lift * ramp * ramp * (3 - 2 * ramp)
            return HeartRatePoint(bpm: Int(bpm.rounded()), at: time)
        }
    }
}
#endif
