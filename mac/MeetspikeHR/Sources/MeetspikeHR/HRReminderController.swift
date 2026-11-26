import Darwin
import Foundation
import MeetspikeHRCore
import UserNotifications

/// Reminds to turn on HR Broadcast in the WHOOP app when a meeting is starting
/// and no Bluetooth reading has arrived for a minute: a macOS notification
/// with sound, and a Pushover push through the Worker when it is configured.
/// HRReminderPolicy decides when (two minutes before, one follow-up if no
/// heart rate in the meeting's first minute). The Mac stays quiet only about a
/// meeting the Worker says the iPhone app scheduled a reminder for, decided
/// per lookup, so anything the phone does not have still gets a reminder.
/// The same lookup says whether the Worker sees heart rate coming in from any
/// device (the iPhone, say), and then the Mac does not alert either.
@MainActor
final class HRReminderController {
    static let enabledKey = "hrReminderEnabled"
    static let pushoverKey = "hrReminderPushover"
    private static let phoneOwnsUntilKey = "hrReminderPhoneOwnsUntil"

    private let uploader: Uploader
    private var policy = HRReminderPolicy()
    private var meeting: ReminderMeeting?
    /// From the same lookup as `meeting`: the phone reminds about it.
    private var phoneOwnsMeeting = false
    /// When the Worker last said heart rate was coming in from some device. Nil when it said no, could not check, or
    /// is an older Worker without the field.
    private var serverLiveAt: Date?
    private var nextLookup = Date.distantPast
    private var lookupTask: Task<Void, Never>?
    /// One permission request that every notification waits on, so a
    /// second notification can't be added while the first prompt is open.
    private var authorization: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    /// The iPhone has a fresh check-in, for the Settings note only. It never
    /// silences the Mac on its own; suppression follows `phoneOwnsMeeting`.
    var phoneOwnsReminders: Bool {
        (defaults.object(forKey: Self.phoneOwnsUntilKey) as? Date).map { $0 > .now } ?? false
    }

    init(uploader: Uploader) {
        self.uploader = uploader
        UserDefaults.standard.register(defaults: [Self.enabledKey: true, Self.pushoverKey: true])
    }

    /// Called every few seconds while recording is running.
    /// `meetingOnlyMeetings` is the calendar's meetings while capture follows them (meeting-only, not Go live now),
    /// nil otherwise. In the five minutes before a meeting the Mac already listens but does not remind until two
    /// minutes before, so a Zoom opened early is not reminded as its own meeting.
    func tick(now: Date, lastReadingAt: Date?, origin: String, meetingOnlyMeetings: [CalendarMeeting]? = nil) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        if let meetingOnlyMeetings, HRReminderPolicy.tooEarly(now: now, meetings: meetingOnlyMeetings) { return }
        let silent = HRReminderPolicy.heartRateSilent(lastReadingAt: lastReadingAt, now: now)
        if silent { lookUpMeeting(now: now, origin: origin) } else { clearMeeting() }
        // Wait for a lookup in flight, so a Zoom call the phone covers on the
        // calendar is not reminded before the Worker answers.
        guard lookupTask == nil else { return }
        let alert = policy.evaluate(
            now: now, lastReadingAt: HRReminderPolicy.effectiveLastReading(local: lastReadingAt, serverLiveAt: serverLiveAt),
            zoomActive: ZoomMeeting.isActive(), meeting: meeting
        )
        // The policy still records the alert so the Mac never reminds late
        // about a meeting the phone already covered.
        if let alert, !phoneOwnsMeeting { deliver(alert, origin: origin) }
    }

    func reset() {
        lookupTask?.cancel()
        lookupTask = nil
        clearMeeting()
        nextLookup = .distantPast
    }

    private func clearMeeting() {
        meeting = nil
        phoneOwnsMeeting = false
        serverLiveAt = nil
    }

    private func lookUpMeeting(now: Date, origin: String) {
        guard lookupTask == nil, now >= nextLookup, let destination = Destination(origin) else { return }
        nextLookup = now.addingTimeInterval(HRReminderPolicy.lookupInterval)
        lookupTask = Task {
            defer { lookupTask = nil }
            guard let credentials = try? CredentialStore.load(), Credentials.isHeaderValue(credentials.ingestSecret),
                  let reply = try? await uploader.reminderLookup(to: destination, credentials: credentials),
                  !Task.isCancelled else { return }
            meeting = reply.meeting
            phoneOwnsMeeting = reply.phoneOwnsMeeting(at: .now)
            // The Worker looked at the last minute of heart rate from every device. Anything but true is as before.
            serverLiveAt = reply.live == true ? .now : nil
            if reply.phoneCheckedIn(at: .now), let until = reply.ownerUntil {
                defaults.set(until, forKey: Self.phoneOwnsUntilKey)
            } else {
                defaults.removeObject(forKey: Self.phoneOwnsUntilKey)
            }
        }
    }

    private func deliver(_ alert: HRReminderAlert, origin: String) {
        notify(alert)
        guard UserDefaults.standard.bool(forKey: Self.pushoverKey), let destination = Destination(origin) else { return }
        Task {
            guard let credentials = try? CredentialStore.load(), Credentials.isHeaderValue(credentials.ingestSecret) else { return }
            // The Worker answers not_configured when PUSHOVER_TOKEN / PUSHOVER_USER are unset.
            _ = try? await uploader.postReminder(alert, to: destination, credentials: credentials)
        }
    }

    /// Tells the user Pause was lifted because a meeting started.
    func notifyResumed(meetingTitle: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meetspike resumed for \(meetingTitle)"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        post(UNNotificationRequest(identifier: "pause-resumed-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func notify(_ alert: HRReminderAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.heading
        content.body = alert.message
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        post(UNNotificationRequest(identifier: "hr-reminder-\(alert.key)", content: content, trigger: nil))
    }

    private func post(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        let authorization = self.authorization ?? Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        self.authorization = authorization
        Task {
            await authorization.value
            try? await center.add(request)
        }
    }
}

/// Zoom runs its meeting window in a helper process named CptHost, present
/// only while a meeting is open.
enum ZoomMeeting {
    static func isActive() -> Bool { processRunning(named: "CptHost") }

    static func processRunning(named name: String) -> Bool {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == name { return true }
        }
        return false
    }
}
