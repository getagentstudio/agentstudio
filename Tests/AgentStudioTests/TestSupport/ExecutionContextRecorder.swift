import Foundation

/// Records one structural fact about the thread an injected observation
/// closure was called from — `Thread.isMainThread` at that exact call site
/// — so a test can assert "this code ran off MainActor" deterministically,
/// without racing the code under test against other MainActor work (the
/// repo's own rule: a verdict must not depend on machine speed).
///
/// Pass `recorder.record` (or `{ recorder.record() }`) as a production
/// seam's injected, no-op-by-default observation closure; the seam calls it
/// from inside the exact execution context under test, this recorder
/// captures `Thread.isMainThread` there, and the test reads `wasOnMainThread`
/// once that call completes.
package final class ExecutionContextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedWasOnMainThread: Bool?

    package init() {}

    package func record() {
        lock.lock()
        defer { lock.unlock() }
        recordedWasOnMainThread = Thread.isMainThread
    }

    /// `nil` until `record()` has been called at least once.
    package var wasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedWasOnMainThread
    }
}
