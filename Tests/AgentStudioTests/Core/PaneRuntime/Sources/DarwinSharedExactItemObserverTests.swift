import AgentStudioGit
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("DarwinSharedExactItemObserver", .serialized)
struct DarwinSharedExactItemObserverTests {
    @Test("shared activity settlement waits for every reentrant delivery")
    func sharedActivitySettlementWaitsForReentrantDelivery() throws {
        let parentKey = makeSharedParentKey("activity-delivery-order")
        let worktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()
        #expect(
            bind(
                fixture.registry,
                worktreeId: worktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        let generation = try #require(fixture.registry.snapshot().generationByParent[parentKey])
        let barrierCapture = SharedActivityBarrierCapture()
        fixture.effectRecorder.setNextActivityObservationHook { _ in
            fixture.registry.receive(
                parentKey: parentKey,
                streamGeneration: generation,
                rawEvents: [
                    DarwinSharedExactItemRawEvent(
                        path: "\(parentKey.parentPath)/configuration",
                        eventId: 402,
                        flags: 0
                    )
                ]
            )
            barrierCapture.store(fixture.registry.captureActivityBarrier())
        }

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: "\(parentKey.parentPath)/configuration",
            eventId: 401
        )

        let participant = try #require(
            fixture.effectRecorder.activityObservationBatches.first?.participant
        )
        #expect(barrierCapture.barrier?.deliveredEventIDByParticipant[participant] == 0)
        let settledBarrier = try #require(fixture.registry.captureActivityBarrier())
        #expect(settledBarrier.deliveredEventIDByParticipant[participant] == 402)
        fixture.registry.shutdown()
    }

    @Test("activity barrier rejects shared binding topology changes")
    func activityBarrierRejectsSharedBindingTopologyChanges() throws {
        let parentKey = makeSharedParentKey("activity-barrier-topology")
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()
        #expect(
            bind(
                fixture.registry,
                worktreeId: firstWorktreeId,
                parentKey: parentKey,
                itemName: "config"
            )
        )
        let snapshot = try #require(fixture.registry.captureActivityBarrierSnapshot())

        #expect(
            bind(
                fixture.registry,
                worktreeId: secondWorktreeId,
                parentKey: parentKey,
                itemName: "ignore"
            )
        )

        #expect(!fixture.registry.activityBarrierIsCurrent(snapshot))
        fixture.registry.shutdown()
    }

    @Test("shared exact observer routes hits selectively after unrelated misses")
    func sharedExactObserverRoutesOnlyExactSubscribers() throws {
        let parentKey = makeSharedParentKey()
        let configurationPath = "\(parentKey.parentPath)/configuration"
        let configurationWorktreeId = UUIDv7.generate()
        let ignoreWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()

        #expect(
            bind(
                fixture.registry,
                worktreeId: configurationWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: ignoreWorktreeId,
                parentKey: parentKey,
                itemName: "ignore"
            )
        )
        let generation = try #require(fixture.registry.snapshot().generationByParent[parentKey])

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: "\(parentKey.parentPath)/unrelated",
            eventId: 40
        )

        #expect(fixture.effectRecorder.actions.isEmpty)

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: configurationPath,
            eventId: 41,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        )

        #expect(
            fixture.effectRecorder.actions == [
                .mutation(worktreeId: configurationWorktreeId, eventIds: [41]),
                .fullGitRefresh(worktreeId: configurationWorktreeId),
            ]
        )
        fixture.registry.shutdown()
    }

    @Test("shared exact observer uncertainty reaches only the affected parent's dependents")
    func sharedExactObserverUncertaintyIsParentScoped() throws {
        let affectedParentKey = makeSharedParentKey("affected-parent")
        let isolatedParentKey = makeSharedParentKey("isolated-parent")
        let firstAffectedWorktreeId = UUIDv7.generate()
        let secondAffectedWorktreeId = UUIDv7.generate()
        let isolatedWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()

        #expect(
            bind(
                fixture.registry,
                worktreeId: firstAffectedWorktreeId,
                parentKey: affectedParentKey,
                itemName: "configuration"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: secondAffectedWorktreeId,
                parentKey: affectedParentKey,
                itemName: "ignore"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: isolatedWorktreeId,
                parentKey: isolatedParentKey,
                itemName: "configuration"
            )
        )
        let generation = try #require(
            fixture.registry.snapshot().generationByParent[affectedParentKey]
        )

        receive(
            fixture.registry,
            parentKey: affectedParentKey,
            streamGeneration: generation,
            path: "\(affectedParentKey.parentPath)/unrelated",
            eventId: 42,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        )

        let affectedWorktreeIds = Set([firstAffectedWorktreeId, secondAffectedWorktreeId])
        #expect(Set(fixture.effectRecorder.uncertainWorktreeIds) == affectedWorktreeIds)
        #expect(Set(fixture.effectRecorder.fullGitRefreshWorktreeIds) == affectedWorktreeIds)
        #expect(!fixture.effectRecorder.uncertainWorktreeIds.contains(isolatedWorktreeId))
        #expect(!fixture.effectRecorder.fullGitRefreshWorktreeIds.contains(isolatedWorktreeId))
        #expect(fixture.registry.hasBinding(worktreeId: firstAffectedWorktreeId))
        #expect(fixture.registry.hasBinding(worktreeId: secondAffectedWorktreeId))
        #expect(fixture.registry.hasBinding(worktreeId: isolatedWorktreeId))
        #expect(fixture.registry.snapshot().generationByParent[affectedParentKey] == nil)
        #expect(fixture.registry.snapshot().generationByParent[isolatedParentKey] != nil)
        #expect(fixture.streamFactory.retirementCount == 1)
        let firstIngressIndex = try #require(
            fixture.effectRecorder.actions.firstIndex {
                if case .fullGitRefresh = $0 { return true }
                return false
            }
        )
        #expect(
            fixture.effectRecorder.actions[..<firstIngressIndex].allSatisfy {
                if case .uncertain = $0 { return true }
                return false
            }
        )
        fixture.registry.shutdown()
    }

    @Test("shared callbacks attribute bounded exact and uncertainty fanout")
    func sharedCallbacksAttributeExactAndUncertaintyFanout() throws {
        let parentKey = makeSharedParentKey("attribution-parent")
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()

        #expect(
            bind(
                fixture.registry,
                worktreeId: firstWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: secondWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        let generation = try #require(fixture.registry.snapshot().generationByParent[parentKey])

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: "\(parentKey.parentPath)/configuration",
            eventId: 91
        )
        let exactSnapshot = fixture.performanceAccumulator.snapshotAndReset()
        #expect(exactSnapshot.sharedRawCallbackBatchCount == 1)
        #expect(exactSnapshot.sharedRawCallbackEventCount == 1)
        #expect(exactSnapshot.sharedExactSubscriberCount == 2)
        #expect(exactSnapshot.sharedUncertaintySubscriberCount == 0)
        #expect(exactSnapshot.sharedFullRefreshEmissionCount == 2)
        #expect(fixture.effectRecorder.fullGitRefreshSources == [.sharedExact, .sharedExact])

        fixture.effectRecorder.reset()
        #expect(
            bind(
                fixture.registry,
                worktreeId: firstWorktreeId,
                bindingGeneration: 2,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: secondWorktreeId,
                bindingGeneration: 2,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: "\(parentKey.parentPath)/unrelated",
            eventId: 92,
            flags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
            )
        )
        let uncertaintySnapshot = fixture.performanceAccumulator.snapshotAndReset()
        #expect(uncertaintySnapshot.sharedRawCallbackBatchCount == 1)
        #expect(uncertaintySnapshot.sharedRawCallbackEventCount == 1)
        #expect(uncertaintySnapshot.sharedExactSubscriberCount == 0)
        #expect(uncertaintySnapshot.sharedUncertaintySubscriberCount == 2)
        #expect(uncertaintySnapshot.sharedFullRefreshEmissionCount == 2)
        #expect(fixture.effectRecorder.fullGitRefreshSources == [.sharedUncertainty, .sharedUncertainty])
        fixture.registry.shutdown()
    }

    @Test("shared uncertainty coalesces delivery until the dependent rebinds")
    func sharedUncertaintyCoalescesDeliveryUntilDependentRebinds() throws {
        let parentKey = makeSharedParentKey("coalesced-delivery-parent")
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()

        #expect(
            bind(
                fixture.registry,
                worktreeId: firstWorktreeId,
                bindingGeneration: 1,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: secondWorktreeId,
                bindingGeneration: 1,
                parentKey: parentKey,
                itemName: "ignore"
            )
        )
        let generation = try #require(fixture.registry.snapshot().generationByParent[parentKey])
        let uncertaintyFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagKernelDropped
        )

        for eventId in FSEventStreamEventId(100)...FSEventStreamEventId(101) {
            receive(
                fixture.registry,
                parentKey: parentKey,
                streamGeneration: generation,
                path: "\(parentKey.parentPath)/unrelated",
                eventId: eventId,
                flags: uncertaintyFlags
            )
        }

        #expect(fixture.effectRecorder.uncertainWorktreeIds.count == 4)
        #expect(
            fixture.effectRecorder.fullGitRefreshWorktreeIds.sorted(by: sortWorktreeIds)
                == [firstWorktreeId, secondWorktreeId].sorted(by: sortWorktreeIds)
        )

        fixture.effectRecorder.reset()
        #expect(
            bind(
                fixture.registry,
                worktreeId: firstWorktreeId,
                bindingGeneration: 2,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: "\(parentKey.parentPath)/unrelated",
            eventId: 102,
            flags: uncertaintyFlags
        )

        #expect(fixture.effectRecorder.uncertainWorktreeIds.count == 2)
        #expect(fixture.effectRecorder.fullGitRefreshWorktreeIds == [firstWorktreeId])
        fixture.registry.shutdown()
    }

    @Test("shared exact observer uses one parent stream for 148 dependent plans")
    func sharedExactObserverContractsSharedParentTopology() throws {
        let parentKey = makeSharedParentKey()
        let fixture = makeSharedExactItemFixture()
        var worktreeIds: Set<UUID> = []

        for _ in 0..<148 {
            let worktreeId = UUIDv7.generate()
            worktreeIds.insert(worktreeId)
            #expect(
                bind(
                    fixture.registry,
                    worktreeId: worktreeId,
                    parentKey: parentKey,
                    itemName: "configuration"
                )
            )
        }

        let snapshot = fixture.registry.snapshot()
        #expect(snapshot.observerCount == 1)
        #expect(snapshot.bindingCount == 148)
        #expect(snapshot.referenceCountByParent[parentKey] == 148)
        #expect(fixture.streamFactory.startCount == 1)
        let generation = try #require(snapshot.generationByParent[parentKey])
        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: generation,
            path: "\(parentKey.parentPath)/unrelated",
            eventId: 41
        )
        #expect(fixture.effectRecorder.activityObservationBatches.count == 1)
        #expect(
            fixture.effectRecorder.activityObservationBatches.first?.participantWorktreeIds
                == worktreeIds
        )
        #expect(
            fixture.effectRecorder.activityObservationBatches.first?.qualifyingWorktreeIds.isEmpty
                == true
        )
        fixture.registry.shutdown()
        #expect(fixture.streamFactory.retirementCount == 1)
    }

    @Test("shared exact observer installs no subscriber when its parent stream cannot start")
    func sharedExactObserverFailsStreamStartClosed() {
        let parentKey = makeSharedParentKey()
        let effectRecorder = SharedExactItemEffectRecorder()
        let streamFactory = RecordingSharedExactItemStreamFactory(startsSuccessfully: false)
        let registry = makeSharedExactItemRegistry(
            effectRecorder: effectRecorder,
            streamFactory: streamFactory,
            performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator()
        )

        #expect(
            !bind(
                registry,
                worktreeId: UUIDv7.generate(),
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        #expect(registry.snapshot().observerCount == 0)
        #expect(registry.snapshot().bindingCount == 0)
        #expect(effectRecorder.actions.isEmpty)
        registry.shutdown()
    }

    @Test("shared exact observer tears down only after its final subscriber retires")
    func sharedExactObserverReferenceCountsLifecycle() {
        let parentKey = makeSharedParentKey()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()

        #expect(
            bind(
                fixture.registry,
                worktreeId: firstWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        #expect(
            bind(
                fixture.registry,
                worktreeId: secondWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )

        fixture.registry.unbind(worktreeId: firstWorktreeId)
        #expect(fixture.registry.snapshot().observerCount == 1)
        #expect(fixture.streamFactory.retirementCount == 0)

        fixture.registry.unbind(worktreeId: secondWorktreeId)
        fixture.registry.unbind(worktreeId: secondWorktreeId)
        #expect(fixture.registry.snapshot().observerCount == 0)
        #expect(fixture.streamFactory.retirementCount == 1)
        fixture.registry.shutdown()
        #expect(fixture.streamFactory.retirementCount == 1)
    }

    @Test("shared exact observer rejects callbacks from a retired stream generation")
    func sharedExactObserverRejectsLateGeneration() throws {
        let parentKey = makeSharedParentKey()
        let configurationPath = "\(parentKey.parentPath)/configuration"
        let retiredWorktreeId = UUIDv7.generate()
        let currentWorktreeId = UUIDv7.generate()
        let fixture = makeSharedExactItemFixture()

        #expect(
            bind(
                fixture.registry,
                worktreeId: retiredWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        let retiredGeneration = try #require(
            fixture.registry.snapshot().generationByParent[parentKey]
        )

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: retiredGeneration,
            path: "\(parentKey.parentPath)/unrelated",
            eventId: 50
        )
        #expect(fixture.effectRecorder.actions.isEmpty)
        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: retiredGeneration,
            path: "\(parentKey.parentPath)/unrelated",
            eventId: 49
        )
        #expect(
            fixture.effectRecorder.actions == [
                .uncertain(worktreeId: retiredWorktreeId),
                .fullGitRefresh(worktreeId: retiredWorktreeId),
            ]
        )
        fixture.effectRecorder.reset()
        fixture.registry.unbind(worktreeId: retiredWorktreeId)
        #expect(
            bind(
                fixture.registry,
                worktreeId: currentWorktreeId,
                parentKey: parentKey,
                itemName: "configuration"
            )
        )
        let currentGeneration = try #require(
            fixture.registry.snapshot().generationByParent[parentKey]
        )
        #expect(currentGeneration != retiredGeneration)
        fixture.effectRecorder.reset()

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: retiredGeneration,
            path: configurationPath,
            eventId: 43
        )
        #expect(fixture.effectRecorder.actions.isEmpty)

        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: currentGeneration,
            path: configurationPath,
            eventId: 44
        )
        #expect(
            fixture.effectRecorder.actions == [
                .mutation(worktreeId: currentWorktreeId, eventIds: [44]),
                .fullGitRefresh(worktreeId: currentWorktreeId),
            ]
        )
        fixture.registry.shutdown()
    }

    @Test("continuity hierarchy streams request watched-root replacement events")
    func continuityHierarchyStreamsUseWatchRoot() {
        #expect(
            DarwinFSEventStreamConfiguration.continuityFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot) != 0
        )
        #expect(
            DarwinFSEventStreamConfiguration.continuityFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagMarkSelf) != 0
        )
    }

    @Test("shared exact self-event metadata does not mint external activity")
    func sharedExactSelfEventMetadataDoesNotMintExternalActivity() throws {
        // Arrange
        let fixture = makeSharedExactItemFixture()
        let parentKey = makeSharedParentKey("activity-metadata")
        let worktreeId = UUIDv7.generate()
        let itemName = "refs/remotes/origin/main"
        let exactPath = "\(parentKey.parentPath)/\(itemName)"
        #expect(
            bind(
                fixture.registry,
                worktreeId: worktreeId,
                parentKey: parentKey,
                itemName: itemName
            )
        )
        let streamGeneration = try #require(
            fixture.registry.snapshot().generationByParent[parentKey]
        )
        let flags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagOwnEvent
        )

        // Act
        receive(
            fixture.registry,
            parentKey: parentKey,
            streamGeneration: streamGeneration,
            path: exactPath,
            eventId: 51,
            flags: flags
        )

        // Assert
        let activityBatch = try #require(fixture.effectRecorder.activityObservationBatches.first)
        #expect(activityBatch.processedThroughEventID == 51)
        #expect(
            activityBatch.participant
                == FSEventParticipant(
                    scopeKey: "shared:1:\(parentKey.parentPath)",
                    generation: streamGeneration,
                    volumeIdentifier: "1"
                )
        )
        #expect(activityBatch.participantWorktreeIds == [worktreeId])
        #expect(activityBatch.qualifyingWorktreeIds.isEmpty)
        #expect(activityBatch.coverageLostWorktreeIds == [worktreeId])
        let barrier = try #require(fixture.registry.captureActivityBarrier())
        let participant = activityBatch.participant
        #expect(barrier.deliveredEventIDByParticipant[participant] == 51)
        #expect(
            barrier.bindings
                == [FSEventParticipantBinding(worktreeId: worktreeId, participant: participant)]
        )
        fixture.registry.shutdown()
    }

    @Test("stable shared-dependent preparation mints and renews composite authority")
    func stableSharedDependentPreparationMintsAndRenewsAuthority() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-shared-authority-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let worktreeRoot = fixtureRoot.appending(path: "worktree", directoryHint: .isDirectory)
        let externalParent = fixtureRoot.appending(path: "external", directoryHint: .isDirectory)
        let configurationPath = externalParent.appending(path: "configuration")
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: true)
        try Data().write(to: configurationPath)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = RecordingSharedExactItemStreamFactory()
        let client = DarwinFSEventStreamClient(
            localStreamFactory: { _ in NoopLocalFSEventStreamLifetime() },
            sharedExactItemStreamFactory: streamFactory.makeStream
        )
        defer { client.shutdown() }
        let worktreeId = UUIDv7.generate()
        _ = client.register(worktreeId: worktreeId, repoId: UUIDv7.generate(), rootPath: worktreeRoot)
        let observationPlan = AgentStudioGit.GitStatusObservationPlan(
            identity: AgentStudioGit.GitStatusObservationIdentity(rawValue: "shared-dependent"),
            scopes: [
                AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: worktreeRoot),
                AgentStudioGit.GitStatusObservationScope(kind: .item, path: configurationPath),
            ],
            support: .supported
        )

        let prepareOutcome = await client.prepare(
            worktreeId: worktreeId,
            rootPath: worktreeRoot,
            observationPlan: observationPlan
        )
        let barrier = try #require(
            prepareOutcome.barrier,
            Comment(rawValue: "preparation: \(prepareOutcome)")
        )
        let commitValidation = await client.commit(barrier)
        let authority = try #require(
            commitValidation.authority,
            "commit rejected: \(commitValidation)"
        )
        let renewal = await client.renew(authority)

        #expect(renewal == .authoritative(authority))
        #expect(streamFactory.startCount == 1)
        // Prepare, pre-fingerprint commit, post-fingerprint commit, and renewal.
        #expect(streamFactory.flushCount == 4)
        client.unregister(worktreeId: worktreeId)
        #expect(streamFactory.retirementCount == 1)
    }

    @Test("unregister during shared stream start cannot publish a stale binding")
    func unregisterDuringSharedStreamStartRejectsStaleBinding() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-shared-unregister-race-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let worktreeRoot = fixtureRoot.appending(path: "worktree", directoryHint: .isDirectory)
        let externalParent = fixtureRoot.appending(path: "external", directoryHint: .isDirectory)
        let configurationPath = externalParent.appending(path: "configuration")
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: true)
        try Data().write(to: configurationPath)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = ControllableSharedExactItemStreamFactory()
        let client = DarwinFSEventStreamClient(
            sharedExactItemStreamFactory: streamFactory.makeStream
        )
        defer {
            streamFactory.allowStreamStartToComplete()
            client.shutdown()
        }
        let worktreeId = UUIDv7.generate()
        _ = client.register(worktreeId: worktreeId, repoId: UUIDv7.generate(), rootPath: worktreeRoot)
        let observationPlan = AgentStudioGit.GitStatusObservationPlan(
            identity: AgentStudioGit.GitStatusObservationIdentity(rawValue: "shared-unregister-race"),
            scopes: [
                AgentStudioGit.GitStatusObservationScope(kind: .subtree, path: worktreeRoot),
                AgentStudioGit.GitStatusObservationScope(kind: .item, path: configurationPath),
            ],
            support: .supported
        )
        let prepareTask = Task {
            await client.prepare(
                worktreeId: worktreeId,
                rootPath: worktreeRoot,
                observationPlan: observationPlan
            )
        }

        await streamFactory.waitUntilStreamStartBegins()
        client.unregister(worktreeId: worktreeId)
        streamFactory.allowStreamStartToComplete()
        let prepareOutcome = await prepareTask.value

        #expect(prepareOutcome == .unavailable(.sharedBindingInstallFailed))
        #expect(streamFactory.startCount == 1)
        #expect(streamFactory.retirementCount == 1)
    }

    private func makeSharedExactItemRegistry(
        effectRecorder: SharedExactItemEffectRecorder,
        streamFactory: RecordingSharedExactItemStreamFactory,
        performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator
    ) -> DarwinSharedExactItemObserverRegistry {
        DarwinSharedExactItemObserverRegistry(
            streamFactory: streamFactory.makeStream,
            recordRawEvents: effectRecorder.recordRawEvents,
            markUncertain: effectRecorder.markUncertain,
            yieldFullGitRefresh: effectRecorder.yieldFullGitRefresh,
            yieldActivityObservations: effectRecorder.recordActivityObservations,
            performanceAccumulator: performanceAccumulator
        )
    }

    private func makeSharedExactItemFixture() -> SharedExactItemFixture {
        let effectRecorder = SharedExactItemEffectRecorder()
        let streamFactory = RecordingSharedExactItemStreamFactory()
        let performanceAccumulator = DarwinFSEventIngressPerformanceAccumulator()
        return SharedExactItemFixture(
            registry: makeSharedExactItemRegistry(
                effectRecorder: effectRecorder,
                streamFactory: streamFactory,
                performanceAccumulator: performanceAccumulator
            ),
            effectRecorder: effectRecorder,
            streamFactory: streamFactory,
            performanceAccumulator: performanceAccumulator
        )
    }

    private func makeSharedParentKey(
        _ name: String = "shared-parent"
    ) -> DarwinSharedExactItemParentKey {
        DarwinSharedExactItemParentKey(
            parentPath: "/private/tmp/\(name)",
            volumeSystemNumber: 1
        )
    }

    private func bind(
        _ registry: DarwinSharedExactItemObserverRegistry,
        worktreeId: UUID,
        bindingGeneration: UInt64 = 1,
        parentKey: DarwinSharedExactItemParentKey,
        itemName: String
    ) -> Bool {
        registry.bind(
            worktreeId: worktreeId,
            bindingGeneration: bindingGeneration,
            exactItemsByParent: [parentKey: ["\(parentKey.parentPath)/\(itemName)"]],
            bindingIsCurrent: { true }
        )
    }

    private func sortWorktreeIds(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private func receive(
        _ registry: DarwinSharedExactItemObserverRegistry,
        parentKey: DarwinSharedExactItemParentKey,
        streamGeneration: UInt64,
        path: String,
        eventId: FSEventStreamEventId,
        flags: FSEventStreamEventFlags = 0
    ) {
        registry.receive(
            parentKey: parentKey,
            streamGeneration: streamGeneration,
            rawEvents: [
                DarwinSharedExactItemRawEvent(
                    path: path,
                    eventId: eventId,
                    flags: flags
                )
            ]
        )
    }
}

private struct SharedExactItemFixture {
    let registry: DarwinSharedExactItemObserverRegistry
    let effectRecorder: SharedExactItemEffectRecorder
    let streamFactory: RecordingSharedExactItemStreamFactory
    let performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator
}

private enum SharedExactItemRecordedAction: Equatable {
    case mutation(worktreeId: UUID, eventIds: [FSEventStreamEventId])
    case uncertain(worktreeId: UUID)
    case fullGitRefresh(worktreeId: UUID)
}

private final class SharedExactItemEffectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [SharedExactItemRecordedAction] = []
    private var recordedFullGitRefreshSources: [DarwinFSEventIngressSource] = []
    private var recordedActivityObservationBatches: [FSEventActivityObservationBatch] = []
    private var nextActivityObservationHook: (@Sendable (FSEventActivityObservationBatch) -> Void)?

    var actions: [SharedExactItemRecordedAction] {
        lock.withLock { recordedActions }
    }

    var uncertainWorktreeIds: [UUID] {
        actions.compactMap { action in
            guard case .uncertain(let worktreeId) = action else { return nil }
            return worktreeId
        }
    }

    var fullGitRefreshWorktreeIds: [UUID] {
        actions.compactMap { action in
            guard case .fullGitRefresh(let worktreeId) = action else { return nil }
            return worktreeId
        }
    }

    var fullGitRefreshSources: [DarwinFSEventIngressSource] {
        lock.withLock { recordedFullGitRefreshSources }
    }

    var activityObservationBatches: [FSEventActivityObservationBatch] {
        lock.withLock { recordedActivityObservationBatches }
    }

    func recordRawEvents(
        worktreeId: UUID,
        events: [DarwinFSEventClassifiedRawEvent]
    ) {
        let mutationEventIds = events.compactMap { event in
            event.hasRelevantMutation ? event.eventId : nil
        }
        guard !mutationEventIds.isEmpty else { return }
        lock.withLock {
            recordedActions.append(
                .mutation(worktreeId: worktreeId, eventIds: mutationEventIds)
            )
        }
    }

    func markUncertain(worktreeId: UUID) {
        lock.withLock {
            recordedActions.append(.uncertain(worktreeId: worktreeId))
        }
    }

    func yieldFullGitRefresh(worktreeId: UUID, source: DarwinFSEventIngressSource) {
        lock.withLock {
            recordedActions.append(.fullGitRefresh(worktreeId: worktreeId))
            recordedFullGitRefreshSources.append(source)
        }
    }

    func recordActivityObservations(_ batch: FSEventActivityObservationBatch) {
        let hook = lock.withLock {
            recordedActivityObservationBatches.append(batch)
            defer { nextActivityObservationHook = nil }
            return nextActivityObservationHook
        }
        hook?(batch)
    }

    func setNextActivityObservationHook(
        _ hook: @escaping @Sendable (FSEventActivityObservationBatch) -> Void
    ) {
        lock.withLock {
            nextActivityObservationHook = hook
        }
    }

    func reset() {
        lock.withLock {
            recordedActions.removeAll(keepingCapacity: true)
            recordedFullGitRefreshSources.removeAll(keepingCapacity: true)
            recordedActivityObservationBatches.removeAll(keepingCapacity: true)
        }
    }
}

private final class SharedActivityBarrierCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBarrier: FSEventActivityBarrier?

    var barrier: FSEventActivityBarrier? {
        lock.withLock { storedBarrier }
    }

    func store(_ barrier: FSEventActivityBarrier?) {
        lock.withLock { storedBarrier = barrier }
    }
}

final class RecordingSharedExactItemStreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let startsSuccessfully: Bool
    private var startedStreamCount = 0
    private var flushedStreamCount = 0
    private var retiredStreamCount = 0
    private var callbackHandler: (@Sendable ([DarwinSharedExactItemRawEvent]) -> Void)?

    init(startsSuccessfully: Bool = true) {
        self.startsSuccessfully = startsSuccessfully
    }

    var startCount: Int {
        lock.withLock { startedStreamCount }
    }

    var retirementCount: Int {
        lock.withLock { retiredStreamCount }
    }

    var flushCount: Int {
        lock.withLock { flushedStreamCount }
    }

    func emit(
        path: String,
        eventId: FSEventStreamEventId,
        flags: FSEventStreamEventFlags = 0
    ) -> Bool {
        guard let callbackHandler = lock.withLock({ callbackHandler }) else { return false }
        callbackHandler([
            DarwinSharedExactItemRawEvent(path: path, eventId: eventId, flags: flags)
        ])
        return true
    }

    func makeStream(
        parentKey _: DarwinSharedExactItemParentKey,
        streamGeneration _: UInt64,
        eventHandler: @escaping @Sendable ([DarwinSharedExactItemRawEvent]) -> Void
    ) -> (any DarwinSharedExactItemStreamLifetime)? {
        lock.withLock {
            startedStreamCount += 1
            callbackHandler = eventHandler
        }
        guard startsSuccessfully else { return nil }
        return RecordingSharedExactItemStreamLifetime(
            onFlush: { [weak self] in
                self?.lock.withLock {
                    self?.flushedStreamCount += 1
                }
                return true
            },
            onRetire: { [weak self] in
                self?.lock.withLock {
                    self?.retiredStreamCount += 1
                    self?.callbackHandler = nil
                }
            }
        )
    }
}

final class NoopLocalFSEventStreamLifetime: DarwinLocalFSEventStreamLifetime, @unchecked Sendable {
    func flush() -> Bool { true }

    func retire() {}

    func scheduleRetirement() {}
}

extension GitCleanContinuityAuthorityValidation {
    fileprivate var authority: GitCleanContinuityAuthority? {
        guard case .authoritative(let authority) = self else { return nil }
        return authority
    }
}
