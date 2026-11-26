#if canImport(Combine)
#if os(iOS)
import UIKit
#endif

@MainActor
final class UploadExecution {
    #if os(iOS)
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(onExpiration: @escaping () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Meetspike heart rate") { [weak self] in
            onExpiration()
            self?.finish()
        }
    }

    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
    #else
    init(onExpiration: @escaping () -> Void) {}
    func finish() {}
    #endif
}
#endif
