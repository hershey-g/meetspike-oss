import Foundation

/// Runs work on a thread with a big stack. A report can hold a call tree 300 containers deep, and `JSONEncoder`,
/// `JSONDecoder`, `JSONSerialization` and the release of an indirect value all recurse once per level. On the 512 KB
/// stack a Swift concurrency thread has, that overflows at about 90 frames, and a crash reporter must never be what
/// crashes the app. Everything that touches a whole report (scrub, signature, queue, upload request) goes through here.
public enum DiagnosticStack {
    /// 16 MB. Address space only, pages are used as the stack grows. A 300-level value needs well under 1 MB.
    public static let stackSize = 16 * 1024 * 1024

    private static let marker = "hg.diagnostic.stack"

    /// Runs `body` on a thread with a 16 MB stack and waits for it. Already on such a thread: runs inline, so it never
    /// nests threads. A value returned from here is released by the caller, so keep deep values inside `body`.
    /// Errors the body throws come out of this call. (Typed throws, so a body that cannot throw needs no `try`.)
    public static func run<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        if Thread.current.threadDictionary[marker] != nil { return try body() }
        var outcome: Result<T, E>?
        withoutActuallyEscaping(body) { work in
            let box = Box<T, E>(work)
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                Thread.current.threadDictionary[marker] = true
                box.execute()
                done.signal()
            }
            thread.name = "MeetspikeDiagnosticStack"
            thread.stackSize = stackSize
            thread.qualityOfService = Thread.current.qualityOfService
            thread.start()
            done.wait()
            outcome = box.outcome
            box.outcome = nil
        }
        guard let outcome else { preconditionFailure("DiagnosticStack: the thread never ran") }
        return try outcome.get()
    }

    /// Holds the work only until it has run, so nothing keeps the closure alive after `run` returns.
    private final class Box<T, E: Error>: @unchecked Sendable {
        var work: (() throws(E) -> T)?
        var outcome: Result<T, E>?

        init(_ work: @escaping () throws(E) -> T) { self.work = work }

        func execute() {
            guard let work else { return }
            self.work = nil
            do throws(E) { outcome = .success(try work()) } catch { outcome = .failure(error) }
        }
    }
}
