import MeetspikeHRCore
import SwiftUI

/// More: sync, what to show, connections, the AI key, setup links and phone settings.
struct MoreScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    @State private var status: ViewStatus?
    @State private var loadedAt: Date?
    @State private var fromCache = false
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var display: SourceDisplay?
    @State private var isSavingDisplay = false
    @State private var displayError: String?
    /// Loading the current switch positions failed. Without this the switches look off and dead with no reason.
    @State private var displayLoadFailed = false
    /// A load is in flight. `.task`, a tab switch and pull to refresh must not stack loads.
    @State private var loadInFlight = false
    @State private var reloadQueued = false
    /// Bumped when the connection changes, so a load that belongs to the old connection cannot clear the flags
    /// of the new one.
    @State private var loadOwner = 0
    /// The `AppEnvironment.connectionRevision` that `status`, `display` and `askStatus` came from.
    @State private var heldConnection = 0

    @State private var askStatus: AskStatus?

    @State private var isSyncing = false
    @State private var syncMessage: String?

    @State private var showPrivacy = false
    @State private var showSettings = false
    @State private var showCalendars = false
    @State private var confirmRemoveKey = false
    @State private var isRemovingKey = false
    @State private var keyRemoveError: String?

    /// "Send crash reports": per phone, on unless turned off.
    @AppStorage(DiagnosticsSettings.key) private var sendReports = true
    @ObservedObject private var diagnostics = DiagnosticsStatus.shared

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section { errorRow(loadError) }
                } else if fromCache, let loadedAt {
                    Section {
                        Label("Offline, showing data from \(loadedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                dataSection
                displaySection
                connectionsSection
                calendarsSection
                askSection
                setupSection
                phoneSection
                crashReportsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Menu")
            .refreshable { await load() }
            .onChange(of: sendReports) { _, _ in DiagnosticsService.shared.settingChanged() }
            .task { await DiagnosticsService.shared.refreshWaiting() }
            // Reloads when the Meetspike URL or a token changes (`connectionRevision`, bumped after the new API is set).
            .task(id: env.connectionRevision) {
                if heldConnection != env.connectionRevision { resetForNewConnection() }
                await load()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
            .navigationDestination(isPresented: $showCalendars) {
                CalendarsScreen()
            }
            .onAppear {
                #if DEBUG
                // `-demoCalendars YES` with `-tab more`: open Calendars for screenshots.
                if model.isDemo && UserDefaults.standard.bool(forKey: "demoCalendars") { showCalendars = true }
                #endif
            }
            .confirmationDialog("Remove your Claude key?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
                Button("Remove key", role: .destructive) { Task { await removeKey() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AskAnnouncement.removeKeyMessage)
            }
        }
    }

    // MARK: Sections

    private var dataSection: some View {
        Section("Data") {
            Button {
                Task { await sync() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync calendar").foregroundStyle(.primary)
                        Text(isSyncing ? "Syncing your calendar..." : syncMessage ?? "Re-read the last 3 weeks and the next month")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isSyncing { ProgressView() }
                }
            }
            .disabled(isSyncing)
            .accessibilityHint("Re-reads your calendar and refreshes your scores")
        }
    }

    private var displaySection: some View {
        Section {
            ForEach([SourceDisplay.Source.oura, .whoop], id: \.rawValue) { source in
                Toggle(isOn: Binding(
                    get: { isShown(source) },
                    set: { value in Task { await setDisplay(source, enabled: value) } }
                )) {
                    Text(source == .oura ? "Show Oura" : "Show WHOOP")
                }
                .disabled(display == nil || isSavingDisplay)
            }
            if isSavingDisplay {
                Text("Saving...").font(.footnote).foregroundStyle(.secondary)
            } else if let displayError {
                Text(displayError).font(.footnote).foregroundStyle(Theme.bad)
            } else if display == nil && displayLoadFailed {
                Text("Could not load display settings.").font(.footnote).foregroundStyle(Theme.bad)
            }
        } header: {
            Text("Show data")
        } footer: {
            Text("Data keeps syncing when hidden.")
        }
    }

    private var connectionsSection: some View {
        Section("Connections") {
            ForEach(connectionRows) { row in
                connectionRow(row)
            }
        }
    }

    /// Before any status has loaded every connection is unknown, not disconnected. WHOOP and Oura rows come from the
    /// status, so until it loads they are listed here with an unknown state.
    private var connectionRows: [MoreConnectionRow] {
        if status != nil { return MoreLogic.connectionRows(status: status) }
        return [
            MoreConnectionRow(id: "google", title: "Google Calendar", isConnected: false, isDisplayed: nil, lastDataDay: nil),
            MoreConnectionRow(id: "whoop", title: "WHOOP", isConnected: false, isDisplayed: nil, lastDataDay: nil),
            MoreConnectionRow(id: "oura", title: "Oura", isConnected: false, isDisplayed: nil, lastDataDay: nil),
        ]
    }

    /// Unknown until a status has loaded (the last loaded one is kept when a later refresh fails).
    private var connectionsUnknown: Bool { status == nil }

    @ViewBuilder
    private func connectionRow(_ row: MoreConnectionRow) -> some View {
        let content = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).foregroundStyle(.primary)
                Text(detail(for: row)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if connectionsUnknown {
                Text(isLoading ? "Checking..." : "Unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(row.isConnected ? "Connected" : "Connect")
                    .font(.subheadline)
                    .foregroundStyle(row.isConnected ? Theme.good : Theme.warn)
            }
        }
        if let url = originURL.flatMap({ MoreLogic.setupURL(origin: $0, rowID: row.id) }) {
            Link(destination: url) { content }
        } else {
            content
        }
    }

    private func detail(for row: MoreConnectionRow) -> String {
        if status == nil { return row.id == "google" ? "Read-only" : "Status not loaded" }
        return MoreLogic.connectionDetail(for: row, status: status)
    }

    private var calendarsSection: some View {
        Section {
            Button {
                showCalendars = true
            } label: {
                linkLabel("Calendars", "Google accounts and which calendars count")
            }
        }
    }

    private var askSection: some View {
        Section("Ask your data") {
            let key = MoreLogic.askKeyStatus(askStatus)
            Button {
                // Sets the sticky pendingAskKeyForm flag, switches to Ask and posts the notification.
                env.openAskKeyForm()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI key").foregroundStyle(.primary)
                        Text("Chat with your data").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if askStatus == nil {
                        // Unknown, not "no key": the status has not loaded.
                        Text(isLoading ? "Checking..." : "Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(key.text)
                            .font(.subheadline)
                            .foregroundStyle(key.isSet ? Theme.good : Theme.warn)
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .accessibilityHint(askStatus?.connected == true ? "Change your key" : "Add your key")
            if askStatus?.connected == true {
                Button(role: .destructive) {
                    confirmRemoveKey = true
                } label: {
                    HStack {
                        Text("Remove key")
                        Spacer()
                        if isRemovingKey { ProgressView() }
                    }
                }
                .disabled(isRemovingKey)
            }
            if let keyRemoveError {
                Text(keyRemoveError).font(.footnote).foregroundStyle(Theme.bad)
            }
        }
    }

    private var setupSection: some View {
        Section {
            if let url = originURL.flatMap({ MoreLogic.setupURL(origin: $0, rowID: "") }) {
                Link(destination: url) {
                    linkLabel("Setup guide", "Keys, redirect links, first import")
                }
            }
            Button {
                showPrivacy.toggle()
            } label: {
                linkLabel("Privacy", "What is stored and where", symbol: showPrivacy ? "chevron.down" : "chevron.right")
            }
            if showPrivacy {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Everything lives in your own Cloudflare account: scores and meetings in D1, raw downloads in R2, sign-in tokens in KV.")
                    Text("Google Calendar is read-only. Nothing is shared with anyone unless you use Ask your data, which sends Anthropic the numbers it needs to answer.")
                    Text("If the app crashes or freezes, it sends a report to your own Meetspike server. Reports hold no meeting names and no heart rates. You can turn them off under Crash reports.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Setup")
        }
    }

    private var phoneSection: some View {
        Section {
            Button {
                showSettings = true
            } label: {
                linkLabel("Phone settings", "Meetspike URL, secrets, calendar access, heart-rate strap")
            }
            NavigationLink {
                LockScreenHeartRatePicker(model: model)
            } label: {
                LabeledContent("Lock Screen heart rate", value: model.liveActivityMode.label)
            }
        } header: {
            Text("This iPhone")
        }
    }

    private var crashReportsSection: some View {
        Section {
            Toggle("Send crash reports", isOn: $sendReports)
            Button {
                Task { await sendTestReport() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send a test report")
                        if let result = diagnostics.testResult, sendReports, !diagnostics.isSendingTest {
                            Text(result).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if diagnostics.isSendingTest { ProgressView() }
                }
            }
            .disabled(!sendReports || model.isDemo || diagnostics.isSendingTest)
            if sendReports, let waiting = DiagnosticPolicy.waitingText(count: diagnostics.waiting) {
                Text(waiting).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Crash reports")
        } footer: {
            Text("Goes only to your own Meetspike server. No meeting names or heart rates.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            NavigationLink {
                ReleaseNotesList()
            } label: {
                Text("What's new")
            }
            let label = MoreLogic.versionLabel(
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
            if !label.isEmpty {
                Text(label).foregroundStyle(.secondary)
            }
            if let site = URL(string: "https://github.com/hershey-g") {
                Link(destination: site) {
                    HStack {
                        Text("Built by Hershey Goldberger").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func linkLabel(_ title: String, _ subtitle: String, symbol: String = "chevron.right") -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.footnote).foregroundStyle(Theme.bad)
            Button("Try again") { Task { await load() } }
        }
    }

    // MARK: State

    private var originURL: URL? {
        let origin = model.origin
        return origin.isEmpty ? nil : URL(string: origin)
    }

    private func isShown(_ source: SourceDisplay.Source) -> Bool {
        guard let display else { return false }
        return source == .oura ? display.oura : display.whoop
    }

    // MARK: Loading

    /// One load at a time. A request made while one is running (tab switch right after `.task`, a sync that finishes
    /// mid-load) is not dropped: it runs again once, right after the current one.
    private func load() async {
        if loadInFlight {
            reloadQueued = true
            return
        }
        loadInFlight = true
        let owner = loadOwner
        defer { if loadOwner == owner { loadInFlight = false } }
        repeat {
            reloadQueued = false
            await loadOnce()
        } while reloadQueued && !Task.isCancelled && loadOwner == owner
    }

    /// The Meetspike URL or a token changed: everything held came from the old server. Clear it, and let the next
    /// `load()` start even if a load for the old connection is still unwinding.
    private func resetForNewConnection() {
        heldConnection = env.connectionRevision
        loadOwner += 1
        loadInFlight = false
        reloadQueued = false
        status = nil
        loadedAt = nil
        fromCache = false
        loadError = nil
        display = nil
        displayError = nil
        displayLoadFailed = false
        askStatus = nil
        syncMessage = nil
        keyRemoveError = nil
    }

    private func loadOnce() async {
        // Read together, before any await: answers for an older connection are dropped.
        let connection = env.connectionRevision
        let api = env.api
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await api.loadView(date: env.selectedDay)
            if connection != env.connectionRevision { return }
            env.noteLoaded(loaded)
            env.noteToday(loaded.value.today ?? env.today, isFromCache: loaded.isFromCache, timeZone: loaded.value.timeZone)
            status = loaded.value.status
            loadedAt = loaded.savedAt
            fromCache = loaded.isFromCache
            loadError = nil
            if let shown = loaded.value.status?.sourceDisplay, !isSavingDisplay { display = shown }
        } catch is CancellationError {
            return
        } catch {
            if connection != env.connectionRevision { return }
            // The sheet has no connection banner, so every error shows here, offline and access rejected included.
            env.report(error)
            loadError = MoreLogic.sheetError(error, prefix: "Couldn't load your connections.")
        }
        if display == nil {
            do {
                let shown = try await api.loadSourceDisplay().value
                if connection != env.connectionRevision { return }
                display = shown
                displayLoadFailed = false
            } catch is CancellationError {
                return
            } catch {
                if connection != env.connectionRevision { return }
                // Not swallowed: the switches stay off and disabled, and the section says why.
                displayLoadFailed = true
                env.report(error)
                NSLog("More: source display load failed: %@", DatesLogic.logCode(error))
            }
        } else {
            displayLoadFailed = false
        }
        do {
            let loadedStatus = try await api.loadAskStatus().value
            if connection != env.connectionRevision { return }
            askStatus = loadedStatus
        } catch is CancellationError {
            return
        } catch {
            if connection != env.connectionRevision { return }
            // The AI key row falls back to "Add key". The key form itself reports a real problem.
            NSLog("More: ask status load failed: %@", DatesLogic.logCode(error))
        }
    }

    // MARK: Actions

    /// Removes the saved Claude key and the saved chat that went with it, like Remove on Ask did. A live Ask tab
    /// is told through `.meetspikeAskKeyRemoved` so it drops its chat too.
    private func removeKey() async {
        guard !isRemovingKey else { return }
        isRemovingKey = true
        keyRemoveError = nil
        defer { isRemovingKey = false }
        do {
            _ = try await env.api.deleteAskKey()
            AskChatStore(directory: AskChatStore.defaultDirectory(), isDemo: env.isDemoData).clear()
            askStatus?.connected = false
            askStatus?.tail = nil
            env.noteOnline()
            NotificationCenter.default.postAskKeyRemoved()
        } catch is CancellationError {
            return
        } catch {
            env.report(error)
            keyRemoveError = MoreLogic.sheetError(error, prefix: "Couldn't remove the key.")
        }
    }

    private func sendTestReport() async {
        guard !diagnostics.isSendingTest else { return }
        diagnostics.isSendingTest = true
        diagnostics.testResult = nil
        // The engine sets the line itself, and keeps it right after the try.
        await DiagnosticsService.shared.sendTestReport()
        diagnostics.isSendingTest = false
    }

    private func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncMessage = nil
        defer { isSyncing = false }
        let connection = env.connectionRevision
        let api = env.api
        do {
            let result = try await api.refresh(full: true)
            // The connection changed while this ran: the answer is the old server's, say nothing about it.
            if connection != env.connectionRevision { return }
            env.noteOnline()
            syncMessage = MoreLogic.syncMessage(
                result, showWhoop: display?.whoop ?? true, showOura: display?.oura ?? true)
            // Also when Google is missing but a wearable refreshed: scores changed (web err.wearableRefreshed).
            if MoreLogic.shouldPostDataRefreshed(result) {
                NotificationCenter.default.postDataRefreshed()
            }
            await load()
        } catch is CancellationError {
            return
        } catch {
            if connection != env.connectionRevision { return }
            env.report(error)
            syncMessage = MoreLogic.sheetError(error, prefix: "Calendar sync failed:")
        }
    }

    private func setDisplay(_ source: SourceDisplay.Source, enabled: Bool) async {
        guard display != nil, !isSavingDisplay else { return }
        isSavingDisplay = true
        displayError = nil
        defer { isSavingDisplay = false }
        do {
            // Exactly one key goes to the Worker (MoreLogic.sourceToggleRequest), so two devices never clobber each other.
            let saved = try await env.api.setSourceDisplay(source, enabled: enabled)
            env.noteOnline()
            display = saved
            // Cached views were written with the old sources. Drop them, and tell Ask and Today to do the same.
            await env.api.responseCache?.clear()
            NotificationCenter.default.postDisplaySourcesChanged(source: source)
            await load()
        } catch is CancellationError {
            return
        } catch {
            env.report(error)
            displayError = MoreLogic.sheetError(error, prefix: "Could not save display setting.")
        }
    }
}
