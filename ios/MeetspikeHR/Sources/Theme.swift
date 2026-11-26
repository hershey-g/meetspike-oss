import MeetspikeHRCore
import SwiftUI
import UIKit

/// Colors follow the Meetspike web app in dark mode (public/app.css). The app is dark only: one color each.
enum Theme {
    static let background = color(0x15191E)
    static let card = color(0x23282F)
    static let inset = color(0x2C323A)
    static let accent = color(0x6CB8F5)
    // Prominent buttons use white labels, so keep their fill darker than links.
    static let buttonFill = color(0x1F6FB3)
    static let good = color(0x4ADE6A)
    static let warn = color(0xF5C542)
    static let bad = color(0xFF7373)

    // Live tab heart rate: the app icon's green ring, then amber and red as BPM climbs over resting.
    // Each stays at least 4.5:1 for the badge text on its own fill (10%) over the tinted card (8%), the hardest
    // place it sits. Check again before changing a value or either opacity in Dashboard.
    static let spike = color(0x4ADE6A)
    static let spikeElevated = color(0xFBBF24)
    static let spikeHigh = color(0xFF8080)

    static func spikeColor(_ level: SpikeLevel) -> Color {
        switch level {
        case .normal: spike
        case .elevated: spikeElevated
        case .high: spikeHigh
        }
    }

    static func tone(_ tone: PhoneHeartState.Tone) -> Color {
        switch tone {
        case .live: good
        case .working: warn
        case .idle: .secondary
        case .problem: bad
        }
    }

    private static func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The rounded panel every dashboard section sits in.
struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
}

/// A small capsule with a colored dot, for example "● Live".
struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.inset, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

enum SystemSettings {
    @MainActor static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
