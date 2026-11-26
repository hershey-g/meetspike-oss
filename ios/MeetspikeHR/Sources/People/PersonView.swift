import MeetspikeHRCore
import SwiftUI

/// One person: average next-morning score, heart rate in meetings with them, and their meetings.
/// Mirrors renderPerson and personHrLine in public/app.js.
struct PersonView: View {
    @EnvironmentObject private var env: AppEnvironment
    let route: PersonRoute
    @ObservedObject var store: PeopleRangeStore

    @State private var load: PeopleLoad<PersonMeetingsResponse> = .loading
    /// A refresh failed with the page on screen. Cleared by the next success.
    @State private var refreshNotice: String?
    @State private var gate = PeopleLoadGate()
    @State private var pager = PeoplePager()
    /// The person `load` belongs to. Nothing but the spinner is drawn unless this is the route on screen.
    @State private var loadedEmail: String?

    private struct LoadKey: Equatable {
        let email: String
        let span: DatesSpan
        /// `AppEnvironment.connectionRevision`: a new Meetspike URL or token loads again.
        let connection: Int
    }

    private var span: DatesSpan { PeopleLogic.dates(for: store.range, today: env.today) }
    private var title: String {
        if case .loaded(let person, _) = load, let name = person.name, !name.isEmpty { return name }
        return route.name ?? route.email
    }

    var body: some View {
        content
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .peopleRangeControls(store: store, today: env.today)
            .task(id: LoadKey(email: route.email, span: span, connection: env.connectionRevision)) {
                // Same person, span and connection as what is on screen (back from another tab or page): keep it
                // and the pager, refresh quietly. Anything else drops what is held and shows the spinner.
                let connection = env.connectionRevision
                let reload = PeopleLogic.shouldReloadPerson(
                    loadedEmail: loadedEmail, loadedSpan: gate.loadedSpan, email: route.email, span: span)
                let fresh = reload || gate.showsSpinner(for: span, connection: connection)
                if fresh || gate.resetsPager(for: span, connection: connection) { pager.reset() }
                await loadPerson(showSpinner: fresh)
            }
            // The Meetspike URL or a token changed: what is held came from the old server. The task above restarts
            // on the new revision and loads again.
            .onChange(of: env.connectionRevision) {
                load = .loading
                loadedEmail = nil
                refreshNotice = nil
                gate.clear()
                pager.reset()
            }
            .refreshable { await loadPerson(showSpinner: false) }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDataRefreshed)) { _ in
                Task { await loadPerson(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDisplaySourcesChanged)) { _ in
                Task { await loadPerson(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeCompanyRenamed)) { _ in
                // Company chips on the meetings show the new name.
                Task { await loadPerson(showSpinner: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeMeetingsChanged)) { _ in
                Task { await loadPerson(showSpinner: false) }
            }
    }

    @ViewBuilder private var content: some View {
        // Another person's data is never drawn, even for a frame: show the spinner until the load is for this route.
        let shown: PeopleLoad<PersonMeetingsResponse> = loadedEmail == route.email ? load : .loading
        switch shown {
        case .loading:
            ProgressView("Loading \(store.scopeLabel(today: env.today).lowercased())")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ScrollView {
                PeopleMessage(
                    symbol: "exclamationmark.triangle", title: "Couldn't load \(title)", detail: message,
                    actionTitle: "Try again"
                ) { Task { await loadPerson(showSpinner: true) } }
            }
        case .offline:
            ScrollView {
                PeopleMessage(
                    symbol: "wifi.slash", title: "You're offline",
                    detail: "No saved meetings with \(title) for this range yet.",
                    actionTitle: "Try again"
                ) { Task { await loadPerson(showSpinner: true) } }
            }
        case .accessRejected:
            ScrollView {
                PeopleMessage(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Sign-in needed",
                    detail: "Meetspike turned this phone away. Check your Access token in Menu.",
                    actionTitle: "Open Menu"
                ) { env.openMore() }
            }
        case .loaded(let person, let savedAt):
            ScrollView {
                VStack(spacing: 16) {
                    if let savedAt { PeopleOfflineNote(savedAt: savedAt) }
                    if let refreshNotice { PeopleRefreshNote(message: refreshNotice) }
                    PersonSummaryCard(person: person, route: route, scope: store.scopeLabel(today: env.today))
                    meetingsCard(person)
                }
                .padding(16)
            }
        }
    }

    // MARK: Meetings

    private func meetingsCard(_ person: PersonMeetingsResponse) -> some View {
        let meetings = person.meetings
        let wearable = person.wearable
        let zone = person.timeZone.flatMap(TimeZone.init(identifier:)) ?? env.timeZone
        return VStack(alignment: .leading, spacing: 12) {
            Text("Meetings")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if meetings.isEmpty {
                Text("No meetings with this person in this range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    let visible = Array(pager.visible(meetings))
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { Divider() }
                        PersonMeetingRow(meeting: meeting, wearable: wearable, zone: zone, today: env.today) {
                            if let day = meeting.day { env.openDay(day) }
                        }
                        CompanyChips(companies: meeting.companies)
                            .peopleChipInset(hasChips: !meeting.companies.isEmpty)
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

    /// `showSpinner: false` is a quiet refresh: what is on screen stays until the new answer arrives.
    private func loadPerson(showSpinner: Bool) async {
        let span = span
        let email = route.email
        // Read before the API: an answer for an older connection is dropped below.
        let connection = env.connectionRevision
        let api = env.api
        if showSpinner {
            load = .loading
            loadedEmail = nil
            refreshNotice = nil
            gate.clear()
        }
        // The answer is for the person, span and connection on screen now, and the task was not cancelled.
        func accepts() -> Bool {
            !Task.isCancelled && connection == env.connectionRevision
                && PeopleLogic.acceptsPersonAnswer(
                    answerEmail: email, answerSpan: span, showingEmail: route.email, showingSpan: self.span)
        }
        do {
            let loaded = try await api.loadPersonMeetings(
                email: email, start: span.start, end: span.end, compact: true
            )
            if !accepts() { return }
            env.noteLoaded(loaded)
            load = .loaded(loaded.value, savedAt: loaded.isFromCache ? loaded.savedAt : nil)
            loadedEmail = email
            refreshNotice = nil
            gate.markLoaded(span, connection: connection)
        } catch is CancellationError {
            return
        } catch {
            if !accepts() { return }
            if !showSpinner, case .loaded = load {
                env.report(error)
                // PersonView is pushed inside the People stack and `.tabBanners` sits on the list root, so no
                // banner shows here: the note is always needed. A banner would also cover the nav bar's title.
                refreshNotice = PeopleLogic.refreshNotice(error: error, coveredByBanner: false)
                return
            }
            refreshNotice = nil
            load = peopleFailure(error, env: env)
            loadedEmail = email
            gate.clear()
        }
    }
}

/// Name, meeting count, the average next-morning score and the heart rate lines.
private struct PersonSummaryCard: View {
    let person: PersonMeetingsResponse
    let route: PersonRoute
    let scope: String

    var body: some View {
        let wearable = person.wearable
        let label = wearable?.source != nil ? (wearable?.scoreLabel ?? "Morning score") : "Morning score"
        let average = PeopleLogic.perDayAverage(person.meetings)
        VStack(alignment: .leading, spacing: 10) {
            Text(scope)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(person.name ?? route.name ?? person.email ?? route.email)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if let avg = average.average {
                let band = TodayLogic.recoveryBand(score: Double(avg), wearable: wearable?.kind)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            PeopleTrendLines(trends: person.trendsByHrSource)
        }
        .card()
    }

    private func lead(label: String, average: PeoplePerDayAverage) -> String {
        var text = "\(PeopleFormat.plural(person.meetings.count, "meeting"))."
        if let avg = average.average {
            text += " On mornings after a meeting with them you woke at \(avg)% \(label) on average, over \(PeopleFormat.plural(average.mornings, "morning"))."
        }
        if average.isThin { text += " Only a few mornings, so this is a hint, not a pattern." }
        return text
    }
}

/// A meeting in the list: day, title, time, and either the heart rate pill or the next-morning score pill.
struct PersonMeetingRow: View {
    let meeting: PersonMeeting
    let wearable: WearableInfo?
    let zone: TimeZone
    let today: String
    /// An extra line under the time, for example who from a company was there.
    var people: String? = nil
    var open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var showHr: Bool { wearable?.hasIntradayHr == true }
    private var scoreLabel: String { wearable?.scoreLabel ?? "Morning score" }

    var body: some View {
        Button(action: open) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                Text(PeopleFormat.shortDay(meeting.day, today: today))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: typeSize.isAccessibilitySize ? 0 : 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title ?? "Untitled")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    if let people, !people.isEmpty {
                        Text(verbatim: people).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                pill
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(meeting.day == nil)
        .accessibilityHint("Opens that day")
    }

    private var subtitle: String {
        var bits = [PeopleFormat.clock(fromLocal: meeting.startLocal)].filter { !$0.isEmpty }
        if showHr, let hr = meeting.hrStress, hr.coverage == "ok", let mean = hr.meanBpm {
            bits.append("\(TodayLogic.hrProviderLabel(hr)) \(Int(mean.rounded())) bpm")
        }
        if showHr, let score = meeting.nextReadinessScore {
            bits.append("\(Int(score.rounded()))% \(scoreLabel)")
        }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder private var pill: some View {
        if showHr {
            let pill = TodayLogic.zonePill(meeting.hrStress, timeZone: zone)
            PeoplePill(text: pill.text, tone: pill.tone, accessibilityText: [pill.text, pill.note].compactMap { $0 }.joined(separator: ". "))
        } else if let score = meeting.nextReadinessScore {
            let band = TodayLogic.recoveryBand(score: score, wearable: wearable?.kind)
            let rounded = Int(score.rounded())
            PeoplePill(
                text: "\(rounded)% · \(scoreLabel)", tone: band?.tone ?? .none,
                accessibilityText: "\(rounded) percent \(scoreLabel)" + (band.map { ", \($0.word)" } ?? "")
            )
        } else if wearable?.source != nil {
            PeoplePill(text: "No score", tone: .none)
        }
    }
}
