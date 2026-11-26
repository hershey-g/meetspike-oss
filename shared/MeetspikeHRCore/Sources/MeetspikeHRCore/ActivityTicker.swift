import Foundation

/// Retries buffered work even when a disconnected strap sends no callbacks.
/// The phone enables this only while foregrounded and inside a listening window.
@MainActor
public final class ActivityTicker {
    private let interval: Duration
    private let tick: @MainActor () -> Void
    private var task: Task<Void, Never>?

    public init(interval: Duration = .seconds(5), tick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    public func setRunning(_ running: Bool) {
        guard running else {
            task?.cancel()
            task = nil
            return
        }
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    deinit { task?.cancel() }
}
