import Foundation

/// What the Bluetooth reader is doing. The app target maps CoreBluetooth
/// callbacks onto these; everything that turns them into words lives here so
/// it can be tested without a Mac.
public enum BluetoothStatus: String, Sendable {
    case starting = "Starting Bluetooth"
    case searching = "Looking for WHOOP"
    case reconnecting = "Waiting to reconnect"
    case poweredOff = "Bluetooth is off"
    case unauthorized = "Bluetooth permission required"
    case unsupported = "Bluetooth is unavailable"
    case waiting = "Waiting for Bluetooth"
    case connecting = "Connecting to WHOOP"
    case connected = "Connected to WHOOP"
    case paused = "Paused"
    case sleeping = "Sleeping"
    case outsideMeeting = "Outside meeting hours"
}

/// The macOS Bluetooth privacy decision for this app.
public enum BluetoothPermission: Sendable, Equatable {
    case notDetermined
    case allowed
    case denied
}

/// Links into System Settings that the menu and walkthrough offer.
public enum SystemSettingsLink: String, Sendable, CaseIterable {
    case bluetoothPrivacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
    case bluetooth = "x-apple.systempreferences:com.apple.BluetoothSettings"
    case calendarPrivacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    public var url: URL { URL(string: rawValue)! }
}

/// What one scan has heard. The scan filters on the standard Heart Rate
/// Service, so every peripheral counted here is a heart rate broadcaster.
public struct ScanDiagnostics: Sendable, Equatable {
    /// How long a scan may run without hearing a WHOOP before the status says so.
    public static let noWhoopAfter: TimeInterval = 20

    public private(set) var startedAt: Date?
    public private(set) var heartRateBroadcasters: Set<UUID> = []
    public private(set) var whoopBroadcasters: Set<UUID> = []
    /// WHOOP broadcasters that were not the remembered strap.
    public private(set) var otherWhoops: Set<UUID> = []
    /// Every heart rate broadcaster heard, in the order first heard.
    public private(set) var broadcasters: [Broadcaster] = []

    public struct Broadcaster: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var advertisement: Advertisement
        public var accepted: Bool
    }

    public init() {}

    public mutating func begin(at date: Date) {
        self = ScanDiagnostics()
        startedAt = date
    }

    /// Records one discovery. Returns true when anything shown changed.
    @discardableResult
    public mutating func record(id: UUID, advertisement: Advertisement, accepted: Bool) -> Bool {
        let before = self
        heartRateBroadcasters.insert(id)
        if let index = broadcasters.firstIndex(where: { $0.id == id }) {
            broadcasters[index].advertisement = broadcasters[index].advertisement.merged(with: advertisement)
            broadcasters[index].accepted = broadcasters[index].accepted || accepted
        } else {
            broadcasters.append(Broadcaster(id: id, advertisement: advertisement, accepted: accepted))
        }
        let heard = broadcasters.first { $0.id == id }!
        if heard.accepted || StrapMatch.isWhoop(heard.advertisement) {
            whoopBroadcasters.insert(id)
            if heard.accepted { otherWhoops.remove(id) } else { otherWhoops.insert(id) }
        }
        return before != self
    }

    /// Convenience for a discovery that only has names.
    @discardableResult
    public mutating func record(id: UUID, names: [String], accepted: Bool) -> Bool {
        record(
            id: id, advertisement: Advertisement(localName: names.first, peripheralName: names.dropFirst().first),
            accepted: accepted
        )
    }

    /// One line per broadcaster: name, manufacturer data, and services.
    public var broadcasterLines: [String] { broadcasters.map(\.advertisement.summary) }

    /// The broadcaster to offer under "Use this broadcaster": once the scan has
    /// run long enough with no WHOOP heard, and exactly one broadcaster was not
    /// accepted.
    public func manualCandidate(now: Date) -> Broadcaster? {
        guard noWhoopHeard(now: now) else { return nil }
        let unknown = broadcasters.filter { !$0.accepted }
        return unknown.count == 1 ? unknown[0] : nil
    }

    public func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// True once the scan has run long enough that a WHOOP with HR Broadcast
    /// on would normally have been heard.
    public func noWhoopHeard(now: Date) -> Bool {
        startedAt != nil && whoopBroadcasters.isEmpty && elapsed(now: now) >= Self.noWhoopAfter
    }

    /// One plain sentence, for example "Heard 2 heart rate broadcasters, none from a WHOOP."
    public var summary: String {
        let total = heartRateBroadcasters.count
        let whoops = whoopBroadcasters.count
        if total == 0 { return "No heart rate broadcasts heard yet." }
        let devices = total == 1 ? "1 heart rate broadcaster" : "\(total) heart rate broadcasters"
        if whoops == 0 { return "Heard \(devices), none from a WHOOP." }
        if !otherWhoops.isEmpty, otherWhoops.count == whoops {
            return "Heard \(devices), including a WHOOP that is not your remembered strap."
        }
        let whoopText = whoops == 1 ? "1 WHOOP" : "\(whoops) WHOOPs"
        return total == whoops ? "Heard \(whoopText)." : "Heard \(devices), including \(whoopText)."
    }
}

/// Everything the menu, the menu bar icon, and the walkthrough need to show,
/// captured at one moment.
public struct HRSnapshot: Sendable {
    public var status: BluetoothStatus
    public var permission: BluetoothPermission
    public var scan: ScanDiagnostics
    public var latestBPM: Int?
    public var latestReadingAt: Date?
    /// True when the latest reading came from the current connection.
    public var readingIsFromConnection: Bool
    /// A valid reading has arrived at some point, in this run or an earlier one.
    public var setupComplete: Bool
    public var lastSuccessfulUpload: Date?
    /// The upload status text when the latest attempt failed, otherwise nil.
    public var uploadProblem: String?
    public var now: Date

    public init(
        status: BluetoothStatus, permission: BluetoothPermission = .allowed, scan: ScanDiagnostics = ScanDiagnostics(),
        latestBPM: Int? = nil, latestReadingAt: Date? = nil, readingIsFromConnection: Bool = false,
        setupComplete: Bool = false, lastSuccessfulUpload: Date? = nil, uploadProblem: String? = nil, now: Date
    ) {
        self.status = status
        self.permission = permission
        self.scan = scan
        self.latestBPM = latestBPM
        self.latestReadingAt = latestReadingAt
        self.readingIsFromConnection = readingIsFromConnection
        self.setupComplete = setupComplete
        self.lastSuccessfulUpload = lastSuccessfulUpload
        self.uploadProblem = uploadProblem
        self.now = now
    }

    public var age: ReadingAge? {
        latestReadingAt.map {
            ReadingAge(readAt: $0, now: now, connected: status == .connected && readingIsFromConnection)
        }
    }

    public var hasLiveReading: Bool {
        guard latestBPM != nil, let age else { return false }
        return !age.isStale
    }

    var bluetoothBlocked: Bool {
        permission == .denied || status == .unauthorized
    }
}

// MARK: - Menu bar icon

public struct MenuBarIcon: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// Fresh reading: filled heart and the BPM.
        case live
        /// No reading yet, or the last one is stale: outline heart and a dash.
        case waiting
        /// Bluetooth is off, unavailable, or not allowed.
        case blocked
        /// The user paused recording.
        case paused
    }

    public static let noReading = "–"

    public let style: Style
    public let symbol: String
    public let text: String
    public let accessibilityLabel: String

    /// Drawn at reduced opacity: no current reading, or Bluetooth needs attention.
    public var isDimmed: Bool { style == .waiting || style == .blocked }

    public init(_ snapshot: HRSnapshot, showReading: Bool = true) {
        if snapshot.status == .paused {
            style = .paused
            symbol = "pause.circle.fill"
            text = ""
            accessibilityLabel = "Meetspike HR, paused"
        } else if showReading, let bpm = snapshot.latestBPM, snapshot.hasLiveReading {
            style = .live
            symbol = "heart.fill"
            text = "\(bpm)"
            accessibilityLabel = "Meetspike HR, \(bpm) beats per minute"
        } else if snapshot.bluetoothBlocked || snapshot.status == .poweredOff || snapshot.status == .unsupported {
            style = .blocked
            symbol = "heart.slash"
            text = Self.noReading
            accessibilityLabel = "Meetspike HR, Bluetooth needs attention"
        } else {
            style = .waiting
            symbol = "heart"
            text = showReading ? Self.noReading : ""
            accessibilityLabel = showReading ? "Meetspike HR, no current heart rate" : "Meetspike HR"
        }
    }
}

// MARK: - Menu status text

public struct MenuStatus: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case openSettings(SystemSettingsLink)
        /// Remember this broadcaster as the strap and connect to it.
        case useBroadcaster(UUID)
    }

    public let headline: String
    public let detail: String?
    public let action: Action?
    public let actionTitle: String?
    /// Scan diagnostics, shown while looking for the strap.
    public let diagnostics: String?
    /// One line per heart rate broadcaster heard in the current scan.
    public let broadcasters: [String]
    public let isProblem: Bool

    init(
        _ headline: String, detail: String? = nil, action: Action? = nil, actionTitle: String? = nil,
        diagnostics: String? = nil, broadcasters: [String] = [], isProblem: Bool = false
    ) {
        self.headline = headline
        self.detail = detail
        self.action = action
        self.actionTitle = actionTitle
        self.diagnostics = diagnostics
        self.broadcasters = broadcasters
        self.isProblem = isProblem
    }

    public static let hrBroadcastPath = "Menu → Device Settings → HR Broadcast"

    public init(_ snapshot: HRSnapshot) {
        let scanLine = snapshot.scan.startedAt == nil ? nil : snapshot.scan.summary
        let heard = snapshot.scan.startedAt == nil ? [] : snapshot.scan.broadcasterLines
        if snapshot.status == .paused {
            self.init("Paused", detail: "Heart rate is not being recorded. Choose Resume to start again.")
            return
        }
        if snapshot.status == .outsideMeeting {
            self.init("Outside meeting hours", detail: "Go live now to listen outside a scheduled meeting.")
            return
        }
        if snapshot.bluetoothBlocked {
            self.init(
                "Bluetooth not allowed — open System Settings",
                detail: "Turn on Meetspike HR in Privacy & Security → Bluetooth.",
                action: .openSettings(.bluetoothPrivacy), actionTitle: "Open Bluetooth Privacy Settings",
                isProblem: true
            )
            return
        }
        switch snapshot.status {
        case .poweredOff:
            self.init(
                "Bluetooth is off — turn it on",
                detail: "Turn on Bluetooth in Control Center or System Settings.",
                action: .openSettings(.bluetooth), actionTitle: "Open Bluetooth Settings", isProblem: true
            )
        case .unsupported:
            self.init("This Mac can't use Bluetooth", isProblem: true)
        case .sleeping:
            self.init("Paused while the Mac sleeps")
        case .starting, .waiting:
            if snapshot.permission == .notDetermined {
                self.init("Waiting for Bluetooth permission", detail: "Click Allow when macOS asks.")
            } else {
                self.init("Starting Bluetooth…")
            }
        case .searching:
            if !snapshot.scan.otherWhoops.isEmpty {
                self.init(
                    "Found a WHOOP, but not your remembered strap",
                    detail: "If you replaced your strap, choose Forget WHOOP in Settings.",
                    diagnostics: scanLine, broadcasters: heard, isProblem: true
                )
            } else if snapshot.scan.noWhoopHeard(now: snapshot.now) {
                let candidate = snapshot.scan.manualCandidate(now: snapshot.now)
                var detail = "In the WHOOP phone app, open \(Self.hrBroadcastPath) and turn it on. Wear the strap and keep it near the Mac."
                if candidate != nil {
                    detail += " If the one broadcaster below is your WHOOP, choose Use this broadcaster."
                }
                self.init(
                    "No WHOOP broadcast found — check HR Broadcast",
                    detail: detail,
                    action: candidate.map { .useBroadcaster($0.id) },
                    actionTitle: candidate.map { "Use this broadcaster (\($0.advertisement.displayName))" },
                    diagnostics: scanLine, broadcasters: heard, isProblem: true
                )
            } else {
                self.init("Scanning for WHOOP…", diagnostics: scanLine, broadcasters: heard)
            }
        case .connecting:
            self.init("WHOOP found — connecting…")
        case .reconnecting:
            self.init(
                "Lost the WHOOP — trying again…",
                detail: "Keep the strap near the Mac with HR Broadcast on. Close other apps that read WHOOP heart rate, such as Peloton or Zwift.",
                diagnostics: scanLine, broadcasters: heard
            )
        case .connected:
            if snapshot.hasLiveReading {
                self.init("Receiving heart rate")
            } else {
                self.init(
                    "Connected — waiting for heart rate",
                    detail: "Make sure you're wearing the strap. Close other apps that read WHOOP heart rate."
                )
            }
        case .paused, .unauthorized, .outsideMeeting:
            // Handled above.
            self.init(snapshot.status.rawValue)
        }
    }
}

// MARK: - First-launch walkthrough

public enum Walkthrough {
    public struct Step: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        /// A "do not" step, shown with a warning style.
        public let isWarning: Bool
    }

    public static let title = "Set up heart rate from your WHOOP"
    public static let intro = """
        Meetspike HR listens to the heart rate your WHOOP strap broadcasts. The strap stays connected to the WHOOP \
        app on your phone. Your Mac just listens, so there is nothing to pair.
        """

    public static let steps: [Step] = [
        Step(
            id: "wear", title: "Wear your WHOOP",
            detail: "Put the strap on. It only sends heart rate while you're wearing it.", isWarning: false
        ),
        Step(
            id: "broadcast", title: "Turn on HR Broadcast",
            detail: """
                In the WHOOP app on your phone, open \(MenuStatus.hrBroadcastPath) and turn it on. \
                It can turn itself off after a WHOOP firmware update, so check it again after updates.
                """,
            isWarning: false
        ),
        Step(
            id: "phone", title: "Keep the WHOOP app connected",
            detail: "Leave your phone's WHOOP app connected to the strap. That's fine. Your phone and your Mac can both listen.",
            isWarning: false
        ),
        Step(
            id: "others", title: "Close other heart rate apps",
            detail: """
                Quit Peloton, Zwift, and other apps or machines that read your WHOOP heart rate. \
                The strap sends heart rate to one listener at a time.
                """,
            isWarning: false
        ),
        Step(
            id: "nopair", title: "Don't pair the strap",
            detail: """
                Do NOT put the strap in pairing mode, and do NOT add it in the Mac's Bluetooth settings. \
                Pairing mode can pull the strap away from the WHOOP app on your phone, and HR Broadcast doesn't need pairing. \
                If your WHOOP is listed in System Settings → Bluetooth, click ⓘ next to it and choose Forget This Device.
                """,
            isWarning: true
        ),
        Step(
            id: "allow", title: "Allow Bluetooth",
            detail: """
                When macOS asks if Meetspike HR can use Bluetooth, click Allow. If you clicked Don't Allow, \
                turn on Meetspike HR in System Settings → Privacy & Security → Bluetooth.
                """,
            isWarning: false
        )
    ]

    /// The walkthrough opens at launch until the first valid reading arrives.
    public static func showsAtLaunch(setupComplete: Bool) -> Bool { !setupComplete }

    public static func isFinished(_ snapshot: HRSnapshot) -> Bool {
        snapshot.setupComplete || snapshot.latestBPM != nil
    }
}

// MARK: - Live setup checklist

public struct SetupCheck: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case bluetoothPermission, scanning, strapFound, firstReading, lastUpload
    }

    public enum State: Equatable, Sendable {
        case done
        case inProgress
        case waiting
        case problem
    }

    public let kind: Kind
    public let title: String
    public let state: State
    public let detail: String

    public var id: Kind { kind }

    public static func all(_ snapshot: HRSnapshot) -> [SetupCheck] {
        Kind.allCases.map { make($0, snapshot) }
    }

    static func make(_ kind: Kind, _ s: HRSnapshot) -> SetupCheck {
        let strapFound = s.status == .connecting || s.status == .connected
        let paused = s.status == .paused || s.status == .sleeping
        switch kind {
        case .bluetoothPermission:
            let title = "Bluetooth permission"
            if s.bluetoothBlocked {
                return SetupCheck(kind: kind, title: title, state: .problem,
                                  detail: "Not allowed. Open System Settings → Privacy & Security → Bluetooth.")
            }
            if s.permission == .notDetermined {
                return SetupCheck(kind: kind, title: title, state: .inProgress, detail: "Click Allow when macOS asks.")
            }
            return SetupCheck(kind: kind, title: title, state: .done, detail: "Allowed")

        case .scanning:
            let title = "Scanning for WHOOP"
            if strapFound || s.hasLiveReading {
                return SetupCheck(kind: kind, title: title, state: .done, detail: s.scan.startedAt == nil ? "Done" : s.scan.summary)
            }
            if paused {
                return SetupCheck(kind: kind, title: title, state: .waiting,
                                  detail: s.status == .paused ? "Paused. Choose Resume in the menu." : "Paused while the Mac sleeps.")
            }
            if s.bluetoothBlocked {
                return SetupCheck(kind: kind, title: title, state: .waiting, detail: "Waiting for Bluetooth permission.")
            }
            switch s.status {
            case .poweredOff:
                return SetupCheck(kind: kind, title: title, state: .problem, detail: "Bluetooth is off. Turn it on.")
            case .unsupported:
                return SetupCheck(kind: kind, title: title, state: .problem, detail: "This Mac can't use Bluetooth.")
            case .searching, .reconnecting:
                return SetupCheck(kind: kind, title: title, state: .inProgress, detail: s.scan.summary)
            default:
                return SetupCheck(kind: kind, title: title, state: .waiting, detail: "Starting Bluetooth…")
            }

        case .strapFound:
            let title = "WHOOP found"
            if strapFound || s.hasLiveReading {
                return SetupCheck(kind: kind, title: title, state: .done,
                                  detail: s.status == .connecting ? "Connecting…" : "Connected")
            }
            if !s.scan.otherWhoops.isEmpty {
                return SetupCheck(kind: kind, title: title, state: .problem,
                                  detail: "Found a WHOOP that is not your remembered strap. If you replaced it, choose Forget WHOOP in Settings.")
            }
            if s.status == .searching, s.scan.noWhoopHeard(now: s.now) {
                return SetupCheck(kind: kind, title: title, state: .problem,
                                  detail: "No WHOOP broadcast found. Check HR Broadcast in the WHOOP phone app.")
            }
            if s.status == .reconnecting {
                return SetupCheck(kind: kind, title: title, state: .inProgress, detail: "Lost the strap. Trying again…")
            }
            return SetupCheck(kind: kind, title: title, state: .waiting, detail: "Not yet")

        case .firstReading:
            let title = "First heart rate reading"
            if let bpm = s.latestBPM {
                return SetupCheck(kind: kind, title: title, state: .done,
                                  detail: s.hasLiveReading ? "\(bpm) bpm" : "Last reading \(bpm) bpm")
            }
            if s.setupComplete {
                return SetupCheck(kind: kind, title: title, state: .done, detail: "Received before")
            }
            if s.status == .connected {
                return SetupCheck(kind: kind, title: title, state: .inProgress,
                                  detail: "Waiting for heart rate. Wear the strap and close other heart rate apps.")
            }
            return SetupCheck(kind: kind, title: title, state: .waiting, detail: "Not yet")

        case .lastUpload:
            let title = "Last upload"
            if let problem = s.uploadProblem {
                return SetupCheck(kind: kind, title: title, state: .problem, detail: problem)
            }
            if let time = s.lastSuccessfulUpload {
                return SetupCheck(kind: kind, title: title, state: .done, detail: "Uploaded \(uploadTime(time, now: s.now))")
            }
            return SetupCheck(kind: kind, title: title, state: .waiting,
                              detail: "Uploads start about 5 minutes after launch, then every 30 minutes.")
        }
    }

    static func uploadTime(_ time: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(time)) / 60)
        switch minutes {
        case 0: return "just now"
        case 1: return "1 minute ago"
        case ..<120: return "\(minutes) minutes ago"
        default: return "\(minutes / 60) hours ago"
        }
    }
}
