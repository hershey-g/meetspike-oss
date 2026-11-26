import Foundation

/// Where the Ask tab keeps its saved chat: one JSON file per mode (real, demo) in a private directory.
/// Replaces the old UserDefaults copy, which was plaintext and part of device backups. The file is written
/// atomically with file protection, and the directory is excluded from backup.
public struct AskChatStore: Sendable {
    public static let realKey = "meetspike-chat-v1"
    public static let demoKey = "meetspike-chat-v1-demo"

    public let directory: URL
    public let isDemo: Bool

    public init(directory: URL, isDemo: Bool) {
        self.directory = directory
        self.isDemo = isDemo
    }

    /// Application Support/Meetspike. Not created until the first save.
    public static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Meetspike", isDirectory: true)
    }

    static func fileName(isDemo: Bool) -> String { isDemo ? "ask-chat-demo.json" : "ask-chat.json" }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName(isDemo: isDemo)) }

    /// The saved chat, or nil when there is none or the file cannot be read.
    public func load() -> AskSavedChat? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AskSavedChat.self, from: data)
    }

    public enum StoreError: Error { case encode }

    /// Writes the chat. Throws so the caller can log it with the triggering action.
    public func save(_ chat: AskSavedChat) throws {
        guard let data = try? JSONEncoder().encode(chat) else { throw StoreError.encode }
        try Self.write(data, to: fileURL, directory: directory)
    }

    /// Removes the saved chat for this mode. A missing file is fine.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Moves any chat the old build left in UserDefaults into files, then deletes the keys, so nothing stays in
    /// defaults. A file that already exists wins over the old copy. Runs for both real and demo keys.
    /// Returns the number of old copies removed from defaults.
    @discardableResult
    public static func migrateLegacy(from defaults: UserDefaults, into directory: URL) -> Int {
        var removed = 0
        for (key, demo) in [(realKey, false), (demoKey, true)] {
            guard let data = defaults.data(forKey: key) else {
                // A value of the wrong type would still leave it in defaults.
                if defaults.object(forKey: key) != nil {
                    defaults.removeObject(forKey: key)
                    removed += 1
                }
                continue
            }
            let target = directory.appendingPathComponent(fileName(isDemo: demo))
            let valid = (try? JSONDecoder().decode(AskSavedChat.self, from: data)) != nil
            let exists = FileManager.default.fileExists(atPath: target.path)
            if valid && !exists {
                // Keep the old copy in defaults if the file could not be written, so no chat is lost.
                guard (try? write(data, to: target, directory: directory)) != nil else { continue }
            }
            defaults.removeObject(forKey: key)
            removed += 1
        }
        return removed
    }

    private static func write(_ data: Data, to url: URL, directory: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        #if os(iOS)
        var local = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try local.setResourceValues(values)
        #endif
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }
}

/// Which tab the person came from when Ask opened. Mirrors the app's tab, without the app type.
public enum AskOrigin: Equatable, Sendable {
    case dates, people, other

    public init(tabName: String?) {
        switch tabName {
        case "dates": self = .dates
        case "people": self = .people
        default: self = .other
        }
    }
}

extension AskScope {
    /// The range a chat is asked over on first visit (web app.js askScope): Dates gives its span, People gives
    /// the range it is showing, anything else lets Ask work the dates out from the question.
    public static func forVisit(from origin: AskOrigin, dates: (start: String, end: String), people: (start: String, end: String)?) -> AskScope? {
        switch origin {
        case .dates: return AskScope(start: dates.start, end: dates.end)
        case .people: return people.flatMap { AskScope(start: $0.start, end: $0.end) }
        case .other: return nil
        }
    }
}

/// What to say out loud when an answer finishes, or nil for nothing.
public enum AskAnnouncement {
    /// Quiet when the session hit a key problem (the last answer would be an older one), or when another tab
    /// is on screen.
    public static func message(for last: AskChatTurn?, hadKeyProblem: Bool, askTabSelected: Bool) -> String? {
        guard !hadKeyProblem, askTabSelected, let last, last.role == .assistant else { return nil }
        if let error = last.error { return AskLogic.appCopy(error) }
        if last.interrupted { return "The connection dropped. The answer is incomplete. You can try again." }
        if !last.content.isEmpty { return "Answer ready." }
        return nil
    }

    /// Copy for the Remove confirmation.
    public static let removeKeyMessage = "This also clears your saved chat. You can add the key again any time."
}
