import Foundation

// Response models for the Meetspike Worker API (src/routes/api.ts and friends).
//
// Lenient on purpose: anything the web code treats as optional is optional here, lists
// default to empty, unknown keys are ignored. Names and nesting follow the JSON exactly so
// the web code (public/app.js) and this file can be read side by side. Every model is
// `Decodable, Equatable, Sendable`. They are built by decoding, not by hand.

public typealias APIModel = Decodable & Equatable & Sendable

/// A JSON array that decodes to `[]` when the key is missing, null, or not an array. An array whose
/// elements do not decode still fails loudly: a half-empty list would hide a Worker change.
@propertyWrapper
public struct Items<Element: APIModel>: APIModel {
    public var wrappedValue: [Element]
    public init(wrappedValue: [Element] = []) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            wrappedValue = []
            return
        }
        var items: [Element] = []
        while !container.isAtEnd { items.append(try container.decode(Element.self)) }
        wrappedValue = items
    }
}

extension KeyedDecodingContainer {
    public func decode<E>(_ type: Items<E>.Type, forKey key: Key) throws -> Items<E> {
        try decodeIfPresent(type, forKey: key) ?? Items(wrappedValue: [])
    }
}

/// Parses the ISO-8601 timestamps the Worker sends, with or without fractional seconds.
public enum APITime {
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let fast = fastParse(value) { return fast }
        return slowParse(value)
    }

    // MARK: Fallback

    /// One shared formatter pair, used only for strings the fast path does not take. `ISO8601DateFormatter` is not
    /// documented as thread safe, and chart models are built off the main actor, so every call holds the lock.
    private final class Formatters: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
        }

        func date(from value: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: value) ?? plain.date(from: value)
        }
    }

    private static let formatters = Formatters()

    private static func slowParse(_ value: String) -> Date? { formatters.date(from: value) }

    // MARK: Fast path

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|+HH:MM|-HH:MM)`, the forms the Worker sends. Only values that are plainly
    /// valid are taken here (year 1600 to 9999, a real calendar day, hour under 24, minute and second under 60,
    /// a fraction of 1 to 9 digits, an offset of under 24 hours and under 60 minutes). Everything else, valid or not,
    /// goes to the formatter so the accept and reject answers stay what they were: a nonsense date is never
    /// "fixed" here, and years before the Gregorian switch (where the formatter's calendar differs) are left to it.
    private static func fastParse(_ value: String) -> Date? {
        var text = value
        return text.withUTF8 { bytes -> Date? in
            let count = bytes.count
            // "YYYY-MM-DDTHH:MM:SSZ" is 20 bytes; a fraction and a numeric offset make it longer.
            guard count >= 20, count <= 40 else { return nil }
            @inline(__always) func digit(_ index: Int) -> Int? {
                let byte = bytes[index]
                return byte >= 48 && byte <= 57 ? Int(byte) - 48 : nil
            }
            @inline(__always) func number(_ start: Int, _ length: Int) -> Int? {
                var total = 0
                for index in start..<(start + length) {
                    guard let d = digit(index) else { return nil }
                    total = total * 10 + d
                }
                return total
            }
            guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
                  let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
            else { return nil }
            guard year >= 1600, (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard day >= 1, day <= monthDays[month - 1] else { return nil }

            var index = 19
            var fraction = 0.0
            if bytes[index] == 46 {
                index += 1
                var scale = 0.1
                var digits = 0
                while index < count, let d = digit(index) {
                    fraction += Double(d) * scale
                    scale /= 10
                    digits += 1
                    index += 1
                }
                guard digits >= 1, digits <= 9 else { return nil }
            }
            guard index < count else { return nil }
            var offsetSeconds = 0
            switch bytes[index] {
            case 90:                                        // Z
                guard index + 1 == count else { return nil }
            case 43, 45:                                    // + or -
                guard index + 6 == count, bytes[index + 3] == 58,
                      let offsetHour = number(index + 1, 2), let offsetMinute = number(index + 4, 2),
                      offsetHour < 24, offsetMinute < 60
                else { return nil }
                offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == 45 ? -1 : 1)
            default:
                return nil
            }

            // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's civil algorithm).
            let shifted = month <= 2 ? year - 1 : year
            let era = shifted / 400
            let yearOfEra = shifted - era * 400
            let monthIndex = month > 2 ? month - 3 : month + 9
            let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        }
    }
}

enum APIModelLabels {
    /// "Recovery (WHOOP)"; just "Morning score" when the wearable label is empty.
    static func score(_ readiness: String?, _ label: String?) -> String {
        [readiness, label.flatMap { $0.isEmpty ? nil : "(\($0))" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum WearableKind: String, Sendable, Equatable {
    case whoop, oura
}

// MARK: Wearable and status

/// `wearable` on every view response. `source` is nil when wearable display is off.
public struct WearableInfo: APIModel {
    public var source: String?
    public var label: String?
    public var readinessLabel: String?
    public var strainLabel: String?
    public var strainMax: Double?
    public var hasIntradayHr: Bool?
    public var hrSource: String?
    public var ouraHr: Bool?
    public var whoopWebHr: Bool?
    public var tagline: String?
    public var note: String?
    public var chosenBy: String?

    public var kind: WearableKind? { source.flatMap(WearableKind.init(rawValue:)) }
    /// "Recovery (WHOOP)" style label, like `scoreLabel` in public/wearable-labels.js.
    public var scoreLabel: String { APIModelLabels.score(readinessLabel, label) }
}

public struct SyncStamp: APIModel {
    public var createdAt: String?
    public var status: String?
    private enum CodingKeys: String, CodingKey { case createdAt = "created_at", status }
}

public struct WearableRange: APIModel {
    public var min: String?
    public var max: String?
}

/// One entry of `status.wearables`.
public struct WearableStatus: APIModel, Identifiable {
    public var source: String?
    public var label: String?
    public var displayEnabled: Bool?
    public var connected: Bool?
    public var expiresAt: String?
    public var lastDataDay: String?
    public var lastReceivedAt: String?
    public var history: WearableRange?
    public var id: String { source ?? label ?? "" }
}

/// `status` on /api/view: what the menu and banners need.
public struct ViewStatus: APIModel {
    public var displayTitle: String?
    public var sandbox: Bool?
    @Items public var wearables: [WearableStatus]
    public var sourceDisplay: SourceDisplay?
    public var wearableConnected: Bool?
    public var googleConnected: Bool?
    public var lastSync: SyncStamp?
}

// MARK: Scores

/// Median of the last 28 days ("your usual"). Every field can be nil.
public struct Usual: APIModel {
    public var from: String?
    public var to: String?
    public var days: Int?
    public var recovery: Double?
    public var sleep: Double?
    public var hrv: Double?
    public var restingHr: Double?
    public var strain: Double?
    public var meetingHours: Double?
    public var afterHours: Double?
}

/// One wearable's morning score block on /api/view (`morningScores`).
public struct MorningScore: APIModel, Identifiable {
    public var source: String?
    public var label: String?
    public var readinessLabel: String?
    public var morning: Double?
    public var nextMorning: Double?
    public var average: Double?
    public var usual: Usual?
    public var id: String { source ?? label ?? "" }
    public var scoreLabel: String { APIModelLabels.score(readinessLabel, label) }
}

/// A wearable's numbers for one morning (`priorNight`, `nextMorning`).
public struct DaySlice: APIModel {
    public var day: String?
    public var sleepScore: Double?
    public var readinessScore: Double?
    public var avgHrv: Double?
    public var lowestHr: Double?
    public var totalSleepS: Double?
    public var stressHighS: Double?
    public var recoveryHighS: Double?
    public var stressSummary: String?
    public var strain: Double?
    public var dayAvgHr: Double?
    public var dayMaxHr: Double?
}

public struct HeavySide: APIModel {
    public var days: Int?
    public var nextRecovery: Double?
}

public struct HeavyEffect: APIModel {
    public var heavyHours: Double?
    public var heavyMeetings: Double?
    public var heavy: HeavySide?
    public var lighter: HeavySide?
    public var cost: Double?
    public var from: String?
    public var to: String?
}

public struct CostlyDay: APIModel, Identifiable {
    public var day: String
    public var meetingCount: Int?
    public var meetingHours: Double?
    public var afterHours: Int?
    public var nextRecovery: Double?
    public var nextSleep: Double?
    public var id: String { day }
}

public struct HeavyDayPerson: APIModel, Identifiable {
    public var email: String
    public var name: String?
    public var heavyDays: Int?
    public var meetings: Int?
    public var id: String { email }
}

/// One day of the chart series on /api/view.
public struct SeriesDay: APIModel, Identifiable {
    public var day: String
    public var meetingCount: Int?
    public var meetingHours: Double?
    public var afterHours: Int?
    public var recovery: Double?
    public var sleep: Double?
    public var strain: Double?
    public var nextRecovery: Double?
    public var id: String { day }
}

// MARK: Heart rate

public struct HRPoint: APIModel {
    /// ISO-8601 timestamp.
    public var t: String
    public var bpm: Double
    public var minutes: Double?
    /// "WHOOP" or "Oura" when the series mixes providers.
    public var source: String?

    public init(t: String, bpm: Double, minutes: Double? = nil, source: String? = nil) {
        self.t = t
        self.bpm = bpm
        self.minutes = minutes
        self.source = source
    }
    public var time: Date? { APITime.parse(t) }
}

public struct HRPartial: APIModel {
    public var fromUtc: String?
    public var toUtc: String?
    public var lateStart: Bool?
    public var earlyEnd: Bool?

    public init(fromUtc: String?, toUtc: String?, lateStart: Bool?, earlyEnd: Bool?) {
        self.fromUtc = fromUtc
        self.toUtc = toUtc
        self.lateStart = lateStart
        self.earlyEnd = earlyEnd
    }
}

/// `hrStress` on a meeting: heart rate inside that meeting. `coverage == "none"` means no HR.
public struct MeetingHR: APIModel {
    public var coverage: String?
    public var source: String?
    /// Gaps as [startMs, endMs] pairs.
    @Items public var gaps: [[Double]]
    public var method: String?
    public var methodNote: String?
    public var sampleCount: Int?
    public var meanBpm: Double?
    public var maxBpm: Double?
    public var dayAwakeMeanBpm: Double?
    public var restingBpm: Double?
    public var elevatedThresholdBpm: Double?
    public var elevatedPct: Double?
    public var elevatedMinutes: Double?
    public var meanVsAwake: Double?
    /// "low", "moderate", "high" or nil.
    public var zone: String?
    public var headline: String?
    public var story: String?
    public var impact: Double?
    @Items public var series: [HRPoint]
    public var partial: HRPartial?

    public var hasCoverage: Bool { coverage == "ok" }
}

// MARK: Meetings

public struct Attendee: APIModel, Identifiable {
    public var email: String
    public var isSelf: Bool?
    public var name: String?
    public var id: String { email }
    private enum CodingKeys: String, CodingKey { case email, isSelf = "self", name }
}

/// A company on a meeting, tagged from an attendee's email domain ("acme.com", "Acme"). Never the owner's own
/// domain, free mail or a calendar room. `name` is the saved name, else one built from the domain.
public struct CompanyTag: APIModel, Identifiable, Hashable {
    public var domain: String
    public var name: String?
    public var id: String { domain }
    public init(domain: String, name: String?) {
        self.domain = domain
        self.name = name
    }
    /// The name, or the domain when there is none.
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? domain }
}

public struct MeetingSignals: APIModel {
    public var stressHighS: Double?
    public var recoveryHighS: Double?
    public var stressSummary: String?
    public var stressSource: String?
    public var readinessProxy: Double?
    public var nextSleepScore: Double?
    public var nextReadinessScore: Double?
    public var nextHrv: Double?
    public var nextLowestHr: Double?
    public var nextTotalSleepS: Double?
}

public struct Meeting: APIModel, Identifiable {
    public var id: String
    public var title: String?
    public var kind: String?
    public var day: String?
    public var startUtc: String?
    public var endUtc: String?
    public var startLocal: String?
    public var endLocal: String?
    public var afterHours: Bool?
    public var earlyStart: Bool?
    public var attendeeCount: Int?
    public var durationS: Int?
    public var ouraMorningDay: String?
    public var signals: MeetingSignals?
    public var score: Double?
    @Items public var flags: [String]
    public var hrStress: MeetingHR?
    @Items public var attendees: [Attendee]
    /// Companies of the attendees, each once. Empty from an older Worker.
    @Items public var companies: [CompanyTag]
    public var attendeeNote: String?
    /// "calendar" for Google events. Anything else (Plaud recordings) has no live window.
    public var sourceType: String?
    public var syncReason: String?
    public var hasTranscript: Bool?
    /// What the owner said about this meeting and what the Mac saw. Present when there is a choice or a sighting, or
    /// when the meeting is in a series (so "All of them" can be offered). Absent otherwise, and from a Worker without
    /// the table. `startUtc` and `endUtc` above are the effective times; the override has the calendar's.
    public var override: MeetingOverride?
    /// True for a meeting left out (not joined, not linked). Only in a day's list so it can be undone: no heart rate,
    /// no score, and never in an average.
    public var excluded: Bool?
}

public struct DayCalendar: APIModel {
    public var day: String?
    public var eventCount: Int?
    public var totalDurationS: Int?
    public var afterHoursCount: Int?
    public var earlyStartCount: Int?
    public var clientCount: Int?
    public var byKind: [String: Int]?
    @Items public var events: [Meeting]
}

public struct DayHR: APIModel {
    public var source: String?
    public var method: String?
    public var methodNote: String?
    @Items public var series: [HRPoint]
}

/// `day` on /api/view when one day is selected.
public struct DayBriefing: APIModel {
    public var date: String?
    public var timeZone: String?
    public var calendar: DayCalendar?
    public var priorNight: DaySlice?
    public var nextMorning: DaySlice?
    @Items public var flags: [String]
    public var summary: String?
    public var hr: DayHR?
    public var wearable: WearableInfo?
    public var methodNote: String?
}

public struct RangeHardest: APIModel {
    public var id: String?
    public var title: String?
    public var day: String?
    public var startLocal: String?
    public var headline: String?
    public var impact: Double?
}

public struct RangeSummary: APIModel {
    public var elevated: Int?
    public var watching: Int?
    public var restored: Int?
    public var noHr: Int?
    public var combinedHr: Int?
    public var meetingCount: Int?
    public var daysWithMeetings: Int?
    public var totalDurationS: Int?
    public var afterHoursCount: Int?
    public var earlyStartCount: Int?
    public var byKind: [String: Int]?
    public var meanBpm: Double?
    public var hardest: RangeHardest?
    public var line: String?
}

public struct RangeRecovery: APIModel {
    public var nSleep: Int?
    public var nReadiness: Int?
    public var avgSleepScore: Double?
    public var avgReadinessScore: Double?
    public var lowSleepDays: Int?
    public var lowReadinessDays: Int?
    public var nStrain: Int?
    public var avgStrain: Double?
}

public struct RangeScores: APIModel {
    public var sleepScore: Double?
    public var readinessScore: Double?
    public var strain: Double?
}

public struct RangeDay: APIModel, Identifiable {
    public var day: String
    public var meetingCount: Int?
    public var totalDurationS: Int?
    public var afterHoursCount: Int?
    public var earlyStartCount: Int?
    public var elevated: Int?
    public var watching: Int?
    public var restored: Int?
    public var noHr: Int?
    public var combinedHr: Int?
    public var meanBpm: Double?
    public var morning: RangeScores?
    public var nextMorning: RangeScores?
    @Items public var meetings: [Meeting]
    public var id: String { day }
}

/// `range` on /api/view when more than one day is selected.
public struct RangeBriefing: APIModel {
    public var start: String?
    public var end: String?
    public var spanDays: Int?
    public var singleDay: Bool?
    public var timeZone: String?
    public var summary: RangeSummary?
    public var recovery: RangeRecovery?
    @Items public var days: [RangeDay]
    public var wearable: WearableInfo?
    public var grain: [String: String]?
    public var methodNote: String?
}

// MARK: Insight hits

public struct InsightCompare: APIModel {
    public var key: String?
    public var label: String?
    public var value: Double?
    public var median: Double?
    public var delta: Double?
    public var worse: Bool?
}

public struct InsightHit: APIModel, Identifiable {
    public var kind: String?
    public var id: String
    public var day: String?
    public var title: String?
    public var startLocal: String?
    public var afterHours: Bool?
    public var earlyStart: Bool?
    public var meetingKind: String?
    public var sentence: String?
    public var badge: String?
    public var impact: Double?
    @Items public var compare: [InsightCompare]
    public var hrStress: MeetingHR?
    @Items public var attendees: [Attendee]
    @Items public var companies: [CompanyTag]
    public var attendeeNote: String?
    public var sourceType: String?
}

// MARK: GET /api/view

/// Everything one screen needs. `day` is set for a single day, `range` for a span.
public struct ViewResponse: APIModel {
    public var ok: Bool?
    /// Today's local day on the server. Never clamp dates to the phone's own clock.
    public var today: String?
    public var start: String?
    public var end: String?
    public var spanDays: Int?
    public var timeZone: String?
    public var wearable: WearableInfo?
    public var status: ViewStatus?
    @Items public var morningScores: [MorningScore]
    public var day: DayBriefing?
    public var range: RangeBriefing?
    public var usual: Usual?
    public var effect: HeavyEffect?
    @Items public var costly: [CostlyDay]
    @Items public var people: [HeavyDayPerson]
    @Items public var series: [SeriesDay]
    /// nil when the wearable has no heart rate inside meetings.
    public var hits: [InsightHit]?
    public var baselineNote: String?

    public var isSingleDay: Bool { day != nil }
}

// MARK: GET /api/meetings/:id/hr

public struct MeetingHRWindow: APIModel {
    public var startUtc: String?
    public var endUtc: String?
    public var fetchStartUtc: String?
    public var fetchEndUtc: String?
}

public struct HRBaseline: APIModel {
    public var meanBpm: Double?
    public var lowBpm: Double?
    public var highBpm: Double?
    public var meetings: Int?
    public var sampleCount: Int?
    /// "meetings", "padding" or "none".
    public var basis: String?
}

public struct StressPoint: APIModel {
    public var t: String
    public var level: Double
}

public struct StressSlice: APIModel {
    @Items public var points: [StressPoint]
    public var meanLevel: Double?
    public var peakLevel: Double?
    public var minLevel: Double?
    public var dayCurrentLevel: Double?
}

public struct FillOutcome: APIModel {
    public var hr: String?
    public var stress: String?
}

/// Per-meeting heart rate detail. A 404 ("per-meeting detail is unavailable") arrives as `APIError.http(404, ...)`.
public struct MeetingHRDetail: APIModel {
    public var ok: Bool?
    public var enabled: Bool?
    public var meetingId: String?
    public var title: String?
    public var timeZone: String?
    public var window: MeetingHRWindow?
    public var hrStress: MeetingHR?
    @Items public var series: [HRPoint]
    public var baseline: HRBaseline?
    public var stress: StressSlice?
    public var fill: FillOutcome?
    public var message: String?
}

// MARK: GET /api/meetings/:id/live-hr

/// One live reading: `[timestampMs, bpm]` on the wire.
public struct LivePoint: APIModel {
    public var ms: Double
    public var bpm: Double

    public init(ms: Double, bpm: Double) {
        self.ms = ms
        self.bpm = bpm
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        ms = try container.decode(Double.self)
        bpm = try container.decode(Double.self)
    }
}

public struct LiveWindowMs: APIModel {
    public var startMs: Double
    public var endMs: Double
    public var fromMs: Double
    public var toMs: Double

    public init(startMs: Double, endMs: Double, fromMs: Double, toMs: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.fromMs = fromMs
        self.toMs = toMs
    }
}

/// Live heart rate poll. Inactive means outside the padded meeting window: `points` is empty.
/// 404 means live heart rate is off (arrives as `APIError.http(404, ...)`).
public struct LiveHRReply: APIModel {
    public var window: LiveWindowMs?
    public var active: Bool?
    @Items public var points: [LivePoint]
    /// Send back as `since` on the next poll.
    public var cursor: Int?
}

// MARK: People

/// One row of GET /api/people.
public struct PersonSummary: APIModel, Identifiable {
    public var email: String
    public var name: String?
    public var meetings: Int?
    public var days: Int?
    /// Average next-morning score across that person's days, nil without scores.
    public var avg: Double?
    public var id: String { email }
}

public struct PeopleResponse: APIModel {
    public var ok: Bool?
    public var start: String?
    public var end: String?
    public var spanDays: Int?
    public var wearable: WearableInfo?
    public var sourceDisplay: SourceDisplay?
    @Items public var people: [PersonSummary]
    public var usualRecovery: Double?
}

/// One row of GET /api/people/search.
public struct PersonMatch: APIModel, Identifiable {
    public var email: String
    public var name: String?
    public var id: String { email }
    public init(email: String, name: String?) {
        self.email = email
        self.name = name
    }
}

struct PeopleSearchReply: APIModel {
    @Items var people: [PersonMatch]
}

public struct PersonTrend: APIModel {
    public var meetingCount: Int?
    public var withCoverage: Int?
    public var elevated: Int?
    public var watching: Int?
    public var restored: Int?
    public var missingHr: Int?
    public var medianAvgBpm: Double?
    /// Newest meeting first.
    @Items public var spark: [Double]
    public var badge: String?
    public var badgeNote: String?
}

/// `trendsByHrSource` entry: a trend for one heart rate provider ("WHOOP", "Oura", "WHOOP + Oura").
public struct PersonSourceTrend: APIModel, Identifiable {
    public var source: String?
    public var meetingCount: Int?
    public var withCoverage: Int?
    public var elevated: Int?
    public var watching: Int?
    public var restored: Int?
    public var missingHr: Int?
    public var medianAvgBpm: Double?
    @Items public var spark: [Double]
    public var badge: String?
    public var badgeNote: String?
    public var id: String { source ?? "" }
}

public struct PersonMeeting: APIModel, Identifiable {
    public var id: String
    public var title: String?
    public var kind: String?
    public var day: String?
    public var startUtc: String?
    public var startLocal: String?
    public var afterHours: Bool?
    public var earlyStart: Bool?
    public var hrStress: MeetingHR?
    public var nextSleepScore: Double?
    public var nextReadinessScore: Double?
    /// Companies on the meeting. Empty from an older Worker.
    @Items public var companies: [CompanyTag]
    /// Company page only: the attendees from that company.
    @Items public var companyAttendees: [Attendee]

    public init(
        id: String, title: String? = nil, kind: String? = nil, day: String? = nil, startUtc: String? = nil,
        startLocal: String? = nil, afterHours: Bool? = nil, earlyStart: Bool? = nil, hrStress: MeetingHR? = nil,
        nextSleepScore: Double? = nil, nextReadinessScore: Double? = nil, companies: [CompanyTag] = []
    ) {
        self.companies = companies
        self.companyAttendees = []
        self.id = id
        self.title = title
        self.kind = kind
        self.day = day
        self.startUtc = startUtc
        self.startLocal = startLocal
        self.afterHours = afterHours
        self.earlyStart = earlyStart
        self.hrStress = hrStress
        self.nextSleepScore = nextSleepScore
        self.nextReadinessScore = nextReadinessScore
    }
}

/// GET /api/people/:email/meetings. Meetings are newest first.
public struct PersonMeetingsResponse: APIModel {
    public var ok: Bool?
    public var email: String?
    public var name: String?
    public var from: String?
    public var to: String?
    public var timeZone: String?
    public var wearable: WearableInfo?
    public var sourceDisplay: SourceDisplay?
    public var grain: [String: String]?
    public var methodNote: String?
    public var trend: PersonTrend?
    @Items public var trendsByHrSource: [PersonSourceTrend]
    @Items public var meetings: [PersonMeeting]
}

// MARK: Companies

/// One row of GET /api/companies: meetings, people and days with that company, the average next-morning score,
/// and the heart rate summary across its meetings (nil without heart rate inside meetings).
public struct CompanySummary: APIModel, Identifiable {
    public var domain: String
    public var name: String?
    public var meetings: Int?
    public var people: Int?
    public var days: Int?
    public var avg: Double?
    public var trend: PersonTrend?
    public var id: String { domain }
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? domain }
}

public struct CompaniesResponse: APIModel {
    public var ok: Bool?
    public var start: String?
    public var end: String?
    public var spanDays: Int?
    public var wearable: WearableInfo?
    public var sourceDisplay: SourceDisplay?
    @Items public var companies: [CompanySummary]
    public var usualRecovery: Double?
}

/// One row of GET /api/companies/search.
public typealias CompanyMatch = CompanyTag

struct CompanySearchReply: APIModel {
    @Items var companies: [CompanyTag]
}

/// Someone at a company, with how many of its meetings they were in.
public struct CompanyPerson: APIModel, Identifiable {
    public var email: String
    public var name: String?
    public var meetings: Int?
    public var id: String { email }
}

/// GET /api/companies/:domain/meetings. The person page's shape, plus the company's people.
public struct CompanyMeetingsResponse: APIModel {
    public var ok: Bool?
    public var domain: String?
    public var name: String?
    public var from: String?
    public var to: String?
    public var timeZone: String?
    public var wearable: WearableInfo?
    public var sourceDisplay: SourceDisplay?
    public var grain: [String: String]?
    public var methodNote: String?
    public var trend: PersonTrend?
    @Items public var trendsByHrSource: [PersonSourceTrend]
    @Items public var people: [CompanyPerson]
    @Items public var meetings: [PersonMeeting]
}

/// PUT /api/companies/:domain/name.
public struct CompanyNameResult: APIModel {
    public var ok: Bool?
    public var domain: String?
    public var name: String?
}

// MARK: Refresh

/// One part of a refresh (calendar, whoop or oura).
public struct RefreshPart: APIModel {
    public var ok: Bool?
    public var error: String?
    public var needsGoogle: Bool?
    /// The work is still running on the Worker after the 15 s wait. Not a failure.
    public var pending: Bool?
    /// Meetings written by the sync. The web shows written + removed as "N meetings updated".
    public var written: Int?
    /// Meetings removed by the sync.
    public var removed: Int?
}

/// What POST /api/refresh (or the older POST /api/calendar/sync) means for the app.
/// It never throws for a part that failed: read the fields.
public struct RefreshResult: Equatable, Sendable {
    public var calendar: RefreshPart?
    public var whoop: RefreshPart?
    public var oura: RefreshPart?
    public var syncedAt: String?
    /// True when the older Worker (no /api/refresh) answered through POST /api/calendar/sync.
    public var usedCalendarFallback: Bool
    /// Google is not connected or its sign-in expired. Treated as "nothing to sync", not an error.
    public var needsGoogle: Bool

    public init(
        calendar: RefreshPart? = nil, whoop: RefreshPart? = nil, oura: RefreshPart? = nil, syncedAt: String? = nil,
        usedCalendarFallback: Bool = false, needsGoogle: Bool = false
    ) {
        self.calendar = calendar
        self.whoop = whoop
        self.oura = oura
        self.syncedAt = syncedAt
        self.usedCalendarFallback = usedCalendarFallback
        self.needsGoogle = needsGoogle
    }

    /// The calendar part failed for a reason other than Google not being connected.
    public var calendarError: String? {
        guard calendar?.ok == false, calendar?.needsGoogle != true else { return nil }
        return calendar?.error ?? "Calendar sync failed"
    }
    public var whoopFailed: Bool { whoop?.ok == false }
    public var ouraFailed: Bool { oura?.ok == false }
    /// A wearable refreshed fine, so scores may have changed even if the calendar failed.
    public var wearableRefreshed: Bool { whoop?.ok == true || oura?.ok == true }
}

struct RefreshReply: APIModel {
    var calendar: RefreshPart?
    var whoop: RefreshPart?
    var oura: RefreshPart?
    var syncedAt: String?
}

/// Just enough of the error body the Worker sends with a 4xx/5xx.
struct ErrorBody: APIModel {
    var error: String?
    var needsKey: Bool?
    var needsGoogle: Bool?
}

// MARK: Ask

/// GET /api/ask/status.
public struct AskStatus: APIModel {
    public var ok: Bool?
    /// false: the Worker has no AI_KEY_SECRET, so a key cannot be saved yet.
    public var available: Bool?
    public var connected: Bool?
    /// Last four characters of the saved key.
    public var tail: String?
    public var savedAt: String?
    public var model: String?
    public var sourceDisplay: SourceDisplay?
}

/// PUT / DELETE /api/ask/key.
public struct AskKeyResult: APIModel {
    public var ok: Bool?
    public var connected: Bool?
    public var tail: String?
    public var savedAt: String?
}

/// The answer to PUT /api/meetings/:id/override: the meeting as it is now.
public struct OverrideSaveResult: APIModel {
    public var ok: Bool?
    public var id: String?
    public var scope: String?
    public var override: MeetingOverride?
    /// The effective times after the change.
    public var startUtc: String?
    public var endUtc: String?
    public var excluded: Bool?

    public init(
        ok: Bool? = true, id: String? = nil, scope: String? = nil, override: MeetingOverride? = nil,
        startUtc: String? = nil, endUtc: String? = nil, excluded: Bool? = nil
    ) {
        self.ok = ok
        self.id = id
        self.scope = scope
        self.override = override
        self.startUtc = startUtc
        self.endUtc = endUtc
        self.excluded = excluded
    }
}
