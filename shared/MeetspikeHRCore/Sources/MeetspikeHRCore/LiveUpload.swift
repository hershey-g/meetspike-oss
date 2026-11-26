import Foundation

struct LiveUploadPayload: Encodable {
    let version = 1
    let points: [HeartRatePoint]
    let includeMeeting: Bool
}

public struct LiveMeeting: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let startUtc: Date
    public let endUtc: Date

    public var paddedStart: Date { startUtc.addingTimeInterval(-600) }
    public var paddedEnd: Date { endUtc.addingTimeInterval(600) }
}

public struct LiveUploadResponse: Decodable, Sendable {
    let ok: Bool
    public let meeting: LiveMeeting?
    public let hasMeeting: Bool

    private enum CodingKeys: String, CodingKey { case ok, meeting }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decode(Bool.self, forKey: .ok)
        meeting = try values.decodeIfPresent(LiveMeeting.self, forKey: .meeting)
        hasMeeting = values.contains(.meeting)
    }
}

public enum LiveUploadError: Error {
    case http(Int)
    case invalidResponse
}

public struct LiveUploadQueue {
    private static let maxAgeMs: Int64 = 15 * 60 * 1_000
    private var pending: [Int64: HeartRatePoint] = [:]

    public init() {}

    public mutating func record(_ point: HeartRatePoint) {
        pending[point.id] = point
    }

    public mutating func batch(now: Date) -> [HeartRatePoint] {
        let oldest = now.unixMilliseconds - Self.maxAgeMs
        pending = pending.filter { $0.key >= oldest }
        return Array(pending.values.sorted { $0.id < $1.id }.prefix(60))
    }

    public mutating func acknowledge(_ points: [HeartRatePoint]) {
        for point in points where pending[point.id] == point {
            pending.removeValue(forKey: point.id)
        }
    }
}
