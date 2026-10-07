import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("RemoteReferenceRefreshActor")
struct RemoteReferenceRefreshActorTests {

    @Test("explicit performance outcomes count each terminal attempt and suppress zero")
    func explicitPerformanceOutcomesAreBounded() {
        var accumulator = RemoteReferencePerformanceAccumulator()
        accumulator.increment(\.explicitAdmitted)
        accumulator.increment(\.explicitAdmitted)
        accumulator.recordExplicitSettlement(.completed, count: 2)
        accumulator.recordExplicitSettlement(.failed, count: 1)
        accumulator.recordExplicitSettlement(.obsolete, count: 1)
        accumulator.recordExplicitSettlement(.cancelled, count: 1)
        accumulator.recordExplicitSettlement(.failed, count: 0)

        let snapshot = accumulator.takeSnapshot()
        #expect(snapshot.explicitAdmitted == 2)
        #expect(snapshot.explicitSettledCompleted == 2)
        #expect(snapshot.explicitSettledFailed == 1)
        #expect(snapshot.explicitSettledObsolete == 1)
        #expect(snapshot.explicitSettledCancelled == 1)
    }

    @Test("explicit repository update reports a genuine promotion failure")
    func explicitRepositoryUpdateReportsPromotionFailure() async throws {
        let fixture = RemoteReferenceRefreshFixture(promotionFailuresRemaining: 1)
        let actor = makeFailedPromotionReconciliationTestActor(fixture)
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )

        let admission = await actor.startExplicitRepositoryUpdate(
            repoId: fixture.repoId,
            attemptId: UUIDv7.generate()
        )
        let lease = try #require(admission.acceptedLease)

        #expect(await lease.settlement() == .failed)
        #expect(await fixture.acceptanceRecorder.localInstallationCount == 2)
        #expect(await fixture.acceptanceRecorder.invalidationCount == 1)
        #expect(await fixture.acceptanceRecorder.acceptanceCount == 0)
        #expect(await fixture.acceptanceRecorder.recomputationOrigins == [fixture.originA])
        await actor.shutdown()
    }

    @Test("explicit repository update remains admitted while remote capacity is occupied")
    func explicitRepositoryUpdateWaitsForCapacity() async throws {
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let actor = RemoteReferenceRefreshActor(provider: fixture.provider, maximumConcurrentFetches: 1)
        let secondRepoID = UUIDv7.generate()
        let secondWorktreeID = UUIDv7.generate()
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.register(
            repoId: secondRepoID,
            worktreeId: secondWorktreeID,
            repositoryPath: fixture.repositoryPath.appending(path: "second"),
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await fixture.provider.waitUntilStageSuspended()

        let admission = await actor.startExplicitRepositoryUpdate(
            repoId: secondRepoID,
            attemptId: UUIDv7.generate()
        )
        let lease = try #require(admission.acceptedLease)
        #expect(await fixture.provider.stageCount == 1)

        await fixture.provider.releaseStage()
        await fixture.provider.waitForStageCount(2)
        await fixture.provider.waitUntilStageSuspended()
        await fixture.provider.releaseStage()
        #expect(await lease.settlement() == .completed)
        await actor.shutdown()
    }

    @Test("explicit repository update without remote registration is not applicable")
    func explicitRepositoryUpdateWithoutRegistrationIsNotApplicable() async {
        let actor = RemoteReferenceRefreshActor()

        let admission = await actor.startExplicitRepositoryUpdate(
            repoId: UUIDv7.generate(),
            attemptId: UUIDv7.generate()
        )

        #expect(admission.acceptedLease == nil)
        await actor.shutdown()
    }

    @Test("cold explicit repository update remains admitted through remote child settlement")
    func coldExplicitRepositoryUpdateWaitsForPhysicalSettlement() async throws {
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let performanceRecorder = RemoteReferencePerformanceRecorderSpy()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            performanceRecorder: performanceRecorder
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )

        let admission = await actor.startExplicitRepositoryUpdate(
            repoId: fixture.repoId,
            attemptId: UUIDv7.generate()
        )
        let lease = try #require(admission.acceptedLease)
        await fixture.provider.waitUntilStageSuspended()
        let admissionPerformance = performanceRecorder.combinedSnapshot
        #expect(admissionPerformance.explicitAdmitted == 1)
        #expect(admissionPerformance.explicitSettledCompleted == 0)
        #expect(admissionPerformance.automaticWithoutDemandStarted == 0)

        await fixture.provider.releaseStage()
        #expect(await lease.settlement() == .completed)
        await actor.waitUntilIdle()
        #expect(await fixture.provider.promoteCount == 1)
        let settlementPerformance = performanceRecorder.combinedSnapshot
        #expect(settlementPerformance.explicitAdmitted == 1)
        #expect(settlementPerformance.explicitSettledCompleted == 1)
        #expect(settlementPerformance.automaticWithoutDemandStarted == 0)

        await actor.shutdown()
    }

    @Test("current demanded stage promotes and targets represented worktrees")
    func currentDemandPromotesAndRecomputes() async throws {
        let fixture = RemoteReferenceRefreshFixture()
        let performanceRecorder = RemoteReferencePerformanceRecorderSpy()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            performanceRecorder: performanceRecorder,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        #expect(await fixture.acceptanceRecorder.localInstallationCount == 1)
        #expect(await fixture.acceptanceRecorder.acceptanceCount == 0)
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await actor.waitUntilIdle()

        #expect(await fixture.provider.stageCount == 1)
        #expect(await fixture.provider.promoteCount == 1)
        #expect(await fixture.provider.cleanupCount == 1)
        let accepted = try #require(await fixture.acceptanceRecorder.lastAcceptance)
        #expect(accepted.repoId == fixture.repoId)
        #expect(accepted.expectedOrigin == fixture.originA)
        #expect(await fixture.acceptanceRecorder.lastWorktreeIds == [fixture.worktreeId])
        #expect(await fixture.acceptanceRecorder.acceptanceCount == 1)
        let performance = performanceRecorder.combinedSnapshot
        #expect(performance.demandChanged == 1)
        #expect(performance.admissionAdmitted == 1)
        #expect(performance.stagingStarted == 1)
        #expect(performance.stagingCompleted == 1)
        #expect(performance.promotionStarted == 1)
        #expect(performance.promotionCompleted == 1)
        #expect(performance.publicationLocalAccepted == 1)
        #expect(performance.publicationPromoted == 1)
        #expect(performance.cleanupSucceeded == 1)
        #expect(performanceRecorder.settlements.contains { $0.physicalActive == 1 })
        #expect(performanceRecorder.settlements.last?.physicalActive == 0)

        await actor.shutdown()
    }

    @Test("equal registration performs no provider work or acceptance callback")
    func equalRegistrationIsSuppressedBeforeProviderCapture() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        let captureCount = await fixture.provider.captureCount
        let cleanupAbandonedCount = await fixture.provider.cleanupAbandonedCount
        let acceptanceCount = await fixture.acceptanceRecorder.acceptanceCount

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )

        #expect(await fixture.provider.captureCount == captureCount)
        #expect(await fixture.provider.cleanupAbandonedCount == cleanupAbandonedCount)
        #expect(await fixture.acceptanceRecorder.acceptanceCount == acceptanceCount)
        await actor.shutdown()
    }

    @Test("topology replacement captures local authority once per changed repository")
    func topologyReplacementCapturesOncePerChangedRepository() async {
        let fixture = RemoteReferenceRefreshFixture()
        let secondWorktreeId = UUIDv7.generate()
        let actor = RemoteReferenceRefreshActor(provider: fixture.provider)

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        let captureCountBeforeReplacement = await fixture.provider.captureCount

        await actor.assertTopology(
            .init(
                generation: 0,
                contextsByWorktreeId: [
                    fixture.worktreeId: WorktreeFilesystemContext(
                        repoId: fixture.repoId,
                        rootPath: fixture.repositoryPath
                    ),
                    secondWorktreeId: WorktreeFilesystemContext(
                        repoId: fixture.repoId,
                        rootPath: fixture.repositoryPath.appending(path: "second-worktree")
                    ),
                ]))

        #expect(await fixture.provider.captureCount == captureCountBeforeReplacement + 1)
        let captureCountAfterReplacement = await fixture.provider.captureCount
        await actor.assertTopology(
            .init(
                generation: 0,
                contextsByWorktreeId: [
                    secondWorktreeId: WorktreeFilesystemContext(
                        repoId: fixture.repoId,
                        rootPath: fixture.repositoryPath.appending(path: "second-worktree")
                    ),
                    fixture.worktreeId: WorktreeFilesystemContext(
                        repoId: fixture.repoId,
                        rootPath: fixture.repositoryPath
                    ),
                ]))
        #expect(await fixture.provider.captureCount == captureCountAfterReplacement)
        await actor.shutdown()
    }

    @Test("cleanup failure retries independently without reopening source work")
    func cleanupFailureRetriesWithoutSourceBackoff() async {
        let fixture = RemoteReferenceRefreshFixture(cleanupFailuresRemaining: 1)
        let clock = TestPushClock()
        let monotonicNow = RemoteReferenceMonotonicNow()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            monotonicNow: { monotonicNow.value },
            sleepClock: clock,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await actor.waitUntilIdle()

        #expect(await fixture.provider.stageCount == 1)
        #expect(await fixture.provider.cleanupCount == 1)
        #expect(await fixture.acceptanceRecorder.acceptanceCount == 1)

        let retryDelay = AppPolicies.RemoteReferenceRefresh.capacityRecheckDelay
        await clock.waitForPendingSleepCount(atLeast: 1)
        monotonicNow.advance(by: retryDelay)
        clock.advance(by: retryDelay)
        await fixture.provider.waitForCleanupCount(2)

        #expect(await fixture.provider.stageCount == 1)
        #expect(await fixture.provider.cleanupCount == 2)
        await actor.shutdown()
    }

    @Test("final unregister retains failed cleanup custody until retry succeeds")
    func finalUnregisterRetainsCleanupDebt() async {
        let fixture = RemoteReferenceRefreshFixture(cleanupFailuresRemaining: 1)
        let clock = TestPushClock()
        let monotonicNow = RemoteReferenceMonotonicNow()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            monotonicNow: { monotonicNow.value },
            sleepClock: clock
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await actor.waitUntilIdle()
        #expect(await fixture.provider.cleanupCount == 1)

        await actor.unregister(worktreeId: fixture.worktreeId, repoId: fixture.repoId)
        let retryDelay = AppPolicies.RemoteReferenceRefresh.capacityRecheckDelay
        await clock.waitForPendingSleepCount(atLeast: 1)
        monotonicNow.advance(by: retryDelay)
        clock.advance(by: retryDelay)
        await fixture.provider.waitForCleanupCount(2)

        #expect(await fixture.provider.cleanupCount == 2)
        await actor.shutdown()
    }

    @Test("final unregister rejects local acceptance resumed during identity invalidation")
    func finalUnregisterRejectsSuspendedLocalAcceptance() async {
        let fixture = RemoteReferenceRefreshFixture(suspendCapture: true)
        let invalidationGate = RemoteReferenceInvalidationGate()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
                if case .invalidated = update {
                    await invalidationGate.suspendInvalidation()
                }
            }
        )
        let registrationTask = Task {
            await actor.register(
                repoId: fixture.repoId,
                worktreeId: fixture.worktreeId,
                repositoryPath: fixture.repositoryPath,
                remoteName: "origin",
                expectedOrigin: fixture.originA
            )
        }
        await fixture.provider.waitUntilCaptureSuspended()

        let unregisterTask = Task {
            await actor.unregister(worktreeId: fixture.worktreeId, repoId: fixture.repoId)
        }
        await invalidationGate.waitUntilInvalidationSuspended()
        await fixture.provider.releaseCapture()
        await registrationTask.value

        #expect(await fixture.acceptanceRecorder.localInstallationCount == 0)

        await invalidationGate.releaseInvalidation()
        await unregisterTask.value
        await actor.shutdown()
    }

    @Test("genuine promotion failure retries only at the source failure floor")
    func genuineFailureUsesSourceBackoff() async {
        let fixture = RemoteReferenceRefreshFixture(promotionFailuresRemaining: 1)
        let clock = TestPushClock()
        let monotonicNow = RemoteReferenceMonotonicNow()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            monotonicNow: { monotonicNow.value },
            sleepClock: clock
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await actor.waitUntilIdle()
        #expect(await fixture.provider.stageCount == 1)

        let retryFloor = AppPolicies.RemoteReferenceRefresh.automaticFailureRetryFloor
        let beforeRetryFloor = retryFloor - .seconds(1)
        await clock.waitForPendingSleepCount(atLeast: 1)
        monotonicNow.advance(by: beforeRetryFloor)
        clock.advance(by: beforeRetryFloor)
        #expect(await fixture.provider.stageCount == 1)

        monotonicNow.advance(by: .seconds(1))
        clock.advance(by: .seconds(1))
        await fixture.provider.waitForStageCount(2)
        await actor.waitUntilIdle()
        #expect(await fixture.provider.stageCount == 2)
        await actor.shutdown()
    }

    @Test("origin change during staged fetch cleans without promotion")
    func staleOriginCannotPromote() async {
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        let acceptanceCountBeforeFetch = await fixture.acceptanceRecorder.acceptanceCount
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await fixture.provider.waitUntilStageStarted()
        await fixture.provider.waitUntilStageSuspended()

        let originChangeTask = Task {
            await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)
        }
        await fixture.provider.releaseStage()
        _ = await originChangeTask.value
        await actor.waitUntilIdle()

        #expect(await fixture.provider.promoteCount == 0)
        #expect(await fixture.provider.cleanupCount == 1)
        #expect(await fixture.acceptanceRecorder.acceptanceCount == acceptanceCountBeforeFetch)

        await actor.shutdown()
    }

    @Test("origin replacement stays unauthorized until its staged fetch promotes")
    func originReplacementWaitsForCurrentPromotionBeforeRestoringAuthority() async {
        let oldOriginReference = GitRemoteTrackingReference(
            canonicalRefName: "refs/remotes/origin/main",
            oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            },
            onPromotedRecomputation: { acceptance in
                await fixture.acceptanceRecorder.recordRecomputation(acceptance)
                return .completed
            }
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await fixture.provider.configureSnapshot(
            remoteURL: fixture.originB,
            references: [oldOriginReference]
        )

        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)

        #expect(await fixture.acceptanceRecorder.invalidationCount == 1)
        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.acceptanceRecorder.promotedAcceptanceOrigins.isEmpty)
        #expect(await fixture.provider.stageCount == 0)
        #expect(await fixture.acceptanceRecorder.recomputationOrigins.isEmpty)

        await actor.setDemand(repositoryIds: [fixture.repoId])
        await fixture.provider.waitUntilStageSuspended()

        #expect(await fixture.provider.stageCount == 1)
        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.acceptanceRecorder.promotedAcceptanceOrigins.isEmpty)
        #expect(await fixture.acceptanceRecorder.recomputationOrigins.isEmpty)

        await fixture.provider.releaseStage()
        await actor.waitUntilIdle()

        #expect(await fixture.provider.stageCount == 1)
        #expect(await fixture.provider.promoteCount == 1)
        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.acceptanceRecorder.promotedAcceptanceOrigins == [fixture.originB])
        #expect(await fixture.acceptanceRecorder.lastWorktreeIds == [fixture.worktreeId])
        #expect(await fixture.acceptanceRecorder.recomputationOrigins == [fixture.originB])
        await actor.shutdown()
    }

    @Test("initial origin discovery accepts local refs once but later rediscovery waits for fetch")
    func initialOriginDiscoveryAcceptsLocalRefsOnlyOnce() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )

        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])

        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: nil)
        await fixture.provider.configureSnapshot(remoteURL: fixture.originB, references: [])
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)

        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.provider.stageCount == 0)
        await actor.shutdown()
    }

    @Test("final unregister does not reopen initial origin discovery")
    func finalUnregisterPreservesResolvedOriginHistory() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        await actor.unregister(worktreeId: fixture.worktreeId, repoId: fixture.repoId)
        await fixture.provider.configureSnapshot(remoteURL: fixture.originB, references: [])
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)

        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.provider.stageCount == 0)
        await actor.shutdown()
    }

    @Test("topology removal does not reopen initial origin discovery")
    func topologyRemovalPreservesResolvedOriginHistory() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        await actor.assertTopology(.init(generation: 0, contextsByWorktreeId: [:]))
        await fixture.provider.configureSnapshot(remoteURL: fixture.originB, references: [])
        await actor.assertTopology(
            .init(
                generation: 0,
                contextsByWorktreeId: [
                    fixture.worktreeId: WorktreeFilesystemContext(
                        repoId: fixture.repoId,
                        rootPath: fixture.repositoryPath
                    )
                ]))
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)

        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA])
        #expect(await fixture.provider.stageCount == 0)
        await actor.shutdown()
    }

    @Test("final unregister restores local acceptance for the same origin")
    func finalUnregisterRestoresSameOriginLocalAcceptance() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        await actor.unregister(worktreeId: fixture.worktreeId, repoId: fixture.repoId)
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA, fixture.originA])
        #expect(await fixture.provider.stageCount == 0)
        await actor.shutdown()
    }

    @Test("topology restoration restores local acceptance for the same origin")
    func topologyRestorationRestoresSameOriginLocalAcceptance() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )
        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: nil
        )
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        await actor.assertTopology(.init(generation: 0, contextsByWorktreeId: [:]))
        await actor.assertTopology(
            .init(
                generation: 0,
                contextsByWorktreeId: [
                    fixture.worktreeId: WorktreeFilesystemContext(
                        repoId: fixture.repoId,
                        rootPath: fixture.repositoryPath
                    )
                ]))
        await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originA)

        #expect(await fixture.acceptanceRecorder.localAcceptanceOrigins == [fixture.originA, fixture.originA])
        #expect(await fixture.provider.stageCount == 0)
        await actor.shutdown()
    }

    @Test("no demand performs no staged fetch")
    func noDemandPerformsNoStagedFetch() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { _ in }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.waitUntilIdle()

        #expect(await fixture.provider.stageCount == 0)
        await actor.shutdown()
    }

    @Test("origin change revokes a suspended promotion before canonical mutation")
    func originChangeRevokesSuspendedPromotion() async {
        let fixture = RemoteReferenceRefreshFixture(suspendPromotion: true)
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        let acceptanceCountBeforeFetch = await fixture.acceptanceRecorder.acceptanceCount
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await fixture.provider.waitUntilPromotionSuspended()

        let originChangeTask = Task {
            await actor.setOrigin(repoId: fixture.repoId, expectedOrigin: fixture.originB)
        }
        await fixture.provider.waitForCleanupCount(1)
        await fixture.provider.releasePromotion()
        _ = await originChangeTask.value
        await actor.waitUntilIdle()

        #expect(await fixture.provider.promotionMutationCount == 0)
        #expect(await fixture.acceptanceRecorder.acceptanceCount == acceptanceCountBeforeFetch)
        await actor.shutdown()
    }

    @Test("fresh automatic demand is suppressed while explicit refresh bypasses freshness")
    func freshnessAndExplicitRefreshAdmission() async {
        let fixture = RemoteReferenceRefreshFixture()
        let actor = RemoteReferenceRefreshActor(provider: fixture.provider)

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await actor.waitUntilIdle()
        #expect(await fixture.provider.stageCount == 1)

        await actor.setDemand(repositoryIds: [])
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await actor.waitUntilIdle()
        #expect(await fixture.provider.stageCount == 1)

        await actor.refresh(repoId: fixture.repoId)
        await actor.waitUntilIdle()
        #expect(await fixture.provider.stageCount == 2)
        await actor.shutdown()
    }

    @Test("demand loss cleans staged work without promotion")
    func demandLossCleansWithoutPromotion() async {
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            onAuthorityUpdate: { update in
                await fixture.acceptanceRecorder.record(update)
            }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await fixture.provider.waitUntilStageSuspended()

        let demandLossTask = Task { await actor.setDemand(repositoryIds: []) }
        await fixture.provider.releaseStage()
        await demandLossTask.value
        await actor.waitUntilIdle()

        #expect(await fixture.provider.promoteCount == 0)
        #expect(await fixture.provider.cleanupCount == 1)
        #expect(await fixture.acceptanceRecorder.localInstallationCount == 1)
        #expect(await fixture.acceptanceRecorder.invalidationCount == 0)
        await actor.shutdown()
    }

    @Test("automatic refresh becomes eligible exactly at the freshness deadline")
    func automaticRefreshUsesFreshnessDeadline() async throws {
        let fixture = RemoteReferenceRefreshFixture()
        let clock = TestPushClock()
        let clockOrigin = clock.now
        let monotonicNow = RemoteReferenceMonotonicNow()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            monotonicNow: { monotonicNow.value },
            sleepClock: clock,
            onAuthorityUpdate: { _ in }
        )

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId])
        await clock.waitForPendingSleepCount(exactly: 1)
        let freshnessSleepGeneration = try #require(clock.pendingSleepGenerations.first)
        let freshnessDeadline = clockOrigin.advanced(by: .seconds(180))
        #expect(clock.pendingSleepDeadlines == [freshnessDeadline])
        #expect(await fixture.provider.stageCount == 1)

        monotonicNow.advance(by: .seconds(179))
        clock.advance(by: .seconds(179))
        await clock.waitForPendingSleepCount(exactly: 1)
        await clock.waitForPendingSleepGeneration(freshnessSleepGeneration)
        // The same sleeper remains registered one second before eligibility.
        #expect(clock.pendingSleepDeadlines == [freshnessDeadline])
        #expect(clock.now.duration(to: freshnessDeadline) == .seconds(1))

        monotonicNow.advance(by: .seconds(1))
        clock.advance(by: .seconds(1))
        await fixture.provider.waitForStageCount(2)
        await clock.waitForPendingSleepCount(atLeast: 1, fromGeneration: freshnessSleepGeneration + 1)
        #expect(await fixture.provider.stageCount == 2)
        await actor.shutdown()
        await clock.waitForPendingSleepCount(exactly: 0)
    }

    @Test("process capacity one defers a second demanded repository without a second start")
    func capacityOneDefersSecondRepository() async {
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let actor = RemoteReferenceRefreshActor(provider: fixture.provider)
        let secondRepoId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()

        await actor.register(
            repoId: fixture.repoId,
            worktreeId: fixture.worktreeId,
            repositoryPath: fixture.repositoryPath,
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.register(
            repoId: secondRepoId,
            worktreeId: secondWorktreeId,
            repositoryPath: fixture.repositoryPath.appending(path: "second"),
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [fixture.repoId, secondRepoId])
        await fixture.provider.waitUntilStageSuspended()
        #expect(await fixture.provider.stageCount == 1)

        let demandLossTask = Task { await actor.setDemand(repositoryIds: []) }
        await fixture.provider.releaseStage()
        await demandLossTask.value
        await actor.waitUntilIdle()

        #expect(await fixture.provider.stageCount == 1)
        await actor.shutdown()
    }

}

extension RemoteReferenceRefreshActorTests {
    @Test("expired currentness retry is consumed while fetch capacity remains occupied")
    func expiredCurrentnessRetryIsConsumedWhileCapacityRemainsOccupied() async {
        let fixture = RemoteReferenceRefreshFixture(suspendStaging: true)
        let clock = TestPushClock()
        let monotonicNow = RemoteReferenceMonotonicNow()
        let actor = RemoteReferenceRefreshActor(
            provider: fixture.provider,
            maximumConcurrentFetches: 1,
            monotonicNow: { monotonicNow.value },
            sleepClock: clock
        )
        let orderedRepoIds = [UUIDv7.generate(), UUIDv7.generate()].sorted {
            $0.uuidString < $1.uuidString
        }
        let obsoleteRepoId = orderedRepoIds[0]
        let capacityRepoId = orderedRepoIds[1]
        let obsoleteWorktreeId = UUIDv7.generate()
        let capacityWorktreeId = UUIDv7.generate()

        await actor.register(
            repoId: obsoleteRepoId,
            worktreeId: obsoleteWorktreeId,
            repositoryPath: fixture.repositoryPath.appending(path: "obsolete"),
            remoteName: "origin",
            expectedOrigin: fixture.originB
        )
        await actor.register(
            repoId: capacityRepoId,
            worktreeId: capacityWorktreeId,
            repositoryPath: fixture.repositoryPath.appending(path: "capacity"),
            remoteName: "origin",
            expectedOrigin: fixture.originA
        )
        await actor.setDemand(repositoryIds: [obsoleteRepoId, capacityRepoId])
        await fixture.provider.waitUntilStageSuspended()
        await clock.waitForPendingSleepCount(exactly: 1)
        let scheduledSleepGeneration = clock.scheduledSleepGeneration

        let retryDelay = AppPolicies.RemoteReferenceRefresh.capacityRecheckDelay
        monotonicNow.advance(by: retryDelay)
        clock.advance(by: retryDelay)
        for _ in 0..<1000 where clock.scheduledSleepGeneration == scheduledSleepGeneration {
            await Task.yield()
        }

        #expect(clock.scheduledSleepGeneration == scheduledSleepGeneration)
        #expect(clock.pendingSleepCount == 0)

        await fixture.provider.releaseStage()
        await actor.waitUntilIdle()
        await actor.shutdown()
    }
}
