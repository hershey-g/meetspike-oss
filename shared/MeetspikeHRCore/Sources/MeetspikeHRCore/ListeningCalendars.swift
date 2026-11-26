import Foundation

/// One Apple Calendar (EventKit) calendar on this device.
public struct DeviceCalendar: Equatable, Sendable, Identifiable {
    /// `EKCalendar.calendarIdentifier`.
    public let id: String
    public let title: String
    /// The account it lives in ("iCloud", "Gmail", "Exchange"...).
    public let sourceTitle: String
    /// "#rrggbb", or nil.
    public let colorHex: String?

    public init(id: String, title: String, sourceTitle: String, colorHex: String? = nil) {
        self.id = id
        self.title = title.isEmpty ? "Untitled calendar" : title
        self.sourceTitle = sourceTitle.isEmpty ? "Other" : sourceTitle
        self.colorHex = colorHex
    }
}

/// Which Apple Calendar calendars start heart-rate listening around their meetings.
///
/// Stored on this device as the calendars left out, so every calendar counts by default (as before this
/// setting existed) and a calendar added later counts too until it is turned off.
public struct ListeningCalendarChoice: Equatable, Codable, Sendable {
    public private(set) var excluded: Set<String>

    public init(excluded: Set<String> = []) {
        self.excluded = excluded
    }

    /// Every calendar counts.
    public var listensToAll: Bool { excluded.isEmpty }

    public func includes(_ id: String) -> Bool { !excluded.contains(id) }

    public mutating func set(_ id: String, included: Bool) {
        if included { excluded.remove(id) } else { excluded.insert(id) }
    }

    public func setting(_ id: String, included: Bool) -> ListeningCalendarChoice {
        var copy = self
        copy.set(id, included: included)
        return copy
    }

    /// Every calendar counts again.
    public static let all = ListeningCalendarChoice()

    /// What to ask EventKit for, given the calendars on the device now.
    public enum Query: Equatable, Sendable {
        /// Pass `calendars: nil` (every calendar, the old behavior).
        case all
        /// Only these calendar ids, in the order given.
        case some([String])
        /// Every calendar is turned off: no meetings, so listening never starts on its own.
        case none
    }

    public func query(available: [String]) -> Query {
        let kept = available.filter(includes)
        if kept.count == available.count { return .all }
        return kept.isEmpty ? .none : .some(kept)
    }

    /// Short state for a settings row: "All calendars", "3 of 5 calendars", "None".
    public func summary(available: [DeviceCalendar]) -> String {
        guard !available.isEmpty else { return listensToAll ? "All calendars" : "Some calendars" }
        let kept = available.filter { includes($0.id) }.count
        if kept == available.count { return "All calendars" }
        if kept == 0 { return "None" }
        return "\(kept) of \(available.count) calendars"
    }

    /// Calendars grouped by account, accounts and calendars in alphabetical order.
    public static func grouped(_ calendars: [DeviceCalendar]) -> [(source: String, calendars: [DeviceCalendar])] {
        let bySource = Dictionary(grouping: calendars, by: \.sourceTitle)
        return bySource.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { source in
                (source, (bySource[source] ?? []).sorted {
                    let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                })
            }
    }

    // MARK: Storage (this device only)

    public static let defaultsKey = "listeningCalendarsExcluded"

    public static func load(from defaults: UserDefaults = .standard) -> ListeningCalendarChoice {
        let ids = defaults.stringArray(forKey: defaultsKey) ?? []
        return ListeningCalendarChoice(excluded: Set(ids.filter { !$0.isEmpty }))
    }

    public func save(to defaults: UserDefaults = .standard) {
        if excluded.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(excluded.sorted(), forKey: Self.defaultsKey)
        }
    }
}
