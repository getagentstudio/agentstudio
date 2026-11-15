import Foundation
import Testing

@testable import AgentStudioCore

extension PaneContextInvalidationTests {
    /// The existing native onTermination flag closes the returned-stop failure path before awaiting EOF.
    static func stopAndCollectInvalidations(
        _ service: PaneContextService, stream: AsyncStream<PaneContextSourceInvalidation>
    ) async throws -> [PaneContextSourceInvalidation] {
        let subscriptions = await service.invalidationSubscribers
        try #require(!subscriptions.isEmpty, "The test must own an active native invalidation subscription")
        await service.stop()
        let nativeStreamsEnded = subscriptions.values.allSatisfy { $0.isEnded }
        try #require(
            nativeStreamsEnded,
            "Service stop returned without closing its native invalidation stream; EOF cannot arrive")
        var observed: [PaneContextSourceInvalidation] = []
        for await change in stream { observed.append(change) }
        return observed
    }
}
