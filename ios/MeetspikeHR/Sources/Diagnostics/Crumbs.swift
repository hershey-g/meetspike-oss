import Foundation
import MeetspikeHRCore

/// The app's breadcrumb trail for crash reports. Recording hands the line to a serial utility queue, so a crumb never
/// does file work on the caller's thread (the main thread included). The queue keeps the order. The shared core's
/// `CrumbLog` writes each line to its file as it goes, so a kill loses at most what was still waiting in the queue.
///
/// Crumbs are a closed set (`Crumb`): no meeting titles, names, ids, heart rates or URLs can get in. Never record a
/// heart rate or a per-reading event here.
final class Crumbs: @unchecked Sendable {
    static let shared = Crumbs()

    private let queue = DispatchQueue(label: "com.hersheyg.meetspike.hr.crumbs", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var recording = false
    /// Created on the queue, never on the main thread.
    private var log: CrumbLog?
    private var previous: [String]?
    private var waiters: [CheckedContinuation<[String], Never>] = []

    private init() {}

    static func directory() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("MeetspikeDiagnostics/Crumbs", isDirectory: true)
    }

    /// Once per launch, first thing. Takes the previous session's lines (`rotate()`, exactly once), then writes this
    /// launch's first crumb. Demo mode records nothing and has no previous session.
    func start(build: Int, demo: Bool) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        recording = !demo
        lock.unlock()
        if demo {
            fulfill([])
            return
        }
        let now = Date()
        queue.async { [self] in
            let log = openLog()
            let lines = log.rotate()
            log.add(.launch(build: build), at: now)
            fulfill(lines)
        }
    }

    func record(_ crumb: Crumb) {
        let now = Date()
        lock.lock()
        let on = recording
        lock.unlock()
        guard on else { return }
        queue.async { [self] in openLog().add(crumb, at: now) }
    }

    /// The previous session's lines, once `start` has read them. Waits (off the main thread) until then.
    func previousSession() async -> [String] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let previous {
                lock.unlock()
                continuation.resume(returning: previous)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func openLog() -> CrumbLog {
        if let log { return log }
        let made = CrumbLog(directory: Self.directory())
        log = made
        return made
    }

    private func fulfill(_ lines: [String]) {
        lock.lock()
        previous = lines
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: lines) }
    }
}

/// Milliseconds since it was made, for the load crumbs.
struct CrumbTimer {
    private let started = DispatchTime.now().uptimeNanoseconds

    var milliseconds: Int { Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }
}

extension AppTab {
    var crumb: Crumb.Tab {
        switch self {
        case .today: .today
        case .dates: .dates
        case .people: .people
        case .ask: .ask
        case .live: .live
        }
    }
}
