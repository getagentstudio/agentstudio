import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("GitWorkingDirectoryProjector typed facts")
struct GitWorkingDirectoryProjectorFactTests {
    @Test("shutdown cancels registered visibility and filesystem coalescing deadlines")
    func shutdownClosesPendingCoalescingDeadlines() async throws {
        let clock = TestPushClock()
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .milliseconds(20),
            sleepClock: clock,
            factSink: source.sink
        )
        await projector.start()
        let visibleWorktreeId = UUIDv7.generate()
        let changingWorktreeId = UUIDv7.generate()
        let visibility = GitProjectorScope.deadline(
            worktreeId: visibleWorktreeId, kind: .visibilityCoalescing, generation: 1
        )
        let coalescing = GitProjectorScope.deadline(
            worktreeId: changingWorktreeId, kind: .coalescingWindow, generation: 1
        )

        await projector.setSidebarVisibleWorktrees([visibleWorktreeId])
        try await facts.expectNext(in: visibility, .deadlineRegistered(.visibilityCoalescing))
        let rootPath = URL(fileURLWithPath: "/tmp/projector-cancel-facts-\(changingWorktreeId.uuidString)")
        _ = await bus.post(
            fileChangedEnvelope(
                worktreeId: changingWorktreeId, rootPath: rootPath, batchSeq: 1
            ))
        try await facts.expectNext(in: coalescing, .deadlineRegistered(.coalescingWindow))

        await projector.shutdown()
        try await facts.expectNext(in: visibility, .deadlineDisposition(.cancelled))
        try await facts.expectNext(in: coalescing, .deadlineDisposition(.cancelled))
        #expect(clock.pendingSleepCount == 0)
        try await facts.finish()
    }

    @Test("visibility coalescing supersedes the old generation and admits the replacement")
    func visibilityCoalescingClosesEachGeneration() async throws {
        let clock = TestPushClock()
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            sleepClock: clock,
            factSink: source.sink
        )
        await projector.start()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let first = GitProjectorScope.deadline(
            worktreeId: firstWorktreeId, kind: .visibilityCoalescing, generation: 1
        )
        let second = GitProjectorScope.deadline(
            worktreeId: secondWorktreeId, kind: .visibilityCoalescing, generation: 2
        )

        await projector.setSidebarVisibleWorktrees([firstWorktreeId])
        try await facts.expectNext(in: first, .deadlineRegistered(.visibilityCoalescing))
        await projector.setSidebarVisibleWorktrees([secondWorktreeId])
        try await facts.expectNext(in: first, .deadlineDisposition(.obsolete))
        try await facts.expectNext(in: second, .deadlineRegistered(.visibilityCoalescing))
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
        try await facts.expectNext(in: second, .deadlineDisposition(.admitted))
        #expect(await projector.lastProcessedSidebarVisibleWorktreeIds == [secondWorktreeId])

        await projector.shutdown()
        try await facts.finish()
    }

    @Test("filesystem coalescing deadline admits the held batch after the controlled clock advances")
    func filesystemCoalescingClosesAtAdmission() async throws {
        let clock = TestPushClock()
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "coalesced", origin: nil
                )
            },
            coalescingWindow: .milliseconds(20),
            sleepClock: clock,
            factSink: source.sink
        )
        await projector.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-window-facts-\(worktreeId.uuidString)")
        let deadline = GitProjectorScope.deadline(
            worktreeId: worktreeId, kind: .coalescingWindow, generation: 1
        )

        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        try await facts.expectNext(in: deadline, .deadlineRegistered(.coalescingWindow))
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: .milliseconds(20))
        try await facts.expectNext(in: deadline, .deadlineDisposition(.admitted))
        let refresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 1)
        try await facts.expectNext(in: refresh, .refreshAdmitted)
        try await facts.expectNext(in: refresh, .refreshStarted)
        _ = try await facts.expectNext(
            in: refresh,
            where: {
                if case .refreshClosed(.completed(snapshotChanged: true, branchChanged: _)) = $0 { return true }
                return false
            }, "refresh completed after coalescing")
        #expect(await projector.lastEmittedSnapshotByWorktreeId[worktreeId]?.summary.changed == 1)

        await projector.shutdown()
        try await facts.finish()
    }

    @Test("a later filesystem batch closes the superseded intake while the first read is held")
    func heldReadCoalescesLaterIntake() async throws {
        let firstReadGate = HeldStep<Void>("first projector read")
        let calls = Mutex(0)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let attempt = calls.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 { try? await firstReadGate.arrive(()) }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: attempt, staged: 0, untracked: 0),
                branch: "coalesced", origin: nil
            )
        }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let output = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var outputIterator = output.makeAsyncIterator()
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-merge-facts-\(worktreeId.uuidString)")
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        _ = try await firstReadGate.firstArrival()
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 3))

        try await facts.expectNext(
            in: .intake(worktreeId: worktreeId, registration: 0, batchSeq: 2),
            .changesetCoalesced(into: 3)
        )
        #expect(await projector.pendingByWorktreeId[worktreeId]?.batchSeq == 3)
        firstReadGate.release()
        try await facts.expectNext(
            in: .intake(worktreeId: worktreeId, registration: 0, batchSeq: 3), .changesetAccepted
        )
        var publishedSnapshot: GitWorkingTreeSnapshot?
        while let event = await outputIterator.next() {
            guard case .worktree(let worktreeEnvelope) = event,
                case .gitWorkingDirectory(.snapshotChanged(let snapshot)) = worktreeEnvelope.event,
                snapshot.worktreeId == worktreeId
            else { continue }
            publishedSnapshot = snapshot
            break
        }
        #expect(publishedSnapshot?.summary.changed == 2)
        let firstRefresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 1)
        try await facts.expectNext(in: firstRefresh, .refreshAdmitted)
        try await facts.expectNext(in: firstRefresh, .refreshStarted)
        try await facts.expectNext(in: firstRefresh, .refreshClosed(.superseded))
        let secondRefresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 2)
        try await facts.expectNext(in: secondRefresh, .refreshAdmitted)
        try await facts.expectNext(in: secondRefresh, .refreshStarted)
        _ = try await facts.expectNext(
            in: secondRefresh,
            where: {
                if case .refreshClosed(.completed(snapshotChanged: true, branchChanged: _)) = $0 { return true }
                return false
            }, "second refresh completed")
        await projector.shutdown()
        try await facts.finish()
    }

    @Test("an empty filesystem batch closes as equal without a status read")
    func emptyIntakeDropsEqual() async throws {
        let calls = Mutex(0)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-empty-facts-\(worktreeId.uuidString)")
        let emptyBatch = FileChangeset(
            worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath,
            paths: [], timestamp: ContinuousClock().now, batchSeq: 1
        )
        _ = await bus.post(
            .worktree(
                WorktreeEnvelope.test(
                    event: .filesystem(.filesChanged(changeset: emptyBatch)),
                    repoId: worktreeId, worktreeId: worktreeId,
                    source: .system(.builtin(.filesystemWatcher)), seq: 1
                )))

        try await facts.expectNext(
            in: .intake(worktreeId: worktreeId, registration: 0, batchSeq: 1), .changesetDropped(.equal)
        )
        #expect(calls.withLock { $0 } == 0)
        await projector.shutdown()
        try await facts.finish()
    }

    @Test("capacity retry closes its episode when the fallback deadline rearms the read")
    func capacityFallbackClosesEpisode() async throws {
        let clock = TestPushClock()
        let calls = Mutex(0)
        let firstReadGate = HeldStep<Void>("capacity first read")
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let attempt = calls.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 {
                try? await firstReadGate.arrive(())
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .readCapacityExceeded))
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 2, staged: 0, untracked: 0),
                    branch: "capacity-recovered",
                    origin: nil
                ))
        })
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let output = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var outputIterator = output.makeAsyncIterator()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            capacityRetryBaseDelay: .milliseconds(50),
            capacityRetryJitterMaxDelay: .zero
        )
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            sleepClock: clock, refreshPolicy: policy, factSink: source.sink
        )
        await projector.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-capacity-facts-\(worktreeId.uuidString)")
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let refresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 1)
        try await facts.expectNext(in: refresh, .refreshAdmitted)
        try await facts.expectNext(in: refresh, .refreshStarted)
        _ = try await firstReadGate.firstArrival()
        #expect(calls.withLock { $0 } == 1)
        firstReadGate.release()

        let capacity = GitProjectorScope.capacity(worktreeId: worktreeId, episode: 1)
        try await facts.expectNext(in: capacity, .capacityRetryScheduled)
        let deadline = GitProjectorScope.deadline(worktreeId: worktreeId, kind: .capacityFallback, generation: 1)
        try await facts.expectNext(in: deadline, .deadlineRegistered(.capacityFallback))
        clock.advance(by: .milliseconds(50))
        try await facts.expectNext(in: capacity, .capacityRetryClosed(.expired))
        try await facts.expectNext(in: deadline, .deadlineDisposition(.admitted))

        var publishedSnapshot: GitWorkingTreeSnapshot?
        while let event = await outputIterator.next() {
            guard case .worktree(let worktreeEnvelope) = event,
                case .gitWorkingDirectory(.snapshotChanged(let snapshot)) = worktreeEnvelope.event,
                snapshot.worktreeId == worktreeId
            else { continue }
            publishedSnapshot = snapshot
            break
        }
        #expect(publishedSnapshot?.summary.changed == 2)
        try await facts.expectNext(in: refresh, .refreshAdmitted)
        try await facts.expectNext(in: refresh, .refreshStarted)
        _ = try await facts.expectNext(
            in: refresh,
            where: {
                if case .refreshClosed(.completed(snapshotChanged: true, branchChanged: _)) = $0 { return true }
                return false
            }, "capacity retry refresh completed")
        #expect(await projector.lastEmittedSnapshotByWorktreeId[worktreeId]?.summary.changed == 2)
        #expect(calls.withLock { $0 } == 2)
        await projector.shutdown()
        try await facts.finish()
    }

    @Test("failure backoff opens, reaches half-open, and closes after a successful retry")
    func failureBackoffClosesAfterRetry() async throws {
        let clock = TestPushClock()
        let calls = Mutex(0)
        let firstReadGate = HeldStep<Void>("backoff first read")
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let attempt = calls.withLock { count -> Int in
                count += 1
                return count
            }
            guard attempt > 1 else {
                try? await firstReadGate.arrive(())
                return nil
            }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "backoff-recovered", origin: nil
            )
        }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50)
        )
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            sleepClock: clock, refreshPolicy: policy, factSink: source.sink
        )
        await projector.start()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-backoff-facts-\(worktreeId.uuidString)")
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let firstRefresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 1)
        try await facts.expectNext(in: firstRefresh, .refreshAdmitted)
        try await facts.expectNext(in: firstRefresh, .refreshStarted)
        _ = try await firstReadGate.firstArrival()
        #expect(calls.withLock { $0 } == 1)
        firstReadGate.release()

        let backoff = GitProjectorScope.backoff(worktreeId: worktreeId, episode: 1)
        try await facts.expectNext(in: backoff, .backoffOpened(level: 1))
        try await facts.expectNext(in: firstRefresh, .refreshClosed(.unavailable))
        let deadline = GitProjectorScope.deadline(worktreeId: worktreeId, kind: .failure, generation: 1)
        try await facts.expectNext(in: deadline, .deadlineRegistered(.failure))
        clock.advance(by: .milliseconds(50))
        try await facts.expectNext(in: backoff, .backoffHalfOpen)
        try await facts.expectNext(in: backoff, .backoffClosed)
        let secondRefresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 2)
        try await facts.expectNext(in: secondRefresh, .refreshAdmitted)
        try await facts.expectNext(in: secondRefresh, .refreshStarted)
        _ = try await facts.expectNext(
            in: secondRefresh,
            where: {
                if case .refreshClosed(.completed(snapshotChanged: true, branchChanged: _)) = $0 { return true }
                return false
            }, "backoff retry refresh completed")
        #expect(await projector.lastEmittedSnapshotByWorktreeId[worktreeId]?.summary.changed == 1)
        #expect(calls.withLock { $0 } == 2)

        await projector.shutdown()
        try await facts.finish()
    }

    @Test("an unregistered automatic deadline closes obsolete after its clock advances")
    func obsoleteAutomaticDeadline() async throws {
        let clock = TestPushClock()
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            sleepClock: clock,
            factSink: source.sink
        )
        let worktreeId = UUIDv7.generate()
        let deadline = GitProjectorScope.deadline(worktreeId: worktreeId, kind: .automatic, generation: 1)

        await projector.setRefreshDeadline(.milliseconds(10), kind: .automatic, worktreeId: worktreeId)
        await projector.rescheduleDeadlineTask()
        try await facts.expectNext(in: deadline, .deadlineRegistered(.automatic))
        clock.advance(by: .milliseconds(10))
        try await facts.expectNext(in: deadline, .deadlineDisposition(.obsolete))
        #expect(await projector.automaticRefreshDeadlineByWorktreeId[worktreeId] == nil)

        await projector.shutdown()
        try await facts.finish()
    }

    @Test("shutdown closes the exact subscription lifetime after its joins")
    func shutdownClosesLifetime() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let projector = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            factSink: source.sink
        )

        await projector.start()
        let lifetime = await projector.subscriptionLifetime
        await projector.shutdown()
        source.end()

        try await facts.expectNext(in: .lifetime(lifetime), .shutdownCompleted)
        try await facts.finish()
    }

    @Test("a missing path opens one quarantine episode and rearm closes it")
    func quarantineClosesAfterPathRearm() async throws {
        let pathExists = Mutex(false)
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            factSink: source.sink,
            pathExistenceProbe: { _ in pathExists.withLock { $0 } }
        )
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-quarantine-\(worktreeId.uuidString)")
        await projector.start()
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let scope = GitProjectorScope.quarantine(worktreeId: worktreeId, episode: 1)
        try await facts.expectNext(in: scope, .quarantineOpened)
        #expect(await projector.quarantinedWorktreeIds.contains(worktreeId))
        pathExists.withLock { $0 = true }
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        try await facts.expectNext(in: scope, .quarantineClosed)
        #expect(await !projector.quarantinedWorktreeIds.contains(worktreeId))
        await projector.shutdown()
        try await facts.finish()
    }

    @Test("accepted intake and refresh close only after held status reaches the bus")
    func heldStatusClosesAfterPublication() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let statusGate = HeldStep<Void>("projector status provider")
        let provider = StubGitWorkingTreeStatusProvider { _ in
            try? await statusGate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "typed-facts",
                origin: nil
            )
        }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let output = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var outputIterator = output.makeAsyncIterator()
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()

        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/projector-facts-\(worktreeId.uuidString)")
        _ = await bus.post(fileChangedEnvelope(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        _ = try await statusGate.firstArrival()
        #expect(await projector.lastEmittedSnapshotByWorktreeId[worktreeId] == nil)

        statusGate.release()
        var publishedSnapshot: GitWorkingTreeSnapshot?
        while let event = await outputIterator.next() {
            guard case .worktree(let worktreeEnvelope) = event,
                case .gitWorkingDirectory(.snapshotChanged(let snapshot)) = worktreeEnvelope.event,
                snapshot.worktreeId == worktreeId
            else { continue }
            publishedSnapshot = snapshot
            break
        }
        #expect(publishedSnapshot?.summary.changed == 1)
        #expect(await projector.lastEmittedSnapshotByWorktreeId[worktreeId]?.summary.changed == 1)
        await projector.shutdown()
        source.end()

        try await facts.expectNext(
            in: .intake(worktreeId: worktreeId, registration: 0, batchSeq: 1), .changesetAccepted
        )
        let refresh = GitProjectorScope.refresh(worktreeId: worktreeId, requestSequence: 1)
        try await facts.expectNext(in: refresh, .refreshAdmitted)
        try await facts.expectNext(in: refresh, .refreshStarted)
        _ = try await facts.expectNext(
            in: refresh,
            where: {
                if case .refreshClosed(.completed(snapshotChanged: true, branchChanged: _)) = $0 {
                    return true
                }
                return false
            }, "refreshClosed(completed(snapshotChanged: true))")
        try await facts.finish()
    }

    private func fileChangedEnvelope(worktreeId: UUID, rootPath: URL, batchSeq: UInt64) -> RuntimeEnvelope {
        let changeset = FileChangeset(
            worktreeId: worktreeId,
            repoId: worktreeId,
            rootPath: rootPath,
            paths: ["tracked.txt"],
            timestamp: ContinuousClock().now,
            batchSeq: batchSeq
        )
        return .worktree(
            WorktreeEnvelope.test(
                event: .filesystem(.filesChanged(changeset: changeset)),
                repoId: worktreeId,
                worktreeId: worktreeId,
                source: .system(.builtin(.filesystemWatcher)),
                seq: batchSeq
            )
        )
    }
}
