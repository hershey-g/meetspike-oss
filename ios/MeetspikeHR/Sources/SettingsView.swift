import MeetspikeHRCore
import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var origin = ""
    @State private var ingest = ""
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var hasSavedIngest = false
    @State private var hasSavedAccess = false
    @State private var result = ""
    @State private var resultIsError = false
    @State private var check: ConnectionCheck?
    @State private var isChecking = false
    @State private var pairing: PairingRequest?
    @State private var confirmRemoveAccess = false
    @State private var demoApplied = false

    /// A pairing sheet to show: scanning, or a demo state for screenshots.
    struct PairingRequest: Identifiable {
        let id = UUID()
        let start: PairingSheet.Start
        var step: PairingSheet.Step?
    }

    private var form: SyncSettingsForm {
        SyncSettingsForm(origin: origin, ingest: ingest, accessID: accessID, accessSecret: accessSecret,
                         savedOrigin: model.origin, hasSavedIngest: hasSavedIngest)
    }

    private var canTest: Bool { model.syncConfigured && hasSavedIngest && !isChecking }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                Form {
                    connectSection
                    syncSection
                    Section("Meetings") {
                        switch model.calendarAccess {
                        case .notRequested:
                            Button("Allow Calendar access") { Task { await model.requestCalendar() } }
                        case .denied:
                            Button("Open iOS settings for Calendar access", action: openSystemSettings)
                        case .allowed:
                            LabeledContent("Calendar access", value: "Allowed")
                            NavigationLink {
                                ListeningCalendarsView(model: model)
                            } label: {
                                LabeledContent("Calendars that start listening",
                                               value: model.listening.summary(available: model.deviceCalendars))
                            }
                        }
                        switch model.reminderAccess {
                        case .notDetermined:
                            Button("Enable broadcast reminders") { Task { await model.requestReminders() } }
                        case .denied:
                            Button("Open iOS notification settings", action: openSystemSettings)
                        default:
                            LabeledContent("Broadcast reminders", value: model.pushActive ? "On, from your server" : model.ownsReminders ? "On, from this iPhone" : "Sent by your Mac")
                        }
                        NavigationLink {
                            LockScreenHeartRatePicker(model: model)
                        } label: {
                            LabeledContent("Lock Screen heart rate", value: model.liveActivityMode.label)
                        }
                    }
                    .id("meetings")
                    Section {
                    } footer: {
                        if model.pushActive {
                            Text("If no heart rate is coming in two minutes before a meeting, you get a reminder to turn on HR Broadcast, and one more a minute in. After the meeting you get a note to turn it off only if heart rate is still coming in. Your server checks first, so nothing is sent while you are live.")
                        } else {
                            Text("Two minutes before each meeting, a reminder to turn on HR Broadcast. If no heart rate arrives in the first minute, one follow-up. Only one device reminds: this iPhone while it is signed in with notifications on, otherwise your Mac.")
                        }
                    }
                    Section("Heart-rate broadcaster") {
                        LabeledContent("WHOOP", value: model.rememberedStrap ? "Remembered" : "None remembered")
                        Button("Forget WHOOP", action: model.forgetStrap).disabled(!model.rememberedStrap)
                        Button("Open iOS settings for Bluetooth access", action: openSystemSettings)
                    }
                    .id("broadcaster")
                }
                .task {
                    #if DEBUG
                    if model.isDemo, let section = UserDefaults.standard.string(forKey: "demoSettingsSection"), !section.isEmpty {
                        await Task.yield()
                        scroll.scrollTo(section, anchor: .bottom)
                    }
                    #endif
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: reload)
            // A pairing link opened from the Camera app can change the saved settings while this is open.
            .onChange(of: model.settingsRevision) { reload() }
            .sheet(item: $pairing, onDismiss: reload) { request in
                PairingSheet(model: model, start: request.start, initialStep: request.step)
            }
            .confirmationDialog("Remove the saved Access token?", isPresented: $confirmRemoveAccess, titleVisibility: .visible) {
                Button("Remove Access token", role: .destructive, action: removeAccess)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If your server uses Cloudflare Access, sync stops until you add a token again.")
            }
        }
    }

    // MARK: Sections

    private var connectSection: some View {
        Section {
            Button {
                pairing = PairingRequest(start: .scan)
            } label: {
                // White icon too: without it the symbol takes the blue tint and vanishes on the blue fill.
                Label("Scan setup code", systemImage: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.buttonFill)
            .controlSize(.large)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if isChecking { ProgressView() }
                }
            }
            .disabled(!canTest)

            if let check, !isChecking {
                checkRow(check)
            }
        } header: {
            Text("Connect")
        } footer: {
            Text("On your computer, open Meetspike setup and show the code in step 8. Scanning fills in everything below.")
        }
    }

    private func checkRow(_ check: ConnectionCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: check.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.isConnected ? Theme.good : Theme.bad)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.body.weight(.semibold))
                Text(check.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var syncSection: some View {
        let current = form
        return Section {
            TextField("Meetspike URL", text: $origin, prompt: Text("https://your-worker.example.com"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Ingest secret", text: $ingest, prompt: Text(hasSavedIngest ? "Ingest secret (saved)" : "Ingest secret"))
            SecureField("Access client ID", text: $accessID, prompt: Text(hasSavedAccess ? "Access client ID (saved)" : "Access client ID"))
            SecureField("Access client secret", text: $accessSecret,
                        prompt: Text(hasSavedAccess ? "Access client secret (saved)" : "Access client secret"))

            VStack(alignment: .leading, spacing: 8) {
                Button(action: save) {
                    Text("Save sync settings")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.buttonFill)
                .controlSize(.large)
                .disabled(!current.canSave)
                if let hint = current.hint {
                    Text(hint).font(.footnote).foregroundStyle(Theme.bad)
                } else if model.isDemo {
                    Text("Preview only. Sync settings are not saved.").font(.footnote).foregroundStyle(.secondary)
                }
                if !result.isEmpty {
                    Text(result).font(.footnote).foregroundStyle(resultIsError ? Theme.bad : Theme.good)
                }
            }
            .padding(.vertical, 6)
            .id("save")

            if hasSavedAccess {
                Button(role: .destructive) {
                    confirmRemoveAccess = true
                } label: {
                    Text("Remove saved Access token")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.bad)
                .padding(.vertical, 4)
            }
        } header: {
            Text("Meetspike sync")
        } footer: {
            Text("Access client ID and secret are only needed if your server uses Cloudflare Access. Leave secret fields blank to keep saved values for the same address.")
        }
    }

    // MARK: Actions

    private func reload() {
        origin = model.origin
        let saved = model.savedSecrets()
        hasSavedIngest = saved.ingest
        hasSavedAccess = saved.access
        #if DEBUG
        applyDemoState()
        #endif
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func testConnection() async {
        isChecking = true
        defer { isChecking = false }
        check = await model.testConnection()
    }

    private func save() {
        guard form.canSave, let destination = Destination(origin) else { return }
        guard !model.isDemo else {
            show("Preview only. Nothing was saved.", error: false)
            return
        }
        let secret = ingest.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = accessID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = accessSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Saved keys belong to the saved address. A new address starts from what was typed.
            let saved = try form.originChanged ? nil : CredentialStore.load()
            var credentials = Credentials(
                ingestSecret: secret.isEmpty ? saved?.ingestSecret ?? "" : secret,
                accessID: saved?.accessID, accessSecret: saved?.accessSecret
            )
            guard Credentials.isHeaderValue(credentials.ingestSecret) else {
                show(SyncSettingsForm.Problem.ingestMissing.message, error: true)
                return
            }
            if !id.isEmpty {
                credentials.accessID = id
                credentials.accessSecret = token
            }
            try model.save(destination: destination, credentials: credentials)
            ingest = ""
            accessID = ""
            accessSecret = ""
            reload()
            check = nil
            show("Saved", error: false)
            Task { await testConnection() }
        } catch {
            show("Could not save settings in Keychain.", error: true)
        }
    }

    private func removeAccess() {
        do {
            try model.removeAccessToken()
            reload()
            check = nil
            show("Access token removed", error: false)
        } catch {
            show("Could not update Keychain.", error: true)
        }
    }

    private func show(_ text: String, error: Bool) {
        result = text
        resultIsError = error
    }

    #if DEBUG
    /// `-demoSettingsState <state>` (demo mode only) fills Settings for screenshots. Applied once.
    private func applyDemoState() {
        guard model.isDemo, !demoApplied, let state = UserDefaults.standard.string(forKey: "demoSettingsState") else { return }
        demoApplied = true
        let code = String(repeating: "Ab3_", count: 12)
        guard let link = PairingLink(string: "meetspike://pair?origin=https%3A%2F%2Fyour-worker.example.com&code=\(code)") else { return }
        switch state {
        case "connected": check = .connected
        case "wrongSecret": check = .wrongSecret
        case "accessBlocked": check = .accessBlocked
        case "unreachable": check = .unreachable
        case "editing":
            origin = "https://meetspike.example.com"
            ingest = "new-secret"
        case "invalid": origin = "meetspike.example.com"
        case "removeAccess":
            // A dialog asked for before the sheet finishes presenting is dropped.
            Task {
                try? await Task.sleep(for: .seconds(1))
                confirmRemoveAccess = true
            }
        case "scanUnavailable": pairing = PairingRequest(start: .scan)
        case "pairConfirm": pairing = PairingRequest(start: .link(link))
        case "paired": pairing = PairingRequest(start: .link(link), step: .done(link, .connected))
        case "pairedAccessBlocked": pairing = PairingRequest(start: .link(link), step: .done(link, .accessBlocked))
        case "pairFailed": pairing = PairingRequest(start: .scan, step: .failed(PairingError.expired.message))
        default: break
        }
    }
    #endif
}
