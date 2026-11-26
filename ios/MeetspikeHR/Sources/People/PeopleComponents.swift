import Charts
import MeetspikeHRCore
import SwiftUI

extension TodayTone {
    var peopleColor: Color {
        switch self {
        case .good: Theme.good
        case .warn: Theme.warn
        case .bad: Theme.bad
        case .none: .secondary
        }
    }
}

/// A rounded tinted label: "72% · Recovery (WHOOP)", "No score", "Elevated · WHOOP".
struct PeoplePill: View {
    let text: String
    let tone: TodayTone
    var accessibilityText: String?

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone.peopleColor)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tone.peopleColor.opacity(0.14), in: Capsule())
            .accessibilityLabel(accessibilityText ?? text)
    }
}

/// Round avatar with up to two initials.
struct PeopleAvatar: View {
    let name: String?
    let email: String?
    /// Grows with Dynamic Type, but is capped so the avatar never takes the row.
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 40

    var body: some View {
        let size = min(diameter, 64)
        Text(PeopleFormat.initials(name: name, email: email))
            .font(.system(size: size * 0.36, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.inset, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The heart rate line for a person: one point per meeting, oldest to newest. Drawn only with more than one point.
struct PeopleSparkline: View {
    /// Newest first, as the Worker sends it.
    let spark: [Double]
    let source: String?

    var body: some View {
        let points = PeopleLogic.sparkline(spark)
        if points.count > 1, let low = points.min(), let high = points.max() {
            Chart(Array(points.enumerated()), id: \.offset) { index, bpm in
                LineMark(x: .value("Meeting", index), y: .value("bpm", bpm))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: (low - 4)...(high + 4))
            .chartLegend(.hidden)
            .transaction { $0.animation = nil }
            .frame(height: 64)
            .accessibilityElement()
            .accessibilityLabel("\(source ?? "Heart rate") trend across \(points.count) meetings")
            .accessibilityValue("From \(Int(low.rounded())) to \(Int(high.rounded())) beats per minute")
        }
    }
}

/// Plain message for the empty, error, offline and sign-in states.
struct PeopleMessage: View {
    let symbol: String
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }
}

/// "Offline, showing data from <time>" strip shown above cached data.
/// A refresh failed while older data stays on screen. Styled like the Dates refresh error.
struct PeopleRefreshNote: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Theme.warn)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PeopleOfflineNote: View {
    let savedAt: Date

    var body: some View {
        Label(savedAt.peopleOfflineNote, systemImage: "wifi.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The range menu: the four presets and Custom.
struct PeopleRangeMenu: View {
    @ObservedObject var store: PeopleRangeStore
    let today: String
    var chooseCustom: () -> Void

    var body: some View {
        Menu {
            ForEach(PeopleRangePreset.allCases, id: \.self) { preset in
                Button {
                    store.range = .preset(preset)
                } label: {
                    if store.range == .preset(preset) {
                        Label(preset.menuLabel, systemImage: "checkmark")
                    } else {
                        Text(preset.menuLabel)
                    }
                }
            }
            Button {
                chooseCustom()
            } label: {
                if store.isCustom {
                    Label("Custom", systemImage: "checkmark")
                } else {
                    Text("Custom")
                }
            }
        } label: {
            Label(store.menuTitle(today: today), systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Date range, \(store.menuTitle(today: today))")
        .accessibilityHint("Choose how far back to look")
    }
}

/// Custom start and end days with Apply. Invalid pairs stay on the sheet with a plain reason.
struct PeopleCustomRangeSheet: View {
    let today: String
    let initial: DatesSpan
    var apply: (DatesSpan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    init(today: String, initial: DatesSpan, apply: @escaping (DatesSpan) -> Void) {
        self.today = today
        self.initial = initial
        self.apply = apply
        _start = State(initialValue: DayMath.date(initial.start) ?? Date())
        _end = State(initialValue: DayMath.date(initial.end) ?? Date())
    }

    private var span: DatesSpan { DatesSpan(start: DayMath.string(start), end: DayMath.string(end)) }
    private var isValid: Bool { PeopleLogic.validCustomDates(start: span.start, end: span.end) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start date", selection: $start, displayedComponents: .date)
                    DatePicker("End date", selection: $end, displayedComponents: .date)
                } footer: {
                    if !isValid {
                        Text("Pick a start day on or before the end day.").foregroundStyle(Theme.bad)
                    }
                }
            }
            .environment(\.timeZone, Self.utc)
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(span)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: Companies

/// The People | Companies switch above both lists.
struct PeopleModePicker: View {
    @Binding var mode: PeopleMode

    var body: some View {
        Picker("Show", selection: $mode) {
            ForEach(PeopleMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.background)
    }
}

/// Square badge with a company's initials. Rounded square, so it never reads as a person's avatar.
struct CompanyBadge: View {
    let name: String?
    let domain: String
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 40

    var body: some View {
        let size = min(side, 64)
        Text(CompanyLogic.initials(name, domain: domain))
            .font(.system(size: size * 0.36, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Tappable company chips under a meeting. Inside the People stack they push the company page; elsewhere
/// (`open` set) they call `open`, which switches tabs.
struct CompanyChips: View {
    let companies: [CompanyTag]
    /// A company not to show, for example the one whose page this is.
    var excluding: String?
    var open: ((CompanyTag) -> Void)?

    private var shown: [CompanyTag] { companies.filter { $0.domain != excluding } }

    var body: some View {
        if !shown.isEmpty {
            ChipFlow(spacing: 6) {
                ForEach(shown) { company in
                    if let open {
                        Button { open(company) } label: { CompanyChipLabel(company: company) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(company.displayName)")
                    } else {
                        NavigationLink(value: PeopleRoute.company(CompanyRoute(company))) {
                            CompanyChipLabel(company: company)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(company.displayName)")
                    }
                }
            }
        }
    }
}

private struct CompanyChipLabel: View {
    let company: CompanyTag

    var body: some View {
        Label {
            Text(verbatim: company.displayName).lineLimit(1)
        } icon: {
            Image(systemName: "building.2").imageScale(.small)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.accent.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }
}

/// Lines chips up under a `PersonMeetingRow`'s title (past the day column), or flush left at accessibility sizes
/// where the row stacks.
private struct PeopleChipInset: ViewModifier {
    let hasChips: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : 68)
            .padding(.bottom, hasChips ? 10 : 0)
    }
}

extension View {
    func peopleChipInset(hasChips: Bool) -> some View { modifier(PeopleChipInset(hasChips: hasChips)) }
}

/// Lays chips out left to right and wraps to the next line when a row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, min(x - spacing, width))
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The heart rate lines per provider, as on a person page: summary line, badge, note and the sparkline.
struct PeopleTrendLines: View {
    let trends: [PersonSourceTrend]

    var body: some View {
        ForEach(trends.filter { ($0.withCoverage ?? 0) > 0 }) { trend in
            VStack(alignment: .leading, spacing: 6) {
                Text(PeopleFormat.hrLine(
                    source: trend.source, withCoverage: trend.withCoverage ?? 0, medianBpm: trend.medianAvgBpm,
                    elevated: trend.elevated, watching: trend.watching, restored: trend.restored
                ))
                .font(.subheadline)
                if let badge = trend.badge, !badge.isEmpty {
                    Text(badge).font(.subheadline.weight(.bold))
                }
                if let note = trend.badgeNote, !note.isEmpty {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                PeopleSparkline(spark: trend.spark, source: trend.source)
            }
            .padding(.top, 4)
        }
    }
}
