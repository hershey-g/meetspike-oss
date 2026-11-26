import Foundation

/// What changed in each iPhone build, newest first. The single source: the What's new sheet reads it, and
/// ios/release-testflight.py reads this file (the `Release(...)` blocks below, so keep their shape) to fill in
/// TestFlight's "What to Test". Short, plain, one line per item, no em dashes.
public enum ReleaseNotes {
    public struct Release: Equatable, Sendable {
        public let build: Int
        public let version: String
        /// "yyyy-MM-dd"
        public let date: String
        public let items: [String]

        public init(build: Int, version: String, date: String, items: [String]) {
            self.build = build
            self.version = version
            self.date = date
            self.items = items
        }

        /// "Nov 25, 2026" for the sheet. The raw text if it is not a day.
        public var displayDate: String {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "UTC")
            parser.dateFormat = "yyyy-MM-dd"
            guard let day = parser.date(from: date) else { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: day)
        }
    }

    public static let all: [Release] = [
        Release(build: 12, version: "1.2", date: "2026-11-25", items: [
            "Lock Screen heart rate is now During meetings: it ends with the meeting. Change it in Menu, This iPhone.",
            "The Dynamic Island now shows how much time is left in the meeting.",
        ]),
        Release(build: 11, version: "1.2", date: "2026-11-25", items: [
            "Broadcast reminders only come when no heart rate is coming in.",
            "Your server checks first, so nothing is sent while you are live on your iPhone or Mac.",
            "The note to turn off HR Broadcast comes only if it is still on.",
            "Listening starts five minutes before a meeting.",
        ]),
        Release(build: 10, version: "1.2", date: "2026-11-25", items: [
            "Ask now uses all your history. It ranks the dates you pick and compares them with every day on record.",
            "A line under each answer says which dates it ranked.",
            "All time button at the top of Ask, and Ask over all time under an answer.",
            "Tables in answers fit the screen. Wide ones turn into one card per row.",
            "Each wearable gets its own usual and its own heavy day comparison.",
        ]),
        Release(build: 9, version: "1.2", date: "2026-11-25", items: [
            "Say what really happened. Tap a meeting and pick I didn't join, or Don't link this meeting.",
            "Pick Just this one or All of them for meetings that repeat.",
            "Fix meeting times. Set a start and end, or go back to the calendar's.",
            "Still going and Ended now, on the Live tab and the Lock Screen.",
            "If your Mac never saw Zoom for a meeting, you get a quiet note: Looks like you didn't join.",
            "Meetings you didn't join are left out of scores and averages. Undo any time.",
            "Heart rate listening follows the real meeting times.",
            "Changes made offline are sent when you are back online.",
        ]),
        Release(build: 8, version: "1.1", date: "2026-11-25", items: [
            "Companies on the People tab, with a page for each one.",
            "Live tab: your heart rate against your resting rate, with the meeting on the chart.",
            "Heart rate on the Lock Screen and Dynamic Island during meetings.",
            "Next meeting widgets for the Home and Lock Screen.",
            "Crash reports. If the app crashes or freezes, it sends a report to your own Meetspike server.",
            "Reports hold no meeting names and no heart rates. Turn them off in the menu any time.",
            "Dark only. The app now looks the same everywhere, including alerts and the keyboard.",
            "What's new shows up here after an update, and the menu has an About section.",
            "New icon: a meeting clock with a heartbeat line.",
            "Built by Hershey Goldberger.",
        ]),
        Release(build: 7, version: "1.0", date: "2026-11-25", items: [
            "Faster. Pages no longer freeze while a chart loads.",
            "Heart rate charts keep showing while they reload.",
            "A page that fails to load tries once more after a refresh.",
        ]),
        Release(build: 6, version: "1.0", date: "2026-11-24", items: [
            "Fixes for build 5 bugs: sleep time, the date bar and the sync message.",
            "People and the menu show the right person and the right sync result.",
        ]),
        Release(build: 5, version: "1.0", date: "2026-11-24", items: [
            "All the web features on your phone: Today, Dates, People and Ask.",
            "Heart rate charts for every meeting.",
            "A menu for sync, settings and your Meetspike link.",
        ]),
        Release(build: 4, version: "1.0", date: "2026-11-24", items: [
            "New icon: a phone with calendar rows and a live heart rate line.",
            "The app is now called Meetspike.",
        ]),
    ]

    /// What to show after an update. nil (a fresh install) shows nothing. Otherwise the releases newer than the last
    /// one seen, up to the build running now, newest first.
    public static func unseen(lastSeen: Int?, current: Int) -> [Release] {
        guard let lastSeen else { return [] }
        return all.filter { $0.build > lastSeen && $0.build <= current }
    }

    /// "- item" lines for TestFlight's What to Test, or nil if that build has no note.
    public static func notesText(build: Int) -> String? {
        guard let release = all.first(where: { $0.build == build }) else { return nil }
        return release.items.map { "- \($0)" }.joined(separator: "\n")
    }
}

/// Decides whether the "What's new" sheet is due, from what the app stored.
public enum WhatsNew {
    /// The last build whose notes were shown on a phone that has run an earlier build of the app.
    public static let lastBuildBeforeTracking = 7

    /// The build to compare against. A stored value wins. With none, an install that already existed (it has a saved
    /// Meetspike link or finished onboarding) is updating from build 7, which did not store anything; a fresh install
    /// has seen nothing and gets no sheet.
    public static func lastSeen(stored: Int?, existingInstall: Bool) -> Int? {
        if let stored { return stored }
        return existingInstall ? lastBuildBeforeTracking : nil
    }

    /// What to show now, and what to store as seen. A fresh install stores the current build and shows nothing.
    public static func decide(stored: Int?, existingInstall: Bool, current: Int) -> (releases: [ReleaseNotes.Release], store: Int) {
        let seen = lastSeen(stored: stored, existingInstall: existingInstall)
        let releases = ReleaseNotes.unseen(lastSeen: seen, current: current)
        // Never store a lower build than one already seen, so a downgrade and back does not show the notes again.
        return (releases, max(current, stored ?? 0))
    }
}
