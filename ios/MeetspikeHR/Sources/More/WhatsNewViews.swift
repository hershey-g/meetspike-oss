import MeetspikeHRCore
import SwiftUI

/// Where the last build whose notes were shown is kept, and what decides whether to show them.
enum WhatsNewStore {
    static let key = "lastSeenBuild"

    static var currentBuild: Int {
        Int((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "") ?? 0
    }

    /// An install that already ran an earlier build has a saved Meetspike URL or has finished onboarding.
    private static var isExistingInstall: Bool {
        let defaults = UserDefaults.standard
        return !(defaults.string(forKey: "workerOrigin") ?? "").isEmpty || defaults.bool(forKey: "onboardingComplete")
    }

    /// What to show now. Stores the current build when there is nothing to show (a fresh install, or nothing new), so
    /// the next update is measured from here. A sheet that is due is stored only once it has been dismissed.
    static func due(demoLaunchArgument: Bool = false) -> [ReleaseNotes.Release] {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: key) as? Int
        #if DEBUG
        // `-demoWhatsNew YES` in demo mode: show the sheet as if updating from build 7. Stores nothing.
        if demoLaunchArgument { return ReleaseNotes.unseen(lastSeen: WhatsNew.lastBuildBeforeTracking, current: currentBuild) }
        #endif
        let decision = WhatsNew.decide(stored: stored, existingInstall: isExistingInstall, current: currentBuild)
        if decision.releases.isEmpty, stored != decision.store { defaults.set(decision.store, forKey: key) }
        return decision.releases
    }

    static func markSeen() {
        UserDefaults.standard.set(max(currentBuild, UserDefaults.standard.integer(forKey: key)), forKey: key)
    }
}

/// One release: version, build and date, then its items.
private struct ReleaseBlock: View {
    let release: ReleaseNotes.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(release.version) (\(release.build))").font(.headline)
                Spacer()
                Text(release.displayDate).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(release.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\u{2022}").foregroundStyle(.secondary)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown once after an update, with the releases the person has not seen.
struct WhatsNewSheet: View {
    let releases: [ReleaseNotes.Release]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(releases, id: \.build) { release in
                        ReleaseBlock(release: release)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("What's new")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(action: onDone) {
                    Text("Got it").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.buttonFill)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
    }
}

/// The menu's "What's new": every release, newest first.
struct ReleaseNotesList: View {
    var body: some View {
        List {
            ForEach(ReleaseNotes.all, id: \.build) { release in
                ReleaseBlock(release: release).padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(.inline)
    }
}
