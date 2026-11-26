import MeetspikeHRCore
import SwiftUI

/// The three choices for the meeting the menu shows right now: "Still going" (15 minutes more), "Ended now" and
/// "I didn't join". Shown only while a meeting is the current one (from two minutes before it to ten minutes after).
/// The buttons act on the Worker's copy of the meeting, found by matching the calendar meeting, so they stay out of
/// the way until that match is known.
@MainActor
struct MeetingChoicesSection: View {
    @ObservedObject var logger: Logger
    @ObservedObject var choices: MeetingChoices
    let now: Date

    var body: some View {
        let displayed = logger.meetings.displayedMeeting(at: now)
        let target = logger.liveTarget(at: now)
        let offer = LiveAdjust.offer(target, now: now)
        VStack(alignment: .leading, spacing: 6) {
            if displayed != nil {
                if target != nil {
                    HStack(spacing: 8) {
                        Button("Still going") { Task { await choices.stillGoing(target, now: .now) } }
                            .disabled(!offer.stillGoing || choices.busy)
                            .help("Adds 15 minutes to the end of this meeting.")
                        Button("Ended now") { Task { await choices.endedNow(target, now: .now) } }
                            .disabled(!offer.endedNow || choices.busy)
                            .help("Ends this meeting now.")
                        // Only while this meeting is current. The action is bound to the meeting on screen now.
                        if offer.didntJoin {
                            Button("I didn't join") { Task { await choices.didntJoin(target, now: .now) } }
                                .disabled(choices.busy)
                                .help("Leaves this meeting out of your scores. Just this one, even if it repeats.")
                        }
                    }
                    .controlSize(.small)
                } else {
                    Text("Can't match this meeting yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let used = choices.lastDidntJoin, now < used.until,
               !(target != nil && target?.meetingID != used.meetingID && offer.didntJoin) {
                HStack(spacing: 8) {
                    Text("Left out: \(used.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Undo") { Task { await choices.undoDidntJoin() } }
                        .controlSize(.small)
                        .disabled(choices.busy)
                        .help("Puts this meeting back.")
                }
            }
            if let note = choices.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(choices.noteIsProblem ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
