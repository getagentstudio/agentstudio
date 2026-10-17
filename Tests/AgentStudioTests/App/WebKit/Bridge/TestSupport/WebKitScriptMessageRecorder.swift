import Foundation
import WebKit

/// Records `WKScriptMessage` bodies and lets a test await their arrival.
///
/// The recorder is the OWNER of the delivered-message fact, so `waitForMessages`
/// parks on a continuation that WebKit's own delivery callback resumes. There is no
/// deadline and no yield budget: the content-world isolation these tests prove has
/// nothing to do with how fast the machine is, and on a hidden page under a
/// three-thread cooperative pool either kind of budget measures the machine instead.
///
/// The lock is an `NSLock` rather than actor isolation because WebKit calls
/// `userContentController(_:didReceive:)` on the main thread while the awaiting test
/// body may be suspended elsewhere.
final class WebKitScriptMessageRecorder: NSObject, WKScriptMessageHandler {
    private struct PendingCountWaiter {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var storage: [Any] = []
    nonisolated(unsafe) private var pendingCountWaiters: [PendingCountWaiter] = []
    private let onStringMessage: (@Sendable (String) -> Void)?

    init(onStringMessage: (@Sendable (String) -> Void)? = nil) {
        self.onStringMessage = onStringMessage
        super.init()
    }

    var receivedMessages: [Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Suspends until at least `expectedCount` messages have been delivered.
    ///
    /// Returns immediately when the count is already satisfied, so there is no
    /// lost-wakeup window between a caller's check and its suspension.
    func waitForMessages(atLeast expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if storage.count >= expectedCount {
                lock.unlock()
                continuation.resume()
                return
            }
            pendingCountWaiters.append(
                PendingCountWaiter(threshold: expectedCount, continuation: continuation)
            )
            lock.unlock()
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        lock.lock()
        storage.append(message.body)
        let deliveredCount = storage.count
        let resumableWaiters = pendingCountWaiters.filter { deliveredCount >= $0.threshold }
        pendingCountWaiters.removeAll { deliveredCount >= $0.threshold }
        lock.unlock()
        if let body = message.body as? String { onStringMessage?(body) }
        // Resume outside the lock: a resumed waiter can re-enter this handler.
        for waiter in resumableWaiters {
            waiter.continuation.resume()
        }
    }
}
