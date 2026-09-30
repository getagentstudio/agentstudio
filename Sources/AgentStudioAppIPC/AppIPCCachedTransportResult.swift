import AgentStudioIPCTransport
import Foundation

/// One immutable transport value, materialized once and then served.
///
/// The two catalog methods answer with a value that is fixed for a runtime and
/// a channel. `command.list` builds its transport value from the typed result on
/// first use; `system.capabilities` supplies bytes validated during server
/// composition. This cache materializes the transport's `JSONValue` once and
/// reuses it for later requests.
///
/// Nothing invalidates this. Round 1 registers no method or command
/// dynamically, so the catalog a runtime advertises cannot change while it is
/// running. A later round that adds dynamic registration has to replace this
/// with something that can be invalidated, not extend it.
package final class AppIPCCachedTransportResult: @unchecked Sendable {
    private let lock = NSLock()
    private let compose: @Sendable () throws -> JSONValue
    private var cachedValue: JSONValue?
    private var composedCount = 0

    package init(compose: @escaping @Sendable () throws -> JSONValue) {
        self.compose = compose
    }

    /// Composition runs outside the lock, so two racing first requests may both
    /// encode. They encode the same immutable value and the first stored one
    /// wins, which is cheaper than holding a lock across the work.
    package func value() throws -> JSONValue {
        if let cachedValue = lock.withLock({ cachedValue }) { return cachedValue }
        let composed = try compose()
        lock.withLock { composedCount += 1 }
        return lock.withLock {
            if let cachedValue { return cachedValue }
            cachedValue = composed
            return composed
        }
    }

    /// Whether the encoded response has been produced yet, for tests that need
    /// to prove it happens once.
    package var hasComposedValue: Bool {
        lock.withLock { cachedValue != nil }
    }

    /// How many times the response has actually been composed and encoded, for
    /// tests that prove repeated requests are served from the stored value
    /// rather than paying for it again. Counts successful compositions only; a
    /// throwing composition is not cached and is retried.
    package var compositionCount: Int {
        lock.withLock { composedCount }
    }
}
