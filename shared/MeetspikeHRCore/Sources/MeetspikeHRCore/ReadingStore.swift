import CSQLite
import Foundation

/// Owns the connection and serializes recording, snapshot reads, encoding, and
/// acknowledgements away from the app's main actor.
public actor ReadingStore {
    private static let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1_000
    private let directory: URL
    private var connection: Database?

    public init(directory: URL) {
        self.directory = directory
    }

    private func database() throws -> Database {
        if let connection { return connection }
        let opened = try Database(directory: directory)
        connection = opened
        return opened
    }

    public func record(bpm: Int, at time: Date) throws {
        // Match the Worker's accepted range and millisecond format.
        let ms = time.unixMilliseconds
        guard (25...250).contains(bpm), ms >= 100_000_000_000 else { return }
        try database().execute("""
            INSERT INTO samples (time_ms, bpm) VALUES (?1, ?2)
            ON CONFLICT(time_ms) DO UPDATE SET
                bpm = excluded.bpm, revision = samples.revision + 1, acknowledged_at_ms = NULL
            WHERE excluded.bpm <> samples.bpm
            """, [ms, Int64(bpm)])
    }

    public func prune(now: Date) throws {
        try database().execute(
            "DELETE FROM samples WHERE acknowledged_revision = revision AND acknowledged_at_ms < ?1",
            [now.unixMilliseconds - Self.retentionMs]
        )
    }

    public func readings(from start: Date, through end: Date) throws -> [HeartRatePoint] {
        let db = try database()
        let query = try db.prepare("SELECT time_ms, bpm FROM samples WHERE time_ms BETWEEN ?1 AND ?2 ORDER BY time_ms")
        defer { sqlite3_finalize(query) }
        try db.bind([start.unixMilliseconds, end.unixMilliseconds], to: query)
        var points: [HeartRatePoint] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            points.append(HeartRatePoint(timeMs: sqlite3_column_int64(query, 0), bpm: Int(sqlite3_column_int(query, 1))))
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw Database.Error.failed }
        return points
    }

    public func prepare(through end: Date, fetchedAt: Date = .now) throws -> UploadBatch? {
        let db = try database()
        let query = try db.prepare("""
            SELECT time_ms, bpm, revision FROM samples
            WHERE acknowledged_revision <> revision AND time_ms <= ?1
            ORDER BY time_ms LIMIT ?2
            """)
        defer { sqlite3_finalize(query) }
        try db.bind([end.unixMilliseconds, Int64(UploadBatch.maxPoints)], to: query)

        var points: [HeartRatePoint] = []
        var pending: [ReadingReceipt] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            let timeMs = sqlite3_column_int64(query, 0)
            let bpm = Int(sqlite3_column_int(query, 1))
            let revision = sqlite3_column_int64(query, 2)
            points.append(HeartRatePoint(timeMs: timeMs, bpm: bpm))
            pending.append(ReadingReceipt(timeMs: timeMs, bpm: bpm, revision: revision))
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw Database.Error.failed }
        guard !points.isEmpty else { return nil }
        let payload = IngestPayload(fetchedAt: fetchedAt, hr: .init(points: points))
        return UploadBatch(body: try payload.encoded(), pending: pending)
    }

    public func acknowledge(_ batch: UploadBatch, httpStatus: Int, at receivedAt: Date = .now) throws {
        guard httpStatus == 200 else { return }
        let db = try database()
        let statement = try db.prepare("""
            UPDATE samples SET acknowledged_revision = ?1, acknowledged_at_ms = ?4
            WHERE time_ms = ?2 AND revision = ?1 AND bpm = ?3 AND acknowledged_revision <> revision
            """)
        defer { sqlite3_finalize(statement) }
        try db.transaction {
            for reading in batch.pending {
                try db.bind([reading.revision, reading.timeMs, Int64(reading.bpm), receivedAt.unixMilliseconds], to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_reset(statement) == SQLITE_OK else {
                    throw Database.Error.failed
                }
            }
        }
    }
}

private final class Database {
    enum Error: Swift.Error { case failed }
    private let handle: OpaquePointer

    convenience init(directory: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        #if os(iOS)
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        #endif
        let path = directory.appendingPathComponent("readings.sqlite3").path
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw Error.failed
        }
        self.init(connection)

        sqlite3_busy_timeout(handle, 1_000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute("PRAGMA secure_delete = ON")
        try transaction {
            try execute("""
                CREATE TABLE IF NOT EXISTS samples (
                    time_ms INTEGER PRIMARY KEY,
                    bpm INTEGER NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1,
                    acknowledged_revision INTEGER NOT NULL DEFAULT 0
                )
                """)
            try execute("""
                CREATE INDEX IF NOT EXISTS pending_samples ON samples(time_ms)
                WHERE acknowledged_revision <> revision
                """)
            try migrateReceipts()
            try importLegacyReadings()
        }
    }

    private init(_ connection: OpaquePointer) { handle = connection }
    deinit { sqlite3_close(handle) }

    private func importLegacyReadings() throws {
        let query = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'readings'")
        let status = sqlite3_step(query)
        sqlite3_finalize(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Error.failed }
        guard status == SQLITE_ROW else { return }

        // Import the actual observations that the old format still has.
        try execute("INSERT OR IGNORE INTO samples (time_ms, bpm) SELECT first_ms, first_bpm FROM readings")
        try execute("INSERT OR IGNORE INTO samples (time_ms, bpm) SELECT last_ms, last_bpm FROM readings")
        try execute("DROP TABLE readings")
    }

    private func migrateReceipts() throws {
        let query = try prepare("PRAGMA user_version")
        let status = sqlite3_step(query)
        let version = sqlite3_column_int(query, 0)
        sqlite3_finalize(query)
        guard status == SQLITE_ROW else { throw Error.failed }
        guard version < 1 else { return }

        // Old receipts could come from a Worker that only stored meeting rows.
        try execute("ALTER TABLE samples ADD COLUMN acknowledged_at_ms INTEGER")
        try execute("UPDATE samples SET acknowledged_revision = 0 WHERE acknowledged_revision <> 0")
        try execute("""
            CREATE INDEX aged_receipts ON samples(acknowledged_at_ms)
            WHERE acknowledged_revision = revision
            """)
        try execute("PRAGMA user_version = 1")
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Error.failed
        }
        return statement
    }

    func bind(_ values: [Int64], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(index + 1), value) == SQLITE_OK else { throw Error.failed }
        }
    }

    func execute(_ sql: String, _ values: [Int64] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw Error.failed }
    }
}
