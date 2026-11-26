import MeetspikeHRCore
import SwiftUI
import UIKit

/// Holds what a meeting menu is asking right now (the "Just this one" / "All of them" question, the times sheet) and
/// turns a tap into an edit. The screen owns one and shows the question and the sheet; the rows and menus only call
/// `choose`. Nothing here sends anything by itself: it hands the edit to `MeetingChoices`.
@MainActor
final class MeetingActionController: ObservableObject {
    struct ScopeAsk: Identifiable {
        let id = UUID()
        let event: Meeting
        let pending: MeetingActions.Pending
    }

    struct TimesAsk: Identifiable {
        let id = UUID()
        let event: Meeting
        let start: Date
        let end: Date
    }

    @Published var scope: ScopeAsk?
    @Published var times: TimesAsk?

    /// A menu item or note button was tapped.
    func choose(_ action: MeetingActions.Action, _ event: Meeting, env: AppEnvironment) {
        switch MeetingActions.plan(action, override: event.override) {
        case .save(let edit):
            send(edit, event, env: env)
        case .askScope(let pending):
            scope = ScopeAsk(event: event, pending: pending)
        case .askTimes:
            let start = APITime.parse(event.startUtc) ?? Date()
            let end = APITime.parse(event.endUtc) ?? start.addingTimeInterval(1_800)
            times = TimesAsk(event: event, start: start, end: end)
        }
    }

    /// "Just this one" or "All of them".
    func answer(_ scopeChoice: MeetingOverride.Scope, env: AppEnvironment) {
        guard let ask = scope else { return }
        scope = nil
        send(MeetingActions.answer(scopeChoice, to: ask.pending, override: ask.event.override), ask.event, env: env)
    }

    /// The times sheet's Save.
    func saveTimes(_ ask: TimesAsk, start: Date, end: Date, env: AppEnvironment) -> MeetingActions.TimesProblem? {
        let calendar = MeetingActions.CalendarBounds.of(
            rowStart: APITime.parse(ask.event.startUtc), rowEnd: APITime.parse(ask.event.endUtc), override: ask.event.override)
        switch MeetingActions.times(start: start, end: end, calendar: calendar) {
        case .failure(let problem):
            return problem
        case .success(let edit):
            times = nil
            send(edit, ask.event, env: env)
            return nil
        }
    }

    private func send(_ edit: OverrideEdit, _ event: Meeting, env: AppEnvironment) {
        let days: Set<String> = event.day.map { [$0] } ?? []
        Task {
            let result = await env.choices.submit(edit, meetingID: event.id, days: days)
            // The row shows the note too. Say it aloud for VoiceOver, where a quiet line can be missed.
            UIAccessibility.post(notification: .announcement, argument: result.message ?? "Saved.")
        }
    }
}

/// The items of the meeting menu: the same list in the long press menu and under the "..." button.
struct MeetingMenuItems: View {
    let event: Meeting
    @EnvironmentObject private var actions: MeetingActionController
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Button("I didn't join", systemImage: "person.fill.xmark") { actions.choose(.notJoined, event, env: env) }
        Button("Don't link this meeting", systemImage: "link.badge.plus") { actions.choose(.unlinked, event, env: env) }
        Button("Meeting times", systemImage: "clock") { actions.choose(.times, event, env: env) }
        if MeetingActions.hasOwnTimes(event.override) {
            Button("Use calendar times", systemImage: "calendar") { actions.choose(.calendarTimes, event, env: env) }
        }
        if MeetingActions.canUndo(event.override) {
            Button("Undo", systemImage: "arrow.uturn.backward") { actions.choose(.undo, event, env: env) }
        }
    }
}

/// The "..." button in an opened meeting. At least 44 pt, and named for VoiceOver.
struct MeetingOptionsButton: View {
    let event: Meeting

    var body: some View {
        Menu {
            MeetingMenuItems(event: event)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Meeting options")
    }
}

/// VoiceOver actions for a row whose children are hidden, so the menu is reachable without a long press.
struct MeetingAccessibilityActions: ViewModifier {
    let event: Meeting
    @EnvironmentObject private var actions: MeetingActionController
    @EnvironmentObject private var env: AppEnvironment

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "I didn't join") { actions.choose(.notJoined, event, env: env) }
            .accessibilityAction(named: "Don't link this meeting") { actions.choose(.unlinked, event, env: env) }
            .accessibilityAction(named: "Meeting times") { actions.choose(.times, event, env: env) }
    }
}

/// A meeting left out: dimmed, says why, and a tap puts it back. No chart, no score.
struct ExcludedMeetingRow: View {
    let event: Meeting
    @EnvironmentObject private var actions: MeetingActionController
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        let label = MeetingActions.excludedLabel(event.override)
        Button {
            actions.choose(.undo, event, env: env)
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
                    Text(label).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("Undo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .opacity(0.6)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TodayFormat.clockFromLocal(event.startLocal)), \(event.title ?? "Untitled"), \(label)")
        .accessibilityHint("Puts it back")
        .accessibilityAddTraits(.isButton)
    }
}

/// The quiet question under a meeting the Mac never saw Zoom for.
struct SkippedNote: View {
    let event: Meeting
    @EnvironmentObject private var actions: MeetingActionController
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            Text(MeetingActions.skippedQuestion)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Yes") { actions.choose(.skipYes, event, env: env) }
                .frame(minWidth: 44, minHeight: 44)
            Button("No") { actions.choose(.skipNo, event, env: env) }
                .frame(minWidth: 44, minHeight: 44)
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        // Under the title, past the 64 pt time column and its 12 pt gap.
        .padding(.leading, 76)
        .accessibilityElement(children: .contain)
    }
}

/// What to say under a meeting after a choice: it is waiting to be sent, or it could not be saved.
struct MeetingChoiceLine: View {
    let eventID: String
    @ObservedObject var choices: MeetingChoices

    var body: some View {
        if let note = choices.notes[eventID] {
            line(note, color: choices.waiting.contains(eventID) ? Theme.warn : Theme.bad)
        } else if choices.waiting.contains(eventID) {
            line("Sends when you are online.", color: .secondary)
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 76)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Start and end pickers, in the time zone the day is shown in.
struct MeetingTimesSheet: View {
    let ask: MeetingActionController.TimesAsk
    let zone: TimeZone

    @EnvironmentObject private var actions: MeetingActionController
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var problem: String?

    init(ask: MeetingActionController.TimesAsk, zone: TimeZone) {
        self.ask = ask
        self.zone = zone
        _start = State(initialValue: ask.start)
        _end = State(initialValue: ask.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        .frame(minHeight: 44)
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                        .frame(minHeight: 44)
                } header: {
                    Text(ask.event.title?.isEmpty == false ? ask.event.title ?? "" : "Untitled")
                } footer: {
                    Text("Times are in \(zone.localizedName(for: .standard, locale: .current) ?? zone.identifier). This only changes Meetspike, not your calendar.")
                }
                if let problem {
                    Text(problem).foregroundStyle(Theme.bad).accessibilityAddTraits(.updatesFrequently)
                }
                if MeetingActions.hasOwnTimes(ask.event.override) {
                    Section {
                        Button("Use calendar times") {
                            actions.times = nil
                            actions.choose(.calendarTimes, ask.event, env: env)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .environment(\.timeZone, zone)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Meeting times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { actions.times = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save times") {
                        problem = actions.saveTimes(ask, start: start, end: end, env: env)?.message
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// The scope question and the times sheet for the meeting menu. Attach once on the screen.
    func meetingActionDialogs(_ actions: MeetingActionController, zone: TimeZone, env: AppEnvironment) -> some View {
        modifier(MeetingActionDialogs(actions: actions, zone: zone, env: env))
    }
}

private struct MeetingActionDialogs: ViewModifier {
    @ObservedObject var actions: MeetingActionController
    let zone: TimeZone
    let env: AppEnvironment

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                actions.scope.map { MeetingActions.scopeTitle($0.pending) } ?? "",
                isPresented: Binding(get: { actions.scope != nil }, set: { if !$0 { actions.scope = nil } }),
                titleVisibility: .visible
            ) {
                Button("Just this one") { actions.answer(.event, env: env) }
                Button("All of them") { actions.answer(.series, env: env) }
                Button("Cancel", role: .cancel) { actions.scope = nil }
            } message: {
                Text("This meeting repeats.")
            }
            .sheet(item: $actions.times) { ask in
                MeetingTimesSheet(ask: ask, zone: zone)
                    .environmentObject(actions)
                    .environmentObject(env)
                    .tint(Theme.accent)
            }
    }
}
