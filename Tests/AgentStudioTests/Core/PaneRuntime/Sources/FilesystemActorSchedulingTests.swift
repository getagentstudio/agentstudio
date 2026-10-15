import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension FilesystemActorTests {
    @Test("default maximum latency forces a flush after 10 seconds of continuous changes")
    func defaultMaximumLatencyForcesContinuousStormFlush() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock
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
            rootPath: URL(fileURLWithPath: "/tmp/default-max-latency-\(UUID().uuidString)")
        )
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/Change-0.swift"])
        await clock.waitForPendingSleepCount()

        for changeIndex in 1...24 {
            clock.advance(by: .milliseconds(400))
            await actor.enqueueRawPaths(
                worktreeId: worktreeId,
                paths: ["Sources/Change-\(changeIndex).swift"]
            )
        }
        #expect(await observed.filesChangedCount(for: worktreeId) == 0)

        clock.advance(by: .milliseconds(400))
        let changeset = await observed.next()
        #expect(changeset.paths.count == 25)

        await actor.shutdown()
    }

    @Test("max latency flushes pending changes even when debounce keeps extending")
    func maxLatencyFlushesPendingChanges() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .milliseconds(250),
            maxFlushLatency: .milliseconds(120)
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
            rootPath: URL(fileURLWithPath: "/tmp/max-latency-\(UUID().uuidString)")
        )

        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/First.swift"])
        await clock.waitForPendingSleepCount()
        clock.advance(by: .milliseconds(70))
        await Task.yield()
        #expect(await observed.filesChangedCount(for: worktreeId) == 0)
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/Second.swift"])

        await Task.yield()
        clock.advance(by: .milliseconds(50))
        let changeset = await observed.next()
        #expect(changeset.worktreeId == worktreeId)
        #expect(Set(changeset.paths) == Set(["Sources/First.swift", "Sources/Second.swift"]))

        await actor.shutdown()
    }

    @Test("shutdown cancels pending debounce drain and prevents delayed filesChanged emission")
    func shutdownCancelsPendingDrain() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .milliseconds(200),
            maxFlushLatency: .seconds(1)
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(
            worktreeId: worktreeId,
            repoId: worktreeId,
            rootPath: URL(fileURLWithPath: "/tmp/shutdown-drain-\(UUIDv7.generate().uuidString)")
        )

        let probe = await FilesystemPublicationProbe(bus: bus)
        _ = await probe.begin()
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/Cancelled.swift"])
        await clock.waitForPendingSleepCount()

        await actor.shutdown()
        clock.advance(by: .milliseconds(300))
        try await probe.closeAfterProducerReturn()
        #expect(probe.changesets.isEmpty)

    }

    @Test("shutdown closes filesystem admission before asynchronous cleanup")
    func shutdownClosesFilesystemAdmission() async throws {
        let clock = TestPushClock()
        let streamClient = ControllableFSEventStreamClient()
        let scan = HeldStep<WatchedFolderScanRequest>(
            "shutdown cleanup scan", cancellation: .holdThroughCancellation)
        let provider = FilesystemHeldScanProvider(steps: [scan], results: [completeResult(entries: [])])
        let scheduler = try await provider.makeScheduler()
        let actor = FilesystemActor(
            bus: EventBus<RuntimeEnvelope>(), fseventStreamClient: streamClient,
            watchedFolderScanScheduler: scheduler, sleepClock: clock,
            debounceWindow: .milliseconds(200), maxFlushLatency: .seconds(1))
        let root = FileManager.default.temporaryDirectory.appending(path: "shutdown-admission-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktreeID = UUIDv7.generate()
        await actor.register(worktreeId: worktreeID, repoId: worktreeID, rootPath: root)
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                FilesystemHostAuthorizedRootInput(
                    registration: FSEventRegistrationToken(
                        sourceID: FilesystemSourceID(kind: .watchedParentMembership, rootID: UUIDv7.generate()),
                        registrationGeneration: 1, rootGeneration: 1),
                    authorizedBoundary: root, registeredRoot: root)))
        _ = await scheduler.submit(WatchedFolderScanRequest(canonicalRoot: descriptor, cause: .manual))
        let request = try await scan.firstArrival()
        #expect(request.canonicalRoot.registration == descriptor.registration)
        let shutdown = Task { await actor.shutdown() }
        try await scan.cancellationObserved()
        let revisionDuringCleanup = await actor.logicalDebtSnapshotPublicationRevision
        let postShutdownWorktreeID = UUIDv7.generate()
        await actor.register(
            worktreeId: postShutdownWorktreeID, repoId: postShutdownWorktreeID,
            rootPath: URL(fileURLWithPath: "/tmp/post-shutdown-registration"))
        await actor.enqueueRawPaths(worktreeId: worktreeID, paths: ["Sources/PostShutdown.swift"])
        #expect(await actor.hasBegunShutdown)
        #expect(await actor.logicalDebtSnapshotPublicationRevision == revisionDuringCleanup)
        #expect(await actor.pendingWorktreeLogicalDebtCount == 0)
        #expect(streamClient.registeredWorktreeIds == [worktreeID])
        scan.release()
        await shutdown.value
        let revisionAfterShutdown = await actor.logicalDebtSnapshotPublicationRevision
        await actor.register(
            worktreeId: postShutdownWorktreeID, repoId: postShutdownWorktreeID,
            rootPath: URL(fileURLWithPath: "/tmp/post-shutdown-registration"))
        await actor.enqueueRawPaths(worktreeId: worktreeID, paths: ["Sources/PostShutdown.swift"])
        clock.advance(by: .seconds(1))
        #expect(await actor.logicalDebtSnapshotPublicationRevision == revisionAfterShutdown)
        #expect(await actor.pendingWorktreeLogicalDebtCount == 0)
        #expect(await actor.logicalDebtSnapshot().logicalDebtCount == 0)
        #expect(streamClient.registeredWorktreeIds == [worktreeID])
        await actor.shutdown()
    }

    @Test("unregister during debounce window prevents stale filesChanged emission")
    func unregisterDuringDebouncePreventsStaleEmission() async throws {
        let bus = EventBus<RuntimeEnvelope>()
        let clock = TestPushClock()
        let actor = FilesystemActor(
            bus: bus,
            fseventStreamClient: ControllableFSEventStreamClient(),
            sleepClock: clock,
            debounceWindow: .milliseconds(200),
            maxFlushLatency: .seconds(1)
        )

        let worktreeId = UUIDv7.generate()
        await actor.register(
            worktreeId: worktreeId,
            repoId: worktreeId,
            rootPath: URL(fileURLWithPath: "/tmp/unregister-debounce-\(UUIDv7.generate().uuidString)")
        )

        let probe = await FilesystemPublicationProbe(bus: bus)
        let opening = await probe.begin()
        await actor.enqueueRawPaths(worktreeId: worktreeId, paths: ["Sources/Stale.swift"])
        await clock.waitForPendingSleepCount()

        clock.advance(by: .milliseconds(25))

        await actor.unregister(worktreeId: worktreeId)
        clock.advance(by: .milliseconds(300))

        await actor.shutdown()
        try await probe.closeAfterProducerReturn()
        try await probe.facts.expectNone(
            of: { FilesystemPublicationProbe.changeset($0) != nil }, "stale filesChanged",
            from: opening,
            closedBy: { envelope in
                guard case .system(let system) = envelope,
                    case .topology(.worktreeUnregistered(let removedWorktree, let removedRepo)) = system.event
                else { return false }
                return removedWorktree == worktreeId && removedRepo == worktreeId
                    && system.source == .builtin(.filesystemWatcher)
            })
        #expect(probe.changesets.isEmpty)
    }
}

actor ObservedFilesystemChanges {
    private var changesetsByWorktreeId: [UUID: [FileChangeset]] = [:]
    private var pendingChangesets: [FileChangeset] = []
    private var nextWaiters: [CheckedContinuation<FileChangeset, Never>] = []

    func record(_ envelope: RuntimeEnvelope) {
        guard case .worktree(let worktreeEnvelope) = envelope else { return }
        guard case .filesystem(.filesChanged(let changeset)) = worktreeEnvelope.event else { return }
        changesetsByWorktreeId[changeset.worktreeId, default: []].append(changeset)
        if nextWaiters.isEmpty {
            pendingChangesets.append(changeset)
            return
        }

        let waiter = nextWaiters.removeFirst()
        waiter.resume(returning: changeset)
    }

    func filesChangedCount(for worktreeId: UUID) -> Int {
        changesetsByWorktreeId[worktreeId]?.count ?? 0
    }

    func latestChangeset(for worktreeId: UUID) -> FileChangeset? {
        changesetsByWorktreeId[worktreeId]?.last
    }

    func next() async -> FileChangeset {
        if !pendingChangesets.isEmpty {
            return pendingChangesets.removeFirst()
        }

        return await withCheckedContinuation { continuation in
            nextWaiters.append(continuation)
        }
    }
}
