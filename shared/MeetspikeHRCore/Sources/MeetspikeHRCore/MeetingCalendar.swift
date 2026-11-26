#if canImport(EventKit) && canImport(Combine)
import Combine
import EventKit
import Foundation

@MainActor
public final class MeetingCalendar {
    public enum Access: Equatable {
        case notRequested, allowed, denied
    }

    /// What the phone listens to: the calendar's meetings with the person's choices laid over them (left out meetings
    /// dropped, changed times used). With no choices known, or when they cannot be loaded, it is the calendar.
    public private(set) var schedule = MeetingSchedule()
    /// The calendar as EventKit has it. Reminders and the Worker's coverage match keep the original starts.
    public private(set) var calendarSchedule = MeetingSchedule()
    /// The calendar's meetings minus the ones left out, at their original starts. Broadcast reminders use this: the
    /// Worker matches the starts the phone covers on the calendar's own start, and it never reminds for a meeting
    /// that was left out.
    public private(set) var reminderSchedule = MeetingSchedule()
    /// Each phone meeting with the Worker meeting it matched, for "Still going" and "Ended now".
    public private(set) var resolved: [ResolvedMeeting] = []
    private var meetings: [CalendarMeeting] = []
    private var remote: [RemoteMeeting] = []
    public private(set) var access: Access = .notRequested
    /// Apple Calendar calendars on this device (empty until access is allowed).
    public private(set) var calendars: [DeviceCalendar] = []
    /// Which calendars start listening. Every calendar until the person turns some off. Saved on this device.
    public var listening: ListeningCalendarChoice {
        didSet {
            guard listening != oldValue else { return }
            listening.save(to: defaults)
            refresh()
        }
    }
    public var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var eventsObserver: AnyCancellable?
    private var clockObserver: AnyCancellable?
    private var boundary: Task<Void, Never>?
    private var requesting = false
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        listening = ListeningCalendarChoice.load(from: defaults)
        eventsObserver = NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        let notifications = NotificationCenter.default
        clockObserver = notifications.publisher(for: .NSSystemTimeZoneDidChange)
            .merge(with: notifications.publisher(for: .NSSystemClockDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    public func requestAccess() async {
        guard access == .notRequested, !requesting else { return }
        requesting = true
        _ = try? await store.requestFullAccessToEvents()
        requesting = false
        refresh()
    }

    /// The Worker's meetings with their overrides (and edits still waiting to be sent). Nothing depends on this
    /// loading: without it the schedule is the calendar.
    public func setRemote(_ meetings: [RemoteMeeting]) {
        guard meetings != remote else { return }
        remote = meetings
        rebuild()
        scheduleBoundary()
        onChange?()
    }

    private func rebuild() {
        calendarSchedule = MeetingSchedule(meetings)
        resolved = OverrideMatch.resolve(remote, to: calendarSchedule.meetings)
        schedule = MeetingSchedule(resolved.compactMap(\.effective))
        reminderSchedule = MeetingSchedule(resolved.filter { $0.effective != nil }.map(\.original))
    }

    /// Wakes up at the next window edge, or in 6 hours, to read the calendar again.
    private func scheduleBoundary() {
        boundary?.cancel()
        guard access == .allowed else { return }
        let now = Date.now
        let refreshBy = now.addingTimeInterval(6 * 3_600)
        let next = min(schedule.nextBoundary(after: now) ?? refreshBy, refreshBy)
        boundary = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) }
            catch { return }
            self?.refresh()
        }
    }

    public func refresh() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .allowed
        case .notDetermined: access = .notRequested
        default: access = .denied
        }

        let now = Date.now
        if access == .allowed {
            let all = store.calendars(for: .event)
            calendars = all.map(Self.deviceCalendar)
            // Only the calendars chosen to start listening (nil: every calendar, as before the choice existed).
            let chosen: [EKCalendar]?
            switch listening.query(available: all.map(\.calendarIdentifier)) {
            case .all: chosen = nil
            case .some(let ids): chosen = all.filter { ids.contains($0.calendarIdentifier) }
            case .none: chosen = []
            }
            // Include meetings already underway and the previous meeting's cooldown. An empty choice must not
            // reach EventKit, which reads an empty list as every calendar.
            let events = chosen?.isEmpty == true ? [] : store.events(matching: store.predicateForEvents(
                withStart: now.addingTimeInterval(-9 * 3_600),
                end: now.addingTimeInterval(7 * 86_400),
                calendars: chosen
            ))
            meetings = events.compactMap { event in
                guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
                let declined = event.attendees?.contains {
                    $0.isCurrentUser && $0.participantStatus == .declined
                } ?? false
                return CalendarMeeting(title: event.title ?? "", start: start, end: end,
                                       isAllDay: event.isAllDay, isDeclined: declined)
            }
        } else {
            meetings = []
            calendars = []
        }
        rebuild()

        scheduleBoundary()
        onChange?()
    }

    private static func deviceCalendar(_ calendar: EKCalendar) -> DeviceCalendar {
        DeviceCalendar(id: calendar.calendarIdentifier, title: calendar.title,
                       sourceTitle: calendar.source?.title ?? "", colorHex: hex(calendar.cgColor))
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color, let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = rgb.components, parts.count >= 3 else { return nil }
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(parts[0]), byte(parts[1]), byte(parts[2]))
    }
}
#endif
