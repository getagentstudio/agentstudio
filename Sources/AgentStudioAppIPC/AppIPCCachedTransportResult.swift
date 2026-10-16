import AgentStudioIPCTransport
import Foundation

/// One immutable, validated encoded result for a fixed runtime and channel.
/// Composition and framing validation run once; later requests only frame these bytes.
/// Nothing invalidates this: dynamic registration would require a different owner.
package final class AppIPCCachedTransportResult: @unchecked Sendable {
    private let lock = NSLock()
    private let compose: @Sendable () throws -> Data
    private var cachedBytes: Data?
    private var composedCount = 0

    package init(compose: @escaping @Sendable () throws -> Data) {
        self.compose = compose
    }

    package func encodedValue() throws -> Data {
        // Serialize the first fill, including validation. Racing requests must not
        // repeat composition; a failed fill remains retryable.
        try lock.withLock {
            if let cachedBytes { return cachedBytes }
            let encoded = try compose()
            guard String(data: encoded, encoding: .utf8) != nil else {
                throw NDJSONFrameError(reason: .invalidUTF8)
            }
            guard !encoded.contains(0x0a), !encoded.contains(0x0d) else {
                throw NDJSONFrameError(reason: .embeddedNewline)
            }
            cachedBytes = encoded
            composedCount += 1
            return encoded
        }
    }

    package var hasComposedValue: Bool { lock.withLock { cachedBytes != nil } }
    package var compositionCount: Int { lock.withLock { composedCount } }
    /// The real socket proof observes the same byte composition, not a second counter.
    package var encodedCompositionCount: Int { compositionCount }
}
