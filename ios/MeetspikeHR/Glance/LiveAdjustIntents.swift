import AppIntents
import Foundation

/// The two things the Live card and the Lock Screen Live Activity let you say about the meeting that is running.
enum LiveAdjustKind: Sendable {
    /// Adds 15 minutes to the end, up to 4 hours past the calendar's end.
    case stillGoing
    /// Ends the meeting now.
    case endedNow
}

/// The bridge from a Live Activity button to the app. The buttons below are `LiveActivityIntent`s: the system runs
/// `perform()` in the app's process, even when the app was not running. This file is also built into the widget
/// extension (which only draws the buttons), so it holds no app code: the app registers what to do at launch.
final class LiveAdjustRouter: @unchecked Sendable {
    typealias Action = @MainActor @Sendable (LiveAdjustKind) async -> Void

    static let shared = LiveAdjustRouter()

    private let lock = NSLock()
    private var action: Action?

    /// Called once by the app at launch, before any intent can run.
    func register(_ action: @escaping Action) {
        lock.lock()
        defer { lock.unlock() }
        self.action = action
    }

    func run(_ kind: LiveAdjustKind) async {
        lock.lock()
        let action = self.action
        lock.unlock()
        await action?(kind)
    }
}

struct StillGoingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Still going"
    static let description = IntentDescription("Adds 15 minutes to the meeting that is running.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await LiveAdjustRouter.shared.run(.stillGoing)
        return .result()
    }
}

struct EndedNowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ended now"
    static let description = IntentDescription("Ends the meeting that is running at this moment.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await LiveAdjustRouter.shared.run(.endedNow)
        return .result()
    }
}
