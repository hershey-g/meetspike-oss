import MeetspikeHRCore
import SwiftUI
import UIKit

/// "Still going" and "Ended now" on a card for the meeting that is running. "Still going" adds 15 minutes each tap,
/// up to 4 hours past the calendar's end. They show only while they apply and the phone knows which meeting this is.
/// The same two actions as the Lock Screen buttons (`LiveAdjustIntents`).
struct LiveAdjustButtons: View {
    let target: LiveAdjustTarget?
    let now: Date

    @EnvironmentObject private var env: AppEnvironment
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        let offer = LiveAdjust.offer(target, now: now)
        if offer.stillGoing || offer.endedNow {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if offer.stillGoing { button("Still going", symbol: "plus.circle", kind: .stillGoing) }
                    if offer.endedNow { button("Ended now", symbol: "stop.circle", kind: .endedNow) }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
    }

    private func button(_ title: String, symbol: String, kind: LiveAdjustKind) -> some View {
        Button {
            run(kind)
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.inset, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityHint(kind == .stillGoing ? "Adds 15 minutes to this meeting" : "Ends this meeting now")
    }

    private func run(_ kind: LiveAdjustKind) {
        busy = true
        message = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let target = target
        Task {
            let result = await env.choices.liveAdjust(target, kind)
            message = result.message
            busy = false
            UIAccessibility.post(notification: .announcement, argument: result.message ?? (kind == .stillGoing ? "Added 15 minutes." : "Ended."))
        }
    }
}
