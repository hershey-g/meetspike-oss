import Foundation

/// Stable ids for reports made from MetricKit payloads, so the same payload is never queued twice (MetricKit can
/// redeliver, and `pastDiagnosticPayloads` returns what was already delivered).
public enum DiagnosticIDs {
    /// The same bytes, kind and index always give the same id. Two FNV-1a 64-bit hashes with different seeds make the
    /// 128 bits; the version and variant bits are set so it reads as a normal UUID.
    public static func stable(payload: Data, kind: DiagnosticReport.Kind, index: Int) -> UUID {
        let tail = Array("|\(kind.rawValue)|\(index)".utf8)
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x84222325_cbf29ce4
        for byte in payload { mix(&first, byte); mix(&second, byte &+ 0x5A) }
        for byte in tail { mix(&first, byte); mix(&second, byte &+ 0x5A) }
        var bytes = [UInt8](repeating: 0, count: 16)
        for position in 0..<8 {
            bytes[position] = UInt8(truncatingIfNeeded: first >> UInt64(8 * position))
            bytes[8 + position] = UInt8(truncatingIfNeeded: second >> UInt64(8 * position))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func mix(_ hash: inout UInt64, _ byte: UInt8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
}

/// The ids already turned into reports, kept in a small file (newest 200) so a payload that was queued and then
/// uploaded is not queued again on the next launch.
public struct DiagnosticSeenIDs: Sendable {
    public let file: URL
    public let limit: Int

    private static let lock = NSLock()

    public init(file: URL, limit: Int = 200) {
        self.file = file
        self.limit = max(1, limit)
    }

    /// True if the id is new (and is now remembered), false if it was seen before.
    public func insert(_ id: UUID) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var ids = load()
        let text = id.uuidString.lowercased()
        if ids.contains(text) { return false }
        ids.append(text)
        if ids.count > limit { ids.removeFirst(ids.count - limit) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((ids.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        return true
    }

    public func contains(_ id: UUID) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return load().contains(id.uuidString.lowercased())
    }

    private func load() -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// How many times a payload has been tried, kept in a small file (newest 200 ids). A payload that kills the app while
/// it is being turned into a report would otherwise be tried again at every launch, forever. `begin` runs before the
/// work and counts the try on disk; `finish` runs after, and removes the id. A try that never finished (the app died)
/// stays counted, and after `maxTries` the payload is given up on. Nothing here throws.
public struct DiagnosticAttempts: Sendable {
    public let file: URL
    public let maxTries: Int
    public let limit: Int

    private static let lock = NSLock()

    public init(file: URL, maxTries: Int = 2, limit: Int = 200) {
        self.file = file
        self.maxTries = max(1, maxTries)
        self.limit = max(1, limit)
    }

    /// True when this id may be tried (and the try is now counted), false once it already had `maxTries` tries.
    /// If the count cannot be saved it still says true: better one more try than a report lost to a full disk.
    public func begin(_ id: UUID) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var entries = load()
        let text = id.uuidString.lowercased()
        if let index = entries.firstIndex(where: { $0.id == text }) {
            if entries[index].tries >= maxTries { return false }
            entries[index].tries += 1
        } else {
            entries.append((id: text, tries: 1))
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
        }
        save(entries)
        return true
    }

    /// The work for this id is over (saved, or failed without killing the app): forget its tries.
    public func finish(_ id: UUID) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let text = id.uuidString.lowercased()
        var entries = load()
        guard entries.contains(where: { $0.id == text }) else { return }
        entries.removeAll { $0.id == text }
        save(entries)
    }

    private func load() -> [(id: String, tries: Int)] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var entries: [(id: String, tries: Int)] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let tries = Int(parts[1]), tries > 0 else { continue }
            entries.append((id: String(parts[0]), tries: tries))
        }
        return entries
    }

    private func save(_ entries: [(id: String, tries: Int)]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = entries.map { "\($0.id) \($0.tries)" }.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: file, options: .atomic)
    }
}
