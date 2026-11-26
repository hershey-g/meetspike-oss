import MeetspikeHRCore
import SwiftUI

/// Where a People row goes.
struct PersonRoute: Hashable {
    let email: String
    let name: String?
}

/// Where a company row or chip goes.
struct CompanyRoute: Hashable {
    let domain: String
    let name: String?

    init(domain: String, name: String?) {
        self.domain = domain
        self.name = name
    }

    init(_ tag: CompanyTag) {
        self.init(domain: tag.domain, name: tag.name)
    }
}

/// A page pushed on the People stack: a person or a company.
enum PeopleRoute: Hashable {
    case person(PersonRoute)
    case company(CompanyRoute)
}

/// The People tab: a searchable list of who you met, or of the companies they work at, with the average
/// next-morning score for each, and a page per person or company. Mirrors the People page in public/app.js
/// (renderPeople) and public/people-ui.js.
struct PeopleScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var store = PeopleRangeStore()
    @State private var path: [PeopleRoute] = []
    /// People or Companies. Saved on the phone. `-people.mode companies` opens on Companies in a debug run.
    @AppStorage("people.mode") private var modeRaw = PeopleMode.people.rawValue
    /// Debug launch arguments open their page once.
    @State private var debugOpened = false

    private var mode: Binding<PeopleMode> {
        Binding(get: { PeopleMode(rawValue: modeRaw) ?? .people }, set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch mode.wrappedValue {
                case .people: PeopleListView(store: store)
                case .companies: CompaniesListView(store: store)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { PeopleModePicker(mode: mode) }
            .navigationDestination(for: PeopleRoute.self) { route in
                // A new identity per page, so a route replaced in place (another tab opened someone else)
                // never paints the previous page, not even for a frame.
                switch route {
                case .person(let person):
                    PersonView(route: person, store: store)
                        .id("person:\(person.email)")
                case .company(let company):
                    CompanyView(route: company, store: store)
                        .id("company:\(company.domain)")
                }
            }
        }
        .onAppear {
            publishSpan()
            #if DEBUG
            // `-openCompany <domain>` or `-openPerson <email>` opens a page on launch, for screenshots.
            if !debugOpened {
                debugOpened = true
                if let domain = UserDefaults.standard.string(forKey: "openCompany") {
                    path = [.company(CompanyRoute(domain: domain, name: nil))]
                } else if let email = UserDefaults.standard.string(forKey: "openPerson") {
                    path = [.person(PersonRoute(email: email, name: nil))]
                }
            }
            #endif
            consumePendingPerson()
            consumePendingCompany()
        }
        .onChange(of: activeSpan) { publishSpan() }
        .onChange(of: env.pendingPerson) { consumePendingPerson() }
        .onChange(of: env.pendingCompany) { consumePendingCompany() }
    }

    /// Another tab asked for a company (`env.openCompany`). Show the Companies list under its page.
    private func consumePendingCompany() {
        guard let tag = env.pendingCompany else { return }
        env.pendingCompany = nil
        modeRaw = PeopleMode.companies.rawValue
        if case .company(let shown) = path.last, shown.domain == tag.domain { return }
        path = [.company(CompanyRoute(tag))]
    }

    private var activeSpan: DatesSpan { PeopleLogic.dates(for: store.range, today: env.today) }

    /// Tell the Ask tab which dates People is showing, so it can scope the chat to them.
    private func publishSpan() {
        let span = activeSpan
        if env.peopleSpan != span { env.peopleSpan = span }
    }

    /// Another tab asked for a person (`env.openPerson`). Show that page, then clear the request.
    private func consumePendingPerson() {
        guard let email = env.pendingPerson else { return }
        env.pendingPerson = nil
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .person(let shown) = path.last, shown.email.lowercased() == trimmed.lowercased() { return }
        path = [.person(PersonRoute(email: trimmed, name: nil))]
    }
}

/// Adds the range menu to the toolbar and the custom range sheet behind it.
struct PeopleRangeControls: ViewModifier {
    @ObservedObject var store: PeopleRangeStore
    let today: String
    @State private var showCustom = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PeopleRangeMenu(store: store, today: today) { showCustom = true }
                }
            }
            .sheet(isPresented: $showCustom) {
                PeopleCustomRangeSheet(
                    today: today,
                    initial: PeopleLogic.dates(for: store.range, today: today)
                ) { span in
                    store.range = .custom(start: span.start, end: span.end)
                }
            }
    }
}

extension View {
    func peopleRangeControls(store: PeopleRangeStore, today: String) -> some View {
        modifier(PeopleRangeControls(store: store, today: today))
    }
}

private enum PeopleSearchState {
    case idle
    case searching
    case results([PersonMatch])
    case failed(String)
}

struct PeopleListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var store: PeopleRangeStore

    @State private var load: PeopleLoad<PeopleResponse> = .loading
    /// A refresh failed with the list on screen and the banner does not say so. Cleared by the next success.
    @State private var refreshNotice: String?
    @State private var gate = PeopleLoadGate()
    @State private var query = ""
    @State private var search = PeopleSearchState.idle
    @State private var cache = PeopleSearchCache()
    /// The connection `cache` and `search` belong to.
    @State private var searchConnection = 0

    private struct LoadKey: Equatable {
        let span: DatesSpan
        /// `AppEnvironment.connectionRevision`: a new Meetspike URL or token loads again.
        let connection: Int
    }

    private struct SearchKey: Equatable {
        let query: String
        let connection: Int
    }

    private var span: DatesSpan { PeopleLogic.dates(for: store.range, today: env.today) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        content
            .background(Theme.background.ignoresSafeArea())
            .tabBanners(.people)
            .navigationTitle("People")
            .moreButton()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or email")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .peopleRangeControls(store: store, today: env.today)
            .task(id: LoadKey(span: span, connection: env.connectionRevision)) {
                await loadPeople(showSpinner: gate.showsSpinner(for: span, connection: env.connectionRevision))
            }
            .task(id: SearchKey(query: query, connection: env.connectionRevision)) { await runSearch() }
            .onChange(of: env.connectionRevision) { resetForNewConnection() }
            .refreshable {
                cache.removeAll()
                await loadPeople(showSpinner: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDataRefreshed)) { _ in
                Task { await loadPeople(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDisplaySourcesChanged)) { _ in
                cache.removeAll()
                Task { await loadPeople(showSpinner: false) }
            }
            // A meeting was left out, put back or moved: the people lists change.
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeMeetingsChanged)) { _ in
                cache.removeAll()
                Task { await loadPeople(showSpinner: false) }
            }
    }

    @ViewBuilder private var content: some View {
        if !trimmedQuery.isEmpty {
            searchList
        } else {
            switch load {
            case .loading:
                ProgressView("Loading \(store.scopeLabel(today: env.today).lowercased())")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                scrollable {
                    PeopleMessage(
                        symbol: "exclamationmark.triangle", title: "Couldn't load people", detail: message,
                        actionTitle: "Try again"
                    ) { Task { await loadPeople(showSpinner: true) } }
                }
            case .offline:
                scrollable {
                    PeopleMessage(
                        symbol: "wifi.slash", title: "You're offline",
                        detail: "No saved people for this range yet. Connect and pull to refresh.",
                        actionTitle: "Try again"
                    ) { Task { await loadPeople(showSpinner: true) } }
                }
            case .accessRejected:
                scrollable {
                    PeopleMessage(
                        symbol: "lock.trianglebadge.exclamationmark", title: "Sign-in needed",
                        detail: "Meetspike turned this phone away. Check your Access token in Menu.",
                        actionTitle: "Open Menu"
                    ) { env.openMore() }
                }
            case .loaded(let response, let savedAt):
                peopleList(response, savedAt: savedAt)
            }
        }
    }

    private func scrollable<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        ScrollView { body() }
    }

    // MARK: People list

    private func peopleList(_ response: PeopleResponse, savedAt: Date?) -> some View {
        let wearable = response.wearable
        let hasScores = wearable?.source != nil
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let savedAt { PeopleOfflineNote(savedAt: savedAt) }
                    if let refreshNotice { PeopleRefreshNote(message: refreshNotice) }
                    Text(store.scopeLabel(today: env.today))
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    if hasScores, let wearable {
                        Text(leadText(wearable: wearable, usual: response.usualRecovery))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            Section {
                if response.people.isEmpty {
                    Text("No meetings with other people in this range.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Theme.card)
                } else {
                    ForEach(response.people) { person in
                        NavigationLink(value: PeopleRoute.person(PersonRoute(email: person.email, name: person.name))) {
                            PersonRow(
                                person: person, wearable: hasScores ? wearable : nil,
                                // The header names the score and source only when it shows "Your usual ...".
                                shortLabel: response.usualRecovery != nil
                            )
                        }
                        .listRowBackground(Theme.card)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(.compact)
    }

    private func leadText(wearable: WearableInfo, usual: Double?) -> String {
        var text = "Who you met and how you woke up the morning after."
        if let usual { text += " Your usual \(wearable.scoreLabel) is \(Int(usual.rounded()))%." }
        return text
    }

    // MARK: Search results

    private var searchList: some View {
        List {
            switch search {
            case .idle, .searching:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            case .failed(let message):
                Text(message).foregroundStyle(Theme.bad).listRowBackground(Color.clear)
            case .results(let people):
                Section {
                    ForEach(people) { match in
                        NavigationLink(value: PeopleRoute.person(PersonRoute(email: match.email, name: match.name))) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.name ?? match.email).font(.body.weight(.semibold))
                                if match.name != nil {
                                    Text(match.email).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Theme.card)
                    }
                } footer: {
                    Text(people.isEmpty
                        ? "No matching people."
                        : "\(people.count) matching \(people.count == 1 ? "person" : "people").")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Loading

    /// The Meetspike URL or a token changed: nothing held belongs to the old server (people, search answers,
    /// the loaded gate). The load and search tasks restart on the new revision.
    private func resetForNewConnection() {
        cache = PeopleSearchCache()
        searchConnection = env.connectionRevision
        search = .idle
        gate.clear()
        load = .loading
        refreshNotice = nil
    }

    /// `showSpinner: false` is a quiet refresh: what is on screen stays until the new answer arrives.
    private func loadPeople(showSpinner: Bool) async {
        let span = span
        // Read before the API: an answer for an older connection is dropped below.
        let connection = env.connectionRevision
        let api = env.api
        if showSpinner {
            load = .loading
            refreshNotice = nil
            gate.clear()
        }
        do {
            let loaded = try await api.loadPeople(start: span.start, end: span.end)
            if Task.isCancelled || span != self.span || connection != env.connectionRevision { return }
            env.noteLoaded(loaded)
            load = .loaded(loaded.value, savedAt: loaded.isFromCache ? loaded.savedAt : nil)
            refreshNotice = nil
            gate.markLoaded(span, connection: connection)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled || span != self.span || connection != env.connectionRevision { return }
            // Keep what is on screen when a refresh fails and there is something to show. The banner (this
            // screen draws it) covers offline and access rejected; anything else gets a note in the list.
            if !showSpinner, case .loaded = load {
                let covered = env.report(error)
                refreshNotice = PeopleLogic.refreshNotice(error: error, coveredByBanner: covered)
                return
            }
            refreshNotice = nil
            load = peopleFailure(error, env: env)
            gate.clear()
        }
    }

    /// Search as you type, after about 20 ms like the web. Answers are reused for 5 minutes.
    private func runSearch() async {
        let connection = env.connectionRevision
        let api = env.api
        if searchConnection != connection {
            // Answers saved for the old server must not be reused.
            cache = PeopleSearchCache()
            searchConnection = connection
        }
        let text = trimmedQuery
        guard !text.isEmpty else {
            search = .idle
            return
        }
        do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
        if let hit = cache.people(for: text, now: Date()) {
            search = .results(hit)
            return
        }
        search = .searching
        do {
            let people = try await api.searchPeople(query: text)
            if Task.isCancelled || connection != env.connectionRevision { return }
            cache.store(people, for: text, now: Date())
            env.noteOnline()
            search = .results(people)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled || connection != env.connectionRevision { return }
            env.report(error)
            switch error as? APIError {
            case .offline: search = .failed("You're offline. Search needs a connection.")
            case .accessRejected: search = .failed("Sign-in needed. Check your Access token in Menu.")
            default: search = .failed((error as? APIError)?.message ?? "Search failed. Try again.")
            }
        }
    }
}

/// One row: avatar, name, "N meetings on N days", and the average next-morning score.
private struct PersonRow: View {
    let person: PersonSummary
    /// nil when there is no wearable, so no score column at all.
    let wearable: WearableInfo?
    /// Show "Recovery" instead of "Recovery (WHOOP)" because the list header already names the source.
    var shortLabel = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The caption under the score. The accessibility label always uses the full `scoreLabel`.
    private func caption(_ wearable: WearableInfo) -> String {
        if shortLabel, let word = wearable.readinessLabel, !word.isEmpty { return word }
        return wearable.scoreLabel
    }

    private var displayName: String { person.name ?? person.email }
    private var nameIsEmail: Bool { person.name == nil }
    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        PeopleAvatar(name: person.name, email: person.email)
                        identity
                    }
                    score
                }
            } else {
                HStack(spacing: 12) {
                    PeopleAvatar(name: person.name, email: person.email)
                    identity.layoutPriority(1)
                    Spacer(minLength: 8)
                    score
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: displayName)
                .font(.body.weight(.semibold))
                .lineLimit(stacked ? nil : 1)
                .truncationMode(nameIsEmail ? .middle : .tail)
                .allowsTightening(true)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(stacked ? nil : 1)
                .minimumScaleFactor(stacked ? 1 : 0.8)
        }
    }

    @ViewBuilder private var score: some View {
        if let wearable {
            if let avg = person.avg {
                let band = TodayLogic.recoveryBand(score: avg, wearable: wearable.kind)
                VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                    Text("\(Int(avg.rounded()))%").font(.body.weight(.semibold))
                    Text(caption(wearable))
                        .font(.caption)
                        .foregroundStyle((band?.tone ?? .none).peopleColor)
                        .multilineTextAlignment(stacked ? .leading : .trailing)
                        .lineLimit(stacked ? nil : 1)
                        .minimumScaleFactor(stacked ? 1 : 0.8)
                }
                .fixedSize(horizontal: !stacked, vertical: false)
            } else {
                Text("no scores").font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: !stacked, vertical: false)
            }
        }
    }

    private var detail: String {
        "\(PeopleFormat.plural(person.meetings ?? 0, "meeting")) on \(PeopleFormat.plural(person.days ?? 0, "day"))"
    }

    private var accessibilityText: String {
        var text = "\(displayName), \(detail)"
        if let wearable {
            if let avg = person.avg {
                let word = TodayLogic.recoveryBand(score: avg, wearable: wearable.kind)?.word
                text += ", average \(wearable.scoreLabel) \(Int(avg.rounded())) percent" + (word.map { ", \($0)" } ?? "")
            } else {
                text += ", no scores"
            }
        }
        return text
    }
}
