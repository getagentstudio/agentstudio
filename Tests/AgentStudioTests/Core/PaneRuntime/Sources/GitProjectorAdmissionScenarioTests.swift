import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

private enum FullStatusInvalidationReason: Sendable, CaseIterable {
    case gitInternal
    case pathspecLimit
}

@Suite("Git projector admitted scenario boundaries")
struct GitProjectorAdmissionScenarioTests {
    @Test("age priority selects the older root when both candidates are already pending")
    func oldestPendingRootWinsOverYoungerUUID() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let runningRoot = URL(fileURLWithPath: "/tmp/priority-running-\(UUIDv7.generate())")
        let olderRoot = URL(fileURLWithPath: "/tmp/priority-older-\(UUIDv7.generate())")
        let youngerRoot = URL(fileURLWithPath: "/tmp/priority-younger-\(UUIDv7.generate())")
        let runningRead = HeldStep<Void>("running priority slot", cancellation: .holdThroughCancellation)
        let nextRead = HeldStep<URL>("first selected pending root", cancellation: .holdThroughCancellation)
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            if rootPath == runningRoot {
                try? await runningRead.arrive(())
            } else {
                try? await nextRead.arrive(rootPath)
            }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main", origin: nil
            )
        }
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            refreshPolicy: .init(backgroundStripeCount: 1, maxConcurrentStatusComputes: 1),
            factSink: source.sink
        )
        let runningId = UUIDv7.generate()
        let sortedCandidateIds = [UUIDv7.generate(), UUIDv7.generate()].sorted { $0.uuidString < $1.uuidString }
        let youngerId = sortedCandidateIds[0]
        let olderId = sortedCandidateIds[1]
        #expect(youngerId.uuidString < olderId.uuidString)
        await projector.start()
        await bus.post(changedEnvelope(sequence: 1, worktreeId: runningId, rootPath: runningRoot, paths: ["file.txt"]))
        try await runningRead.firstArrival()
        await bus.post(changedEnvelope(sequence: 2, worktreeId: olderId, rootPath: olderRoot, paths: ["file.txt"]))
        await bus.post(changedEnvelope(sequence: 3, worktreeId: youngerId, rootPath: youngerRoot, paths: ["file.txt"]))

        #expect(try await facts.expectHandledEnvelope(seq: 3) == .routed)
        #expect(await projector.pendingByWorktreeId[olderId] != nil)
        #expect(await projector.pendingByWorktreeId[youngerId] != nil)
        runningRead.release()
        let selectedRoot = try await nextRead.firstArrival()
        #expect(selectedRoot == olderRoot)

        nextRead.release()
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    @Test(
        "git internals and pathspec overflow choose full status after an accepted baseline",
        arguments: FullStatusInvalidationReason.allCases
    )
    fileprivate func acceptedBaselineStillRequiresFullStatus(reason: FullStatusInvalidationReason) async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let pathspecCalls = Mutex<[[String]?]>([])
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            pathspecCalls.withLock { $0.append(pathspecs) }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main", origin: nil
                )
            )
        })
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: .init(backgroundStripeCount: 1, maxScopedStatusPathspecCount: 2),
            factSink: source.sink
        )
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/accepted-baseline-\(worktreeId)")
        await projector.start()
        await projector.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            RuntimeEnvelope.system(
                SystemEnvelope.test(
                    event: .topology(
                        .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)),
                    source: .builtin(.filesystemWatcher), seq: 1
                )
            )
        )

        #expect(
            try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
                == .completed(snapshotChanged: true, branchChanged: false)
        )
        #expect(await projector.lastStatusEntriesByWorktreeId[worktreeId]?.isEmpty == true)
        #expect(pathspecCalls.withLock { $0.count } == 1)
        let paths = reason == .gitInternal ? ["a.txt"] : ["a.txt", "b.txt", "c.txt"]
        await bus.post(
            changedEnvelope(
                sequence: 2, worktreeId: worktreeId, rootPath: rootPath,
                paths: paths, containsGitInternalChanges: reason == .gitInternal
            )
        )
        #expect(try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId) == .equal)
        let recordedPathspecs = pathspecCalls.withLock { $0 }
        #expect(recordedPathspecs.count == 2)
        #expect(recordedPathspecs.allSatisfy { $0 == nil })

        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    private func changedEnvelope(
        sequence: UInt64, worktreeId: UUID, rootPath: URL, paths: [String],
        containsGitInternalChanges: Bool = false
    ) -> RuntimeEnvelope {
        .worktree(
            WorktreeEnvelope.test(
                event: .filesystem(
                    .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath,
                            paths: paths, containsGitInternalChanges: containsGitInternalChanges,
                            timestamp: ContinuousClock().now, batchSeq: sequence
                        )
                    )
                ),
                repoId: worktreeId, worktreeId: worktreeId,
                source: .system(.builtin(.filesystemWatcher)), seq: sequence
            )
        )
    }
}
