import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("DarwinSharedLocalFSEventObserver", .serialized)
struct DarwinSharedLocalFSEventObserverTests {
    @Test("one real stream delivers changes to multiple logical worktrees")
    func oneRealStreamDeliversChangesToMultipleLogicalWorktrees() async throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-real-shared-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let firstWorktreeRoot = fixtureRoot.appending(path: "first", directoryHint: .isDirectory)
        let secondWorktreeRoot = fixtureRoot.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstWorktreeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondWorktreeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let client = DarwinFSEventStreamClient()
        let repositoryId = UUIDv7.generate()
        let rootRegistrationId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        _ = client.register(worktreeId: rootRegistrationId, repoId: repositoryId, rootPath: fixtureRoot)
        _ = client.register(worktreeId: firstWorktreeId, repoId: repositoryId, rootPath: firstWorktreeRoot)
        _ = client.register(worktreeId: secondWorktreeId, repoId: repositoryId, rootPath: secondWorktreeRoot)
        let firstCreatedFile = firstWorktreeRoot.appending(path: "first.txt")
        let secondCreatedFile = secondWorktreeRoot.appending(path: "second.txt")
        let deliveryTask = Task<Set<UUID>?, Never> {
            var deliveredWorktreeIds: Set<UUID> = []
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem else { continue }
                if batch.worktreeId == firstWorktreeId,
                    batch.paths.contains(where: { $0.hasSuffix("/first.txt") })
                {
                    deliveredWorktreeIds.insert(firstWorktreeId)
                }
                if batch.worktreeId == secondWorktreeId,
                    batch.paths.contains(where: { $0.hasSuffix("/second.txt") })
                {
                    deliveredWorktreeIds.insert(secondWorktreeId)
                }
                if deliveredWorktreeIds.count == 2 {
                    return deliveredWorktreeIds
                }
            }
            return nil
        }

        // Act
        try Data("first".utf8).write(to: firstCreatedFile)
        try Data("second".utf8).write(to: secondCreatedFile)

        // Assert
        #expect(
            try #require(
                await firstCompletedValue(from: deliveryTask, timeout: .seconds(5))
            ) == [firstWorktreeId, secondWorktreeId]
        )
        let observationSnapshot = client.sharedLocalObservationSnapshot()
        #expect(observationSnapshot.physicalStreamCount == 1)
        #expect(observationSnapshot.logicalRegistrationCount == 3)
        #expect(observationSnapshot.physicalStreamCountByVolume.values.single == 1)
        client.shutdown()
        #expect(client.sharedLocalObservationSnapshot().physicalStreamCount == 0)
        #expect(client.sharedLocalObservationSnapshot().logicalRegistrationCount == 0)
    }

    @Test("real stream preserves descendant logical root replacement semantics")
    func realStreamPreservesDescendantLogicalRootReplacementSemantics() async throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevent-real-descendant-root-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let descendantRoot = fixtureRoot.appending(path: "descendant", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: descendantRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let client = DarwinFSEventStreamClient()
        defer { client.shutdown() }
        let repositoryId = UUIDv7.generate()
        let parentWorktreeId = UUIDv7.generate()
        let descendantWorktreeId = UUIDv7.generate()
        _ = client.register(worktreeId: parentWorktreeId, repoId: repositoryId, rootPath: fixtureRoot)
        _ = client.register(worktreeId: descendantWorktreeId, repoId: repositoryId, rootPath: descendantRoot)
        let readinessSentinel = descendantRoot.appending(path: "native-stream-ready.sentinel")
        let canonicalReadinessSentinel = DarwinFSEventPathCanonicalizer.canonicalURL(readinessSentinel).path
        let readinessTask = Task<FSEventBatch?, Never> {
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem else { continue }
                if batch.worktreeId == descendantWorktreeId,
                    batch.paths.contains(canonicalReadinessSentinel)
                {
                    return batch
                }
            }
            return nil
        }
        try Data("ready".utf8).write(to: readinessSentinel)
        _ = try #require(await firstCompletedValue(from: readinessTask, timeout: .seconds(5)))
        let rootChangedTask = Task<FSEventBatch?, Never> {
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem,
                    batch.worktreeId == descendantWorktreeId,
                    batch.observations.contains(where: { observation in
                        FSEventStreamEventFlags(observation.flags)
                            & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                    })
                else {
                    continue
                }
                return batch
            }
            return nil
        }

        // Act
        try FileManager.default.moveItem(
            at: descendantRoot,
            to: fixtureRoot.appending(path: "relocated-descendant", directoryHint: .isDirectory)
        )

        // Assert
        let rootChangedBatch = try #require(
            await firstCompletedValue(from: rootChangedTask, timeout: .seconds(5))
        )
        #expect(rootChangedBatch.requiresFullGitRefresh)
        let fenceConsumer = Task {
            for await ingressItem in client.events() {
                guard case .activityProcessingFence(let fenceID) = ingressItem else { continue }
                client.acknowledgeActivityProcessingFence(fenceID)
                return
            }
        }
        #expect(
            await waitForLogicalRegistrationCount(
                1,
                client: client,
                timeout: .seconds(1)
            )
        )
        let barrier = try #require(await client.captureActivityBarrier())
        await fenceConsumer.value
        #expect(barrier.bindings.map(\.worktreeId) == [parentWorktreeId])
    }

    @Test("same-volume descendant registrations preserve roots in one physical stream")
    func sameVolumeDescendantRegistrationsPreserveRootsInOnePhysicalStream() throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-local-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: streamFactory.makeStream)
        let repositoryId = UUIDv7.generate()

        // Act
        _ = client.register(
            worktreeId: UUIDv7.generate(),
            repoId: repositoryId,
            rootPath: fixtureRoot
        )
        for index in 0..<100 {
            _ = client.register(
                worktreeId: UUIDv7.generate(),
                repoId: repositoryId,
                rootPath: fixtureRoot.appending(path: "worktree-\(index)", directoryHint: .isDirectory)
            )
        }

        // Assert
        #expect(streamFactory.snapshot == .init(successfulStartCount: 101, activeCount: 1, peakActiveCount: 2))
        client.shutdown()
        #expect(streamFactory.snapshot == .init(successfulStartCount: 101, activeCount: 0, peakActiveCount: 2))
    }

    @Test("same-volume sibling registrations keep physical replacement overlap bounded")
    func sameVolumeSiblingRegistrationsKeepPhysicalReplacementOverlapBounded() throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-siblings-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: streamFactory.makeStream)
        let repositoryId = UUIDv7.generate()

        // Act
        for index in 0..<32 {
            _ = client.register(
                worktreeId: UUIDv7.generate(),
                repoId: repositoryId,
                rootPath: fixtureRoot.appending(path: "worktree-\(index)", directoryHint: .isDirectory)
            )
        }

        // Assert
        #expect(streamFactory.snapshot == .init(successfulStartCount: 32, activeCount: 1, peakActiveCount: 2))
        client.shutdown()
        #expect(streamFactory.snapshot == .init(successfulStartCount: 32, activeCount: 0, peakActiveCount: 2))
    }

    @Test("shared physical stream retires only after its final logical registration")
    func sharedPhysicalStreamRetiresAfterFinalLogicalRegistration() throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-retirement-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: streamFactory.makeStream)
        defer { client.shutdown() }
        let repositoryId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        _ = client.register(worktreeId: firstWorktreeId, repoId: repositoryId, rootPath: fixtureRoot)
        _ = client.register(
            worktreeId: secondWorktreeId,
            repoId: repositoryId,
            rootPath: fixtureRoot.appending(path: "nested", directoryHint: .isDirectory)
        )

        // Act / Assert
        #expect(client.sharedLocalObservationSnapshot().logicalRegistrationCount == 2)
        #expect(streamFactory.snapshot.activeCount == 1)
        client.unregister(worktreeId: firstWorktreeId)
        #expect(client.sharedLocalObservationSnapshot().logicalRegistrationCount == 1)
        #expect(streamFactory.snapshot.activeCount == 1)
        client.unregister(worktreeId: secondWorktreeId)
        #expect(client.sharedLocalObservationSnapshot().logicalRegistrationCount == 0)
        #expect(streamFactory.snapshot.activeCount == 0)
    }

    @Test("activity barrier flushes one shared physical stream once")
    func activityBarrierFlushesOneSharedPhysicalStreamOnce() async throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-barrier-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: streamFactory.makeStream)
        defer { client.shutdown() }
        let repositoryId = UUIDv7.generate()
        _ = client.register(
            worktreeId: UUIDv7.generate(),
            repoId: repositoryId,
            rootPath: fixtureRoot
        )
        for index in 0..<100 {
            _ = client.register(
                worktreeId: UUIDv7.generate(),
                repoId: repositoryId,
                rootPath: fixtureRoot.appending(path: "worktree-\(index)", directoryHint: .isDirectory)
            )
        }
        streamFactory.resetFlushCount()
        let fenceConsumer = Task {
            for await ingressItem in client.events() {
                guard case .activityProcessingFence(let fenceID) = ingressItem else { continue }
                client.acknowledgeActivityProcessingFence(fenceID)
                return
            }
        }

        // Act
        let barrier = await client.captureActivityBarrier()
        await fenceConsumer.value

        // Assert
        #expect(barrier?.bindings.count == 101)
        #expect(streamFactory.flushCountSnapshot == 1)
    }

    @Test("binding prepares only the incoming registration paths")
    func bindingPreparesOnlyIncomingRegistrationPaths() throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-path-preparation-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        let firstRoot = fixtureRoot.appending(path: "first", directoryHint: .isDirectory)
        let secondRoot = fixtureRoot.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let normalizationRecorder = SharedLocalPathNormalizationRecorder()
        let registry = DarwinSharedLocalFSEventObserverRegistry(
            streamFactory: streamFactory.makeStream,
            recordPhysicalRawCallback: { _ in },
            normalizePath: normalizationRecorder.normalize
        )
        defer { registry.shutdown() }

        // Act / Assert
        let firstLease = try #require(
            registry.bind(request: Self.request(root: firstRoot, generation: 1))
        )
        #expect(normalizationRecorder.callCount == 2)

        normalizationRecorder.reset()
        let secondLease = try #require(
            registry.bind(request: Self.request(root: secondRoot, generation: 2))
        )
        #expect(normalizationRecorder.callCount == 2)
        _ = firstLease
        _ = secondLease
    }

    @Test("logical fan-out normalizes each physical raw path once")
    func logicalFanOutNormalizesEachPhysicalRawPathOnce() throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-raw-path-preparation-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let normalizationRecorder = SharedLocalPathNormalizationRecorder()
        let registry = DarwinSharedLocalFSEventObserverRegistry(
            streamFactory: streamFactory.makeStream,
            recordPhysicalRawCallback: { _ in },
            normalizePath: normalizationRecorder.normalize
        )
        defer { registry.shutdown() }
        let deliveryRecorder = SharedLocalPreparedPathDeliveryRecorder()
        let worktreeIds = (0..<174).map { _ in UUIDv7.generate() }
        var leases: [any DarwinLocalFSEventStreamLifetime] = []
        for (index, worktreeId) in worktreeIds.enumerated() {
            let root = fixtureRoot.appending(path: "worktree-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            leases.append(
                try #require(
                    registry.bind(
                        request: Self.request(
                            root: root,
                            worktreeId: worktreeId,
                            generation: UInt64(index + 1),
                            eventHandler: { events in
                                deliveryRecorder.record(worktreeId: worktreeId, events: events)
                            }
                        )
                    )
                )
            )
        }
        normalizationRecorder.reset()

        // Act
        #expect(
            streamFactory.sendToCurrentStream([
                DarwinLocalFSEventRawEvent(
                    path: "\(fixtureRoot.path)/worktree-0/./Changed.swift",
                    eventId: 103,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
                ),
                DarwinLocalFSEventRawEvent(
                    path: "\(fixtureRoot.path)/descendant/..",
                    eventId: 104,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                ),
            ])
        )

        // Assert
        #expect(normalizationRecorder.callCount == 2)
        #expect(leases.count == 174)
        #expect(deliveryRecorder.eventIds(for: worktreeIds[0]) == [103, 104])
        for worktreeId in worktreeIds.dropFirst() {
            #expect(deliveryRecorder.eventIds(for: worktreeId) == [104])
        }
    }

    @Test("shared local stream routes ordinary paths only to intersecting registrations")
    func sharedLocalStreamRoutesOrdinaryPathsToIntersectingRegistrations() async throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-routing-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: streamFactory.makeStream)
        defer { client.shutdown() }
        let repositoryId = UUIDv7.generate()
        let rootRegistrationId = UUIDv7.generate()
        let firstWorktreeId = UUIDv7.generate()
        let secondWorktreeId = UUIDv7.generate()
        let firstWorktreeRoot = fixtureRoot.appending(path: "first", directoryHint: .isDirectory)
        let secondWorktreeRoot = fixtureRoot.appending(path: "second", directoryHint: .isDirectory)
        _ = client.register(worktreeId: rootRegistrationId, repoId: repositoryId, rootPath: fixtureRoot)
        _ = client.register(worktreeId: firstWorktreeId, repoId: repositoryId, rootPath: firstWorktreeRoot)
        _ = client.register(worktreeId: secondWorktreeId, repoId: repositoryId, rootPath: secondWorktreeRoot)
        let eventId: FSEventStreamEventId = 71
        let changedPath = DarwinFSEventPathCanonicalizer.canonicalURL(firstWorktreeRoot)
            .appending(path: "Changed.swift").path
        // Open before stimulus; consume every batch through the correlated
        // ingress fence placed after the synchronous routing call returns.
        let routedWorktreeIds = Task<Set<UUID>, Never> {
            var worktreeIds: Set<UUID> = []
            for await ingressItem in client.events() {
                switch ingressItem {
                case .batch(let batch):
                    if batch.observations.contains(where: { $0.eventID == eventId }) {
                        worktreeIds.insert(batch.worktreeId)
                    }
                case .activityProcessingFence(let fenceId):
                    client.acknowledgeActivityProcessingFence(fenceId)
                    return worktreeIds
                case .activityObservations:
                    break
                }
            }
            return worktreeIds
        }

        // Act
        #expect(
            streamFactory.sendToCurrentStream([
                DarwinLocalFSEventRawEvent(
                    path: changedPath,
                    eventId: eventId,
                    flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
                )
            ])
        )

        // Assert
        #expect(await client.ingressBuffer.enqueueActivityProcessingFence())
        let routed = await routedWorktreeIds.value
        #expect(routed == [rootRegistrationId, firstWorktreeId])
        #expect(!routed.contains(secondWorktreeId))
    }

    @Test("shared local stream broadcasts dropped-event coverage loss to every logical registration")
    func sharedLocalStreamBroadcastsDroppedEventCoverageLossToEveryLogicalRegistration() async throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "darwin-fsevents-shared-loss-\(UUIDv7.generate().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: streamFactory.makeStream)
        defer { client.shutdown() }
        let repositoryId = UUIDv7.generate()
        let worktreeIds = Set((0..<3).map { _ in UUIDv7.generate() })
        for (index, worktreeId) in worktreeIds.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
            _ = client.register(
                worktreeId: worktreeId,
                repoId: repositoryId,
                rootPath: fixtureRoot.appending(path: "worktree-\(index)", directoryHint: .isDirectory)
            )
        }
        let eventId: FSEventStreamEventId = 72
        let routedWorktreeIds = Task<Set<UUID>?, Never> {
            var routed: Set<UUID> = []
            for await ingressItem in client.events() {
                guard case .batch(let batch) = ingressItem,
                    batch.observations.contains(where: { $0.eventID == eventId })
                else {
                    continue
                }
                routed.insert(batch.worktreeId)
                if routed == worktreeIds {
                    return routed
                }
            }
            return nil
        }

        // Act
        #expect(
            streamFactory.sendToCurrentStream([
                DarwinLocalFSEventRawEvent(
                    path: fixtureRoot.appending(path: "unrelated").path,
                    eventId: eventId,
                    flags: FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs
                            | kFSEventStreamEventFlagUserDropped
                    )
                )
            ])
        )

        // Assert
        #expect(
            try #require(
                await firstCompletedValue(from: routedWorktreeIds, timeout: .seconds(5))
            ) == worktreeIds
        )
    }

    private func firstCompletedValue<Value: Sendable>(
        from task: Task<Value?, Never>,
        timeout: Duration
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await AsyncDelay.taskSleep.wait(timeout)
                return nil
            }
            guard let value = await group.next() else {
                task.cancel()
                return nil
            }
            group.cancelAll()
            task.cancel()
            return value
        }
    }

    private func waitForLogicalRegistrationCount(
        _ expectedCount: Int,
        client: DarwinFSEventStreamClient,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while client.sharedLocalObservationSnapshot().logicalRegistrationCount != expectedCount {
                    guard !Task.isCancelled else { return false }
                    await Task.yield()
                }
                return true
            }
            group.addTask {
                try? await AsyncDelay.taskSleep.wait(timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private static func request(
        root: URL,
        worktreeId: UUID = UUIDv7.generate(),
        generation: UInt64,
        eventHandler: @escaping @Sendable ([DarwinLocalFSEventRawEvent]) -> Void = { _ in }
    ) -> DarwinLocalFSEventStreamRequest {
        DarwinLocalFSEventStreamRequest(
            worktreeId: worktreeId,
            lifecycleGeneration: generation,
            watchedPaths: [root.path],
            privateStagingExclusionPaths: [
                root.appending(path: ".git/refs/agentstudio/staged", directoryHint: .isDirectory).path
            ],
            eventHandler: eventHandler
        )
    }
}

private final class SharedLocalPathNormalizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCallCount = 0

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func normalize(_ path: String) -> String {
        lock.withLock {
            recordedCallCount += 1
        }
        return DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath(path)
    }

    func reset() {
        lock.withLock {
            recordedCallCount = 0
        }
    }
}

private final class SharedLocalPreparedPathDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventIdsByWorktreeId: [UUID: [FSEventStreamEventId]] = [:]

    func record(worktreeId: UUID, events: [DarwinLocalFSEventRawEvent]) {
        lock.withLock {
            eventIdsByWorktreeId[worktreeId, default: []].append(contentsOf: events.map(\.eventId))
        }
    }

    func eventIds(for worktreeId: UUID) -> [FSEventStreamEventId] {
        lock.withLock { eventIdsByWorktreeId[worktreeId, default: []] }
    }
}

final class CountingLocalFSEventStreamFactory: @unchecked Sendable {
    struct Snapshot: Equatable {
        let successfulStartCount: Int
        let activeCount: Int
        let peakActiveCount: Int
    }

    private let lock = NSLock()
    private var successfulStartCount = 0
    private var activeCount = 0
    private var peakActiveCount = 0
    private var flushCount = 0
    private var currentEventHandler: (@Sendable ([DarwinLocalFSEventRawEvent]) -> Void)?

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                successfulStartCount: successfulStartCount,
                activeCount: activeCount,
                peakActiveCount: peakActiveCount
            )
        }
    }

    var flushCountSnapshot: Int {
        lock.withLock { flushCount }
    }

    func resetFlushCount() {
        lock.withLock {
            flushCount = 0
        }
    }

    func makeStream(
        request: DarwinLocalFSEventStreamRequest
    ) -> (any DarwinLocalFSEventStreamLifetime)? {
        lock.withLock {
            successfulStartCount += 1
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            currentEventHandler = request.eventHandler
        }
        return CountingLocalFSEventStreamLifetime(
            flush: { [weak self] in self?.recordFlush() },
            retirement: { [weak self] in self?.recordRetirement() }
        )
    }

    func sendToCurrentStream(_ events: [DarwinLocalFSEventRawEvent]) -> Bool {
        guard let eventHandler = lock.withLock({ currentEventHandler }) else { return false }
        eventHandler(events)
        return true
    }

    private func recordRetirement() {
        lock.withLock {
            activeCount -= 1
        }
    }

    private func recordFlush() {
        lock.withLock {
            flushCount += 1
        }
    }
}

private final class CountingLocalFSEventStreamLifetime:
    DarwinLocalFSEventStreamLifetime, @unchecked Sendable
{
    private let lock = NSLock()
    private var didRetire = false
    private let flushCallback: @Sendable () -> Void
    private let retirement: @Sendable () -> Void

    init(
        flush: @escaping @Sendable () -> Void,
        retirement: @escaping @Sendable () -> Void
    ) {
        flushCallback = flush
        self.retirement = retirement
    }

    deinit {
        retire()
    }

    func flush() -> Bool {
        let isActive = lock.withLock { !didRetire }
        if isActive {
            flushCallback()
        }
        return isActive
    }

    func retire() {
        let shouldRetire = lock.withLock {
            guard !didRetire else { return false }
            didRetire = true
            return true
        }
        if shouldRetire {
            retirement()
        }
    }

    func scheduleRetirement() {
        retire()
    }
}
