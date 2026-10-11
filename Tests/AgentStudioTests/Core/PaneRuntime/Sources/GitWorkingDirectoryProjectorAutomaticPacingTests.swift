import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("GitWorkingDirectoryProjector automatic pacing")
struct GitWorkingDirectoryProjectorAutomaticPacingTests {
    @Test("cold attended registration receives one baseline without recurring automatic work")
    func inactiveRegistrationHasNoAutomaticDeadline() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let worktreeID = UUIDv7.generate()
        let repositoryID = UUIDv7.generate()
        let rootPath = URL(filePath: "/tmp/inactive-registration-\(worktreeID)")
        let providerCallCount = AutomaticPacingCallCounter()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in
                await providerCallCount.increment()
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            },
            coalescingWindow: .zero,
            factSink: source.sink
        )

        await actor.setRepositoryFactAttention(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [worktreeID],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            warmAutomaticWorktreeIds: [],
            backgroundOnlyAutomaticWorktreeIds: []
        )
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: [
                    worktreeID: WorktreeFilesystemContext(repoId: repositoryID, rootPath: rootPath)
                ]
            )
        )

        try await facts.expectRefreshStarted(worktreeId: worktreeID, requestSequence: 1)
        _ = try await facts.expectRefreshClosed(worktreeId: worktreeID, requestSequence: 1)
        #expect(await providerCallCount.value == 1)
        #expect(await actor.worktreeTasks.isEmpty)
        #expect(await actor.pendingByWorktreeId[worktreeID] == nil)
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[worktreeID] == nil)

        await actor.setRepositoryFactAttention(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [worktreeID],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            warmAutomaticWorktreeIds: [],
            backgroundOnlyAutomaticWorktreeIds: []
        )
        #expect(await providerCallCount.value == 1)

        await actor.setRepositoryFactAttention(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [worktreeID],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            warmAutomaticWorktreeIds: [worktreeID],
            backgroundOnlyAutomaticWorktreeIds: []
        )
        #expect(await providerCallCount.value == 1)
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[worktreeID] != nil)

        await actor.setRepositoryFactAttention(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [worktreeID],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            warmAutomaticWorktreeIds: [],
            backgroundOnlyAutomaticWorktreeIds: []
        )

        #expect(await actor.automaticRefreshDeadlineByWorktreeId[worktreeID] == nil)
        #expect(await actor.logicalDebtSnapshot().futureAutomaticCount == 0)
        await actor.shutdown()
    }

    @Test("background-only promotion starts one ordinary-tier baseline without duplication")
    func backgroundOnlyPromotionStartsOneOrdinaryTierBaseline() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = AutomaticPacingCallCounter()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(50),
            visibleSidebarCadence: .milliseconds(100),
            openPaneCadence: .milliseconds(200),
            backgroundCadence: .milliseconds(400),
            backgroundStripeCount: 1
        )
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in
                await calls.increment()
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            },
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )
        await actor.start()

        let worktreeId = UUIDv7.generate()
        await actor.setRepositoryFactAttention(
            activePaneWorktreeId: nil,
            sidebarAttendedWorktreeIds: [worktreeId],
            visibleActiveTabWorktreeIds: [],
            openWorktreeIds: [],
            warmAutomaticWorktreeIds: [worktreeId],
            backgroundOnlyAutomaticWorktreeIds: [worktreeId]
        )
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .visibilityCoalescing
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
        await actor.waitForVisibilityAdmission()
        await bus.post(
            automaticPacingRegistrationEnvelope(
                seq: 1,
                worktreeId: worktreeId,
                rootPath: URL(fileURLWithPath: "/tmp/background-promotion-\(worktreeId)")
            )
        )
        #expect(try await facts.expectHandledEnvelope(seq: 1) == .routed)
        #expect(await actor.rootPathByWorktreeId[worktreeId] != nil)
        #expect(await calls.value == 0)

        await setPromotedAttention(actor: actor, worktreeId: worktreeId)
        try await facts.expectRefreshStarted(worktreeId: worktreeId, requestSequence: 1)
        _ = try await facts.expectRefreshClosed(worktreeId: worktreeId, requestSequence: 1)
        #expect(await calls.value == 1)
        #expect(await actor.worktreeTasks[worktreeId] == nil)
        await setPromotedAttention(actor: actor, worktreeId: worktreeId)
        #expect(await calls.value == 1)
        let lastStart = try #require(await actor.lastAutomaticStartAtByWorktreeId[worktreeId])
        let nextDeadline = try #require(
            await actor.automaticRefreshDeadlineByWorktreeId[worktreeId]
        )
        #expect(nextDeadline >= lastStart + policy.visibleSidebarCadence)

        await actor.shutdown()
    }

    @Test(
        "active-pane invalidation bypasses automatic pacing",
        arguments: [false, true]
    )
    func activePaneInvalidationBypassesAutomaticPacing(
        usesRemoteReferenceRefresh: Bool
    ) async {
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/active-pacing-\(UUIDv7.generate())")
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                minimumAutomaticStartInterval: .milliseconds(10)
            )
        )
        await actor.setActivePaneWorktree(worktreeId: worktreeId)
        await actor.enqueueImmediateRefresh(
            FileChangeset(
                worktreeId: worktreeId,
                rootPath: rootPath,
                paths: ["tracked.txt"],
                timestamp: ContinuousClock().now,
                batchSeq: 1
            ),
            triggerSource: usesRemoteReferenceRefresh
                ? .remoteReferenceRefresh
                : .filesystemChange
        )

        #expect(
            await !actor.requiresAutomaticStartPacing(
                worktreeId: worktreeId,
                isExplicit: false
            )
        )
        await actor.shutdown()
    }

    @Test(
        "lower-tier invalidation starts obey process pacing",
        arguments: [false, true]
    )
    func lowerTierInvalidationStartsObeyProcessPacing(
        usesRemoteReferenceRefresh: Bool
    ) async throws {
        let scenario = try await prepareLowerTierPacingScenario()
        let facts = scenario.facts
        let bus = scenario.bus
        let clock = scenario.clock
        let gate = scenario.gate
        let policy = scenario.policy
        let actor = scenario.actor
        let worktreeIds = scenario.worktreeIds
        let rootPaths = scenario.rootPaths

        if usesRemoteReferenceRefresh {
            await actor.enqueueImmediateRefreshIfRegistered(
                worktreeId: worktreeIds[0],
                triggerSource: .remoteReferenceRefresh
            )
            #expect(
                await actor.requiresAutomaticStartPacing(
                    worktreeId: worktreeIds[0],
                    isExplicit: false
                )
            )
            await actor.shutdown()
            return
        }

        for index in worktreeIds.indices {
            await bus.post(
                automaticPacingFilesChangedEnvelope(
                    seq: UInt64(index + 3),
                    worktreeId: worktreeIds[index],
                    rootPath: rootPaths[index],
                    batchSeq: UInt64(index + 1)
                )
            )
        }

        #expect(try await facts.expectHandledEnvelope(seq: 4) == .routed)
        #expect(await gate.count == 2)
        let nextAutomaticStartAt = await actor.nextAutomaticStartAt
        let deadlineClockNow = await actor.deadlineClock.now
        clock.advance(by: max(.zero, nextAutomaticStartAt - deadlineClockNow))
        let thirdStartLabels = try await gate.waitForArrival(3)
        #expect(thirdStartLabels.count == 3)
        #expect(await gate.activeCallCount == 1)
        let thirdStartedIndex = try #require(rootPaths.firstIndex { $0.lastPathComponent == thirdStartLabels[2] })
        _ = try await facts.expectNextRefreshStarted(worktreeId: worktreeIds[thirdStartedIndex])
        clock.advance(by: policy.minimumAutomaticStartInterval - .milliseconds(1))
        #expect(await gate.count == 3)
        clock.advance(by: .milliseconds(1))
        let fourthStartLabels = try await gate.waitForArrival(4)
        #expect(fourthStartLabels.count == 4)
        #expect(await gate.activeCallCount == 2)
        let fourthStartedIndex = try #require(rootPaths.firstIndex { $0.lastPathComponent == fourthStartLabels[3] })
        _ = try await facts.expectNextRefreshStarted(worktreeId: worktreeIds[fourthStartedIndex])

        #expect(await gate.distinctCalledLabelCount == 2)
        #expect(await gate.activeCallCount <= 2)
        await gate.releaseAll()
        await actor.shutdown()
    }
}

private struct PreparedLowerTierPacingScenario {
    let facts: FactRecorder<GitProjectorScope, GitProjectorFact>
    let bus: EventBus<RuntimeEnvelope>
    let clock: TestPushClock
    let gate: AutomaticPacingStatusGate
    let policy: AppPolicies.GitRefresh.Policy
    let actor: GitWorkingDirectoryProjector
    let worktreeIds: [UUID]
    let rootPaths: [URL]
}

private func prepareLowerTierPacingScenario() async throws -> PreparedLowerTierPacingScenario {
    let source = GitProjectorFactSource()
    let facts = try source.attach()
    let bus = EventBus<RuntimeEnvelope>()
    let clock = TestPushClock()
    let gate = AutomaticPacingStatusGate()
    let policy = automaticPacingPolicy()
    let provider = StubGitWorkingTreeStatusProvider { rootPath in
        await gate.recordAndWait(rootPath.lastPathComponent)
        return GitWorkingTreeStatus(
            summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
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
    await actor.start()

    let worktreeIds = [UUIDv7.generate(), UUIDv7.generate()]
    let rootPaths = [
        URL(fileURLWithPath: "/tmp/lower-tier-pacing-a-\(UUIDv7.generate())"),
        URL(fileURLWithPath: "/tmp/lower-tier-pacing-b-\(UUIDv7.generate())"),
    ]
    await actor.setSidebarVisibleWorktrees(Set(worktreeIds))
    for index in worktreeIds.indices {
        await bus.post(
            automaticPacingRegistrationEnvelope(
                seq: UInt64(index + 1),
                worktreeId: worktreeIds[index],
                rootPath: rootPaths[index]
            )
        )
    }
    let firstStartLabels = try await gate.waitForArrival(1)
    #expect(firstStartLabels.count == 1)
    let firstStartedIndex = try #require(rootPaths.firstIndex { $0.lastPathComponent == firstStartLabels[0] })
    let firstRequestSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeIds[firstStartedIndex])
    _ = try await source.expectDeadlineRegistered(facts: facts, kind: .governorPacing)
    await clock.waitForPendingSleepCount(exactly: 2)
    clock.advance(by: policy.minimumAutomaticStartInterval)
    let secondStartLabels = try await gate.waitForArrival(2)
    #expect(secondStartLabels.count == 2)
    let secondStartedIndex = try #require(rootPaths.firstIndex { $0.lastPathComponent == secondStartLabels[1] })
    let secondRequestSequence = try await facts.expectNextRefreshStarted(worktreeId: worktreeIds[secondStartedIndex])
    #expect(await gate.activeCallCount == 2)
    await gate.releaseArrivedCalls()
    _ = try await facts.expectRefreshClosed(
        worktreeId: worktreeIds[firstStartedIndex], requestSequence: firstRequestSequence
    )
    _ = try await facts.expectRefreshClosed(
        worktreeId: worktreeIds[secondStartedIndex], requestSequence: secondRequestSequence
    )
    #expect(await actor.worktreeTasks.isEmpty)
    return PreparedLowerTierPacingScenario(
        facts: facts,
        bus: bus,
        clock: clock,
        gate: gate,
        policy: policy,
        actor: actor,
        worktreeIds: worktreeIds,
        rootPaths: rootPaths
    )
}

private func setPromotedAttention(
    actor: GitWorkingDirectoryProjector,
    worktreeId: UUID
) async {
    await actor.setRepositoryFactAttention(
        activePaneWorktreeId: nil,
        sidebarAttendedWorktreeIds: [worktreeId],
        visibleActiveTabWorktreeIds: [],
        openWorktreeIds: [],
        warmAutomaticWorktreeIds: [worktreeId],
        backgroundOnlyAutomaticWorktreeIds: []
    )
}

private actor AutomaticPacingCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func automaticPacingPolicy() -> AppPolicies.GitRefresh.Policy {
    AppPolicies.GitRefresh.Policy(
        activePaneCadence: .milliseconds(500),
        visibleSidebarCadence: .seconds(1),
        openPaneCadence: .seconds(2),
        backgroundCadence: .seconds(4),
        backgroundStripeCount: 1,
        maxConcurrentStatusComputes: 4,
        visibleSidebarMaxConcurrent: 2,
        minimumAutomaticStartInterval: .milliseconds(10)
    )
}

private actor AutomaticPacingStatusGate {
    private var labels: [String] = []
    private var activeCallsByLabel: [String: Int] = [:]
    private let callArrivals: [HeldStep<[String]>] = (1...4).map { count in
        let arrival = HeldStep<[String]>("automatic pacing status provider call \(count)")
        return arrival
    }

    var count: Int { labels.count }
    var distinctCalledLabelCount: Int { Set(labels).count }
    var activeCallCount: Int { activeCallsByLabel.values.reduce(0, +) }

    func recordAndWait(_ label: String) async {
        labels.append(label)
        activeCallsByLabel[label, default: 0] += 1
        defer {
            let remaining = activeCallsByLabel[label, default: 0] - 1
            activeCallsByLabel[label] = remaining == 0 ? nil : remaining
        }
        if labels.count <= callArrivals.count {
            try? await callArrivals[labels.count - 1].arrive(labels)
        }
    }

    func waitForArrival(_ callNumber: Int) async throws -> [String] {
        try await callArrivals[callNumber - 1].firstArrival()
    }

    func releaseAll() {
        for arrival in callArrivals { arrival.release() }
    }

    func releaseArrivedCalls() {
        // HeldStep release is sticky: future paced calls must stay held so
        // completion duty cannot move the admission deadline under the test.
        for arrival in callArrivals.prefix(labels.count) { arrival.release() }
    }
}

private func automaticPacingRegistrationEnvelope(
    seq: UInt64,
    worktreeId: UUID,
    rootPath: URL
) -> RuntimeEnvelope {
    .system(
        SystemEnvelope(
            source: .builtin(.filesystemWatcher),
            seq: seq,
            timestamp: ContinuousClock().now,
            event: .topology(
                .worktreeRegistered(
                    worktreeId: worktreeId,
                    repoId: worktreeId,
                    rootPath: rootPath
                )
            )
        )
    )
}

private func automaticPacingFilesChangedEnvelope(
    seq: UInt64,
    worktreeId: UUID,
    rootPath: URL,
    batchSeq: UInt64
) -> RuntimeEnvelope {
    .worktree(
        WorktreeEnvelope(
            source: .system(.builtin(.filesystemWatcher)),
            seq: seq,
            timestamp: ContinuousClock().now,
            repoId: worktreeId,
            worktreeId: worktreeId,
            event: .filesystem(
                .filesChanged(
                    changeset: FileChangeset(
                        worktreeId: worktreeId,
                        rootPath: rootPath,
                        paths: ["tracked-\(batchSeq).txt"],
                        timestamp: ContinuousClock().now,
                        batchSeq: batchSeq
                    )
                )
            )
        )
    )
}
