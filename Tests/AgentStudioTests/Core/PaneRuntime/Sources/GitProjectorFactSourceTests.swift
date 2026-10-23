import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Git projector fact-source termination")
struct GitProjectorFactSourceTests {
    @Test("owner shutdown terminates the fact source before any refresh is admitted")
    func shutdownTerminatesSourceBeforeAdmission() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            sleepClock: TestPushClock(),
            factSink: source.sink
        )
        await projector.start()
        await projector.shutdown()
        try await facts.expectNext(in: .lifetime(1), .shutdownCompleted)

        // A different scope distinguishes source termination from lifetime closure.
        source.sink(.refresh(worktreeId: UUIDv7.generate(), requestSequence: 1), .refreshAdmitted)
        await #expect(throws: FactAfterSourceTerminated.self) { try await facts.finish() }
    }

    @Test("subscription retirement ends refresh discovery with a named source failure")
    func retirementEndsRefreshDiscoveryBeforeAdmission() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            sleepClock: TestPushClock(),
            factSink: source.sink
        )
        await projector.start()
        await projector.subscriptionStreamDidEnd(lifetime: 1)

        await #expect(throws: SourceEnded.self) {
            try await source.expectNextRefreshClosed(facts: facts, worktreeId: UUIDv7.generate())
        }
        await projector.shutdown()
        try await facts.expectNext(in: .lifetime(1), .shutdownCompleted)
        try await facts.finish()
    }
}
