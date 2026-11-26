import MeetspikeHRCore
import SwiftUI
import UserNotifications

/// First-run setup: what Meetspike does, WHOOP HR Broadcast, then each iOS
/// permission with its reason before the system prompt appears.
@MainActor
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, broadcast, calendar, bluetooth, notifications, done
    }

    @ObservedObject var model: PhoneModel
    @State private var step: Step = .welcome
    @State private var showSettings = false
    @State private var isRequesting = false
    @State private var permissionTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: PhoneModel) {
        self.model = model
        #if DEBUG
        let start = UserDefaults.standard.integer(forKey: "onboardingStep")
        _step = State(initialValue: Step(rawValue: start) ?? .welcome)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 12)
            ScrollView {
                page
                    .padding(.horizontal, 28)
                    .padding(.top, 40)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            buttons
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: 520)
        }
        .background(Theme.background.ignoresSafeArea())
        .tint(Theme.accent)
        .animation(reduceMotion ? nil : .snappy, value: step)
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .onDisappear { permissionTask?.cancel() }
        .onChange(of: model.bluetoothPermission) {
            if step == .bluetooth, isRequesting, model.bluetoothPermission != .notDetermined {
                advance()
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Theme.accent : Theme.inset)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            Page(symbol: "heart.text.square.fill", brandMark: true, title: "Meetspike",
                 message: "Live heart rate from your WHOOP, captured only around your meetings and sent to your Meetspike dashboard.") {
                Bullet(symbol: "calendar.badge.clock", text: "Listens from 5 minutes before each meeting until 10 minutes after.")
                Bullet(symbol: "lock.iphone", text: "Keeps working with the screen locked once it's connected.")
                Bullet(symbol: "hand.raised", text: "Meeting titles stay on this iPhone. Only times and heart rate are uploaded.")
            }
        case .broadcast:
            Page(symbol: "dot.radiowaves.left.and.right", title: "Turn on HR Broadcast",
                 message: "Your strap stays connected to the WHOOP app. Meetspike listens to its separate heart-rate broadcast, so there's nothing to pair.") {
                Bullet(symbol: "1.circle.fill", text: "Open the WHOOP app.")
                Bullet(symbol: "2.circle.fill", text: "Go to Menu → Device Settings.")
                Bullet(symbol: "3.circle.fill", text: "Turn on HR Broadcast. Check it again after a WHOOP firmware update.")
            }
        case .calendar:
            Page(symbol: "calendar", title: "Know when meetings start",
                 message: "Meetspike reads your calendar on this iPhone to start listening just before each meeting and stop after. All-day and declined events are skipped.") {
                PermissionState(granted: model.calendarAccess == .allowed, denied: model.calendarAccess == .denied)
            }
        case .bluetooth:
            Page(symbol: "antenna.radiowaves.left.and.right", title: "Hear your WHOOP",
                 message: "Bluetooth lets Meetspike receive the heart-rate broadcast from your strap during meetings.") {
                PermissionState(granted: model.bluetoothPermission == .allowed, denied: model.bluetoothPermission == .denied)
            }
        case .notifications:
            Page(symbol: "bell.badge", title: "Get a nudge",
                 message: "A reminder before your first meeting to switch HR Broadcast on, and one after your last meeting when you can switch it off.") {
                PermissionState(granted: model.reminderAccess == .authorized || model.reminderAccess == .provisional,
                                denied: model.reminderAccess == .denied)
            }
        case .done:
            Page(symbol: "checkmark.circle.fill", title: "Ready when you are",
                 message: "Keep Meetspike open until it connects at the start of a meeting. After that you can lock your phone.") {
                Checklist(label: "Calendar", ok: model.calendarAccess == .allowed,
                          missing: "Optional. Use Go live now without calendar access.")
                Checklist(label: "Bluetooth", ok: model.bluetoothPermission == .allowed,
                          missing: "Required for heart rate. Allow it in Settings or on your first connection.")
                Checklist(label: "Reminders", ok: model.reminderAccess == .authorized || model.reminderAccess == .provisional,
                          missing: "Optional. Enable reminders in Settings any time.")
                Checklist(label: "Meetspike sync", ok: model.syncConfigured,
                          missing: "Add your Meetspike URL and ingest secret")
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        VStack(spacing: 8) {
            Button(action: primary) {
                Text(primaryTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.buttonFill)
            .controlSize(.large)
            .disabled(isRequesting)

            Group {
                if isPermissionStep, !alreadyAnswered || isRequesting {
                    Button("Not Now", action: advance)
                } else if step == .done, !model.syncConfigured {
                    Button("Set Up Sync") { showSettings = true }
                } else {
                    // Keeps the primary button in the same place on every page.
                    Button(" ", action: {}).hidden().accessibilityHidden(true)
                }
            }
            .controlSize(.large)
        }
    }

    private var isPermissionStep: Bool { [.calendar, .bluetooth, .notifications].contains(step) }

    private var alreadyAnswered: Bool {
        switch step {
        case .calendar: model.calendarAccess != .notRequested
        case .bluetooth: model.bluetoothPermission != .notDetermined
        case .notifications: model.reminderAccess != .notDetermined
        default: true
        }
    }

    private var primaryTitle: String {
        if isRequesting { return "Waiting…" }
        if isPermissionStep, !alreadyAnswered {
            switch step {
            case .calendar: return "Allow Calendar Access"
            case .bluetooth: return "Allow Bluetooth"
            default: return "Allow Notifications"
            }
        }
        return step == .done ? "Get Started" : "Continue"
    }

    private func primary() {
        guard !isRequesting else { return }
        guard isPermissionStep, !alreadyAnswered else {
            if step == .done { model.finishOnboarding() } else { advance() }
            return
        }
        let requestedStep = step
        isRequesting = true
        if requestedStep == .bluetooth {
            model.requestBluetooth()
            return
        }
        permissionTask = Task {
            switch requestedStep {
            case .calendar: await model.requestCalendar()
            default: await model.requestReminders()
            }
            guard !Task.isCancelled, step == requestedStep else { return }
            advance()
        }
    }

    private func advance() {
        permissionTask?.cancel()
        permissionTask = nil
        isRequesting = false
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }
}

private struct Page<Content: View>: View {
    let symbol: String
    var brandMark = false
    let title: String
    let message: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if brandMark {
                // The app icon itself, so the first screen matches what's on the Home Screen.
                Image("BrandMark")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 72, height: 72)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionState: View {
    let granted: Bool
    let denied: Bool

    var body: some View {
        if granted {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
                .font(.headline)
        } else if denied {
            VStack(alignment: .leading, spacing: 8) {
                Label("Not allowed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(Theme.bad)
                    .font(.headline)
                Text("You can change this any time in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: SystemSettings.open)
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct Checklist: View {
    let label: String
    let ok: Bool
    var missing = "Not allowed. Change it in Settings."

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Theme.good : Theme.warn)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.headline)
                if !ok {
                    Text(missing).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
