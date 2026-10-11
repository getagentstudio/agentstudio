import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("GitWorkingDirectoryProjector visible tier")
struct GitWorkingDirectoryProjectorVisibleTierTests {
    @Test("sidebar-visible unknown worktree keeps background baseline and cadence")
    func sidebarVisibleUnknownWorktreeKeepsBackgroundBaselineAndCadence() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(50),
            visibleSidebarCadence: .milliseconds(100),
            openPaneCadence: .milliseconds(200),
            backgroundCadence: .milliseconds(400),
            backgroundStripeCount: 1
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let callNumber = await calls.record(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "call-\(callNumber)",
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
        try await withStartedVisibleTierProjector(actor) {
            let worktreeID = UUIDv7.generate()
            await actor.setRepositoryFactAttention(
                activePaneWorktreeId: nil,
                sidebarAttendedWorktreeIds: [],
                visibleActiveTabWorktreeIds: [],
                openWorktreeIds: [],
                warmAutomaticWorktreeIds: [worktreeID],
                backgroundOnlyAutomaticWorktreeIds: [worktreeID]
            )
            // A later worktree-specific visibility update replaces this empty delay.
            // It has a deadline fact and supplies the clock synchronization below.
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [
                        worktreeID: URL(
                            fileURLWithPath: "/tmp/unknown-background-\(worktreeID.uuidString)"
                        )
                    ]
                )
            )
            #expect(await actor.rootPathByWorktreeId[worktreeID] != nil)
            #expect(await actor.lastProcessedSidebarVisibleWorktreeIds.isEmpty)
            #expect(await actor.lastAcceptedStatusAtByWorktreeId[worktreeID] == nil)
            #expect(await actor.worktreeTasks.isEmpty)

            await actor.setSidebarVisibleWorktrees([worktreeID])
            #expect(await actor.sidebarVisibleWorktreeIds == [worktreeID])
            #expect(await actor.pendingVisibilityDeltaWorktreeIds == [worktreeID])
            _ = try await source.expectDeadlineRegistered(
                facts: facts, worktreeId: worktreeID, kind: .visibilityCoalescing)
            await clock.waitForPendingSleepCount(exactly: 2)
            clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
            await actor.waitForVisibilityAdmission()
            #expect(await actor.lastProcessedSidebarVisibleWorktreeIds == [worktreeID])
            #expect(await calls.isEmpty)

            clock.advance(
                by: policy.backgroundCadence
                    - AppPolicies.GitRefresh.visibilityChangeCoalescingWindow
            )
            await calls.waitForCount(1)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeID)
            let lastStart = try #require(await actor.lastAutomaticStartAtByWorktreeId[worktreeID])
            let nextDeadline = try #require(
                await actor.automaticRefreshDeadlineByWorktreeId[worktreeID]
            )
            #expect(nextDeadline >= lastStart + policy.backgroundCadence)
            let debt = await actor.logicalDebtSnapshot()
            #expect(debt.backgroundOnlyAutomaticCount == 1)
            #expect(debt.backgroundOnlyAutomaticDeadlineCount == 1)
            #expect(debt.backgroundOnlyAutomaticOwnedCount == 1)
            #expect(debt.backgroundOnlyResolvedVisibleTierCount == 0)
        }
    }

    @Test("automatic registration wave waits for process start pacing")
    func automaticRegistrationWaveWaitsForProcessStartPacing() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let gate = VisibleTierStatusGate()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(20),
            visibleSidebarCadence: .milliseconds(40),
            openPaneCadence: .milliseconds(80),
            backgroundCadence: .milliseconds(100),
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 4,
            backgroundMaxConcurrent: 4,
            minimumAutomaticStartInterval: .milliseconds(10)
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            _ = await calls.record(rootPath.lastPathComponent)
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
        try await withStartedVisibleTierProjector(actor, gate: gate) {
            var rootPathsByWorktreeId: [UUID: URL] = [:]
            for offset in 0..<3 {
                let worktreeID = UUID(
                    uuidString: String(format: "00000000-0000-0000-0000-%012X", offset + 1)
                )!
                rootPathsByWorktreeId[worktreeID] = URL(
                    fileURLWithPath: "/tmp/paced-registration-\(offset)"
                )
            }
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: rootPathsByWorktreeId
                )
            )
            #expect(await actor.rootPathByWorktreeId.count == 3)

            clock.advance(by: policy.backgroundCadence)
            await calls.waitForCount(1)
            _ = try await source.expectDeadlineRegistered(facts: facts, kind: .governorPacing)
            await clock.waitForPendingSleepCount(exactly: 1)
            clock.advance(by: .milliseconds(9))
            #expect(await calls.count == 1)

            clock.advance(by: .milliseconds(1))
            await calls.waitForCount(2)
            _ = try await source.expectDeadlineRegistered(facts: facts, kind: .governorPacing)
            await clock.waitForPendingSleepCount(
                exactly: 1
            )
            let thirdStartDeadline = try #require(clock.pendingSleepDeadlines.min())
            clock.advance(to: thirdStartDeadline)
            await calls.waitForCount(3)

            await gate.releaseAllAndRemainOpen()
        }
    }

    @Test("large hidden registration fleet owns one phased deadline waiter")
    func largeHiddenRegistrationFleetOwnsOneDeadlineWaiter() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(20),
            visibleSidebarCadence: .milliseconds(40),
            openPaneCadence: .milliseconds(80),
            backgroundCadence: .milliseconds(160),
            backgroundStripeCount: 16,
            maxConcurrentStatusComputes: 4,
            backgroundMaxConcurrent: 4
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            _ = await calls.record(rootPath.lastPathComponent)
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
            subscriptionBufferLimit: 512,
            factSink: source.sink
        )
        try await withStartedVisibleTierProjector(actor) {
            let worktreeIds = (0..<160).map { offset in
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", offset + 1))!
            }
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: Dictionary(
                        uniqueKeysWithValues: worktreeIds.enumerated().map { offset, worktreeId in
                            (worktreeId, URL(fileURLWithPath: "/tmp/deadline-fleet-\(offset)"))
                        }
                    )
                )
            )
            #expect(await actor.rootPathByWorktreeId.count == 160)
            _ = try await source.expectDeadlineRegistered(facts: facts, worktreeId: worktreeIds[0], kind: .automatic)
            await clock.waitForPendingSleepCount(exactly: 1)
            #expect(await calls.isEmpty)
            #expect(await actor.automaticRefreshDeadlineByWorktreeId.count == 160)

            clock.advance(by: policy.backgroundCadence)
            await calls.waitForCount(160)
            for worktreeId in worktreeIds {
                await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)
            }
            #expect(await actor.worktreeTasks.isEmpty)
            _ = try await source.expectDeadlineRegistered(facts: facts, worktreeId: worktreeIds[0], kind: .automatic)
            await clock.waitForPendingSleepCount(exactly: 1)
        }
        #expect(clock.pendingSleepCount == 0)
    }

    @Test("rapid visibility changes retain only the latest pending delta")
    func rapidVisibilityChangesRetainOnlyLatestPendingDelta() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let clock = TestPushClock()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            sleepClock: clock,
            factSink: source.sink
        )
        let firstWorktreeId = UUID()
        let latestWorktreeId = UUID()

        await actor.setSidebarVisibleWorktrees([firstWorktreeId])
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: firstWorktreeId, kind: .visibilityCoalescing)
        await clock.waitForPendingSleepCount(exactly: 1)
        await actor.setSidebarVisibleWorktrees([latestWorktreeId])
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: latestWorktreeId, kind: .visibilityCoalescing)
        await clock.waitForPendingSleepCount(exactly: 1)

        #expect(await actor.pendingVisibilityDeltaWorktreeIds == [latestWorktreeId])
        #expect(await actor.sidebarVisibleWorktreeIds == [latestWorktreeId])

        await actor.shutdown()
    }

    @Test("covered worktree visibility change waits for its tier cadence")
    func coveredWorktreeVisibilityChangeWaitsForTierCadence() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(100),
            visibleSidebarCadence: .milliseconds(200),
            openPaneCadence: .milliseconds(600),
            backgroundCadence: .milliseconds(800)
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let callNumber = await calls.record(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "call-\(callNumber)",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy
        )
        try await withStartedVisibleTierProjector(actor) {
            let worktreeId = UUID()
            let rootPath = URL(fileURLWithPath: "/tmp/covered-visibility-\(UUID().uuidString)")
            await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [worktreeId: rootPath]
                )
            )
            await calls.waitForCount(1)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)
            await actor.setActivity(worktreeId: worktreeId, isActiveInApp: false)

            await actor.setSidebarVisibleWorktrees([worktreeId])

            #expect(await actor.worktreeTasks[worktreeId] == nil)
            #expect(await calls.count == 1)
        }
    }

    @Test("160 visible worktrees stay within the visible share and make rolling progress")
    func hugeVisibleFleetUsesBoundedShareWithRollingProgress() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let gate = VisibleTierStatusGate()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(100),
            visibleSidebarCadence: .milliseconds(200),
            openPaneCadence: .milliseconds(600),
            backgroundCadence: .milliseconds(800),
            maxConcurrentStatusComputes: 4,
            activePaneMaxConcurrent: 1,
            visibleSidebarMaxConcurrent: 2,
            openPaneMaxConcurrent: 1,
            backgroundMaxConcurrent: 1,
            visibleSidebarStripeSize: 8
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            await gate.recordAndWait(rootPath.lastPathComponent)
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
            subscriptionBufferLimit: 512,
            factSink: source.sink
        )
        try await withStartedVisibleTierProjector(actor, gate: gate) {
            let worktreeIds = (0..<160).map { offset in
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", offset + 1))!
            }
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: Dictionary(
                        uniqueKeysWithValues: worktreeIds.enumerated().map { offset, worktreeId in
                            (worktreeId, URL(fileURLWithPath: "/tmp/visible-fleet-\(offset)"))
                        }
                    )
                )
            )
            #expect(await actor.rootPathByWorktreeId.count == worktreeIds.count)
            await actor.setSidebarVisibleWorktrees(Set(worktreeIds))
            _ = try await source.expectDeadlineRegistered(
                facts: facts, worktreeId: worktreeIds[0], kind: .visibilityCoalescing)
            await clock.waitForPendingSleepCount(exactly: 2)
            clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)

            await gate.waitForLabelCount(policy.visibleSidebarMaxConcurrent)
            #expect(await gate.labels.count == policy.visibleSidebarMaxConcurrent)

            for expectedCount in stride(from: 4, through: policy.visibleSidebarStripeSize, by: 2) {
                await gate.releaseAll()
                await gate.waitForLabelCount(expectedCount)
            }
            await gate.releaseAllAndRemainOpen()
            await gate.waitForLabelCount(policy.visibleSidebarStripeSize + policy.visibleSidebarMaxConcurrent)
            let admittedLabels = await gate.labels
            #expect(Set(admittedLabels).count > policy.visibleSidebarStripeSize)
            #expect(await gate.maximumInFlightCount == policy.visibleSidebarMaxConcurrent)
        }
    }

    @Test("hidden registration retains refresh debt without starting status compute until visible")
    func hiddenRegistrationDefersStatusComputeUntilVisible() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(100),
            visibleSidebarCadence: .milliseconds(200),
            openPaneCadence: .milliseconds(600),
            backgroundCadence: .milliseconds(800)
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let callNumber = await calls.record(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "call-\(callNumber)",
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
        try await withStartedVisibleTierProjector(actor) {
            let worktreeId = UUID()
            let rootPath = URL(fileURLWithPath: "/tmp/hidden-demand-\(UUID().uuidString)")
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [worktreeId: rootPath]
                )
            )
            _ = try await source.expectDeadlineRegistered(facts: facts, worktreeId: worktreeId, kind: .automatic)
            await clock.waitForPendingSleepCount(exactly: 1)
            #expect(await calls.isEmpty)
            #expect(await actor.pendingByWorktreeId[worktreeId] != nil)

            await actor.setSidebarVisibleWorktrees([worktreeId])
            _ = try await source.expectDeadlineRegistered(
                facts: facts, worktreeId: worktreeId, kind: .visibilityCoalescing)
            await clock.waitForPendingSleepCount(exactly: 2)
            clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
            await calls.waitForCount(1)
        }
    }

    @Test("unchanged cadence multiplier composes with visible tier cadence")
    func unchangedResultsLengthenPeriodicCadence() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(120),
            visibleSidebarCadence: .milliseconds(240),
            openPaneCadence: .milliseconds(720),
            backgroundCadence: .milliseconds(960),
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 1,
            unchangedStatusCadenceMultipliers: [1, 2]
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let callNumber = await calls.record(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: min(callNumber, 2), staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy
        )
        try await withStartedVisibleTierProjector(actor) {
            let worktreeId = UUID()
            let rootPath = URL(fileURLWithPath: "/tmp/adaptive-cadence-\(UUID().uuidString)")
            await actor.setSidebarVisibleWorktrees([worktreeId])
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [worktreeId: rootPath]
                )
            )
            await calls.waitForCount(1)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)
            // Status duty uses a real clock, even when scheduling uses TestPushClock.
            // CI contention can make its required cooldown longer than the base cadence.
            let clockOrigin = clock.now
            let expectedCadences = [
                policy.visibleSidebarCadence,
                policy.visibleSidebarCadence,
                policy.visibleSidebarCadence + policy.visibleSidebarCadence,
            ]
            for (index, expectedCadence) in expectedCadences.enumerated() {
                let expectedCallCount = index + 1
                let lastStart = try #require(await actor.lastAutomaticStartAtByWorktreeId[worktreeId])
                let lastCompletion = try #require(await actor.lastAutomaticCompletionAtByWorktreeId[worktreeId])
                let measuredDuty = try #require(await actor.lastAutomaticDutyByWorktreeId[worktreeId])
                let deadline = try #require(await actor.automaticRefreshDeadlineByWorktreeId[worktreeId])
                #expect(
                    deadline
                        == max(lastStart + expectedCadence, lastCompletion + policy.automaticDutyGap(for: measuredDuty))
                )

                clock.advance(to: clockOrigin.advanced(by: deadline - .milliseconds(1)))
                #expect(await calls.count == expectedCallCount)
                clock.advance(by: .milliseconds(1))
                await calls.waitForCount(expectedCallCount + 1)
                await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)
            }
        }
    }

    @Test(
        "filesystem refresh updates cadence from complete result equality",
        arguments: [false, true]
    )
    func filesystemRefreshUpdatesCadenceFromCompleteResultEquality(
        completeFactsChanged: Bool
    ) async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(20),
            visibleSidebarCadence: .milliseconds(40),
            openPaneCadence: .milliseconds(120),
            backgroundCadence: .milliseconds(160),
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 1,
            unchangedStatusCadenceMultipliers: [1, 2, 4]
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let callNumber = await calls.record(rootPath.lastPathComponent)
            let entryPath = completeFactsChanged && callNumber >= 4 ? "b.txt" : "a.txt"
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: "main",
                originResolution: .confirmedAbsent,
                entries: [
                    GitWorkingTreeStatusEntry(
                        path: entryPath,
                        hasStagedChange: false,
                        hasUnstagedChange: true,
                        isUntracked: false
                    )
                ]
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
        try await withStartedVisibleTierProjector(actor) {
            let worktreeId = UUIDv7.generate()
            let rootPath = URL(fileURLWithPath: "/tmp/adapted-filesystem-\(UUIDv7.generate())")
            await actor.setSidebarVisibleWorktrees([worktreeId])
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [worktreeId: rootPath]
                )
            )
            await calls.waitForCount(1)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)

            for expectedCallCount in 2...3 {
                let scheduledDeadline = try #require(
                    await actor.automaticRefreshDeadlineByWorktreeId[worktreeId]
                )
                let deadlineClockNow = await actor.deadlineClock.now
                clock.advance(by: max(.zero, scheduledDeadline - deadlineClockNow))
                await calls.waitForCount(expectedCallCount)
                await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)
            }
            #expect(await actor.unchangedStatusResultCountByWorktreeId[worktreeId] == 2)

            await bus.post(
                visibleTierFilesChangedEnvelope(
                    seq: 2,
                    worktreeId: worktreeId,
                    rootPath: rootPath,
                    batchSeq: 1,
                    paths: [".git/HEAD"],
                    containsGitInternalChanges: true
                )
            )
            await calls.waitForCount(4)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: worktreeId)
            if completeFactsChanged {
                #expect(await actor.unchangedStatusResultCountByWorktreeId[worktreeId] == nil)
            } else {
                #expect(await actor.unchangedStatusResultCountByWorktreeId[worktreeId] == 3)
            }

            _ = try await source.expectDeadlineRegistered(facts: facts, worktreeId: worktreeId, kind: .automatic)

            await clock.waitForPendingSleepCount(exactly: 2)

            let expectedCadence =
                completeFactsChanged
                ? policy.visibleSidebarCadence
                : policy.visibleSidebarCadence * 4
            let lastAutomaticStart = try #require(
                await actor.lastAutomaticStartAtByWorktreeId[worktreeId]
            )
            let scheduledDeadline = try #require(
                await actor.automaticRefreshDeadlineByWorktreeId[worktreeId]
            )
            #expect(scheduledDeadline >= lastAutomaticStart + expectedCadence)
            if !completeFactsChanged {
                clock.advance(by: policy.visibleSidebarCadence * 2)
                #expect(await calls.count == 4)
            }
            let deadlineClockNow = await actor.deadlineClock.now
            clock.advance(by: max(.zero, scheduledDeadline - deadlineClockNow))
            await calls.waitForCount(5)
        }
    }

    @Test("visible sidebar refreshes compose visible cadence with measured duty")
    func visibleSidebarRefreshesComposeVisibleCadenceWithMeasuredDuty() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let calls = VisibleTierCallRecorder()
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(120),
            visibleSidebarCadence: .milliseconds(120),
            openPaneCadence: .milliseconds(360),
            backgroundCadence: .milliseconds(480),
            backgroundStripeCount: 3,
            maxConcurrentStatusComputes: 4
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            let callNumber = await calls.record(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: callNumber, staged: 0, untracked: 0),
                branch: "call-\(callNumber)",
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
        try await withStartedVisibleTierProjector(actor) {
            let visibleWorktreeId = visibleTierWorktreeId(forBackgroundStripe: 2, policy: policy)
            await actor.setActivity(worktreeId: visibleWorktreeId, isActiveInApp: true)
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [
                        visibleWorktreeId: URL(
                            fileURLWithPath: "/tmp/visible-active-\(UUID().uuidString)"
                        )
                    ]
                )
            )
            await calls.waitForCount(1)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: visibleWorktreeId)

            await actor.setActivity(worktreeId: visibleWorktreeId, isActiveInApp: false)
            await actor.setSidebarVisibleWorktrees([visibleWorktreeId])
            _ = try await source.expectDeadlineRegistered(
                facts: facts, worktreeId: visibleWorktreeId, kind: .visibilityCoalescing)
            await clock.waitForPendingSleepCount(exactly: 2)
            clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
            await actor.waitForVisibilityAdmission()
            if await calls.count == 1,
                let deadline = await actor.automaticRefreshDeadlineByWorktreeId[visibleWorktreeId]
            {
                let clockNow = await actor.deadlineClock.now
                clock.advance(by: max(.zero, deadline - clockNow))
            }
            await calls.waitForCount(2)
            await waitForVisibleTierStatusCompletion(actor, worktreeId: visibleWorktreeId)
            #expect(await actor.demandTier(for: visibleWorktreeId) == .visibleSidebar)

            let lastStart = try #require(await actor.lastAutomaticStartAtByWorktreeId[visibleWorktreeId])
            let lastCompletion = try #require(await actor.lastAutomaticCompletionAtByWorktreeId[visibleWorktreeId])
            let duty = try #require(await actor.lastAutomaticDutyByWorktreeId[visibleWorktreeId])
            let expectedDeadline = max(
                lastStart + policy.visibleSidebarCadence,
                lastCompletion + policy.automaticDutyGap(for: duty)
            )
            #expect(await actor.automaticRefreshDeadlineByWorktreeId[visibleWorktreeId] == expectedDeadline)
            _ = try await source.expectDeadlineRegistered(facts: facts, worktreeId: visibleWorktreeId, kind: .automatic)
            await clock.waitForPendingSleepCount(exactly: 1)
            try await advanceVisibleDeadline(actor, clock, visibleWorktreeId, cadence: policy.visibleSidebarCadence)
            await calls.waitForCount(3)
        }
    }

    @Test("demotion preserves pending refresh debt until visibility returns")
    func demotionPreservesPendingRefreshDebtUntilVisibilityReturns() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let gate = VisibleTierStatusGate()
        let policy = AppPolicies.GitRefresh.Policy(
            maxConcurrentStatusComputes: 1,
            visibleSidebarMaxConcurrent: 1
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            await gate.recordAndWait(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: rootPath.lastPathComponent,
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
        try await withStartedVisibleTierProjector(actor, gate: gate) {
            let blockingWorktreeId = UUID()
            let pendingWorktreeId = UUID()
            await actor.setActivity(worktreeId: blockingWorktreeId, isActiveInApp: true)
            let blockingRootPath = URL(
                fileURLWithPath: "/tmp/demotion-blocking-\(UUID().uuidString)"
            )
            let pendingRootPath = URL(
                fileURLWithPath: "/tmp/demotion-pending-\(UUID().uuidString)"
            )
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 1,
                    rootPathsByWorktreeId: [blockingWorktreeId: blockingRootPath]
                )
            )
            await gate.waitForLabelCount(1)

            await actor.setSidebarVisibleWorktrees([pendingWorktreeId])
            await actor.assertTopology(
                visibleTierTopologyAssertion(
                    generation: 2,
                    rootPathsByWorktreeId: [
                        blockingWorktreeId: blockingRootPath,
                        pendingWorktreeId: pendingRootPath,
                    ]
                )
            )
            #expect(await actor.pendingByWorktreeId[pendingWorktreeId] != nil)

            await actor.setSidebarVisibleWorktrees([])
            #expect(await actor.pendingByWorktreeId[pendingWorktreeId] != nil)

            let blockingStatusTask = await actor.worktreeTasks[blockingWorktreeId]
            await gate.releaseFirst(containing: "demotion-blocking")
            await blockingStatusTask?.value
            #expect(await gate.labels.count == 1)
            #expect(await actor.pendingByWorktreeId[pendingWorktreeId] != nil)

            await actor.setSidebarVisibleWorktrees([pendingWorktreeId])
            _ = try await source.expectDeadlineRegistered(
                facts: facts, worktreeId: pendingWorktreeId, kind: .visibilityCoalescing)
            await clock.waitForPendingSleepCount(exactly: 2)
            clock.advance(by: AppPolicies.GitRefresh.visibilityChangeCoalescingWindow)
            await gate.waitForLabel(containing: "demotion-pending")

            await gate.releaseAll()
        }
    }

    @Test("active pane reservation admits before merely visible sidebar worktree")
    func activePaneReservationAdmitsBeforeMerelyVisibleSidebarWorktree() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let gate = VisibleTierStatusGate()
        let policy = AppPolicies.GitRefresh.Policy(
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 4,
            activePaneMaxConcurrent: 1
        )
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            await gate.recordAndWait(rootPath.lastPathComponent)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 1, staged: 0, untracked: 0),
                branch: rootPath.lastPathComponent,
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: policy
        )
        try await withStartedVisibleTierProjector(actor, gate: gate) {
            let runningWorktreeIds = (0..<policy.maxConcurrentStatusComputes).map { _ in UUID() }
            await actor.setSidebarVisibleWorktrees(Set(runningWorktreeIds))
            for (offset, runningWorktreeId) in runningWorktreeIds.enumerated() {
                await bus.post(
                    visibleTierFilesChangedEnvelope(
                        seq: UInt64(offset + 1),
                        worktreeId: runningWorktreeId,
                        rootPath: URL(fileURLWithPath: "/tmp/visible-running-\(offset)-\(UUID().uuidString)"),
                        batchSeq: 1
                    )
                )
            }
            await gate.waitForLabelCount(policy.visibleSidebarMaxConcurrent)

            let visibleWorktreeId = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
            let activePaneWorktreeId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            await actor.setSidebarVisibleWorktrees(Set(runningWorktreeIds).union([visibleWorktreeId]))
            await actor.setActivePaneWorktree(worktreeId: activePaneWorktreeId)
            await bus.post(
                visibleTierFilesChangedEnvelope(
                    seq: 10,
                    worktreeId: visibleWorktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/visible-pending-\(UUID().uuidString)"),
                    batchSeq: 1
                )
            )
            await bus.post(
                visibleTierFilesChangedEnvelope(
                    seq: 11,
                    worktreeId: activePaneWorktreeId,
                    rootPath: URL(fileURLWithPath: "/tmp/active-pane-pending-\(UUID().uuidString)"),
                    batchSeq: 1
                )
            )

            await gate.waitForLabelCount(policy.visibleSidebarMaxConcurrent + 1)
            let labels = await gate.labels
            #expect(labels.contains(where: { $0.contains("active-pane-pending") }))

            await gate.releaseAll()
        }
    }
}
