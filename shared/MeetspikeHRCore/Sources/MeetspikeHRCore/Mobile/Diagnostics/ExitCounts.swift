import Foundation

/// Abnormal exit counts from a MetricKit metric payload (`MXMetricPayload.jsonRepresentation()`,
/// `applicationExitMetrics`). A normal exit never counts. MetricKit's counts are cumulative over the payload's day,
/// so one payload is at most one report.
public struct ExitCounts: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        public var memoryLimit = 0
        public var watchdog = 0
        public var crash = 0
        public var illegalInstruction = 0
        public var suspendedWithLockedFile = 0
        public var backgroundTaskTimeout = 0
        public var memoryPressure = 0
        /// Background only: the system stopped the app for using too much CPU while it was off screen.
        public var cpuLimit = 0

        public init() {}

        public var total: Int {
            memoryLimit + watchdog + crash + illegalInstruction + suspendedWithLockedFile + backgroundTaskTimeout + memoryPressure + cpuLimit
        }
    }

    public var foreground = Counts()
    public var background = Counts()

    public init() {}

    /// Never fails: bad JSON, or no `applicationExitMetrics`, is all zeros.
    public init(json: Data) {
        guard let parsed = try? JSONSerialization.jsonObject(with: json, options: []),
              let root = parsed as? [String: Any],
              let exits = root["applicationExitMetrics"] as? [String: Any] else { return }
        if let data = exits["foregroundExitData"] as? [String: Any] {
            foreground.memoryLimit = Self.count(data, "cumulativeMemoryResourceLimitExitCount")
            foreground.watchdog = Self.count(data, "cumulativeAppWatchdogExitCount")
            foreground.crash = Self.count(data, "cumulativeBadAccessExitCount") + Self.count(data, "cumulativeAbnormalExitCount")
            foreground.illegalInstruction = Self.count(data, "cumulativeIllegalInstructionExitCount")
        }
        if let data = exits["backgroundExitData"] as? [String: Any] {
            background.memoryLimit = Self.count(data, "cumulativeMemoryResourceLimitExitCount")
            background.watchdog = Self.count(data, "cumulativeAppWatchdogExitCount")
            background.crash = Self.count(data, "cumulativeBadAccessExitCount") + Self.count(data, "cumulativeAbnormalExitCount")
            background.illegalInstruction = Self.count(data, "cumulativeIllegalInstructionExitCount")
            background.suspendedWithLockedFile = Self.count(data, "cumulativeSuspendedWithLockedFileExitCount")
            background.backgroundTaskTimeout = Self.count(data, "cumulativeBackgroundTaskAssertionTimeoutExitCount")
            background.memoryPressure = Self.count(data, "cumulativeMemoryPressureExitCount")
            background.cpuLimit = Self.count(data, "cumulativeCPUResourceLimitExitCount")
        }
    }

    public var hasProblem: Bool { foreground.total > 0 || background.total > 0 }

    /// The `report` of an `exit` report: {"exits": {"foreground.memoryLimit": 2, ...}} with only the non-zero counts.
    public var report: DiagnosticValue {
        var map: [String: DiagnosticValue] = [:]
        for (prefix, counts) in [("foreground", foreground), ("background", background)] {
            let named: [(String, Int)] = [
                ("memoryLimit", counts.memoryLimit), ("watchdog", counts.watchdog), ("crash", counts.crash),
                ("illegalInstruction", counts.illegalInstruction), ("suspendedWithLockedFile", counts.suspendedWithLockedFile),
                ("backgroundTaskTimeout", counts.backgroundTaskTimeout), ("memoryPressure", counts.memoryPressure),
                ("cpuLimit", counts.cpuLimit),
            ]
            for (name, value) in named where value > 0 { map["\(prefix).\(name)"] = .number(Double(value)) }
        }
        return .object(["exits": .object(map)])
    }

    /// A number the payload wrote as a number. Text, booleans, nulls and negatives are 0.
    private static func count(_ data: [String: Any], _ key: String) -> Int {
        guard let number = data[key] as? NSNumber, String(cString: number.objCType) != "c" else { return 0 }
        let value = number.doubleValue
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value.rounded(), 1_000_000_000))
    }
}
