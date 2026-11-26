import SwiftUI

/// The menu (three lines) button in the leading top bar of every tab. Opens the Menu sheet.
struct MoreButton: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Button { env.openMore() } label: { Image(systemName: "line.3.horizontal") }
            .accessibilityLabel("Menu")
    }
}

extension View {
    /// Adds the Menu button to the leading top bar.
    func moreButton() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { MoreButton() }
        }
    }
}
