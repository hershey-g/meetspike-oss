import Foundation

/// A JSON value. Plain `JSONEncoder` / `JSONDecoder` round trip, and a Bool never turns into a number.
public indirect enum DiagnosticValue: Codable, Equatable, Sendable {
    case object([String: DiagnosticValue])
    case array([DiagnosticValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Bool first: JSONDecoder will not read a number as a Bool, so 1 stays a number.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([DiagnosticValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: DiagnosticValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// The body the phone sends to its own Worker (POST /api/whoop-web/app/diagnostics).
public struct DiagnosticReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case crash, hang, cpu, disk, exit, error, test
    }

    public var id: UUID
    public var kind: Kind
    public var at: Date
    public var build: Int
    public var version: String
    public var os: String
    public var device: String
    public var signature: String?
    public var report: DiagnosticValue
    public var crumbs: [String]

    public init(
        id: UUID, kind: Kind, at: Date, build: Int, version: String, os: String, device: String,
        signature: String? = nil, report: DiagnosticValue, crumbs: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.build = build
        self.version = version
        self.os = os
        self.device = device
        self.signature = signature
        self.report = report
        self.crumbs = crumbs
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, at, app, build, version, os, device, signature, report, crumbs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idText = try container.decode(String.self, forKey: .id)
        guard let id = UUID(uuidString: idText) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "id is not a uuid")
        }
        let atText = try container.decode(String.self, forKey: .at)
        guard let at = DiagnosticTime.parse(atText) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "at is not an ISO date")
        }
        self.id = id
        kind = try container.decode(Kind.self, forKey: .kind)
        self.at = at
        build = try container.decode(Int.self, forKey: .build)
        version = try container.decode(String.self, forKey: .version)
        os = try container.decode(String.self, forKey: .os)
        device = try container.decode(String.self, forKey: .device)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        // The tree can be 300 levels deep and the decoder recurses once per level, so whoever decodes a report (the
        // queue, a test, a tool) never needs a big stack of their own: the deep part runs on `DiagnosticStack`.
        report = try DiagnosticStack.run { () throws -> DiagnosticValue in
            try container.decode(DiagnosticValue.self, forKey: .report)
        }
        crumbs = try container.decodeIfPresent([String].self, forKey: .crumbs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(DiagnosticTime.format(at), forKey: .at)
        try container.encode("ios", forKey: .app)
        try container.encode(build, forKey: .build)
        try container.encode(version, forKey: .version)
        try container.encode(os, forKey: .os)
        try container.encode(device, forKey: .device)
        try container.encodeIfPresent(signature, forKey: .signature)
        try DiagnosticStack.run { () throws -> Void in try container.encode(report, forKey: .report) }
        if !crumbs.isEmpty { try container.encode(crumbs, forKey: .crumbs) }
    }
}
