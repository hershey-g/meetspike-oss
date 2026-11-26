import Foundation
import XCTest
@testable import MeetspikeHRCore

// Build 8 fix pass 2 (gate review of 195fca9). Shared helpers for the Build8Fix2* test files. Compiles on today's
// code: it only uses API that exists now. The F1 to F9 contract is in .claude/jobs/92fc823f/tmp/fix8.md.

enum Fix2Payload {
    static let meta = """
    {"appBuildVersion":"8","appVersion":"1.1","osVersion":"iPhone OS 26.1 (23B85)","deviceType":"iPhone16,2",\
    "exceptionType":6,"signal":5,"terminationReason":"Namespace SIGNAL, Code 5"}
    """

    /// One MetricKit crash diagnostic with `frames` frames nested through subFrames (frame i is `f<i>+<i>`), built in
    /// linear time. Container depth of frame i is 6 + 2 * i (root, callStackTree, callStacks, one stack,
    /// callStackRootFrames, then an object and an array per level), so the scrubber's limit of 300 keeps 148 frames.
    static func crash(frames: Int, perThread: Bool = false, meta: String = Fix2Payload.meta) -> String {
        precondition(frames >= 1)
        func head(_ index: Int) -> String {
            "{\"binaryName\":\"f\(index)\",\"offsetIntoBinaryTextSegment\":\(index),\"sampleCount\":1"
        }
        var open = ""
        open.reserveCapacity(frames * 90)
        for index in 0..<(frames - 1) { open += head(index) + ",\"subFrames\":[" }
        let last = head(frames - 1) + "}"
        let close = String(repeating: "]}", count: frames - 1)
        return """
        {"callStackTree":{"callStackPerThread":\(perThread),"callStacks":[{"threadAttributed":true,\
        "callStackRootFrames":[\(open)\(last)\(close)]}]},"diagnosticMetaData":\(meta)}
        """
    }

    /// Container depth the scrubber keeps for `frames` frames.
    static func keptDepth(frames: Int) -> Int { min(300, 4 + 2 * frames) }

    /// The names of the frames down the first branch, walked with a loop (never recursion).
    static func chainNames(_ report: DiagnosticValue) -> [String] {
        guard case .object(let root) = report, case .object(let tree)? = root["callStackTree"],
              case .array(let stacks)? = tree["callStacks"], case .object(let stack)? = stacks.first,
              case .array(let roots)? = stack["callStackRootFrames"] else { return [] }
        var names: [String] = []
        var level: DiagnosticValue? = roots.first
        while case .object(let frame)? = level {
            if case .string(let name)? = frame["binaryName"] { names.append(name) }
            if case .array(let children)? = frame["subFrames"] { level = children.first } else { level = nil }
        }
        return names
    }

    static func metaValue(_ report: DiagnosticValue, _ key: String) -> DiagnosticValue? {
        guard case .object(let root) = report, case .object(let meta)? = root["diagnosticMetaData"] else { return nil }
        return meta[key]
    }
}

extension DiagnosticReportBuilder.Running {
    static let fix2 = DiagnosticReportBuilder.Running(build: 99, version: "9.9", os: "iPhone OS 99", device: "iPhoneX")
}
