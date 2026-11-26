import MeetspikeHRCore
import SwiftUI

/// Menu > Calendars. Connected Google accounts with a switch per calendar (which ones count as meetings),
/// Add Google account (Safari, the setup page), Disconnect, and the Apple Calendar calendars on this iPhone
/// that start heart-rate listening.
struct CalendarsScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var model: PhoneModel

    @State private var state: GoogleCalendarsResponse?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var message: String?
    @State private var messageIsError = false
    /// "account|calendarId" of switches being saved.
    @State private var saving: Set<String> = []
    @State private var confirmDisconnect: GoogleAccount?
    @State private var disconnecting: String?

    var body: some View {
        ScrollViewReader { scroll in
            list
                .task {
                    #if DEBUG
                    // `-demoCalendarsSection listening`: start scrolled to the iPhone calendars, for screenshots.
                    if model.isDemo, UserDefaults.standard.string(forKey: "demoCalendarsSection") == "listening" {
                        try? await Task.sleep(for: .milliseconds(600))
                        scroll.scrollTo("listening", anchor: .top)
                    }
                    #endif
                }
        }
    }

    private var list: some View {
        List {
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loadError).font(.footnote).foregroundStyle(Theme.bad)
                        Button("Try again") { Task { await load(refresh: true) } }
                    }
                }
            }
            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(messageIsError ? Theme.bad : .secondary)
                }
            }
            googleSections
            addAccountSection
            ListeningCalendarsSection()
                .id("listening")
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(refresh: true) }
        .task(id: env.connectionRevision) { await load(refresh: true) }
        .confirmationDialog(
            confirmDisconnect.map { CalendarsLogic.disconnectTitle($0.email) } ?? "",
            isPresented: Binding(get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } }),
            titleVisibility: .visible,
            presenting: confirmDisconnect
        ) { account in
            Button("Disconnect", role: .destructive) { Task { await disconnect(account) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(CalendarsLogic.disconnectMessage)
        }
    }

    // MARK: Google

    @ViewBuilder
    private var googleSections: some View {
        if let state {
            if state.accounts.isEmpty {
                Section("Google Calendar") {
                    Text("No Google account connected.").foregroundStyle(.secondary)
                }
            }
            ForEach(state.accounts) { account in
                Section {
                    ForEach(account.calendars) { calendar in
                        calendarRow(account, calendar)
                    }
                    Button(role: .destructive) {
                        confirmDisconnect = account
                    } label: {
                        HStack {
                            Text("Disconnect")
                            Spacer()
                            if disconnecting == account.email { ProgressView() }
                        }
                    }
                    .disabled(disconnecting != nil)
                } header: {
                    // An address must not wrap with a hyphen ("you@exam-ple.com"): shrink it instead.
                    Text(account.email)
                        .textCase(nil)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .truncationMode(.middle)
                } footer: {
                    Text(CalendarsLogic.accountFooter(account))
                }
            }
        } else if loadError == nil {
            Section("Google Calendar") {
                HStack {
                    Text("Loading calendars...").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }
        }
    }

    private func calendarRow(_ account: GoogleAccount, _ calendar: GoogleCalendar) -> some View {
        let key = "\(account.email)|\(calendar.id)"
        return Toggle(isOn: Binding(
            get: { calendar.isSelected },
            set: { value in Task { await setCalendar(account: account.email, calendar: calendar.id, selected: value) } }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ColorDot(hex: calendar.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CalendarsLogic.calendarName(calendar, account: account.email)).foregroundStyle(.primary)
                    if let detail = CalendarsLogic.calendarDetail(calendar) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(calendar.error == nil ? Color.secondary : Theme.bad)
                    }
                }
            }
        }
        .tint(Theme.good)
        .disabled(saving.contains(key) || disconnecting == account.email)
        .accessibilityHint("Counts this calendar's events as meetings")
    }

    @ViewBuilder
    private var addAccountSection: some View {
        Section {
            if let url = originURL.flatMap(CalendarsLogic.addAccountURL) {
                Link(destination: url) {
                    HStack {
                        Label("Add Google account", systemImage: "plus.circle")
                        Spacer()
                        Image(systemName: "safari").foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("Add your Meetspike URL in Phone settings first.").foregroundStyle(.secondary)
            }
        } footer: {
            Text("Sign-in opens in Safari. Pull down here when you are done. Every account you add counts as you, and a meeting on two calendars counts once.")
        }
    }

    private var originURL: URL? {
        let origin = model.origin
        return origin.isEmpty ? nil : URL(string: origin)
    }

    // MARK: Actions

    private func load(refresh: Bool) async {
        let connection = env.connectionRevision
        let api = env.api
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await api.googleCalendars(refresh: refresh)
            if connection != env.connectionRevision { return }
            state = loaded
            loadError = nil
            env.noteOnline()
        } catch is CancellationError {
            return
        } catch {
            if connection != env.connectionRevision { return }
            env.report(error)
            loadError = MoreLogic.sheetError(error, prefix: "Couldn't load your calendars.")
        }
    }

    private func setCalendar(account: String, calendar: String, selected: Bool) async {
        let key = "\(account)|\(calendar)"
        guard !saving.contains(key), let before = state else { return }
        saving.insert(key)
        defer { saving.remove(key) }
        state = CalendarsLogic.applying(before, account: account, calendarId: calendar, selected: selected)
        message = nil
        let api = env.api
        do {
            let saved = try await api.setGoogleCalendar(account: account, calendarId: calendar, selected: selected)
            state = saved
            message = CalendarsLogic.savedMessage(saved, selected: selected)
            messageIsError = saved.syncError != nil
            env.noteOnline()
            // Meetings changed: drop cached days and tell the tabs to reload.
            await api.responseCache?.clear()
            NotificationCenter.default.postDataRefreshed()
        } catch is CancellationError {
            if let current = state {
                state = CalendarsLogic.applying(current, account: account, calendarId: calendar, selected: !selected)
            }
        } catch {
            if let current = state {
                state = CalendarsLogic.applying(current, account: account, calendarId: calendar, selected: !selected)
            }
            env.report(error)
            message = MoreLogic.sheetError(error, prefix: "Couldn't save.")
            messageIsError = true
        }
    }

    private func disconnect(_ account: GoogleAccount) async {
        guard disconnecting == nil else { return }
        disconnecting = account.email
        defer { disconnecting = nil }
        message = nil
        let api = env.api
        do {
            state = try await api.disconnectGoogleAccount(email: account.email)
            message = "\(account.email) disconnected."
            messageIsError = false
            env.noteOnline()
            await api.responseCache?.clear()
            NotificationCenter.default.postDataRefreshed()
        } catch is CancellationError {
            return
        } catch {
            env.report(error)
            message = MoreLogic.sheetError(error, prefix: "Couldn't disconnect.")
            messageIsError = true
        }
    }
}

/// The Apple Calendar calendars on this iPhone that start heart-rate listening. Saved on this iPhone only.
struct ListeningCalendarsSection: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Section {
            switch model.calendarAccess {
            case .allowed:
                if model.deviceCalendars.isEmpty {
                    Text("No calendars on this iPhone.").foregroundStyle(.secondary)
                }
                ForEach(ListeningCalendarChoice.grouped(model.deviceCalendars), id: \.source) { group in
                    ForEach(group.calendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { model.listening.includes(calendar.id) },
                            set: { model.setListening(calendar.id, included: $0) }
                        )) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                ColorDot(hex: calendar.colorHex)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(calendar.title)
                                    Text(group.source).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(Theme.good)
                    }
                }
            case .denied:
                Button("Open iOS settings for Calendar access") { SystemSettings.open() }
            case .notRequested:
                Button("Allow Calendar access") { Task { await model.requestCalendar() } }
            }
        } header: {
            Text("Calendars that start listening")
        } footer: {
            Text("On this iPhone. Heart rate listening starts 5 minutes before meetings on these calendars. New calendars are on until you turn them off.")
        }
    }
}

/// The same list on its own page, for Phone settings.
struct ListeningCalendarsView: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        List { ListeningCalendarsSection() }
            .environmentObject(model)
            .navigationTitle("Listening calendars")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A calendar's color, or nothing when Google or iOS gave none. Sits on the first line of the name at every
/// text size (placed in a `.firstTextBaseline` stack).
private struct ColorDot: View {
    let hex: String?
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var lift: CGFloat = 3

    var body: some View {
        Group {
            if let rgb = CalendarsLogic.rgb(hex) {
                Circle().fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
            } else {
                Circle().strokeBorder(.tertiary, lineWidth: 1)
            }
        }
        // Grows with the text, but stays a dot at the largest sizes.
        .frame(width: min(size, 18), height: min(size, 18))
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + lift }
        .accessibilityHidden(true)
    }
}
