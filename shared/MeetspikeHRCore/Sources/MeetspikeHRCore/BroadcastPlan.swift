import Foundation

/// One local notification the iPhone schedules around a meeting.
public struct PlannedReminder: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Two minutes before the meeting: turn on HR Broadcast.
        case on
        /// One minute into the meeting, removed once heart rate arrives.
        case followUp
        /// When the listening block ends, cooldown included.
        case off
    }

    public let kind: Kind
    public let fireAt: Date
    /// The meeting start for on and followUp; the block end for off.
    public let anchor: Date
    public let title: String
    public let body: String

    public var id: String { "\(BroadcastPlan.prefix)\(kind.rawValue).\(anchor.unixMilliseconds)" }
}

/// What the iPhone schedules. It schedules nothing unless the Worker confirmed
/// it as reminder owner, and nothing past that confirmation's expiry, so the
/// Mac takes over cleanly when the phone stops checking in.
public enum BroadcastPlan {
    public static let prefix = "meetspike.broadcast."
    public static let lead: TimeInterval = 120
    public static let followUpAfter: TimeInterval = 60
    /// iOS keeps at most 64 pending requests per app.
    public static let maxPending = 60
    /// A reading this long before a meeting means the broadcast is already on.
    static let alreadyOnBefore: TimeInterval = 300

    public static func plan(
        _ schedule: MeetingSchedule, now: Date, ownerUntil: Date?, satisfied: Set<String> = []
    ) -> [PlannedReminder] {
        guard let ownerUntil, ownerUntil > now else { return [] }
        var items: [PlannedReminder] = []
        for meeting in schedule.meetings {
            let name = "“\(meeting.title)”"
            items.append(PlannedReminder(
                kind: .on, fireAt: meeting.start.addingTimeInterval(-lead), anchor: meeting.start,
                title: "Turn on HR Broadcast in the WHOOP app",
                body: "\(name) starts in 2 minutes. In WHOOP, open Device Settings and turn on HR Broadcast."
            ))
            items.append(PlannedReminder(
                kind: .followUp, fireAt: meeting.start.addingTimeInterval(followUpAfter), anchor: meeting.start,
                title: "Still no heart rate",
                body: "\(name) has started and no heart rate is coming in. Turn on HR Broadcast in the WHOOP app."
            ))
        }
        for block in schedule.blocks {
            items.append(PlannedReminder(
                kind: .off, fireAt: block.end, anchor: block.end,
                title: "You can turn off HR Broadcast",
                body: "“\(block.last.title)” is over and the cooldown is captured."
            ))
        }
        var seen = Set<String>()
        return items
            .filter { $0.fireAt > now && $0.fireAt < ownerUntil && !satisfied.contains($0.id) }
            .sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }
            .filter { seen.insert($0.id).inserted }
            .prefix(maxPending)
            .map { $0 }
    }

    /// The on and follow-up reminders a reading at `time` makes unnecessary:
    /// heart rate is coming in from five minutes before a meeting through its first minute.
    public static func satisfied(byReadingAt time: Date, in planned: [PlannedReminder]) -> [String] {
        planned.filter { item in
            item.kind != .off
                && time >= item.anchor.addingTimeInterval(-alreadyOnBefore)
                && time <= item.anchor.addingTimeInterval(followUpAfter)
        }.map(\.id)
    }

    /// A started meeting stays covered this long, so the Mac does not take
    /// over mid-meeting once the phone's on reminder has fired.
    static let keepCoveredAfterStart: TimeInterval = 12 * 3_600

    /// The meeting starts the phone vouches for, sent with its check-in: every
    /// meeting with an on reminder in the plan or satisfied by heart rate, plus
    /// meetings it covered before whose on reminder already fired. Future meetings that left the plan
    /// drop out, so the Mac reminds about them. Earliest first, at most maxPending.
    public static func covered(
        plan: [PlannedReminder], satisfied: Set<String>, previous: [Date], now: Date
    ) -> [Date] {
        var starts = Set(plan.filter { $0.kind == .on }.map(\.anchor.unixMilliseconds))
        for id in satisfied where id.hasPrefix("\(prefix)\(PlannedReminder.Kind.on.rawValue).") {
            if let start = anchor(of: id) { starts.insert(start.unixMilliseconds) }
        }
        // Its on reminder already fired, so it is no longer in the plan.
        for start in previous where start.addingTimeInterval(-lead) <= now
            && now.timeIntervalSince(start) < keepCoveredAfterStart {
            starts.insert(start.unixMilliseconds)
        }
        return starts.sorted().prefix(maxPending).map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    /// A notification request already pending with iOS.
    public struct Pending: Equatable, Sendable {
        public let id: String
        public let title: String
        public let body: String

        public init(id: String, title: String, body: String) {
            self.id = id
            self.title = title
            self.body = body
        }
    }

    /// What to remove and what to add so pending matches the plan. A pending
    /// request whose text changed (a renamed meeting) is replaced.
    public static func changes(pending: [Pending], plan: [PlannedReminder]) -> (remove: [String], add: [PlannedReminder]) {
        let ours = pending.filter { $0.id.hasPrefix(prefix) }
        let wanted = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(ours.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remove = ours.filter { item in
            guard let want = wanted[item.id] else { return true }
            return want.title != item.title || want.body != item.body
        }.map(\.id)
        let removed = Set(remove)
        let add = plan.filter { current[$0.id] == nil || removed.contains($0.id) }
        return (remove, add)
    }

    /// The meeting start encoded in a reminder id, to forget old satisfied ids.
    public static func anchor(of id: String) -> Date? {
        guard let ms = id.split(separator: ".").last.flatMap({ Int64($0) }) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
    }
}
