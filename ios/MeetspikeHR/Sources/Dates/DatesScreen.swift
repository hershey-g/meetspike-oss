import Combine
import MeetspikeHRCore
import OSLog
import SwiftUI

private let datesLog = Logger(subsystem: "com.hersheyg.meetspike.hr", category: "dates")

// MARK: Model

/// Loads the range for the selected span. Paints the saved copy first, then the network, and falls back to the
/// saved copy only when offline (`loadView`). Every failure is logged with its error code only.
@MainActor
final class DatesModel: ObservableObject {
    enum Failure: Equatable {
        case offline
        case accessRejected
        case notConfigured
        case other(String)
    }

    enum Phase {
        case loading
        case loaded(ViewResponse)
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .loading
    /// Set when the data on screen came from the offline copy.
    @Published private(set) var savedAt: Date?
    /// A refresh failed while older data for the same span stays on screen.
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false

    private var shown: DatesSpan?
    private var token = 0

    func load(span: DatesSpan, api: MeetspikeAPI, env: AppEnvironment) async {
        token += 1
        let mine = token
        isRefreshing = true
        defer { if mine == token { isRefreshing = false } }

        if shown != span {
            phase = .loading
            savedAt = nil
            shown = nil
            if let cached = await api.cachedView(start: span.start, end: span.end) {
                guard mine == token else { return }
                phase = .loaded(cached.value)
                shown = span
            }
        }
        do {
            let loaded = try await api.loadView(start: span.start, end: span.end)
            guard mine == token else { return }
            phase = .loaded(loaded.value)
            shown = span
            savedAt = loaded.isFromCache ? loaded.savedAt : nil
            refreshError = nil
            env.noteLoaded(loaded)
            if DatesLogic.shouldNoteToday(isFromCache: loaded.isFromCache), let today = loaded.value.today {
                env.noteToday(today, isFromCache: loaded.isFromCache, timeZone: loaded.value.timeZone)
            }
        } catch is CancellationError {
            return
        } catch {
            guard mine == token else { return }
            // Only the error case or HTTP status is public. No dates, no Worker text.
            datesLog.error("Dates load failed: \(DatesLogic.logCode(error), privacy: .public)")
            env.report(error)
            let failure: Failure
            switch error as? APIError {
            case .offline: failure = .offline
            case .accessRejected: failure = .accessRejected
            case .notConfigured: failure = .notConfigured
            case let apiError?: failure = .other(apiError.message)
            case nil: failure = .other("Something went wrong. Try again.")
            }
            if shown == span, case .loaded = phase {
                // Keep what we have; say the refresh failed.
                refreshError = Self.text(for: failure)
            } else {
                shown = nil
                savedAt = nil
                phase = .failed(failure)
            }
        }
    }

    static func text(for failure: Failure) -> String {
        switch failure {
        case .offline: "Can't reach Meetspike. Check your connection."
        case .accessRejected: "Sign-in needed. Check your Access token in Menu."
        case .notConfigured: "Add your Meetspike URL in Menu."
        case .other(let message): message
        }
    }
}

// MARK: Screen

struct DatesScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model = DatesModel()
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Dates")
            .navigationBarTitleDisplayMode(.inline)
            .moreButton()
            .safeAreaInset(edge: .top, spacing: 0) {
                DatesBar(
                    span: env.datesSpan, today: env.today,
                    previous: { env.datesSpan = DatesLogic.shift(env.datesSpan, direction: -1, today: env.today) },
                    next: { env.datesSpan = DatesLogic.shift(env.datesSpan, direction: 1, today: env.today) },
                    pick: { showPicker = true }
                )
            }
            .tabBanners(.dates)
            .refreshable { await reload() }
            .task(id: env.datesSpan) { await reload() }
            .onReceive(env.$api.dropFirst()) { api in
                Task { await model.load(span: env.datesSpan, api: api, env: env) }
            }
            // A sync finished or a source toggle changed: refetch the current span. Content stays up meanwhile
            // (the model only shows the loading card when the span changes).
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDataRefreshed)) { _ in
                Task { await reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeDisplaySourcesChanged)) { _ in
                Task { await reload() }
            }
            // A meeting was left out, put back or moved: the span's numbers change.
            .onReceive(NotificationCenter.default.publisher(for: .meetspikeMeetingsChanged)) { _ in
                Task { await reload() }
            }
            .sheet(isPresented: $showPicker) {
                DatePickerSheet(start: env.datesSpan.start, end: env.datesSpan.end)
            }
        }
    }

    private func reload() async {
        await model.load(span: env.datesSpan, api: env.api, env: env)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            DatesStateCard(icon: nil, title: "Loading", message: "Getting your dates.", actionTitle: nil, action: {})
        case .failed(let failure):
            failureCard(failure)
        case .loaded(let view):
            loaded(view)
        }
    }

    @ViewBuilder private func failureCard(_ failure: DatesModel.Failure) -> some View {
        switch failure {
        case .offline:
            DatesStateCard(
                icon: "wifi.slash", title: "You're offline", message: "There is no saved data for these dates yet.",
                actionTitle: "Try again", action: { Task { await reload() } })
        case .accessRejected:
            DatesStateCard(
                icon: "lock.trianglebadge.exclamationmark", title: "Sign-in needed",
                message: "Meetspike turned this phone away. Check your Access token in Menu.",
                actionTitle: "Open Menu", action: { env.openMore() })
        case .notConfigured:
            DatesStateCard(
                icon: "link", title: "Not set up", message: DatesModel.text(for: failure),
                actionTitle: "Open Menu", action: { env.openMore() })
        case .other(let message):
            DatesStateCard(
                icon: "exclamationmark.triangle", title: "Couldn't load these dates", message: message,
                actionTitle: "Try again", action: { Task { await reload() } })
        }
    }

    @ViewBuilder private func loaded(_ view: ViewResponse) -> some View {
        if let savedAt = model.savedAt {
            Label("Offline, showing data from \(savedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: env.timeZone)))", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(Theme.warn)
        }
        if let error = model.refreshError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.warn)
        }
        if view.range == nil {
            DatesStateCard(
                icon: "calendar", title: "Just one day",
                message: "Dates compares a range of days. Open this day on Today instead.",
                actionTitle: "Open Today", action: { env.openDay(env.datesSpan.start) })
        } else {
            DatesSummaryCard(view: view, today: env.today)
            if !view.series.isEmpty { DatesChartsCard(view: view) }
            if !view.costly.isEmpty {
                DatesSection(title: "Days that cost you") {
                    ForEach(view.costly) { day in
                        DatesCostlyRow(day: day, wearable: view.wearable) { env.openDay(day.day) }
                    }
                }
            }
            if !view.people.isEmpty {
                DatesSection(title: "People on your heaviest days") {
                    ForEach(view.people) { person in
                        DatesPersonRow(person: person) { env.openPerson(person.email) }
                    }
                }
            }
            let hits = DatesCopy.meetingHits(view.hits)
            if view.wearable?.hasIntradayHr == true, !hits.isEmpty {
                DatesHitsCard(hits: hits, timeZone: env.timeZone, today: env.today) { day in
                    if let day { env.openDay(day) }
                }
            }
            DatesSyncFoot(status: view.status, timeZone: env.timeZone)
        }
    }
}

// MARK: Date bar

/// Previous span, the date picker button, next span. Next is off while the span ends today.
struct DatesBar: View {
    let span: DatesSpan
    let today: String
    let previous: () -> Void
    let next: () -> Void
    let pick: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let days = span.dayCount
        HStack(spacing: 8) {
            Button(action: previous) {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous \(DatesFormat.plural(days, "day"))")
            Button(action: pick) {
                Group {
                    if typeSize.isAccessibilitySize {
                        // The range, then the day count under it, so neither is cut off.
                        VStack(spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar").accessibilityHidden(true)
                                Text(DatesFormat.rangeLabel(span.start, span.end, today: today))
                            }
                            Text(DatesFormat.plural(days, "day")).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar").accessibilityHidden(true)
                            Text(DatesFormat.rangeLabel(span.start, span.end, today: today)).lineLimit(1).minimumScaleFactor(0.8)
                            Text("· \(DatesFormat.plural(days, "day"))").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: typeSize.isAccessibilitySize ? 18 : 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the date picker")
            Button(action: next) {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(!DatesLogic.canGoNext(span, today: today))
            .accessibilityLabel("Next \(DatesFormat.plural(days, "day"))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.background)
    }
}

// MARK: Cards

private struct DatesStateCard: View {
    let icon: String?
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            } else {
                ProgressView()
            }
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).tint(Theme.buttonFill)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
        .accessibilityElement(children: actionTitle == nil ? .combine : .contain)
    }
}

private struct DatesSummaryCard: View {
    let view: ViewResponse
    let today: String

    var body: some View {
        let copy = DatesCopy.headline(view)
        let start = view.start ?? view.range?.start ?? ""
        let end = view.end ?? view.range?.end ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Text(DatesFormat.rangeLabel(start, end, today: today))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(copy.headline)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !copy.lead.isEmpty {
                Text(copy.lead).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(DatesCopy.stats(view)) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.label).font(.caption).foregroundStyle(.secondary)
                        Text(stat.value).font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
        }
        .card()
    }
}

private struct DatesChartsCard: View {
    let view: ViewResponse

    var body: some View {
        let wearable = view.wearable
        let hasWearable = !(wearable?.source ?? "").isEmpty
        let label = wearable?.scoreLabel ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Text(hasWearable ? "Meetings, then next-morning \(label)" : "Meeting hours")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if hasWearable {
                let usual = view.usual?.recovery
                Text("Next-morning \(label), %" + (usual.map { ". Dashed line is your usual \(DatesFormat.number($0))%." } ?? ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                DatesRecoveryChart(series: view.series, usual: usual, scoreLabel: label)
                Text("Hours of meetings that day")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            DatesHoursChart(series: view.series)
        }
        .card()
    }
}

private struct DatesSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private func datesColor(_ tone: TodayTone) -> Color {
    switch tone {
    case .good: Theme.good
    case .warn: Theme.warn
    case .bad: Theme.bad
    case .none: .secondary
    }
}

private struct DatesCostlyRow: View {
    let day: CostlyDay
    let wearable: WearableInfo?
    let open: () -> Void

    var body: some View {
        let band = TodayLogic.recoveryBand(score: day.nextRecovery, wearable: wearable?.kind)
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DatesFormat.weekdayDay(day.day)).font(.body.weight(.semibold))
                    Text(DatesCopy.costlySubtitle(day)).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(day.nextRecovery.map { "\(DatesFormat.percent($0))%" } ?? "n/a").font(.body.weight(.semibold))
                    if let band {
                        Text("\(band.word) · \(wearable?.scoreLabel ?? "")")
                            .font(.footnote)
                            .foregroundStyle(datesColor(band.tone))
                    }
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this day on Today")
    }
}

private struct DatesPersonRow: View {
    let person: HeavyDayPerson
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Text(DatesFormat.initials(name: person.name, email: person.email))
                    .font(.footnote.weight(.bold))
                    .frame(width: 36, height: 36)
                    .background(Theme.inset, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name.flatMap { $0.isEmpty ? nil : $0 } ?? person.email).font(.body.weight(.semibold))
                    Text(DatesCopy.personSubtitle(person)).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this person on People")
    }
}

private struct DatesHitsCard: View {
    let hits: [InsightHit]
    let timeZone: TimeZone
    let today: String
    let open: (String?) -> Void

    var body: some View {
        DatesSection(title: "Meetings that spiked") {
            ForEach(hits) { hit in
                let pill = TodayLogic.zonePill(hit.hrStress, timeZone: timeZone)
                Button { open(hit.day) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(hit.day.map { DatesFormat.shortDay($0, today: today) } ?? "")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(pill.text)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(datesColor(pill.tone))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.inset, in: Capsule())
                        }
                        Text(hit.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled").font(.body.weight(.semibold))
                        let sentence = DatesCopy.shortSentence(hit)
                        if !sentence.isEmpty {
                            Text(sentence).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens this day on Today")
            }
        }
    }
}

private struct DatesSyncFoot: View {
    let status: ViewStatus?
    let timeZone: TimeZone

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    private var text: String {
        guard let stamp = status?.lastSync?.createdAt, let date = APITime.parse(stamp) else { return "Pull down to refresh" }
        let when = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
        return "Last synced \(when)" + (status?.sandbox == true ? " · sandbox data" : "")
    }
}
