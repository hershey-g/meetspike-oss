import AppKit
import Foundation
import MeetspikeHRCore
import SwiftUI

@main
@MainActor
struct MeetspikeHRApp: App {
    @StateObject private var logger = Logger()

    var body: some Scene {
        MenuBarExtra {
            StatusView(logger: logger, live: logger.liveSync)
        } label: {
            MenuBarLabel(icon: MenuBarIcon(logger.snapshot(now: .now), showReading: logger.showsWhoop), clock: logger.heartbeat)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(logger: logger)
        }
    }
}

/// Flips `beat` on for a moment at each heartbeat, so the menu bar heart
/// beats at the live heart rate. The menu bar can't run a smooth animation,
/// so it shows two frames: resting and a brief bigger heart on each beat.
@MainActor
final class HeartbeatClock: ObservableObject {
    @Published private(set) var beat = false
    /// Returns the live BPM, or nil when there is no live reading.
    var bpm: () -> Int? = { nil }
    private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
            }
        }
    }

    deinit { task?.cancel() }

    private func step() async {
        guard let bpm = bpm(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if beat { beat = false }
            try? await Task.sleep(for: .seconds(1))
            return
        }
        let now = Date.now.timeIntervalSinceReferenceDate
        let next = Heartbeat.nextBeat(bpm: bpm, after: now)
        try? await Task.sleep(for: .seconds(next - now))
        beat = true
        // Short enough to stay a beat even at 220 BPM (0.27 s apart).
        try? await Task.sleep(for: .milliseconds(min(140, Int(Heartbeat.period(bpm: bpm) * 500))))
        beat = false
    }
}

/// The heart and live BPM in the menu bar, for example "♥ 72". A dimmed
/// outline heart with a dash means no current reading; a pause symbol means
/// recording is paused.
///
/// MenuBarExtra drops an SF Symbol embedded in a Text label (only the dash
/// showed), so the symbol and number are drawn into one template image,
/// which the status item always displays and tints for light and dark menu bars.
@MainActor
private struct MenuBarLabel: View {
    let icon: MenuBarIcon
    @ObservedObject var clock: HeartbeatClock

    var body: some View {
        Image(nsImage: MenuBarImage.image(for: icon, beat: clock.beat && icon.style == .live))
            .accessibilityLabel(Text(icon.accessibilityLabel))
    }
}

@MainActor
enum MenuBarImage {
    private struct Key: Equatable {
        let icon: MenuBarIcon
        let beat: Bool
        let scale: CGFloat
    }

    /// Both frames of a beating heart stay cached, so beating doesn't re-render.
    private static var cache: [(key: Key, image: NSImage)] = []

    static func image(for icon: MenuBarIcon, beat: Bool = false) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = Key(icon: icon, beat: beat, scale: scale)
        if let hit = cache.first(where: { $0.key == key }) { return hit.image }

        let content = HStack(spacing: 3) {
            // A fixed box, so the number doesn't shift when the heart grows on a beat.
            // Sized for the scaled heart (about 19x17pt) so the beat never clips.
            Image(systemName: icon.symbol)
                .scaleEffect(beat ? 1.18 : 1)
                .frame(width: 21, height: 18)
            if !icon.text.isEmpty {
                Text(verbatim: icon.text).monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.black)
        // Template images keep alpha, so dimming survives the menu bar tint.
        .opacity(icon.isDimmed ? 0.5 : 1)
        .padding(.horizontal, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        let image: NSImage
        if let cgImage = renderer.cgImage {
            image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            )
        } else {
            // Never leave the status item empty.
            image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) ?? NSImage()
        }
        image.isTemplate = true
        image.accessibilityDescription = icon.accessibilityLabel
        cache = cache.filter { $0.key.icon == icon && $0.key.scale == scale }
        cache.append((key, image))
        return image
    }
}

@MainActor
private struct StatusView: View {
    private static let ageFormatter = RelativeDateTimeFormatter()

    @ObservedObject var logger: Logger
    @ObservedObject var live: LiveSync
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if logger.showsWhoop { readout(now: context.date) }
                StatusHeader(status: MenuStatus(logger.snapshot(now: context.date)), onUseBroadcaster: logger.useBroadcaster)
                if let meeting = logger.meetings.displayedMeeting(at: context.date) {
                    Text(meeting.title).font(.subheadline).lineLimit(2)
                }
                MeetingChoicesSection(logger: logger, choices: logger.choices, now: context.date)
            }

            if logger.meetingOnly {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Go live now", isOn: Binding(get: { logger.manualLive }, set: { logger.setManualLive($0) }))
                        .disabled(!logger.canToggleManualLive)
                    Text("Record outside meetings too, like while you work. Stays on until you turn it off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if logger.calendarAccess == .notRequested {
                    Button("Allow Calendar access", action: logger.requestCalendarAccess)
                }
                if logger.calendarAccessNeeded {
                    CalendarAccessNeeded()
                }
            }

            if logger.showsWhoop {
                LiveHistoryView(logger: logger, meeting: live.meeting)
            }

            if !logger.setupComplete {
                Button {
                    WalkthroughWindow.show(logger: logger)
                } label: {
                    Label("Finish setup…", systemImage: "list.bullet.clipboard")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    Text("Last live sync").foregroundStyle(.secondary)
                    if let time = live.lastSync {
                        Text(time, format: .dateTime.hour().minute().second())
                    } else {
                        Text("None yet")
                    }
                }
                GridRow {
                    Text("Last replay attempt").foregroundStyle(.secondary)
                    if let time = logger.lastUpload {
                        Text(time, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text("None yet")
                    }
                }
                if logger.lastUpload != nil || logger.uploadFailed {
                    GridRow {
                        Text("Replay status").foregroundStyle(.secondary)
                        Text(logger.uploadResult)
                    }
                }
            }
            .font(.caption)

            if logger.storageIssue {
                Label("Local storage unavailable", systemImage: "exclamationmark.triangle")
            }

            Divider()

            // Only promise a resume the pause policy will actually make.
            if let resumesAt = logger.pauseResumesAt(now: .now) {
                Text("Paused. Resumes at \(resumesAt, style: .time).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(logger.paused ? "Resume" : "Pause", action: logger.togglePause)
                Spacer()
                if logger.setupComplete {
                    Button("Setup Guide…") { WalkthroughWindow.show(logger: logger) }
                }
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 382)
        .onAppear { logger.refreshSourceDisplay() }
    }

    private func readout(now: Date) -> some View {
        let reading = logger.latestReading
        let age = reading.map {
            ReadingAge(readAt: $0.time, now: now, connected: logger.connection == .connected && logger.readingIsFromConnection)
        }
        let stale = age?.isStale ?? true
        let ageText = reading.map {
            age?.seconds == 0 ? "just now" : Self.ageFormatter.localizedString(for: $0.time, relativeTo: now)
        }
        let syncing = live.status == "Live syncing" && !stale
        let status = live.status == "Live syncing" && stale ? "Waiting for new readings" : live.status
        return VStack(alignment: .leading, spacing: 2) {
            Text("Heart rate").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(reading.map { String($0.bpm) } ?? "—")
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stale ? .secondary : .primary)
                Text("bpm").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Label(status, systemImage: syncing ? "checkmark.icloud" : "icloud")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(syncing ? Color.green : Color.secondary)
            }
            if let ageText {
                Text(stale ? "Last reading · \(ageText)" : "Updated \(ageText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Headline, plain-language detail, an optional System Settings button, and
/// scan diagnostics while looking for the strap.
@MainActor
struct StatusHeader: View {
    let status: MenuStatus
    let onUseBroadcaster: @MainActor (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(status.headline).font(.headline)
            } icon: {
                if status.isProblem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let diagnostics = status.diagnostics {
                Text(diagnostics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(status.broadcasters.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = status.action, let title = status.actionTitle {
                Button(title) { perform(action) }
                    .padding(.top, 2)
            }
        }
    }

    private func perform(_ action: MenuStatus.Action) {
        switch action {
        case .openSettings(let link): SystemSettings.open(link)
        case .useBroadcaster(let id): onUseBroadcaster(id)
        }
    }
}

/// Meeting-only mode without Calendar access: the app cannot see meetings,
/// so it listens continuously until access is granted.
struct CalendarAccessNeeded: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Calendar access needed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text("Meetspike can't see your meetings, so it is listening continuously. Allow full Calendar access to listen only around meetings.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Calendar Privacy Settings") { SystemSettings.open(.calendarPrivacy) }
        }
    }
}

@MainActor
enum SystemSettings {
    static func open(_ link: SystemSettingsLink) {
        if !NSWorkspace.shared.open(link.url), let root = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(root)
        }
    }
}
