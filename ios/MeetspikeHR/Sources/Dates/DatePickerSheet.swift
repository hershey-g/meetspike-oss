import MeetspikeHRCore
import SwiftUI

/// The date picker sheet (`renderPicker` in public/app.js). Present it from any tab:
///
///     .sheet(isPresented: $showPicker) { DatePickerSheet(start: env.selectedDay, end: env.selectedDay) }
///
/// One day goes to the Today tab, a range to Dates, through `AppEnvironment.openDay` and `openSpan`. There is no
/// cap on the number of days. Future days are disabled, using the server's today.
struct DatePickerSheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var picker: DatesPicker
    private let startedEmpty: Bool

    private static let weekdayHeaders = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    init(start: String?, end: String?) {
        let seed = end ?? start ?? DayMath.today(in: AppEnvironment.defaultTimeZone)
        _picker = State(initialValue: DatesPicker(start: start, end: end, today: seed))
        startedEmpty = start == nil && end == nil
    }

    var body: some View {
        let today = env.today
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                fields(today: today)
                chips(today: today)
                monthHeader(today: today)
                grid(today: today)
                Text(DatesCalendar.note(picker, today: today))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                applyButton(today: today)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Opened with nothing chosen: show the server's month, not the phone's.
            if startedEmpty { picker.month = String(env.today.prefix(7)) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text("Pick dates").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Clear") { picker.clear() }
                .disabled(picker.start == nil && picker.end == nil)
            Button("Close") { dismiss() }
                .padding(.leading, 12)
        }
        .font(.body.weight(.medium))
    }

    private func fields(today: String) -> some View {
        HStack(spacing: 12) {
            field(title: "From", day: picker.start, selected: picker.editing == .start || picker.start == nil, today: today) {
                picker.select(.start)
            }
            field(title: "To", day: picker.end, selected: picker.editing == .end, today: today) {
                picker.select(.end)
            }
            .disabled(picker.start == nil)
        }
    }

    private func field(title: String, day: String?, selected: Bool, today: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(day.map { DatesFormat.shortDay($0, today: today) } ?? "Pick")
                    .font(.headline)
                    .foregroundStyle(day == nil ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chips(today: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DatesLogic.quickChips(today: today)) { chip in
                    Button(chip.label) { picker.choose(chip) }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(picker.span == chip.span ? Theme.accent.opacity(0.22) : Theme.inset, in: Capsule())
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picker.span == chip.span ? .isSelected : [])
                }
            }
        }
    }

    private func monthHeader(today: String) -> some View {
        HStack {
            Button {
                picker.moveMonth(-1, today: today)
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(DatesFormat.monthTitle(picker.month))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                picker.moveMonth(1, today: today)
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(picker.month >= String(today.prefix(7)))
            .accessibilityLabel("Next month")
        }
    }

    private func grid(today: String) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        let cells = DatesCalendar.cells(month: picker.month)
        return VStack(spacing: 4) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Self.weekdayHeaders, id: \.self) { name in
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day, today: today) } else { Color.clear.frame(height: 40) }
                }
            }
        }
    }

    private func cell(_ day: String, today: String) -> some View {
        let selected = day == picker.start || day == picker.end
        let hasBand = picker.start != nil && picker.end != nil && picker.start != picker.end
        let inBand = hasBand && day >= (picker.start ?? "") && day <= (picker.end ?? "")
        let isFirst = inBand && day == picker.start
        let isLast = inBand && day == picker.end
        let isToday = day == today
        return Button {
            picker.pick(day)
        } label: {
            Text(DatesFormat.dayNumber(day))
                .font(.body.weight(selected ? .bold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if selected { Circle().fill(Theme.buttonFill) }
                }
                .overlay {
                    if isToday && !selected { Circle().strokeBorder(Theme.accent, lineWidth: 1.5) }
                }
        }
        .buttonStyle(.plain)
        .disabled(day > today)
        .opacity(day > today ? 0.3 : 1)
        .background {
            if inBand {
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? 20 : 0, bottomLeadingRadius: isFirst ? 20 : 0,
                    bottomTrailingRadius: isLast ? 20 : 0, topTrailingRadius: isLast ? 20 : 0
                )
                .fill(Theme.accent.opacity(0.18))
            }
        }
        .accessibilityLabel(DatesFormat.longDay(day) + (isToday ? ", today" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func applyButton(today: String) -> some View {
        Button {
            apply()
        } label: {
            Text(DatesCalendar.applyTitle(picker, today: today))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.buttonFill)
        .disabled(picker.span == nil)
    }

    private func apply() {
        guard let span = picker.span else { return }
        dismiss()
        switch DatesLogic.destination(for: span) {
        case .today(let day): env.openDay(day)
        case .dates(let span): env.openSpan(span)
        }
    }
}
