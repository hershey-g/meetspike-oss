import Foundation

public struct ReadingAge {
    public let seconds: Int
    public let isStale: Bool

    public init(readAt: Date, now: Date, connected: Bool) {
        seconds = Int(max(0, now.timeIntervalSince(readAt)))
        isStale = !connected || seconds >= 45
    }
}
