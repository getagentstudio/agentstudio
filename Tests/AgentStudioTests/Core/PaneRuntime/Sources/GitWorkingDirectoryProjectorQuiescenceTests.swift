import AgentStudioGit
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("GitWorkingDirectoryProjector quiescence")
struct GitWorkingDirectoryProjectorQuiescenceTests {
    @Test("registration batch zero closes again after unregister and re-register")
    func registrationBatchZeroHasTwoIntakeOperations() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let projector = makeProjector(bus: bus, factSink: source.sink)
        await projector.start()
        let worktreeID = UUIDv7.generate()
        await projector.setActivePaneWorktree(worktreeId: worktreeID)
        _ = await bus.post(registeredEnvelope(seq: 1, worktreeID: worktreeID))
        #expect(try await facts.expectHandledEnvelope(seq: 1) == .routed)
        let firstRefresh = try await facts.expectNextRefreshStarted(worktreeId: worktreeID)
        _ = try await facts.expectRefreshClosed(worktreeId: worktreeID, requestSequence: firstRefresh)
        _ = await bus.post(unregisteredEnvelope(seq: 2, worktreeID: worktreeID))
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        await projector.setActivePaneWorktree(worktreeId: worktreeID)
        _ = await bus.post(registeredEnvelope(seq: 3, worktreeID: worktreeID))
        #expect(try await facts.expectHandledEnvelope(seq: 3) == .routed)
        let secondRefresh = try await facts.expectNextRefreshStarted(worktreeId: worktreeID)
        _ = try await facts.expectRefreshClosed(worktreeId: worktreeID, requestSequence: secondRefresh)
        await projector.shutdown()
        source.end()

        let firstIntake = GitProjectorScope.intake(worktreeId: worktreeID, registration: 1, batchSeq: 0)
        let secondIntake = GitProjectorScope.intake(worktreeId: worktreeID, registration: 2, batchSeq: 0)
        try await facts.expectNext(in: firstIntake, .changesetAccepted)
        try await facts.expectNext(in: secondIntake, .changesetAccepted)
        try await facts.finish()
    }

    @Test("before start, shutdown, and restart have distinct subscription lifetimes")
    func lifecycleAndIgnoredEnvelope() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let projector = makeProjector(bus: bus, factSink: source.sink)

        await projector.start()
        let duplicateLabel = await bus.subscribe(
            policy: .criticalUnbounded,
            subscriberName: "GitWorkingDirectoryProjector"
        )
        _ = await bus.post(ignoredTopologyEnvelope(seq: 1))
        try await facts.expectNext(in: .lifetime(1), .envelopeHandled(seq: 1, disposition: .ignored))
        #expect(duplicateLabel.deliveryCheckpoint().enqueuedCount == 1)

        await projector.shutdown()
        try await facts.expectNext(in: .lifetime(1), .shutdownCompleted)
        await projector.start()
        _ = await bus.post(ignoredTopologyEnvelope(seq: 2))
        try await facts.expectNext(in: .lifetime(2), .envelopeHandled(seq: 2, disposition: .ignored))
        await projector.shutdown()
        try await facts.expectNext(in: .lifetime(2), .shutdownCompleted)
        try await facts.finish()
    }

    @Test("a queued newest-buffer replacement reports loss after intake catches up")
    func queuedEnvelopeReportsLoss() async throws {
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(capacityPerSource: 4, sourceKey: { $0.source.description })
        )
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let projector = makeProjector(bus: bus, subscriptionBufferLimit: 1, factSink: source.sink)
        _ = await bus.post(contentsOf: (1...4).map { ignoredTopologyEnvelope(seq: UInt64($0)) })
        await projector.start()

        try await facts.expectNext(in: .lifetime(1), .envelopesDropped(count: 3))
        try await facts.expectNext(in: .lifetime(1), .envelopeHandled(seq: 4, disposition: .ignored))
        await projector.shutdown()
        try await facts.expectNext(in: .lifetime(1), .shutdownCompleted)
        try await facts.finish()
    }

    @Test("subscription stream end starts self-shutdown and closes its lifetime")
    func streamEndStartsShutdown() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let projector = makeProjector(bus: bus, factSink: source.sink)
        await projector.start()

        await projector.subscriptionStreamDidEnd(lifetime: 1)

        #expect(try await facts.expectShutdownCompleted() == 0)
        #expect(await projector.isShuttingDown)
    }

    @Test("coalesced provider work and a later input settle after the provider exits")
    func coalescedProviderAndLaterInput() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let providerStep = HeldStep<Void>("coalesced status provider")
        let provider = StubGitWorkingTreeStatusProvider { _ in
            try? await providerStep.arrive(())
            return cleanStatus()
        }
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .milliseconds(20),
            sleepClock: clock,
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        await projector.setActivity(worktreeId: worktreeID, isActiveInApp: true)
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeID, kind: .coalescingWindow
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        clock.advance(by: .milliseconds(20))
        _ = try await providerStep.firstArrival()
        _ = await bus.post(ignoredTopologyEnvelope(seq: 2))
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .ignored)
        providerStep.release()

        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        #expect(await projector.worktreeTasks.isEmpty)
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    @Test("cancelled retired provider remains outstanding until it actually exits")
    func retiredProviderLifetime() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let providerStep = HeldStep<Void>("retired provider", cancellation: .holdThroughCancellation)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            try? await providerStep.arrive(())
            return cleanStatus()
        }
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        await projector.setActivity(worktreeId: worktreeID, isActiveInApp: true)
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await providerStep.firstArrival()

        _ = await bus.post(unregisteredEnvelope(seq: 2, worktreeID: worktreeID))
        try await providerStep.cancellationObserved()
        #expect(await projector.outstandingDrainTasks.isEmpty == false)
        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        providerStep.release()
        let retiredOutcome = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        #expect(retiredOutcome == .cancelled)
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
        #expect(await projector.outstandingDrainTasks.isEmpty)
    }

    @Test("retired drain cannot close a replacement refresh")
    func retiredDrainKeepsReplacementRefreshOpen() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let firstStep = HeldStep<Void>("retired first read", cancellation: .holdThroughCancellation)
        let secondStep = HeldStep<Void>("replacement read", cancellation: .holdThroughCancellation)
        let calls = Mutex(0)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            let attempt = calls.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 { try? await firstStep.arrive(()) }
            if attempt == 2 { try? await secondStep.arrive(()) }
            return cleanStatus()
        }
        let projector = GitWorkingDirectoryProjector(
            bus: bus, gitWorkingTreeProvider: provider, coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        await projector.setActivity(worktreeId: worktreeID, isActiveInApp: true)
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await firstStep.firstArrival()
        let firstSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeID)

        _ = await bus.post(unregisteredEnvelope(seq: 2, worktreeID: worktreeID))
        try await firstStep.cancellationObserved()
        _ = await bus.post(registeredEnvelope(seq: 3, worktreeID: worktreeID))
        await projector.setActivity(worktreeId: worktreeID, isActiveInApp: true)
        _ = await bus.post(filesChangedEnvelope(seq: 4, worktreeID: worktreeID))
        _ = try await secondStep.firstArrival()
        let secondSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeID)
        #expect(secondSequence > firstSequence)

        firstStep.release()
        let firstOutcome = try await facts.expectRefreshClosed(
            worktreeId: worktreeID, requestSequence: firstSequence)
        #expect(firstOutcome == .superseded || firstOutcome == .cancelled)
        let secondScope = GitProjectorScope.refresh(worktreeId: worktreeID, requestSequence: secondSequence)
        secondStep.release()
        let secondClose = try await facts.expectNext(
            in: secondScope,
            where: {
                if case .refreshClosed = $0 { return true }
                return false
            }, "replacement refresh closes after its provider exits")
        #expect(secondClose == .refreshClosed(.completed(snapshotChanged: true, branchChanged: false)))
        await projector.shutdown()
        try await facts.finish()
    }

    @Test("shutdown reports buffered drops without another handled envelope")
    func shutdownReportsFinalBufferedDrops() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>(
            replayConfiguration: .init(capacityPerSource: 4, sourceKey: { $0.source.description })
        )
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in cleanStatus() },
            coalescingWindow: .zero, subscriptionBufferLimit: 0,
            factSink: source.sink
        )
        _ = await bus.post(contentsOf: (1...4).map { ignoredTopologyEnvelope(seq: UInt64($0)) })
        await projector.start()
        await projector.shutdown()
        try await facts.expectNext(in: .lifetime(1), .envelopesDropped(count: 4))
        try await facts.expectNext(in: .lifetime(1), .shutdownCompleted)
        try await facts.finish()
    }

    @Test("shutdown joins a cancelled provider before closing the subscription lifetime")
    func cancellationAndShutdown() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let providerStep = HeldStep<Void>("shutdown provider", cancellation: .holdThroughCancellation)
        let provider = StubGitWorkingTreeStatusProvider { _ in
            try? await providerStep.arrive(())
            return cleanStatus()
        }
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        await projector.setActivity(worktreeId: worktreeID, isActiveInApp: true)
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await providerStep.firstArrival()

        let shutdownTask = Task { await projector.shutdown() }
        try await providerStep.cancellationObserved()
        #expect(await projector.outstandingDrainTasks.isEmpty == false)
        providerStep.release()
        await shutdownTask.value
        #expect(try await facts.expectShutdownCompleted() == 0)
        #expect(await projector.outstandingDrainTasks.isEmpty)
    }

    @Test("status failure debt remains outstanding until controlled backoff retries it")
    func statusBackoffDebt() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let attempts = StatusAttemptSequence(firstFailure: .providerReturnedNil)
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider(resultHandler: { _ in
                await attempts.nextResult()
            }),
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: .init(statusFailureBackoffBaseDelay: .milliseconds(10)),
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeID, kind: .failure
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await projector.deferredStatusBackoffChangesetByWorktreeId[worktreeID] != nil)

        clock.advance(by: .milliseconds(10))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        #expect(await attempts.callCount == 2)
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    @Test("capacity retry debt remains outstanding until controlled fallback retries it")
    func capacityRetryDebt() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let attempts = StatusAttemptSequence(firstFailure: .readCapacityExceeded)
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider(resultHandler: { _ in
                await attempts.nextResult()
            }),
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: .init(
                capacityRetryBaseDelay: .milliseconds(10),
                capacityRetryJitterMaxDelay: .zero
            ),
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeID, kind: .capacityFallback
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await projector.capacityRetryWorktreeIds.contains(worktreeID))

        clock.advance(by: .milliseconds(10))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        #expect(await attempts.callCount == 2)
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    @Test("admission pacing keeps the second accepted worktree pending")
    func admissionPacedDebt() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let attempts = StatusAttemptSequence(firstFailure: nil)
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider(resultHandler: { _ in
                await attempts.nextResult()
            }),
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: .init(
                backgroundStripeCount: 1,
                maxConcurrentStatusComputes: 1,
                minimumAutomaticStartInterval: .milliseconds(10)
            ),
            factSink: source.sink
        )
        await projector.start()
        let firstWorktreeID = UUIDv7.generate()
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: firstWorktreeID))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: firstWorktreeID)
        #expect(await attempts.callCount == 1)

        let secondWorktreeID = UUIDv7.generate()
        _ = await bus.post(filesChangedEnvelope(seq: 2, worktreeID: secondWorktreeID))
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: secondWorktreeID, kind: .governorPacing
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        #expect(await projector.pendingByWorktreeId[secondWorktreeID] != nil)
        clock.advance(by: .milliseconds(10))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: secondWorktreeID)
        #expect(await attempts.callCount == 2)
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    @Test("a due periodic deadline stays active through exact-clean renewal")
    func activeDeadlineRenewal() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let renewalStep = HeldStep<Void>("exact-clean deadline renewal")
        let authority = GitCleanContinuityAuthority(
            registrationId: UUIDv7.generate(),
            observationIdentity: GitStatusObservationIdentity(rawValue: "quiescence-renewal"),
            registrationGeneration: 1,
            mutationEpoch: 0,
            uncertaintyEpoch: 0
        )
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: HeldExactCleanRenewalProvider(
                authority: authority,
                renewalStep: renewalStep
            ),
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: .init(activePaneCadence: .milliseconds(10)),
            factSink: source.sink
        )
        await projector.start()
        let worktreeID = UUIDv7.generate()
        await projector.setActivity(worktreeId: worktreeID, isActiveInApp: true)
        _ = await bus.post(registeredEnvelope(seq: 1, worktreeID: worktreeID))
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        let periodicDeadline = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeID, kind: .automatic
        )
        await clock.waitForPendingSleepCount(exactly: 1)

        #expect(clock.advanceToNextPendingSleep())
        _ = try await renewalStep.firstArrival()
        renewalStep.release()
        _ = try await facts.expectNext(
            in: periodicDeadline,
            where: {
                if case .deadlineDisposition = $0 { return true }
                return false
            },
            "periodic deadline closed after renewal"
        )
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    @Test("work posted during provider completion closes in a second refresh")
    func followupWorkClosesInSecondRefresh() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let attempts = StatusAttemptSequence(firstFailure: nil)
        let worktreeID = UUIDv7.generate()
        let provider = StubGitWorkingTreeStatusProvider(resultHandler: { _ in
            let result = await attempts.nextResult()
            if await attempts.callCount == 1 {
                _ = await bus.post(filesChangedEnvelope(seq: 2, worktreeID: worktreeID))
            }
            return result
        })
        let projector = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            factSink: source.sink
        )
        await projector.start()
        _ = await bus.post(filesChangedEnvelope(seq: 1, worktreeID: worktreeID))

        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeID)
        #expect(await attempts.callCount == 2)
        await projector.shutdown()
        #expect(try await facts.expectShutdownCompleted() == 0)
    }

    private func makeProjector(
        bus: EventBus<RuntimeEnvelope>,
        subscriptionBufferLimit: Int = 256,
        factSink: GitProjectorFactSink? = nil
    ) -> GitWorkingDirectoryProjector {
        GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in cleanStatus() },
            coalescingWindow: .zero,
            subscriptionBufferLimit: subscriptionBufferLimit,
            factSink: factSink
        )
    }

    private func ignoredTopologyEnvelope(seq: UInt64) -> RuntimeEnvelope {
        .system(
            SystemEnvelope.test(
                event: .topology(
                    .worktreeUnregistered(worktreeId: UUIDv7.generate(), repoId: UUIDv7.generate())
                ),
                source: .builtin(.gitWorkingDirectoryProjector),
                seq: seq
            )
        )
    }

    private func unregisteredEnvelope(seq: UInt64, worktreeID: UUID) -> RuntimeEnvelope {
        .system(
            SystemEnvelope.test(
                event: .topology(.worktreeUnregistered(worktreeId: worktreeID, repoId: worktreeID)),
                source: .builtin(.filesystemWatcher),
                seq: seq
            )
        )
    }

    private func registeredEnvelope(seq: UInt64, worktreeID: UUID) -> RuntimeEnvelope {
        .system(
            SystemEnvelope.test(
                event: .topology(
                    .worktreeRegistered(
                        worktreeId: worktreeID,
                        repoId: worktreeID,
                        rootPath: URL(fileURLWithPath: "/tmp/projector-quiescence-\(worktreeID.uuidString)")
                    )
                ),
                source: .builtin(.filesystemWatcher),
                seq: seq
            )
        )
    }

    private func filesChangedEnvelope(seq: UInt64, worktreeID: UUID) -> RuntimeEnvelope {
        let rootPath = URL(fileURLWithPath: "/tmp/projector-quiescence-\(worktreeID.uuidString)")
        return .worktree(
            WorktreeEnvelope.test(
                event: .filesystem(
                    .filesChanged(
                        changeset: FileChangeset(
                            worktreeId: worktreeID,
                            repoId: worktreeID,
                            rootPath: rootPath,
                            paths: ["file.txt"],
                            timestamp: ContinuousClock().now,
                            batchSeq: seq
                        )
                    )
                ),
                repoId: worktreeID,
                worktreeId: worktreeID,
                source: .system(.builtin(.filesystemWatcher)),
                seq: seq
            )
        )
    }
}

private func cleanStatus() -> GitWorkingTreeStatus {
    GitWorkingTreeStatus(
        summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
        branch: "main",
        origin: nil
    )
}

private actor StatusAttemptSequence {
    let firstFailure: GitWorkingTreeStatusUnavailableReason?
    private(set) var callCount = 0

    init(firstFailure: GitWorkingTreeStatusUnavailableReason?) {
        self.firstFailure = firstFailure
    }

    func nextResult() -> GitWorkingTreeStatusResult {
        callCount += 1
        if callCount == 1, let firstFailure {
            return .unavailable(GitWorkingTreeStatusUnavailable(reason: firstFailure))
        }
        return .available(cleanStatus())
    }
}

private struct HeldExactCleanRenewalProvider: GitExactCleanStatusProviding {
    let authority: GitCleanContinuityAuthority
    let renewalStep: HeldStep<Void>

    func statusResult(for _: URL, pathspecs _: [String]?) async -> GitWorkingTreeStatusResult {
        .available(cleanStatus())
    }

    func exactCleanStatusFactsResult(for _: UUID, rootPath _: URL) async -> GitExactCleanStatusFactsResult {
        .available(GitWorkingTreeStatusFacts(status: cleanStatus(), exactCleanAuthority: authority))
    }

    func renewExactCleanAuthority(_: GitCleanContinuityAuthority) async -> GitExactCleanRenewalResult {
        try? await renewalStep.arrive(())
        return .renewed(authority)
    }

    func retireExactCleanAuthority(worktreeId _: UUID, rootPath _: URL) {}
}
