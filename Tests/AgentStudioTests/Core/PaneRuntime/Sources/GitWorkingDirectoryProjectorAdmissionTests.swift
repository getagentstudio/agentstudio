import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("GitWorkingDirectoryProjector admission")
struct GitWorkingDirectoryProjectorAdmissionTests {
    @Test("quarantine discards orphaned capacity rearm state")
    func quarantineDiscardsOrphanedCapacityRearmState() async {
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/admission-rearm-quarantine-\(worktreeId)")
        let pathProbe = RootPathProbeRecorder(missingRootPaths: [rootPath])
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { _ in nil },
            coalescingWindow: .zero,
            pathExistenceProbe: { probedRootPath in
                pathProbe.recordExistence(probedRootPath)
            }
        )
        await actor.scheduleCapacityRetry(
            for: admissionFilesystemChangeset(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1),
            reason: .readCapacityExceeded,
            afterPhysicalCompletionGeneration: nil
        )
        #expect(await actor.capacityRearmedWorktreeIds == Set([worktreeId]))

        await actor.expireCapacityRetry(worktreeId: worktreeId)

        #expect(await actor.quarantinedWorktreeIds == Set([worktreeId]))
        #expect(await actor.capacityRearmedWorktreeIds.isEmpty)
        #expect(await actor.pendingByWorktreeId[worktreeId] == nil)
        #expect(pathProbe.recordedRootPaths == [rootPath])

        await actor.shutdown()
    }

    @Test("capacity completion resumes the paid attempt and paces the next invalidation")
    func capacityCompletionResumesPaidAttemptAndPacesNextInvalidation() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let clock = TestPushClock()
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let blockingReadStarted = AdmissionAsyncReceipt()
        let blockingReadGate = HeldStep<Void>("blockingReadGate", cancellation: .holdThroughCancellation)
        let statusSnapshot = admissionCompleteStatusSnapshot()
        let blockingProvider = admissionBlockingProvider(
            physicalGate: physicalGate,
            started: blockingReadStarted,
            heldRead: blockingReadGate,
            statusSnapshot: statusSnapshot
        )
        let projectorProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveAdmissionGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in statusSnapshot }
        let policy = AppPolicies.GitRefresh.Policy(
            maxConcurrentStatusComputes: 1,
            backgroundMaxConcurrent: 1,
            capacityRetryJitterMaxDelay: .zero,
            minimumAutomaticStartInterval: .milliseconds(300)
        )
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: projectorProvider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink
        )
        await actor.start()

        let blockingRead = Task {
            await blockingProvider.statusResult(
                for: URL(fileURLWithPath: "/tmp/admission-capacity-pacing-blocker")
            )
        }
        await blockingReadStarted.wait()

        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/admission-capacity-pacing-\(worktreeId)")
        await actor.enqueueImmediateRefresh(
            admissionFilesystemChangeset(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 1),
            triggerSource: .filesystemChange
        )
        try await expectCapacityRetryScheduled(facts: facts, actor: actor, worktreeId: worktreeId)
        let originalRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeId]
        )
        #expect(await actor.refreshAttribution.triggerSourceByWorktreeId[worktreeId] == .filesystemChange)
        #expect(await actor.refreshAttribution.admittedTriggerSourceByWorktreeId[worktreeId] == .filesystemChange)
        #expect(await actor.refreshAttribution.admittedDemandClassByWorktreeId[worktreeId] == "background")
        #expect(await actor.refreshAttribution.admittedCadenceTierByWorktreeId[worktreeId] == "background")
        #expect(await actor.admittedDemandTierByWorktreeId[worktreeId] == .background)

        blockingReadGate.release()
        _ = await blockingRead.value
        _ = try await facts.expectRefreshClosed(
            worktreeId: worktreeId, requestSequence: originalRequestSequence
        )
        #expect(await actor.lastAcceptedStatusAtByWorktreeId[worktreeId] != nil)
        #expect(await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeId] == originalRequestSequence)
        #expect(await actor.capacityRearmedWorktreeIds.isEmpty)
        #expect(await actor.worktreeTasks.isEmpty)

        await actor.enqueueImmediateRefresh(
            admissionFilesystemChangeset(worktreeId: worktreeId, rootPath: rootPath, batchSeq: 2),
            triggerSource: .filesystemChange
        )
        #expect(await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeId] == originalRequestSequence)
        _ = try await source.expectDeadlineRegistered(
            facts: facts, worktreeId: worktreeId, kind: .governorPacing
        )
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: policy.minimumAutomaticStartInterval - .milliseconds(1))
        #expect(await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeId] == originalRequestSequence)
        clock.advance(by: .milliseconds(1))
        try await facts.expectRefreshStarted(
            worktreeId: worktreeId, requestSequence: originalRequestSequence + 1
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: worktreeId, requestSequence: originalRequestSequence + 1
        )
        #expect(
            await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeId]
                == originalRequestSequence + 1
        )
        #expect(await actor.worktreeTasks.isEmpty)

        await actor.shutdown()
    }

    @Test("same-root contention does not pause admission for a distinct active root")
    func sameRootContentionDoesNotPauseDistinctActiveRoot() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 4)
        let blockingReadStarted = AdmissionAsyncReceipt()
        let blockingReadGate = HeldStep<Void>("blockingReadGate", cancellation: .holdThroughCancellation)
        let activeReadGate = HeldStep<Void>("activeReadGate", cancellation: .holdThroughCancellation)
        let statusSnapshot = admissionCompleteStatusSnapshot()
        let contendedWorktreeId = UUIDv7.generate()
        let activeWorktreeId = UUIDv7.generate()
        let contendedRootPath = URL(fileURLWithPath: "/tmp/admission-same-root-\(contendedWorktreeId)")
        let activeRootPath = URL(fileURLWithPath: "/tmp/admission-distinct-active-\(activeWorktreeId)")
        let blockingProvider = admissionBlockingProvider(
            physicalGate: physicalGate,
            started: blockingReadStarted,
            heldRead: blockingReadGate,
            statusSnapshot: statusSnapshot
        )
        let projectorStatusCalls = StatusCallRecorder()
        let projectorProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveAdmissionGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { rootPath, _ in
            await projectorStatusCalls.record(rootPath)
            if rootPath == activeRootPath {
                try? await activeReadGate.arrive(())
            }
            return statusSnapshot
        }
        let pathProbe = RootPathProbeRecorder()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: projectorProvider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                maxConcurrentStatusComputes: 2,
                activePaneMaxConcurrent: 1,
                openPaneMaxConcurrent: 1
            ),
            factSink: source.sink,
            pathExistenceProbe: { rootPath in
                pathProbe.recordExistence(rootPath)
            }
        )

        let blockingRead = Task {
            await blockingProvider.statusResult(for: contendedRootPath)
        }
        await blockingReadStarted.wait()

        await actor.setActivity(worktreeId: contendedWorktreeId, isActiveInApp: true)
        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 1,
                rootPathsByWorktreeId: [contendedWorktreeId: contendedRootPath]
            )
        )
        try await expectCapacityRetryScheduled(facts: facts, actor: actor, worktreeId: contendedWorktreeId)
        #expect(
            await actor.capacityRetryReasonByWorktreeId[contendedWorktreeId]
                == .readAlreadyInFlight
        )

        await actor.setActivePaneWorktree(worktreeId: activeWorktreeId)
        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 2,
                rootPathsByWorktreeId: [
                    contendedWorktreeId: contendedRootPath,
                    activeWorktreeId: activeRootPath,
                ]
            )
        )

        let activeStatusRootPaths = try await projectorStatusCalls.waitForFirstArrival()
        #expect(activeStatusRootPaths == [activeRootPath])
        let contendedRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[contendedWorktreeId]
        )
        let activeRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[activeWorktreeId]
        )
        try await facts.expectRefreshStarted(
            worktreeId: activeWorktreeId, requestSequence: activeRequestSequence
        )
        #expect(await actor.capacityRetryWorktreeIds == Set([contendedWorktreeId]))
        #expect(pathProbe.recordedRootPaths.filter { $0 == contendedRootPath }.count == 1)

        activeReadGate.release()
        blockingReadGate.release()
        _ = await blockingRead.value
        _ = try await facts.expectRefreshClosed(
            worktreeId: contendedWorktreeId, requestSequence: contendedRequestSequence
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: activeWorktreeId, requestSequence: activeRequestSequence
        )
        #expect(await actor.lastAcceptedStatusAtByWorktreeId.count == 2)
        #expect(await actor.worktreeTasks.isEmpty)
        let recordedStatusRootPaths = await projectorStatusCalls.rootPaths
        #expect(Set(recordedStatusRootPaths) == Set([contendedRootPath, activeRootPath]))
        #expect(pathProbe.recordedRootPaths.count == 2)
        #expect(Set(pathProbe.recordedRootPaths) == Set([contendedRootPath, activeRootPath]))

        await actor.shutdown()
    }

    @Test("removing the final capacity pause owner re-admits unrelated pending work")
    func removingFinalCapacityPauseOwnerReadmitsPendingWork() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let blockingReadStarted = AdmissionAsyncReceipt()
        let blockingReadGate = HeldStep<Void>("blockingReadGate", cancellation: .holdThroughCancellation)
        let statusSnapshot = admissionCompleteStatusSnapshot()
        let capacityWorktreeId = UUIDv7.generate()
        let pendingWorktreeId = UUIDv7.generate()
        let blockerRootPath = URL(fileURLWithPath: "/tmp/admission-capacity-owner-blocker-\(UUIDv7.generate())")
        let capacityRootPath = URL(fileURLWithPath: "/tmp/admission-capacity-owner-\(capacityWorktreeId)")
        let pendingRootPath = URL(fileURLWithPath: "/tmp/admission-capacity-pending-\(pendingWorktreeId)")
        let blockingProvider = admissionBlockingProvider(
            physicalGate: physicalGate,
            started: blockingReadStarted,
            heldRead: blockingReadGate,
            statusSnapshot: statusSnapshot
        )
        let projectorStatusCalls = StatusCallRecorder()
        let projectorProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveAdmissionGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { rootPath, _ in
            await projectorStatusCalls.record(rootPath)
            return statusSnapshot
        }
        let pathProbe = RootPathProbeRecorder()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: projectorProvider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                maxConcurrentStatusComputes: 1,
                activePaneMaxConcurrent: 1,
                openPaneMaxConcurrent: 1
            ),
            factSink: source.sink,
            pathExistenceProbe: { rootPath in
                pathProbe.recordExistence(rootPath)
            }
        )

        let blockingRead = Task {
            await blockingProvider.statusResult(for: blockerRootPath)
        }
        await blockingReadStarted.wait()

        await actor.setActivity(worktreeId: capacityWorktreeId, isActiveInApp: true)
        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 1,
                rootPathsByWorktreeId: [capacityWorktreeId: capacityRootPath]
            )
        )
        try await expectCapacityRetryScheduled(facts: facts, actor: actor, worktreeId: capacityWorktreeId)
        let capacityRetryReason = await actor.capacityRetryReasonByWorktreeId[capacityWorktreeId]
        #expect(capacityRetryReason == .readCapacityExceeded)

        await actor.setActivePaneWorktree(worktreeId: pendingWorktreeId)
        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 2,
                rootPathsByWorktreeId: [
                    capacityWorktreeId: capacityRootPath,
                    pendingWorktreeId: pendingRootPath,
                ]
            )
        )
        await actor.enqueueImmediateRefreshIfRegistered(
            worktreeId: pendingWorktreeId,
            isExplicit: true
        )
        #expect(await actor.pendingByWorktreeId[pendingWorktreeId] != nil)

        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 3,
                rootPathsByWorktreeId: [pendingWorktreeId: pendingRootPath]
            )
        )

        try await expectCapacityRetryScheduled(facts: facts, actor: actor, worktreeId: pendingWorktreeId)
        let pendingRetryReason = await actor.capacityRetryReasonByWorktreeId[pendingWorktreeId]
        #expect(pendingRetryReason == .readCapacityExceeded)
        #expect(await projectorStatusCalls.rootPaths.isEmpty)
        #expect(pathProbe.recordedRootPaths.count == 2)
        #expect(Set(pathProbe.recordedRootPaths) == Set([capacityRootPath, pendingRootPath]))

        blockingReadGate.release()
        _ = await blockingRead.value
        let pendingStatusRootPaths = try await projectorStatusCalls.waitForFirstArrival()
        #expect(pendingStatusRootPaths == [pendingRootPath])
        let pendingRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[pendingWorktreeId]
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: pendingWorktreeId, requestSequence: pendingRequestSequence
        )
        #expect(await actor.worktreeTasks.isEmpty)
        #expect(await actor.capacityRetryWorktreeIds.isEmpty)
        #expect(await actor.capacityRetryReasonByWorktreeId.isEmpty)
        #expect(pathProbe.recordedRootPaths.filter { $0 == pendingRootPath }.count == 1)

        await actor.shutdown()
    }

    @Test("shared physical capacity rejection retains validation and pauses later admission")
    func sharedPhysicalCapacityRejectionRetainsValidationAndPausesLaterAdmission() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let noDropsFrom = await facts.mark(.lifetime(1))
        let clock = TestPushClock()
        let physicalGate = AgentStudioGitStatusPhysicalGate(maxActiveReadCount: 1)
        let blockingReadStarted = AdmissionAsyncReceipt()
        let blockingReadGate = HeldStep<Void>("blockingReadGate", cancellation: .holdThroughCancellation)
        let statusSnapshot = admissionCompleteStatusSnapshot()
        let blockingProvider = admissionBlockingProvider(
            physicalGate: physicalGate,
            started: blockingReadStarted,
            heldRead: blockingReadGate,
            statusSnapshot: statusSnapshot
        )
        let projectorProvider = AgentStudioGitWorkingTreeStatusProvider(
            slowObservationScheduler: PassiveAdmissionGitStatusSlowObservationScheduler(),
            physicalGate: physicalGate
        ) { _, _ in
            statusSnapshot
        }
        let pathProbe = RootPathProbeRecorder()
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: projectorProvider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                maxConcurrentStatusComputes: 1,
                openPaneMaxConcurrent: 1
            ),
            factSink: source.sink,
            pathExistenceProbe: { rootPath in
                pathProbe.recordExistence(rootPath)
            }
        )
        await actor.start()

        let blockingRead = Task {
            await blockingProvider.statusResult(
                for: URL(fileURLWithPath: "/tmp/admission-capacity-blocker-\(UUIDv7.generate())")
            )
        }
        await blockingReadStarted.wait()

        let worktreeIds = [UUIDv7.generate(), UUIDv7.generate()]
        let rootPaths = worktreeIds.map { worktreeId in
            URL(fileURLWithPath: "/tmp/admission-capacity-pending-\(worktreeId)")
        }
        for worktreeId in worktreeIds {
            await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        }
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: Dictionary(
                    uniqueKeysWithValues: zip(worktreeIds, rootPaths).map { worktreeId, rootPath in
                        (
                            worktreeId,
                            WorktreeFilesystemContext(repoId: worktreeId, rootPath: rootPath)
                        )
                    }
                )
            )
        )

        _ = try await source.expectDeadlineRegistered(facts: facts, kind: .capacityFallback)
        await clock.waitForPendingSleepCount(exactly: 1)
        let firstProbedRootPath = pathProbe.recordedRootPaths.first
        #expect(pathProbe.recordedRootPaths == firstProbedRootPath.map { [$0] } ?? [])
        #expect(await actor.capacityRetryWorktreeIds.count == 1)
        #expect(await actor.validatedRootPathByWorktreeId.count == 1)

        blockingReadGate.release()
        _ = await blockingRead.value
        for worktreeId in worktreeIds {
            _ = try await source.expectNextRefreshClosed(facts: facts, worktreeId: worktreeId)
        }
        #expect(await actor.lastAcceptedStatusAtByWorktreeId.count == worktreeIds.count)
        #expect(await actor.worktreeTasks.isEmpty)
        #expect(pathProbe.recordedRootPaths.count == rootPaths.count)
        #expect(Set(pathProbe.recordedRootPaths) == Set(rootPaths))
        #expect(
            await actor.validatedRootPathByWorktreeId
                == Dictionary(uniqueKeysWithValues: zip(worktreeIds, rootPaths))
        )
        if let firstProbedRootPath {
            #expect(pathProbe.recordedRootPaths.filter { $0 == firstProbedRootPath }.count == 1)
        }

        await actor.shutdown()
        try await facts.expectNoDroppedEnvelopes(from: noDropsFrom)
    }

    @Test("root existence is probed only when pending work can consume an admission slot")
    func rootExistenceIsProbedOnlyForAdmissiblePendingWork() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let statusGate = FirstStatusCallGate()
        let pathProbe = RootPathProbeRecorder()
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            await statusGate.recordAndWaitIfFirst(rootPath)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                maxConcurrentStatusComputes: 1,
                openPaneMaxConcurrent: 1
            ),
            factSink: source.sink,
            pathExistenceProbe: { rootPath in
                pathProbe.recordExistence(rootPath)
            }
        )

        let worktreeIds = [UUIDv7.generate(), UUIDv7.generate()]
        let rootPaths = worktreeIds.map { worktreeId in
            URL(fileURLWithPath: "/tmp/admission-path-probe-\(worktreeId)")
        }
        for worktreeId in worktreeIds {
            await actor.setActivity(worktreeId: worktreeId, isActiveInApp: true)
        }
        await actor.assertTopology(
            FilesystemTopologyAssertion(
                generation: 1,
                contextsByWorktreeId: Dictionary(
                    uniqueKeysWithValues: zip(worktreeIds, rootPaths).map { worktreeId, rootPath in
                        (
                            worktreeId,
                            WorktreeFilesystemContext(repoId: worktreeId, rootPath: rootPath)
                        )
                    }
                )
            )
        )

        #expect(try await statusGate.waitForFirstArrival() == 1)
        let firstAdmittedRootPath = try #require(await statusGate.firstRootPath)
        let firstWorktreeIndex = try #require(rootPaths.firstIndex(of: firstAdmittedRootPath))
        let firstRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeIds[firstWorktreeIndex]]
        )
        try await facts.expectRefreshStarted(
            worktreeId: worktreeIds[firstWorktreeIndex], requestSequence: firstRequestSequence
        )
        #expect(pathProbe.recordedRootPaths == [firstAdmittedRootPath])

        await statusGate.releaseFirst()
        let secondWorktreeIndex = 1 - firstWorktreeIndex
        let secondRequestSequence = try await facts.expectNextRefreshStarted(
            worktreeId: worktreeIds[secondWorktreeIndex]
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: worktreeIds[firstWorktreeIndex], requestSequence: firstRequestSequence
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: worktreeIds[secondWorktreeIndex], requestSequence: secondRequestSequence
        )
        #expect(await statusGate.recordedRootPaths == [firstAdmittedRootPath, rootPaths[secondWorktreeIndex]])
        #expect(await actor.worktreeTasks.isEmpty)
        #expect(pathProbe.recordedRootPaths.count == 2)
        #expect(Set(pathProbe.recordedRootPaths) == Set(rootPaths))

        await actor.shutdown()
    }

    @Test("inactive contraction preserves required full refresh after visibility attribution")
    func inactiveContractionPreservesFilesystemScopeAfterVisibilityAttribution() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let statusGate = FirstStatusCallGate()
        let blockingWorktreeId = UUIDv7.generate()
        let targetWorktreeId = UUIDv7.generate()
        let blockingRootPath = URL(fileURLWithPath: "/tmp/admission-required-blocker-\(blockingWorktreeId)")
        let targetRootPath = URL(fileURLWithPath: "/tmp/admission-required-intent-\(targetWorktreeId)")
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { rootPath in
                await statusGate.recordAndWaitIfFirst(rootPath)
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            },
            coalescingWindow: .zero,
            refreshPolicy: AppPolicies.GitRefresh.Policy(
                maxConcurrentStatusComputes: 1,
                backgroundMaxConcurrent: 1,
                minimumAutomaticStartInterval: .zero
            ),
            factSink: source.sink,
            pathExistenceProbe: { _ in true }
        )

        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 1,
                rootPathsByWorktreeId: [
                    blockingWorktreeId: blockingRootPath,
                    targetWorktreeId: targetRootPath,
                ]
            )
        )
        await setAdmissionAutomaticAttention(
            actor: actor,
            warmWorktreeIds: [blockingWorktreeId, targetWorktreeId],
            backgroundOnlyWorktreeIds: [targetWorktreeId]
        )
        #expect(await actor.logicalDebtSnapshot().backgroundOnlyAutomaticCount == 1)
        await actor.enqueueImmediateRefresh(
            admissionFilesystemChangeset(
                worktreeId: blockingWorktreeId,
                rootPath: blockingRootPath,
                batchSeq: 1
            ),
            triggerSource: .filesystemChange
        )
        #expect(try await statusGate.waitForFirstArrival() == 1)
        let blockingRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[blockingWorktreeId]
        )
        try await facts.expectRefreshStarted(
            worktreeId: blockingWorktreeId, requestSequence: blockingRequestSequence
        )

        await actor.enqueueImmediateRefresh(
            admissionFilesystemChangeset(
                worktreeId: targetWorktreeId,
                rootPath: targetRootPath,
                batchSeq: 41
            ),
            triggerSource: .filesystemChange
        )
        await actor.enqueueImmediateRefreshIfRegistered(
            worktreeId: targetWorktreeId,
            triggerSource: .visibilityChange
        )

        await expectRetainedRequiredFullRefresh(actor: actor, worktreeId: targetWorktreeId)
        #expect(
            await actor.refreshAttribution.triggerSourceByWorktreeId[targetWorktreeId]
                == .visibilityChange
        )

        await setAdmissionAutomaticAttention(
            actor: actor,
            warmWorktreeIds: [blockingWorktreeId],
            backgroundOnlyWorktreeIds: []
        )

        await expectRetainedRequiredFullRefresh(actor: actor, worktreeId: targetWorktreeId)
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[targetWorktreeId] == nil)

        await statusGate.releaseFirst()
        let targetRequestSequence = try await facts.expectNextRefreshStarted(worktreeId: targetWorktreeId)
        _ = try await facts.expectRefreshClosed(
            worktreeId: blockingWorktreeId, requestSequence: blockingRequestSequence
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: targetWorktreeId, requestSequence: targetRequestSequence
        )
        #expect(await statusGate.callCount == 2)
        #expect(await actor.worktreeTasks.isEmpty)
        #expect(await actor.pendingByWorktreeId[targetWorktreeId] == nil)
        #expect(await !actor.hasRequiredIntent(worktreeId: targetWorktreeId))
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[targetWorktreeId] == nil)

        await actor.shutdown()
    }

    @Test("inactive contraction drops an automatic follower after required work settles")
    func inactiveContractionDropsAutomaticFollowerAfterRequiredWorkSettles() async throws {
        let source = LocalFactSource(vocabulary: FactVocabulary<GitProjectorScope, GitProjectorFact>.gitProjector)
        let facts = try source.attach()
        let statusGate = FirstStatusCallGate()
        let worktreeId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/admission-required-active-\(worktreeId)")
        let actor = GitWorkingDirectoryProjector(
            bus: EventBus<RuntimeEnvelope>(),
            gitWorkingTreeProvider: StubGitWorkingTreeStatusProvider { rootPath in
                await statusGate.recordAndWaitIfFirst(rootPath)
                return GitWorkingTreeStatus(
                    summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                    branch: "main",
                    origin: nil
                )
            },
            coalescingWindow: .zero,
            factSink: source.sink,
            pathExistenceProbe: { _ in true }
        )

        await actor.assertTopology(
            admissionTopologyAssertion(
                generation: 1,
                rootPathsByWorktreeId: [worktreeId: rootPath]
            )
        )
        await actor.setAutomaticEligibleWorktrees([worktreeId])
        await actor.enqueueImmediateRefresh(
            admissionFilesystemChangeset(
                worktreeId: worktreeId,
                rootPath: rootPath,
                batchSeq: 99
            ),
            triggerSource: .filesystemChange
        )
        #expect(try await statusGate.waitForFirstArrival() == 1)
        let requiredRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[worktreeId]
        )
        try await facts.expectRefreshStarted(
            worktreeId: worktreeId, requestSequence: requiredRequestSequence
        )
        #expect(
            await actor.refreshAttribution.admittedRequiredIntentGenerationByWorktreeId[worktreeId]
                != nil
        )

        await actor.enqueueImmediateRefreshIfRegistered(
            worktreeId: worktreeId,
            triggerSource: .visibilityChange
        )
        #expect(await actor.pendingByWorktreeId[worktreeId] != nil)
        #expect(
            await actor.refreshAttribution.pendingRequiredIntentGenerationByWorktreeId[worktreeId]
                == nil
        )

        await actor.setAutomaticEligibleWorktrees([])
        #expect(await actor.pendingByWorktreeId[worktreeId] != nil)

        await statusGate.releaseFirst()
        _ = try await facts.expectRefreshClosed(
            worktreeId: worktreeId, requestSequence: requiredRequestSequence
        )
        #expect(await actor.worktreeTasks.isEmpty)
        let debt = await actor.logicalDebtSnapshot()
        #expect(await statusGate.callCount == 1)
        #expect(await actor.pendingByWorktreeId[worktreeId] == nil)
        #expect(await !actor.hasRequiredIntent(worktreeId: worktreeId))
        #expect(await actor.automaticRefreshDeadlineByWorktreeId[worktreeId] == nil)
        #expect(await actor.statusFailureDeadlineByWorktreeId[worktreeId] == nil)
        #expect(await actor.capacityFallbackDeadlineByWorktreeId[worktreeId] == nil)
        #expect(debt.logicalDebtCount == 0)
        #expect(debt.unclassifiedPendingCount == 0)

        await actor.shutdown()
    }

    @Test("missing selected root is quarantined without consuming the admission slot")
    func missingSelectedRootDoesNotConsumeAdmissionSlot() async throws {
        let source = GitProjectorFactSource()
        let facts = try source.attach()
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let missingWorktreeId = UUIDv7.generate()
        let healthyWorktreeId = UUIDv7.generate()
        let missingRootPath = URL(fileURLWithPath: "/tmp/admission-missing-\(missingWorktreeId)")
        let healthyRootPath = URL(fileURLWithPath: "/tmp/admission-healthy-\(healthyWorktreeId)")
        let pathProbe = RootPathProbeRecorder(missingRootPaths: [missingRootPath])
        let statusCalls = StatusCallRecorder()
        let provider = StubGitWorkingTreeStatusProvider { rootPath in
            await statusCalls.record(rootPath)
            return GitWorkingTreeStatus(
                summary: GitWorkingTreeSummary(changed: 0, staged: 0, untracked: 0),
                branch: "main",
                origin: nil
            )
        }
        let policy = AppPolicies.GitRefresh.Policy(
            activePaneCadence: .milliseconds(25),
            visibleSidebarCadence: .milliseconds(50),
            openPaneCadence: .milliseconds(75),
            backgroundCadence: .milliseconds(100),
            backgroundStripeCount: 1,
            maxConcurrentStatusComputes: 1,
            backgroundMaxConcurrent: 1
        )
        let actor = GitWorkingDirectoryProjector(
            bus: bus,
            gitWorkingTreeProvider: provider,
            coalescingWindow: .zero,
            sleepClock: clock,
            refreshPolicy: policy,
            factSink: source.sink,
            pathExistenceProbe: { rootPath in
                pathProbe.recordExistence(rootPath)
            }
        )
        await actor.start()

        let registrationTimestamp = ContinuousClock().now
        await bus.post(
            admissionRegistrationEnvelope(
                seq: 1,
                timestamp: registrationTimestamp,
                worktreeId: missingWorktreeId,
                rootPath: missingRootPath
            )
        )
        await bus.post(
            admissionRegistrationEnvelope(
                seq: 2,
                timestamp: registrationTimestamp.advanced(by: .milliseconds(1)),
                worktreeId: healthyWorktreeId,
                rootPath: healthyRootPath
            )
        )

        #expect(try await facts.expectHandledEnvelope(seq: 2) == .routed)
        #expect(await actor.pendingByWorktreeId.count == 2)
        _ = try await source.expectDeadlineRegistered(facts: facts, kind: .automatic)
        await clock.waitForPendingSleepCount(exactly: 1)
        clock.advance(by: policy.backgroundCadence)

        try await facts.expectNext(
            in: .quarantine(worktreeId: missingWorktreeId, episode: 1), .quarantineOpened
        )
        #expect(try await statusCalls.waitForFirstArrival() == [healthyRootPath])
        let healthyRequestSequence = try #require(
            await actor.refreshAttribution.requestSequenceByWorktreeId[healthyWorktreeId]
        )
        _ = try await facts.expectRefreshClosed(
            worktreeId: healthyWorktreeId, requestSequence: healthyRequestSequence
        )
        #expect(await actor.quarantinedWorktreeIds == Set([missingWorktreeId]))
        #expect(
            await actor.automaticRefreshDeadlineByWorktreeId[missingWorktreeId]
                == policy.backgroundCadence + policy.backgroundCadence
        )
        #expect(pathProbe.recordedRootPaths == [missingRootPath, healthyRootPath])

        await actor.shutdown()
    }
}

private func admissionBlockingProvider(
    physicalGate: AgentStudioGitStatusPhysicalGate,
    started: AdmissionAsyncReceipt,
    heldRead: HeldStep<Void>,
    statusSnapshot: AgentStudioGit.GitCompleteStatusSnapshot
) -> AgentStudioGitWorkingTreeStatusProvider {
    AgentStudioGitWorkingTreeStatusProvider(
        slowObservationScheduler: PassiveAdmissionGitStatusSlowObservationScheduler(),
        physicalGate: physicalGate
    ) { _, _ in
        await started.signal()
        try? await heldRead.arrive(())
        return statusSnapshot
    }
}

private actor FirstStatusCallGate {
    private var rootPaths: [URL] = []
    private let firstCallArrival = HeldStep<Int>("admission first status provider call")

    var callCount: Int { rootPaths.count }
    var firstRootPath: URL? { rootPaths.first }
    var recordedRootPaths: [URL] { rootPaths }

    func recordAndWaitIfFirst(_ rootPath: URL) async {
        rootPaths.append(rootPath)
        let callNumber = rootPaths.count
        if callNumber == 1 {
            try? await firstCallArrival.arrive(callNumber)
        }
    }

    func waitForFirstArrival() async throws -> Int {
        try await firstCallArrival.firstArrival()
    }

    func releaseFirst() {
        firstCallArrival.release()
    }
}

private actor AdmissionAsyncReceipt {
    private var isSignalled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        isSignalled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private struct PassiveAdmissionGitStatusSlowObservationScheduler: AgentStudioGitStatusSlowObservationScheduler {
    func scheduleObservation(
        after _: Duration,
        _: @escaping @Sendable () -> Void
    ) -> AgentStudioGitScheduledSlowObservation {
        AgentStudioGitScheduledSlowObservation {}
    }
}
