import Foundation

public enum BluetoothCrumb: String, Sendable {
    case connected, disconnected, failed
}

/// One breadcrumb. A CLOSED set: every case holds numbers, flags or other closed values, so no meeting title, name,
/// id, heart rate, URL or token can ever get into the log.
public enum Crumb: Equatable, Sendable {
    public enum Tab: String, Sendable {
        case today, dates, people, ask, live
    }

    case launch(build: Int)
    case active
    case background
    case memoryWarning
    case tab(Tab)
    case menuOpen
    case dayLoad(ms: Int, ok: Bool)
    case detailLoad(ms: Int, points: Int, ok: Bool)
    case request(route: String, status: Int, ms: Int)
    case bluetooth(BluetoothCrumb)
    case listen(on: Bool)

    /// The text after the timestamp.
    var body: String {
        switch self {
        case .launch(let build): return "launch \(build)"
        case .active: return "active"
        case .background: return "background"
        case .memoryWarning: return "memoryWarning"
        case .tab(let tab): return "tab \(tab.rawValue)"
        case .menuOpen: return "menuOpen"
        case .dayLoad(let ms, let ok): return "dayLoad \(Self.number(ms))ms \(ok ? "ok" : "fail")"
        case .detailLoad(let ms, let points, let ok):
            return "detailLoad \(Self.number(ms))ms \(Self.number(points))pts \(ok ? "ok" : "fail")"
        case .request(let route, let status, let ms):
            // Whatever the caller passes, only a known template (or "other") can be written.
            let safe = CrumbRoute.isTemplate(route) ? route : "other"
            return "request \(safe) \(min(max(status, 0), 999)) \(Self.number(ms))ms"
        case .bluetooth(let state): return "bluetooth \(state.rawValue)"
        case .listen(let on): return "listen \(on ? "on" : "off")"
        }
    }

    private static func number(_ value: Int) -> Int { max(0, value) }
}

/// Maps a request path to one of a fixed set of templates, or "other". Ids become ":id", the query is dropped, and a
/// path the app does not know is "other", so nothing from the path (an email, a meeting id) can reach the log.
public enum CrumbRoute {
    private static let fixed: Set<String> = [
        "/api/view", "/api/people", "/api/people/search", "/api/refresh", "/api/calendar/sync",
        "/api/settings/source-display", "/api/ask/status", "/api/ask/key", "/api/ask/stream",
        "/api/companies", "/api/companies/search",
    ]
    private static let templates: Set<String> = fixed.union([
        "/api/meetings/:id/hr", "/api/meetings/:id/live-hr", "/api/meetings/:id/override", "/api/people/:id/meetings", "other",
        // A company is addressed by its domain. The domain becomes ":id", so it never reaches the log.
        "/api/companies/:id/meetings", "/api/companies/:id/name",
    ])

    static func isTemplate(_ route: String) -> Bool { templates.contains(route) }

    public static func name(path: String) -> String {
        var text = Substring(path)
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = text[..<cut] }
        guard text.hasPrefix("/") else { return "other" }
        let parts = text.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "api", parts.count >= 2 else { return "other" }
        let joined = "/" + parts.joined(separator: "/")
        if fixed.contains(joined) { return joined }
        guard parts.count == 4, !parts[2].isEmpty else { return "other" }
        switch (parts[1], parts[3]) {
        case ("meetings", "hr"): return "/api/meetings/:id/hr"
        case ("meetings", "live-hr"): return "/api/meetings/:id/live-hr"
        case ("meetings", "override"): return "/api/meetings/:id/override"
        case ("people", "meetings"): return "/api/people/:id/meetings"
        case ("companies", "meetings"): return "/api/companies/:id/meetings"
        case ("companies", "name"): return "/api/companies/:id/name"
        default: return "other"
        }
    }
}
