import AgentStudioGit
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

// swiftlint:disable file_length type_body_length

@Suite("GitWorkingDirectoryProjector")
struct GitWorkingDirectoryProjectorTests {
    @Test("disabled performance recorder suppresses logical debt traces")
    func disabledPerformanceRecorderSuppressesLogicalDebtTraces() async {
        let recorder = GitProjectorTraceRecorderSpy(isEnabled: false)
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            performanceTraceRecorder: recorder
        )

        await actor.recordLogicalDebtSnapshotIfChanged()

        #expect(recorder.recordedAttributes(for: .gitLogicalDebt).isEmpty)
    }

    @Test("logical debt trace suppresses countdown-only changes")
    func logicalDebtTraceSuppressesCountdownOnlyChanges() async {
        let recorder = GitProjectorTraceRecorderSpy()
        let clock = TestPushClock()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            sleepClock: clock,
            performanceTraceRecorder: recorder
        )
        let worktreeId = UUIDv7.generate()

        await actor.setRefreshDeadline(.seconds(60), kind: .automatic, worktreeId: worktreeId)
        await actor.recordLogicalDebtSnapshotIfChanged()
        clock.advance(by: .milliseconds(1))
        await actor.recordLogicalDebtSnapshotIfChanged()

        #expect(recorder.recordedAttributes(for: .gitLogicalDebt).count == 1)

        await actor.setRefreshDeadline(.seconds(30), kind: .automatic, worktreeId: worktreeId)
        await actor.recordLogicalDebtSnapshotIfChanged()

        #expect(recorder.recordedAttributes(for: .gitLogicalDebt).count == 2)
    }

    @Test("logical debt trace records failure backoff dequeue and re-admission transitions")
    func logicalDebtTraceRecordsFailureBackoffTransitions() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let traceRuntime = makeGitLogicalDebtTraceRuntime()
        let recorder = AgentStudioPerformanceTraceRecorder(
            traceRuntime: traceRuntime,
            processMemorySampleWait: { false }
        )
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callCount = await calls.increment()
            if callCount == 1 {
                return nil
            }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "retry-success",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                backgroundStripeCount: 1,
                maxConcurrentStatusComputes: 1,
                statusFailureBackoffBaseDelay: .milliseconds(50)
            ),
            performanceTraceRecorder: recorder,
            factSink: source.sink
        )
        await actor.start()

        let worktreeId = UUIDv7.generate()
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/git-logical-debt-trace-\(UUIDv7.generate().uuidString)"),
                batchSeq: 1
            )
        )
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        let retryScheduled = clock.pendingSleepCount == 1
        #expect(retryScheduled)
        clock.advance(by: .milliseconds(50))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(await calls.value() == 2)
        #expect(await actor.logicalDebtSnapshot().logicalDebtCount == 0)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await recorder.drain()
        let settlementRecords = try gitLogicalDebtTraceAttributes(from: traceRuntime)
        let debtCounts = settlementRecords.compactMap {
            $0["agentstudio.performance.git.logical_debt.count"] as? Int
        }
        #expect(debtCounts.first == 0)
        #expect(debtCounts.last == 0)
        #expect(debtCounts.contains(2))
        #expect(
            settlementRecords.contains {
                $0["agentstudio.performance.git.future_failure.count"] as? Int == 1
            })
        let observedOverdueRecords = settlementRecords.filter {
            ($0["agentstudio.performance.git.overdue_deadline.count"] as? Int ?? 0) > 0
        }
        #expect(
            observedOverdueRecords.allSatisfy {
                $0["agentstudio.performance.git.overdue_deadline.count"] as? Int == 1
                    && $0["agentstudio.performance.git.retry_pending.count"] as? Int == 1
                    && $0["agentstudio.performance.git.logical_running.count"] as? Int == 0
            })
        #expect(
            settlementRecords.last?["agentstudio.performance.git.overdue_deadline.count"] as? Int == 0
        )
    }

    @Test("real SDK provider emits initial git snapshot")
    func realSDKProviderEmitsInitialGitSnapshot() async throws {
        let repoURL = try await FilesystemTestGitRepo.create(named: "projector-real-sdk-provider")
        defer { FilesystemTestGitRepo.destroy(repoURL) }
        try "initial\n".write(to: repoURL.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repoURL, args: ["add", "tracked.txt"])
        try await FilesystemTestGitRepo.runGit(at: repoURL, args: ["commit", "-m", "Seed projector SDK"])
        try "initial\nupdated\n".write(to: repoURL.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)

        let bus = EventBus<RuntimeEnvelope>()
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        let gitLocalClient = AgentStudioGit.LibGit2AgentStudioGitLocalClient()
        let statusPhysicalGate = AgentStudioGitStatusPhysicalGate()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: AgentStudioGitWorkingTreeStatusProvider(
                slowObservationScheduler: PassiveGitStatusSlowObservationScheduler(),
                physicalGate: statusPhysicalGate,
                statusReader: { worktreePath, options in
                    try await gitLocalClient.completeStatus(for: worktreePath, options: options)
                }
            ),
            coalescingWindow: .zero
        )
        await actor.start()

        let worktreeId = UUID()
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: UUID(), rootPath: repoURL)
            )
        )

        var snapshot: GitWorkingTreeSnapshot?
        while let envelope = await iterator.next() {
            guard case .worktree(let worktreeEnvelope) = envelope else { continue }
            guard worktreeEnvelope.worktreeId == worktreeId else { continue }
            guard case .gitWorkingDirectory(.snapshotChanged(let emittedSnapshot)) = worktreeEnvelope.event else {
                continue
            }
            snapshot = emittedSnapshot
            break
        }
        #expect(snapshot?.rootPath == repoURL)
        #expect(snapshot?.branch == "main")
        #expect(snapshot?.summary.changed == 1)

        await actor.shutdown()
    }

    @Test("background registration waits for its deadline and active promotion runs promptly")
    func backgroundRegistrationWaitsUntilActivePromotion() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider(handler: { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/eager-\(UUID().uuidString)")
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await calls.value() == 0)
        #expect(await actor.pendingByWorktreeId[worktreeId] != nil)
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[worktreeId] != nil)
        let futureSettlement = await actor.logicalDebtSnapshot()
        #expect(futureSettlement.futureAutomaticCount == 1)
        #expect(futureSettlement.readyPendingCount == 0)
        #expect(futureSettlement.overdueDeadlineCount == 0)
        #expect(futureSettlement.nextDeadlineMilliseconds > 0)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [],
                containsGitInternalChanges: true
            )
        )

        let didReceiveSnapshot = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1
        #expect(didReceiveSnapshot)
        let snapshot = await observed.latestSnapshot(for: worktreeId)
        #expect(snapshot?.rootPath == rootPath)
        #expect(snapshot?.branch == "main")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("filesChanged triggers git snapshot fact")
    func filesChangedTriggersGitSnapshotFact() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 3, staged: 1, untracked: 2),
                branch: "feature/projector",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/git-status-actor-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        let didReceiveSnapshot = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1
        #expect(didReceiveSnapshot)

        let latestSnapshot = await observed.latestSnapshot(for: worktreeId)
        #expect(latestSnapshot?.summary.changed == 3)
        #expect(latestSnapshot?.summary.staged == 1)
        #expect(latestSnapshot?.summary.untracked == 2)
        #expect(latestSnapshot?.branch == "feature/projector")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("projector emits derived git facts with dedicated system source tag")
    func projectorEmitsWithDedicatedSystemSource() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )
        await actor.start()

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/source-tag-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        var observedDerivedSource: EventSource?
        var observedDerivedSnapshot: GitWorkingTreeSnapshot?
        for _ in 0..<20 {
            guard let envelope = await iterator.next() else { break }
            guard case .worktree(let worktreeEnvelope) = envelope else { continue }
            guard case .gitWorkingDirectory(.snapshotChanged(let snapshot)) = worktreeEnvelope.event else { continue }
            observedDerivedSource = worktreeEnvelope.source
            observedDerivedSnapshot = snapshot
            break
        }

        #expect(observedDerivedSource == .system(.builtin(.gitWorkingDirectoryProjector)))
        let derivedSnapshot = try #require(observedDerivedSnapshot)
        #expect(derivedSnapshot.worktreeId == worktreeId)
        #expect(derivedSnapshot.branch == "main")
        await actor.shutdown()
    }

    @Test("provider nil status emits no git snapshot facts")
    func providerNilStatusEmitsNoGitSnapshotFacts() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let provider = StubGitWorkingTreeStatusProvider { _ in nil }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/provider-nil-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        // The unavailable outcome follows failure admission
        // (GitWorkingDirectoryProjector.swift:828–840); the controlled clock holds its retry.
        #expect((try await observed.expectStatusOutcomes(for: worktreeId, through: 1)).count == 1)
        await observed.markAcceptedOutputs()

        #expect(await observed.snapshotCount(for: worktreeId) == 0)
        #expect(await observed.branchEventCount(for: worktreeId) == 0)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("provider nil status retries through the shared failure backoff")
    func providerNilStatusRetriesOnceAfterBoundedBackoff() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50)
        )
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callNumber = await calls.increment()
            guard callNumber > 1 else { return nil }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 2, staged: 0, untracked: 0),
                branch: "retry-success",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/provider-nil-retry-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        let firstAttemptCompleted = (await calls.count(until: { $0 == 1 })) == 1
        #expect(firstAttemptCompleted)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        let retryScheduled = clock.pendingSleepCount > 0
        #expect(retryScheduled)
        guard retryScheduled else {
            await actor.shutdown()
            try await collectionTask.finish()
            return
        }
        #expect(await observed.snapshotCount(for: worktreeId) == 0)
        // The unavailable outcome is emitted after backoff debt opens
        // (GitWorkingDirectoryProjector.swift:828–840).
        #expect((try await observed.expectStatusOutcomes(for: worktreeId, through: 1)).count == 1)
        let breakerDebt = await actor.logicalDebtSnapshot()
        #expect(breakerDebt.retryPendingCount == 1)
        #expect(breakerDebt.logicalPendingCount == 1)
        #expect(breakerDebt.logicalRunningCount == 0)
        #expect(breakerDebt.logicalDebtCount == 1)
        let failureSettlement = await actor.logicalDebtSnapshot()
        #expect(failureSettlement.futureFailureCount == 1)
        #expect(failureSettlement.readyPendingCount == 0)
        #expect(failureSettlement.overdueDeadlineCount == 0)

        clock.advance(by: .milliseconds(50))

        let retrySnapshots = try await observed.expectNextSnapshot(
            for: worktreeId, where: { $0.branch == "retry-success" }, "next snapshot")
        let retriedAndEmittedSnapshot = await calls.value() == 2 && retrySnapshots.last?.branch == "retry-success"
        #expect(retriedAndEmittedSnapshot)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(await actor.logicalDebtSnapshot().logicalDebtCount == 0)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("failure backoff skips when worktree context changes before delay")
    func failureBackoffSkipsWhenWorktreeContextChangesBeforeDelay() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let callOrder = CallOrderRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50)
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let label = rootPath.lastPathComponent
            await callOrder.record(label)
            guard label.contains("old-retry-root") == false else { return nil }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: label,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let oldRootPath = URL(fileURLWithPath: "/tmp/old-retry-root-\(UUID().uuidString)")
        let newRootPath = URL(fileURLWithPath: "/tmp/new-retry-root-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: oldRootPath)
            )
        )
        let oldNilAttemptCompleted =
            (await callOrder.labels(until: {
                $0.contains { $0.contains("old-retry-root") }
            })).contains { $0.contains("old-retry-root") }
        #expect(oldNilAttemptCompleted)
        let oldFailureDeadline = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: worktreeId, rootPath: newRootPath)
                ]
            )
        )
        let newContextSnapshotArrived =
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.rootPath == newRootPath }, "next snapshot")).last?.rootPath
            == newRootPath
        #expect(newContextSnapshotArrived)

        clock.advance(by: .milliseconds(50))
        try await facts.expectNext(in: oldFailureDeadline, .deadlineDisposition(.cancelled))
        await observed.markAcceptedOutputs()
        let labels = await callOrder.labels
        #expect(labels.filter { $0.contains("old-retry-root") }.count == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("same worktree rejects stale completion and emits the latest snapshot")
    func sameWorktreeRejectsStaleCompletionAndEmitsLatestSnapshot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callNumber = await calls.increment()
            try? await gate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main-\(callNumber)",
                origin: nil
            )
        }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(),
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/coalesce-\(UUID().uuidString)")

        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let firstStarted = (await calls.count(until: { $0 >= 1 })) >= 1
        #expect(firstStarted)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        await bus.post(makeFilesChangedEnvelope(seq: 3, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 3))
        // The third input has reached the projector before the held provider returns.
        #expect(try await facts.expectHandledEnvelope(seq: 3) == .routed)
        #expect(await actor.pendingByWorktreeId[worktreeId]?.batchSeq == 3)

        gate.release()

        let reachedLatestSnapshot =
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "main-2" }, "next snapshot"))
            .last?.branch == "main-2"
        #expect(reachedLatestSnapshot)
        #expect(await calls.value() >= 2)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        #expect(await observed.latestSnapshot(for: worktreeId)?.branch == "main-2")

        await actor.shutdown()
        try await collectionTask.finish()

    }

    @Test("ignored-only filesChanged event does not call git provider")
    func ignoredOnlyFilesChangedEventDoesNotCallGitProvider() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/ignored-only-\(UUID().uuidString)")
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [],
                suppressedIgnoredPathCount: 4
            )
        )

        try await facts.expectNext(
            in: .intake(worktreeId: worktreeId, registration: 0, batchSeq: 1), .changesetDropped(.equal)
        )
        await observed.markAcceptedOutputs()
        #expect(await calls.value() == 0)
        #expect(await observed.snapshotCount(for: worktreeId) == 0)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("identical snapshot result does not emit duplicate snapshot facts")
    func identicalSnapshotResultDoesNotEmitDuplicateSnapshotFacts() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(),
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/dedup-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let firstSnapshotArrived = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1
        #expect(firstSnapshotArrived)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        let equalRefresh = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(equalRefresh == .equal)
        await observed.markAcceptedOutputs()
        #expect(await calls.value() == 2)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("equal automatic facts reuse fresh line detail without another detail read")
    func equalAutomaticFactsReuseFreshLineDetail() async throws {
        let source = GitProjectorFactSource()
        let projectorFacts = try source.attach()
        let noDropsFrom = await projectorFacts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let factCalls = CallCounter()
        let detailCalls = CallCounter()
        let legacyCalls = CallCounter()
        let facts = Self.a2Facts(changed: 1, branch: "main", paths: ["tracked.txt"])
        let provider = A2FactDetailStatusProvider(
            legacyCallCounter: legacyCalls,
            factsHandler: { _, _ in
                _ = await factCalls.increment()
                return .available(facts)
            },
            detailHandler: { _ in
                _ = await detailCalls.increment()
                return .available(GitWorkingTreeLineDetail(linesAdded: 7, linesDeleted: 2))
            }
        )
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                lineDetailFreshnessInterval: .seconds(960)
            ),
            factSink: source.sink
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/a2-equal-facts-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [],
                containsGitInternalChanges: true
            )
        )
        _ = try await source.expectNextRefreshClosed(facts: projectorFacts, worktreeId: worktreeId)
        let equalRefresh = try await source.expectNextRefreshClosed(facts: projectorFacts, worktreeId: worktreeId)
        #expect(equalRefresh == .equal)
        await observed.markAcceptedOutputs()
        #expect(await factCalls.value() == 2)
        #expect(await actor.worktreeTasks[worktreeId] == nil)

        #expect(await detailCalls.value() == 1)
        #expect(await legacyCalls.value() == 0)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.linesAdded == 7)

        await actor.shutdown()
        try await projectorFacts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("fact success plus line detail failure retains the prior complete candidate")
    func detailFailureRetainsPriorCompleteCandidate() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let factCalls = CallCounter()
        let detailCalls = CallCounter()
        let legacyCalls = CallCounter()
        let initialFacts = Self.a2Facts(changed: 1, branch: "initial", paths: ["initial.txt"])
        let changedFacts = Self.a2Facts(changed: 2, branch: "changed", paths: ["initial.txt", "changed.txt"])
        let provider = A2FactDetailStatusProvider(
            legacyCallCounter: legacyCalls,
            factsHandler: { _, _ in
                let call = await factCalls.increment()
                return .available(call == 1 ? initialFacts : changedFacts)
            },
            detailHandler: { _ in
                let call = await detailCalls.increment()
                if call == 1 {
                    return .available(GitWorkingTreeLineDetail(linesAdded: 5, linesDeleted: 1))
                }
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .sdkError))
            }
        )
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/a2-detail-failure-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "initial" }, "next snapshot"))
                .last?.branch
                == "initial")

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [],
                containsGitInternalChanges: true
            )
        )
        // The unavailable outcome follows failure admission
        // (GitWorkingDirectoryProjector.swift:828–840); the controlled clock holds its retry.
        #expect(
            (try await observed.expectStatusOutcomes(for: worktreeId, through: 2)).last == .unavailable
        )
        await observed.markAcceptedOutputs()
        #expect(await detailCalls.value() == 2)
        #expect(await actor.worktreeTasks[worktreeId] == nil)

        #expect(await legacyCalls.value() == 0)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        #expect(await observed.latestSnapshot(for: worktreeId)?.branch == "initial")
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.linesAdded == 5)
        #expect(await actor.lastAcceptedStatusFactsByWorktreeId[worktreeId] == initialFacts)
        #expect(
            await actor.lastAcceptedLineDetailByWorktreeId[worktreeId]
                == GitWorkingTreeLineDetail(linesAdded: 5, linesDeleted: 1)
        )

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("changed facts publish only after matching line detail completes")
    func changedFactsPublishOnlyAfterMatchingDetailCompletes() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let factCalls = CallCounter()
        let detailCalls = CallCounter()
        let detailStarted = AsyncReceipt()
        let detailGate = HeldStep<Void>("detailGate", cancellation: .holdThroughCancellation)
        let initialFacts = Self.a2Facts(changed: 1, branch: "initial", paths: ["initial.txt"])
        let changedFacts = Self.a2Facts(changed: 2, branch: "changed", paths: ["initial.txt", "changed.txt"])
        let provider = A2FactDetailStatusProvider(
            factsHandler: { _, _ in
                let call = await factCalls.increment()
                return .available(call == 1 ? initialFacts : changedFacts)
            },
            detailHandler: { _ in
                let call = await detailCalls.increment()
                if call == 1 {
                    return .available(GitWorkingTreeLineDetail(linesAdded: 3, linesDeleted: 1))
                }
                await detailStarted.signal()
                try? await detailGate.arrive(())
                return .available(GitWorkingTreeLineDetail(linesAdded: 13, linesDeleted: 8))
            }
        )
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/a2-complete-candidate-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "initial" }, "next snapshot"))
                .last?.branch
                == "initial")

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [],
                containsGitInternalChanges: true
            )
        )
        #expect(try await detailStarted.wait())

        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        #expect(await observed.latestSnapshot(for: worktreeId)?.branch == "initial")

        detailGate.release()
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "changed" }, "next snapshot"))
                .last?.branch
                == "changed")
        #expect(await detailCalls.value() == 2)
        #expect(await observed.snapshotCount(for: worktreeId) == 2)
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.linesAdded == 13)
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.linesDeleted == 8)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("newer invalidation supersedes stale detail completion and preserves pending scope")
    func newerInvalidationSupersedesStaleDetailAndPreservesPendingScope() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let initialFacts = Self.a2Facts(changed: 1, branch: "initial", paths: ["initial.txt"])
        let staleFacts = Self.a2Facts(changed: 1, branch: "stale", paths: ["older.txt"])
        let currentFacts = Self.a2Facts(
            changed: 2,
            branch: "current",
            paths: ["newer-one.txt", "newer-two.txt"]
        )
        let providerFixture = A2StaleDetailProviderFixture(
            initialFacts: initialFacts,
            staleFacts: staleFacts,
            currentFacts: currentFacts
        )
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: providerFixture.provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/a2-stale-detail-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "initial" }, "next snapshot"))
                .last?.branch
                == "initial")
        let initialDetailAcceptedAt = try #require(
            await actor.lastAcceptedLineDetailAtByWorktreeId[worktreeId]
        )

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: ["older.txt"]
            )
        )
        #expect(try await providerFixture.staleDetailStarted.wait())
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 3,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 2,
                paths: ["newer-one.txt"]
            )
        )
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 4,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 3,
                paths: ["newer-two.txt"]
            )
        )
        // The replacement paths are retained while line detail is held.
        #expect(try await facts.expectHandledEnvelope(seq: 4) == .routed)
        #expect(
            await actor.pendingByWorktreeId[worktreeId].map { Set($0.paths) }
                == ["newer-one.txt", "newer-two.txt"]
        )

        providerFixture.staleDetailGate.release()
        #expect(try await providerFixture.currentDetailStarted.wait())

        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        #expect(await observed.latestSnapshot(for: worktreeId)?.branch == "initial")
        #expect(
            Set(await providerFixture.pathspecRecorder.lastPathspecs ?? [])
                == ["newer-one.txt", "newer-two.txt"]
        )
        #expect(await actor.lastAcceptedStatusFactsByWorktreeId[worktreeId] == initialFacts)
        #expect(
            await actor.lastAcceptedLineDetailByWorktreeId[worktreeId]
                == GitWorkingTreeLineDetail(linesAdded: 1, linesDeleted: 0)
        )
        #expect(await actor.lastAcceptedLineDetailAtByWorktreeId[worktreeId] == initialDetailAcceptedAt)

        providerFixture.currentDetailGate.release()
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "current" }, "next snapshot"))
                .last?.branch
                == "current")
        #expect(await observed.snapshotCount(for: worktreeId) == 2)
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.linesAdded == 30)
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.linesDeleted == 15)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("non-zero coalescing window merges rapid same-worktree bursts into one compute")
    func nonZeroCoalescingWindowMergesRapidBursts() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .milliseconds(60),
            sleepClock: clock,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/window-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .coalescingWindow
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        let coalescingSleepScheduled = clock.pendingSleepCount > 0
        #expect(coalescingSleepScheduled)
        clock.advance(by: .milliseconds(60))

        let didEmitSnapshot = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1
        #expect(didEmitSnapshot)

        await actor.shutdown()
        try await collectionTask.finish()

        #expect(await calls.value() == 1)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)
    }

    @Test("fixed coalescing window does not reset when a newer batch arrives")
    func fixedCoalescingWindowDoesNotResetForNewerBatch() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .milliseconds(500),
            sleepClock: clock,
            factSink: source.sink
        )

        await actor.start()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/fixed-window-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .coalescingWindow
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        clock.advance(by: .milliseconds(400))
        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        // The second input has reached the projector inside the coalescing window.
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        #expect(await actor.pendingByWorktreeId[worktreeId]?.batchSeq == 2)

        clock.advance(by: .milliseconds(100))
        let computeCompletedAtOriginalDeadline = (await calls.count(until: { $0 == 1 })) == 1
        #expect(computeCompletedAtOriginalDeadline)

        await actor.shutdown()
    }

    @Test("coalescing preserves affected paths from the pending batch it replaces")
    func coalescingPreservesAffectedPathsFromReplacedPendingBatch() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let recorder = PathspecRecorder()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .milliseconds(500),
            sleepClock: clock,
            refreshPolicy: AppPolicies.GitRefresh.Policy(),
            factSink: source.sink
        )

        await actor.start()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/coalescing-path-union-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 1 })).count == 1)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(await actor.lastStatusEntriesByWorktreeId[worktreeId] != nil)

        let coalescingDeadline = clock.now.advanced(by: .milliseconds(500))
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: ["a.txt"]
            )
        )
        // The registration baseline used task generation one; this batch uses two.
        try await facts.expectNext(
            in: .deadline(worktreeId: worktreeId, kind: .coalescingWindow, generation: 2),
            .deadlineRegistered(.coalescingWindow)
        )
        #expect(clock.pendingSleepDeadlines.contains(coalescingDeadline))
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 3,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 2,
                paths: ["b.txt"]
            )
        )
        // Missing fact: replacement pending batch accepted before coalescing fires.
        #expect(try await facts.expectHandledEnvelope(seq: 3) == .routed)
        #expect(await actor.pendingByWorktreeId[worktreeId]?.batchSeq == 2)

        clock.advance(by: .milliseconds(500))
        #expect((await recorder.recordedCalls(until: { $0.count == 2 })).count == 2)
        let lastPathspecs = await recorder.lastPathspecs
        #expect(lastPathspecs == ["a.txt", "b.txt"])

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
    }

    @Test("foreground registration bypasses filesystem-derived coalescing")
    func foregroundRegistrationBypassesFilesystemDerivedCoalescing() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "startup",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .milliseconds(500),
            sleepClock: clock
        )

        await actor.start()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/startup-bypass-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )

        let registrationComputedWithoutClockAdvance = (await calls.count(until: { $0 == 1 })) == 1
        #expect(registrationComputedWithoutClockAdvance)

        await actor.shutdown()
    }

    @Test("independent worktrees run independently")
    func independentWorktreesRunIndependently() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            try? await gate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 2, staged: 1, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let firstWorktreeId = UUID()
        let secondWorktreeId = UUID()
        await actor.setActivePaneWorktree(worktreeId: firstWorktreeId)
        await actor.setSidebarVisibleWorktrees([secondWorktreeId])
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 1,
                worktreeId: firstWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/parallel-a-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: secondWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/parallel-b-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )

        let bothStarted = (await calls.count(until: { $0 >= 2 })) >= 2
        #expect(bothStarted)

        gate.release()
        let firstSnapshots = try await observed.expectSnapshots(for: firstWorktreeId, through: 1)
        let secondSnapshots = try await observed.expectSnapshots(for: secondWorktreeId, through: 1)
        let bothProducedSnapshots = firstSnapshots.count >= 1 && secondSnapshots.count >= 1
        #expect(bothProducedSnapshots)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("automatic admission preserves one foreground slot inside the global budget")
    func automaticAdmissionPreservesForegroundSlot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let calls = CallCounter()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 2,
            backgroundMaxConcurrent: 2
        )
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            try? await gate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeIds = (0..<6).map { _ in UUID() }
        for (offset, worktreeId) in worktreeIds.enumerated() {
            await bus.post(
                makeFilesChangedEnvelope(
                    seq: UInt64(offset + 1),
                    worktreeId: worktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/admission-\(offset)-\(UUID().uuidString)"),
                    batchSeq: 1
                )
            )
        }

        let automaticBudget = policy.maxConcurrentStatusComputes - policy.activePaneMaxConcurrent
        let admittedInitialBudget = (await calls.count(until: { $0 >= automaticBudget })) >= automaticBudget
        #expect(admittedInitialBudget)
        // Missing fact: all six admitted inputs have reached held or queued work.
        #expect(try await facts.expectHandledEnvelope(seq: 6) == .routed)
        #expect(await actor.logicalDebtSnapshot().logicalDebtCount == worktreeIds.count)
        #expect(await calls.value() == automaticBudget)
        let boundedDebtSnapshot = await actor.logicalDebtSnapshot()
        #expect(boundedDebtSnapshot.logicalPendingCount == 5)
        #expect(boundedDebtSnapshot.logicalRunningCount == 1)
        #expect(boundedDebtSnapshot.logicalDebtCount == 6)
        #expect(boundedDebtSnapshot.readyPendingCount == 5)
        #expect(boundedDebtSnapshot.activeFollowUpCount == 0)

        gate.release()
        let drainedAllQueuedWork = (await calls.count(until: { $0 == worktreeIds.count })) == worktreeIds.count
        #expect(drainedAllQueuedWork)

        var emittedAllSnapshots = true
        for worktreeId in worktreeIds {
            let snapshots = try await observed.expectSnapshots(for: worktreeId, through: 1)
            emittedAllSnapshots = emittedAllSnapshots && snapshots.count == 1
        }
        #expect(emittedAllSnapshots)
        for worktreeId in worktreeIds {
            _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        }
        let settledDebt = await actor.logicalDebtSnapshot()
        #expect(settledDebt.logicalPendingCount == 0)
        #expect(settledDebt.logicalRunningCount == 0)
        #expect(settledDebt.logicalDebtCount == 0)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("failure backoff releases admission slot during delay")
    func failureBackoffReleasesAdmissionSlotDuringDelay() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let callOrder = CallOrderRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50)
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let label = rootPath.lastPathComponent
            await callOrder.record(label)
            guard label.contains("retry-sleeper") == false else { return nil }
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: label,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let retryWorktreeId = UUID()
        let healthyWorktreeId = UUID()
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 1,
                worktreeId: retryWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/retry-sleeper-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        let retryAttemptCompleted = (await callOrder.labels(until: { $0.count == 1 })).count == 1
        #expect(retryAttemptCompleted)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: retryWorktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        let retryBackoffScheduled = clock.pendingSleepCount > 0
        #expect(retryBackoffScheduled)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: healthyWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/healthy-after-nil-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )

        let healthyWorktreeAdmittedBeforeRetryDelay =
            (await callOrder.labels(until: {
                $0.contains { $0.contains("healthy-after-nil") }
            })).contains { $0.contains("healthy-after-nil") }
        #expect(healthyWorktreeAdmittedBeforeRetryDelay)
        let healthySnapshotObserved =
            (try await observed.expectSnapshots(for: healthyWorktreeId, through: 1)).count == 1
        #expect(healthySnapshotObserved)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("reserved oldest stale slot admits background work ahead of younger UUID")
    func reservedOldestStaleSlotAdmitsBackgroundWorkAheadOfYoungerUUID() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let callOrder = CallOrderRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 1,
            activePaneMaxConcurrent: 1
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let label = rootPath.lastPathComponent
            await callOrder.record(label)
            try? await gate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: label,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: policy
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let runningWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let olderBackgroundWorktreeId = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let youngerBackgroundWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 1,
                worktreeId: runningWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/running-slot-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        let firstCallStarted = (await callOrder.labels(until: { $0.count == 1 })).count == 1
        #expect(firstCallStarted)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: olderBackgroundWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/old-background-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 3,
                worktreeId: youngerBackgroundWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/young-background-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )

        gate.release()
        let secondCallArrived = (await callOrder.labels(until: { $0.count >= 2 })).count >= 2
        #expect(secondCallArrived)
        let labels = await callOrder.labels
        #expect(labels.dropFirst().first?.contains("old-background") == true)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("active pane pending work gets the reserved admission slot ahead of older background work")
    func activePanePendingWorkGetsReservedAdmissionSlot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 4,
            activePaneMaxConcurrent: 1,
            backgroundMaxConcurrent: 4
        )
        let callGate = OneByOneStatusGate(maximumHeldCalls: policy.maxConcurrentStatusComputes)
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let label = rootPath.lastPathComponent
            await callGate.recordAndWait(label)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: label,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: policy
        )
        await actor.start()

        let runningWorktreeIds = (0..<policy.maxConcurrentStatusComputes).map { _ in UUID() }
        for (offset, worktreeId) in runningWorktreeIds.enumerated() {
            await bus.post(
                makeFilesChangedEnvelope(
                    seq: UInt64(offset + 1),
                    worktreeId: worktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/foreground-running-\(offset)-\(UUID().uuidString)"),
                    batchSeq: 1
                )
            )
        }
        let automaticBudget = policy.maxConcurrentStatusComputes - policy.activePaneMaxConcurrent
        #expect((try await callGate.labels(through: automaticBudget)).count == automaticBudget)

        let olderBackgroundWorktreeId = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let activePaneWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let youngerBackgroundWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        await actor.setActivePaneWorktree(worktreeId: activePaneWorktreeId)
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 10,
                worktreeId: olderBackgroundWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/older-background-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 11,
                worktreeId: activePaneWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/active-pane-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 12,
                worktreeId: youngerBackgroundWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/younger-background-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )

        let foregroundUsedReservedSlot =
            (try await callGate.labels(through: policy.maxConcurrentStatusComputes)).count
            == policy.maxConcurrentStatusComputes
        #expect(foregroundUsedReservedSlot)
        let labels = await callGate.labels
        #expect(labels.dropFirst(automaticBudget).first?.contains("active-pane") == true)

        await callGate.releaseAll()
        await actor.shutdown()
    }

    @Test("lower-tier automatic work never consumes the proactive foreground reserve")
    func lowerTierAutomaticWorkPreservesForegroundReserve() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 4,
            activePaneMaxConcurrent: 1,
            backgroundMaxConcurrent: 4
        )
        let callGate = OneByOneStatusGate(maximumHeldCalls: policy.maxConcurrentStatusComputes)
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let label = rootPath.lastPathComponent
            await callGate.recordAndWait(label)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: label,
                origin: nil
            )
        }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: policy,
            factSink: source.sink
        )
        await actor.start()

        let runningWorktreeIds = (0..<policy.maxConcurrentStatusComputes).map { _ in UUID() }
        for (offset, worktreeId) in runningWorktreeIds.enumerated() {
            await bus.post(
                makeFilesChangedEnvelope(
                    seq: UInt64(offset + 1),
                    worktreeId: worktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/fallback-running-\(offset)-\(UUID().uuidString)"),
                    batchSeq: 1
                )
            )
        }
        let automaticBudget = policy.maxConcurrentStatusComputes - policy.activePaneMaxConcurrent
        #expect((try await callGate.labels(through: automaticBudget)).count == automaticBudget)

        await actor.setActivePaneWorktree(worktreeId: UUID())
        let olderBackgroundWorktreeId = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let youngerBackgroundWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 10,
                worktreeId: olderBackgroundWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/fallback-old-background-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 11,
                worktreeId: youngerBackgroundWorktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/fallback-young-background-\(UUID().uuidString)"),
                batchSeq: 1
            )
        )

        // Missing fact: both background changesets have entered the held queue.
        #expect(try await facts.expectHandledEnvelope(seq: 11) == .routed)
        #expect(await actor.pendingByWorktreeId[olderBackgroundWorktreeId] != nil)
        #expect(await actor.pendingByWorktreeId[youngerBackgroundWorktreeId] != nil)
        #expect(await callGate.labels.count == automaticBudget)
        #expect(await actor.pendingByWorktreeId[olderBackgroundWorktreeId] != nil)
        #expect(await actor.pendingByWorktreeId[youngerBackgroundWorktreeId] != nil)

        await callGate.releaseAll()
        await actor.shutdown()
    }

    @Test("background registrations use stable phased deadlines")
    func backgroundRegistrationsUseStablePhasedDeadlines() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(120),
            visibleSidebarCadence: .milliseconds(120),
            openPaneCadence: .milliseconds(120),
            backgroundCadence: .milliseconds(120),
            backgroundStripeCount: 2,
            maxConcurrentStatusComputes: 4
        )
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callNumber = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let firstStripeWorktreeId = worktreeId(forBackgroundStripe: 0, policy: policy)
        let secondStripeWorktreeId = worktreeId(forBackgroundStripe: 1, policy: policy)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: firstStripeWorktreeId,
                event: .worktreeRegistered(
                    worktreeId: firstStripeWorktreeId,
                    repoId: firstStripeWorktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/stripe-0-\(UUID().uuidString)")
                )
            )
        )
        await bus.post(
            makeEnvelope(
                seq: 2,
                worktreeId: secondStripeWorktreeId,
                event: .worktreeRegistered(
                    worktreeId: secondStripeWorktreeId,
                    repoId: secondStripeWorktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/stripe-1-\(UUID().uuidString)")
                )
            )
        )

        let firstStripeDeadline = clock.now.advanced(by: .milliseconds(60))
        let secondStripeDeadline = clock.now.advanced(by: .milliseconds(120))
        // Missing fact: both background stripe deadlines have been admitted.
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        let refreshDeadlines = await actor.automaticRefreshDeadlineByWorktreeId
        #expect(refreshDeadlines[firstStripeWorktreeId] == .milliseconds(60))
        #expect(refreshDeadlines[secondStripeWorktreeId] == .milliseconds(120))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: firstStripeWorktreeId, kind: .automatic
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(clock.pendingSleepDeadlines.contains(firstStripeDeadline))
        #expect(await observed.snapshotCount(for: firstStripeWorktreeId) == 0)
        #expect(await observed.snapshotCount(for: secondStripeWorktreeId) == 0)

        clock.advance(by: .milliseconds(60))
        #expect((try await observed.expectSnapshots(for: firstStripeWorktreeId, through: 1)).count == 1)
        #expect(await observed.snapshotCount(for: secondStripeWorktreeId) == 0)

        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: secondStripeWorktreeId, kind: .automatic
        )

        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(clock.pendingSleepDeadlines.contains(secondStripeDeadline))
        clock.advance(by: .milliseconds(60))
        #expect((try await observed.expectSnapshots(for: secondStripeWorktreeId, through: 1)).count == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("git status retains worktree attribution while admission telemetry is bounded")
    func gitStatusRetainsWorktreeAttributionWhileAdmissionTelemetryIsBounded() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let recorder = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(120),
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 4
        )
        let provider = StubGitWorkingTreeStatusProvider { _ in
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorder
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(
                    worktreeId: worktreeId,
                    repoId: worktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/git-telemetry-attribution-\(UUID().uuidString)")
                )
            )
        )

        let statusRecorded =
            !(await recorder.recordedAttributes(
                for: .gitStatusComputed, until: { !$0.isEmpty }
            )).isEmpty
        #expect(statusRecorded)

        let statusAttributes = try #require(recorder.recordedAttributes(for: .gitStatusComputed).first)
        #expect(statusAttributes["agentstudio.worktree.id"] == .string(worktreeId.uuidString))
        #expect(statusAttributes["agentstudio.performance.git.demand_class"] == .string("open_pane"))
        #expect(statusAttributes["agentstudio.performance.git.trigger_source"] == .string("registration"))
        #expect(statusAttributes["agentstudio.performance.git.cadence_tier"] == .string("open_pane"))
        #expect(statusAttributes["agentstudio.performance.git.admission_to_status.elapsed_ms"] != nil)
        #expect(recorder.recordedAttributes(for: .gitAdmission).isEmpty)
        #expect(recorder.recordedAttributes(for: .gitTick).isEmpty)

        await actor.shutdown()
        let aggregateSnapshot = try #require(recorder.gitAggregateSnapshots().first)
        #expect(aggregateSnapshot.admitted == 1)
        #expect(aggregateSnapshot.eventPosted >= 1)
        try await collectionTask.finish()
    }

    @Test(
        "active pane periodic refresh bypasses background stripe",
        arguments: [Duration.zero, .milliseconds(80)])
    func activePanePeriodicRefreshBypassesBackgroundStripe(completedDuty: Duration) async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let clockOrigin = clock.now
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(120),
            backgroundStripeCount: 2,
            maxConcurrentStatusComputes: 4
        )
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callNumber = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let activePaneWorktreeId = worktreeId(forBackgroundStripe: 0, policy: policy)
        let inactiveWorktreeId = worktreeId(
            forBackgroundStripe: 0,
            policy: policy,
            excluding: [activePaneWorktreeId]
        )
        let inactiveRootPath = URL(fileURLWithPath: "/tmp/inactive-stripe-\(UUID().uuidString)")
        await actor.setActivePaneWorktree(worktreeId: activePaneWorktreeId)
        await actor.setActivity(worktreeId: inactiveWorktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: activePaneWorktreeId,
                event: .worktreeRegistered(
                    worktreeId: activePaneWorktreeId,
                    repoId: activePaneWorktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/active-stripe-\(UUID().uuidString)")
                )
            )
        )
        await bus.post(
            makeEnvelope(
                seq: 2,
                worktreeId: inactiveWorktreeId,
                event: .worktreeRegistered(
                    worktreeId: inactiveWorktreeId,
                    repoId: inactiveWorktreeId,
                    rootPath: inactiveRootPath
                )
            )
        )

        let activeSnapshots = try await observed.expectSnapshots(for: activePaneWorktreeId, through: 1)
        let inactiveSnapshots = try await observed.expectSnapshots(for: inactiveWorktreeId, through: 1)
        let initialSnapshotsArrived = activeSnapshots.count == 1 && inactiveSnapshots.count == 1
        #expect(initialSnapshotsArrived)
        await actor.setActivity(worktreeId: inactiveWorktreeId, isActiveInApp: false)

        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: activePaneWorktreeId)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: inactiveWorktreeId)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: activePaneWorktreeId, kind: .automatic
        )
        // Feed the existing completion owner a controlled physical duty. A
        // loaded runner may otherwise supply duty above the cadence floor.
        await actor.recordAutomaticCompletion(worktreeId: activePaneWorktreeId, duty: completedDuty)

        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: activePaneWorktreeId, kind: .automatic
        )
        let activeDeadline = try #require(await actor.automaticRefreshDeadlineByWorktreeId[activePaneWorktreeId])
        #expect(activeDeadline == max(policy.activePaneCadence, policy.automaticDutyGap(for: completedDuty)))

        // Absolute advancement also handles a rescheduled sleep that enters
        // the clock after this advance; no anonymous sleeper count is needed.
        clock.advance(to: clockOrigin.advanced(by: activeDeadline))
        let activeRefreshedOnNonMatchingBackgroundStripe =
            (try await observed.expectSnapshots(for: activePaneWorktreeId, through: 2)).count == 2
        #expect(activeRefreshedOnNonMatchingBackgroundStripe)
        #expect(await observed.snapshotCount(for: inactiveWorktreeId) == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("topology assertion recovers dropped registration envelope")
    func topologyAssertionRecoversDroppedRegistrationEnvelope() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "asserted",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/topology-assert-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: worktreeId, rootPath: rootPath)
                ]
            )
        )

        let assertionProducedSnapshot =
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "asserted" }, "next snapshot"))
            .last?.branch
            == "asserted"
        #expect(assertionProducedSnapshot)
        #expect(await calls.value() == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("registration followed by identical topology assertion is idempotent")
    func registrationFollowedByIdenticalTopologyAssertionIsIdempotent() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "registered",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/register-then-assert-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )

        let registrationSnapshotArrived =
            (try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1
        #expect(registrationSnapshotArrived)

        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: worktreeId, rootPath: rootPath)
                ]
            )
        )
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        await observed.markAcceptedOutputs()
        #expect(await calls.value() == 1)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("context change cancels in-flight compute before stale snapshot emit")
    func contextChangeCancelsInFlightComputeBeforeStaleSnapshotEmit() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let callOrder = CallOrderRecorder()
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let label = rootPath.lastPathComponent
            await callOrder.record(label)
            try? await gate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: label,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let oldRootPath = URL(fileURLWithPath: "/tmp/old-root-\(UUID().uuidString)")
        let newRootPath = URL(fileURLWithPath: "/tmp/new-root-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: oldRootPath)
            )
        )
        let oldComputeStarted =
            (await callOrder.labels(until: {
                $0.contains { $0.contains("old-root") }
            })).contains { $0.contains("old-root") }
        #expect(oldComputeStarted)

        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: worktreeId, rootPath: newRootPath)
                ]
            )
        )
        let newComputeStarted =
            (await callOrder.labels(until: {
                $0.contains { $0.contains("new-root") }
            })).contains { $0.contains("new-root") }
        #expect(newComputeStarted)

        gate.release()
        let newSnapshotArrived =
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.rootPath == newRootPath }, "next snapshot")).last?.rootPath
            == newRootPath
        #expect(newSnapshotArrived)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)
        #expect(await observed.statusOutcomeCount(for: worktreeId) == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("stale registration envelope after topology removal does not resurrect worktree")
    func staleRegistrationEnvelopeAfterTopologyRemovalDoesNotResurrectWorktree() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "stale",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/topology-stale-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeId: WorktreeFilesystemContext(repoId: worktreeId, rootPath: rootPath)
                ]
            )
        )
        let firstSnapshotArrived = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1
        #expect(firstSnapshotArrived)

        await actor.assertTopology(
            FilesystemTopologyAssertion(generation: 2, contextsByWorktreeId: [:])
        )
        await bus.post(
            makeEnvelope(
                seq: 10,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )

        #expect(try await facts.expectHandledEnvelope(seq: 10) == .ignored)
        await observed.markAcceptedOutputs()
        #expect(await calls.value() == 1)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("duplicate topology assertion is idempotent")
    func duplicateTopologyAssertionIsIdempotent() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "idempotent",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let assertion = FilesystemTopologyAssertion(
            generation: 1,
            contextsByWorktreeId: [
                worktreeId: WorktreeFilesystemContext(
                    repoId: worktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/topology-idempotent-\(UUID().uuidString)")
                )
            ]
        )
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await actor.assertTopology(assertion)
        let firstSnapshotArrived = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1
        #expect(firstSnapshotArrived)

        await actor.assertTopology(assertion)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        #expect(await actor.refreshAttribution.nextRequestSequence == 1)
        await observed.markAcceptedOutputs()
        #expect(await calls.value() == 1)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("worktree unregistration cancels and clears state")
    func worktreeUnregistrationCancelsAndClearsState() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let cancellationReceipt = AsyncReceipt()
        let providerReleaseReceipt = AsyncReceipt()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            await withTaskCancellationHandler {
                try? await gate.arrive(())
            } onCancel: {
                Task { await cancellationReceipt.signal() }
            }
            await providerReleaseReceipt.signal()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 4, staged: 0, untracked: 1),
                branch: "cleanup",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/cleanup-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let started = (await calls.count(until: { $0 >= 1 })) >= 1
        #expect(started)

        await bus.post(
            makeEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                event: .worktreeUnregistered(worktreeId: worktreeId, repoId: worktreeId)
            )
        )
        await bus.post(makeFilesChangedEnvelope(seq: 3, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))

        #expect(try await cancellationReceipt.wait())
        gate.release()
        #expect(try await providerReleaseReceipt.wait())

        #expect(await calls.value() == 1)
        #expect(await observed.snapshotCount(for: worktreeId) == 0)
        #expect(await observed.branchEventCount(for: worktreeId) == 0)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("shutdown while provider is in-flight does not emit stale snapshot")
    func shutdownWhileProviderIsInFlightDoesNotEmitStaleSnapshot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = HeldStep<Void>("gate", cancellation: .holdThroughCancellation)
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            try? await gate.arrive(())
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/shutdown-inflight-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        let started = (await calls.count(until: { $0 >= 1 })) >= 1
        #expect(started)

        let shutdownTask = Task {
            await actor.shutdown()
        }
        // Release the stale provider result only after shutdown has cancelled the in-flight call.
        try await gate.cancellationObserved()
        gate.release()
        await shutdownTask.value

        await observed.markAcceptedOutputs()
        #expect(await observed.snapshotCount(for: worktreeId) == 0)
        #expect(await observed.branchEventCount(for: worktreeId) == 0)

        try await collectionTask.finish()
    }

    @Test("branchChanged emits when consecutive snapshots change branch")
    func branchChangedEmitsWhenConsecutiveSnapshotsChangeBranch() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callNumber = await calls.increment()
            let branch = callNumber == 1 ? "main" : "feature/split"
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: branch,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/branch-change-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        let firstSnapshotObserved = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1
        #expect(firstSnapshotObserved)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))

        let branchEvents = try await observed.expectBranchEvents(for: worktreeId, through: 1)
        let branchEvent = try #require(branchEvents.last)
        #expect(branchEvent.0 == "main")
        #expect(branchEvent.1 == "feature/split")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("branchChanged emits when branchless snapshot becomes a branch")
    func branchChangedEmitsWhenBranchlessSnapshotBecomesBranch() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let callNumber = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: callNumber == 1 ? nil : "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/branchless-change-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        let firstSnapshotObserved = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1
        #expect(firstSnapshotObserved)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))

        let branchEvents = try await observed.expectBranchEvents(for: worktreeId, through: 1)
        let branchEvent = try #require(branchEvents.last)
        #expect(branchEvent.0.isEmpty)
        #expect(branchEvent.1 == "main")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("projector emits originChanged when origin differs from last known repo origin")
    func emitsOriginChangedWhenOriginChanges() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let repoId = UUID()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/origin-change-\(UUID().uuidString)")
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let call = await calls.increment()
            let origin = call == 1 ? "git@github.com:acme/repo.git" : "git@github.com:acme/repo-2.git"
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: origin
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
            )
        )

        let firstOriginEvent = (try await observed.expectOriginEvents(for: repoId, through: 1)).count == 1
        #expect(firstOriginEvent)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                repoId: repoId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [".git/config"]
            )
        )

        let emittedTwoOriginEvents = (try await observed.expectOriginEvents(for: repoId, through: 2)).count >= 2
        #expect(emittedTwoOriginEvents)
        let latestOrigin = await observed.latestOriginEvent(for: repoId)
        #expect(latestOrigin?.0 == "git@github.com:acme/repo.git")
        #expect(latestOrigin?.1 == "git@github.com:acme/repo-2.git")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("projector tracks origin per repo and suppresses duplicates across worktrees")
    func suppressesDuplicateOriginEventsAcrossWorktreesInSameRepo() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let repoId = UUID()
        let firstWorktreeId = UUID()
        let secondWorktreeId = UUID()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: "git@github.com:acme/repo.git"
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        await actor.setActivity(worktreeId: firstWorktreeId, isActiveInApp: true)
        await actor.setActivity(worktreeId: secondWorktreeId, isActiveInApp: true)

        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: firstWorktreeId,
                event: .worktreeRegistered(
                    worktreeId: firstWorktreeId,
                    repoId: repoId,
                    rootPath: URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)-a")
                )
            )
        )
        await bus.post(
            makeEnvelope(
                seq: 2,
                worktreeId: secondWorktreeId,
                event: .worktreeRegistered(
                    worktreeId: secondWorktreeId,
                    repoId: repoId,
                    rootPath: URL(fileURLWithPath: "/tmp/repo-\(UUID().uuidString)-b")
                )
            )
        )

        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: firstWorktreeId)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: secondWorktreeId)
        await observed.markAcceptedOutputs()
        #expect(await observed.originEventCount(for: repoId) == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("projector only emits originChanged for registration and git config changes")
    func onlyEmitsOriginChangedForRegistrationAndGitConfigChanges() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let repoId = UUID()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/origin-filter-\(UUID().uuidString)")
        let calls = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let call = await calls.increment()
            let origin = call == 1 ? "git@github.com:acme/repo.git" : "git@github.com:acme/repo-2.git"
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: origin
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(),
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
            )
        )
        let firstOriginEvent = (try await observed.expectOriginEvents(for: repoId, through: 1)).count == 1
        #expect(firstOriginEvent)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                repoId: repoId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: ["Sources/File.swift"]
            )
        )
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        await observed.markAcceptedOutputs()
        #expect(await calls.value() >= 2)
        #expect(await observed.originEventCount(for: repoId) == 1)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 3,
                worktreeId: worktreeId,
                repoId: repoId,
                rootPath: rootPath,
                batchSeq: 2,
                paths: [".git/config"]
            )
        )
        let secondOriginEvent = (try await observed.expectOriginEvents(for: repoId, through: 2)).count == 2
        #expect(secondOriginEvent)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("projector emits one initial empty origin event without locking retry state")
    func emitsInitialEmptyOriginEventWithoutLockingRetryState() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let repoId = UUID()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/origin-none-\(UUID().uuidString)")
        let callCounter = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await callCounter.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
            )
        )

        // First registration probes origin and emits exactly one local-origin signal.
        let initialOriginEvents = try await observed.expectOriginEvents(for: repoId, through: 1)
        let emittedInitialOriginSignal = await callCounter.value() >= 1 && initialOriginEvents.count == 1
        #expect(emittedInitialOriginSignal)
        let initialEvent = await observed.latestOriginEvent(for: repoId)
        #expect(initialEvent?.0.isEmpty == true)
        #expect(initialEvent?.1.isEmpty == true)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("projector retries origin discovery after initial empty result")
    func retriesOriginDiscoveryAfterInitialEmptyResult() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let repoId = UUID()
        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/origin-retry-\(UUID().uuidString)")
        let callCounter = CallCounter()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let call = await callCounter.increment()
            let origin = call >= 2 ? "git@github.com:acme/repo.git" : nil
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: origin
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
            )
        )

        let registrationOriginEvents = try await observed.expectOriginEvents(for: repoId, through: 1)
        let registrationProcessed = await callCounter.value() >= 1 && registrationOriginEvents.count == 1
        #expect(registrationProcessed)

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                repoId: repoId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [".git/config"]
            )
        )

        let emittedOriginAfterRetry = (try await observed.expectOriginEvents(for: repoId, through: 2)).count == 2
        #expect(emittedOriginAfterRetry)
        let event = await observed.latestOriginEvent(for: repoId)
        #expect(event?.0.isEmpty == true)
        #expect(event?.1 == "git@github.com:acme/repo.git")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("git internal-only filesChanged event still triggers git snapshot projection")
    func gitInternalOnlyFilesChangedEventStillTriggersSnapshot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/git-internal-only-\(UUID().uuidString)")
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [],
                containsGitInternalChanges: true,
                suppressedGitInternalPathCount: 2
            )
        )

        let didReceiveSnapshot = (try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1
        #expect(didReceiveSnapshot)
        let snapshot = await observed.latestSnapshot(for: worktreeId)
        #expect(snapshot?.worktreeId == worktreeId)
        #expect(snapshot?.branch == "main")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("capacity exceeded uses a fixed fallback without opening source failure")
    func capacityExceededUsesFixedFallbackWithoutSourceFailure() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .seconds(5),
            capacityRetryBaseDelay: .milliseconds(50),
            capacityRetryJitterMaxDelay: .zero
        )
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let callNumber = await calls.increment()
            guard callNumber > 1 else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .readCapacityExceeded))
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                    branch: "capacity-recovered",
                    origin: nil
                )
            )
        })
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorder,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/capacity-short-retry-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        #expect((await calls.count(until: { $0 == 1 })) == 1)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .capacityFallback
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        // Missing fact: a newer batch joined the held capacity retry.
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        #expect(await actor.pendingByWorktreeId[worktreeId]?.batchSeq == 2)
        #expect(await calls.value() == 1)
        #expect(recorder.backoffEvents(open: true).isEmpty)
        #expect(await actor.statusBackoffFailureCountByWorktreeId[worktreeId] == nil)
        #expect(await actor.consecutiveStatusFailureCountByWorktreeId[worktreeId] == nil)

        clock.advance(by: .milliseconds(49))
        #expect(await calls.value() == 1)

        clock.advance(by: .milliseconds(1))
        let retriedAfterCapacityDelay =
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.branch == "capacity-recovered" }, "next snapshot")).last?.branch
            == "capacity-recovered"
        #expect(retriedAfterCapacityDelay)
        #expect(await calls.value() == 2)
        #expect(recorder.backoffEvents(open: false).isEmpty)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("physical completion wakes capacity deferral without clock advance")
    func physicalCompletionWakesCapacityDeferralWithoutClockAdvance() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let blockingReadStarted = AsyncReceipt()
        let blockingReadGate = HeldStep<Void>("blockingReadGate", cancellation: .holdThroughCancellation)
        let snapshot = Self.a3CompleteStatusSnapshot()
        let blockingProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            await blockingReadStarted.signal()
            try? await blockingReadGate.arrive(())
            return snapshot
        }
        let projectorProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in snapshot }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: projectorProvider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let blockedRead = Task {
            await blockingProvider.statusResult(for: URL(fileURLWithPath: "/tmp/a3-capacity-blocker"))
        }
        #expect(try await blockingReadStarted.wait())

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/a3-capacity-wake-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        // Missing fact: capacity retry admitted while the physical read is held.
        try await facts.expectNext(
            in: .capacity(worktreeId: worktreeId, episode: 1), .capacityRetryScheduled
        )
        #expect(await actor.capacityRetryWorktreeIds.contains(worktreeId))
        #expect(await actor.statusBackoffFailureCountByWorktreeId[worktreeId] == nil)

        blockingReadGate.release()
        _ = await blockedRead.value
        #expect((try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1)
        #expect(await actor.capacityRetryWorktreeIds.contains(worktreeId) == false)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("shutdown cancels capacity-completion interest and starts no deferred work")
    func shutdownCancelsCapacityCompletionInterest() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let blockingReadStarted = AsyncReceipt()
        let blockingReadGate = HeldStep<Void>("blockingReadGate", cancellation: .holdThroughCancellation)
        let snapshot = Self.a3CompleteStatusSnapshot()
        let blockingProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            await blockingReadStarted.signal()
            try? await blockingReadGate.arrive(())
            return snapshot
        }
        let projectorProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in snapshot }
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: projectorProvider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let blockedRead = Task {
            await blockingProvider.statusResult(for: URL(fileURLWithPath: "/tmp/a3-shutdown-blocker"))
        }
        #expect(try await blockingReadStarted.wait())

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/a3-shutdown-capacity-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        // Missing fact: capacity retry admitted before shutdown cancels it.
        try await facts.expectNext(
            in: .capacity(worktreeId: worktreeId, episode: 1), .capacityRetryScheduled
        )
        #expect(await actor.capacityRetryWorktreeIds.contains(worktreeId))
        #expect(await actor.capacityCompletionTask != nil)

        await actor.shutdown()
        #expect(await actor.capacityCompletionTask == nil)
        #expect(await actor.capacityRetryWorktreeIds.isEmpty)

        blockingReadGate.release()
        _ = await blockedRead.value
        await observed.markAcceptedOutputs()
        #expect(await observed.snapshotCount(for: worktreeId) == 0)
        try await collectionTask.finish()
    }

    @Test("capacity fallback stays fixed while genuine timeout backoff grows")
    func capacityFallbackStaysFixedWhileTimeoutBackoffGrows() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50),
            statusFailureBackoffMultiplier: 2,
            statusFailureBackoffMaxDelay: .seconds(10),
            capacityRetryBaseDelay: .milliseconds(50),
            capacityRetryJitterMaxDelay: .zero
        )
        let provider = capacityThenRecoveredStatusProvider(calls: calls)
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorder,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/capacity-fixed-retry-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        #expect((await calls.count(until: { $0 == 1 })) == 1)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .capacityFallback
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        for expectedCallCount in [2, 3] {
            clock.advance(by: .milliseconds(50))
            #expect((await calls.count(until: { $0 == expectedCallCount })) == expectedCallCount)
            _ = try await source.expectDeadlineRegistered(
                facts: facts, worktreeId: worktreeId, kind: .capacityFallback
            )
            await clock.waitForPendingSleepCount(exactly: 1)
        }

        clock.advance(by: .milliseconds(50))
        let recovered =
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.branch == "capacity-recovered" }, "next snapshot")).last?.branch
            == "capacity-recovered"
        #expect(recovered)
        #expect(await calls.value() == 4)
        #expect(recorder.backoffEvents(open: true).isEmpty)

        await actor.shutdown()
        try await collectionTask.finish()

        let timeoutSource = GitProjectorFactSource()
        let timeoutFacts = try timeoutSource.attach()
        let timeoutBus = EventBus<RuntimeEnvelope>()
        let timeoutClock = TestPushClock()
        let timeoutCalls = CallCounter()
        let timeoutProvider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            _ = await timeoutCalls.increment()
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .timeout))
        })
        let timeoutActor = GitWorkingDirectoryProjector(
            bus: timeoutBus,
            gitWorkingTreeProvider: timeoutProvider,
            coalescingWindow: .zero,
            sleepClock: timeoutClock,
            refreshPolicy: policy,
            factSink: timeoutSource.sink
        )
        await timeoutActor.start()

        let timeoutWorktreeId = UUID()
        let timeoutRootPath = URL(fileURLWithPath: "/tmp/timeout-still-grows-\(UUID().uuidString)")
        await timeoutBus.post(
            makeFilesChangedEnvelope(seq: 1, worktreeId: timeoutWorktreeId, rootPath: timeoutRootPath, batchSeq: 1)
        )
        #expect((await timeoutCalls.count(until: { $0 == 1 })) == 1)
        _ = try await timeoutSource.expectDeadlineRegistered(
            facts: timeoutFacts, worktreeId: timeoutWorktreeId, kind: .failure
        )
        await timeoutClock.waitForPendingSleepCount(exactly: 1)

        timeoutClock.advance(by: .milliseconds(50))
        #expect((await timeoutCalls.count(until: { $0 == 2 })) == 2)
        _ = try await timeoutSource.expectDeadlineRegistered(
            facts: timeoutFacts, worktreeId: timeoutWorktreeId, kind: .failure
        )
        await timeoutClock.waitForPendingSleepCount(exactly: 1)

        timeoutClock.advance(by: .milliseconds(50))
        #expect(await timeoutCalls.value() == 2)

        timeoutClock.advance(by: .milliseconds(50))
        #expect((await timeoutCalls.count(until: { $0 == 3 })) == 3)

        await timeoutActor.shutdown()
    }

    @Test("status timeout opens per-worktree backoff and coalesces changes into one deferred refresh")
    func statusTimeoutOpensBackoffAndCoalescesDeferredRefresh() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50),
            statusFailureBackoffMultiplier: 2,
            statusFailureBackoffMaxDelay: .seconds(1)
        )
        // First compute times out (opens the breaker); the deferred retry succeeds.
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let callNumber = await calls.increment()
            guard callNumber > 1 else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .timeout))
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "recovered",
                    origin: nil
                )
            )
        })
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/backoff-coalesce-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        let firstComputeTimedOut = (await calls.count(until: { $0 == 1 })) == 1
        #expect(firstComputeTimedOut)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        // Three changes arrive while the breaker is open. They must not each
        // trigger a compute; they coalesce into a single deferred refresh.
        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        await bus.post(makeFilesChangedEnvelope(seq: 3, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 3))
        await bus.post(makeFilesChangedEnvelope(seq: 4, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 4))
        // Missing fact: deferred backoff work coalesced the three held batches.
        #expect(try await facts.expectHandledEnvelope(seq: 4) == .routed)
        #expect(await actor.deferredStatusBackoffChangesetByWorktreeId[worktreeId]?.batchSeq == 4)
        #expect(await calls.value() == 1)
        #expect(await observed.snapshotCount(for: worktreeId) == 0)

        // Backoff window expires -> exactly one deferred refresh fires and succeeds.
        clock.advance(by: .milliseconds(50))
        let recovered =
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.branch == "recovered" }, "next snapshot")).last?.branch
            == "recovered"
        #expect(recovered)
        #expect(await calls.value() == 2)
        #expect(await observed.snapshotCount(for: worktreeId) == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("sdk error opens per-worktree backoff and blocks filesystem re-admission")
    func sdkErrorOpensBackoffAndBlocksFilesystemReadmission() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider(resultHandler: { _ in
                _ = await calls.increment()
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .sdkError))
            }),
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                backgroundStripeCount: 1,
                statusFailureBackoffBaseDelay: .milliseconds(50)
            ),
            performanceTraceRecorder: recorder,
            factSink: source.sink
        )
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/sdk-error-backoff-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        #expect((await calls.count(until: { $0 == 1 })) == 1)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2))
        await bus.post(makeFilesChangedEnvelope(seq: 3, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 3))
        // Missing fact: SDK backoff retained the latest deferred batch.
        #expect(try await facts.expectHandledEnvelope(seq: 3) == .routed)
        #expect(await actor.deferredStatusBackoffChangesetByWorktreeId[worktreeId]?.batchSeq == 3)

        #expect(await calls.value() == 1)
        #expect(recorder.backoffEvents(open: true).map(\.reason) == ["sdk_error"])
        await actor.shutdown()
    }

    @Test("repeated status timeout grows per-worktree backoff on the doubling schedule")
    func repeatedStatusTimeoutGrowsBackoff() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50),
            statusFailureBackoffMultiplier: 2,
            statusFailureBackoffMaxDelay: .seconds(10)
        )
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            _ = await calls.increment()
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .timeout))
        })
        let traceRecorder = GitProjectorTraceRecorderSpy()
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: traceRecorder,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/backoff-grow-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        #expect((await calls.count(until: { $0 == 1 })) == 1)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        // Expire step 1 (50ms) -> the seeded refresh recomputes and times out again.
        clock.advance(by: .milliseconds(50))
        #expect((await calls.count(until: { $0 == 2 })) == 2)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        // Step 2 must be 100ms: advancing only the base 50ms leaves it closed.
        clock.advance(by: .milliseconds(50))
        #expect(await calls.value() == 2)

        // The remaining 50ms (100ms total) expires step 2 and recomputes.
        clock.advance(by: .milliseconds(50))
        #expect((await calls.count(until: { $0 == 3 })) == 3)
        #expect(
            (await traceRecorder.recordedAttributes(
                for: .gitStatusUnavailable, until: { $0.count == 3 }
            )).count == 3)

        let timeoutAttempts = traceRecorder.recordedAttributes(for: .gitStatusUnavailable)
        #expect(timeoutAttempts.count == 3)
        #expect(
            timeoutAttempts.map { $0["agentstudio.performance.git.status.last_outcome"] } == [
                .string("timeout"), .string("timeout"), .string("timeout"),
            ])
        #expect(
            timeoutAttempts.map { $0["agentstudio.performance.git.status.consecutive_failure.count"] } == [
                .int(1), .int(2), .int(2),
            ])
        #expect(timeoutAttempts.allSatisfy { $0["agentstudio.performance.git.status.duration_ms"] != nil })

        await actor.shutdown()
        #expect(await actor.consecutiveStatusFailureCountByWorktreeId.isEmpty)
        try await collectionTask.finish()
    }

    @Test(
        "equal active results lengthen the deadline and a file change runs promptly",
        arguments: [Duration.zero, .milliseconds(80)])
    func equalActiveResultsLengthenDeadlineAndFileChangeRunsPromptly(completedDuty: Duration) async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let clockOrigin = clock.now
        let calls = CallCounter()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(100),
            visibleSidebarCadence: .milliseconds(200),
            openPaneCadence: .milliseconds(300),
            backgroundCadence: .milliseconds(400),
            backgroundStripeCount: 1,
            unchangedStatusCadenceMultipliers: [1, 2, 4]
        )
        // Every compute yields the same snapshot, so computes after the first dedup.
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            _ = await calls.increment()
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/quiescent-tick-\(UUID().uuidString)")
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic
        )
        await actor.recordAutomaticCompletion(worktreeId: worktreeId, duty: completedDuty)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic
        )
        let firstDeadline = try #require(await actor.automaticRefreshDeadlineByWorktreeId[worktreeId])
        #expect(firstDeadline == max(policy.activePaneCadence, policy.automaticDutyGap(for: completedDuty)))
        clock.advance(to: clockOrigin.advanced(by: firstDeadline))
        #expect((await calls.count(until: { $0 == 2 })) == 2)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic
        )
        let secondDeadline = try #require(await actor.automaticRefreshDeadlineByWorktreeId[worktreeId])
        #expect(
            secondDeadline >= firstDeadline
                + policy.adaptiveCadence(base: policy.activePaneCadence, unchangedResultCount: 1))
        let secondDeadlineInstant = clockOrigin.advanced(by: secondDeadline)
        clock.advance(to: secondDeadlineInstant.advanced(by: .milliseconds(-1)))
        #expect(await calls.value() == 2)
        clock.advance(to: secondDeadlineInstant)
        #expect((await calls.count(until: { $0 == 3 })) == 3)

        await bus.post(makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))
        #expect((await calls.count(until: { $0 == 4 })) == 4)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("circuit breaker emits git backoff telemetry on open and close")
    func circuitBreakerEmitsBackoffTelemetry() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50),
            statusFailureBackoffMaxDelay: .seconds(1)
        )
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let callNumber = await calls.increment()
            guard callNumber > 1 else {
                return .unavailable(GitWorkingTreeStatusUnavailable(reason: .timeout))
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorder,
            factSink: source.sink
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/backoff-telemetry-\(UUID().uuidString)")
        await bus.post(makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1))

        #expect((await calls.count(until: { $0 == 1 })) == 1)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        let openEmitted = (await recorder.backoffEvents(open: true, until: { $0.count == 1 })).count == 1
        #expect(openEmitted)
        let openEvent = recorder.backoffEvents(open: true).first
        #expect(openEvent?.reason == "timeout")
        #expect(openEvent?.backoffMilliseconds == 50)
        #expect(openEvent?.attempt == 1)

        // Backoff expiry retries the seeded refresh, which succeeds and closes.
        clock.advance(by: .milliseconds(50))
        #expect((try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1)
        let closeEmitted = (await recorder.backoffEvents(open: false, until: { $0.count >= 1 })).count >= 1
        #expect(closeEmitted)
        #expect(recorder.backoffEvents(open: false).first?.attempt == 0)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    // MARK: - Pathspec-scoped status fold

    @Test("file-change batch after cache warm scopes status to the changed paths")
    func fileChangeBatchAfterCacheWarmScopesToChangedPaths() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let recorder = PathspecRecorder()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/scoped-pathspec-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        // Registration warms the cache with a full status (pathspecs nil).
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 1 })).count == 1)
        #expect(await recorder.lastPathspecs == .some(nil))

        // A real file-change batch scopes to its changed paths.
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: ["Sources/App/File.swift"]
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 2 })).count == 2)
        #expect(await recorder.lastPathspecs == ["Sources/App/File.swift"])

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("scoped fold drops paths absent from the scoped result (became clean)")
    func scopedFoldDropsPathsThatBecameClean() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            if pathspecs == nil {
                // Full: two unstaged files warm the cache.
                return .available(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 2, staged: 0, untracked: 0),
                        branch: "main",
                        originResolution: .confirmedAbsent,
                        entries: [Self.modifiedEntry("a.txt"), Self.modifiedEntry("b.txt")]
                    )
                )
            }
            // Scoped to a.txt: it is now clean (no entries).
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    originResolution: .confirmedAbsent,
                    entries: []
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/fold-clean-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.summary.changed == 2 }, "next snapshot"))
                .last?.summary.changed
                == 2)

        await bus.post(
            makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1, paths: ["a.txt"])
        )
        // Fold keeps b.txt, drops a.txt -> changed == 1, matching a full status of the final state.
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.summary.changed == 1 }, "next snapshot"))
                .last?.summary.changed
                == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("scoped fold adds a new in-scope entry to the cached set")
    func scopedFoldAddsNewInScopeEntry() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            if pathspecs == nil {
                return .available(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                        branch: "main",
                        originResolution: .confirmedAbsent,
                        entries: [Self.modifiedEntry("a.txt")]
                    )
                )
            }
            // Scoped to c.txt: newly modified.
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    originResolution: .confirmedAbsent,
                    entries: [Self.modifiedEntry("c.txt")]
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/fold-new-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.summary.changed == 1 }, "next snapshot"))
                .last?.summary.changed
                == 1)

        await bus.post(
            makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1, paths: ["c.txt"])
        )
        // Fold keeps a.txt and adds c.txt -> changed == 2.
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.summary.changed == 2 }, "next snapshot"))
                .last?.summary.changed
                == 2)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("scoped fold re-classifies an in-scope entry from unstaged to staged")
    func scopedFoldReclassifiesEntryToStaged() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            if pathspecs == nil {
                return .available(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                        branch: "main",
                        originResolution: .confirmedAbsent,
                        entries: [Self.modifiedEntry("a.txt")]
                    )
                )
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 1, untracked: 0),
                    branch: "main",
                    originResolution: .confirmedAbsent,
                    entries: [Self.stagedEntry("a.txt")]
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/fold-staged-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.summary.changed == 1 }, "next snapshot"))
                .last?.summary.changed
                == 1)

        await bus.post(
            makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1, paths: ["a.txt"])
        )
        let changedSnapshot = try await observed.expectNextSnapshot(
            for: worktreeId, where: { $0.summary.changed == 0 && $0.summary.staged == 1 }, "next snapshot"
        ).last
        #expect(changedSnapshot?.summary.changed == 0 && changedSnapshot?.summary.staged == 1)

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("no cached snapshot forces a full status for a file-change batch")
    func noCachedSnapshotForcesFullStatus() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let recorder = PathspecRecorder()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero)
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/no-cache-\(UUID().uuidString)")
        // File-change batch with no prior cache -> full status (pathspecs nil).
        await bus.post(
            makeFilesChangedEnvelope(seq: 1, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1, paths: ["a.txt"])
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 1 })).count == 1)
        #expect(await recorder.lastPathspecs == .some(nil))

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("git-internal changeset forces a full status even with a warm cache")
    func gitInternalChangesetForcesFullStatus() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let recorder = PathspecRecorder()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/git-internal-full-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 1 })).count == 1)

        // Batch that touches git-internal state stays full even though a cache exists.
        await actor.grantDemandEligibility(worktreeId: worktreeId)
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: ["a.txt"],
                containsGitInternalChanges: true
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 2 })).count == 2)
        #expect(await recorder.lastPathspecs == .some(nil))

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("pathspec count over the policy cap forces a full status")
    func pathspecCountOverCapForcesFullStatus() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let recorder = PathspecRecorder()
        let policy = AppPolicies.GitRefresh.Policy(backgroundStripeCount: 1, maxScopedStatusPathspecCount: 2)
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: policy
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/cap-full-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 1 })).count == 1)

        // Three changed paths exceeds the cap of two -> full status.
        await actor.grantDemandEligibility(worktreeId: worktreeId)
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: ["a.txt", "b.txt", "c.txt"]
            )
        )
        #expect((await recorder.recordedCalls(until: { $0.count == 2 })).count == 2)
        #expect(await recorder.lastPathspecs == .some(nil))

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("rename half outside the pathspec falls back to a full recompute")
    func renameHalfOutsidePathspecFallsBackToFullRecompute() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let recorder = PathspecRecorder()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            if pathspecs == nil {
                // Full: seeds the cache, and later serves the fallback recompute.
                return .available(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                        branch: "main",
                        originResolution: .confirmedAbsent,
                        entries: [Self.modifiedEntry("a.txt")]
                    )
                )
            }
            // Scoped to new.txt: a rename whose source "old.txt" is outside the pathspec.
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                    branch: "main",
                    originResolution: .confirmedAbsent,
                    entries: [Self.renameEntry(path: "new.txt", previousPath: "old.txt")]
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy()
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/rename-guard-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        // Provider entry precedes cache publication. The scoped refresh needs
        // the accepted initial snapshot, not merely a started provider call.
        #expect((try await observed.expectSnapshots(for: worktreeId, through: 1)).count == 1)

        await actor.grantDemandEligibility(worktreeId: worktreeId)
        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1, paths: ["new.txt"])
        )
        // The batch triggers a scoped call, then a full recompute: scoped ["new.txt"] then nil.
        #expect((await recorder.recordedCalls(until: { $0.count == 3 })).count == 3)
        let calls = await recorder.calls
        #expect(calls == [nil, ["new.txt"], nil])

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("target-only ambiguous scoped entry falls back exactly once")
    func targetOnlyAmbiguousScopedEntryFallsBackExactlyOnce() async throws {
        try await assertAmbiguousScopedStatusFallsBackExactlyOnce(
            ambiguousEntry: GitWorkingTreeStatusEntry(
                path: "new.txt",
                hasStagedChange: false,
                hasUnstagedChange: true,
                isUntracked: true
            ),
            rootLabel: "target-only"
        )
    }

    @Test("source-only ambiguous scoped entry falls back exactly once")
    func sourceOnlyAmbiguousScopedEntryFallsBackExactlyOnce() async throws {
        try await assertAmbiguousScopedStatusFallsBackExactlyOnce(
            ambiguousEntry: GitWorkingTreeStatusEntry(
                path: "old.txt",
                hasStagedChange: true,
                hasUnstagedChange: false,
                isUntracked: false
            ),
            rootLabel: "source-only"
        )
    }

    @Test("scoped compute timeout opens the per-worktree backoff breaker")
    func scopedComputeTimeoutOpensBackoffBreaker() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let recorderSpy = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            statusFailureBackoffBaseDelay: .milliseconds(50),
            statusFailureBackoffMaxDelay: .seconds(1)
        )
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            if pathspecs == nil {
                // Full: warms the cache.
                return .available(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                        branch: "main",
                        origin: nil
                    )
                )
            }
            // Scoped compute times out -> must route into the breaker.
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .timeout))
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorderSpy
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/scoped-timeout-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect((try await observed.expectSnapshots(for: worktreeId, through: 1)).count >= 1)

        await bus.post(
            makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1, paths: ["a.txt"])
        )
        let openEmitted = (await recorderSpy.backoffEvents(open: true, until: { $0.count == 1 })).count == 1
        #expect(openEmitted)
        #expect(recorderSpy.backoffEvents(open: true).first?.reason == "timeout")

        await actor.shutdown()
        try await collectionTask.finish()
    }

    // MARK: - Dead-path quarantine

    @Test("dead-path worktree is quarantined with one bounded self-heal deadline")
    func deadPathWorktreeIsQuarantinedWithBoundedSelfHealDeadline() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(backgroundStripeCount: 1)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorder,
            factSink: source.sink,
            pathExistenceProbe: GitWorkingDirectoryProjector.liveRootPathProbe
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        // A path that does not exist on disk: registration must quarantine it.
        let missingRootPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "quarantine-missing-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: missingRootPath)
            )
        )

        // The registration seed is quarantined at admission: one open fact, no compute.
        let quarantined = (await recorder.quarantineEvents(until: { $0.count == 1 })).count == 1
        #expect(quarantined)
        #expect(recorder.quarantineEvents().first?.quarantined == true)
        #expect(recorder.quarantineEvents().first?.reason == "path_missing")

        // File-change events on the still-missing path neither compute nor re-emit.
        for seq in UInt64(2)...4 {
            await bus.post(
                makeFilesChangedEnvelope(seq: seq, worktreeId: worktreeId, rootPath: missingRootPath, batchSeq: seq)
            )
        }

        try await facts.expectNext(
            in: .intake(worktreeId: worktreeId, registration: 1, batchSeq: 4), .changesetDropped(.stale)
        )
        await observed.markAcceptedOutputs()

        #expect(await calls.value() == 0)
        #expect(await observed.snapshotCount(for: worktreeId) == 0)
        #expect(recorder.quarantineEvents().count == 1)
        #expect(
            await actor.automaticRefreshDeadlineByWorktreeId[worktreeId]
                == policy.backgroundCadence
        )
        let selfHealDeadline = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        clock.advance(by: policy.backgroundCadence)
        _ = try await facts.expectNext(
            in: selfHealDeadline,
            where: {
                if case .deadlineDisposition = $0 { return true }
                return false
            },
            "self-heal deadline closed"
        )
        #expect(
            await actor.automaticRefreshDeadlineByWorktreeId[worktreeId]
                == policy.backgroundCadence + policy.backgroundCadence
        )
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .automatic
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await calls.value() == 0)
        #expect(recorder.quarantineEvents().count == 1)

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
        try await collectionTask.finish()
    }

    @Test("quarantined worktree re-arms and computes when a file-change arrives after its path returns")
    func quarantinedWorktreeReArmsWhenPathReturns() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 2, staged: 0, untracked: 0),
                branch: "rearmed",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            performanceTraceRecorder: recorder,
            pathExistenceProbe: GitWorkingDirectoryProjector.liveRootPathProbe
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "quarantine-rearm-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        defer { try? FileManager.default.removeItem(at: rootPath) }

        // Path missing at registration: the worktree is quarantined, no compute.
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        let quarantined =
            (await recorder.quarantineEvents(until: {
                $0.contains { $0.quarantined }
            })).contains { $0.quarantined }
        #expect(quarantined)
        #expect(await calls.value() == 0)

        // The path returns; a file-change re-arms the worktree and it recomputes.
        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        await bus.post(
            makeFilesChangedEnvelope(seq: 2, worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1)
        )

        let reArmedSnapshot =
            (try await observed.expectNextSnapshot(for: worktreeId, where: { $0.branch == "rearmed" }, "next snapshot"))
            .last?.branch
            == "rearmed"
        #expect(reArmedSnapshot)
        #expect(await calls.value() == 1)
        #expect(recorder.quarantineEvents().contains { !$0.quarantined })

        await actor.shutdown()
        try await collectionTask.finish()
    }

    @Test("quarantined worktree self-heals when its path returns without a filesystem event")
    func quarantinedWorktreeSelfHealsWhenPathReturnsWithoutEvent() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = CallCounter()
        let recorder = GitProjectorTraceRecorderSpy()
        let policy = AppPolicies.GitRefresh.Policy(backgroundStripeCount: 1)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            _ = await calls.increment()
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "self-healed",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            performanceTraceRecorder: recorder,
            pathExistenceProbe: GitWorkingDirectoryProjector.liveRootPathProbe
        )

        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "quarantine-self-heal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootPath) }
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (await recorder.quarantineEvents(until: {
                $0.contains { $0.quarantined }
            })).contains { $0.quarantined })
        #expect(await calls.value() == 0)

        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)
        clock.advance(by: policy.backgroundCadence)

        #expect(
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.branch == "self-healed" }, "next snapshot")).last?.branch
                == "self-healed")
        #expect(await calls.value() == 1)
        #expect(recorder.quarantineEvents().contains { !$0.quarantined })

        await actor.shutdown()
        try await collectionTask.finish()
    }

    static func modifiedEntry(_ path: String) -> GitWorkingTreeStatusEntry {
        GitWorkingTreeStatusEntry(path: path, hasStagedChange: false, hasUnstagedChange: true, isUntracked: false)
    }

    static func stagedEntry(_ path: String) -> GitWorkingTreeStatusEntry {
        GitWorkingTreeStatusEntry(path: path, hasStagedChange: true, hasUnstagedChange: false, isUntracked: false)
    }

    static func renameEntry(path: String, previousPath: String) -> GitWorkingTreeStatusEntry {
        GitWorkingTreeStatusEntry(
            path: path,
            previousPath: previousPath,
            hasStagedChange: false,
            hasUnstagedChange: true,
            isUntracked: false,
            isRename: true
        )
    }

    private func assertAmbiguousScopedStatusFallsBackExactlyOnce(
        ambiguousEntry: GitWorkingTreeStatusEntry,
        rootLabel: String
    ) async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let recorder = PathspecRecorder()
        let traceRecorder = GitProjectorTraceRecorderSpy()
        let provider = StubGitWorkingTreeStatusProvider(pathspecAwareResultHandler: { _, pathspecs in
            await recorder.record(pathspecs)
            let callNumber = await recorder.callCount
            if pathspecs == nil {
                if callNumber == 1 {
                    return .available(
                        GitWorkingTreeStatus(
                            summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                            branch: "warm-cache",
                            originResolution: .confirmedAbsent,
                            entries: [Self.modifiedEntry("cached.txt")]
                        )
                    )
                }
                return .available(
                    GitWorkingTreeStatus(
                        summary: GitWorkingTreeSummary(changed: 2, staged: 0, untracked: 0),
                        branch: "full-fallback",
                        originResolution: .confirmedAbsent,
                        entries: [Self.modifiedEntry("cached.txt"), Self.modifiedEntry("fallback.txt")]
                    )
                )
            }
            return .available(
                GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 99, staged: 0, untracked: 1),
                    branch: "rejected-scoped",
                    originResolution: .confirmedAbsent,
                    entries: [ambiguousEntry],
                    containsPathIdentityAmbiguity: true
                )
            )
        })
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(),
            performanceTraceRecorder: traceRecorder
        )
        let observed = GitProjectorOutputFactRecorder()
        let collectionTask = await startCollection(on: bus, observed: observed)
        await actor.start()

        let worktreeId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/ambiguous-\(rootLabel)-\(UUID().uuidString)")
        await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        await bus.post(
            makeEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                event: .worktreeRegistered(worktreeId: worktreeId, repoId: worktreeId, rootPath: rootPath)
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.branch == "warm-cache" }, "next snapshot")).last?.branch
                == "warm-cache")

        await bus.post(
            makeFilesChangedEnvelope(
                seq: 2,
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 1,
                paths: [ambiguousEntry.path]
            )
        )
        #expect(
            (try await observed.expectNextSnapshot(
                for: worktreeId, where: { $0.branch == "full-fallback" }, "next snapshot")).last?.branch
                == "full-fallback")

        let calls = await recorder.calls
        #expect(calls.count == 3)
        #expect(calls[1] == [ambiguousEntry.path])
        #expect(calls[2] == .some(nil))
        #expect(await observed.snapshotCount(for: worktreeId) == 2)
        #expect(await observed.latestSnapshot(for: worktreeId)?.summary.changed == 2)
        let statusAttributes = try #require(
            traceRecorder.recordedAttributes(for: .gitStatusComputed).last
        )
        #expect(statusAttributes["agentstudio.performance.git.status_scope"] == .string("full"))
        #expect(statusAttributes["agentstudio.performance.git.pathspec.count"] == .int(0))

        await actor.shutdown()
        try await collectionTask.finish()
    }

    private static func a2Facts(
        changed: Int,
        branch: String,
        paths: [String]
    ) -> GitWorkingTreeStatusFacts {
        GitWorkingTreeStatusFacts(
            status: GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(
                    changed: changed,
                    staged: 0,
                    untracked: 0,
                    linesAdded: 0,
                    linesDeleted: 0
                ),
                branch: branch,
                originResolution: .confirmedAbsent,
                entries: paths.map(Self.modifiedEntry)
            )
        )
    }

    private static func a3CompleteStatusSnapshot() -> AgentStudioGit.GitCompleteStatusSnapshot {
        let rootPath = URL(fileURLWithPath: "/tmp/a3-status-snapshot")
        return AgentStudioGit.GitCompleteStatusSnapshot(
            facts: AgentStudioGit.GitStatusFactsSnapshot(
                repositoryRoot: rootPath,
                worktreePath: rootPath,
                generatedAtUnixMilliseconds: 1,
                head: AgentStudioGit.GitHeadSnapshot(kind: .branch, oid: "abc123", shortName: "main"),
                originResolution: .confirmedAbsent,
                summary: AgentStudioGit.GitStatusFactSummary(
                    changedFileCount: 0,
                    stagedFileCount: 0,
                    unstagedFileCount: 0,
                    untrackedFileCount: 0,
                    ignoredFileCount: 0,
                    aheadCount: 0,
                    behindCount: 0,
                    hasUpstream: false
                ),
                entries: []
            ),
            lineCountDetail: AgentStudioGit.GitStatusLineCountDetail(
                repositoryRoot: rootPath,
                worktreePath: rootPath,
                generatedAtUnixMilliseconds: 1,
                linesAdded: 0,
                linesDeleted: 0
            )
        )
    }

    private func startCollection(
        on bus: EventBus<RuntimeEnvelope>,
        observed: GitProjectorOutputFactRecorder
    ) async -> GitProjectorOutputFactRecorder {
        await observed.start(on: bus)
        return observed
    }

    private func makeFilesChangedEnvelope(
        seq: UInt64,
        worktreeId: UUID,
        repoId: UUID? = nil,
        rootPath: URL,
        batchSeq: UInt64,
        paths: [String] = ["Sources/File.swift"],
        containsGitInternalChanges: Bool = false,
        suppressedIgnoredPathCount: Int = 0,
        suppressedGitInternalPathCount: Int = 0
    ) -> RuntimeEnvelope {
        makeEnvelope(
            seq: seq,
            worktreeId: worktreeId,
            event: .filesChanged(
                changeset: FileChangeset(
                    worktreeId: worktreeId,
                    repoId: repoId ?? worktreeId,
                    rootPath: rootPath,
                    paths: paths,
                    containsGitInternalChanges: containsGitInternalChanges,
                    suppressedIgnoredPathCount: suppressedIgnoredPathCount,
                    suppressedGitInternalPathCount: suppressedGitInternalPathCount,
                    timestamp: ContinuousClock().now,
                    batchSeq: batchSeq
                )
            )
        )
    }

    private func makeEnvelope(
        seq: UInt64,
        worktreeId: UUID,
        event: FilesystemEvent
    ) -> RuntimeEnvelope {
        switch event {
        case .worktreeRegistered(let registeredWorktreeId, let repoId, let rootPath):
            return .system(
                SystemEnvelope.test(
                    event: .topology(
                        .worktreeRegistered(
                            worktreeId: registeredWorktreeId,
                            repoId: repoId,
                            rootPath: rootPath
                        )
                    ),
                    source: .builtin(.filesystemWatcher),
                    seq: seq
                )
            )
        case .worktreeUnregistered(let unregisteredWorktreeId, let repoId):
            return .system(
                SystemEnvelope.test(
                    event: .topology(
                        .worktreeUnregistered(
                            worktreeId: unregisteredWorktreeId,
                            repoId: repoId
                        )
                    ),
                    source: .builtin(.filesystemWatcher),
                    seq: seq
                )
            )
        case .filesChanged(let changeset):
            return .worktree(
                WorktreeEnvelope.test(
                    event: .filesystem(.filesChanged(changeset: changeset)),
                    repoId: changeset.repoId,
                    worktreeId: changeset.worktreeId,
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: seq
                )
            )
        case .gitSnapshotChanged(let snapshot):
            return .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(.snapshotChanged(snapshot: snapshot)),
                    repoId: snapshot.repoId,
                    worktreeId: snapshot.worktreeId,
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: seq
                )
            )
        case .diffAvailable(let diffId, let changedWorktreeId, let repoId):
            return .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .diffAvailable(
                            diffId: diffId,
                            worktreeId: changedWorktreeId,
                            repoId: repoId
                        )
                    ),
                    repoId: repoId,
                    worktreeId: changedWorktreeId,
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: seq
                )
            )
        case .branchChanged(let changedWorktreeId, let repoId, let from, let to):
            return .worktree(
                WorktreeEnvelope.test(
                    event: .gitWorkingDirectory(
                        .branchChanged(
                            worktreeId: changedWorktreeId,
                            repoId: repoId,
                            from: from,
                            to: to
                        )
                    ),
                    repoId: repoId,
                    worktreeId: changedWorktreeId,
                    source: .system(.builtin(.filesystemWatcher)),
                    seq: seq
                )
            )
        }
    }

    private func worktreeId(
        forBackgroundStripe expectedStripe: Int,
        policy: AppPolicies.GitRefresh.Policy,
        excluding excludedWorktreeIds: Set<UUID> = []
    ) -> UUID {
        for suffix in 0..<10_000 {
            let uuidString = String(format: "00000000-0000-0000-0000-%012X", suffix)
            guard let candidate = UUID(uuidString: uuidString) else { continue }
            guard !excludedWorktreeIds.contains(candidate) else { continue }
            if policy.backgroundStripe(for: candidate) == expectedStripe {
                return candidate
            }
        }
        fatalError("Unable to find deterministic UUID for background stripe \(expectedStripe)")
    }
}

private struct PassiveGitStatusSlowObservationScheduler: AgentStudioGitStatusSlowObservationScheduler {
    func scheduleObservation(
        after _: Duration,
        _: @escaping @Sendable () -> Void
    ) -> AgentStudioGitScheduledSlowObservation {
        AgentStudioGitScheduledSlowObservation {}
    }
}

private struct A2FactDetailStatusProvider: GitWorkingTreeStatusProvider {
    let legacyCallCounter: CallCounter
    let factsHandler: @Sendable (URL, [String]?) async -> GitWorkingTreeStatusFactsResult
    let detailHandler: @Sendable (URL) async -> GitWorkingTreeLineDetailResult

    init(
        legacyCallCounter: CallCounter = CallCounter(),
        factsHandler: @escaping @Sendable (URL, [String]?) async -> GitWorkingTreeStatusFactsResult,
        detailHandler: @escaping @Sendable (URL) async -> GitWorkingTreeLineDetailResult
    ) {
        self.legacyCallCounter = legacyCallCounter
        self.factsHandler = factsHandler
        self.detailHandler = detailHandler
    }

    func statusResult(
        for _: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusResult {
        _ = await legacyCallCounter.increment()
        return .unavailable(GitWorkingTreeStatusUnavailable(reason: .sdkError))
    }

    func statusFactsResult(
        for rootPath: URL,
        pathspecs: [String]?
    ) async -> GitWorkingTreeStatusFactsResult {
        await factsHandler(rootPath, pathspecs)
    }

    func lineDetailResult(for rootPath: URL) async -> GitWorkingTreeLineDetailResult {
        await detailHandler(rootPath)
    }
}

private struct A2StaleDetailProviderFixture {
    let pathspecRecorder: PathspecRecorder
    let staleDetailStarted: AsyncReceipt
    let staleDetailGate: HeldStep<Void>
    let currentDetailStarted: AsyncReceipt
    let currentDetailGate: HeldStep<Void>
    let provider: A2FactDetailStatusProvider

    init(
        initialFacts: GitWorkingTreeStatusFacts,
        staleFacts: GitWorkingTreeStatusFacts,
        currentFacts: GitWorkingTreeStatusFacts
    ) {
        let factCalls = CallCounter()
        let detailCalls = CallCounter()
        let pathspecRecorder = PathspecRecorder()
        let staleDetailStarted = AsyncReceipt()
        let staleDetailGate = HeldStep<Void>("staleDetailGate", cancellation: .holdThroughCancellation)
        let currentDetailStarted = AsyncReceipt()
        let currentDetailGate = HeldStep<Void>("currentDetailGate", cancellation: .holdThroughCancellation)
        self.pathspecRecorder = pathspecRecorder
        self.staleDetailStarted = staleDetailStarted
        self.staleDetailGate = staleDetailGate
        self.currentDetailStarted = currentDetailStarted
        self.currentDetailGate = currentDetailGate
        provider = A2FactDetailStatusProvider(
            factsHandler: { _, pathspecs in
                await pathspecRecorder.record(pathspecs)
                switch await factCalls.increment() {
                case 1: return .available(initialFacts)
                case 2: return .available(staleFacts)
                default: return .available(currentFacts)
                }
            },
            detailHandler: { _ in
                switch await detailCalls.increment() {
                case 1:
                    return .available(GitWorkingTreeLineDetail(linesAdded: 1, linesDeleted: 0))
                case 2:
                    await staleDetailStarted.signal()
                    try? await staleDetailGate.arrive(())
                    return .available(GitWorkingTreeLineDetail(linesAdded: 20, linesDeleted: 10))
                default:
                    await currentDetailStarted.signal()
                    try? await currentDetailGate.arrive(())
                    return .available(GitWorkingTreeLineDetail(linesAdded: 30, linesDeleted: 15))
                }
            }
        )
    }
}

private actor OneByOneStatusGate {
    private var recordedLabels: [String] = []
    private let heldCalls: [HeldStep<String>]
    private var isOpen = false

    init(maximumHeldCalls: Int) {
        heldCalls = (0..<maximumHeldCalls).map { HeldStep<String>("status provider call \($0 + 1)") }
    }

    var labels: [String] { recordedLabels }

    func recordAndWait(_ label: String) async {
        recordedLabels.append(label)
        guard !isOpen else { return }
        let callIndex = recordedLabels.count - 1
        precondition(callIndex < heldCalls.count, "More held provider calls than configured capacity")
        try? await heldCalls[callIndex].arrive(label)
    }

    func labels(through count: Int) async throws -> [String] {
        precondition(count <= heldCalls.count)
        var observedLabels: [String] = []
        for heldCall in heldCalls.prefix(count) {
            observedLabels.append(try await heldCall.firstArrival())
        }
        return observedLabels
    }

    func releaseAll() {
        isOpen = true
        for heldCall in heldCalls { heldCall.release() }
    }
}

private final class AsyncReceipt: Sendable {
    private let signalStep = HeldStep<Bool>("provider receipt")

    init() {
        signalStep.release()
    }

    func wait() async throws -> Bool {
        try await signalStep.firstArrival()
    }

    func signal() async {
        try? await signalStep.arrive(true)
    }
}

private actor CallCounter {
    private var count = 0
    private var countWaiters:
        [(
            predicate: @Sendable (Int) -> Bool,
            continuation: CheckedContinuation<Int, Never>
        )] = []

    func increment() -> Int {
        count += 1
        var remainingWaiters:
            [(
                predicate: @Sendable (Int) -> Bool,
                continuation: CheckedContinuation<Int, Never>
            )] = []
        for waiter in countWaiters {
            if waiter.predicate(count) {
                waiter.continuation.resume(returning: count)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        countWaiters = remainingWaiters
        return count
    }

    func value() -> Int {
        count
    }

    func count(until predicate: @escaping @Sendable (Int) -> Bool) async -> Int {
        if predicate(count) {
            return count
        }
        return await withCheckedContinuation { continuation in
            countWaiters.append((predicate: predicate, continuation: continuation))
        }
    }
}

private actor PathspecRecorder {
    private(set) var calls: [[String]?] = []
    private var callWaiters:
        [(
            predicate: @Sendable ([[String]?]) -> Bool,
            continuation: CheckedContinuation<[[String]?], Never>
        )] = []

    func record(_ pathspecs: [String]?) {
        calls.append(pathspecs)
        var remainingWaiters:
            [(
                predicate: @Sendable ([[String]?]) -> Bool,
                continuation: CheckedContinuation<[[String]?], Never>
            )] = []
        for waiter in callWaiters {
            if waiter.predicate(calls) {
                waiter.continuation.resume(returning: calls)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        callWaiters = remainingWaiters
    }

    func recordedCalls(until predicate: @escaping @Sendable ([[String]?]) -> Bool) async -> [[String]?] {
        if predicate(calls) { return calls }
        return await withCheckedContinuation { continuation in
            callWaiters.append((predicate: predicate, continuation: continuation))
        }
    }

    var callCount: Int {
        calls.count
    }

    var lastPathspecs: [String]? {
        calls.last.flatMap { $0 }
    }
}

private actor CallOrderRecorder {
    private var recordedLabels: [String] = []
    private var labelWaiters:
        [(
            predicate: @Sendable ([String]) -> Bool,
            continuation: CheckedContinuation<[String], Never>
        )] = []

    var labels: [String] {
        recordedLabels
    }

    func record(_ label: String) {
        recordedLabels.append(label)
        var remainingWaiters:
            [(
                predicate: @Sendable ([String]) -> Bool,
                continuation: CheckedContinuation<[String], Never>
            )] = []
        for waiter in labelWaiters {
            if waiter.predicate(recordedLabels) {
                waiter.continuation.resume(returning: recordedLabels)
            } else {
                remainingWaiters.append(waiter)
            }
        }
        labelWaiters = remainingWaiters
    }

    func labels(until predicate: @escaping @Sendable ([String]) -> Bool) async -> [String] {
        if predicate(recordedLabels) { return recordedLabels }
        return await withCheckedContinuation { continuation in
            labelWaiters.append((predicate: predicate, continuation: continuation))
        }
    }
}

private final class GitProjectorTraceRecorderSpy: GitProjectorPerformanceRecording, @unchecked Sendable {
    private typealias RecordedEvent = (AgentStudioPerformanceTraceRecorder.Event, [String: AgentStudioTraceValue])

    private struct EventWaiter {
        let predicate: @Sendable ([RecordedEvent]) -> Bool
        let continuation: CheckedContinuation<[RecordedEvent], Never>
    }

    struct BackoffEvent: Sendable {
        let open: Bool
        let reason: String?
        let backoffMilliseconds: Double?
        let attempt: Int?
    }

    struct QuarantineEvent: Sendable {
        let quarantined: Bool
        let reason: String?
    }

    private let lock = NSLock()
    let isEnabled: Bool
    private var recordedEvents: [RecordedEvent] = []
    private var eventWaiters: [EventWaiter] = []
    private var recordedGitAggregateSnapshots: [GitWorkingDirectoryPerformanceSnapshot] = []

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func record(
        _ event: AgentStudioPerformanceTraceRecorder.Event,
        attributes: @autoclosure () -> [String: AgentStudioTraceValue]
    ) {
        guard isEnabled else { return }
        let evaluatedAttributes = attributes()
        appendRecordedEvent(event, attributes: evaluatedAttributes)
    }

    func recordDuration(
        _ event: AgentStudioPerformanceTraceRecorder.Event,
        duration: Duration,
        attributes: @autoclosure () -> [String: AgentStudioTraceValue]
    ) {
        guard isEnabled else { return }
        let evaluatedAttributes = attributes()
        appendRecordedEvent(event, attributes: evaluatedAttributes)
    }

    private func appendRecordedEvent(
        _ event: AgentStudioPerformanceTraceRecorder.Event,
        attributes: [String: AgentStudioTraceValue]
    ) {
        let (events, completedWaiters) = lock.withLock { () -> ([RecordedEvent], [EventWaiter]) in
            recordedEvents.append((event, attributes))
            let events = recordedEvents
            var completed: [EventWaiter] = []
            var remaining: [EventWaiter] = []
            for waiter in eventWaiters {
                if waiter.predicate(events) {
                    completed.append(waiter)
                } else {
                    remaining.append(waiter)
                }
            }
            eventWaiters = remaining
            return (events, completed)
        }
        for waiter in completedWaiters {
            waiter.continuation.resume(returning: events)
        }
    }

    private func events(until predicate: @escaping @Sendable ([RecordedEvent]) -> Bool) async -> [RecordedEvent] {
        await withCheckedContinuation { continuation in
            let currentEvents = lock.withLock { () -> [RecordedEvent]? in
                if predicate(recordedEvents) { return recordedEvents }
                eventWaiters.append(EventWaiter(predicate: predicate, continuation: continuation))
                return nil
            }
            if let currentEvents {
                continuation.resume(returning: currentEvents)
            }
        }
    }

    func recordGitWorkingDirectoryPerformanceSnapshot(
        _ snapshot: GitWorkingDirectoryPerformanceSnapshot
    ) {
        guard isEnabled else { return }
        lock.lock()
        recordedGitAggregateSnapshots.append(snapshot)
        lock.unlock()
    }

    func gitAggregateSnapshots() -> [GitWorkingDirectoryPerformanceSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recordedGitAggregateSnapshots
    }

    func backoffEvents(open: Bool) -> [BackoffEvent] {
        lock.withLock { Self.backoffEvents(from: recordedEvents, open: open) }
    }

    func backoffEvents(open: Bool, until predicate: @escaping @Sendable ([BackoffEvent]) -> Bool) async
        -> [BackoffEvent]
    {
        let matchedEvents = await events(until: { predicate(Self.backoffEvents(from: $0, open: open)) })
        return Self.backoffEvents(from: matchedEvents, open: open)
    }

    private static func backoffEvents(from recordedEvents: [RecordedEvent], open: Bool) -> [BackoffEvent] {
        recordedEvents.compactMap { event, attributes in
            guard event == .gitBackoff else { return nil }
            guard
                case .bool(let isOpen)? = attributes["agentstudio.performance.git.backoff_open"],
                isOpen == open
            else {
                return nil
            }
            return BackoffEvent(
                open: isOpen,
                reason: Self.string(attributes["agentstudio.performance.git.backoff.reason"]),
                backoffMilliseconds: Self.double(attributes["agentstudio.performance.git.backoff_ms"]),
                attempt: Self.int(attributes["agentstudio.performance.git.backoff_attempt.count"])
            )
        }
    }

    func quarantineEvents() -> [QuarantineEvent] {
        lock.withLock { Self.quarantineEvents(from: recordedEvents) }
    }

    func quarantineEvents(until predicate: @escaping @Sendable ([QuarantineEvent]) -> Bool) async -> [QuarantineEvent] {
        let matchedEvents = await events(until: { predicate(Self.quarantineEvents(from: $0)) })
        return Self.quarantineEvents(from: matchedEvents)
    }

    private static func quarantineEvents(from recordedEvents: [RecordedEvent]) -> [QuarantineEvent] {
        recordedEvents.compactMap { event, attributes in
            guard event == .gitPathQuarantine else { return nil }
            guard case .bool(let quarantined)? = attributes["agentstudio.performance.git.path_quarantined"] else {
                return nil
            }
            return QuarantineEvent(
                quarantined: quarantined,
                reason: Self.string(attributes["agentstudio.performance.git.path_quarantine.reason"])
            )
        }
    }

    func recordedAttributes(
        for expectedEvent: AgentStudioPerformanceTraceRecorder.Event
    ) -> [[String: AgentStudioTraceValue]] {
        lock.withLock { Self.recordedAttributes(from: recordedEvents, for: expectedEvent) }
    }

    func recordedAttributes(
        for expectedEvent: AgentStudioPerformanceTraceRecorder.Event,
        until predicate: @escaping @Sendable ([[String: AgentStudioTraceValue]]) -> Bool
    ) async -> [[String: AgentStudioTraceValue]] {
        let matchedEvents = await events(until: {
            predicate(Self.recordedAttributes(from: $0, for: expectedEvent))
        })
        return Self.recordedAttributes(from: matchedEvents, for: expectedEvent)
    }

    private static func recordedAttributes(
        from recordedEvents: [RecordedEvent],
        for expectedEvent: AgentStudioPerformanceTraceRecorder.Event
    ) -> [[String: AgentStudioTraceValue]] {
        recordedEvents.compactMap { event, attributes in
            guard event == expectedEvent else { return nil }
            return attributes
        }
    }

    private static func string(_ value: AgentStudioTraceValue?) -> String? {
        guard case .string(let stringValue)? = value else { return nil }
        return stringValue
    }

    private static func double(_ value: AgentStudioTraceValue?) -> Double? {
        guard case .double(let doubleValue)? = value else { return nil }
        return doubleValue
    }

    private static func int(_ value: AgentStudioTraceValue?) -> Int? {
        guard case .int(let intValue)? = value else { return nil }
        return intValue
    }
}

private func makeGitLogicalDebtTraceRuntime() -> AgentStudioTraceRuntime {
    AgentStudioTraceRuntime(
        configuration: AgentStudioTraceConfiguration.from(environment: [
            "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
            "AGENTSTUDIO_TRACE_DIR": FileManager.default.temporaryDirectory.path,
            "AGENTSTUDIO_TRACE_NAME": "git-logical-debt-transitions-\(UUIDv7.generate().uuidString)",
            "AGENTSTUDIO_TRACE_TAGS": "performance",
        ]),
        processIdentifier: 925
    )
}

private func gitLogicalDebtTraceAttributes(
    from traceRuntime: AgentStudioTraceRuntime
) throws -> [[String: Any]] {
    let outputFileURL = try #require(traceRuntime.outputFileURL)
    let contents = try String(contentsOf: outputFileURL, encoding: .utf8)
    return try contents.split(separator: "\n").compactMap { line in
        let data = Data(line.utf8)
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            record["body"] as? String == "performance.git.logical_debt",
            let attributes = record["attributes"] as? [String: Any]
        else {
            return nil
        }
        return attributes
    }
}

private func capacityThenRecoveredStatusProvider(calls: CallCounter) -> StubGitWorkingTreeStatusProvider {
    StubGitWorkingTreeStatusProvider(resultHandler: { _ in
        let callNumber = await calls.increment()
        guard callNumber > 3 else {
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: .readCapacityExceeded))
        }
        return .available(
            GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "capacity-recovered",
                origin: nil
            )
        )
    })
}
