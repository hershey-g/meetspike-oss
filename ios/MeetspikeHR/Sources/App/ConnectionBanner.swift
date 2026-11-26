import MeetspikeHRCore
import SwiftUI

/// The strip under the status bar when Meetspike cannot be reached or Access turned the phone away.
/// Tracks do not draw this themselves: they call `AppEnvironment.report(_:)` and `noteLoaded(_:)`.
struct ConnectionBanner: View {
    let issue: ConnectionIssue
    var openMore: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        layout {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if issue == .accessRejected {
                Button("Open Menu", action: openMore)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.5)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch issue {
        case .offline: "wifi.slash"
        case .accessRejected: "lock.trianglebadge.exclamationmark"
        }
    }

    private var tint: Color {
        switch issue {
        case .offline: Theme.warn
        case .accessRejected: Theme.bad
        }
    }

    private var title: String {
        switch issue {
        case .offline: "You're offline"
        case .accessRejected: "Sign-in needed"
        }
    }

    private var detail: String? {
        switch issue {
        case .offline(let date):
            date.map { "Showing data from \($0.formatted(date: .abbreviated, time: .shortened))" }
        case .accessRejected:
            "Meetspike turned this phone away. Check your Access token."
        }
    }
}

/// The banners under the navigation bar of a tab: the connection issue, and the update strip.
///
/// Apply this (`.tabBanners(_:)`) to the root content inside each tab's `NavigationStack`. A safe-area inset set
/// outside the `TabView` is drawn over the navigation bar and hides the title and the More gear.
struct TabBanners: ViewModifier {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var model: PhoneModel
    let tab: AppTab

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let issue = env.issue {
                    ConnectionBanner(issue: issue) { env.openMore() }
                }
                if let build = model.availableUpdate, tab != .live {
                    UpdateBanner(build: build)
                }
            }
        }
    }
}

extension View {
    func tabBanners(_ tab: AppTab) -> some View { modifier(TabBanners(tab: tab)) }
}

/// Slim "update available" strip for tabs other than Live (the Live tab keeps its own card).
struct UpdateBanner: View {
    let build: Int
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text("Update available. Build \(build) is in TestFlight.")
                .font(.footnote)
            Spacer(minLength: 8)
            Button("Update") {
                openURL(AppUpdate.testFlightURL) { opened in
                    if !opened { openURL(AppUpdate.testFlightInstallURL) }
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .accessibilityElement(children: .combine)
    }
}
