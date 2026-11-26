import Foundation

extension BluetoothCrumb {
    /// What to log when the Bluetooth status moves from `old` to `new`, or nil when it is not worth a crumb. The
    /// status changes often (searching, connecting), and only the connect, the loss of a connection and a failure
    /// to use Bluetooth at all help in a crash report.
    public static func transition(from old: BluetoothStatus?, to new: BluetoothStatus) -> BluetoothCrumb? {
        guard old != new else { return nil }
        switch new {
        case .connected: return .connected
        case .poweredOff, .unauthorized, .unsupported: return .failed
        default: return old == .connected ? .disconnected : nil
        }
    }
}
