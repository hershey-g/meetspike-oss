import Charts
import MeetspikeHRCore
import SwiftUI

@MainActor
struct Dashboard: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var live: LiveSync
    @ObservedObject var replay: ReplaySync
    @EnvironmentObject private var env: AppEnvironment
    @State private var showSettings = false
    @State private var showLockScreenPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var bpmSize = 72.0
    @ScaledMetric(relativeTo: .caption) private var legendSize = 11.0
    /// Stats for the part of a long meeting older than the chart's 15 minutes, read from the phone's store.
    @State private var meetingBase: MeetingBase?
    @State private var hapticGate = LiveHapticGate()
    @State private var hapticSeeded = false
    @State private var hapticTick = 0
    /// When this screen last asked the Worker for the usual resting heart rate.
    @State private var restingAskedAt = Date.distantPast

    private struct MeetingBase: Equatable {
        let start: Date
        let stats: HeartRateStats
        /// Read after the meeting ended: its stored readings will not change, so they are not read again.
        let complete: Bool
    }

    private struct HapticInput: Equatable {
        let live: Bool
        let listening: Bool
    }

    private struct RestingKey: Equatable {
        let revision: Int
        let visible: Bool
    }

    private var sync: SyncDisplay { model.demoSync ?? SyncDisplay(live: live, replay: replay) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 16) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 16) {
                                if let build = model.availableUpdate { updateCard(build: build) }
                                if !model.syncConfigured { setupCard }
                                heartCard(at: context.date)
                                meetingCard(at: context.date)
                                goLiveCard
                                chartCard(at: context.date)
                                .id("chart")
                            }
                        }
                        syncCard
                            .id("sync")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    #if DEBUG
                    if model.isDemo {
                        if UserDefaults.standard.bool(forKey: "demoChart") {
                            scroll.scrollTo("chart", anchor: .top)
                        } else if UserDefaults.standard.bool(forKey: "demoBottom") {
                            scroll.scrollTo("sync", anchor: .bottom)
                        }
                    }
                    #endif
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .tabBanners(.live)
            .navigationTitle("Meetspike")
            .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { MoreButton() }
            }
        }
        .tint(Theme.accent)
        .task(id: RestingKey(revision: env.connectionRevision, visible: env.selectedTab == .live)) {
            await loadResting()
        }
        .task(id: LiveChart.meeting(in: model.schedule, range: LiveChart.range(now: .now))?.start) {
            await keepMeetingStats()
        }
        // One success tap when the strap first goes live in a listening session (see LiveHapticGate).
        .onChange(of: HapticInput(live: model.hasCurrentReading, listening: model.connection != .outsideMeeting),
                  initial: true) { _, input in
            let fire = hapticGate.update(live: input.live, listening: input.listening, now: .now)
            // Opening the app mid-session is not a new connection: the first look only seeds the gate.
            if fire && hapticSeeded { hapticTick += 1 }
            hapticSeeded = true
        }
        .sensoryFeedback(.success, trigger: hapticTick)
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $showLockScreenPicker) { LockScreenHeartRateSheet(model: model) }
        .fullScreenCover(isPresented: Binding(
            get: { !model.onboardingComplete }, set: { if !$0 { model.finishOnboarding() } }
        )) {
            OnboardingView(model: model)
        }
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "demoSettings") { showSettings = true }
            #endif
        }
    }

    // MARK: Background loads

    /// The usual resting heart rate comes from the same day view Today loads (`usual.restingHr`). The saved copy
    /// shows first; the Worker is asked again only when the phone's value is missing or over 6 hours old, at most
    /// every 30 minutes from here. Failures stay quiet: the last known value keeps working offline.
    private func loadResting() async {
        guard env.selectedTab == .live, !model.isDemo else { return }
        let api = env.api
        let day = env.today
        if let cached = await api.cachedView(date: day) {
            model.noteUsualResting(cached.value.usual?.restingHr, savedAt: cached.savedAt)
        }
        guard model.restingNeedsRefresh, Date.now.timeIntervalSince(restingAskedAt) > 1_800, !Task.isCancelled else { return }
        restingAskedAt = .now
        if let loaded = try? await api.loadView(date: day) {
            model.noteUsualResting(loaded.value.usual?.restingHr, savedAt: loaded.savedAt)
        }
    }

    /// While the charted meeting started before the chart's 15 minutes, keeps its stats from stored readings
    /// (every 30 seconds). Newer readings are added from memory when the card draws. Each pass looks up the
    /// charted meeting again (this task's id only changes when the screen redraws), reads only readings newer
    /// than the last pass, and stops reading once a pass ran after the meeting ended.
    private func keepMeetingStats() async {
        while !Task.isCancelled {
            let now = Date.now
            let range = LiveChart.range(now: now)
            let meeting = LiveChart.meeting(in: model.schedule, range: range)
            if meetingBase != nil, meetingBase?.start != meeting?.start { meetingBase = nil }
            if let meeting, LiveChart.needsStoredReadings(meeting: meeting, range: range), meetingBase?.complete != true {
                let base = meetingBase?.stats ?? HeartRateStats()
                let from = base.through.map { $0.addingTimeInterval(0.001) } ?? meeting.start
                let readings = await model.storedReadings(from: from, through: min(meeting.end, now))
                if Task.isCancelled { return }
                meetingBase = MeetingBase(start: meeting.start,
                                          stats: base.adding(readings, within: meeting.start...meeting.end),
                                          complete: now >= meeting.end)
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    // MARK: Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect to Meetspike", systemImage: "link.badge.plus")
                .font(.headline)
            Text("Add your Meetspike URL and ingest secret so heart rate reaches your dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Set Up Sync") { showSettings = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.buttonFill)
        }
        .card()
    }

    private func updateCard(build: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Update available", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Build \(build) is ready in TestFlight.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Update") {
                openURL(AppUpdate.testFlightURL) { opened in
                    if !opened { openURL(AppUpdate.testFlightInstallURL) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.buttonFill)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Heart rate

    private func heartCard(at now: Date) -> some View {
        let listening = model.isListening(at: now)
        let state = PhoneHeartState(
            connection: model.connection, permission: model.bluetoothPermission, listening: listening,
            latestAt: model.latest?.time, hasCurrentReading: model.hasCurrentReading, now: now
        )
        let isLive = state.tone == .live
        // Only a live reading is compared: an old one against resting says nothing about now.
        let comparison = isLive ? RestingComparison(bpm: model.latest?.bpm, resting: model.restingHr) : nil
        let level = comparison?.level ?? .normal
        let spikeColor = Theme.spikeColor(level)
        return VStack(alignment: .leading, spacing: 8) {
            (typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())) {
                Label("Heart rate", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isLive ? spikeColor : .secondary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                StatusPill(title: state.title, color: Theme.tone(state.tone))
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let latest = model.latest {
                            Text(String(latest.bpm))
                                .font(.system(size: bpmSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(reduceMotion ? .identity : .numericText())
                                .foregroundStyle(isLive ? .primary : .secondary)
                        } else {
                            // A thin placeholder at full size, so the layout does not jump when the first reading lands.
                            Text("--")
                                .font(.system(size: bpmSize, weight: .ultraLight, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        Text("bpm")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.latest.map { "\($0.bpm) beats per minute" } ?? "No reading")
                    if let comparison, !typeSize.isAccessibilitySize {
                        restingBadge(comparison, color: spikeColor)
                    }
                }
                Spacer(minLength: 0)
                BeatingHeart(bpm: isLive ? model.latest?.bpm : nil, color: spikeColor, animate: !reduceMotion,
                             size: bpmSize * 0.6)
            }
            // At the largest text sizes the badge gets the full width, so it wraps by words, not syllables.
            if let comparison, typeSize.isAccessibilitySize {
                restingBadge(comparison, color: spikeColor)
            }
            if let latest = model.latest, !isLive {
                Text("Last reading at \(latest.time.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let detail = state.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.action == .openSettings {
                Button("Open Settings", action: SystemSettings.open)
                    .buttonStyle(.bordered)
            }
            if listening, model.connection == .searching, let broadcaster = model.scan.manualCandidate(now: now) {
                Divider().padding(.vertical, 4)
                Text("Heard one heart-rate broadcaster that isn't named WHOOP. Use it only if your WHOOP is the only heart-rate device nearby.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Use \(broadcaster.advertisement.displayName)") { model.useBroadcaster(broadcaster.id) }
                    .buttonStyle(.bordered)
            }
        }
        .spikeCard(level: comparison?.level)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: comparison?.level)
    }

    /// "+14 over resting" under the BPM, in the level's color.
    private func restingBadge(_ comparison: RestingComparison, color: Color) -> some View {
        let icon = comparison.delta > 0 ? "arrow.up" : comparison.delta < 0 ? "arrow.down" : "equal"
        return Label {
            Text(comparison.label)
        } icon: {
            Image(systemName: icon)
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: typeSize.isAccessibilitySize
                    ? AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) : AnyShape(Capsule()))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(comparison.accessibilityLabel)
    }

    // MARK: Meeting

    private func meetingCard(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Meeting", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            switch model.calendarAccess {
            case .notRequested:
                Text("Meetspike uses your calendar to listen only around meetings.")
                    .font(.subheadline)
                Button("Allow Calendar Access") { Task { await model.requestCalendar() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.buttonFill)
            case .denied:
                Text("Calendar access is off").font(.headline)
                Text("Meetspike can't see your meetings, so it only listens when you turn on Go live now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: SystemSettings.open)
                    .buttonStyle(.bordered)
            case .allowed:
                if let event = model.schedule.displayedMeeting(at: now) {
                    meetingDetail(event, now: now)
                } else {
                    Text("No meetings in the next 7 days").font(.headline)
                    Text("Turn on Go live now to listen anyway.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private func meetingDetail(_ event: CalendarMeeting, now: Date) -> some View {
        let countdown = MeetingCountdown(meeting: event, schedule: model.schedule, now: now)
        let upcoming: Bool = {
            switch countdown {
            case .later, .startsIn: return true
            default: return false
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(event.title)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
            Text(event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            switch countdown {
            case .later(let start):
                Text("Starts \(start.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .startsIn(let date):
                timer("Starts in", to: date, from: now)
            case .endsIn(let date):
                timer("Ends in", to: date, from: now)
            case .cooldown(let date):
                timer("Cooldown ends in", to: date, from: now)
            case .ended:
                EmptyView()
            }
            if upcoming, !model.hasCurrentReading {
                broadcastHint(for: event, now: now)
            }
            LiveAdjustButtons(target: model.liveAdjustTarget(at: now), now: now)
                .padding(.top, 4)
        }
    }

    /// Before a meeting with no heart rate coming in: what to do, and when the reminder comes.
    private func broadcastHint(for event: CalendarMeeting, now: Date) -> some View {
        let soon = event.start.timeIntervalSince(now) <= 5 * 60
        let reminderAt = event.start.addingTimeInterval(-BroadcastPlan.lead)
        let text = soon
            ? "Turn on HR Broadcast in the WHOOP app before it starts."
            : model.pushActive && reminderAt > now
                ? "Reminder at \(reminderAt.formatted(date: .omitted, time: .shortened)) if no heart rate is coming in."
            : model.ownsReminders && reminderAt > now
                ? "Reminder to turn on HR Broadcast at \(reminderAt.formatted(date: .omitted, time: .shortened))."
                : "Turn on HR Broadcast in the WHOOP app before it starts."
        return Label(text, systemImage: soon ? "dot.radiowaves.left.and.right" : "bell")
            .font(.footnote.weight(soon ? .semibold : .regular))
            .foregroundStyle(soon ? Theme.warn : .secondary)
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timer(_ label: String, to end: Date, from now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(timerInterval: now...max(now, end), countsDown: true)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func chartCard(at now: Date) -> some View {
        let range = LiveChart.range(now: now)
        let readings = model.recent.filter { range.contains($0.time) }
        let meeting = LiveChart.meeting(in: model.schedule, range: range)
        let history = HeartRateHistory(readings: readings, range: range, meetingWindow: meeting.map { $0.start...$0.end })
        let summary = chartSummary(history: history, readings: readings, meeting: meeting, range: range)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Last 15 minutes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if history.points.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(model.isListening(at: now) ? "Waiting for readings" : "Readings show here while Meetspike listens")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                chart(history, meeting: meeting)
                    .frame(height: typeSize.isAccessibilitySize ? 230 : 170)
                    .accessibilityLabel(chartAccessibilityLabel(meeting: meeting, range: range))
                if let meeting {
                    meetingLegend(meeting, now: now)
                }
                if let summary {
                    stat(summary.stats, title: summary.title)
                }
            }
        }
        .card()
    }

    /// Min / Avg / Max for the meeting when it has readings ("This meeting"), else for the 15 minutes. A meeting
    /// that began before the chart adds its stored readings (`meetingBase`) to the newer ones held in memory.
    private func chartSummary(history: HeartRateHistory, readings: [HeartRatePoint], meeting: CalendarMeeting?,
                              range: ClosedRange<Date>) -> (title: String, stats: (min: Int, avg: Int, max: Int))? {
        if let meeting {
            let window = LiveChart.statsWindow(meeting: meeting, range: range)
            var stats = history.stats
            if LiveChart.needsStoredReadings(meeting: meeting, range: range), let base = meetingBase,
               base.start == meeting.start, let combined = base.stats.adding(readings, within: window).summary {
                stats = combined
            }
            if let stats { return (LiveChart.statsTitle(meeting: meeting), stats) }
        }
        return HeartRateStats(readings).summary.map { (LiveChart.statsTitle(meeting: nil), $0) }
    }

    private func chartAccessibilityLabel(meeting: CalendarMeeting?, range: ClosedRange<Date>) -> String {
        var label = "Heart-rate history in beats per minute"
        if let meeting {
            let time = meeting.start.formatted(date: .omitted, time: .shortened)
            label += meeting.start >= range.lowerBound ? ". The meeting started at \(time)" : ". The meeting runs the whole span"
        }
        return label
    }

    private func meetingLegend(_ meeting: CalendarMeeting, now: Date) -> some View {
        let text = meeting.end > now
            ? "Shaded: meeting since \(meeting.start.formatted(date: .omitted, time: .shortened))"
            : "Shaded: meeting until \(meeting.end.formatted(date: .omitted, time: .shortened))"
        return Label {
            Text(text)
        } icon: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Self.meetingShade)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                .frame(width: legendSize * 1.2, height: legendSize)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }

    private static let meetingShade = Color.primary.opacity(0.10)

    private func chart(_ history: HeartRateHistory, meeting: CalendarMeeting?) -> some View {
        // Keep labels inside the plot; automatic ticks can land at a clipped edge.
        let tickOffsets: [TimeInterval] = typeSize.isAccessibilitySize ? [450] : [300, 600]
        let ticks = tickOffsets.map { history.range.lowerBound.addingTimeInterval($0) }
        let smooth = Self.smoothed(history.points)
        let shaded = meeting.flatMap { LiveChart.shaded($0, in: history.range) }
        let startRule = meeting.map(\.start).flatMap { history.range.contains($0) ? $0 : nil }
        return Chart {
            if let shaded {
                RectangleMark(xStart: .value("Meeting start", shaded.lowerBound),
                              xEnd: .value("Meeting end", shaded.upperBound))
                    .foregroundStyle(Self.meetingShade)
            }
            if let startRule {
                RuleMark(x: .value("Meeting start", startRule))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            ForEach(smooth, id: \.id) { point in
                AreaMark(x: .value("Time", point.time), yStart: .value("Floor", Double(history.bpmRange.lowerBound)),
                         yEnd: .value("BPM", point.bpm), series: .value("Segment", point.segment))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Theme.spike.opacity(0.28), Theme.spike.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.time), y: .value("BPM", point.bpm),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Theme.spike)
            }
            ForEach(history.points.filter(\.isolated)) { point in
                PointMark(x: .value("Time", point.reading.time), y: .value("BPM", point.reading.bpm))
                    .foregroundStyle(Theme.spike)
                    .symbolSize(14)
            }
            if let last = history.points.last?.reading {
                PointMark(x: .value("Latest reading", last.time), y: .value("BPM", last.bpm))
                    .foregroundStyle(Theme.spike)
                    .symbolSize(60)
                    // Kept inside the chart: the latest point sits on the right edge. At the largest text sizes
                    // the label would cover the line, and the heart card already shows the BPM big.
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if !typeSize.isAccessibilitySize {
                            Text("\(last.bpm)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.spike)
                        }
                    }
            }
        }
        .chartXScale(domain: history.range)
        .chartYScale(domain: history.bpmRange)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let time = value.as(Date.self) {
                        Text(time, format: .dateTime.hour().minute())
                            .fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
    }

    private struct SmoothPoint {
        let id: String
        let time: Date
        let bpm: Double
        let segment: Int
    }

    /// Per-second BPM is whole numbers, so a raw line looks like stairs.
    /// Plot 5-second means per segment; gaps stay gaps. Stats use raw readings.
    private static func smoothed(_ points: [HeartRateHistory.Point]) -> [SmoothPoint] {
        var buckets: [(segment: Int, slot: Int64, sum: Double, count: Double, time: Double)] = []
        for point in points where !point.isolated {
            let seconds = point.reading.time.timeIntervalSince1970
            let slot = Int64(seconds / 5)
            if let last = buckets.last, last.segment == point.segment, last.slot == slot {
                buckets[buckets.count - 1].sum += Double(point.reading.bpm)
                buckets[buckets.count - 1].count += 1
                buckets[buckets.count - 1].time += seconds
            } else {
                buckets.append((point.segment, slot, Double(point.reading.bpm), 1, seconds))
            }
        }
        return buckets.map {
            SmoothPoint(id: "\($0.segment).\($0.slot)", time: Date(timeIntervalSince1970: $0.time / $0.count),
                        bpm: $0.sum / $0.count, segment: $0.segment)
        }
    }

    private func stat(_ stats: (min: Int, avg: Int, max: Int), title: String) -> some View {
        let items = [("Min", stats.min), ("Avg", stats.avg), ("Max", stats.max)]
        return VStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                ForEach(items, id: \.0) { label, value in
                    VStack(spacing: 2) {
                        Text(value, format: .number)
                            .font(.headline.monospacedDigit())
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 8)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Go live

    private var goLiveCard: some View {
        let on = model.manualLive
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.setManualLive(!on)
            } label: {
                Label(on ? "Stop listening" : "Go live now",
                      systemImage: on ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(on ? Theme.bad : Theme.buttonFill)
            .accessibilityHint(on ? "Stops listening outside meetings" : "Listens and syncs now, outside a meeting")
            Text(on
                 ? "Listening outside meetings until you stop or quit the app."
                 : "Listen and sync now, even with no meeting. Stays on until you stop or quit the app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isListening(at: .now) {
                Button {
                    showLockScreenPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(model.liveActivityMode.liveTabLine)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Lock Screen heart rate choices")
            }
        }
        .card()
    }

    // MARK: Sync

    private var syncCard: some View {
        let sync = sync
        let liveTone: Color = sync.liveStatus == "Live syncing" ? Theme.good
            : sync.liveStatus.contains("retrying") || sync.liveStatus.contains("Settings") ? Theme.warn : .secondary
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sync")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            syncRow(
                icon: "dot.radiowaves.up.forward", color: liveTone, title: sync.liveStatus,
                detail: sync.lastLiveSync.map { "Last live sync \($0.formatted(date: .omitted, time: .standard))" }
            )
            syncRow(
                icon: sync.replayFailed ? "exclamationmark.icloud" : "checkmark.icloud",
                color: sync.replayFailed ? Theme.warn : .secondary,
                title: "Backup: \(sync.replayResult)",
                detail: sync.lastReplay.map { "Last backup \($0.formatted(.relative(presentation: .named)))" }
            )
            if model.storageIssue {
                syncRow(icon: "exclamationmark.triangle", color: Theme.warn,
                        title: "Local storage is temporarily unavailable", detail: nil)
            }
        }
        .card()
    }

    private func syncRow(icon: String, color: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The heart beside the BPM. While live it beats at the live heart rate, one
/// lub-dub per beat. With no live reading it's an empty outline; with Reduce
/// Motion on it stays filled but still.
private struct BeatingHeart: View {
    let bpm: Int?
    /// Spike green, or amber and red as the rate climbs over resting.
    let color: Color
    let animate: Bool
    let size: CGFloat

    var body: some View {
        if let bpm, animate {
            TimelineView(.animation) { context in
                let beat = Heartbeat.intensity(bpm: bpm, at: context.date.timeIntervalSinceReferenceDate)
                heart(filled: true).scaleEffect(1 + 0.14 * beat)
            }
        } else {
            heart(filled: bpm != nil)
        }
    }

    private func heart(filled: Bool) -> some View {
        Image(systemName: filled ? "heart.fill" : "heart")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(filled ? color : Color.secondary.opacity(0.4))
            .frame(width: size * 1.3, height: size * 1.2)
            .accessibilityHidden(true)
    }
}

/// The dashboard card, tinted and outlined in amber or red while the heart rate is elevated or high.
private struct SpikeCard: ViewModifier {
    let level: SpikeLevel?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let tint: Color? = switch level {
        case .elevated?, .high?: Theme.spikeColor(level ?? .normal)
        default: nil
        }
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background {
                shape.fill(Theme.card)
                if let tint { shape.fill(tint.opacity(0.08)) }
            }
            .overlay {
                if let tint { shape.strokeBorder(tint.opacity(0.7), lineWidth: 1.5) }
            }
    }
}

private extension View {
    func spikeCard(level: SpikeLevel?) -> some View { modifier(SpikeCard(level: level)) }
}
