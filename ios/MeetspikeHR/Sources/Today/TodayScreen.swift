import MeetspikeHRCore
import SwiftUI

/// The Today tab: one day of calendar against the wearable (`renderToday` in public/app.js).
/// Date bar, rings, meetings with their heart rate, what to expect tomorrow, the day against your usual.
struct TodayScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var model = TodayModel()
    /// Bumped to reload: the app came back, or the API was rebuilt.
    @State private var reloadToken = 0
    /// Re-read every 15 seconds so "In progress" and the live meeting follow the clock.
    @State private var now = Date()
    @State private var showPicker = false
    /// The meeting menu: the "Just this one" question and the times sheet.
    @StateObject private var actions = MeetingActionController()
    /// Bumped when a choice is queued or sent, so the rows read the waiting edits again.
    @State private var choicesRevision = 0

    private struct LoadKey: Equatable {
        var day: String
        var token: Int
    }

    /// The day the picker opens on: the one on screen, else the selected day.
    private var pickerDay: String { model.shownDay ?? env.selectedDay }

    /// Moves `now` forward. When a live window passed in between, the day reloads so the row pill shows the
    /// finished heart rate instead of "In progress" (web app.js 425-429).
    private func advanceClock() {
        let next = Date()
        let previous = now
        now = next
        // The day on screen, not the selected one: a saved copy of another day must not start live reloads.
        guard model.shownDay == env.today, scenePhase == .active,
              model.view?.wearable?.whoopWebHr == true,
              let events = model.view?.day?.calendar?.events,
              TodayLogic.liveWindowEnded(events: events, previous: previous, now: next)
        else { return }
        model.reloadQuietly(env: env, syncedElsewhere: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(Theme.background.ignoresSafeArea())
            .tabBanners(.today)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .moreButton()
            .refreshable {
                // Unstructured, so the refresh finishes even if this view redraws and cancels the gesture's task.
                let day = env.selectedDay
                await Task { await model.pullRefresh(day: day, env: env) }.value
            }
        }
        .task(id: LoadKey(day: env.selectedDay, token: reloadToken)) {
            let day = env.selectedDay
            await model.load(day: day, env: env)
            #if DEBUG
            // `-openMeeting <id>` opens one meeting on launch, for screenshots.
            if let id = UserDefaults.standard.string(forKey: "openMeeting"), case .auto = model.selection {
                model.selection = .meeting(id)
            }
            #endif
            if day == env.today, scenePhase == .active { await model.autoRefresh(day: day, env: env) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            advanceClock()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                advanceClock()
            }
        }
        // Another tab synced or toggled a source: reload quietly. Today never posts these, so no loop.
        .onReceive(NotificationCenter.default.publisher(for: .meetspikeDataRefreshed)) { _ in
            model.reloadQuietly(env: env, syncedElsewhere: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetspikeDisplaySourcesChanged)) { _ in
            model.reloadQuietly(env: env, syncedElsewhere: false, sourcesChanged: true)
        }
        // A company was renamed on People: reload for the chips, without counting it as a sync.
        .onReceive(NotificationCenter.default.publisher(for: .meetspikeCompanyRenamed)) { _ in
            model.reloadQuietly(env: env, syncedElsewhere: false)
        }
        // A meeting was left out, put back or moved (here, in the Live Activity, or a waiting edit went out).
        .onReceive(NotificationCenter.default.publisher(for: .meetspikeMeetingsChanged)) { _ in
            model.reloadQuietly(env: env, syncedElsewhere: false)
        }
        .onReceive(env.choices.$waiting.dropFirst()) { _ in choicesRevision += 1 }
        .sheet(isPresented: $showPicker) {
            DatePickerSheet(start: pickerDay, end: pickerDay)
        }
        .environmentObject(actions)
        .meetingActionDialogs(actions, zone: env.timeZone, env: env)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadToken += 1 }
        }
        .onReceive(env.$connectionRevision.dropFirst()) { _ in
            model.reset()
            reloadToken += 1
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 16) {
            if let view = model.view, let briefing = view.day {
                loaded(view, briefing)
            } else if let failure = model.failure {
                // Keep the date bar so a day that fails can be left: the day before may be saved.
                dateBar(label: dayLabel(env.selectedDay), sub: "", canGoNext: TodayLogic.dateBar(day: env.selectedDay, today: env.today).canGoNext)
                TodayFailureView(failure: failure, retry: { reloadToken += 1 }, openMore: { env.openMore() })
            } else {
                dateBar(label: dayLabel(env.selectedDay), sub: "", canGoNext: TodayLogic.dateBar(day: env.selectedDay, today: env.today).canGoNext)
                TodayLoadingView()
            }
        }
    }

    private func dayLabel(_ day: String) -> String {
        TodayLogic.dateBar(day: day, today: env.today).isToday ? "Today" : TodayFormat.dayText(day, weekday: true)
    }

    private func dateBar(label: String, sub: String, canGoNext: Bool) -> some View {
        TodayDateBar(
            label: label, sub: sub, canGoNext: canGoNext,
            pickDate: { showPicker = true },
            previous: { env.selectedDay = DayMath.addDays(env.selectedDay, -1) },
            next: { env.selectedDay = min(DayMath.addDays(env.selectedDay, 1), env.today) })
    }

    @ViewBuilder
    private func loaded(_ view: ViewResponse, _ briefing: DayBriefing) -> some View {
        let wearable = view.wearable
        let day = briefing.date ?? env.selectedDay
        // The app's today, never the one inside `view`: an offline copy of yesterday says yesterday is today.
        let today = env.today
        let bar = TodayLogic.dateBar(day: day, today: today)
        let isToday = bar.isToday
        let scores = view.morningScores
        let calendar = briefing.calendar
        // Choices still waiting to be sent show on their rows at once.
        let events = env.choices.overlaid(calendar?.events ?? [])
        let _ = choicesRevision
        let zoneName = briefing.timeZone ?? view.timeZone
        let zone = zoneName.flatMap(TimeZone.init(identifier:)) ?? env.timeZone
        let heavy = TodayLogic.isHeavyDay(totalDurationS: calendar?.totalDurationS, eventCount: calendar?.eventCount)

        dateBar(
            label: isToday ? "Today" : TodayFormat.dayText(day, weekday: true),
            sub: isToday ? TodayFormat.dayText(day, weekday: true) : "",
            canGoNext: bar.canGoNext)

        Text(scores.count > 1 ? "Calendar \u{D7} WHOOP and Oura" : (wearable?.tagline ?? "Calendar \u{D7} \(wearable?.label ?? "your wearable")"))
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

        rings(view, briefing)

        meetingsCard(
            events: events, calendar: calendar, wearable: wearable, isToday: isToday, zone: zone, today: today)

        if let outlook = outlook(view, briefing, heavy: heavy, today: today) {
            outlook
        }

        usualCard(view, briefing)

        if wearable?.hasIntradayHr == true, let hits = view.hits, hits.contains(where: { $0.kind != "day" }) {
            hitsCard(hits, today: today)
        }

        syncFooter(view)
    }

    // MARK: Rings

    private func rings(_ view: ViewResponse, _ briefing: DayBriefing) -> some View {
        let wearable = view.wearable
        let morning = briefing.priorNight
        let calendar = briefing.calendar
        var rings: [TodayRingModel] = []

        for score in view.morningScores {
            let band = TodayLogic.recoveryBand(score: score.morning, wearable: WearableKind(rawValue: score.source ?? ""))
            let title = score.scoreLabel
            rings.append(TodayRingModel(
                id: "score-\(score.id)", label: title,
                value: score.morning.map { "\(TodayFormat.number($0))%" } ?? "\u{2013}",
                progress: (score.morning ?? 0) / 100,
                color: band.map { TodayPalette.color($0.tone) } ?? .secondary,
                note: band?.word ?? "No score",
                spoken: score.morning == nil
                    ? "\(title) has no score"
                    : "\(title) \(TodayFormat.number(score.morning ?? 0)) percent, \(band?.word ?? "")"))
        }

        if let wearable, wearable.source != nil {
            let label = wearable.label ?? ""
            let sleepScore = morning?.sleepScore
            rings.append(TodayRingModel(
                id: "sleep", label: "Sleep (\(label))",
                value: sleepScore.map { "\(TodayFormat.number($0))%" } ?? "\u{2013}",
                progress: (sleepScore ?? 0) / 100,
                color: TodayPalette.sleep,
                note: (morning?.totalSleepS).flatMap { $0 > 0 ? TodayFormat.sleepText(seconds: $0) : nil } ?? "No score",
                spoken: sleepScore == nil
                    ? "\(label) sleep has no score"
                    : "\(label) sleep \(TodayFormat.number(sleepScore ?? 0)) percent"))
        }

        if let strainLabel = wearable?.strainLabel, !strainLabel.isEmpty {
            let max = (wearable?.strainMax ?? 0) > 0 ? (wearable?.strainMax ?? 21) : 21
            let strain = morning?.strain
            rings.append(TodayRingModel(
                id: "strain", label: strainLabel.uppercased(),
                value: strain.map(TodayFormat.number) ?? "\u{2013}",
                progress: (strain ?? 0) / max,
                color: TodayPalette.strain,
                note: "of \(TodayFormat.number(max))",
                spoken: strain == nil
                    ? "\(strainLabel): none yet"
                    : "\(strainLabel) \(TodayFormat.number(strain ?? 0)) of \(TodayFormat.number(max))"))
        } else {
            let seconds = calendar?.totalDurationS ?? 0
            rings.append(TodayRingModel(
                id: "meetings", label: "MEETINGS",
                value: TodayFormat.hoursText(seconds: seconds).replacingOccurrences(of: " ", with: ""),
                progress: Double(seconds) / (8 * 3600),
                color: TodayPalette.strain,
                note: TodayFormat.plural(calendar?.eventCount ?? 0, "meeting"),
                spoken: "\(TodayFormat.hoursText(seconds: seconds)) of meetings"))
        }

        let columns = rings.count > 3 || typeSize >= .accessibility1 ? 2 : 3
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 12) {
            ForEach(rings) { TodayRing(ring: $0) }
        }
        .padding(.vertical, 4)
    }

    // MARK: Meetings

    @ViewBuilder
    private func meetingsCard(
        events: [Meeting], calendar: DayCalendar?, wearable: WearableInfo?, isToday: Bool, zone: TimeZone, today: String
    ) -> some View {
        if events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                TodayKicker("Meetings")
                Text("No meetings on the calendar.").font(.body).foregroundStyle(.secondary)
            }
            .card()
        } else {
            let kept = events.filter { $0.excluded != true }
            let openID = openMeetingID(events: kept, wearable: wearable, isToday: isToday)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    TodayKicker(isToday ? "Today's meetings" : "Meetings")
                    Spacer(minLength: 8)
                    Text(meetingsSummary(calendar))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                TodayTimeline(events: kept)
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        Divider()
                        if event.excluded == true {
                            ExcludedMeetingRow(event: event)
                            MeetingChoiceLine(eventID: event.id, choices: env.choices)
                        } else {
                            meetingRow(event, wearable: wearable, open: openID == event.id, zone: zone)
                        }
                    }
                }
            }
            .card()
        }
    }

    private func meetingsSummary(_ calendar: DayCalendar?) -> String {
        var text = "\(TodayFormat.plural(calendar?.eventCount ?? 0, "meeting")) \u{B7} \(TodayFormat.hoursText(seconds: calendar?.totalDurationS))"
        if let after = calendar?.afterHoursCount, after > 0 { text += " \u{B7} \(after) after 6 pm" }
        return text
    }

    /// The open meeting: the person's choice, or on today a running meeting opens itself.
    private func openMeetingID(events: [Meeting], wearable: WearableInfo?, isToday: Bool) -> String? {
        switch model.selection {
        case .closed: return nil
        case .meeting(let id): return id
        case .auto:
            guard isToday, wearable?.whoopWebHr == true else { return nil }
            return TodayFormat.liveMeetingID(events: events, now: now)
        }
    }

    private func meetingRow(_ event: Meeting, wearable: WearableInfo?, open: Bool, zone: TimeZone) -> some View {
        let window = wearable?.whoopWebHr == true
            ? TodayLogic.liveWindow(startUtc: event.startUtc, endUtc: event.endUtc, sourceType: event.sourceType)
            : nil
        let nowMs = now.timeIntervalSince1970 * 1000
        let inProgress = window.map { nowMs >= $0.startMs && nowMs < $0.endMs } ?? false
        let pill = TodayLogic.zonePill(event.hrStress, timeZone: zone)
        let meta = [TodayFormat.meetingMeta(event), TodayLogic.partialNote(event.hrStress, timeZone: zone)]
            .filter { !$0.isEmpty }.joined(separator: " \u{B7} ")
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                model.selection = open ? .closed : .meeting(event.id)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text(TodayFormat.clockFromLocal(event.startLocal))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title?.isEmpty == false ? event.title ?? "" : "Untitled")
                            .font(.body.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        if !meta.isEmpty {
                            Text(meta).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        // The pill sits under the title so its full text shows at any width.
                        if inProgress {
                            TodayPill(tone: .good, text: "In progress").padding(.top, 2)
                        } else if wearable?.hasIntradayHr == true {
                            TodayPill(tone: pill.tone, text: pill.text).padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 4)
                    if !inProgress && wearable?.hasIntradayHr != true {
                        Text(TodayFormat.lengthText(durationS: event.durationS)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { MeetingMenuItems(event: event) }
            .accessibilityElement(children: .ignore)
            .modifier(MeetingAccessibilityActions(event: event))
            .accessibilityLabel(rowSpoken(event, meta: meta, pill: pill, inProgress: inProgress, hasHR: wearable?.hasIntradayHr == true))
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            .accessibilityHint(open ? "Hides the heart rate" : "Shows the heart rate")
            .accessibilityAddTraits(.isButton)

            if OverrideRules.suggestsNotJoined(event.override) { SkippedNote(event: event) }
            MeetingChoiceLine(eventID: event.id, choices: env.choices)
            if open {
                HStack { Spacer(); MeetingOptionsButton(event: event) }
            }
            if open, !event.companies.isEmpty {
                // Companies of the people in this meeting. A chip opens the company on People.
                CompanyChips(companies: event.companies) { env.openCompany($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Under the title, past the 64 pt time column and its 12 pt gap.
                    .padding(.leading, 76)
                    .padding(.bottom, 10)
            }
            if open, wearable?.hasIntradayHr == true {
                MeetingDetailView(
                    event: event, window: window, now: now, zone: zone, model: model,
                    isActive: scenePhase == .active && env.selectedTab == .today)
            }
        }
    }

    private func rowSpoken(_ event: Meeting, meta: String, pill: TodayZonePill, inProgress: Bool, hasHR: Bool) -> String {
        var parts = [TodayFormat.clockFromLocal(event.startLocal), event.title ?? "Untitled"]
        if !meta.isEmpty { parts.append(meta) }
        if inProgress { parts.append("In progress") } else if hasHR { parts.append(pill.text) } else {
            parts.append(TodayFormat.lengthText(durationS: event.durationS))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Outlook

    private func outlook(_ view: ViewResponse, _ briefing: DayBriefing, heavy: Bool, today: String) -> AnyView? {
        guard let wearable = view.wearable, wearable.source != nil else { return nil }
        let day = briefing.date ?? env.selectedDay
        let scores = view.morningScores
        if scores.contains(where: { $0.nextMorning != nil }) {
            let rows = scores.compactMap { score in
                TodayMetric(
                    name: score.scoreLabel, value: score.nextMorning, usual: score.usual?.recovery, unit: "%",
                    higherIs: .better, step: TodayLogic.recoveryStep)
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    TodayKicker("The night after")
                    ForEach(rows) { TodayMetricRow(metric: $0) }
                }
                .card())
        }
        if day >= DayMath.addDays(today, -1) {
            let effect = view.effect
            let label = wearable.scoreLabel
            let cost = effect?.cost
            var line = "Not enough days with scores yet to say what a day like this usually costs."
            if let effect, cost != nil, (effect.heavy?.days ?? 0) >= 2, (effect.lighter?.days ?? 0) >= 2 {
                let heavyAfter = TodayFormat.number(effect.heavy?.nextRecovery ?? 0)
                let lighterAfter = TodayFormat.number(effect.lighter?.nextRecovery ?? 0)
                line = heavy
                    ? "After your last \(effect.heavy?.days ?? 0) heavy days you woke at \(heavyAfter)% \(label) on average, against \(lighterAfter)% after lighter days."
                    : "After lighter days you usually wake at \(lighterAfter)% \(label), against \(heavyAfter)% after heavy ones."
            }
            let title: String
            if heavy, let cost, cost >= 3 {
                title = "Heavy days usually cost you about \(TodayFormat.number(cost)) points of \(label)."
            } else {
                title = heavy ? "A heavy day." : "A lighter day."
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    TodayKicker("What to expect tomorrow")
                    Text(title).font(.title3.weight(.semibold))
                    Text(line).font(.body).foregroundStyle(.secondary)
                }
                .card())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                TodayKicker("The night after")
                Text("No wearable scores for the next morning.").font(.body).foregroundStyle(.secondary)
            }
            .card())
    }

    // MARK: Against your usual

    @ViewBuilder
    private func usualCard(_ view: ViewResponse, _ briefing: DayBriefing) -> some View {
        let rows = usualRows(view, briefing)
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    TodayMetricRow(metric: row)
                }
            }
            .card()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("This day against your usual")
        }
    }

    private func usualRows(_ view: ViewResponse, _ briefing: DayBriefing) -> [TodayMetric] {
        let wearable = view.wearable
        let usual = view.usual
        let calendar = briefing.calendar
        let morning = briefing.priorNight
        var rows: [TodayMetric?] = [
            TodayMetric(
                name: "Meeting hours", value: TodayFormat.rounded(Double(calendar?.totalDurationS ?? 0) / 3600, places: 1),
                usual: usual?.meetingHours, higherIs: .worse, step: TodayLogic.meetingHoursStep, words: .moreFewer),
            TodayMetric(
                name: "After 6 pm", value: Double(calendar?.afterHoursCount ?? 0), usual: usual?.afterHours,
                higherIs: .worse, step: 1, words: .moreFewer),
        ]
        for score in view.morningScores {
            rows.append(TodayMetric(
                name: score.scoreLabel, value: score.morning, usual: score.usual?.recovery, unit: "%",
                higherIs: .better, step: TodayLogic.recoveryStep))
        }
        if let wearable, wearable.source != nil {
            let label = wearable.label ?? ""
            rows.append(TodayMetric(
                name: "Heart rate variability (\(label))", value: TodayFormat.rounded(morning?.avgHrv), usual: usual?.hrv,
                unit: " ms", higherIs: .better, step: TodayLogic.hrvStep))
            rows.append(TodayMetric(
                name: "Resting heart rate (\(label))", value: TodayFormat.rounded(morning?.lowestHr), usual: usual?.restingHr,
                unit: " bpm", higherIs: .worse, step: TodayLogic.restingHrStep))
        }
        if let strainLabel = wearable?.strainLabel, !strainLabel.isEmpty {
            rows.append(TodayMetric(
                name: "Day \(strainLabel)", value: morning?.strain, usual: usual?.strain, higherIs: .neutral, step: 1))
        }
        return rows.compactMap { $0 }
    }

    // MARK: Meetings that spiked

    private func hitsCard(_ hits: [InsightHit], today: String) -> some View {
        let meetingHits = hits.filter { $0.kind != "day" }.prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            TodayKicker("Meetings that spiked, last 28 days")
            VStack(spacing: 0) {
                ForEach(Array(meetingHits.enumerated()), id: \.element.id) { index, hit in
                    if index > 0 { Divider() }
                    Button {
                        if let day = hit.day { env.openDay(day) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(hit.day.map { TodayFormat.shortDay($0, today: today) } ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title?.isEmpty == false ? hit.title ?? "" : "Untitled")
                                    .font(.body.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                let sentence = TodayFormat.shortSentence(hit)
                                if !sentence.isEmpty {
                                    Text(sentence).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                let pill = TodayLogic.zonePill(hit.hrStress, timeZone: env.timeZone)
                                TodayPill(tone: pill.tone, text: pill.text).padding(.top, 2)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens that day")
                }
            }
        }
        .card()
    }

    // MARK: Footer

    private func syncFooter(_ view: ViewResponse) -> some View {
        let (text, failed) = syncLine(view)
        return VStack(spacing: 6) {
            if let saved = model.offlineSavedAt {
                Text("Offline, showing data from \(saved.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            }
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(failed ? Theme.bad : .secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Button {
                    let day = env.selectedDay
                    Task { await model.pullRefresh(day: day, env: env) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.footnote.weight(.semibold))
                }
                .disabled(model.sync == .running)
                .accessibilityLabel("Refresh data")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    /// The footer line and whether it is a problem. The calendar part and each wearable are decided by
    /// `SyncOutcome`, the same as the Menu: a calendar problem never hides a wearable that did not refresh, and a
    /// sync still running in the background never says "Synced".
    private func syncLine(_ view: ViewResponse) -> (text: String, isProblem: Bool) {
        switch model.sync {
        case .running:
            return ("Syncing your calendar\u{2026}", false)
        case .failed(let message):
            return ("Calendar sync failed: \(message)", true)
        case .finished(let at, let result):
            let display = view.status?.sourceDisplay
            let outcome = SyncOutcome.decide(result, showWhoop: display?.whoop == true, showOura: display?.oura == true)
            let extra = outcome.wearableNotes.map { " \u{B7} " + ($0.hasSuffix(".") ? String($0.dropLast()) : $0) }.joined()
            switch outcome.calendar {
            case .failed(let message):
                return ("Calendar sync failed: \(message)\(extra)", true)
            case .pending:
                return ("Still syncing in the background\(extra)", false)
            case .needsGoogle:
                // Google is not connected: nothing to sync, not an error. Wearable problems still show.
                return (lastSyncLine(view) + extra, false)
            case .synced:
                let minutes = Int(now.timeIntervalSince(at) / 60)
                guard minutes < 60 else { return (lastSyncLine(view) + extra, false) }
                let ago = minutes < 1 ? "just now" : minutes == 1 ? "1 min ago" : "\(minutes) min ago"
                return ("Synced \(ago)\(view.status?.sandbox == true ? " \u{B7} sandbox data" : "")\(extra)", false)
            }
        case .idle:
            return (lastSyncLine(view), false)
        }
    }

    private func lastSyncLine(_ view: ViewResponse) -> String {
        guard let stamp = APITime.parse(view.status?.lastSync?.createdAt) else {
            let label = view.wearable?.source != nil ? "\(view.wearable?.label ?? "Your wearable") and Google Calendar" : "Google Calendar"
            return label
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = env.timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        return "Last synced \(formatter.string(from: stamp))\(view.status?.sandbox == true ? " \u{B7} sandbox data" : "")"
    }
}

// MARK: Loading and failure

private struct TodayLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading your day").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
    }
}

private struct TodayFailureView: View {
    let failure: TodayFailure
    let retry: () -> Void
    let openMore: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(failure.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            switch failure.kind {
            case .accessRejected, .notConfigured:
                Button("Open Menu", action: openMore).buttonStyle(.borderedProminent).tint(Theme.buttonFill)
            case .offline, .generic:
                Button("Try again", action: retry).buttonStyle(.borderedProminent).tint(Theme.buttonFill)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch failure.kind {
        case .offline: "wifi.slash"
        case .accessRejected: "lock.trianglebadge.exclamationmark"
        case .notConfigured: "link.badge.plus"
        case .generic: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch failure.kind {
        case .offline: "You're offline"
        case .accessRejected: "Sign-in needed"
        case .notConfigured: "Set up Meetspike"
        case .generic: "Couldn't load your day"
        }
    }
}

// MARK: Open meeting

/// What shows under an open meeting row: the live card while it runs, then the heart rate detail.
private struct MeetingDetailView: View {
    let event: Meeting
    let window: LiveWindowMs?
    let now: Date
    let zone: TimeZone
    @ObservedObject var model: TodayModel
    let isActive: Bool

    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        let nowMs = now.timeIntervalSince1970 * 1000
        let showLive = window.map { nowMs >= $0.fromMs && nowMs < $0.toMs } ?? false
        VStack(alignment: .leading, spacing: 10) {
            if showLive, let window {
                LiveHRCard(
                    meetingID: event.id, window: window,
                    adjust: LiveAdjust.target(
                        meetingID: event.id, title: event.title, startUtc: event.startUtc, endUtc: event.endUtc,
                        override: event.override),
                    timeZone: zone, isActive: isActive)
                    .id(event.id)
            }
            if !showLive || event.hrStress?.coverage == "ok" {
                detail
                    // The epoch changes when a refresh clears the cached details, so an open meeting loads again.
                    .task(id: "\(event.id)#\(model.detailEpoch)") { model.loadDetail(id: event.id, zone: zone, env: env) }
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var detail: some View {
        // Old data keeps showing while a refresh reloads it: the placeholder is only for a first load.
        let entry = model.details[event.id]
        if let content = entry?.data {
            VStack(alignment: .leading, spacing: 8) {
                if let chart = content.chart { MeetingHRChart(model: chart, zone: content.zone).equatable() }
                if !content.facts.isEmpty {
                    Text(content.facts.joined(separator: " \u{B7} ")).font(.footnote).foregroundStyle(.secondary)
                }
                if entry?.refreshFailed == true {
                    Text("Couldn't refresh. Showing the last one.").font(.footnote).foregroundStyle(.secondary)
                }
                Text(content.story).font(.body)
            }
        } else if let entry, !entry.showsLoadingPlaceholder, entry.error != nil {
            Text("No heart rate for this meeting.").font(.body).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let sparkline = model.sparklines[event.id] { MeetingSparkline(model: sparkline).equatable() }
                Text("Loading heart rate\u{2026}").font(.body).foregroundStyle(.secondary)
            }
        }
    }
}
