import AppKit
import Combine
import EventKit
import Foundation
import MeetspikeHRCore
import os

/// Sends the Worker what this Mac saw of a Zoom meeting: POST /api/whoop-web/app/attendance, with the same headers
/// as the Mac's other Worker calls (the saved ingest secret, plus the Access service token when one is saved).
struct AttendanceClient {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// The HTTP status, or nil when there was no answer.
    func send(_ body: Data, to destination: Destination, credentials: Credentials) async -> Int? {
        guard var parts = URLComponents(url: destination.origin, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/api/whoop-web/app/attendance"
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.ingestSecret)", forHTTPHeaderField: "Authorization")
        if let id = credentials.accessID, let secret = credentials.accessSecret,
           Credentials.isHeaderValue(id), Credentials.isHeaderValue(secret) {
            request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        request.httpBody = body
        // `NoRedirects` hands the 3xx itself back (no error), so an Access redirect to its login page is a 302 here and
        // is kept for later. It is never followed into a 200 login page that would count as delivered.
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}

/// Watches for Zoom all day, whether or not the Mac is recording, and tells the Worker which meetings it saw.
///
/// Every 15 s (the loop in `Logger`) it asks whether a Zoom call is open (the CptHost process, the same check the
/// broadcast reminder uses) and hands that, with whether the Mac is awake and today's calendar meetings, to the shared
/// `AttendanceTracker`. Awake means not asleep, display not asleep, not locked and on the console. Any change of that
/// takes a sample right away, so a short sleep or lock can never look like time spent watching.
///
/// Nothing is kept across a quit. A new run has no memory of the start of a call or of the time before it, so the
/// tracker cannot call a meeting "never joined" (it needs 90 % of the time watched), and `AttendanceContinuity` drops a
/// report whose first sighting began in the middle of a call. A report is therefore always something the Mac watched.
///
/// Titles go in the report body only (the Worker uses them to break a tie). Nothing here logs a title or a secret.
@MainActor
final class AttendanceWatcher {
    private static let log = os.Logger(subsystem: "com.meetspike.hr", category: "attendance")

    private var tracker = AttendanceTracker()
    private var continuity = AttendanceContinuity()
    private var meetings: [TrackedMeeting] = []
    private var meetingsLoadedAt = Date.distantPast
    private var meetingsDirty = true
    private let store = EKEventStore()
    private let queue: AttendanceQueue
    private let client = AttendanceClient()
    private var sending = false
    private var observers: Set<AnyCancellable> = []

    private var systemAsleep = false
    private var displayAsleep = false
    private var screenLocked = false
    private var sessionResigned = false

    init(queue: AttendanceQueue = AttendanceWatcher.defaultQueue) {
        self.queue = queue
    }

    nonisolated static var defaultQueue: AttendanceQueue {
        AttendanceQueue(
            file: URL.applicationSupportDirectory.appendingPathComponent("MeetspikeHR", isDirectory: true)
                .appendingPathComponent("Attendance", isDirectory: true)
                .appendingPathComponent("queue.json", isDirectory: false))
    }

    /// Starts listening for sleep, wake, lock and calendar changes. Safe to call once.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, on center: NotificationCenter, _ change: @escaping (AttendanceWatcher) -> Void) {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    change(self)
                    self.sample()
                }
                .store(in: &observers)
        }
        watch(NSWorkspace.willSleepNotification, on: workspace) { $0.systemAsleep = true }
        watch(NSWorkspace.didWakeNotification, on: workspace) { $0.systemAsleep = false }
        watch(NSWorkspace.screensDidSleepNotification, on: workspace) { $0.displayAsleep = true }
        watch(NSWorkspace.screensDidWakeNotification, on: workspace) { $0.displayAsleep = false }
        watch(NSWorkspace.sessionDidResignActiveNotification, on: workspace) { $0.sessionResigned = true }
        watch(NSWorkspace.sessionDidBecomeActiveNotification, on: workspace) { $0.sessionResigned = false }
        let distributed = DistributedNotificationCenter.default()
        watch(Notification.Name("com.apple.screenIsLocked"), on: distributed) { $0.screenLocked = true }
        watch(Notification.Name("com.apple.screenIsUnlocked"), on: distributed) { $0.screenLocked = false }
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.meetingsDirty = true }
            .store(in: &observers)
    }

    /// Awake: nothing has put the Mac, the display or the session to sleep, and the screen is not locked. The
    /// session dictionary is asked as well, so a lock that happened before the app started still counts.
    var isAwake: Bool {
        !systemAsleep && !displayAsleep && !screenLocked && !sessionResigned && Self.sessionIsActive()
    }

    private static func sessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return false }
        if (session["kCGSSessionOnConsoleKey"] as? Bool) == false { return false }
        return true
    }

    /// One sample. Called from the 15 s loop and on every change of the Mac's awake state.
    func sample(now: Date = .now) {
        let awake = isAwake
        loadMeetingsIfNeeded(now: now)
        // Asleep or locked means Zoom is not "seen", whatever the process list says.
        let zoom = awake && ZoomMeeting.isActive()
        continuity.note(now: now, zoomRunning: zoom, awake: awake, meetings: meetings)
        let reports = tracker.observe(now: now, zoomRunning: zoom, awake: awake, meetings: meetings)
        for report in reports { enqueue(report, now: now) }
        flushIfDue(now: now)
    }

    // MARK: Reports

    private func enqueue(_ report: AttendanceReport, now: Date) {
        guard continuity.isReliable(report) else {
            Self.log.notice("Attendance report dropped: the Mac was not watching when the call began")
            return
        }
        var body = report
        // The Worker's body limit is 4 KB. A title is only a tie-breaker.
        body.title = String(report.title.prefix(1_000))
        guard let data = try? JSONEncoder().encode(body) else {
            Self.log.error("Attendance report could not be encoded")
            return
        }
        let key = AttendanceContinuity.key(id: report.id, start: report.meetingStart)
        if queue.enqueue(key: key, body: data, at: now) {
            Self.log.notice("Attendance report queued (seenNone=\(report.seenNone, privacy: .public))")
        } else {
            Self.log.error("Attendance report could not be saved to the queue")
        }
    }

    private func flushIfDue(now: Date) {
        guard !sending else { return }
        queue.expire(at: now)
        let due = queue.due(at: now)
        guard !due.isEmpty else { return }
        guard let destination = Destination(UserDefaults.standard.string(forKey: "workerOrigin") ?? ""),
              let credentials = try? CredentialStore.load(), Credentials.isHeaderValue(credentials.ingestSecret) else {
            // Not set up yet. The reports wait (they expire after three days).
            return
        }
        sending = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.sending = false }
            for (index, entry) in due.enumerated() {
                let status = await self.client.send(entry.body, to: destination, credentials: credentials)
                let verdict = AttendanceReportDelivery.verdict(status: status)
                self.queue.settle(entry, verdict, at: .now)
                Self.log.notice("Attendance report: \(String(describing: verdict), privacy: .public) (status \(status ?? 0, privacy: .public))")
                if verdict == .later {
                    // 401, 403, a redirect to a login page or 503 is about the setup, not this one report. The rest
                    // wait the same time, so a full queue does not try the Worker every 15 s one report at a time.
                    for rest in due.dropFirst(index + 1) { self.queue.settle(rest, .later, at: .now) }
                    break
                }
                // One failure that is not about this report (no answer) stops the pass.
                if verdict == .retry { break }
            }
        }
    }

    // MARK: Calendar

    /// Meetings from 13 h back (an 8 h meeting plus its 4 h tail) to a day ahead, read at most every two minutes.
    private func loadMeetingsIfNeeded(now: Date) {
        guard meetingsDirty || now.timeIntervalSince(meetingsLoadedAt) > 120 else { return }
        meetingsDirty = false
        meetingsLoadedAt = now
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            meetings = []
            return
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-13 * 3_600), end: now.addingTimeInterval(24 * 3_600), calendars: nil)
        meetings = store.events(matching: predicate).compactMap(Self.tracked)
    }

    private static func tracked(_ event: EKEvent) -> TrackedMeeting? {
        guard event.status != .canceled, !event.isAllDay, let start = event.startDate, let end = event.endDate,
              end > start else { return nil }
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        if declined { return nil }
        let texts = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return TrackedMeeting(
            // One id per occurrence: a repeating meeting shares its identifier.
            id: "\(identifier)@\(Int(start.timeIntervalSince1970))", title: event.title ?? "", start: start, end: end,
            hasZoom: texts.contains { ZoomLink.isZoom(text: $0) })
    }
}
