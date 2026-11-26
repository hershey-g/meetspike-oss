import AppKit
import MeetspikeHRCore
import SwiftUI

/// One reusable window for the setup walkthrough. It opens at launch until the
/// first valid reading arrives, and from the menu or Settings at any time.
@MainActor
enum WalkthroughWindow {
    private static var window: NSWindow?

    static func show(logger: Logger) {
        let window = window ?? makeWindow(logger: logger)
        Self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    private static func makeWindow(logger: Logger) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: WalkthroughView(logger: logger)))
        window.title = "Set Up Meetspike"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 720))
        window.center()
        return window
    }
}

@MainActor
struct WalkthroughView: View {
    @ObservedObject var logger: Logger

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let snapshot = logger.snapshot(now: context.date, includeReading: logger.showsWhoop)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Walkthrough.title).font(.title2.bold())
                        Text(Walkthrough.intro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(Walkthrough.steps.enumerated()), id: \.element.id) { index, step in
                            StepRow(number: index + 1, step: step)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live status").font(.headline)
                        ForEach(SetupCheck.all(snapshot)) { check in
                            CheckRow(check: check)
                        }
                        StatusHeader(status: MenuStatus(snapshot), onUseBroadcaster: logger.useBroadcaster)
                            .padding(.top, 4)
                    }

                    Divider()

                    footer(finished: Walkthrough.isFinished(snapshot))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 720)
    }

    @ViewBuilder
    private func footer(finished: Bool) -> some View {
        HStack(alignment: .center) {
            if finished {
                Label("You're all set. Meetspike is receiving heart rate.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("This guide opens each time Meetspike starts until the first heart rate reading arrives. You can reopen it from Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(finished ? "Done" : "Close") { WalkthroughWindow.close() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let step: Walkthrough.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if step.isWarning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.body.weight(.semibold))
                Text(step.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CheckRow: View {
    let check: SetupCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateDescription))
    }

    @ViewBuilder
    private var icon: some View {
        switch check.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .inProgress:
            Image(systemName: "ellipsis.circle").foregroundStyle(.blue)
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var stateDescription: String {
        switch check.state {
        case .done: "Done"
        case .inProgress: "In progress"
        case .waiting: "Not yet"
        case .problem: "Needs attention"
        }
    }
}
