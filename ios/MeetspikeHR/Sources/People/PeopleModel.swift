import Foundation
import MeetspikeHRCore

/// What a People screen shows while it loads. `offline` and `accessRejected` mean the connection banner already
/// told the story; the screen still says what is (not) on it.
enum PeopleLoad<Value> {
    case loading
    case loaded(Value, savedAt: Date?)
    case failed(String)
    case offline
    case accessRejected
}

/// The selected range, shared by the list and the person page (like `state.peopleRange` on the web).
/// Saved on the phone so it survives a relaunch. A saved custom range is only trusted when it still validates.
@MainActor
final class PeopleRangeStore: ObservableObject {
    private static let key = "people.range"

    @Published var range: PeopleRange {
        didSet { UserDefaults.standard.set(Self.encode(range), forKey: Self.key) }
    }

    init() {
        #if DEBUG
        let launch = UserDefaults.standard.string(forKey: "peopleRange")
        #else
        let launch: String? = nil
        #endif
        range = Self.decode(launch ?? UserDefaults.standard.string(forKey: Self.key)) ?? .default
    }

    static func encode(_ range: PeopleRange) -> String {
        switch range {
        case .preset(let preset): preset.rawValue
        case .custom(let start, let end): "custom|\(start)|\(end)"
        }
    }

    static func decode(_ text: String?) -> PeopleRange? {
        guard let text else { return nil }
        if let preset = PeopleRangePreset(rawValue: text) { return .preset(preset) }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "custom", PeopleLogic.validCustomDates(start: parts[1], end: parts[2]) {
            return .custom(start: parts[1], end: parts[2])
        }
        return nil
    }

    var isCustom: Bool {
        if case .custom = range { return true }
        return false
    }

    /// "Last 28 days", or "Nov 1 to Nov 20" for a custom range.
    func scopeLabel(today: String) -> String {
        switch range {
        case .preset(let preset):
            return preset.scopeLabel
        case .custom(let start, let end):
            let a = PeopleFormat.shortDay(start, today: today)
            let b = PeopleFormat.shortDay(end, today: today)
            return start == end ? a : "\(a) to \(b)"
        }
    }

    /// Short label for the range menu.
    func menuTitle(today: String) -> String {
        switch range {
        case .preset(let preset): preset.menuLabel
        case .custom: scopeLabel(today: today)
        }
    }
}

/// Turns a failed call into what the screen shows. Reports to the banner first.
@MainActor
func peopleFailure<Value>(_ error: Error, env: AppEnvironment) -> PeopleLoad<Value> {
    env.report(error)
    switch error as? APIError {
    case .accessRejected: return .accessRejected
    case .offline: return .offline
    default:
        return .failed((error as? APIError)?.message ?? "Something went wrong loading this. Try again.")
    }
}

extension Date {
    /// "Offline, showing data from Nov 24, 2026 at 3:05 PM".
    var peopleOfflineNote: String {
        "Offline, showing data from \(formatted(date: .abbreviated, time: .shortened))"
    }
}
