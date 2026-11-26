import Combine
import Foundation
import MeetspikeHRCore

/// The five tabs, in order. `live` is the existing broadcast Dashboard. More is not a tab: it is a sheet
/// (`AppEnvironment.showMore`, `openMore()`) opened from the gear button on every tab.
enum AppTab: String, CaseIterable, Identifiable {
    case today, dates, people, ask, live
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .dates: "Dates"
        case .people: "People"
        case .ask: "Ask"
        case .live: "Live"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .dates: "calendar"
        case .people: "person.2"
        case .ask: "sparkles"
        case .live: "heart.text.square"
        }
    }
}

/// What the connection banner shows. Screens report into it through `AppEnvironment`.
enum ConnectionIssue: Equatable {
    /// No network. `dataFrom` is when the data on screen was saved, when it came from the offline cache.
    case offline(dataFrom: Date?)
    /// Cloudflare Access turned the request away: the token is wrong, expired or missing.
    case accessRejected
}

/// App-wide state the tab screens share: the API, the selected day and span, the server's today, and the
/// connection banner. Built from the saved settings, or from bundled fixtures in `-demo data` mode.
///
/// Screens read `api` and call `report(_:)` / `noteLoaded(_:)` so the banner stays truthful. They do not
/// keep their own copy of the origin or credentials.
@MainActor
final class AppEnvironment: ObservableObject {
    /// Best guess of the Worker's time zone until a response says otherwise.
    static let defaultTimeZone = TimeZone(identifier: "America/New_York") ?? .current

    @Published var selectedTab: AppTab {
        // willSet runs before the change is published, so a lazily created tab reads the right
        // `previousTab` in its first `.task`.
        willSet { if newValue != selectedTab { previousTab = selectedTab } }
    }
    /// The tab that was selected before the current one. Nil until the tab changes once.
    @Published private(set) var previousTab: AppTab?
    /// The API for the saved settings. Replaced when settings change. Never nil: `UnconfiguredAPI` throws `.notConfigured`.
    @Published private(set) var api: MeetspikeAPI
    /// True in `-demo data` mode: the API serves bundled fixtures and nothing leaves the phone.
    @Published private(set) var isDemoData: Bool
    /// The day shown on Today. Never after `today`.
    @Published var selectedDay: String
    /// The span shown on Dates. Never ends after `today`.
    @Published var datesSpan: DatesSpan
    /// The range People is showing (its preset or custom range). Nil until People sets it. Other tabs (Ask) read it.
    @Published var peopleSpan: DatesSpan?
    /// True while the More sheet is up. `openMore()` sets it; the sheet's Done button and `openAskKeyForm()` clear it.
    @Published var showMore: Bool = false
    /// Sticky flag set by `openAskKeyForm()`. The Ask tab shows its key form, then sets this to false.
    @Published var pendingAskKeyForm: Bool = false
    /// Email of a person another tab asked to open (`openPerson(_:)`). The People tab pushes the page, then sets this to nil.
    @Published var pendingPerson: String?
    /// A company another tab asked to open (`openCompany(_:)`). The People tab pushes its page, then sets this to nil.
    @Published var pendingCompany: CompanyTag?
    /// The server's today (`ViewResponse.today`). The phone's clock only seeds it until the first answer.
    @Published private(set) var today: String
    @Published private(set) var timeZone: TimeZone = AppEnvironment.defaultTimeZone
    /// Set when saved settings could not be read from the Keychain.
    @Published private(set) var configurationNote: String?
    @Published private(set) var issue: ConnectionIssue?
    /// Bumped by `rebuild()` after `api` holds the new connection (the Meetspike URL or a token changed). `$api`
    /// publishes in willSet, so a screen that reloads when `api` publishes can still read the old API: key reloads on
    /// this instead. Starts at 0 and only goes up.
    @Published private(set) var connectionRevision = 0

    private let model: PhoneModel
    private var subscription: AnyCancellable?

    /// The person's meeting choices: sends them, keeps them when offline, and tells the phone what to listen to.
    private(set) lazy var choices = MeetingChoices(
        api: { [unowned self] in self.api },
        apply: { [weak model] meetings in model?.setRemoteMeetings(meetings) },
        report: { [weak self] error in self?.report(error) },
        timeZone: { [unowned self] in self.timeZone })

    init(model: PhoneModel) {
        self.model = model
        let demo = Self.demoAPI(for: model)
        isDemoData = demo != nil
        let seed = demo != nil ? DemoAPI.demoToday : DayMath.today(in: Self.defaultTimeZone)
        today = seed
        selectedDay = seed
        datesSpan = DatesSpan(start: DayMath.addDays(seed, -6), end: seed)
        selectedTab = Self.startTab(model: model)
        showMore = Self.startsWithMore()
        let (live, note) = Self.liveAPI(origin: model.origin)
        api = demo ?? live
        configurationNote = demo == nil ? note : nil
        subscription = model.$settingsRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Builds the API again from the saved settings (after the Meetspike URL or tokens change).
    func rebuild() {
        guard !isDemoData else { return }
        let (live, note) = Self.liveAPI(origin: model.origin)
        api = live
        configurationNote = note
        issue = nil
        connectionRevision += 1
    }

    // MARK: Shared date state

    /// Records the server's today through `DayState.noting`: an offline copy never moves anything, a later day
    /// rolls the selected day and span that were on today, and an earlier fresh day clamps them. `isFromCache` is
    /// required so no caller can forget it.
    func noteToday(_ day: String, isFromCache: Bool, timeZone name: String? = nil) {
        guard DayMath.isValid(day), !isFromCache else { return }
        if let name, let zone = TimeZone(identifier: name), zone != timeZone { timeZone = zone }
        let before = DayState(today: today, selectedDay: selectedDay, span: datesSpan)
        let after = before.noting(day, isFromCache: isFromCache)
        if after.today != today { today = after.today }
        if after.selectedDay != selectedDay { selectedDay = after.selectedDay }
        if after.span != datesSpan { datesSpan = after.span }
    }

    /// Show one day on Today.
    func openDay(_ day: String) {
        selectedDay = min(day, today)
        selectedTab = .today
    }

    /// Show a span on Dates, or one day on Today when the span is a single day.
    func openSpan(_ span: DatesSpan) {
        if span.isSingleDay { return openDay(span.start) }
        datesSpan = DatesSpan(start: span.start, end: min(span.end, today))
        selectedTab = .dates
    }

    /// Show one person's page: switches to People and sets `pendingPerson`. People consumes and clears it.
    func openPerson(_ email: String) {
        pendingPerson = email
        selectedTab = .people
    }

    /// Show one company's page: switches to People (Companies) and sets `pendingCompany`. People consumes and clears it.
    func openCompany(_ company: CompanyTag) {
        pendingCompany = company
        selectedTab = .people
    }

    /// Show the More sheet (sync, display, connections, AI key, phone settings) over the current tab.
    func openMore() {
        showMore = true
    }

    /// Show the Ask tab's key form: closes the More sheet, sets `pendingAskKeyForm`, switches to Ask, and posts
    /// `.meetspikeOpenAskKeyForm` for an Ask tab that is already on screen. Ask consumes the flag and sets it back to false.
    func openAskKeyForm() {
        showMore = false
        pendingAskKeyForm = true
        selectedTab = .ask
        NotificationCenter.default.postOpenAskKeyForm()
    }

    // MARK: Connection banner

    /// Reports a failed call. Returns true when the banner covers it (offline, sign-in rejected), so the screen
    /// can stay quiet; false means the screen should show the error itself (`APIError.message`).
    @discardableResult
    func report(_ error: Error) -> Bool {
        switch error as? APIError {
        case .offline:
            if case .offline = issue { return true }
            issue = .offline(dataFrom: nil)
            return true
        case .accessRejected:
            setIssue(.accessRejected)
            return true
        default:
            return false
        }
    }

    /// A load came back. From the offline cache: say when the data was saved. Fresh: clear the banner.
    func noteLoaded<Value>(_ loaded: Loaded<Value>) {
        setIssue(loaded.isFromCache ? .offline(dataFrom: loaded.savedAt) : nil)
        if !loaded.isFromCache, !choices.waiting.isEmpty { Task { await choices.sendWaiting() } }
    }

    /// Any successful network call that does not go through `Loaded`. Runs after every poll and load.
    func noteOnline() {
        setIssue(nil)
        // Back online: send any meeting choice that was waiting.
        if !choices.waiting.isEmpty { Task { await choices.sendWaiting() } }
    }

    /// `issue` publishes on every assignment, equal or not, and every screen observes it, so only assign a change.
    private func setIssue(_ next: ConnectionIssue?) {
        if issue != next { issue = next }
    }

    // MARK: Building

    private static func demoAPI(for model: PhoneModel) -> MeetspikeAPI? {
        #if DEBUG
        guard model.isDemo else { return nil }
        guard let api = DemoAPI.bundled() else { return nil }
        // Debug launch arguments for screenshotting empty and error states (demo mode only):
        // `-demoFailure offline|rejected|http|notConfigured`, `-demoEmpty YES`.
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "demoFailure") {
        case "offline": api.failure = .offline
        case "rejected": api.failure = .accessRejected
        case "http": api.failure = .http(status: 500, message: "Meetspike hit an error. Try again.")
        case "notConfigured": api.failure = .notConfigured
        default: break
        }
        if defaults.bool(forKey: "demoEmpty") { api.showsEmptyDays = true }
        return api
        #else
        return nil
        #endif
    }

    private static func startTab(model: PhoneModel) -> AppTab {
        #if DEBUG
        // `-tab more` has no tab of its own: it starts on the default tab with the More sheet up (`startsWithMore`).
        if let name = UserDefaults.standard.string(forKey: "tab"), let tab = AppTab(rawValue: name) { return tab }
        if model.isDemo { return DemoScenario.current == .data ? .today : .live }
        #endif
        // First launch: onboarding is presented by the Live tab's Dashboard, so start there.
        return model.onboardingComplete ? .today : .live
    }

    /// Debug launch argument `-tab more`: open the More sheet at launch.
    private static func startsWithMore() -> Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "tab") == "more"
        #else
        return false
        #endif
    }

    private static func liveAPI(origin: String) -> (MeetspikeAPI, String?) {
        guard let destination = Destination(origin) else { return (UnconfiguredAPI(), nil) }
        let credentials: Credentials?
        do {
            credentials = try CredentialStore.load()
        } catch {
            return (UnconfiguredAPI(), "Couldn't read your saved settings. Save them again in Menu.")
        }
        guard credentials != nil else { return (UnconfiguredAPI(), nil) }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let crumbFilter = RequestCrumbFilter()
        let client = APIClient(
            destination: destination, credentials: credentials, userAgent: "MeetspikeHR/\(version) (\(build))",
            cache: ResponseCache.standard(origin: destination.origin),
            // Crash crumbs: the route template, status and time of each request. Never the path itself.
            // Live polling is written only when it fails or its status changes.
            observer: { path, status, milliseconds in
                let route = CrumbRoute.name(path: path)
                guard crumbFilter.shouldRecord(route: route, status: status) else { return }
                Crumbs.shared.record(.request(route: route, status: status, ms: milliseconds))
            }
        )
        return (client, nil)
    }
}
