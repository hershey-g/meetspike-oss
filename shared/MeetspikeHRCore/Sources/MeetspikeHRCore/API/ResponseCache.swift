import Foundation

/// A decoded response read back from disk, with when it was saved.
public struct CachedValue<Value: Sendable>: Sendable {
    public var value: Value
    public var savedAt: Date
    public init(value: Value, savedAt: Date) {
        self.value = value
        self.savedAt = savedAt
    }
}

/// What a typed load returns: the data, when it was fetched or saved, and whether it came from disk
/// because the network was unreachable. The UI shows "Showing data from <time>" when `isFromCache`.
public struct Loaded<Value: Sendable>: Sendable {
    public var value: Value
    public var savedAt: Date
    public var isFromCache: Bool
    public init(value: Value, savedAt: Date, isFromCache: Bool) {
        self.value = value
        self.savedAt = savedAt
        self.isFromCache = isFromCache
    }
}

/// The last good response for each GET, on disk, so screens still open offline. One file per request
/// key, written atomically. Nothing secret goes in: Access headers are never part of a key or a body.
public actor ResponseCache {
    private struct Envelope: Codable {
        var key: String
        var savedAt: Date
        var body: Data
    }

    private let directory: URL
    private let now: @Sendable () -> Date
    private let maxEntries: Int
    /// Writes that failed (disk full, permissions). The caller still got its answer; this makes the loss visible.
    public private(set) var writeFailures = 0

    public init(directory: URL, maxEntries: Int = 300, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxEntries = maxEntries
        self.now = now
    }

    /// The standard cache folder for one origin: `Caches/MeetspikeAPI/<origin hash>`.
    public static func standard(origin: URL) -> ResponseCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return ResponseCache(directory: base.appendingPathComponent("MeetspikeAPI", isDirectory: true)
            .appendingPathComponent(Self.hash(origin.absoluteString), isDirectory: true))
    }

    /// Saves the raw JSON body of a good answer.
    public func write(_ body: Data, for request: APIRequest) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let envelope = Envelope(key: request.cacheKey, savedAt: now(), body: body)
            let data = try JSONEncoder().encode(envelope)
            #if os(iOS)
            try data.write(to: file(for: request), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file(for: request), options: .atomic)
            #endif
            prune()
        } catch {
            writeFailures += 1
            throw error
        }
    }

    /// The saved body and when it was saved, or nil when nothing (or something unreadable) is stored.
    public func readData(for request: APIRequest) -> (body: Data, savedAt: Date)? {
        guard let data = try? Data(contentsOf: file(for: request)),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.key == request.cacheKey else { return nil }
        return (envelope.body, envelope.savedAt)
    }

    /// The saved response decoded as `type`, or nil.
    public func read<Value: Decodable & Sendable>(_ type: Value.Type, for request: APIRequest) -> CachedValue<Value>? {
        guard let (body, savedAt) = readData(for: request),
              let value = try? JSONDecoder().decode(type, from: body) else { return nil }
        return CachedValue(value: value, savedAt: savedAt)
    }

    /// Forgets what is saved for these days (and for one meeting's detail), so a screen that is offline right after a
    /// change does not show the answer from before it. A saved answer is dropped when its request names one of the
    /// days or a span that holds one: the day view, a range, the people and company lists and their meeting lists.
    /// Anything it cannot read is left alone.
    public func invalidate(days: Set<String>, meetingID: String?) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let detail = meetingID.map { "GET /api/meetings/\(APIRequest.encode($0))/hr" }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
            else { continue }
            if Self.key(envelope.key, touches: days, detail: detail) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// `GET /api/view?date=D`, `?start=S&end=E`, or a detail path, against the days.
    static func key(_ key: String, touches days: Set<String>, detail: String?) -> Bool {
        if let detail, key == detail || key.hasPrefix(detail + "?") { return true }
        guard key.hasPrefix("GET /api/"), let mark = key.firstIndex(of: "?") else { return false }
        var values: [String: String] = [:]
        for pair in key[key.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        if let date = values["date"] { return days.contains(date) }
        if let start = values["start"], let end = values["end"] { return days.contains { $0 >= start && $0 <= end } }
        return false
    }

    /// Forget everything (sign out, or the origin changed).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(for request: APIRequest) -> URL {
        directory.appendingPathComponent("\(Self.hash(request.cacheKey)).json")
    }

    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > maxEntries else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// FNV-1a 64-bit, as hex. Only names files; the envelope holds the real key.
    static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h)
    }
}
