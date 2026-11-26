import Foundation

public struct HeartRatePoint: Codable, Equatable, Sendable, Identifiable {
    public let timeMs: Int64
    public let bpm: Int
    public var id: Int64 { timeMs }
    public var time: Date { Date(timeIntervalSince1970: Double(timeMs) / 1_000) }

    init(timeMs: Int64, bpm: Int) {
        self.timeMs = timeMs
        self.bpm = bpm
    }

    public init(bpm: Int, at time: Date) {
        self.init(timeMs: time.unixMilliseconds, bpm: bpm)
    }

    public init(from decoder: Decoder) throws {
        var pair = try decoder.unkeyedContainer()
        timeMs = try pair.decode(Int64.self)
        bpm = try pair.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var pair = encoder.unkeyedContainer()
        try pair.encode(timeMs)
        try pair.encode(bpm)
    }
}

struct IngestPayload: Codable {
    struct Span: Codable, Equatable {
        let startMs: Int64
        let endMs: Int64
    }

    struct HeartRate: Codable {
        var spans: [Span] = []
        let points: [HeartRatePoint]
    }

    var version = 1
    var source = "ble"
    let fetchedAt: Date
    let hr: HeartRate

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct ReadingReceipt: Sendable {
    let timeMs: Int64
    let bpm: Int
    let revision: Int64
}

public struct UploadBatch: Sendable {
    public let body: Data
    let pending: [ReadingReceipt]

    static let maxPoints = 4_000
}

public struct UploadSchedule {
    public static let interval: TimeInterval = 1_800
    static let firstRetry: TimeInterval = 300
    static let maxRetry: TimeInterval = 3_600
    public private(set) var nextAttempt: Date
    private var retryDelay = UploadSchedule.firstRetry

    public init(now: Date) {
        nextAttempt = now.addingTimeInterval(Self.firstRetry)
    }

    public mutating func complete(success: Bool, now: Date) {
        if success {
            retryDelay = Self.firstRetry
            nextAttempt = now.addingTimeInterval(Self.interval)
        } else {
            nextAttempt = now.addingTimeInterval(retryDelay)
            retryDelay = min(retryDelay * 2, Self.maxRetry)
        }
    }
}
