import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite(.serialized)
struct FilesystemActorTests {
    @Test("logical debt trace identity suppresses internal custody-only transitions")
    func logicalDebtTraceIdentitySuppressesInternalCustodyTransitions() {
        let activeQuantum = FilesystemLogicalDebtSnapshot(
            pendingWorktreeCount: 0,
            drainTaskCount: 0,
            watchedFolderReadyCount: 0,
            watchedFolderActiveQuantumCount: 1,
            watchedFolderAwaitingValidationCount: 0,
            watchedFolderPendingResultCount: 0,
            watchedFolderLeasedResultCount: 0,
            watchedFolderDirtyFollowUpCount: 0
        )
        let pendingResult = FilesystemLogicalDebtSnapshot(
            pendingWorktreeCount: 0,
            drainTaskCount: 0,
            watchedFolderReadyCount: 0,
            watchedFolderActiveQuantumCount: 0,
            watchedFolderAwaitingValidationCount: 0,
            watchedFolderPendingResultCount: 1,
            watchedFolderLeasedResultCount: 0,
            watchedFolderDirtyFollowUpCount: 0
        )

        #expect(activeQuantum != pendingResult)
        #expect(activeQuantum.traceIdentity == pendingResult.traceIdentity)
    }

    @Test("one ingress batch publishes overflow debt once after aggregate admission")
    func ingressBatchPublishesAggregateOverflowDebtOnce() async throws {
        let traceRuntime = makeFilesystemLogicalDebtTraceRuntime()
        let recorder = AgentStudioPerformanceTraceRecorder(
            traceRuntime: traceRuntime,
            processMemorySampleWait: { false }
        )
        let streamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: streamClient,
            sleepClock: TestPushClock(),
            debounceWindow: .seconds(60),
            maxFlushLatency: .seconds(120),
            performanceTraceRecorder: recorder
        )
        let worktreeIDs = (0..<3).map { _ in UUIDv7.generate() }
        for (index, worktreeID) in worktreeIDs.enumerated() {
            await actor.register(
                worktreeId: worktreeID,
                repoId: UUIDv7.generate(),
                rootPath: URL(fileURLWithPath: "/tmp/aggregate-overflow-debt-\(index)")
            )
            streamClient.sendOverflowRecovery(
                worktreeId: worktreeID,
                paths: ["Sources/Recovered\(index).swift"]
            )
        }
        let baselineRevision = await actor.logicalDebtSnapshotPublicationRevision

        streamClient.send(
            FSEventBatch(worktreeId: worktreeIDs[0], paths: ["Sources/Trigger.swift"])
        )

        let aggregateSnapshotRecorded = await waitUntil {
            await actor.lastRecordedLogicalDebtSnapshot?.pendingWorktreeCount == 3
        }
        #expect(aggregateSnapshotRecorded)
        #expect(await actor.logicalDebtSnapshotPublicationRevision == baselineRevision + 1)

        await actor.shutdown()
        try await recorder.drain()
    }

    private func waitUntil(
        maxTurns: Int = 10_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxTurns {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }

    @Test("overflow debt widens the affected worktree to a root-scoped change")
    func overflowDebtWidensAffectedWorktreeToRootScope() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let streamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: streamClient,
            sleepClock: TestPushClock(),
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        let worktreeId = UUIDv7.generate()

        await actor.register(
            worktreeId: worktreeId,
            repoId: UUIDv7.generate(),
            rootPath: URL(fileURLWithPath: "/tmp/overflow-debt-(UUIDv7.generate().uuidString)")
        )
        _ = try #require(await iterator.next())

        streamClient.sendOverflowRecovery(worktreeId: worktreeId)
        streamClient.send(FSEventBatch(worktreeId: worktreeId, paths: ["Sources/Fine.swift"]))

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == worktreeId)
        #expect(Set(changeset.paths) == [".", "Sources/Fine.swift"])

        await actor.shutdown()
    }

    @Test("older scheduler snapshot cannot overwrite a newer logical-debt publication")
    func olderSchedulerSnapshotCannotOverwriteNewerLogicalDebtPublication() async throws {
        let traceRuntime = makeFilesystemLogicalDebtTraceRuntime()
        let recorder = AgentStudioPerformanceTraceRecorder(
            traceRuntime: traceRuntime,
            processMemorySampleWait: { false }
        )
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(),
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .seconds(1),
            maxFlushLatency: .seconds(2),
            performanceTraceRecorder: recorder
        )
        let worktreeID = UUIDv7.generate()
        await actor.register(
            worktreeId: worktreeID,
            repoId: worktreeID,
            rootPath: URL(
                fileURLWithPath: "/tmp/logical-debt-ordering-\(UUIDv7.generate().uuidString)"
            )
        )
        let snapshotGate = LogicalDebtSnapshotGate()
        let olderPublication = Task {
            await actor.recordLogicalDebtSnapshotIfChanged(
                watchedFolderStateSnapshot: { await snapshotGate.waitForRelease() }
            )
        }
        await snapshotGate.waitUntilEntered()

        await actor.enqueueRawPaths(worktreeId: worktreeID, paths: ["Sources/Fresher.swift"])
        let newerSnapshot = await actor.lastRecordedLogicalDebtSnapshot
        #expect(newerSnapshot?.logicalDebtCount == 2)

        await snapshotGate.release()
        await olderPublication.value
        #expect(await actor.lastRecordedLogicalDebtSnapshot == newerSnapshot)

        await actor.shutdown()
        try await recorder.drain()
    }

    @Test("register emits worktreeRegistered fact")
    func registerEmitsWorktreeRegisteredFact() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        let worktreeId = UUID()
        let repoId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/register-\(UUID().uuidString)")
        let outcome = await actor.registerForObservation(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath
        )

        #expect(outcome == .observing)

        let envelope = try #require(await iterator.next())
        guard case .system(let systemEnvelope) = envelope else {
            Issue.record("Expected system envelope")
            return
        }
        guard
            case .topology(
                .worktreeRegistered(let registeredWorktreeId, let registeredRepoId, let registeredRootPath)) =
                systemEnvelope.event
        else {
            Issue.record("Expected worktreeRegistered topology event")
            return
        }

        #expect(registeredWorktreeId == worktreeId)
        #expect(registeredRepoId == repoId)
        #expect(registeredRootPath == rootPath)
        #expect(systemEnvelope.source == .builtin(.filesystemWatcher))

        await actor.shutdown()
    }

    @Test(
        "registration failure installs no root or topology fact",
        arguments: [
            FSEventStreamRegistrationUnavailableReason.streamCreationFailed,
            .streamStartFailed,
            .clientShutdown,
        ]
    )
    func registrationFailureRollsBackCompletely(
        reason: FSEventStreamRegistrationUnavailableReason
    ) async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let streamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: streamClient,
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        let failedWorktreeId = UUIDv7.generate()
        streamClient.setNextRegistrationOutcome(.unavailable(reason))

        let failedOutcome = await actor.registerForObservation(
            worktreeId: failedWorktreeId,
            repoId: UUIDv7.generate(),
            rootPath: URL(fileURLWithPath: "/tmp/failed-registration-\(UUIDv7.generate().uuidString)")
        )
        await actor.enqueueRawPaths(worktreeId: failedWorktreeId, paths: ["Sources/Ignored.swift"])
        await actor.unregister(worktreeId: failedWorktreeId)

        #expect(failedOutcome == .unavailable(reason))
        #expect(!streamClient.registeredWorktreeIds.contains(failedWorktreeId))

        let observingWorktreeId = UUIDv7.generate()
        let observingRepoId = UUIDv7.generate()
        let observingRootPath = URL(
            fileURLWithPath: "/tmp/observing-registration-\(UUIDv7.generate().uuidString)"
        )
        let observingOutcome = await actor.registerForObservation(
            worktreeId: observingWorktreeId,
            repoId: observingRepoId,
            rootPath: observingRootPath
        )

        #expect(observingOutcome == .observing)
        let firstEnvelope = try #require(await iterator.next())
        guard case .system(let systemEnvelope) = firstEnvelope,
            case .topology(.worktreeRegistered(let worktreeId, let repoId, let rootPath)) =
                systemEnvelope.event
        else {
            Issue.record("Expected the first topology fact to belong to the observing registration")
            await actor.shutdown()
            return
        }
        #expect(worktreeId == observingWorktreeId)
        #expect(repoId == observingRepoId)
        #expect(rootPath == observingRootPath)

        await actor.shutdown()
    }

    @Test("same-root registration is idempotent")
    func sameRootRegistrationIsIdempotent() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        let worktreeId = UUIDv7.generate()
        let repoId = UUIDv7.generate()
        let rootPath = URL(fileURLWithPath: "/tmp/idempotent-registration-\(UUIDv7.generate().uuidString)")

        let firstOutcome = await actor.registerForObservation(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath
        )
        let secondOutcome = await actor.registerForObservation(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootPath
        )
        await actor.unregister(worktreeId: worktreeId)

        #expect(firstOutcome == .observing)
        #expect(secondOutcome == .observing)
        let firstEnvelope = try #require(await iterator.next())
        let secondEnvelope = try #require(await iterator.next())
        guard case .system(let firstSystemEnvelope) = firstEnvelope,
            case .topology(.worktreeRegistered) = firstSystemEnvelope.event,
            case .system(let secondSystemEnvelope) = secondEnvelope,
            case .topology(.worktreeUnregistered) = secondSystemEnvelope.event
        else {
            Issue.record("Expected one registration fact followed by one unregistration fact")
            await actor.shutdown()
            return
        }

        await actor.shutdown()
    }

    @Test("failed replacement preserves the observing root")
    func failedReplacementPreservesObservingRoot() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let streamClient = ControllableFSEventStreamClient()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: streamClient,
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()
        let worktreeId = UUIDv7.generate()
        let originalRepoId = UUIDv7.generate()
        let originalRootPath = URL(
            fileURLWithPath: "/tmp/original-registration-\(UUIDv7.generate().uuidString)"
        )
        let replacementRepoId = UUIDv7.generate()
        let replacementRootPath = URL(
            fileURLWithPath: "/tmp/replacement-registration-\(UUIDv7.generate().uuidString)"
        )
        _ = await actor.registerForObservation(
            worktreeId: worktreeId,
            repoId: originalRepoId,
            rootPath: originalRootPath
        )
        _ = try #require(await iterator.next())
        streamClient.setNextRegistrationOutcome(.unavailable(.streamStartFailed))

        let replacementOutcome = await actor.registerForObservation(
            worktreeId: worktreeId,
            repoId: replacementRepoId,
            rootPath: replacementRootPath
        )
        await actor.unregister(worktreeId: worktreeId)

        #expect(replacementOutcome == .unavailable(.streamStartFailed))
        let envelope = try #require(await iterator.next())
        guard case .system(let systemEnvelope) = envelope,
            case .topology(.worktreeUnregistered(let unregisteredWorktreeId, let repoId)) =
                systemEnvelope.event
        else {
            Issue.record("Expected unregistration of the retained observing root")
            await actor.shutdown()
            return
        }
        #expect(unregisteredWorktreeId == worktreeId)
        #expect(repoId == originalRepoId)

        await actor.shutdown()
    }

    @Test("unregister emits worktreeUnregistered fact")
    func unregisterEmitsWorktreeUnregisteredFact() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        let worktreeId = UUID()
        let repoId = UUID()
        let rootPath = URL(fileURLWithPath: "/tmp/unregister-\(UUID().uuidString)")
        await actor.register(worktreeId: worktreeId, repoId: repoId, rootPath: rootPath)
        _ = try #require(await iterator.next())  // worktreeRegistered

        await actor.unregister(worktreeId: worktreeId)
        let envelope = try #require(await iterator.next())
        guard case .system(let systemEnvelope) = envelope else {
            Issue.record("Expected system envelope")
            return
        }
        guard
            case .topology(.worktreeUnregistered(let unregisteredWorktreeId, let unregisteredRepoId)) = systemEnvelope
                .event
        else {
            Issue.record("Expected worktreeUnregistered topology event")
            return
        }

        #expect(unregisteredWorktreeId == worktreeId)
        #expect(unregisteredRepoId == repoId)
        #expect(systemEnvelope.source == .builtin(.filesystemWatcher))

        await actor.shutdown()
    }

    @Test("deepest ownership dedupes nested roots")
    func deepestOwnershipDedupesNestedRoots() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let parentId = UUID()
        let childId = UUID()
        await actor.register(worktreeId: parentId, repoId: parentId, rootPath: URL(fileURLWithPath: "/tmp/repo"))
        await actor.register(worktreeId: childId, repoId: childId, rootPath: URL(fileURLWithPath: "/tmp/repo/nested"))

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(
            worktreeId: parentId,
            paths: ["nested/file.swift", "nested/file.swift"]
        )

        let envelope = try #require(await iterator.next())
        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == childId)
        #expect(changeset.paths == ["file.swift"])

        await actor.shutdown()
    }

    @Test("nested root routing emits one owner event per path without duplication")
    func nestedRootRoutingEmitsSingleOwnerPerPath() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let parentId = UUID()
        let childId = UUID()
        await actor.register(worktreeId: parentId, repoId: parentId, rootPath: URL(fileURLWithPath: "/tmp/repo"))
        await actor.register(worktreeId: childId, repoId: childId, rootPath: URL(fileURLWithPath: "/tmp/repo/nested"))

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(
            worktreeId: parentId,
            paths: ["README.md", "nested/src/feature.swift"]
        )

        let firstEnvelope = try #require(await iterator.next())
        let secondEnvelope = try #require(await iterator.next())
        let firstChangeset = try #require(filesChangedChangeset(from: firstEnvelope))
        let secondChangeset = try #require(filesChangedChangeset(from: secondEnvelope))

        #expect(firstChangeset.worktreeId == parentId)
        #expect(firstChangeset.paths == ["README.md"])
        #expect(secondChangeset.worktreeId == childId)
        #expect(secondChangeset.paths == ["src/feature.swift"])

        await actor.shutdown()
    }

    @Test("active-in-app priority order beats sidebar-only")
    func activeInAppPriorityWinsQueueOrder() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .milliseconds(60),
            maxFlushLatency: .seconds(1)
        )

        let basePath = "/tmp/activity-priority-\(UUIDv7.generate().uuidString)"
        let sidebarOnlyWorktreeId = UUIDv7.generate()
        let activeWorktreeId = UUIDv7.generate()
        await actor.register(
            worktreeId: sidebarOnlyWorktreeId, repoId: sidebarOnlyWorktreeId,
            rootPath: URL(fileURLWithPath: basePath))
        await actor.register(
            worktreeId: activeWorktreeId,
            repoId: activeWorktreeId,
            rootPath: URL(fileURLWithPath: "\(basePath)/active"))
        await actor.setActivity(worktreeId: activeWorktreeId, isActiveInApp: true)
        await actor.setActivity(worktreeId: sidebarOnlyWorktreeId, isActiveInApp: false)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(worktreeId: sidebarOnlyWorktreeId, paths: ["README.md"])
        await actor.enqueueRawPaths(worktreeId: activeWorktreeId, paths: ["src/main.swift"])
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(60))

        let firstEnvelope = try #require(await iterator.next())
        let firstChangeset = try #require(filesChangedChangeset(from: firstEnvelope))
        #expect(firstChangeset.worktreeId == activeWorktreeId)

        await actor.shutdown()
    }

    @Test("priority ordering is focused active pane, then active in app, then sidebar-only")
    func priorityOrderingFocusedThenActiveThenSidebar() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let basePath = "/tmp/priority-\(UUID().uuidString)"
        let sidebarWorktreeId = UUID()
        let activeWorktreeId = UUID()
        let focusedWorktreeId = UUID()
        await actor.register(
            worktreeId: sidebarWorktreeId, repoId: sidebarWorktreeId, rootPath: URL(fileURLWithPath: basePath))
        await actor.register(
            worktreeId: activeWorktreeId, repoId: activeWorktreeId, rootPath: URL(fileURLWithPath: "\(basePath)/active")
        )
        await actor.register(
            worktreeId: focusedWorktreeId,
            repoId: focusedWorktreeId,
            rootPath: URL(fileURLWithPath: "\(basePath)/active/focused")
        )

        await actor.setActivity(worktreeId: sidebarWorktreeId, isActiveInApp: false)
        await actor.setActivity(worktreeId: activeWorktreeId, isActiveInApp: true)
        await actor.setActivity(worktreeId: focusedWorktreeId, isActiveInApp: true)
        await actor.setActivePaneWorktree(worktreeId: focusedWorktreeId)

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        // Route all tiers in one ingress call so queue order depends only on priority keys.
        await actor.enqueueRawPaths(
            worktreeId: sidebarWorktreeId,
            paths: ["sidebar.txt", "active/active.txt", "active/focused/focused.txt"]
        )

        let firstEnvelope = try #require(await iterator.next())
        let secondEnvelope = try #require(await iterator.next())
        let thirdEnvelope = try #require(await iterator.next())

        let firstChangeset = try #require(filesChangedChangeset(from: firstEnvelope))
        let secondChangeset = try #require(filesChangedChangeset(from: secondEnvelope))
        let thirdChangeset = try #require(filesChangedChangeset(from: thirdEnvelope))

        #expect(firstChangeset.worktreeId == focusedWorktreeId)
        #expect(secondChangeset.worktreeId == activeWorktreeId)
        #expect(thirdChangeset.worktreeId == sidebarWorktreeId)

        await actor.shutdown()
    }

    @Test("filesChanged routes through worktree envelope from filesystem watcher")
    func filesChangedRoutingContract() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = makeActor(bus: bus)

        let worktreeId = UUID()
        await actor.register(
            worktreeId: worktreeId, repoId: worktreeId, rootPath: URL(fileURLWithPath: "/tmp/contract"))

        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        var iterator = stream.makeAsyncIterator()

        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/App.swift"])

        let envelope = try #require(await iterator.next())
        guard case .worktree(let worktreeEnvelope) = envelope else {
            Issue.record("Expected worktree envelope")
            return
        }
        #expect(worktreeEnvelope.source == .system(.builtin(.filesystemWatcher)))
        #expect(worktreeEnvelope.worktreeId == worktreeId)
        #expect(worktreeEnvelope.repoId == worktreeId)

        let changeset = try #require(filesChangedChangeset(from: envelope))
        #expect(changeset.worktreeId == worktreeId)
        #expect(changeset.paths == ["Sources/App.swift"])

        await actor.shutdown()
    }

    @Test("large path bursts split into fixed-size ordered filesChanged batches")
    func largeBurstSplitsIntoBoundedSortedBatches() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let actor = FilesystemActor(
            bus: bus, fseventStreamClient: ControllableFSEventStreamClient(), sleepClock: TestPushClock(),
            debounceWindow: .zero, maxFlushLatency: .zero)

        let worktreeId = UUIDv7.generate()
        await actor.register(
            worktreeId: worktreeId, repoId: worktreeId, rootPath: URL(fileURLWithPath: "/tmp/large-batch"))

        let probe = await FilesystemPublicationProbe(bus: bus)
        _ = await probe.begin()

        let batchLimit = FilesystemActor.maxPathsPerFilesChangedEvent
        let uniquePathCount = batchLimit * 2 + 17
        let descendingPaths = (0..<uniquePathCount).map { index in
            String(format: "src/%04d.swift", uniquePathCount - index)
        }
        let rawPaths = descendingPaths + ["src/0001.swift", "./src/0001.swift", "/src/0001.swift"]
        let expectedSortedPaths = Set(rawPaths.map(normalizedRelativePath)).sorted()
        let expectedChunkCount = (expectedSortedPaths.count + batchLimit - 1) / batchLimit

        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: rawPaths)

        for _ in 0..<expectedChunkCount { _ = try await probe.nextChangeset() }
        await actor.shutdown()
        try await probe.closeAfterProducerReturn()
        let receivedChangesets = probe.changesets
        #expect(receivedChangesets.allSatisfy { $0.worktreeId == worktreeId && $0.repoId == worktreeId })

        let flattenedPaths = receivedChangesets.flatMap(\.paths)
        let batchSequences = receivedChangesets.map(\.batchSeq)

        #expect(receivedChangesets.count == expectedChunkCount)
        #expect(receivedChangesets.allSatisfy { $0.paths.count <= batchLimit })
        #expect(flattenedPaths == expectedSortedPaths)
        #expect(batchSequences == Array(1...UInt64(expectedChunkCount)))

    }

    @Test("debounce coalesces bursts and flushes once after debounce window")
    func debounceCoalescesBursts() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .milliseconds(60),
            maxFlushLatency: .seconds(1)
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(
            worktreeId: worktreeId,
            repoId: worktreeId,
            rootPath: URL(fileURLWithPath: "/tmp/debounce-\(UUIDv7.generate().uuidString)")
        )

        let probe = await FilesystemPublicationProbe(bus: bus)
        _ = await probe.begin()
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/A.swift"])
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/B.swift"])

        await clock.waitForPendingSleepCount()
        let expectedDeadline = TestPushClock().now.advanced(by: .milliseconds(60))
        #expect(clock.pendingSleepDeadlines == [expectedDeadline])
        clock.advance(by: .milliseconds(20))
        #expect(clock.pendingSleepDeadlines == [expectedDeadline])

        clock.advance(by: .milliseconds(40))
        let changeset = try await probe.nextChangeset()
        #expect(changeset.worktreeId == worktreeId)
        #expect(Set(changeset.paths) == Set(["Sources/A.swift", "Sources/B.swift"]))

        await actor.shutdown()
        try await probe.closeAfterProducerReturn()
        #expect(probe.changesets.count == 1)
        #expect(probe.changesets.allSatisfy { $0.worktreeId == worktreeId && $0.repoId == worktreeId })
    }

    @Test("logical debt retains drain custody until the accepted filesystem batch finishes")
    func logicalDebtRetainsDrainCustodyUntilBatchFinishes() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .milliseconds(60),
            maxFlushLatency: .seconds(1)
        )
        let observed = ObservedFilesystemChanges()
        let stream = await bus.subscribe(policy: .criticalUnbounded, subscriberName: #function)
        let collectionTask = Task {
            for await envelope in stream {
                await observed.record(envelope)
            }
        }
        defer { collectionTask.cancel() }

        let worktreeId = UUID()
        await actor.register(
            worktreeId: worktreeId,
            repoId: worktreeId,
            rootPath: URL(fileURLWithPath: "/tmp/logical-debt-\(UUID().uuidString)")
        )
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/Accepted.swift"])
        await clock.waitForPendingSleepCount()

        let pendingSnapshot = await actor.logicalDebtSnapshot()
        #expect(pendingSnapshot.pendingWorktreeCount == 1)
        #expect(pendingSnapshot.drainTaskCount == 1)
        #expect(pendingSnapshot.logicalDebtCount == 2)

        clock.advance(by: .milliseconds(60))
        _ = await observed.next()
        let reachedZeroDebt = await waitUntilFilesystemLogicalDebt(actor, equals: 0)
        #expect(reachedZeroDebt)
        let finalSnapshot = await actor.logicalDebtSnapshot()
        #expect(finalSnapshot.pendingWorktreeCount == 0)
        #expect(finalSnapshot.drainTaskCount == 0)
        #expect(finalSnapshot.logicalDebtCount == 0)

        await actor.shutdown()
    }

    @Test("default debounce flushes an isolated change after 500 milliseconds of quiet")
    func defaultDebounceFlushesIsolatedChangeAfterQuietWindow() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(
            worktreeId: worktreeId,
            repoId: worktreeId,
            rootPath: URL(fileURLWithPath: "/tmp/default-debounce-\(UUIDv7.generate().uuidString)")
        )
        let probe = await FilesystemPublicationProbe(bus: bus)
        _ = await probe.begin()
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/Isolated.swift"])

        await clock.waitForPendingSleepCount()
        let expectedDeadline = TestPushClock().now.advanced(by: .milliseconds(500))
        #expect(clock.pendingSleepDeadlines == [expectedDeadline])
        clock.advance(by: .milliseconds(499))
        #expect(clock.pendingSleepDeadlines == [expectedDeadline])

        clock.advance(by: .milliseconds(1))
        let changeset = try await probe.nextChangeset()
        #expect(changeset.paths == ["Sources/Isolated.swift"])

        await actor.shutdown()
        try await probe.closeAfterProducerReturn()
        #expect(probe.changesets.count == 1)
        #expect(probe.changesets.allSatisfy { $0.worktreeId == worktreeId && $0.repoId == worktreeId })
    }

    private func filesChangedChangeset(from envelope: RuntimeEnvelope) -> FileChangeset? {
        guard case .worktree(let worktreeEnvelope) = envelope else { return nil }
        guard case .filesystem(.filesChanged(let changeset)) = worktreeEnvelope.event else {
            return nil
        }
        return changeset
    }

    private func normalizedRelativePath(_ rawPath: String) -> String {
        var normalizedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedPath.hasPrefix("./") {
            normalizedPath.removeFirst(2)
        }
        if normalizedPath.hasPrefix("/") {
            normalizedPath.removeFirst()
        }
        return normalizedPath
    }

    private func makeActor(bus: EventBus<RuntimeEnvelope>) -> FilesystemActor {
        FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            debounceWindow: .zero,
            maxFlushLatency: .zero
        )
    }

    private func waitUntilFilesystemLogicalDebt(
        _ actor: FilesystemActor,
        equals expectedCount: Int,
        maxTurns: Int = 10_000
    ) async -> Bool {
        for _ in 0..<maxTurns {
            if await actor.logicalDebtSnapshot().logicalDebtCount == expectedCount {
                return true
            }
            await Task.yield()
        }
        return await actor.logicalDebtSnapshot().logicalDebtCount == expectedCount
    }

    private func makeFilesystemLogicalDebtTraceRuntime() -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": FileManager.default.temporaryDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "filesystem-logical-debt-ordering-\(UUIDv7.generate().uuidString)",
                "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]),
            processIdentifier: 924
        )
    }
}

private actor LogicalDebtSnapshotGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async -> WatchedFolderScanSchedulerStateSnapshot {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return .active(
            WatchedFolderScanSchedulerActiveState(
                ready: 1,
                activeQuanta: 0,
                awaitingValidations: 0,
                pendingResults: 0,
                leasedResults: 0,
                dirtyFollowUps: 0,
                resultCustodyHighWater: 0
            )
        )
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
