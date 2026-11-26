import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The last few things the app did, one line each, kept in a small file so they survive a crash.
///
/// `add` appends one line to an open file (a single `write`, no rewrite), so it is cheap and the line is on disk when
/// the call returns. The file is trimmed once it holds more than twice the limit. A failed write is dropped, never
/// thrown: a log must not be able to break the app. `rotate()` hands back the previous session's lines at launch and
/// starts a new file.
public final class CrumbLog: @unchecked Sendable {
    private let directory: URL
    private let file: URL
    private let limit: Int
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    /// Lines in the file, learned on first use then kept up to date. nil until counted.
    private var count: Int?

    public init(directory: URL, limit: Int = 150) {
        self.directory = directory
        file = directory.appendingPathComponent("crumbs.log", isDirectory: false)
        self.limit = max(1, limit)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { closeDescriptor() }

    public func add(_ kind: Crumb, at date: Date) {
        let line = DiagnosticTime.format(date) + " " + kind.body + "\n"
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return }
        if !append(line) {
            // A broken descriptor (disk full, directory gone): drop it and try again on the next add.
            closeDescriptor()
            count = nil
            return
        }
        let total = count.map { $0 + 1 } ?? readLines().count
        count = total
        if total > limit * 2 { trim() }
    }

    /// The current file's newest `limit` lines, oldest first.
    public func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(readLines().suffix(limit))
    }

    /// Returns `lines()` and starts a fresh, empty file.
    public func rotate() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let previous = Array(readLines().suffix(limit))
        closeDescriptor()
        let fresh = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        if fresh >= 0 {
            descriptor = fresh
            count = 0
        } else {
            count = nil
        }
        return previous
    }

    // MARK: Private (the lock is held)

    private func openIfNeeded() -> Bool {
        if descriptor >= 0 { return true }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return false }
        descriptor = opened
        // A kill in the middle of a write can leave a line without its newline. End it so the next line starts clean.
        if let data = try? Data(contentsOf: file), let last = data.last, last != 0x0A { _ = append("\n") }
        return true
    }

    private func append(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
        return written == bytes.count
    }

    private func closeDescriptor() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func readLines() -> [String] {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Keeps the newest `limit` lines. Written to a temporary file and moved over the log, so a kill mid-trim leaves
    /// the old file, not a half one.
    private func trim() {
        let keep = readLines().suffix(limit)
        let temporary = directory.appendingPathComponent("crumbs.log.tmp", isDirectory: false)
        let text = keep.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: temporary, options: .atomic)
            closeDescriptor()
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            count = keep.count
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // Could not trim (read-only directory): keep appending, try again after more lines.
            count = limit + 1
        }
    }
}
