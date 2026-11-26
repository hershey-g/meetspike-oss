#if canImport(Combine) && canImport(Security)
import Combine
import Foundation

@MainActor
public final class ReplaySync: ObservableObject {
    @Published public private(set) var lastUpload: Date?
    @Published public private(set) var lastSuccessfulUpload: Date?
    @Published public private(set) var result = "No replay attempts"
    @Published public private(set) var failed = false

    public var canUpload: (() -> Bool)?
    private let uploader: Uploader
    private let store: ReadingStore
    private var schedule = UploadSchedule(now: .now)
    private var task: Task<Void, Never>?
    private var origin = ""
    private var running = false
    private var attemptedClosing: Date?

    public init(uploader: Uploader, store: ReadingStore, origin: String) {
        self.uploader = uploader
        self.store = store
        self.origin = origin
    }

    public func configure(origin: String) {
        task?.cancel()
        self.origin = origin
        result = "Settings saved"
        failed = false
        uploadSoon()
    }

    public func setRunning(_ running: Bool) {
        guard self.running != running else { return }
        self.running = running
        if !running {
            task?.cancel()
            if result == "Uploading" { result = "Replay paused" }
        }
    }

    public func uploadSoon() {
        schedule = UploadSchedule(now: Date.now.addingTimeInterval(-UploadSchedule.interval))
    }

    public func tick(now: Date, closingAt: Date?) {
        guard running, (canUpload?() ?? true), task == nil else { return }
        // Give a short block's completed meeting a replay before leaving live mode.
        let closing = closingAt.flatMap { end in
            end != attemptedClosing && end > now && end.timeIntervalSince(now) <= 30 ? end : nil
        }
        guard now >= schedule.nextAttempt || closing != nil else { return }
        if let closing { attemptedClosing = closing }
        task = Task {
            let execution = UploadExecution { [weak self] in self?.task?.cancel() }
            defer {
                execution.finish()
                task = nil
            }
            let success = await upload()
            if !Task.isCancelled {
                schedule.complete(success: success, now: .now)
                failed = !success
            }
        }
    }

    enum Failure: Error {
        case settings(String)
        case request(String)
    }

    private func upload() async -> Bool {
        do {
            // Send pending readings oldest first. Each batch stays pending
            // until the Worker confirms raw storage.
            let through = Date.now
            var settings: (Destination, Credentials)?
            while true {
                try checkRunning()
                guard let batch = try await store.prepare(through: through) else { break }
                try checkRunning()
                if settings == nil { settings = try uploadSettings() }
                guard let (destination, credentials) = settings else { return false }
                try await post(batch, destination: destination, credentials: credentials)
            }
            try checkRunning()
            if settings != nil {
                result = "Uploaded"
                lastSuccessfulUpload = .now
            }
            return true
        } catch is CancellationError {
            if result == "Uploading" { result = "Replay paused" }
            return false
        } catch Failure.settings(let message) {
            result = message
            return false
        } catch Failure.request(let message) {
            if !Task.isCancelled { result = message }
            return false
        } catch {
            if !Task.isCancelled { result = "Could not prepare local readings. Will retry." }
            return false
        }
    }

    private func checkRunning() throws {
        try Task.checkCancellation()
        guard running, (canUpload?() ?? true) else { throw CancellationError() }
    }

    private func uploadSettings() throws -> (Destination, Credentials) {
        guard let destination = Destination(origin) else {
            throw Failure.settings("Set the Meetspike URL in Settings")
        }
        let saved: Credentials?
        do { saved = try CredentialStore.load() }
        catch { throw Failure.settings("Could not read Keychain") }
        guard let saved, Credentials.isHeaderValue(saved.ingestSecret) else {
            throw Failure.settings("Set the ingest secret in Settings")
        }
        return (destination, saved)
    }

    private func post(
        _ batch: UploadBatch, destination: Destination, credentials: Credentials
    ) async throws {
        result = "Uploading"
        lastUpload = .now
        try await Self.send(
            { try await self.uploader.post(batch.body, to: destination, credentials: credentials) },
            acknowledge: { try await self.store.acknowledge(batch, httpStatus: $0) }
        )
    }

    /// Post, then acknowledge a confirmed upload before honoring cancellation:
    /// the Worker already stored the batch, so dropping the receipt would only
    /// upload it again.
    static func send(
        _ post: () async throws -> Int?, acknowledge: (Int) async throws -> Void
    ) async throws {
        let status: Int?
        do { status = try await post() }
        catch IngestUploadError.missingReceipt { throw Failure.request("Worker did not confirm raw storage. Will retry.") }
        catch { throw Failure.request("Upload failed. Will retry.") }
        guard let status else { throw Failure.request("Invalid HTTP response. Will retry.") }
        guard status == 200 else { throw Failure.request("HTTP \(status). Will retry.") }
        do { try await acknowledge(status) }
        catch { throw Failure.request("Could not save upload receipt. Will retry.") }
        try Task.checkCancellation()
    }
}
#endif
