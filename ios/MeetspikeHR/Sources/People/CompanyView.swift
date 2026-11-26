import MeetspikeHRCore
import SwiftUI

/// One company: average next-morning score, heart rate in meetings with its people, the people you met there and
/// the meetings. Mirrors `PersonView`, keyed on the email domain.
struct CompanyView: View {
    @EnvironmentObject private var env: AppEnvironment
    let route: CompanyRoute
    @ObservedObject var store: PeopleRangeStore

    @State private var load: PeopleLoad<CompanyMeetingsResponse> = .loading
    @State private var refreshNotice: String?
    @State private var gate = PeopleLoadGate()
    @State private var pager = PeoplePager()
    /// The domain `load` belongs to. Nothing but the spinner is drawn unless this is the route on screen.
    @State private var loadedDomain: String?
    /// A name saved in this session, shown before the reload comes back.
    @State private var renamed: String?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var renameError: String?

    private struct LoadKey: Equatable {
        let domain: String
        let span: DatesSpan
        let connection: Int
    }

    private var span: DatesSpan { PeopleLogic.dates(for: store.range, today: env.today) }
    private var title: String {
        if let renamed { return renamed }
        if case .loaded(let company, _) = load, let name = company.name, !name.isEmpty { return name }
        return route.name ?? route.domain
    }

    var body: some View {
        content
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .peopleRangeControls(store: store, today: env.today)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        draftName = title
                        renameError = nil
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Rename company")
                }
            }
            .alert("Rename company", isPresented: $showRename) {
                TextField("Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                Button("Save") { Task { await rename(to: draftName) } }
                Button("Use domain name") { Task { await rename(to: nil) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shown for \(route.domain) everywhere in Meetspike.")
            }
            .task(id: LoadKey(domain: route.domain, span: span, connection: env.connectionRevision)) {
                let connection = env.connectionRevision
                let reload = PeopleLogic.shouldReloadPerson(
                    loadedEmail: loadedDomain, loadedSpan: gate.loadedSpan, email: route.domain, span: span)
                let fresh = reload || gate.showsSpinner(for: span, connection: connection)
                if fresh || gate.resetsPager(for: span, connection: connection) { pager.reset() }
                await loadCompany(showSpinner: fresh)
            }
            .onChange(of: env.connectionRevision) {
                load = .loading
                loadedDomain = nil
                refreshNotice = nil
                gate.clear()
                pager.reset()
            }
            .refreshable { await loadCompany(showSpinner: false) }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDataRefreshed)) { _ in
                Task { await loadCompany(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDisplaySourcesChanged)) { _ in
                Task { await loadCompany(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeCompanyRenamed)) { _ in
                Task { await loadCompany(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeMeetingsChanged)) { _ in
                Task { await loadCompany(showSpinner: false) }
            }
    }

    @ViewBuilder private var content: some View {
        let shown: PeopleLoad<CompanyMeetingsResponse> = loadedDomain == route.domain ? load : .loading
        switch shown {
        case .loading:
            ProgressView("Loading \(store.scopeLabel(today: env.today).lowercased())")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ScrollView {
                PeopleMessage(
                    symbol: "exclamationmark.triangle", title: "Couldn't load \(title)", detail: message,
                    actionTitle: "Try again"
                ) { Task { await loadCompany(showSpinner: true) } }
            }
        case .offline:
            ScrollView {
                PeopleMessage(
                    symbol: "wifi.slash", title: "You're offline",
                    detail: "No saved meetings with \(title) for this range yet.",
                    actionTitle: "Try again"
                ) { Task { await loadCompany(showSpinner: true) } }
            }
        case .accessRejected:
            ScrollView {
                PeopleMessage(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Sign-in needed",
                    detail: "Meetspike turned this phone away. Check your Access token in Menu.",
                    actionTitle: "Open Menu"
                ) { env.openMore() }
            }
        case .loaded(let company, let savedAt):
            ScrollView {
                VStack(spacing: 16) {
                    if let savedAt { PeopleOfflineNote(savedAt: savedAt) }
                    if let refreshNotice { PeopleRefreshNote(message: refreshNotice) }
                    if let renameError { PeopleRefreshNote(message: renameError) }
                    CompanySummaryCard(company: company, title: title, domain: route.domain, scope: store.scopeLabel(today: env.today))
                    if !company.people.isEmpty { peopleCard(company.people) }
                    meetingsCard(company)
                }
                .padding(16)
            }
        }
    }

    // MARK: People

    private func peopleCard(_ people: [CompanyPerson]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("People")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    if index > 0 { Divider() }
                    NavigationLink(value: PeopleRoute.person(PersonRoute(email: person.email, name: person.name))) {
                        HStack(spacing: 12) {
                            PeopleAvatar(name: person.name, email: person.email)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: person.name ?? person.email)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(PeopleFormat.plural(person.meetings ?? 0, "meeting"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens their page")
                }
            }
        }
        .card()
    }

    // MARK: Meetings

    private func meetingsCard(_ company: CompanyMeetingsResponse) -> some View {
        let meetings = company.meetings
        let zone = company.timeZone.flatMap(TimeZone.init(identifier:)) ?? env.timeZone
        return VStack(alignment: .leading, spacing: 12) {
            Text("Meetings")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if meetings.isEmpty {
                Text("No meetings with this company in this range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    let visible = Array(pager.visible(meetings))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { Divider() }
                        PersonMeetingRow(
                            meeting: meeting, wearable: company.wearable, zone: zone, today: env.today,
                            people: CompanyLogic.attendeeLine(meeting.companyAttendees)
                        ) {
                            if let day = meeting.day { env.openDay(day) }
                        }
                        // Other companies in the same meeting.
                        CompanyChips(companies: meeting.companies, excluding: route.domain)
                            .peopleChipInset(hasChips: meeting.companies.contains { $0.domain != route.domain })
                    }
                }
                if pager.hasMore(total: meetings.count) {
                    Button {
                        pager.showMore()
                    } label: {
                        Text("Show more meetings").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .card()
    }

    // MARK: Loading

    private func loadCompany(showSpinner: Bool) async {
        let span = span
        let domain = route.domain
        let connection = env.connectionRevision
        let api = env.api
        if showSpinner {
            load = .loading
            loadedDomain = nil
            refreshNotice = nil
            gate.clear()
        }
        func accepts() -> Bool {
            !Task.isCancelled && connection == env.connectionRevision
                && PeopleLogic.acceptsPersonAnswer(
                    answerEmail: domain, answerSpan: span, showingEmail: route.domain, showingSpan: self.span)
        }
        do {
            let loaded = try await api.loadCompanyMeetings(domain: domain, start: span.start, end: span.end, compact: true)
            if !accepts() { return }
            env.noteLoaded(loaded)
            load = .loaded(loaded.value, savedAt: loaded.isFromCache ? loaded.savedAt : nil)
            loadedDomain = domain
            renamed = nil
            refreshNotice = nil
            gate.markLoaded(span, connection: connection)
        } catch is CancellationError {
            return
        } catch {
            if !accepts() { return }
            if !showSpinner, case .loaded = load {
                env.report(error)
                refreshNotice = PeopleLogic.refreshNotice(error: error, coveredByBanner: false)
                return
            }
            refreshNotice = nil
            load = peopleFailure(error, env: env)
            loadedDomain = domain
            gate.clear()
        }
    }

    private func rename(to name: String?) async {
        let domain = route.domain
        do {
            let result = try await env.api.renameCompany(domain: domain, name: name)
            renameError = nil
            renamed = result.name
            // Pages that show company names reload. Not a sync, so Today's auto-refresh timer is left alone.
            NotificationCenter.default.postCompanyRenamed()
        } catch {
            env.report(error)
            renameError = (error as? APIError)?.message ?? "Couldn't rename. Try again."
        }
    }
}

/// Name, domain, the average next-morning score, who you met there and the heart rate lines.
private struct CompanySummaryCard: View {
    let company: CompanyMeetingsResponse
    let title: String
    let domain: String
    let scope: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let wearable = company.wearable
        let label = wearable?.source != nil ? (wearable?.scoreLabel ?? "Morning score") : "Morning score"
        let average = PeopleLogic.perDayAverage(company.meetings)
        VStack(alignment: .leading, spacing: 10) {
            Text(scope)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            // Large text stacks the badge over the name, so the name keeps the full width.
            let stacked = typeSize.isAccessibilitySize
            let header = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            header {
                CompanyBadge(name: title, domain: domain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: domain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let avg = average.average {
                let band = TodayLogic.recoveryBand(score: Double(avg), wearable: wearable?.kind)
                let scoreLayout = stacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                scoreLayout {
                    Text("\(avg)%")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle((band?.tone ?? .none).peopleColor)
                    Text("average next-morning \(label)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Text(lead(label: label, average: average))
                .font(.subheadline)
            PeopleTrendLines(trends: company.trendsByHrSource)
        }
        .card()
    }

    private func lead(label: String, average: PeoplePerDayAverage) -> String {
        var text = "\(PeopleFormat.plural(company.meetings.count, "meeting")) with \(PeopleFormat.plural(company.people.count, "person", many: "people"))."
        if let avg = average.average {
            text += " On mornings after a meeting with them you woke at \(avg)% \(label) on average, over \(PeopleFormat.plural(average.mornings, "morning"))."
        }
        if average.isThin { text += " Only a few mornings, so this is a hint, not a pattern." }
        return text
    }
}
