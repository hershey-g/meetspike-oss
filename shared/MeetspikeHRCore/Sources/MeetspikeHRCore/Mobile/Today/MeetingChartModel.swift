import Foundation

// The meeting heart rate chart as plain values. Built once per loaded detail, off the main actor, so a view only
// renders it: nothing in a view body or init is proportional to the raw series (a long meeting is 33,000 points).

/// One drawn heart rate point.
public struct MeetingChartPoint: Equatable, Sendable {
    public var date: Date
    public var bpm: Double
    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

/// A run of drawn points from one provider with no long gap.
public struct MeetingChartSegment: Equatable, Sendable, Identifiable {
    public var id: Int
    public var provider: String
    public var points: [MeetingChartPoint]
    public init(id: Int, provider: String, points: [MeetingChartPoint]) {
        self.id = id
        self.provider = provider
        self.points = points
    }
}

/// One WHOOP stress reading, 0 to 3.
public struct MeetingChartStressPoint: Equatable, Sendable {
    public var date: Date
    public var level: Double
    public init(date: Date, level: Double) {
        self.date = date
        self.level = level
    }
}

/// Everything `MeetingHRChart` draws and says. The drawn points are thinned to about `maxPoints`; the domain
/// (`low`, `high`, `from`, `to`) and the spoken min and max come from every point.
public struct MeetingChartModel: Equatable, Sendable {
    public var sourceLabel: String
    public var segments: [MeetingChartSegment]
    public var from: Date
    public var to: Date
    public var meetingStart: Date?
    public var meetingEnd: Date?
    public var low: Double
    public var high: Double
    public var band: ClosedRange<Double>?
    public var stress: [MeetingChartStressPoint]
    /// Lowest and highest bpm of the whole series, nil when it is empty.
    public var minBpm: Double?
    public var maxBpm: Double?
    /// "WHOOP usual about N" in the spoken text, when the answer had a baseline.
    public var usualMeanBpm: Double?
    /// The highest stress level, for the spoken text.
    public var peakStress: Double?

    public static let defaultMaxPoints = 400

    /// One pass over the series: each timestamp is parsed once. Segments follow `TodayLogic.hrSegments` (same provider,
    /// no gap over 180 s for WHOOP or 600 s otherwise, a point without a readable time still counts for the gap). Then
    /// each segment is thinned by `HRDownsampling` when the whole series is over `maxPoints`.
    public init(detail: MeetingHRDetail, maxPoints: Int = MeetingChartModel.defaultMaxPoints) {
        let label = TodayLogic.hrProviderLabel(detail.hrStress)
        sourceLabel = label

        var full: [(provider: String, points: [MeetingChartPoint])] = []
        var lastTime = 0.0
        var earliest: Date?
        var latest: Date?
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for point in detail.series {
            let parsed = APITime.parse(point.t)
            let own = (point.source?.isEmpty == false) ? point.source : nil
            let provider = own ?? label
            let time = parsed?.timeIntervalSince1970 ?? 0
            let gap = provider == "WHOOP" ? TodayLogic.whoopGapSeconds : TodayLogic.ouraGapSeconds
            let joins: Bool
            if let last = full.last, last.provider == provider, time - lastTime <= gap { joins = true } else { joins = false }
            if !joins { full.append((provider, [])) }
            lastTime = time
            minimum = Swift.min(minimum, point.bpm)
            maximum = Swift.max(maximum, point.bpm)
            guard let parsed else { continue }
            full[full.count - 1].points.append(MeetingChartPoint(date: parsed, bpm: point.bpm))
            if earliest == nil || parsed < earliest! { earliest = parsed }
            if latest == nil || parsed > latest! { latest = parsed }
        }
        let drawable = full.filter { !$0.points.isEmpty }
        let kept = HRDownsampling.thin(drawable.map { $0.points.map(\.bpm) }, maxPoints: maxPoints)
        segments = drawable.enumerated().map { index, segment in
            MeetingChartSegment(
                id: index, provider: segment.provider,
                points: kept[index].map { segment.points[$0] })
        }

        let start = APITime.parse(detail.window?.startUtc)
        let end = APITime.parse(detail.window?.endUtc)
        meetingStart = start
        meetingEnd = end
        var first = APITime.parse(detail.window?.fetchStartUtc) ?? start ?? earliest ?? Date()
        var last = APITime.parse(detail.window?.fetchEndUtc) ?? end ?? latest ?? first.addingTimeInterval(60)
        if last <= first { last = first.addingTimeInterval(60) }
        if let earliest, earliest < first, detail.window?.fetchStartUtc == nil { first = earliest }
        from = first
        to = last

        var band: ClosedRange<Double>?
        if let lowBpm = detail.baseline?.lowBpm, let highBpm = detail.baseline?.highBpm, lowBpm <= highBpm {
            band = lowBpm...highBpm
        }
        self.band = band
        let hasSeries = !detail.series.isEmpty
        let lowest = [hasSeries ? minimum : nil, band?.lowerBound].compactMap { $0 }.min()
        let highest = [hasSeries ? maximum : nil, band?.upperBound].compactMap { $0 }.max()
        low = lowest.map { $0 - 4 } ?? 50
        high = highest.map { $0 + 4 } ?? 100
        minBpm = hasSeries ? minimum : nil
        maxBpm = hasSeries ? maximum : nil
        usualMeanBpm = detail.baseline?.meanBpm
        peakStress = detail.stress?.peakLevel
        stress = (detail.stress?.points ?? []).compactMap { point in
            APITime.parse(point.t).map { MeetingChartStressPoint(date: $0, level: point.level) }
        }
    }
}

/// The small line shown while the full detail loads, from the series that came with the day.
public struct MeetingSparklineModel: Equatable, Sendable {
    public var points: [MeetingChartPoint]
    public var minBpm: Double
    public var maxBpm: Double

    /// nil when fewer than two points have a readable time.
    public init?(series: [HRPoint], maxPoints: Int = 120) {
        var all: [MeetingChartPoint] = []
        all.reserveCapacity(series.count)
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for point in series {
            guard let date = APITime.parse(point.t) else { continue }
            all.append(MeetingChartPoint(date: date, bpm: point.bpm))
            minimum = Swift.min(minimum, point.bpm)
            maximum = Swift.max(maximum, point.bpm)
        }
        guard all.count > 1 else { return nil }
        points = HRDownsampling.thin([all.map(\.bpm)], maxPoints: maxPoints)[0].map { all[$0] }
        minBpm = minimum
        maxBpm = maximum
    }
}

/// Thinning that keeps what a reader looks for: each bucket's lowest and highest value, and the ends.
public enum HRDownsampling {
    /// For each run of values, the indexes to draw (ascending, no repeats). With `maxPoints` or fewer values in all,
    /// every index. Otherwise each run gets a share of `maxPoints` in proportion to its length, and a run over its share
    /// is cut into equal buckets that each keep their first lowest and first highest value, plus the run's first and
    /// last. A run keeps at most its share plus 2 points, so the total is at most `maxPoints` plus 2 per run.
    public static func thin(_ runs: [[Double]], maxPoints: Int) -> [[Int]] {
        let total = runs.reduce(0) { $0 + $1.count }
        if total <= maxPoints { return runs.map { Array($0.indices) } }
        return runs.map { run in
            let share = total > 0 ? maxPoints * run.count / total : 0
            return keep(run, budget: share)
        }
    }

    static func keep(_ values: [Double], budget: Int) -> [Int] {
        let count = values.count
        if count <= budget || count <= 2 { return Array(values.indices) }
        if budget < 2 { return [0, count - 1] }
        let buckets = budget / 2
        var kept: [Int] = [0, count - 1]
        kept.reserveCapacity(buckets * 2 + 2)
        for bucket in 0..<buckets {
            let start = bucket * count / buckets
            let end = (bucket + 1) * count / buckets
            guard start < end else { continue }
            var lowIndex = start
            var highIndex = start
            var index = start + 1
            while index < end {
                if values[index] < values[lowIndex] { lowIndex = index }
                if values[index] > values[highIndex] { highIndex = index }
                index += 1
            }
            kept.append(lowIndex)
            kept.append(highIndex)
        }
        return Array(Set(kept)).sorted()
    }
}

/// Why a held meeting detail is being refreshed. A toggle of the display sources changes what a chart may show.
public enum MeetingDetailRefresh: Sendable {
    /// A sync or a live window ended: the same sources, so the chart stays up while it reloads.
    case sameSources
    /// A display source was turned on or off: the held chart may show a source that is now off.
    case sourcesChanged
}

/// What to show for one meeting's heart rate detail, and when to load it again. A pure value: `TodayModel` keeps one
/// per meeting. A reload keeps the old data on screen (`showsLoadingPlaceholder` stays false), so an open chart never
/// blinks to "Loading heart rate". Switching day or connection does not use this: every entry is dropped.
public struct MeetingDetailState<Value> {
    public var data: Value?
    public var error: String?
    public var loading: Bool
    public var loadedAt: Date?
    public var stale: Bool

    public init(data: Value? = nil, error: String? = nil, loading: Bool = false, loadedAt: Date? = nil, stale: Bool = false) {
        self.data = data
        self.error = error
        self.loading = loading
        self.loadedAt = loadedAt
        self.stale = stale
    }

    /// A load starts: loading on, error cleared, data and stale kept.
    public func beginLoad() -> Self {
        var next = self
        next.loading = true
        next.error = nil
        return next
    }

    public func finishLoad(_ value: Value, at date: Date) -> Self {
        Self(data: value, error: nil, loading: false, loadedAt: date, stale: false)
    }

    /// The old data stays, with the reason it could not be refreshed. Stale is cleared so a failing call is tried
    /// again after `maxAge`, not on every visit.
    public func failLoad(_ message: String, at date: Date) -> Self {
        var next = self
        next.error = message
        next.loading = false
        next.stale = false
        next.loadedAt = date
        return next
    }

    /// The data is out of date but still shown until a new answer lands.
    public func markStale() -> Self {
        var next = self
        next.stale = true
        return next
    }

    /// The state after a refresh, or nil when the held entry must be dropped. Same sources: stale, data kept on screen.
    /// Sources changed: nil, because the held chart may show a source that is now off.
    public func refreshed(_ change: MeetingDetailRefresh) -> Self? {
        switch change {
        case .sameSources: return markStale()
        case .sourcesChanged: return nil
        }
    }

    /// Whether a load that just ended is tried once more: only when a refresh landed while it ran, and only after the
    /// first attempt (`attempt` is 1-based, the one that just ended). Used on both success and failure.
    public static func retriesLoad(refreshedWhileLoading: Bool, attempt: Int) -> Bool {
        refreshedWhileLoading && attempt < 2
    }

    /// A reload failed and the older data is still shown.
    public var refreshFailed: Bool { data != nil && error != nil && !loading }

    /// False while loading; true when stale, never loaded, or `maxAge` seconds old.
    public func needsLoad(now: Date, maxAge: TimeInterval) -> Bool {
        if loading { return false }
        if stale { return true }
        guard let loadedAt else { return true }
        return now.timeIntervalSince(loadedAt) >= maxAge
    }

    /// Loading with nothing to show yet.
    public var showsLoadingPlaceholder: Bool { loading && data == nil }
}

extension MeetingDetailState: Equatable where Value: Equatable {}
extension MeetingDetailState: Sendable where Value: Sendable {}

/// Remembers the live chart between the card's 1 second ticks. Nothing is rescanned while no reading has arrived and
/// the clock has not passed a moment that changes the answer: the next reading that was in the future (it appears once
/// due) or the newest reading going stale (the current value goes away on time). A new reading, a changed window or a
/// clock that moved backwards recomputes. Readings are matched by count and first and last time, which is enough
/// because a poll only ever adds newer readings or starts over.
public struct LiveChartMemo: Sendable {
    private struct Key: Equatable, Sendable {
        var count: Int
        var firstMs: Double
        var lastMs: Double
        var window: LiveWindowMs
        var maxPoints: Int
    }

    private var key: Key?
    private var computedAtMs = 0.0
    private var validUntilMs = 0.0
    private var cached: TodayLiveChart?
    /// How many times the readings were scanned. For tests and diagnostics.
    public private(set) var scans = 0

    public init() {}

    public mutating func chart(
        points: [LivePoint], window: LiveWindowMs, nowMs: Double, maxPoints: Int = TodayLogic.liveMaxPoints
    ) -> TodayLiveChart {
        let next = Key(
            count: points.count, firstMs: points.first?.ms ?? 0, lastMs: points.last?.ms ?? 0,
            window: window, maxPoints: maxPoints)
        if let cached, key == next, nowMs >= computedAtMs, nowMs < validUntilMs { return cached }
        let result = TodayLogic.liveChartWithHorizon(points: points, window: window, nowMs: nowMs, maxPoints: maxPoints)
        scans += 1
        key = next
        computedAtMs = nowMs
        validUntilMs = result.validUntilMs
        cached = result.chart
        return result.chart
    }
}
