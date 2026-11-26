import Foundation
import MeetspikeHRCore

/// Pure pieces of the Mac's Zoom attendance reporting. No AppKit, no network, so the rules read on their own.

/// Catches the one thing the shared tracker cannot know: that the Mac was not watching when a call began. After a
/// quit, a relaunch, a sleep or a lock the tracker has no memory of the start, so its first sighting would be the
/// moment the Mac looked again, not the moment the person joined. A report built on that would move the meeting's
/// start. Nothing is better than that, so a meeting whose first sighting began in the middle of a call (Zoom already
/// running at the first awake, steady sample after the start) gets no report.
///
/// `seenNone` is never affected: the tracker already needs 90 % watched time for it, and a relaunch loses that.
struct AttendanceContinuity {
    private struct Previous {
        var time: Date
        var awake: Bool
        var zoom: Bool
    }

    /// The tracker counts sightings from 15 minutes before the start.
    static let lead: TimeInterval = 15 * 60
    static let maxGap: TimeInterval = 60

    private var previous: Previous?
    private var checked: Set<String> = []
    private var midCall: Set<String> = []

    static func key(id: String, start: Date) -> String { "\(id)|\(start.timeIntervalSince1970)" }

    /// Call with every sample, the same values the tracker gets.
    mutating func note(now: Date, zoomRunning: Bool, awake: Bool, meetings: [TrackedMeeting]) {
        let zoom = zoomRunning && awake
        defer { previous = Previous(time: now, awake: awake, zoom: zoom) }
        guard zoom else { return }
        // The sample before this one saw an awake Mac with Zoom closed, close enough in time: a join we watched.
        let sawItOpen = previous.map {
            $0.time < now && now.timeIntervalSince($0.time) <= Self.maxGap && $0.awake && !$0.zoom
        } ?? false
        for meeting in meetings where meeting.hasZoom {
            let key = Self.key(id: meeting.id, start: meeting.start)
            guard !checked.contains(key), now >= meeting.start.addingTimeInterval(-Self.lead), now <= meeting.end else { continue }
            checked.insert(key)
            if !sawItOpen, now > meeting.start { midCall.insert(key) }
        }
        if checked.count > 400 {
            // Long gone meetings are not needed. Keeping the newest is enough for a day of meetings.
            let keep = now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970
            checked = checked.filter { Self.startOf($0).map { $0 > keep } ?? true }
            midCall = midCall.filter { Self.startOf($0).map { $0 > keep } ?? true }
        }
    }

    /// False for a report whose sighting began mid-call. A report that says nobody was seen is always fine.
    func isReliable(_ report: AttendanceReport) -> Bool {
        if report.seenNone { return true }
        return !midCall.contains(Self.key(id: report.id, start: report.meetingStart))
    }

    private static func startOf(_ key: String) -> Double? {
        key.split(separator: "|").last.flatMap { Double($0) }
    }
}

/// Reports waiting to be sent, in one small file, so a failure or a quit loses nothing. One entry per meeting (a
/// newer report for the same meeting replaces it). Never throws: a file that cannot be written makes `enqueue` answer
/// false, a file that cannot be read is an empty queue. The file holds the report bodies, so it lives in the app's own
/// folder and nothing from it goes to a log.
struct AttendanceQueue {
    struct Entry: Codable, Equatable {
        var key: String
        var body: Data
        var queuedAt: Date
        var attempts: Int
        var notBefore: Date
    }

        let file: URL

    init(file: URL) {
        self.file = file
    }

    func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return list
    }

    @discardableResult
    func enqueue(key: String, body: Data, at now: Date) -> Bool {
        var list = entries().filter { $0.key != key }
        list.append(Entry(key: key, body: body, queuedAt: now, attempts: 0, notBefore: now))
        // Reports kept for later (401, 403, a redirect, 503) count toward the shared limit too.
        if list.count > AttendanceReportDelivery.queueCap { list = Array(list.suffix(AttendanceReportDelivery.queueCap)) }
        return write(list)
    }

    /// Entries ready to send now, oldest first.
    func due(at now: Date) -> [Entry] {
        entries().filter { $0.notBefore <= now }.sorted { ($0.queuedAt, $0.key) < ($1.queuedAt, $1.key) }
    }

    /// Applies what the Worker said to one entry. Returns false only when the queue could not be written.
    @discardableResult
    func settle(_ entry: Entry, _ verdict: AttendanceReportDelivery.Verdict, at now: Date) -> Bool {
        var list = entries()
        guard let index = list.firstIndex(where: { $0.key == entry.key }) else { return true }
        // A newer report replaced this one while it was in flight: leave the newer one alone.
        guard list[index].body == entry.body else { return true }
        switch verdict {
        case .done, .drop:
            list.remove(at: index)
        case .retry:
            list[index].attempts += 1
            if list[index].attempts >= AttendanceReportDelivery.maxAttempts {
                list.remove(at: index)
            } else {
                let steps = AttendanceReportDelivery.backoff
                list[index].notBefore = now.addingTimeInterval(steps[min(list[index].attempts - 1, steps.count - 1)])
            }
        case .later:
            list[index].notBefore = now.addingTimeInterval(AttendanceReportDelivery.laterDelay)
        }
        return write(list)
    }

    /// Drops what has waited too long. Returns how many.
    @discardableResult
    func expire(at now: Date) -> Int {
        let list = entries()
        let kept = list.filter { now.timeIntervalSince($0.queuedAt) <= AttendanceReportDelivery.maxAge }
        guard kept.count != list.count else { return 0 }
        write(kept)
        return list.count - kept.count
    }

    @discardableResult
    private func write(_ list: [Entry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
