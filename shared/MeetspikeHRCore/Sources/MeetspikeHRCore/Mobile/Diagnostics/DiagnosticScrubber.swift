import Foundation

/// Turns one MetricKit diagnostic (`jsonRepresentation()`) into the `report` the Worker stores. Only an allowlist of
/// keys survives, and under them only numbers, booleans and strings. Anything that can hold personal text
/// (exception reasons, message arguments, memory regions, region, bundle id, pid) is dropped with its subtree.
///
/// The same limits as the Worker's `sanitizeReport` apply on the phone (depth 300, 20,000 nodes, strings cut to 500),
/// plus a byte budget so the encoded result always fits well inside the Worker's 256 KB body limit. The Worker
/// answers 413 to a body that is too big and the phone drops a 413, so the report would be lost.
public enum DiagnosticScrubber {
    /// Keys kept at any depth. Everything else is dropped. Matches REPORT_KEYS in src/lib/diagnostics.ts.
    static let allowedKeys: Set<String> = [
        "callStackTree", "callStacks", "callStackPerThread", "threadAttributed", "callStackRootFrames", "subFrames",
        "binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address", "sampleCount", "diagnosticMetaData",
        "appBuildVersion", "appVersion", "osVersion", "deviceType", "platformArchitecture", "exceptionType",
        "exceptionCode", "signal", "terminationReason", "hangDuration", "totalCPUTime", "totalSampledTime",
        "writesCaused", "exits", "message", "code", "path",
    ]

    static let maxDepth = 300
    static let maxNodes = 20_000
    static let maxString = 500
    /// Encoded size of the report value. The whole body (report, up to 150 crumbs of 200 characters, the rest) must
    /// stay under the Worker's 256 KB, and the tests pin the report under 200,000.
    static let maxBytes = 190_000

    /// Runs on `DiagnosticStack`: parsing and walking the tree recurse once per level. The result is deep too, so the
    /// caller should keep it inside a `DiagnosticStack.run` until it is done with it (the report builder does).
    public static func scrub(_ data: Data) -> DiagnosticValue {
        DiagnosticStack.run {
            guard !data.isEmpty else { return .object([:]) }
            // Anything nested past the limit is cut out first, so `JSONSerialization` (which refuses past 512
            // levels) never sees it and a very deep stack still keeps its metadata, signal and shallow frames.
            let shallow = limitingDepth(data, to: maxDepth)
            guard let parsed = try? JSONSerialization.jsonObject(with: shallow, options: []),
                  let root = parsed as? [String: Any] else { return .object([:]) }
            var state = State()
            return .object(state.object(root, depth: 1, exits: false))
        }
    }

    /// The same JSON with every container deeper than `limit` levels (the root is level 1) replaced by `null`. One
    /// pass over the bytes, no recursion, and it understands strings and escapes so brackets inside text do not
    /// count. Not valid JSON in, not valid JSON out (the parser then says no). Returns `data` itself when nothing
    /// was that deep.
    static func limitingDepth(_ data: Data, to limit: Int) -> Data {
        var out: [UInt8] = []
        var cut = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            out.reserveCapacity(raw.count)
            var depth = 0          // open containers that were kept
            var skipping = 0       // open containers inside a cut one (0 = not cutting)
            var inString = false
            var escaped = false
            for byte in raw {
                if inString {
                    if skipping == 0 { out.append(byte) }
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                    continue
                }
                switch byte {
                case 0x22:
                    inString = true
                    if skipping == 0 { out.append(byte) }
                case 0x7B, 0x5B:   // { [
                    if skipping > 0 {
                        skipping += 1
                    } else if depth >= limit {
                        skipping = 1
                        cut = true
                        out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])   // null
                    } else {
                        depth += 1
                        out.append(byte)
                    }
                case 0x7D, 0x5D:   // } ]
                    if skipping > 0 {
                        skipping -= 1
                    } else {
                        depth -= 1
                        out.append(byte)
                    }
                default:
                    if skipping == 0 { out.append(byte) }
                }
            }
        }
        return cut ? Data(out) : data
    }

    private struct State {
        var nodes = 1   // the root
        var bytes = 2
        var full = false

        mutating func object(_ source: [String: Any], depth: Int, exits: Bool) -> [String: DiagnosticValue] {
            var out: [String: DiagnosticValue] = [:]
            let keys = exits ? Array(source.keys) : source.keys.filter { DiagnosticScrubber.allowedKeys.contains($0) }
            // Plain values first, then the metadata, then the other containers, so when a huge tree runs out of room
            // what is lost is the tail of the stacks, not the small facts around them.
            let ordered = keys.sorted { lhs, rhs in
                let l = Self.rank(source[lhs], key: lhs), r = Self.rank(source[rhs], key: rhs)
                return l != r ? l < r : lhs < rhs
            }
            for key in ordered {
                if full { break }
                guard let value = source[key] else { continue }
                if exits && key == "__proto__" { continue }
                let overhead = Self.escapedLength(key) + 4   // quotes, colon, comma
                if let converted = convert(value, overhead: overhead, depth: depth, key: key, inExits: exits) {
                    out[key] = converted
                }
            }
            return out
        }

        private mutating func array(_ source: [Any], depth: Int) -> [DiagnosticValue] {
            var out: [DiagnosticValue] = []
            for element in source {
                if full { break }
                if let converted = convert(element, overhead: 1, depth: depth, key: nil, inExits: false) {
                    out.append(converted)
                }
            }
            return out
        }

        private mutating func convert(_ value: Any, overhead: Int, depth: Int, key: String?, inExits: Bool) -> DiagnosticValue? {
            if value is NSNull { return nil }
            if let number = value as? NSNumber {
                if Self.isBool(number) {
                    if inExits { return nil }
                    return charge(overhead + 5) ? .bool(number.boolValue) : nil
                }
                let double = number.doubleValue
                guard double.isFinite else { return nil }
                return charge(overhead + Self.numberLength(double)) ? .number(double) : nil
            }
            if inExits { return nil }   // exits is a map of string to number, nothing else
            if let text = value as? String {
                let cut = Self.cut(text)
                return charge(overhead + Self.escapedLength(cut) + 2) ? .string(cut) : nil
            }
            if let map = value as? [String: Any] {
                guard depth + 1 <= DiagnosticScrubber.maxDepth, charge(overhead + 2) else { return nil }
                return .object(object(map, depth: depth + 1, exits: key == "exits"))
            }
            if let list = value as? [Any] {
                guard depth + 1 <= DiagnosticScrubber.maxDepth, charge(overhead + 2) else { return nil }
                return .array(array(list, depth: depth + 1))
            }
            return nil
        }

        /// Takes one node and `size` bytes, or marks the budget as spent.
        private mutating func charge(_ size: Int) -> Bool {
            if nodes >= DiagnosticScrubber.maxNodes || bytes + size > DiagnosticScrubber.maxBytes {
                full = true
                return false
            }
            nodes += 1
            bytes += size
            return true
        }

        private static func rank(_ value: Any?, key: String) -> Int {
            if value is [String: Any] || value is [Any] { return key == "diagnosticMetaData" ? 1 : 2 }
            return 0
        }

        private static func isBool(_ number: NSNumber) -> Bool {
            String(cString: number.objCType) == "c"
        }

        private static func numberLength(_ value: Double) -> Int {
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)).count }
            return "\(value)".count
        }

        /// Characters of JSON text a string takes, counting the worst case: every `/` is escaped and every control
        /// character takes six.
        static func escapedLength(_ text: String) -> Int {
            var total = 0
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x22, 0x5C, 0x2F: total += 2
                case 0..<0x20: total += 6
                default: total += String(scalar).utf8.count
                }
            }
            return total
        }

        /// At most 500 UTF-16 units, never splitting a surrogate pair.
        static func cut(_ text: String) -> String {
            guard text.utf16.count > DiagnosticScrubber.maxString else { return text }
            var units = 0
            var out = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                let size = scalar.value > 0xFFFF ? 2 : 1
                if units + size > DiagnosticScrubber.maxString { break }
                units += size
                out.append(scalar)
            }
            return String(out)
        }
    }
}
