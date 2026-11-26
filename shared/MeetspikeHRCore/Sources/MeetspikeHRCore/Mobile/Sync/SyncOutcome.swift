import Foundation

/// What a finished refresh means, decided once for every screen that tells the person (Today's footer and the
/// Menu's Sync row). The calendar part and the wearable parts are separate answers: a calendar problem never hides
/// a wearable that did not refresh, and a sync that is still running in the background is never "done".
public struct SyncOutcome: Equatable, Sendable {
    public enum Calendar: Equatable, Sendable {
        /// Done. `changed` is meetings written plus removed.
        case synced(changed: Int)
        /// The Worker is still working after the 15 s wait. Not done, not a failure.
        case pending
        /// Google is not connected or its sign-in expired.
        case needsGoogle
        /// The calendar part failed. The text is the Worker's reason.
        case failed(String)
    }

    public var calendar: Calendar
    /// "WHOOP did not refresh." and "Oura did not refresh.", only for wearables the person shows.
    public var wearableNotes: [String]

    public init(calendar: Calendar, wearableNotes: [String]) {
        self.calendar = calendar
        self.wearableNotes = wearableNotes
    }

    /// `showWhoop` and `showOura` follow "Show data": a hidden wearable that failed to refresh stays quiet.
    public static func decide(_ result: RefreshResult, showWhoop: Bool = true, showOura: Bool = true) -> SyncOutcome {
        let calendar: Calendar
        if result.needsGoogle {
            calendar = .needsGoogle
        } else if let error = result.calendarError {
            calendar = .failed(error)
        } else if result.calendar?.pending == true {
            calendar = .pending
        } else {
            calendar = .synced(changed: MoreLogic.changedCount(result))
        }
        var notes: [String] = []
        if showWhoop && result.whoopFailed { notes.append("WHOOP did not refresh.") }
        if showOura && result.ouraFailed { notes.append("Oura did not refresh.") }
        return SyncOutcome(calendar: calendar, wearableNotes: notes)
    }
}
