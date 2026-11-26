import Foundation

/// Decides which requests leave a crumb. A polling route (live heart rate, every 5 s) would fill the trail in
/// minutes, so it is written only when it is not a success, or when its status differs from the last one written for
/// that route (so a recovery shows once). Every other route is always written. Safe to call from any thread.
public final class RequestCrumbFilter: @unchecked Sendable {
    /// Routes (`CrumbRoute` templates) that are polled.
    public static let defaultPollingRoutes: Set<String> = ["/api/meetings/:id/live-hr"]

    private let pollingRoutes: Set<String>
    private let lock = NSLock()
    private var lastRecorded: [String: Int] = [:]

    public init(pollingRoutes: Set<String> = RequestCrumbFilter.defaultPollingRoutes) {
        self.pollingRoutes = pollingRoutes
    }

    /// True when a request crumb should be written. Call once per request. A true answer on a polling route is
    /// remembered as that route's last written status.
    public func shouldRecord(route: String, status: Int) -> Bool {
        guard pollingRoutes.contains(route) else { return true }
        lock.lock()
        defer { lock.unlock() }
        if (200..<300).contains(status), lastRecorded[route] == status { return false }
        lastRecorded[route] = status
        return true
    }
}
