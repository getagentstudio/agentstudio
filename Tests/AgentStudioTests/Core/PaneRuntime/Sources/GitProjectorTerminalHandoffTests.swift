import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

private enum TerminalStatusScenario: Sendable, CaseIterable {
    case completed
    case equal
    case unavailable
}

@Suite("Git projector terminal handoff correlation")
struct GitProjectorTerminalHandoffTests {
    @Test("an old terminal post cannot close the replacement refresh", arguments: TerminalStatusScenario.allCases)
    fileprivate func replacementStaysOpen(scenario: TerminalStatusScenario) async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let terminalPost = HeldStep<RuntimeEnvelope>(
            "old refresh terminal post", cancellation: .holdThroughCancellation)
        let replacementRead = HeldStep<Void>("replacement status read", cancellation: .holdThroughCancellation)
        let warmupCount = scenario == .equal ? 1 : 0
        let poster = HeldTerminalEnvelopePoster(bus: bus, step: terminalPost, heldStatusOrdinal: warmupCount + 1)
        let attempts = Mutex(0)
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == warmupCount + 2 { try? await replacementRead.arrive(()) }
            if attempt == warmupCount + 1, scenario == .unavailable {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .providerReturnedNil))
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main", origin: nil
                )
            )
        })
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            refreshPolicy: .init(), factSink: source.sink, runtimeEnvelopePoster: poster
        )
        await projector.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-terminal-handoff-\(worktreeId.uuidString)")
        await projector.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        if warmupCount == 1 {
            _ = await bus.post(changedEnvelope(sequence: 1, worktreeId: worktreeId, rootPath: rootPath))
            _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
            await projector.grantDemandEligibility(worktreeId: worktreeId)
        }

        _ = await bus.post(changedEnvelope(sequence: 2, worktreeId: worktreeId, rootPath: rootPath))
        _ = try await terminalPost.firstArrival()
        let firstSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeId)
        let firstTask = try #require(await projector.worktreeTasks[worktreeId])
        _ = await bus.post(
            RuntimeEnvelope.system(
                SystemEnvelope.test(
                    event: .topology(.worktreeUnregistered(worktreeId: worktreeId, repoId: worktreeId)),
                    source: .builtin(.filesystemWatcher), seq: 3
                )
            )
        )
        #expect(try await facts.expectHandledEnvelope(seq: 3) == .routed)
        await projector.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        _ = await bus.post(
            RuntimeEnvelope.system(
                SystemEnvelope.test(
                    event: .topology(
                        .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
                    ),
                    source: .builtin(.filesystemWatcher), seq: 4
                )
            )
        )
        _ = try await replacementRead.firstArrival()
        let secondSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeId)
        let secondScope = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: secondSequence)

        terminalPost.release()
        await firstTask.value

        #expect(await projector.openRefreshFactScopeByWorktreeId[worktreeId] == secondScope)
        #expect(
            try await facts.expectRefreshClosed(worktreeId: worktreeId, requestSequence: firstSequence) == .superseded
        )
        replacementRead.release()
        #expect(
            try await facts.expectRefreshClosed(worktreeId: worktreeId, requestSequence: secondSequence)
                == .completed(snapshotChanged: true, branchChanged: false)
        )
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    private func changedEnvelope(sequence: UInt64, worktreeId: UUID, rootPath: URL) -> RuntimeEnvelope {
        .worktree(
            WorktreeEnvelope.test(
                event: .filesystem(
                    .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath,
                            paths: ["file.txt"], timestamp: ContinuousClock().now, batchSeq: sequence
                        )
                    )
                ),
                repoId: worktreeId, worktreeId: worktreeId,
                source: .system(.builtin(.filesystemWatcher)), seq: sequence
            )
        )
    }
}

private final class HeldTerminalEnvelopePoster: RuntimeEnvelopePosting {
    private let bus: EventBus<RuntimeEnvelope>
    private let step: HeldStep<RuntimeEnvelope>
    private let heldStatusOrdinal: Int
    private let statusCount = Mutex(0)

    init(bus: EventBus<RuntimeEnvelope>, step: HeldStep<RuntimeEnvelope>, heldStatusOrdinal: Int) {
        self.bus = bus
        self.step = step
        self.heldStatusOrdinal = heldStatusOrdinal
    }

    func post(_ envelope: RuntimeEnvelope) async -> EventBus<RuntimeEnvelope>.PostResult {
        if case .worktree(let worktree) = envelope,
            case .gitWorkingDirectory(.statusOutcome) = worktree.event
        {
            let ordinal = statusCount.withLock { count -> Int in
                count += 1
                return count
            }
            if ordinal == heldStatusOrdinal { try? await step.arrive(envelope) }
        }
        return await bus.post(envelope)
    }
}
