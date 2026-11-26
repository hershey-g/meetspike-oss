import AppKit
import Combine
import MeetspikeHRCore
import ServiceManagement
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var logger: Logger
    @State private var origin = ""
    @State private var ingestSecret = ""
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var removeAccess = false
    @State private var saved = ""
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginMessage = ""
    @AppStorage(HRReminderController.enabledKey) private var reminderEnabled = true
    @AppStorage(HRReminderController.pushoverKey) private var reminderPushover = true

    var body: some View {
        Form {
            Section("Meetspike sync") {
                TextField("Worker URL", text: $origin, prompt: Text("https://"))
                SecureField("Ingest secret", text: $ingestSecret)
                SecureField("Access client ID", text: $accessID)
                    .disabled(removeAccess)
                SecureField("Access client secret", text: $accessSecret)
                    .disabled(removeAccess)
                Toggle("Remove saved Access token", isOn: $removeAccess)
                Text("Blank credential fields keep their saved values. To replace the optional Access token, enter both fields.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                HStack {
                    Button("Save", action: save)
                    Text(saved)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Meeting live mode") {
                Toggle("Listen only around meetings", isOn: Binding(
                    get: { logger.meetingOnly }, set: { logger.setMeetingOnly($0) }
                ))
                if logger.meetingOnly {
                    switch logger.calendarAccess {
                    case .notRequested:
                        Button("Allow Calendar access", action: logger.requestCalendarAccess)
                    case .denied:
                        CalendarAccessNeeded()
                    case .allowed:
                        LabeledContent("Calendar access", value: "Allowed")
                    }
                }
            }

            Section("Show data") {
                Toggle("Oura", isOn: Binding(
                    get: { logger.sourceDisplay?.oura == true },
                    set: { logger.setSourceDisplay(.oura, enabled: $0) }
                ))
                .disabled(logger.sourceDisplay == nil || logger.sourceDisplaySaving)
                Toggle("WHOOP", isOn: Binding(
                    get: { logger.showsWhoop },
                    set: { logger.setSourceDisplay(.whoop, enabled: $0) }
                ))
                .disabled(logger.sourceDisplay == nil || logger.sourceDisplaySaving)
                Text("Data keeps syncing when hidden.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if logger.sourceDisplaySaving {
                    Text("Saving…").foregroundStyle(.secondary)
                }
                if let error = logger.sourceDisplayError {
                    Text(error).foregroundStyle(.secondary)
                }
            }

            Section("Heart-rate broadcaster") {
                LabeledContent("WHOOP", value: logger.paired ? "Remembered" : "None remembered")
                Button("Forget WHOOP", action: logger.forgetDevice)
                    .disabled(!logger.paired)
                Button("Show Setup Guide…") { WalkthroughWindow.show(logger: logger) }
                Text("Turn on HR Broadcast in the WHOOP app and keep your strap nearby. The setup guide walks you through connecting it.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Meeting reminder") {
                Toggle("Remind me to turn on HR Broadcast", isOn: $reminderEnabled)
                Toggle("Also send to my phone (Pushover)", isOn: $reminderPushover)
                    .disabled(!reminderEnabled)
                if logger.phoneOwnsReminders {
                    Text("Your iPhone reminds you about the meetings it has scheduled, so the Mac stays quiet for those. The Mac still reminds about any other meeting, and takes over fully if the iPhone app is signed out, has notifications off, or has not checked in for 7 days.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text("Two minutes before a calendar meeting (or when a Zoom meeting opens) with no heart rate coming in, Meetspike shows a notification with sound. If no heart rate arrives in the meeting's first minute, it sends one follow-up. The phone push needs PUSHOVER_TOKEN and PUSHOVER_USER set on the Worker.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Login") {
                LabeledContent("Open at login", value: loginDescription)
                HStack {
                    Button(loginStatus == .notRegistered ? "Enable" : "Disable", action: changeLogin)
                        .disabled(loginStatus == .notFound)
                    if loginStatus == .requiresApproval {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if !loginMessage.isEmpty {
                    Text(loginMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 720)
        .onAppear {
            origin = logger.origin
            loginStatus = SMAppService.mainApp.status
            logger.refreshSourceDisplay()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var loginDescription: String {
        switch loginStatus {
        case .enabled: "On"
        case .requiresApproval: "Awaiting approval"
        case .notRegistered: "Off"
        case .notFound: "App bundle unavailable"
        @unknown default: "Unavailable"
        }
    }

    private func changeLogin() {
        do {
            if loginStatus == .notRegistered {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = ""
        } catch {
            loginMessage = "Could not change the login setting."
        }
        loginStatus = SMAppService.mainApp.status
    }

    private func save() {
        guard let destination = Destination(origin) else {
            saved = "Enter the Meetspike HTTPS origin."
            return
        }
        let ingest = ingestSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = accessID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = accessSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let current = try CredentialStore.load()
            let effectiveIngest = ingest.isEmpty ? current?.ingestSecret ?? "" : ingest
            guard Credentials.isHeaderValue(effectiveIngest) else {
                saved = "Enter a valid ingest secret."
                return
            }

            var newCredentials = Credentials(
                ingestSecret: effectiveIngest, accessID: current?.accessID, accessSecret: current?.accessSecret
            )
            if removeAccess {
                newCredentials.accessID = nil
                newCredentials.accessSecret = nil
            } else if !id.isEmpty || !secret.isEmpty {
                guard Credentials.isHeaderValue(id), Credentials.isHeaderValue(secret) else {
                    saved = "Enter both Access token fields."
                    return
                }
                newCredentials.accessID = id
                newCredentials.accessSecret = secret
            }

            try logger.save(destination: destination, credentials: newCredentials)
            origin = logger.origin
            ingestSecret = ""
            accessID = ""
            accessSecret = ""
            removeAccess = false
            saved = "Saved"
        } catch {
            saved = "Could not save settings in Keychain."
        }
    }
}
