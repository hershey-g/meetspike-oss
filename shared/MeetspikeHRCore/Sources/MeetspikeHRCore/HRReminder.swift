import Foundation

/// What the Worker says about the calendar: the meeting starting within two
/// minutes or in progress (GET /api/whoop-web/reminder).
public struct ReminderMeeting: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String?
    /// The calendar start. Older Workers leave it out.
    public let start: Date?

    public init(id: String, title: String?, start: Date? = nil) {
        self.id = id
        self.title = title
        self.start = start
    }

    private enum CodingKeys: String, CodingKey { case id, title, startUtc }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        start = (try? container.decodeIfPresent(String.self, forKey: .startUtc)).flatMap(ReminderDate.parse)
    }
}

/// Which app sends the broadcast reminders. The other one stays quiet.
public enum ReminderOwner: String, Decodable, Sendable {
    case phone, mac
}

public struct ReminderLookup: Decodable, Sendable {
    let ok: Bool
    public let meeting: ReminderMeeting?
    public let pushover: Bool
    /// Older Workers leave it out, which means the Mac.
    public let owner: ReminderOwner
    public let ownerUntil: Date?
    /// Whether the Worker sees heart rate coming in from any device right now. Nil when it could not check, or when
    /// an older Worker leaves it out.
    public let live: Bool?

    private enum CodingKeys: String, CodingKey { case ok, meeting, pushover, owner, ownerUntil, live }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        meeting = try container.decodeIfPresent(ReminderMeeting.self, forKey: .meeting)
        pushover = try container.decodeIfPresent(Bool.self, forKey: .pushover) ?? false
        owner = (try? container.decodeIfPresent(ReminderOwner.self, forKey: .owner)) ?? .mac
        ownerUntil = (try? container.decodeIfPresent(String.self, forKey: .ownerUntil)).flatMap(ReminderDate.parse)
        live = (try? container.decodeIfPresent(Bool.self, forKey: .live)) ?? nil
    }

    /// True when the phone scheduled a reminder for the meeting in this
    /// lookup, so the Mac stays quiet about that meeting only. The Worker
    /// answers "phone" per meeting; no meeting is always the Mac's.
    public func phoneOwnsMeeting(at now: Date) -> Bool {
        meeting != nil && owner == .phone && (ownerUntil.map { $0 > now } ?? true)
    }

    /// True while the phone has a fresh check-in, for the Settings note. It
    /// does not silence the Mac by itself.
    public func phoneCheckedIn(at now: Date) -> Bool {
        ownerUntil.map { $0 > now } ?? false
    }
}

/// The Worker's answer to an iPhone check-in (POST /api/whoop-web/reminder/owner).
public struct ReminderOwnerReply: Decodable, Sendable {
    let ok: Bool
    public let owner: ReminderOwner
    public let ownerUntil: Date?
    /// True when the Worker will send this phone the reminders as pushes. Missing or malformed is false.
    public let push: Bool

    private enum CodingKeys: String, CodingKey { case ok, owner, ownerUntil, push }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        owner = try container.decode(ReminderOwner.self, forKey: .owner)
        ownerUntil = (try? container.decodeIfPresent(String.self, forKey: .ownerUntil)).flatMap(ReminderDate.parse)
        push = ((try? container.decodeIfPresent(Bool.self, forKey: .push)) ?? nil) ?? false
    }
}

enum ReminderDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// ISO UTC with milliseconds, e.g. 2026-11-24T14:00:00.000Z.
    static func format(_ date: Date) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        return fractional.string(from: date)
    }
}

struct ReminderOwnerPost: Encodable {
    let active: Bool
    /// Starts of the meetings the phone scheduled a reminder for. The Mac
    /// stays quiet about these only.
    let covered: [String]
    /// The device token for server pushes. Only sent while checking in.
    let push: PushRegistration?

    init(active: Bool, covered: [Date], push: PushRegistration? = nil) {
        self.active = active
        self.push = active ? push : nil
        self.covered = active
            ? Array(Set(covered.map(\.unixMilliseconds)).sorted().prefix(BroadcastPlan.maxPending))
                .map { ReminderDate.format(Date(timeIntervalSince1970: TimeInterval($0) / 1_000)) }
            : []
    }
}

extension ReminderOwnerPost {
    private enum CodingKeys: String, CodingKey { case active, covered, push }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(active, forKey: .active)
        try container.encode(covered, forKey: .covered)
        try container.encodeIfPresent(push, forKey: .push)
    }
}

struct ReminderPost: Encodable {
    let title: String?
    let repeated: Bool

    private enum CodingKeys: String, CodingKey { case title, repeated = "repeat" }
}

/// One "turn on HR Broadcast" alert to show.
public struct HRReminderAlert: Equatable, Sendable {
    public let key: String
    public let title: String?
    public let isRepeat: Bool

    public var heading: String { isRepeat ? "Still no heart rate" : "Turn on HR Broadcast in the WHOOP app" }

    public var message: String {
        if isRepeat {
            return "Still no heart rate for \(title.map { "“\($0)”" } ?? "your meeting"). Turn on HR Broadcast in the WHOOP app."
        }
        return "\(title.map { "“\($0)” is starting" } ?? "A meeting is starting"). Turn on HR Broadcast in the WHOOP app."
    }
}

/// Decides when the Mac reminds. A meeting is starting when Zoom has a meeting
/// open or the Worker reports a calendar meeting starting within two minutes
/// (or in progress). The first alert goes out when heart rate is silent (no
/// reading for 60 seconds). One follow-up goes out if no reading arrived in the
/// meeting's first minute: at start + 60 s for a calendar meeting, and two
/// minutes after the first alert for a Zoom call.
public struct HRReminderPolicy: Sendable {
    public static let silence: TimeInterval = 60
    /// The follow-up waits for the meeting's first minute.
    public static let followUpAfterStart: TimeInterval = 60
    /// And never comes sooner than this after the first alert.
    public static let followUpGap: TimeInterval = 120
    /// How often the app asks the Worker about the calendar while heart rate is silent.
    public static let lookupInterval: TimeInterval = 60
    private static let forgetAfter: TimeInterval = 12 * 3_600

    private struct Sent { let first: Date; let start: Date; var repeated: Bool }
    private var sent: [String: Sent] = [:]
    private var zoomSince: Date?

    public init() {}

    /// The later of the Mac's own last reading and the moment the Worker said heart rate was coming in, so nothing
    /// alerts while any device streams.
    public static func effectiveLastReading(local: Date?, serverLiveAt: Date?) -> Date? {
        switch (local, serverLiveAt) {
        case let (local?, server?): return max(local, server)
        case let (local?, nil): return local
        case let (nil, server?): return server
        case (nil, nil): return nil
        }
    }

    /// True while the Mac should hold every reminder in meeting-only mode: listening already started (five minutes
    /// before a meeting) but the next meeting is still more than two minutes away, and no meeting is running or in its
    /// after-window. Reminders stay at two minutes before, as before the longer listening lead-in.
    public static func tooEarly(now: Date, meetings: [CalendarMeeting]) -> Bool {
        let inReminderWindow = meetings.contains {
            now >= $0.start.addingTimeInterval(-BroadcastPlan.lead)
                && now <= $0.end.addingTimeInterval(CalendarMeeting.cooldown)
        }
        guard !inReminderWindow else { return false }
        return meetings.contains {
            now >= $0.start.addingTimeInterval(-CalendarMeeting.leadIn)
                && now < $0.start.addingTimeInterval(-BroadcastPlan.lead)
        }
    }

    /// True when no reading arrived in the last minute.
    public static func heartRateSilent(lastReadingAt: Date?, now: Date) -> Bool {
        guard let lastReadingAt else { return true }
        return now.timeIntervalSince(lastReadingAt) >= silence
    }

    /// Call on every check, also while readings arrive, so a Zoom meeting's
    /// start time is tracked. Returns the alert to show now, if any.
    public mutating func evaluate(
        now: Date, lastReadingAt: Date?, zoomActive: Bool, meeting: ReminderMeeting?
    ) -> HRReminderAlert? {
        if zoomActive {
            if zoomSince == nil { zoomSince = now }
        } else {
            zoomSince = nil
        }
        sent = sent.filter { now.timeIntervalSince($0.value.first) < Self.forgetAfter }
        guard Self.heartRateSilent(lastReadingAt: lastReadingAt, now: now) else { return nil }

        // A Zoom call that is also on the calendar is one meeting: keep
        // whichever key alerted first so it is not reminded twice.
        let zoomKey = zoomSince.map { "zoom:\(Int64($0.timeIntervalSince1970))" }
        let calendarKey = meeting.map { "calendar:\($0.id)" }
        let key: String
        let start: Date
        if let zoomKey, sent[zoomKey] != nil, let zoomSince {
            (key, start) = (zoomKey, zoomSince)
        } else if let calendarKey, let meeting {
            (key, start) = (calendarKey, meeting.start ?? now)
        } else if let zoomKey, let zoomSince {
            (key, start) = (zoomKey, zoomSince)
        } else {
            return nil
        }
        let title = meeting?.title.flatMap { $0.isEmpty ? nil : $0 } ?? (meeting == nil ? "Zoom meeting" : nil)
        guard var record = sent[key] else {
            sent[key] = Sent(first: now, start: start, repeated: false)
            return HRReminderAlert(key: key, title: title, isRepeat: false)
        }
        let followUpAt = max(record.start.addingTimeInterval(Self.followUpAfterStart),
                             record.first.addingTimeInterval(Self.followUpGap))
        let readingSinceStart = lastReadingAt.map { $0 >= record.start } ?? false
        guard !record.repeated, now >= followUpAt, !readingSinceStart else { return nil }
        record.repeated = true
        sent[key] = record
        return HRReminderAlert(key: key, title: title, isRepeat: true)
    }
}
