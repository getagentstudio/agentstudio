import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@Suite("Git observation lifetime")
struct GitObservationLifetimeTests {
    @Test("a replacement lifetime reannounces an unchanged origin")
    func replacementLifetimeResetsOriginDeduplication() async {
        let fixture = GitLifetimeFixture()
        let recorder = GitLifetimeOriginGate()
        let harness = EventBusHarness<RuntimeEnvelope>()
        let events = await harness.makeSubscriber(policy: .criticalUnbounded)
        let projector = fixture.makeProjector(gate: recorder, bus: harness.bus)
        await projector.assertTopology(fixture.assertion(1))
        await RepositoryObservationRequestContext.$worktree.withValue(fixture.lifetime(1)) {
            _ = await projector.prepareRemoteReferenceCurrentStatus(fixture.status, changeset: fixture.changeset)
        }

        await projector.assertTopology(fixture.assertion(2))
        await RepositoryObservationRequestContext.$worktree.withValue(fixture.lifetime(2)) {
            _ = await projector.prepareRemoteReferenceCurrentStatus(fixture.status, changeset: fixture.changeset)
        }

        await assertEventuallyAsync("each lifetime receives its confirmed origin fact") {
            await events.count {
                guard case .worktree(let envelope) = $0,
                    case .gitWorkingDirectory(.originChanged) = envelope.event
                else { return false }
                return true
            } == 2
        }
        #expect(await recorder.receivedOrigins.count == 1)
        await projector.shutdown()
        await events.shutdown()
    }

    @Test("a completion resumed after origin validation cannot overwrite the replacement baseline")
    func delayedOriginValidationCannotRestoreRetiredBaseline() async {
        let fixture = GitLifetimeFixture()
        let gate = GitLifetimeOriginGate(suspendsFirst: true)
        let projector = fixture.makeProjector(gate: gate)
        await projector.assertTopology(fixture.assertion(1))
        let oldCompletion = Task {
            await RepositoryObservationRequestContext.$worktree.withValue(fixture.lifetime(1)) {
                await projector.handleAvailableStatusResult(
                    fixture.status,
                    materialized: .init(
                        result: .available(fixture.status), facts: .init(status: fixture.status),
                        detail: nil, refreshedDetail: false, capacityCompletionGeneration: nil),
                    changeset: fixture.changeset,
                    context: .init(computeStart: .now, scope: .full, pathspecCount: 0, refreshFactScope: nil)
                )
            }
        }
        await assertEventuallyAsync("old completion reaches origin authority") { await gate.hasSuspended }

        await projector.assertTopology(fixture.assertion(2))
        await gate.release()
        await oldCompletion.value

        #expect(await projector.lastAcceptedStatusFactsByWorktreeId[fixture.worktreeID] == nil)
        #expect(await projector.lastEmittedSnapshotByWorktreeId[fixture.worktreeID] == nil)
        await projector.shutdown()
    }
}

private struct GitLifetimeFixture: Sendable {
    let repositoryID = UUIDv7.generate()
    let worktreeID = UUIDv7.generate()
    let epoch = UUIDv7.generate()
    let path = URL(fileURLWithPath: "/tmp/git-lifetime-fixture")
    let status = GitWorkingTreeStatus(
        summary: .init(changed: 1, staged: 0, untracked: 0),
        branch: "main", origin: "https://example.com/org/lifetime.git")

    var changeset: FileChangeset {
        .init(
            worktreeId: worktreeID, repoId: repositoryID, rootPath: path, paths: [],
            containsGitInternalChanges: true, timestamp: .now, batchSeq: 100)
    }

    func lifetime(_ revision: UInt64) -> WorktreeObservationLifetime {
        .init(launchEpoch: epoch, revision: revision)
    }

    func assertion(_ revision: UInt64) -> FilesystemTopologyAssertion {
        .init(
            generation: revision, contextsByWorktreeId: [worktreeID: .init(repoId: repositoryID, rootPath: path)],
            repositoryLifetimes: [repositoryID: .init(launchEpoch: epoch, revision: revision)],
            worktreeLifetimes: [worktreeID: lifetime(revision)])
    }

    func makeProjector(gate: GitLifetimeOriginGate, bus: EventBus<RuntimeEnvelope> = EventBus<RuntimeEnvelope>())
        -> GitWorkingDirectoryProjector
    {
        GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil }, coalescingWindow: .zero,
            remoteReferenceOriginHandler: { _, origin, _ in await gate.receive(origin) })
    }
}

private actor GitLifetimeOriginGate {
    private let suspendsFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var receivedOrigins: [String?] = []
    private(set) var hasSuspended = false

    init(suspendsFirst: Bool = false) { self.suspendsFirst = suspendsFirst }

    func receive(_ origin: String?) async {
        receivedOrigins.append(origin)
        if suspendsFirst && receivedOrigins.count == 1 {
            await withCheckedContinuation {
                continuation = $0
                hasSuspended = true
            }
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
