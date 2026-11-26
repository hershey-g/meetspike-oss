import Foundation

/// Edits waiting to be sent, one file each, so an edit made offline survives the app being killed and goes out later.
/// One pending edit per (event id, scope): enqueuing again merges per field into it. The newer edit keeps the older
/// edit's fields it does not touch, and its own fields win (`.clear` counts as touched). The merged edit is stored under
/// the newer `queuedAt`.
/// Nothing here throws: a directory that cannot be written makes `enqueue` answer false, a file that is junk is
/// skipped. Any event id is safe, because the file name is a hash and the id itself lives inside the file.
public struct OverrideOutbox: Sendable {
    public struct Item: Equatable, Sendable {
        public let eventID: String
        public let edit: OverrideEdit
        public let queuedAt: Date

        public init(eventID: String, edit: OverrideEdit, queuedAt: Date) {
            self.eventID = eventID
            self.edit = edit
            self.queuedAt = queuedAt
        }

        /// The same queued entry: the same meeting, scope and moment of queuing. Callers that ask "is this the edit I
        /// queued" use this, not `==`, so a change in how an edit is written can never break the match.
        public func isSameEntry(as other: Item) -> Bool {
            eventID == other.eventID && edit.scope == other.edit.scope && queuedAt == other.queuedAt
        }
    }

    public let directory: URL

    /// One lock for every outbox in the process: the files are tiny and this keeps a reader from seeing a half
    /// written file or removing one that was just replaced.
    private static let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// True when the edit is on disk. False means it was not saved (no space, no permission), and the caller says so.
    @discardableResult
    public func enqueue(eventID: String, edit: OverrideEdit, at: Date) -> Bool {
        enqueueReplacing(eventID: eventID, edit: edit, at: at).saved
    }

    /// `enqueue`, and also the item that was stored for this event and scope just before, exactly as `pending()` showed
    /// it (nil when there was none). A caller whose edit is then refused hands that item back to `restore`.
    @discardableResult
    public func enqueueReplacing(eventID: String, edit: OverrideEdit, at: Date) -> (saved: Bool, replaced: Item?) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = file(eventID: eventID, scope: edit.scope)
        let replaced = read(url)
        let merged = replaced.map { Self.merge(older: $0.edit, newer: edit) } ?? edit
        let saved = write(Item(eventID: eventID, edit: merged, queuedAt: at), to: url)
        return (saved, replaced)
    }

    /// Puts `replaced` back in place of the entry for `insteadOf`'s event and scope, or removes that entry when
    /// `replaced` is nil. It only acts while the stored entry is still `insteadOf` (same event, scope and queuedAt), so
    /// an edit queued meanwhile, or one that was already sent and removed, is left alone.
    public func restore(_ replaced: Item?, insteadOf item: Item) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = file(eventID: item.eventID, scope: item.edit.scope)
        guard let stored = read(url), stored.isSameEntry(as: item) else { return }
        if let replaced, replaced.eventID == item.eventID, replaced.edit.scope == item.edit.scope {
            _ = write(replaced, to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Oldest first (ties by event id, then scope).
    public func pending() -> [Item] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return load().sorted { lhs, rhs in
            if lhs.queuedAt != rhs.queuedAt { return lhs.queuedAt < rhs.queuedAt }
            if lhs.eventID != rhs.eventID { return lhs.eventID < rhs.eventID }
            return lhs.edit.scope.rawValue < rhs.edit.scope.rawValue
        }
    }

    /// Removes the stored edit, but only while it is still this item: an edit queued while this one was being sent
    /// stays.
    public func remove(_ item: Item) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = file(eventID: item.eventID, scope: item.edit.scope)
        guard let stored = read(url), stored.isSameEntry(as: item) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Private (the lock is held)

    /// `queuedRef` is the Date's own value (seconds since the reference date), so a Date that went through the disk
    /// compares equal to the one that was saved. Going through the 1970 epoch moves some Dates by a rounding step.
    /// `queuedAt` (seconds since 1970) is what earlier builds wrote; it is still read.
    private struct Stored: Codable {
        let eventID: String
        var queuedRef: Double?
        var queuedAt: Double?
        let edit: OverrideEdit

        init(eventID: String, queuedRef: Double, edit: OverrideEdit) {
            self.eventID = eventID
            self.queuedRef = queuedRef
            self.queuedAt = nil
            self.edit = edit
        }

        var seconds: Double? {
            if let queuedRef { return Date(timeIntervalSinceReferenceDate: queuedRef).timeIntervalSinceReferenceDate }
            return queuedAt.map { Date(timeIntervalSince1970: $0).timeIntervalSinceReferenceDate }
        }

        var item: Item? {
            seconds.map { Item(eventID: eventID, edit: edit, queuedAt: Date(timeIntervalSinceReferenceDate: $0)) }
        }
    }

    /// The newer edit's own fields win, the older edit's fields fill the rest.
    private static func merge(older: OverrideEdit, newer: OverrideEdit) -> OverrideEdit {
        func pick<Value>(_ new: OverrideEdit.Change<Value>, _ old: OverrideEdit.Change<Value>) -> OverrideEdit.Change<Value> {
            if case .unchanged = new { return old }
            return new
        }
        return OverrideEdit(
            scope: newer.scope, state: pick(newer.state, older.state),
            startUtc: pick(newer.startUtc, older.startUtc), endUtc: pick(newer.endUtc, older.endUtc))
    }

    private func read(_ url: URL) -> Item? {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let item = stored.item, item.queuedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return item
    }

    private func write(_ item: Item, to url: URL) -> Bool {
        let stored = Stored(eventID: item.eventID, queuedRef: item.queuedAt.timeIntervalSinceReferenceDate, edit: item.edit)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func load() -> [Item] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }
        var items: [Item] = []
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  let item = stored.item, item.queuedAt.timeIntervalSinceReferenceDate.isFinite else { continue }
            items.append(item)
        }
        return items
    }

    /// A fixed length name made from the id and scope: any id is safe (slashes, dots, case, 400 characters), and ids
    /// that differ only by case get different files on a case-insensitive disk.
    private func file(eventID: String, scope: MeetingOverride.Scope) -> URL {
        let bytes = Array("\(scope.rawValue)\u{0}\(eventID)".utf8)
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        let name = String(fnv(0xcbf2_9ce4_8422_2325), radix: 16) + "-" + String(fnv(0x8422_2325_cbf2_9ce4), radix: 16)
            + "-" + scope.rawValue + ".json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
