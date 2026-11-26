import Foundation
import MeetspikeHRCore
import UserNotifications

/// Local "turn on HR Broadcast" notifications. BroadcastPlan decides what to
/// schedule: two minutes before each meeting, one follow-up a minute in, and
/// a "you can turn it off" when the listening block ends. Nothing is scheduled
/// unless the Worker confirmed this phone as reminder owner, so the Mac and the
/// phone never both remind about the same meeting. While the Worker pushes the
/// reminders instead (it only does when no heart rate is coming in), nothing is
/// scheduled here either, but the plan and `covered` are still worked out.
@MainActor
final class BroadcastReminders {
    private struct Request: Equatable {
        let schedule: MeetingSchedule
        let ownerUntil: Date?
        let pushActive: Bool
    }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private static let satisfiedKey = "satisfiedBroadcastReminders"
    private static let coveredKey = "coveredBroadcastMeetings"
    private var queued: Request?
    private var worker: Task<Void, Never>?
    private(set) var planned: [PlannedReminder] = []
    /// Meeting starts this phone scheduled a reminder for, sent with its
    /// check-in so the Mac stays quiet about these only.
    private(set) var covered: [Date]
    /// Called after a reconcile changes `covered`.
    var onCoveredChange: (() -> Void)?

    init() {
        covered = (UserDefaults.standard.array(forKey: Self.coveredKey) as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
    }

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func authorization() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func update(for schedule: MeetingSchedule, ownerUntil: Date?, pushActive: Bool) {
        queued = Request(schedule: schedule, ownerUntil: ownerUntil, pushActive: pushActive)
        guard worker == nil else { return }
        worker = Task {
            while let request = queued {
                queued = nil
                await reconcile(request)
            }
            worker = nil
        }
    }

    /// Heart rate is coming in, so drop the on and follow-up reminders for a
    /// meeting about to start or just started.
    func heartRateArrived(at time: Date) {
        let ids = BroadcastPlan.satisfied(byReadingAt: time, in: planned)
        guard !ids.isEmpty else { return }
        var satisfied = satisfiedIDs(now: time)
        let fresh = ids.filter { !satisfied.contains($0) }
        guard !fresh.isEmpty else { return }
        satisfied.formUnion(fresh)
        defaults.set(Array(satisfied), forKey: Self.satisfiedKey)
        center.removePendingNotificationRequests(withIdentifiers: fresh)
        planned.removeAll { fresh.contains($0.id) }
    }

    /// Ids stay satisfied until their meeting is an hour old, so a replan does
    /// not put them back.
    private func satisfiedIDs(now: Date) -> Set<String> {
        let stored = defaults.stringArray(forKey: Self.satisfiedKey) ?? []
        return Set(stored.filter { id in
            BroadcastPlan.anchor(of: id).map { $0 > now.addingTimeInterval(-3_600) } ?? false
        })
    }

    private func reconcile(_ request: Request) async {
        let access = await authorization()
        let now = Date.now
        let eligible = (access == .authorized || access == .provisional) && (request.ownerUntil.map { $0 > now } ?? false)
        let satisfied = satisfiedIDs(now: now)
        let plan = eligible
            ? BroadcastPlan.plan(request.schedule, now: now, ownerUntil: request.ownerUntil, satisfied: satisfied)
            : []
        planned = plan
        // Covered comes from the whole plan, whoever delivers it, so the Mac stays quiet about these meetings.
        setCovered(eligible ? BroadcastPlan.covered(plan: plan, satisfied: satisfied, previous: covered, now: now) : [])
        // Push only counts while this phone's check-in is still good.
        let wanted = ReminderDelivery.pending(plan: plan, pushActive: request.pushActive && eligible)
        let pending = await center.pendingNotificationRequests().map {
            BroadcastPlan.Pending(id: $0.identifier, title: $0.content.title, body: $0.content.body)
        }
        let changes = BroadcastPlan.changes(pending: pending, plan: wanted)
        center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        for item in changes.add {
            guard queued == nil else { return }
            try? await center.add(notification(for: item))
        }
    }

    private func setCovered(_ value: [Date]) {
        guard value != covered else { return }
        covered = value
        defaults.set(value.map(\.timeIntervalSince1970), forKey: Self.coveredKey)
        onCoveredChange?()
    }

    private func notification(for item: PlannedReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        if item.kind != .off { content.interruptionLevel = .timeSensitive }
        // An absolute UTC time, so a time zone change does not move it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second, .timeZone]
        let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents(fields, from: item.fireAt), repeats: false)
        return UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
    }
}
