import Foundation
import MeetspikeHRCore

/// What the phone remembers about meeting choices, on disk, so listening follows them with no network and at a
/// background launch (Bluetooth restoration) before any screen exists. Two things live here: the Worker's meetings
/// with their overrides as last seen, and the outbox of edits not yet sent. Nothing depends on this loading: with
/// nothing saved, or a file that cannot be read, the phone listens to the calendar.
enum ListeningOverrides {
    private static let lock = NSLock()

    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MeetspikeHR", isDirectory: true)
            .appendingPathComponent("Overrides", isDirectory: true)
    }

    /// Edits waiting to be sent. One per meeting and scope (a newer edit is merged into it), survives a relaunch.
    static var outbox: OverrideOutbox {
        OverrideOutbox(directory: directory.appendingPathComponent("Outbox", isDirectory: true))
    }

    private static var file: URL { directory.appendingPathComponent("remote-meetings.json", isDirectory: false) }

    /// The Worker's meetings as last seen. Empty when nothing was saved or it cannot be read.
    static func stored() -> [RemoteMeeting] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let meetings = try? JSONDecoder().decode([RemoteMeeting].self, from: data) else { return [] }
        return meetings
    }

    /// What listening uses: the saved Worker meetings with the waiting edits laid over them.
    static func current() -> [RemoteMeeting] {
        OverrideOverlay.apply(outbox.pending(), to: stored())
    }

    /// Remembers the meetings of a day the Worker just described, replacing earlier copies of the same meetings and
    /// dropping the ones long past. Returns false when it could not be saved (the old copy stays).
    @discardableResult
    static func remember(_ events: [Meeting], now: Date = .now) -> Bool {
        let fresh = remoteMeetings(from: events)
        lock.lock()
        defer { lock.unlock() }
        let old = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([RemoteMeeting].self, from: $0) } ?? []
        let ids = Set(fresh.map(\.id))
        let kept = old.filter {
            !ids.contains($0.id) && $0.calendarEnd > now.addingTimeInterval(-36 * 3_600)
                && $0.calendarStart < now.addingTimeInterval(10 * 86_400)
        }
        let all = (kept + fresh).sorted { ($0.calendarStart, $0.id) < ($1.calendarStart, $1.id) }
        guard all != old else { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Calendar meetings only: a recording of a meeting is another row with the same title and start, and would make
    /// the match look ambiguous.
    static func remoteMeetings(from events: [Meeting]) -> [RemoteMeeting] {
        events.compactMap { event in
            if let source = event.sourceType, !source.isEmpty, source != "calendar" { return nil }
            let override = event.override
            guard let start = override?.calendarStartUtc ?? APITime.parse(event.startUtc),
                  let end = override?.calendarEndUtc ?? APITime.parse(event.endUtc), end > start else { return nil }
            return RemoteMeeting(id: event.id, title: event.title ?? "", calendarStart: start, calendarEnd: end, override: override)
        }
    }
}
