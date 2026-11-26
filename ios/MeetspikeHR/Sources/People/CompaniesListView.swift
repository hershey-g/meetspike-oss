import MeetspikeHRCore
import SwiftUI

private enum CompanySearchState {
    case idle
    case searching
    case results([CompanyMatch])
    case failed(String)
}

/// The Companies side of the People tab: companies tagged from attendee email domains, with how many meetings and
/// people, the average next-morning score and the heart rate pattern for each. Same range, search and loading rules
/// as `PeopleListView`.
struct CompaniesListView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var store: PeopleRangeStore

    @State private var load: PeopleLoad<CompaniesResponse> = .loading
    @State private var refreshNotice: String?
    @State private var gate = PeopleLoadGate()
    @State private var query = ""
    @State private var search = CompanySearchState.idle
    @State private var cache = CompanySearchCache()
    @State private var searchConnection = 0
    @AppStorage("companies.sort") private var sortRaw = CompanySort.meetings.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct LoadKey: Equatable {
        let span: DatesSpan
        let connection: Int
    }

    private struct SearchKey: Equatable {
        let query: String
        let connection: Int
    }

    private var span: DatesSpan { PeopleLogic.dates(for: store.range, today: env.today) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sort: CompanySort { CompanySort(rawValue: sortRaw) ?? .meetings }

    var body: some View {
        content
            .background(Theme.background.ignoresSafeArea())
            .tabBanners(.people)
            .navigationTitle("Companies")
            .moreButton()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Company or domain")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .peopleRangeControls(store: store, today: env.today)
            .task(id: LoadKey(span: span, connection: env.connectionRevision)) {
                await loadCompanies(showSpinner: gate.showsSpinner(for: span, connection: env.connectionRevision))
            }
            .task(id: SearchKey(query: query, connection: env.connectionRevision)) { await runSearch() }
            .onChange(of: env.connectionRevision) { resetForNewConnection() }
            .refreshable {
                cache.removeAll()
                await loadCompanies(showSpinner: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDataRefreshed)) { _ in
                Task { await loadCompanies(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDisplaySourcesChanged)) { _ in
                cache.removeAll()
                Task { await loadCompanies(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeCompanyRenamed)) { _ in
                // Saved search answers carry the old name.
                cache.removeAll()
                Task { await loadCompanies(showSpinner: false) }
                if !trimmedQuery.isEmpty { Task { await runSearch() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeMeetingsChanged)) { _ in
                cache.removeAll()
                Task { await loadCompanies(showSpinner: false) }
                if !trimmedQuery.isEmpty { Task { await runSearch() } }
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
                ScrollView {
                    PeopleMessage(
                        symbol: "exclamationmark.triangle", title: "Couldn't load companies", detail: message,
                        actionTitle: "Try again"
                    ) { Task { await loadCompanies(showSpinner: true) } }
                }
            case .offline:
                ScrollView {
                    PeopleMessage(
                        symbol: "wifi.slash", title: "You're offline",
                        detail: "No saved companies for this range yet. Connect and pull to refresh.",
                        actionTitle: "Try again"
                    ) { Task { await loadCompanies(showSpinner: true) } }
                }
            case .accessRejected:
                ScrollView {
                    PeopleMessage(
                        symbol: "lock.trianglebadge.exclamationmark", title: "Sign-in needed",
                        detail: "Meetspike turned this phone away. Check your Access token in Menu.",
                        actionTitle: "Open Menu"
                    ) { env.openMore() }
                }
            case .loaded(let response, let savedAt):
                companyList(response, savedAt: savedAt)
            }
        }
    }

    // MARK: List

    private func companyList(_ response: CompaniesResponse, savedAt: Date?) -> some View {
        let wearable = response.wearable
        let hasScores = wearable?.source != nil
        let companies = CompanyLogic.sorted(response.companies, by: sort)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let savedAt { PeopleOfflineNote(savedAt: savedAt) }
                    if let refreshNotice { PeopleRefreshNote(message: refreshNotice) }
                    let header = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    header {
                        Text(store.scopeLabel(today: env.today))
                            .font(.footnote.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        sortMenu
                    }
                    Text(leadText(wearable: hasScores ? wearable : nil, usual: response.usualRecovery))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            Section {
                if companies.isEmpty {
                    Text("No meetings with other companies in this range.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Theme.card)
                } else {
                    ForEach(companies) { company in
                        NavigationLink(value: PeopleRoute.company(CompanyRoute(domain: company.domain, name: company.name))) {
                            CompanyRow(company: company, wearable: hasScores ? wearable : nil, shortLabel: response.usualRecovery != nil)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listSectionSpacing(.compact)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(CompanySort.allCases, id: \.self) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityLabel("Sort, \(sort.label)")
    }

    private func leadText(wearable: WearableInfo?, usual: Double?) -> String {
        var text = "Companies you met, from your guests' email addresses."
        if let wearable, let usual { text += " Your usual \(wearable.scoreLabel) is \(Int(usual.rounded()))%." }
        return text
    }

    // MARK: Search

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
            case .results(let companies):
                Section {
                    ForEach(companies) { match in
                        NavigationLink(value: PeopleRoute.company(CompanyRoute(match))) {
                            HStack(spacing: 12) {
                                CompanyBadge(name: match.name, domain: match.domain)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: match.displayName).font(.body.weight(.semibold))
                                    Text(verbatim: match.domain).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Theme.card)
                    }
                } footer: {
                    Text(companies.isEmpty
                        ? "No matching companies."
                        : "\(companies.count) matching \(companies.count == 1 ? "company" : "companies").")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Loading

    private func resetForNewConnection() {
        cache = CompanySearchCache()
        searchConnection = env.connectionRevision
        search = .idle
        gate.clear()
        load = .loading
        refreshNotice = nil
    }

    private func loadCompanies(showSpinner: Bool) async {
        let span = span
        let connection = env.connectionRevision
        let api = env.api
        if showSpinner {
            load = .loading
            refreshNotice = nil
            gate.clear()
        }
        do {
            let loaded = try await api.loadCompanies(start: span.start, end: span.end)
            if Task.isCancelled || span != self.span || connection != env.connectionRevision { return }
            env.noteLoaded(loaded)
            load = .loaded(loaded.value, savedAt: loaded.isFromCache ? loaded.savedAt : nil)
            refreshNotice = nil
            gate.markLoaded(span, connection: connection)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled || span != self.span || connection != env.connectionRevision { return }
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

    private func runSearch() async {
        let connection = env.connectionRevision
        let api = env.api
        if searchConnection != connection {
            cache = CompanySearchCache()
            searchConnection = connection
        }
        let text = trimmedQuery
        guard !text.isEmpty else {
            search = .idle
            return
        }
        do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
        if let hit = cache.companies(for: text, now: Date()) {
            search = .results(hit)
            return
        }
        search = .searching
        do {
            let companies = try await api.searchCompanies(query: text)
            if Task.isCancelled || connection != env.connectionRevision { return }
            cache.store(companies, for: text, now: Date())
            env.noteOnline()
            search = .results(companies)
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

/// One company: badge, name, domain, "N meetings · N people", the heart rate pattern, and the average next-morning score.
private struct CompanyRow: View {
    let company: CompanySummary
    let wearable: WearableInfo?
    var shortLabel = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var stacked: Bool { typeSize.isAccessibilitySize }

    private func caption(_ wearable: WearableInfo) -> String {
        if shortLabel, let word = wearable.readinessLabel, !word.isEmpty { return word }
        return wearable.scoreLabel
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        CompanyBadge(name: company.name, domain: company.domain)
                        identity
                    }
                    score
                }
            } else {
                HStack(spacing: 12) {
                    CompanyBadge(name: company.name, domain: company.domain)
                    identity.layoutPriority(1)
                    Spacer(minLength: 8)
                    score
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var hrLine: String? {
        wearable?.hasIntradayHr == true ? CompanyLogic.hrSummary(company.trend) : nil
    }

    private var hrTone: TodayTone {
        switch company.trend?.badge {
        case "often spikes you": return .bad
        case "usually restored": return .good
        default: return .none
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: company.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(stacked ? nil : 1)
            Text(verbatim: company.domain)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(stacked ? nil : 1)
                .truncationMode(.middle)
            Text(CompanyLogic.detail(company))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(stacked ? nil : 1)
                .minimumScaleFactor(stacked ? 1 : 0.8)
            if let hrLine {
                Text(hrLine)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(hrTone.peopleColor)
                    .lineLimit(stacked ? nil : 1)
            }
        }
    }

    @ViewBuilder private var score: some View {
        if let wearable {
            if let avg = company.avg {
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

    private var accessibilityText: String {
        var text = "\(company.displayName), \(company.domain), \(CompanyLogic.detail(company).replacingOccurrences(of: " \u{B7} ", with: ", "))"
        if let hrLine { text += ", \(hrLine)" }
        if let wearable {
            if let avg = company.avg {
                let word = TodayLogic.recoveryBand(score: avg, wearable: wearable.kind)?.word
                text += ", average \(wearable.scoreLabel) \(Int(avg.rounded())) percent" + (word.map { ", \($0)" } ?? "")
            } else {
                text += ", no scores"
            }
        }
        return text
    }
}
