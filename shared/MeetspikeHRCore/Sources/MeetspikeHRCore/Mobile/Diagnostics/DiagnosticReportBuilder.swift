import Foundation

/// Makes the reports the app sends. Pure: the iOS side hands in the MetricKit JSON, the clock and the crumbs.
public enum DiagnosticReportBuilder {
    /// What the app running right now knows about itself. Used for anything the report itself does not say.
    public struct Running: Equatable, Sendable {
        public var build: Int
        public var version: String
        public var os: String
        public var device: String

        public init(build: Int, version: String, os: String, device: String) {
            self.build = build
            self.version = version
            self.os = os
            self.device = device
        }
    }

    /// A crash, hang, CPU or disk diagnostic. The scrubbed tree is the report. Build, version, OS and device come
    /// from the diagnostic's own metadata, because that is the build that crashed, not the one running now.
    /// Only a crash carries crumbs (the previous session's); the rest happened in a session that is not on file.
    public static func diagnostic(
        kind: DiagnosticReport.Kind, json: Data, id: UUID, at: Date, now: Date, running: Running, crumbs: [String]
    ) -> DiagnosticReport {
        // The scrubbed tree can be 300 levels deep: scrub, signature and the temporary values are all made, and the
        // temporaries released, on the big stack. The finished report is released by the caller (the app keeps it
        // inside `DiagnosticStack.run` until it is saved).
        DiagnosticStack.run {
            let report = DiagnosticScrubber.scrub(json)
            let meta = metaData(report)
            return DiagnosticReport(
                id: id, kind: kind, at: min(at, now), build: meta.build ?? running.build, version: meta.version ?? running.version,
                os: meta.os ?? running.os, device: meta.device ?? running.device,
                signature: DiagnosticSignature.make(kind: kind, report: report), report: report,
                crumbs: kind == .crash ? crumbs : []
            )
        }
    }

    /// An `exit` report from a metric payload, or nil when nothing abnormal happened.
    public static func exits(json: Data, id: UUID, at: Date, now: Date, running: Running) -> DiagnosticReport? {
        let counts = ExitCounts(json: json)
        guard counts.hasProblem else { return nil }
        var meta = (build: Int?.none, version: String?.none, os: String?.none, device: String?.none)
        if let parsed = try? JSONSerialization.jsonObject(with: json, options: []) as? [String: Any] {
            if let map = parsed["metaData"] as? [String: Any] {
                meta = fields(build: map["appBuildVersion"], version: map["appVersion"], os: map["osVersion"], device: map["deviceType"])
            }
            // MetricKit also puts the app version at the payload root. The metaData one wins when both are there.
            if meta.version == nil { meta.version = fields(build: nil, version: parsed["appVersion"], os: nil, device: nil).version }
        }
        return DiagnosticReport(
            id: id, kind: .exit, at: min(at, now), build: meta.build ?? running.build, version: meta.version ?? running.version,
            os: meta.os ?? running.os, device: meta.device ?? running.device, signature: nil, report: counts.report, crumbs: []
        )
    }

    /// The report behind "Send a test report".
    public static func test(id: UUID, at: Date, running: Running) -> DiagnosticReport {
        DiagnosticReport(
            id: id, kind: .test, at: at, build: running.build, version: running.version, os: running.os,
            device: running.device, signature: nil, report: .object(["message": .string("Test report")]), crumbs: []
        )
    }

    private static func metaData(_ report: DiagnosticValue) -> (build: Int?, version: String?, os: String?, device: String?) {
        guard case .object(let root) = report, case .object(let meta)? = root["diagnosticMetaData"] else { return (nil, nil, nil, nil) }
        func raw(_ key: String) -> Any? {
            switch meta[key] {
            case .string(let text)?: return text
            case .number(let value)?: return value
            default: return nil
            }
        }
        return fields(build: raw("appBuildVersion"), version: raw("appVersion"), os: raw("osVersion"), device: raw("deviceType"))
    }

    private static func fields(build: Any?, version: Any?, os: Any?, device: Any?) -> (build: Int?, version: String?, os: String?, device: String?) {
        func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var number: Int?
        if let value = build as? String { number = Int(value.trimmingCharacters(in: .whitespaces)) }
        if let value = build as? Double, value.isFinite, value > 0, value < 1_000_000_000 { number = Int(value) }
        if let value = number, value <= 0 { number = nil }
        return (number, text(version), text(os), text(device))
    }
}

/// The yes/no decisions around reports, kept apart from the iOS code so they can be tested.
public enum DiagnosticPolicy {
    /// A new report is queued only when the person has the switch on and this is a real run, not demo mode.
    public static func shouldQueue(enabled: Bool, demo: Bool) -> Bool { enabled && !demo }

    /// The queue is sent only with the switch on, a Meetspike URL and secret, and never in demo mode.
    public static func shouldUpload(enabled: Bool, demo: Bool, hasDestination: Bool, hasSecret: Bool) -> Bool {
        enabled && !demo && hasDestination && hasSecret
    }

    /// The line under "Send a test report" after a try.
    public static func testResultText(sent: Bool) -> String {
        sent ? "Sent." : "Not sent yet. It will try again."
    }

    /// What the line under "Send a test report" says.
    public enum TestLine: Equatable, Sendable {
        /// No line.
        case none
        /// The test report is still in the queue.
        case waiting
        /// The Worker took it.
        case sent
        /// The server refused it (400 or 413). It will not be tried again.
        case refused
        /// It could not be written to the queue.
        case notSaved

        public var text: String? {
            switch self {
            case .none: return nil
            case .waiting: return DiagnosticPolicy.testResultText(sent: false)
            case .sent: return DiagnosticPolicy.testResultText(sent: true)
            case .refused: return "Not sent. Your server refused it."
            case .notSaved: return "Couldn't save the report."
            }
        }
    }

    /// The line for the last test report, from what the queue holds now. First match wins:
    /// - nil `lastTestID` (no test yet, or the switch was turned off and it was dropped): `.none`.
    /// - in `pendingIDs`: `.waiting`.
    /// - in `refusedIDs` (the server refused it): `.refused`.
    /// - in `unsavedIDs` (it never got written to the queue): `.notSaved`.
    /// - otherwise: `.sent` when `sentIDs` is nil or holds the id, else `.notSaved` (it left the queue without being sent).
    public static func testLine(
        lastTestID: UUID?, pendingIDs: Set<UUID>, refusedIDs: Set<UUID> = [], unsavedIDs: Set<UUID> = [],
        sentIDs: Set<UUID>? = nil
    ) -> TestLine {
        guard let id = lastTestID else { return .none }
        if pendingIDs.contains(id) { return .waiting }
        if refusedIDs.contains(id) { return .refused }
        if unsavedIDs.contains(id) { return .notSaved }
        // With the set of ids the Worker really took, "gone from the queue" is not enough: a report pushed out of a
        // full queue is gone too, and was never sent. Without the set, gone means sent.
        guard let sentIDs else { return .sent }
        return sentIDs.contains(id) ? .sent : .notSaved
    }

    /// Crumbs (the session before this launch) go only on a crash that is the one crash in this delivery and came
    /// from a live delivery. A past payload, or several crashes at once, cannot be tied to that session: the crumbs
    /// may belong to a launch in between.
    public static func attachCrumbs(crashCount: Int, live: Bool) -> Bool { live && crashCount == 1 }

    /// "2 reports waiting", or nil when none are.
    public static func waitingText(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 report waiting" : "\(count) reports waiting"
    }
}
