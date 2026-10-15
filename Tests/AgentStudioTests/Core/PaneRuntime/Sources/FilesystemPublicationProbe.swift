import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore

// Mark before the stimulus. After the producer's joined shutdown, mark again
// to consume its finite delivery checkpoint, then stop and join the collector.
// No shutdown fact is synthesized: exact observations use the joined return.
final class FilesystemPublicationProbe: Sendable {
    let facts: FactRecorder<UInt64, RuntimeEnvelope>
    private let recorded: FilesystemDeliveredEnvelopes

    init(bus: EventBus<RuntimeEnvelope>) async {
        let subscription = await bus.subscribe(policy: .criticalUnbounded, subscriberName: "filesystem proof")
        let recorded = FilesystemDeliveredEnvelopes()
        self.recorded = recorded
        facts = EventBusFactSource.attach(
            subscription: subscription,
            vocabulary: FactVocabulary(
                describeScope: { "filesystem operation \($0)" },
                describeFact: { String(describing: $0) },
                isClosing: { _, envelope in
                    if case .system(let system) = envelope,
                        case .topology(.worktreeUnregistered) = system.event
                    {
                        return true
                    }
                    return false
                }),
            replayWasTruncated: { false },
            classify: { envelope in
                recorded.append(envelope)
                return (0, envelope)
            })
    }

    func begin() async -> OpeningPosition<UInt64> { await facts.mark(0) }

    func nextChangeset() async throws -> FileChangeset {
        let envelope = try await facts.expectNext(
            in: 0, where: { Self.changeset($0) != nil }, "filesChanged")
        return try #require(Self.changeset(envelope))
    }

    func closeAfterProducerReturn() async throws {
        _ = await facts.mark(0)
        try await facts.finish()
    }

    var envelopes: [RuntimeEnvelope] { recorded.values }
    var changesets: [FileChangeset] { envelopes.compactMap(Self.changeset) }

    static func changeset(_ envelope: RuntimeEnvelope) -> FileChangeset? {
        guard case .worktree(let worktree) = envelope,
            case .filesystem(.filesChanged(let changeset)) = worktree.event
        else { return nil }
        return changeset
    }
}

private final class FilesystemDeliveredEnvelopes: Sendable {
    private let storage = Mutex<[RuntimeEnvelope]>([])
    var values: [RuntimeEnvelope] { storage.withLock { $0 } }
    func append(_ envelope: RuntimeEnvelope) { storage.withLock { $0.append(envelope) } }
}
