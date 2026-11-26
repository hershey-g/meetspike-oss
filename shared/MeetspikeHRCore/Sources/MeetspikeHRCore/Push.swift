import Foundation

/// The iPhone's Apple push token, sent with its reminder check-in so the Worker can push the broadcast reminders.
public struct PushRegistration: Equatable, Sendable, Encodable {
    public enum Environment: String, Sendable, Encodable {
        case production, development
    }

    /// Lowercase hex, leading zeros kept.
    public let token: String
    public let environment: Environment

    public init(token: Data, environment: Environment) {
        self.token = token.map { String(format: "%02x", $0) }.joined()
        self.environment = environment
    }

    /// From a token already written as hex (the copy kept in UserDefaults). Nil when it is not hex.
    public init?(hex: String, environment: Environment) {
        let text = hex.lowercased()
        guard !text.isEmpty, text.count % 2 == 0,
              text.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { return nil }
        self.token = text
        self.environment = environment
    }
}

/// Who delivers the broadcast reminders.
public enum ReminderDelivery {
    /// What the phone keeps pending with iOS. While the Worker pushes the reminders (and only checks first that no
    /// heart rate is coming in), the phone schedules none of its own, so a reminder never fires over a live broadcast.
    public static func pending(plan: [PlannedReminder], pushActive: Bool) -> [PlannedReminder] {
        pushActive ? [] : plan
    }
}
