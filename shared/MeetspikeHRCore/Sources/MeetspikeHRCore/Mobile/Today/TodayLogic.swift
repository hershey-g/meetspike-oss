import Foundation

// Pure logic for the Today tab. Each function names the web code it mirrors (public/app.js, public/live-hr.js).
// Nothing here touches the network, the clock (pass `now`) or SwiftUI.

/// Colour family for a score, pill or trend. Maps to Theme.good / warn / bad / secondary.
public enum TodayTone: Sendable, Equatable {
    case good, warn, bad, none
}

/// Recovery band for a score: tone plus the word shown beside it.
public struct TodayBand: Equatable, Sendable {
    public var tone: TodayTone
    /// "Good" or "Optimal" (top band), "Fair", "Low".
    public var word: String
    public init(tone: TodayTone, word: String) {
        self.tone = tone
        self.word = word
    }
}

/// Which direction of change is good for a metric.
public enum TodayHigherIs: Sendable, Equatable {
    case better, worse, neutral
}

/// The two words for "above usual" and "below usual".
public struct TodayTrendWords: Equatable, Sendable {
    public var up: String
    public var down: String
    public init(up: String, down: String) {
        self.up = up
        self.down = down
    }
    public static let higherLower = TodayTrendWords(up: "higher", down: "lower")
    public static let moreFewer = TodayTrendWords(up: "more", down: "fewer")
}

/// One metric row's comparison against "your usual".
public struct TodayTrend: Equatable, Sendable {
    public enum Direction: Sendable, Equatable { case up, down, usual, none }
    public enum Tone: Sendable, Equatable { case good, bad, flat }
    public var direction: Direction
    public var tone: Tone
    /// "higher", "lower", "more", "fewer", "usual", or "" when there is no usual to compare with.
    /// No arrow glyph: the view draws ▲ / ▼ from `direction`.
    public var text: String
    public init(direction: Direction, tone: Tone, text: String) {
        self.direction = direction
        self.tone = tone
        self.text = text
    }
}

/// A run of heart rate points from one provider with no long gap.
public struct TodayHRSegment: Equatable, Sendable {
    public var provider: String
    public var points: [HRPoint]
    public init(provider: String, points: [HRPoint]) {
        self.provider = provider
        self.points = points
    }
}

/// The heart rate pill on a meeting row.
public struct TodayZonePill: Equatable, Sendable {
    public var tone: TodayTone
    /// "No HR", or "<headline> · <provider>".
    public var text: String
    /// Partial coverage note ("HR from 9:45 AM"), shown as a hint, or nil.
    public var note: String?
    public init(tone: TodayTone, text: String, note: String?) {
        self.tone = tone
        self.text = text
        self.note = note
    }
}

public struct TodayLiveStats: Equatable, Sendable {
    public var min: Int
    public var avg: Int
    public var max: Int
    public init(min: Int, avg: Int, max: Int) {
        self.min = min
        self.avg = avg
        self.max = max
    }
}

/// What the live heart rate card draws.
public struct TodayLiveChart: Equatable, Sendable {
    /// The newest reading when it is under 45 s old, else nil ("Waiting for new readings").
    public var current: Int?
    /// The newest reading in the window, even when stale.
    public var last: LivePoint?
    /// min / avg / max of readings between the real meeting start and end (not the pads), nil when none.
    public var stats: TodayLiveStats?
    /// Lowest and highest bpm among plotted readings, nil when none.
    public var extent: ClosedRange<Double>?
    /// Readings inside the padded window and not after now, split wherever two are more than 15 s apart.
    public var segments: [[LivePoint]]
    public init(current: Int?, last: LivePoint?, stats: TodayLiveStats?, extent: ClosedRange<Double>?, segments: [[LivePoint]]) {
        self.current = current
        self.last = last
        self.stats = stats
        self.extent = extent
        self.segments = segments
    }
}

/// A meeting bar on the 7 am to 9 pm strip.
public struct TodayTimelineBar: Equatable, Sendable {
    /// 0...1 from the left edge of the strip.
    public var left: Double
    /// 0...1 of the strip width, at least 0.006 and never past the right edge.
    public var width: Double
    /// Starts at 18:00 or later.
    public var afterHours: Bool
    public init(left: Double, width: Double, afterHours: Bool) {
        self.left = left
        self.width = width
        self.afterHours = afterHours
    }
}

/// What the Today date bar says about the day on screen.
public struct TodayDateBar: Equatable, Sendable {
    /// The day on screen is today, so the label says "Today".
    public var isToday: Bool
    /// There is a later day to step to (never past today).
    public var canGoNext: Bool
}

public enum TodayLogic {
    /// The date bar for `day` against the app's `today` (`AppEnvironment.today`). Callers pass the app's today,
    /// never the `today` of a cached `ViewResponse`: an offline copy from yesterday says yesterday is today.
    public static func dateBar(day: String, today: String) -> TodayDateBar {
        TodayDateBar(isToday: day == today, canGoNext: day < today)
    }

    // MARK: Constants (from public/app.js and public/live-hr.js)

    /// Heavy day: 4 h or more of meetings...
    public static let heavyDurationS = 4 * 3600
    /// ...or 5 or more meetings.
    public static let heavyMeetingCount = 5
    /// Trend steps: a difference smaller than this reads as "usual".
    public static let recoveryStep = 3.0
    public static let hrvStep = 2.0
    public static let restingHrStep = 1.0
    public static let meetingHoursStep = 0.5
    /// A gap bigger than this (seconds) breaks a heart rate line.
    public static let whoopGapSeconds = 180.0
    public static let ouraGapSeconds = 600.0
    /// Live window: 10 minutes either side of the meeting, meetings over 8 h have none.
    public static let livePadMs = 600_000.0
    public static let liveMaxMeetingMs = 28_800_000.0
    /// A live reading older than this is stale.
    public static let liveStaleMs = 45_000.0
    /// Two live readings further apart than this start a new line segment.
    public static let liveGapMs = 15_000.0
    /// Skip an automatic refresh when the last sync was under this many seconds ago.
    public static let refreshThrottleSeconds = 120.0
    /// The timeline strip covers these local hours.
    public static let timelineFromHour = 7.0
    public static let timelineToHour = 21.0

    // MARK: Functions

    /// Recovery colour band (`band()` in app.js). WHOOP: 67+ good ("Good"), 34 to 66 warn ("Fair"), below bad ("Low").
    /// Oura: 85+ good ("Optimal"), 70 to 84 warn ("Fair"), below bad ("Low"). nil score gives nil. nil wearable reads as WHOOP.
    public static func recoveryBand(score: Double?, wearable: WearableKind?) -> TodayBand? {
        guard let score else { return nil }
        let oura = wearable == .oura
        let hi = oura ? 85.0 : 67.0
        let lo = oura ? 70.0 : 34.0
        if score >= hi { return TodayBand(tone: .good, word: oura ? "Optimal" : "Good") }
        if score >= lo { return TodayBand(tone: .warn, word: "Fair") }
        return TodayBand(tone: .bad, word: "Low")
    }

    /// Heavy day: `totalDurationS >= 4 h` or `eventCount >= 5` (nil counts as 0).
    public static func isHeavyDay(totalDurationS: Int?, eventCount: Int?) -> Bool {
        (totalDurationS ?? 0) >= heavyDurationS || (eventCount ?? 0) >= heavyMeetingCount
    }

    /// `metricRow` comparison. nil when the row should be hidden: no value, or value 0 with no usual (nil or 0).
    /// With a usual: |value - usual| >= step is `.up`/`.down` (tone from `higherIs`: better means up is good,
    /// worse means up is bad, neutral is always `.flat`); smaller is `.usual` with text "usual".
    /// Without a usual: direction `.none`, tone `.flat`, text "".
    public static func metricTrend(
        value: Double?, usual: Double?, step: Double, higherIs: TodayHigherIs,
        words: TodayTrendWords = .higherLower
    ) -> TodayTrend? {
        guard let value else { return nil }
        if value == 0 && (usual == nil || usual == 0) { return nil }
        guard let usual else { return TodayTrend(direction: .none, tone: .flat, text: "") }
        let diff = value - usual
        // A hair of slack so float noise cannot flip a row that sits exactly on the step.
        guard abs(diff) >= step - 1e-9 else { return TodayTrend(direction: .usual, tone: .flat, text: "usual") }
        let up = diff > 0
        let tone: TodayTrend.Tone
        switch higherIs {
        case .better: tone = up ? .good : .bad
        case .worse: tone = up ? .bad : .good
        case .neutral: tone = .flat
        }
        return TodayTrend(direction: up ? .up : .down, tone: tone, text: up ? words.up : words.down)
    }

    /// Splits an HR series into line segments. A point joins the previous segment when it has the same provider
    /// and is no more than 180 s (WHOOP) or 600 s (anything else) after the previous point. A point's provider is
    /// its own `source`, else `meetingSource` (the meeting's `hrStress.source`), else "".
    public static func hrSegments(_ series: [HRPoint], meetingSource: String?) -> [TodayHRSegment] {
        var segments: [TodayHRSegment] = []
        var lastTime = 0.0
        for point in series {
            let own = (point.source?.isEmpty == false) ? point.source : nil
            let provider = own ?? meetingSource ?? ""
            let time = point.time?.timeIntervalSince1970 ?? 0
            let gap = provider == "WHOOP" ? whoopGapSeconds : ouraGapSeconds
            if let last = segments.last, last.provider == provider, time - lastTime <= gap {
                segments[segments.count - 1].points.append(point)
            } else {
                segments.append(TodayHRSegment(provider: provider, points: [point]))
            }
            lastTime = time
        }
        return segments
    }

    /// "HR from 9:45 AM", "HR until 10:20 AM", "HR between 9:45 AM and 10:20 AM", "Gaps in heart rate", or ""
    /// (no partial info, or no coverage). Times use `timeZone`, format "h:mm a" in en_US.
    public static func partialNote(_ hr: MeetingHR?, timeZone: TimeZone) -> String {
        guard let hr, hr.hasCoverage, let partial = hr.partial else { return "" }
        func clock(_ iso: String?) -> String {
            guard let date = APITime.parse(iso ?? "") else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
        let late = partial.lateStart == true
        let early = partial.earlyEnd == true
        if late && early { return "HR between \(clock(partial.fromUtc)) and \(clock(partial.toUtc))" }
        if late { return "HR from \(clock(partial.fromUtc))" }
        if early { return "HR until \(clock(partial.toUtc))" }
        return "Gaps in heart rate"
    }

    /// Provider name for a heart rate summary: its `source`, else "WHOOP" when `methodNote` mentions WHOOP, else
    /// "Oura". Empty when there is no coverage.
    public static func hrProviderLabel(_ hr: MeetingHR?) -> String {
        guard let hr, hr.hasCoverage else { return "" }
        if let source = hr.source, !source.isEmpty { return source }
        if hr.methodNote?.range(of: "WHOOP", options: .caseInsensitive) != nil { return "WHOOP" }
        return "Oura"
    }

    /// The pill on a meeting row. No coverage: tone `.none`, text "No HR". Otherwise tone from zone (high bad,
    /// moderate warn, low good, else none) and text "<headline> · <provider>".
    public static func zonePill(_ hr: MeetingHR?, timeZone: TimeZone) -> TodayZonePill {
        guard let hr, hr.hasCoverage else { return TodayZonePill(tone: .none, text: "No HR", note: nil) }
        let tone: TodayTone
        switch hr.zone {
        case "high": tone = .bad
        case "moderate": tone = .warn
        case "low": tone = .good
        default: tone = .none
        }
        let note = partialNote(hr, timeZone: timeZone)
        return TodayZonePill(
            tone: tone,
            text: "\(hr.headline ?? "") \u{B7} \(hrProviderLabel(hr))",
            note: note.isEmpty ? nil : note)
    }

    /// Live window for a meeting, or nil when it is not a calendar event, has bad times, or lasts over 8 h.
    /// `startMs`/`endMs` are the meeting, `fromMs`/`toMs` add the 10 minute pads. `sourceType` nil counts as calendar.
    public static func liveWindow(startUtc: String?, endUtc: String?, sourceType: String?) -> LiveWindowMs? {
        if let sourceType, !sourceType.isEmpty, sourceType != "calendar" { return nil }
        guard let start = APITime.parse(startUtc ?? ""), let end = APITime.parse(endUtc ?? "") else { return nil }
        let startMs = start.timeIntervalSince1970 * 1000
        let endMs = end.timeIntervalSince1970 * 1000
        guard endMs > startMs, endMs - startMs <= liveMaxMeetingMs else { return nil }
        return LiveWindowMs(startMs: startMs, endMs: endMs, fromMs: startMs - livePadMs, toMs: endMs + livePadMs)
    }

    /// Adds a batch to what is already held. Same timestamp: the batch wins. Result sorted oldest first.
    public static func mergeLivePoints(_ previous: [LivePoint], _ batch: [LivePoint]) -> [LivePoint] {
        if batch.isEmpty { return previous }
        // The usual poll: a few newer readings in order. Append instead of rebuilding thousands of readings.
        if let newest = previous.last, let first = batch.first, first.ms > newest.ms,
           zip(batch, batch.dropFirst()).allSatisfy({ $0.ms < $1.ms }) {
            return previous + batch
        }
        var byTime: [Double: LivePoint] = [:]
        for point in previous { byTime[point.ms] = point }
        for point in batch { byTime[point.ms] = point }
        return byTime.values.sorted { $0.ms < $1.ms }
    }

    /// The live card's numbers (`liveChartData` in live-hr.js). Readings outside `window.fromMs...min(window.toMs, nowMs)`
    /// are ignored.
    public static func liveChart(
        points: [LivePoint], window: LiveWindowMs, nowMs: Double, maxPoints: Int = liveMaxPoints
    ) -> TodayLiveChart {
        liveChartWithHorizon(points: points, window: window, nowMs: nowMs, maxPoints: maxPoints).chart
    }

    /// Most readings the live plot draws, plus 2 per segment. The numbers still come from every reading.
    public static let liveMaxPoints = 400

    /// `liveChart` plus the clock time before which the same readings give the same chart: the next reading that is
    /// still in the future (it appears once due) or the moment the newest reading goes stale, whichever is first.
    static func liveChartWithHorizon(
        points: [LivePoint], window: LiveWindowMs, nowMs: Double, maxPoints: Int
    ) -> (chart: TodayLiveChart, validUntilMs: Double) {
        var nextFuture = Double.infinity
        var segments: [[LivePoint]] = []
        var last: LivePoint?
        var count = 0
        var sum = 0.0
        var minBpm = Double.infinity, maxBpm = -Double.infinity
        var low = Double.infinity, high = -Double.infinity
        let upper = Swift.min(window.toMs, nowMs)
        for point in points {
            if point.ms < window.fromMs { continue }
            if point.ms > upper {
                if point.ms <= window.toMs { nextFuture = Swift.min(nextFuture, point.ms) }
                continue
            }
            if let previous = last, point.ms - previous.ms <= liveGapMs {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
            last = point
            low = Swift.min(low, point.bpm)
            high = Swift.max(high, point.bpm)
            if point.ms >= window.startMs && point.ms <= window.endMs {
                count += 1
                sum += point.bpm
                minBpm = Swift.min(minBpm, point.bpm)
                maxBpm = Swift.max(maxBpm, point.bpm)
            }
        }
        var current: Int?
        if let last, nowMs - last.ms < liveStaleMs { current = Int(last.bpm.rounded()) }
        var stats: TodayLiveStats?
        if count > 0 {
            stats = TodayLiveStats(
                min: Int(minBpm.rounded()),
                avg: Int((sum / Double(count)).rounded(.toNearestOrAwayFromZero)),
                max: Int(maxBpm.rounded()))
        }
        var validUntil = nextFuture
        if current != nil, let last { validUntil = Swift.min(validUntil, last.ms + liveStaleMs) }
        let chart = TodayLiveChart(
            current: current, last: last, stats: stats,
            extent: last == nil ? nil : low...high,
            segments: thinLiveSegments(segments, window: window, maxPoints: maxPoints))
        return (chart, validUntil)
    }

    /// At most `maxPoints` readings in all, plus 2 per segment, once there are more than `maxPoints`. The window is cut
    /// into equal time buckets anchored to `window.fromMs`, so a bucket that is full never changes when later readings
    /// arrive. Each bucket of each segment keeps its first lowest and first highest reading, and each segment keeps its
    /// first and last reading, so the newest reading is always drawn. Many short segments can overflow that: the buckets
    /// are then made twice as wide until it fits, and as a last resort only the ends are kept.
    static func thinLiveSegments(_ segments: [[LivePoint]], window: LiveWindowMs, maxPoints: Int) -> [[LivePoint]] {
        let total = segments.reduce(0) { $0 + $1.count }
        if total <= maxPoints { return segments }
        let limit = maxPoints + 2 * segments.count
        let span = window.toMs - window.fromMs
        var buckets = Swift.max(1, maxPoints / 2 - 1)
        while span > 0 {
            let width = span / Double(buckets)
            let thinned = segments.map { thinLiveSegment($0, fromMs: window.fromMs, width: width) }
            if thinned.reduce(0, { $0 + $1.count }) <= limit { return thinned }
            if buckets == 1 { break }
            buckets = Swift.max(1, buckets / 2)
        }
        return segments.map { segment in
            segment.count > 1 ? [segment[0], segment[segment.count - 1]] : segment
        }
    }

    private static func thinLiveSegment(_ segment: [LivePoint], fromMs: Double, width: Double) -> [LivePoint] {
        if segment.count <= 2 { return segment }
        var kept: [Int] = [0, segment.count - 1]
        var bucket = -1
        var lowIndex = 0
        var highIndex = 0
        func flush() {
            if bucket >= 0 { kept.append(lowIndex); kept.append(highIndex) }
        }
        for (index, point) in segment.enumerated() {
            let id = Int(((point.ms - fromMs) / width).rounded(.down))
            if id != bucket {
                flush()
                bucket = id
                lowIndex = index
                highIndex = index
            } else {
                if point.bpm < segment[lowIndex].bpm { lowIndex = index }
                if point.bpm > segment[highIndex].bpm { highIndex = index }
            }
        }
        flush()
        return Array(Set(kept)).sorted().map { segment[$0] }
    }

    /// Where a meeting sits on the 7 am to 9 pm strip. nil without a parsable local start ("...T09:30:00...").
    /// `left = clamp((hour - 7) / 14)`, `width = max(0.006, min(1 - left, hours / 14))`, after hours when start >= 18.
    public static func timelineBar(startLocal: String?, durationS: Int?) -> TodayTimelineBar? {
        guard let startLocal,
              let match = startLocal.range(of: #"T(\d{2}):(\d{2})"#, options: .regularExpression)
        else { return nil }
        let parts = startLocal[match].dropFirst().split(separator: ":")
        guard parts.count == 2, let hour = Double(parts[0]), let minute = Double(parts[1]) else { return nil }
        let start = hour + minute / 60
        let span = timelineToHour - timelineFromHour
        let left = Swift.min(1, Swift.max(0, (start - timelineFromHour) / span))
        let hours = Double(durationS ?? 0) / 3600
        let width = Swift.max(0.006, Swift.min(1 - left, hours / span))
        return TodayTimelineBar(left: left, width: width, afterHours: start >= 18)
    }

    /// True when an automatic refresh should run: never synced, or the last sync was 120 s ago or more.
    public static func shouldAutoRefresh(lastSync: Date?, now: Date) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= refreshThrottleSeconds
    }

    /// True when a meeting's live window (meeting plus 10 minute pads) ended after `previous` and by `now`, so the row
    /// pill needs a fresh load (web app.js 425-429 re-renders when the window passes). Only calendar meetings have one.
    public static func liveWindowEnded(events: [Meeting], previous: Date, now: Date) -> Bool {
        let previousMs = previous.timeIntervalSince1970 * 1000
        let nowMs = now.timeIntervalSince1970 * 1000
        return events.contains { event in
            guard let window = liveWindow(startUtc: event.startUtc, endUtc: event.endUtc, sourceType: event.sourceType)
            else { return false }
            return window.toMs > previousMs && window.toMs <= nowMs
        }
    }

    /// A load for `requested` should be dropped when the person has since moved to another day.
    public static func isStaleLoad(requested: String, selected: String) -> Bool {
        requested != selected
    }
}
