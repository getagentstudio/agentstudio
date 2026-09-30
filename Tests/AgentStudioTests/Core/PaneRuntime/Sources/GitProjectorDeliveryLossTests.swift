import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Git projector lifetime loss consumption")
struct GitProjectorDeliveryLossTests {
    @Test("handling an envelope rejects an earlier drop instead of hiding it from shutdown")
    func earlierDropCannotDisappear() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        source.sink(.lifetime(1), .envelopesDropped(count: 3))
        source.sink(.lifetime(1), .envelopeHandled(seq: 4, disposition: .ignored))
        source.sink(.lifetime(1), .shutdownCompleted)

        await #expect(throws: UnexpectedFact.self) {
            try await facts.expectHandledEnvelope(seq: 4)
        }

        try await facts.finish()
    }

    @Test("a real newest-buffer replacement fails the envelope consumption helper")
    func realReplayDropCannotDisappear() async throws {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(capacityPerSource: 4, sourceKey: { $0.source.description })
        )
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            subscriptionBufferLimit: 1,
            factSink: source.sink
        )
        _ = await bus.post(contentsOf: (1...4).map { ignoredEnvelope(sequence: UInt64($0)) })
        await projector.start()

        await #expect(throws: UnexpectedFact.self) {
            try await facts.expectHandledEnvelope(seq: 4)
        }

        await projector.shutdown()
        try await facts.finish()
    }

    private func ignoredEnvelope(sequence: UInt64) -> RuntimeEnvelope {
        .system(
            SystemEnvelope.test(
                event: .topology(
                    .worktreeUnregistered(worktreeId: UUIDv7.generate(), repoId: UUIDv7.generate())
                ),
                source: .builtin(.gitWorkingDirectoryProjector),
                seq: sequence
            )
        )
    }
}
