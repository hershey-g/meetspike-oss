#if canImport(Combine) && canImport(Security)
import Combine
import Foundation

@MainActor
public final class LiveSync: ObservableObject {
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var meeting: LiveMeeting?
    @Published public private(set) var status = "Waiting for readings"

    private let uploader: Uploader
    private var queue = LiveUploadQueue()
    private var task: Task<Void, Never>?
    private var credentials: Credentials?
    private var nextAttempt = Date.distantPast
    private var nextMeetingLookup = Date.distantPast
    private var retryDelay: TimeInterval = 5
    private var running = false
    private var origin = ""
    public var canUpload: (() -> Bool)?

    public init(uploader: Uploader) {
        self.uploader = uploader
    }

    public func configure(origin: String) {
        if !self.origin.isEmpty, self.origin != origin { queue = LiveUploadQueue() }
        self.origin = origin
        credentials = nil
        lastSync = nil
        meeting = nil
        nextMeetingLookup = .distantPast
        resetAttempt()
    }

    public func setRunning(_ running: Bool) {
        guard self.running != running else { return }
        self.running = running
        resetAttempt()
        if !running {
            meeting = nil
            nextMeetingLookup = .distantPast
            status = "Live sync paused"
        }
    }

    public func record(bpm: Int, at date: Date) {
        guard running, (25...250).contains(bpm) else { return }
        queue.record(HeartRatePoint(bpm: bpm, at: date))
    }

    public func tick(now: Date) {
        if let meeting, now >= meeting.paddedEnd { self.meeting = nil }
        guard running, (canUpload?() ?? true), task == nil, now >= nextAttempt else { return }
        let points = queue.batch(now: now)
        guard !points.isEmpty else { return }
        nextAttempt = now.addingTimeInterval(5)
        guard let destination = Destination(origin) else {
            status = "Set up live sync in Settings"
            return
        }
        let includeMeeting = now >= nextMeetingLookup
        task = Task {
            let execution = UploadExecution { [weak self] in self?.task?.cancel() }
            defer {
                execution.finish()
                task = nil
            }
            do {
                try Task.checkCancellation()
                guard canUpload?() ?? true else { return }
                if credentials == nil { credentials = try CredentialStore.load() }
                guard let credentials, Credentials.isHeaderValue(credentials.ingestSecret) else {
                    retry(status: "Set the ingest secret in Settings")
                    return
                }
                let response = try await uploader.postLive(points, includeMeeting: includeMeeting, to: destination, credentials: credentials)
                try Task.checkCancellation()
                queue.acknowledge(points)
                lastSync = .now
                retryDelay = 5
                status = "Live syncing"
                if response.hasMeeting {
                    meeting = response.meeting
                    nextMeetingLookup = Date.now.addingTimeInterval(30)
                }
            } catch LiveUploadError.http(let code) {
                guard !Task.isCancelled else { return }
                retry(status: "Live sync retrying · HTTP \(code)")
            } catch {
                guard !Task.isCancelled else { return }
                retry(status: "Live sync retrying")
            }
        }
    }

    private func resetAttempt() {
        task?.cancel()
        nextAttempt = .distantPast
        retryDelay = 5
        status = "Waiting for readings"
    }

    private func retry(status: String) {
        self.status = status
        nextAttempt = Date.now.addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 60)
    }
}
#endif
