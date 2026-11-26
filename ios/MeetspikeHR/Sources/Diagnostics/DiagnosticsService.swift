import Foundation
import MeetspikeHRCore
import MetricKit
import SwiftUI
import UIKit

/// The person's choice, per phone. On unless they turned it off.
enum DiagnosticsSettings {
    static let key = "sendCrashReports"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// What the menu shows about reports. Written by the engine, read by the menu.
@MainActor
final class DiagnosticsStatus: ObservableObject {
    static let shared = DiagnosticsStatus()
    /// Reports waiting to be sent.
    @Published var waiting = 0
    /// The line under "Send a test report" after a try.
    @Published var testResult: String?
    @Published var isSendingTest = false
}

/// Subscribes to MetricKit and hands what arrives to `DiagnosticsEngine`. MetricKit calls us on its own background
/// queue; we copy the payloads into plain values there and never touch the main thread.
final class DiagnosticsService: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsService()
    private let engine = DiagnosticsEngine()
    private var started = false

    /// At launch, after `Crumbs.start`. Registering is cheap; everything else runs off the main thread.
    @MainActor
    func start(demo: Bool) {
        guard !started else { return }
        started = true
        // Demo mode (screenshots) never queues and never uploads.
        guard !demo else { return }
        MXMetricManager.shared.add(self)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in Crumbs.shared.record(.memoryWarning) }
        Task.detached(priority: .utility) { [engine] in
            await engine.configure(demo: false)
            // Whatever MetricKit already delivered, once. Stable ids keep it from being queued twice.
            let diagnostics = MXMetricManager.shared.pastDiagnosticPayloads.map(Self.summary)
            let metrics = MXMetricManager.shared.pastPayloads.map(Self.summary)
            // A crash MetricKit delivers live goes first, so its crumbs (the previous session's) are attached before
            // anything older is handled.
            await engine.waitForLiveDelivery()
            await engine.handle(diagnostics: diagnostics, live: false)
            await engine.handle(metrics: metrics)
            await engine.refreshWaiting()
            await engine.upload(.launch)
        }
    }

    func becameActive() {
        Task.detached(priority: .utility) { [engine] in
            await engine.upload(.active)
            await engine.refreshWaiting()
        }
    }

    func refreshWaiting() async { await engine.refreshWaiting() }

    func settingChanged() {
        Task.detached(priority: .utility) { [engine] in await engine.settingChanged() }
    }

    /// Queues a test report and tries it. The line under the button is kept by the engine, so it stays right when the
    /// menu is closed and reopened, and when a later retry sends the report.
    func sendTestReport() async { await engine.sendTest() }

    // MARK: MXMetricManagerSubscriber (background queue)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let summaries = payloads.map(Self.summary)
        Task.detached(priority: .utility) { [engine] in await engine.handle(diagnostics: summaries, live: true) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let summaries = payloads.map(Self.summary)
        Task.detached(priority: .utility) { [engine] in await engine.handle(metrics: summaries) }
    }

    private static func summary(_ payload: MXDiagnosticPayload) -> DiagnosticsEngine.DiagnosticSummary {
        // MetricKit builds and releases the whole call tree here, which can be 300 levels deep. Do it on the big
        // stack, like everything else that touches a report.
        DiagnosticStack.run {
            var items: [DiagnosticsEngine.Item] = []
            func add(_ kind: DiagnosticReport.Kind, _ json: [Data]) {
                for (index, data) in json.enumerated() { items.append(.init(kind: kind, json: data, index: index)) }
            }
            add(.crash, (payload.crashDiagnostics ?? []).map { $0.jsonRepresentation() })
            add(.hang, (payload.hangDiagnostics ?? []).map { $0.jsonRepresentation() })
            add(.cpu, (payload.cpuExceptionDiagnostics ?? []).map { $0.jsonRepresentation() })
            add(.disk, (payload.diskWriteExceptionDiagnostics ?? []).map { $0.jsonRepresentation() })
            return DiagnosticsEngine.DiagnosticSummary(bytes: payload.jsonRepresentation(), at: payload.timeStampEnd, items: items)
        }
    }

    private static func summary(_ payload: MXMetricPayload) -> DiagnosticsEngine.MetricSummary {
        DiagnosticStack.run { .init(bytes: payload.jsonRepresentation(), at: payload.timeStampEnd) }
    }
}

/// Turns payloads into queued reports and uploads them. An actor, so there is one upload pass at a time and all the
/// file work (scrubbing, the queue, the seen ids) runs off the main thread.
actor DiagnosticsEngine {
    struct Item: Sendable {
        let kind: DiagnosticReport.Kind
        let json: Data
        let index: Int
    }

    struct DiagnosticSummary: Sendable {
        let bytes: Data
        let at: Date
        let items: [Item]
    }

    struct MetricSummary: Sendable {
        let bytes: Data
        let at: Date
    }

    enum Trigger { case launch, active, afterAdd }

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MeetspikeDiagnostics", isDirectory: true)
    }

    private let queue = DiagnosticQueue(directory: DiagnosticsEngine.directory.appendingPathComponent("Queue", isDirectory: true))
    private let seen = DiagnosticSeenIDs(file: DiagnosticsEngine.directory.appendingPathComponent("seen-ids.txt"))
    private let attempts = DiagnosticAttempts(file: DiagnosticsEngine.directory.appendingPathComponent("attempts.txt"))
    private let sender = DiagnosticSender()
    private var demo = false
    private var running = false
    private var rerun = false
    private var lastAttempt = Date.distantPast
    private var pass: Task<Void, Never>?
    /// The last "Send a test report" report, the reports the server refused this run, and test reports that could not
    /// be written to the queue. Together with what is still queued they decide the line under the button
    /// (`DiagnosticPolicy.testLine`).
    private var lastTestID: UUID?
    private var refusedIDs: Set<UUID> = []
    private var unsavedIDs: Set<UUID> = []
    /// Test reports the Worker took. A test report that is no longer queued and is not in here was pushed out of a
    /// full queue, not sent.
    private var sentIDs: Set<UUID> = []
    /// A launch and the first "active" come within a second of each other, and a phone with no signal would otherwise
    /// try on every one. After-add tries are not held back.
    private let minimumGap: TimeInterval = 30

    func configure(demo: Bool) { self.demo = demo }

    /// Set once a live delivery has been handled (a crash or not).
    private var liveHandled = false

    /// Gives a live delivery a short head start over the past payloads read at launch. MetricKit sends a live crash
    /// within a moment of subscribing; past payloads wait for it, up to `grace`, and go on without it after that.
    func waitForLiveDelivery(grace: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(grace)
        while !liveHandled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Turning payloads into reports

    /// `live` is true for what MetricKit delivers while the app runs (`didReceive`), false for `pastDiagnosticPayloads`
    /// read at launch.
    func handle(diagnostics payloads: [DiagnosticSummary], live: Bool) async {
        defer { if live { liveHandled = true } }
        guard !demo, !payloads.isEmpty else { return }
        // Crash crumbs are the previous session's, and only mean something for one crash that has just been
        // delivered: with older or several crashes, the session on file may belong to none of them.
        let crashCount = payloads.reduce(0) { $0 + $1.items.filter { $0.kind == .crash }.count }
        let attach = DiagnosticPolicy.attachCrumbs(crashCount: crashCount, live: live)
        let crumbs = attach ? await Crumbs.shared.previousSession() : []
        let running = DeviceInfo.running()
        var added = false
        for payload in payloads {
            for item in payload.items {
                let id = DiagnosticIDs.stable(payload: payload.bytes, kind: item.kind, index: item.index)
                guard !seen.contains(id) else { continue }
                guard DiagnosticPolicy.shouldQueue(enabled: DiagnosticsSettings.enabled, demo: demo) else {
                    _ = seen.insert(id)   // switch off: remember it so the report does not appear later
                    continue
                }
                guard attempts.begin(id) else {
                    _ = seen.insert(id)
                    NSLog("Diagnostics: gave up on payload %@ after it kept failing", id.uuidString)
                    continue
                }
                // Made and saved on the big stack, so the deep report is also released there.
                let saved = DiagnosticStack.run { () -> Bool in
                    let report = DiagnosticReportBuilder.diagnostic(
                        kind: item.kind, json: item.json, id: id, at: payload.at, now: Date(), running: running,
                        crumbs: crumbs)
                    let ok = queue.add(report)
                    return ok
                }
                if saved {
                    _ = seen.insert(id)
                    attempts.finish(id)
                    added = true
                } else {
                    NSLog("Diagnostics: could not save report %@, will try again next launch", id.uuidString)
                    attempts.finish(id)
                }
            }
        }
        await finishAdding(added)
    }

    /// A metric payload becomes at most one `exit` report: the counts are cumulative over its day.
    func handle(metrics payloads: [MetricSummary]) async {
        guard !demo, !payloads.isEmpty else { return }
        let running = DeviceInfo.running()
        var added = false
        for payload in payloads {
            let id = DiagnosticIDs.stable(payload: payload.bytes, kind: .exit, index: 0)
            guard !seen.contains(id) else { continue }
            guard DiagnosticPolicy.shouldQueue(enabled: DiagnosticsSettings.enabled, demo: demo) else {
                _ = seen.insert(id)
                continue
            }
            guard attempts.begin(id) else {
                _ = seen.insert(id)
                continue
            }
            let built = DiagnosticReportBuilder.exits(
                json: payload.bytes, id: id, at: payload.at, now: Date(), running: running)
            guard let report = built else {
                attempts.finish(id)   // nothing abnormal that day: no report, and not remembered
                continue
            }
            if queue.add(report) {
                _ = seen.insert(id)
                attempts.finish(id)
                added = true
            } else {
                NSLog("Diagnostics: could not save report %@, will try again next launch", id.uuidString)
                attempts.finish(id)
            }
        }
        await finishAdding(added)
    }

    private func finishAdding(_ added: Bool) async {
        await refreshWaiting()
        if added { upload(.afterAdd) }
    }

    // MARK: Uploading

    /// One pass at a time. A pass sends oldest first and stops at the first "try later".
    func upload(_ trigger: Trigger) {
        guard let target = target() else { return }
        if running {
            if trigger == .afterAdd { rerun = true }
            return
        }
        if trigger != .afterAdd, Date().timeIntervalSince(lastAttempt) < minimumGap { return }
        running = true
        lastAttempt = Date()
        pass = Task {
            await send(to: target)
            finishPass()
        }
    }

    private func finishPass() {
        running = false
        pass = nil
        if rerun {
            rerun = false
            upload(.afterAdd)
        }
    }

    private func send(to target: (Destination, Credentials)) async {
        let (destination, credentials) = target
        await DiagnosticUploader.send(queue: queue) { report in
            // Switch turned off mid-pass: nothing more goes out.
            if Task.isCancelled || !DiagnosticsSettings.enabled { return .retryLater }
            let outcome = await sender.send(report, to: destination, credentials: credentials)
            if outcome == .sent, report.kind == .test { sentIDs.insert(report.id) }
            if outcome == .reject {
                refusedIDs.insert(report.id)
                NSLog("Diagnostics: the server refused report %@ and it was dropped", report.id.uuidString)
            }
            return outcome
        }
        await refreshWaiting()
    }

    /// The Meetspike URL and secret, when the switch is on and this is a real run. Nil otherwise.
    private func target() -> (Destination, Credentials)? {
        let origin = UserDefaults.standard.string(forKey: "workerOrigin") ?? ""
        let destination = Destination(origin)
        let credentials = try? CredentialStore.load()
        let allowed = DiagnosticPolicy.shouldUpload(
            enabled: DiagnosticsSettings.enabled, demo: demo, hasDestination: destination != nil,
            hasSecret: credentials.map { Credentials.isHeaderValue($0.ingestSecret) } ?? false)
        guard allowed, let destination, let credentials else { return nil }
        return (destination, credentials)
    }

    // MARK: The menu

    func refreshWaiting() async {
        // Ids only: nothing deep is made here, so nothing deep is released on this thread.
        let pending = queue.pendingIDs()
        let line = DiagnosticPolicy.testLine(
            lastTestID: lastTestID, pendingIDs: Set(pending), refusedIDs: refusedIDs, unsavedIDs: unsavedIDs,
            sentIDs: sentIDs)
        await MainActor.run {
            DiagnosticsStatus.shared.waiting = pending.count
            DiagnosticsStatus.shared.testResult = line.text
        }
    }

    /// The switch moved. Off: stop what is uploading and drop what was waiting, because the person said no. On: try
    /// whatever is queued (nothing, unless it was queued since).
    func settingChanged() async {
        if DiagnosticsSettings.enabled {
            upload(.afterAdd)
        } else {
            pass?.cancel()
            for id in queue.pendingIDs() { queue.remove(id: id) }
            // Dropped, not sent: the test report's line goes with it.
            lastTestID = nil
        }
        await refreshWaiting()
    }

    /// "Send a test report": queue one and run a pass now. The line under the button comes from `refreshWaiting`, so a
    /// report that stays queued reads "Not sent yet" and turns into "Sent." when a later pass sends it. One the server
    /// refuses reads "Not sent. Your server refused it.", and one that could not be saved reads "Couldn't save the
    /// report.". Does nothing when it is not allowed.
    func sendTest() async {
        guard !demo, DiagnosticsSettings.enabled else { return }
        let report = DiagnosticReportBuilder.test(id: UUID(), at: Date(), running: DeviceInfo.running())
        lastTestID = report.id
        // Could not be written to the queue: it is not "sent", so say so rather than leave it looking sent.
        if !queue.add(report) { unsavedIDs.insert(report.id) }
        await refreshWaiting()
        if let pass { await pass.value }
        upload(.afterAdd)
        if let pass { await pass.value }
        await refreshWaiting()
    }
}

/// What this running copy of the app knows about itself, for reports that do not say.
enum DeviceInfo {
    static func running() -> DiagnosticReportBuilder.Running {
        let info = Bundle.main.infoDictionary
        let build = Int((info?["CFBundleVersion"] as? String) ?? "") ?? 0
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var os = "iPhone OS \(system.majorVersion).\(system.minorVersion)"
        if system.patchVersion > 0 { os += ".\(system.patchVersion)" }
        if let osBuild = sysctlString("kern.osversion") { os += " (\(osBuild))" }
        return .init(build: build, version: version, os: os, device: sysctlString("hw.machine") ?? "iPhone")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
