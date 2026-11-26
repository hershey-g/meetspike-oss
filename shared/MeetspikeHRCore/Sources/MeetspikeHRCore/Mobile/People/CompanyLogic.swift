import Foundation

// Pure logic for companies on the People tab: the People | Companies switch, list sorting, search answers kept
// in memory, and the short lines a company row and page show.

/// What the People tab lists.
public enum PeopleMode: String, CaseIterable, Sendable, Equatable {
    case people, companies

    /// Segment label: "People", "Companies".
    public var label: String {
        switch self {
        case .people: return "People"
        case .companies: return "Companies"
        }
    }
}

/// How the company list is ordered.
public enum CompanySort: String, CaseIterable, Sendable, Equatable {
    case meetings, people, score, name

    /// Menu label.
    public var label: String {
        switch self {
        case .meetings: return "Most meetings"
        case .people: return "Most people"
        case .score: return "Lowest score"
        case .name: return "Name"
        }
    }
}

public enum CompanyLogic {
    /// Orders companies. Ties fall back to most meetings, then the name, so the order never jumps.
    /// "Lowest score" puts companies without a score last.
    public static func sorted(_ companies: [CompanySummary], by sort: CompanySort) -> [CompanySummary] {
        func name(_ c: CompanySummary) -> String { c.displayName.lowercased() }
        func fallback(_ a: CompanySummary, _ b: CompanySummary) -> Bool {
            let am = a.meetings ?? 0, bm = b.meetings ?? 0
            if am != bm { return am > bm }
            if name(a) != name(b) { return name(a) < name(b) }
            return a.domain < b.domain
        }
        return companies.sorted { a, b in
            switch sort {
            case .meetings:
                return fallback(a, b)
            case .people:
                let ap = a.people ?? 0, bp = b.people ?? 0
                return ap != bp ? ap > bp : fallback(a, b)
            case .score:
                switch (a.avg, b.avg) {
                case let (x?, y?) where x != y: return x < y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return fallback(a, b)
                }
            case .name:
                if name(a) != name(b) { return name(a) < name(b) }
                return a.domain < b.domain
            }
        }
    }

    /// "3 meetings · 2 people".
    public static func detail(_ company: CompanySummary) -> String {
        "\(PeopleFormat.plural(company.meetings ?? 0, "meeting")) \u{B7} \(PeopleFormat.plural(company.people ?? 0, "person", many: "people"))"
    }

    /// A short heart rate line for a company row, or nil without heart rate in its meetings:
    /// "Often spikes you", "Usually restored", "Elevated in 2 of 5", or "Heart rate in 1 meeting".
    public static func hrSummary(_ trend: PersonTrend?) -> String? {
        guard let trend, let covered = trend.withCoverage, covered > 0 else { return nil }
        switch trend.badge {
        case "often spikes you": return "Often spikes you"
        case "usually restored": return "Usually restored"
        default: break
        }
        let scored = (trend.elevated ?? 0) + (trend.watching ?? 0) + (trend.restored ?? 0)
        if scored > 0 { return "Elevated in \(trend.elevated ?? 0) of \(scored)" }
        return "Heart rate in \(PeopleFormat.plural(covered, "meeting"))"
    }

    /// Initials for a company badge: "AC" for "Acme Corp", "G" for "Globex", from the domain when there is no name.
    public static func initials(_ name: String?, domain: String) -> String {
        let source = (name?.isEmpty == false ? name : nil) ?? String(domain.split(separator: ".").first ?? "")
        let parts = source.split(whereSeparator: { " -_.&".contains($0) })
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// Who from the company was in a meeting: "Pat Lee, Sam Ruiz", "Pat Lee +2".
    public static func attendeeLine(_ attendees: [Attendee]) -> String {
        let names = attendees.map { ($0.name?.isEmpty == false ? $0.name : nil) ?? $0.email }
        if names.count > 2 { return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)" }
        return names.joined(separator: ", ")
    }
}

/// Answers to company search kept in memory, like `PeopleSearchCache`: 5 minutes, 40 queries, oldest dropped first.
public struct CompanySearchCache: Sendable {
    private struct Entry: Sendable {
        var companies: [CompanyMatch]
        var storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    private static func key(_ query: String) -> String {
        query.precomposedStringWithCanonicalMapping.lowercased()
    }

    public func companies(for query: String, now: Date) -> [CompanyMatch]? {
        guard let entry = entries[Self.key(query)] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) < PeopleLogic.searchCacheSeconds else { return nil }
        return entry.companies
    }

    public mutating func store(_ companies: [CompanyMatch], for query: String, now: Date) {
        let key = Self.key(query)
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = Entry(companies: companies, storedAt: now)
        while order.count > PeopleLogic.searchCacheLimit {
            entries[order.removeFirst()] = nil
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int { entries.count }
}
