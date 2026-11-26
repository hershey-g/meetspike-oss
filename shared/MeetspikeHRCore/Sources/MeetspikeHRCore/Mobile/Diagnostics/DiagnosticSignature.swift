import Foundation

/// A short text that is the same for the same crash, so the reports can be grouped: the exception, the signal and the
/// termination reason, then the top three frames of the thread that crashed ("binary+offset", crash site first).
public enum DiagnosticSignature {
    static let maxLength = 200

    /// `report` is the scrubbed value. Only crash, hang, CPU and disk reports have stacks; the others get nil.
    public static func make(kind: DiagnosticReport.Kind, report: DiagnosticValue) -> String? {
        DiagnosticStack.run { build(kind: kind, report: report) }
    }

    private static func build(kind: DiagnosticReport.Kind, report: DiagnosticValue) -> String? {
        switch kind {
        case .crash, .hang, .cpu, .disk: break
        case .exit, .error, .test: return nil
        }
        guard case .object(let root) = report else { return nil }
        let prefix = prefixText(root)
        let frames = topFrames(root)
        var text: String
        switch (prefix.isEmpty, frames.isEmpty) {
        case (true, true): return nil
        case (false, true): text = prefix
        case (true, false): text = frames.joined(separator: " < ")
        case (false, false): text = prefix + " | " + frames.joined(separator: " < ")
        }
        if text.count > maxLength { text = String(text.prefix(maxLength)) }
        return text
    }

    private static func prefixText(_ root: [String: DiagnosticValue]) -> String {
        guard case .object(let meta)? = root["diagnosticMetaData"] else { return "" }
        var parts: [String] = []
        for key in ["exceptionType", "signal", "terminationReason"] {
            switch meta[key] {
            case .number(let value)?: parts.append(whole(value))
            case .string(let value)?: if !value.isEmpty { parts.append(value) }
            default: break
            }
        }
        return parts.joined(separator: "/")
    }

    /// Up to three frames, crash site first, from the attributed thread's heaviest path. With `callStackPerThread` true
    /// MetricKit writes the newest frame as the root and the oldest (dyld, main) at the end of the chain, so the first
    /// three of the chain from the root are the crash site. Otherwise the root is the outermost caller and the deepest
    /// frames are the top of the stack, so the chain is read from its end.
    private static func topFrames(_ root: [String: DiagnosticValue]) -> [String] {
        guard case .object(let tree)? = root["callStackTree"], case .array(let stacks)? = tree["callStacks"] else { return [] }
        let objects: [[String: DiagnosticValue]] = stacks.compactMap {
            if case .object(let map) = $0 { return map } else { return nil }
        }
        let stack = objects.first { $0["threadAttributed"] == .bool(true) } ?? objects.first
        guard let stack, case .array(let roots)? = stack["callStackRootFrames"] else { return [] }
        var chain: [String] = []
        var level = heaviest(roots)
        // Bounded by the scrubber's depth limit, but never trust the input to be shallow.
        var steps = 0
        while let frame = level, steps < 1000 {
            if case .string(let name)? = frame["binaryName"], case .number(let offset)? = frame["offsetIntoBinaryTextSegment"] {
                chain.append("\(name)+\(whole(offset))")
            }
            if case .array(let children)? = frame["subFrames"] { level = heaviest(children) } else { level = nil }
            steps += 1
        }
        if case .bool(true)? = tree["callStackPerThread"] { return Array(chain.prefix(3)) }
        return Array(chain.reversed().prefix(3))
    }

    /// The frame with the highest sampleCount, the first one on a tie.
    private static func heaviest(_ frames: [DiagnosticValue]) -> [String: DiagnosticValue]? {
        var best: [String: DiagnosticValue]?
        var bestCount = -Double.infinity
        for case .object(let frame) in frames {
            var count = 0.0
            if case .number(let value)? = frame["sampleCount"] { count = value }
            if count > bestCount { best = frame; bestCount = count }
        }
        return best
    }

    private static func whole(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }
}
