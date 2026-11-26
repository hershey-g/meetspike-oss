import MeetspikeHRCore
import SwiftUI

/// Five tabs: Today, Dates, People, Ask and Live (the broadcast Dashboard, unchanged). More is a sheet, opened by
/// the gear button on each tab (`AppEnvironment.openMore()`).
/// Tab screens get `AppEnvironment` and `PhoneModel` as environment objects.
struct RootTabView: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var env: AppEnvironment
    /// Releases to show in the What's new sheet, set once after an update.
    @State private var whatsNew: WhatsNewItem?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $env.selectedTab) {
            TodayScreen()
                .tabItem { Label(AppTab.today.title, systemImage: AppTab.today.systemImage) }
                .tag(AppTab.today)
            DatesScreen()
                .tabItem { Label(AppTab.dates.title, systemImage: AppTab.dates.systemImage) }
                .tag(AppTab.dates)
            PeopleScreen()
                .tabItem { Label(AppTab.people.title, systemImage: AppTab.people.systemImage) }
                .tag(AppTab.people)
            AskScreen()
                .tabItem { Label(AppTab.ask.title, systemImage: AppTab.ask.systemImage) }
                .tag(AppTab.ask)
            Dashboard(model: model, live: model.liveSync, replay: model.replay)
                .tabItem { Label(AppTab.live.title, systemImage: AppTab.live.systemImage) }
                .tag(AppTab.live)
        }
        .environmentObject(env)
        .environmentObject(model)
        .tint(Theme.accent)
        .sheet(isPresented: $env.showMore) {
            MoreScreen()
                .environmentObject(env)
                .environmentObject(model)
                .tint(Theme.accent)
        }
        // The connection and update banners are not drawn here: an inset outside the TabView covers the
        // navigation bars. Each tab adds them under its own bar with `.tabBanners(_:)`.
        .onChange(of: model.onboardingComplete) { _, done in
            // Onboarding is presented by the Live tab. When it finishes, land on Today.
            if done && env.selectedTab == .live { env.selectedTab = .today }
            if done { showWhatsNewIfDue() }
        }
        .onChange(of: env.selectedTab) { _, tab in Crumbs.shared.record(.tab(tab.crumb)) }
        .onChange(of: env.showMore) { _, open in if open { Crumbs.shared.record(.menuOpen) } }
        .sheet(item: $whatsNew, onDismiss: { WhatsNewStore.markSeen() }) { item in
            WhatsNewSheet(releases: item.releases) { whatsNew = nil }
                .tint(Theme.accent)
        }
        .task { showWhatsNewIfDue() }
        // Each time the app comes forward: send any meeting choice that was waiting, and read today's meetings so
        // listening follows what the Worker says. Neither blocks anything, and a failure keeps what is saved.
        .task(id: scenePhase) {
            guard scenePhase == .active, !model.isDemo, model.onboardingComplete else { return }
            await env.choices.sendWaiting(force: true)
            await env.choices.refreshListening(today: env.today)
        }
    }

    /// After an update, once. Never on a fresh install, never over onboarding, and never in demo screenshots unless
    /// `-demoWhatsNew YES` asks (Debug builds).
    private func showWhatsNewIfDue() {
        guard whatsNew == nil else { return }
        var demoArgument = false
        #if DEBUG
        demoArgument = UserDefaults.standard.bool(forKey: "demoWhatsNew")
        #endif
        if model.isDemo && !demoArgument { return }
        // Asked first even during onboarding: a fresh install records the current build here, before the finished
        // onboarding makes it look like an old install.
        let releases = WhatsNewStore.due(demoLaunchArgument: model.isDemo && demoArgument)
        guard !releases.isEmpty, model.onboardingComplete || demoArgument else { return }
        whatsNew = WhatsNewItem(releases: releases)
    }
}

private struct WhatsNewItem: Identifiable {
    let id = UUID()
    let releases: [ReleaseNotes.Release]
}
