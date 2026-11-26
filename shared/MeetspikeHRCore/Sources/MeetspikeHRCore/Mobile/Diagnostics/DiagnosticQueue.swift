import Foundation

/// Reports waiting to be sent, one JSON file each, named by the report id. A phone that is offline, or a Worker that
/// is down, keeps them until the next try. Over the limit the oldest are dropped. A file that reads but does not
/// decode is deleted, not fatal. A file that cannot be read at all (locked before first unlock, a busy disk) is kept
/// and skipped for now. Nothing here throws. Encoding and decoding run on `DiagnosticStack`: a report can be 300
/// levels deep and the coders recurse once per level.
public struct DiagnosticQueue: Sendable {
    public let directory: URL
    public let maxFiles: Int

    /// One lock for every queue in the process: the files are tiny and this keeps a reader from ever seeing a
    /// half-written file or deleting one that is mid-write.
    private static let lock = NSLock()

    public init(directory: URL, maxFiles: Int = 20) {
        self.directory = directory
        self.maxFiles = max(1, maxFiles)
    }

    /// True only when the report is on disk. False means it was not saved (cannot encode, no space, no permission),
    /// or the queue's own trim removed it again because it is older than everything kept. The caller decides what
    /// that means for the report.
    @discardableResult
    public func add(_ report: DiagnosticReport) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return DiagnosticStack.run {
            guard let data = try? JSONEncoder().encode(report) else { return false }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try data.write(to: url(for: report.id), options: .atomic)
            } catch {
                return false
            }
            let all = load()
            if all.count > maxFiles {
                for old in all.prefix(all.count - maxFiles) { try? FileManager.default.removeItem(at: url(for: old.id)) }
                // The trim drops the oldest. When that is the report just written, it is not on disk.
                return !all.prefix(all.count - maxFiles).contains { $0.id == report.id }
            }
            return true
        }
    }

    /// Oldest first (ties by id). The reports are deep values: prefer `pendingIDs()` when only the ids matter, so
    /// nothing deep is released on a small stack.
    public func pending() -> [DiagnosticReport] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return DiagnosticStack.run { load() }
    }

    /// The ids of `pending()`, oldest first.
    public func pendingIDs() -> [UUID] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return DiagnosticStack.run { load().map(\.id) }
    }

    public func remove(id: UUID) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: id))
    }

    // MARK: Private (the lock is held, on the big stack)

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json", isDirectory: false)
    }

    private func load() -> [DiagnosticReport] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }
        var reports: [DiagnosticReport] = []
        for name in names {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            // Cannot be read now: leave it for a later try. Only a file that reads and does not decode is junk.
            guard let data = try? Data(contentsOf: file) else { continue }
            if let report = try? JSONDecoder().decode(DiagnosticReport.self, from: data) {
                reports.append(report)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return reports.sorted { lhs, rhs in
            lhs.at != rhs.at ? lhs.at < rhs.at : lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
