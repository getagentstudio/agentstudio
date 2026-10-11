import AgentStudioTestHarness
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension DarwinSharedLocalFSEventObserverFailureTests {
    @Test("unbind suppresses delivery already selected in the same callback batch")
    func unbindSuppressesSelectedDeliveryInSameBatch() async throws {
        // Arrange
        let source = replayFactSource()
        let facts = try source.attach()
        let operationID = UUIDv7.generate()
        let streamFactory = CountingLocalFSEventStreamFactory()
        let registry = DarwinSharedLocalFSEventObserverRegistry(
            streamFactory: streamFactory.makeStream, recordPhysicalRawCallback: { _ in }
        )
        defer { registry.shutdown() }
        let leaseHolder = ReplayTestLeaseHolder()
        for _ in 0..<2 {
            let worktreeID = UUIDv7.generate()
            let lease = try #require(
                registry.bind(
                    request: DarwinLocalFSEventStreamRequest(
                        worktreeId: worktreeID, lifecycleGeneration: 1, watchedPaths: ["/tmp"],
                        privateStagingExclusionPaths: [],
                        eventHandler: { _ in
                            source.sink(
                                operationID,
                                leaseHolder.isRetired(worktreeID) ? .deliveryAfterRetirement : .delivered(worktreeID))
                            leaseHolder.retireOthers(except: worktreeID)
                        }
                    )
                )
            )
            leaseHolder.retain(lease, for: worktreeID)
        }
        let opening = await facts.mark(operationID)

        // Act
        #expect(streamFactory.sendToCurrentStream([.init(path: "/tmp/file", eventId: 1, flags: 0)]))
        source.sink(operationID, .completed)

        // Assert: the first handler unbound its peer before delivery could start.
        try await facts.expectNone(
            of: { $0 == .deliveryAfterRetirement },
            "delivery after unbind", from: opening, closedBy: { $0 == .completed })
        try await facts.finish()
    }

    @Test("another bind completes while replacement replay is held", arguments: [false, true])
    func anotherBindCompletesWhileReplacementReplayIsHeld(widensPaths: Bool) async throws {
        // Arrange
        let source = replayFactSource()
        let facts = try source.attach()
        let operationID = UUIDv7.generate()
        let replayStep = HeldStep<String>("replacement replay path preparation")
        defer { replayStep.retire() }
        let replayPath = "/tmp/c1-first/replayed"
        let streamFactory = ConcurrentReplayStreamFactory(bufferedEventPath: replayPath)
        let registry = DarwinSharedLocalFSEventObserverRegistry(
            streamFactory: streamFactory.makeStream, recordPhysicalRawCallback: { _ in },
            normalizePath: { path in
                if path == replayPath { _ = try? replayStep.arriveBlocking(path) }
                return DarwinFSEventPathNormalizer.lexicallyNormalizedAbsolutePath(path)
            }
        )
        defer { registry.shutdown() }
        let firstID = UUIDv7.generate()
        let firstLease = try #require(
            registry.bind(
                request: replayRequest(path: "/tmp/c1-first", worktreeID: firstID) { events in
                    for event in events { source.sink(operationID, .eventDelivered(event.eventId)) }
                }
            )
        )
        let replacementID = UUIDv7.generate()
        let replacementTask = Task {
            await valueFromDedicatedThread {
                registry.bind(request: replayRequest(path: "/tmp/c1-second", worktreeID: replacementID))
            }
        }

        // Act: the join/replacement must return before the held replay is released.
        #expect(try await replayStep.firstArrival() == replayPath)
        let concurrentID = UUIDv7.generate()
        let concurrentLease = try #require(
            await valueFromDedicatedThread {
                let lease = registry.bind(
                    request: replayRequest(
                        path: widensPaths ? "/tmp/c1-third" : "/tmp/c1-second", worktreeID: concurrentID
                    )
                )
                source.sink(operationID, .concurrentBindCompleted)
                return lease
            }
        )
        try await facts.expectNext(in: operationID, .concurrentBindCompleted)
        streamFactory.sendNewest(path: replayPath, eventID: 101)
        replayStep.release()
        let replacementLease = try #require(await replacementTask.value)
        source.sink(operationID, .completed)

        // Assert
        try await facts.expectNext(in: operationID, .eventDelivered(100))
        try await facts.expectNext(in: operationID, .eventDelivered(101))
        try await facts.expectNext(in: operationID, .completed)
        #expect(registry.snapshot().logicalRegistrationCount == 3)
        #expect(!registry.snapshot().hasPendingPhysicalReplacement)
        firstLease.retire()
        concurrentLease.retire()
        replacementLease.retire()
        try await facts.finish()
    }
}

private enum ReplayTestFact: Equatable, Sendable {
    case delivered(UUID)
    case deliveryAfterRetirement
    case eventDelivered(UInt64)
    case concurrentBindCompleted
    case completed
}

private func replayFactSource() -> LocalFactSource<UUID, ReplayTestFact> {
    LocalFactSource(
        vocabulary: FactVocabulary(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .completed }
        ))
}

private func replayRequest(
    path: String, worktreeID: UUID,
    handler: @escaping @Sendable ([DarwinLocalFSEventRawEvent]) -> Void = { _ in }
) -> DarwinLocalFSEventStreamRequest {
    .init(
        worktreeId: worktreeID, lifecycleGeneration: 1, watchedPaths: [path],
        privateStagingExclusionPaths: [], eventHandler: handler)
}

private final class ReplayTestLeaseHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [UUID: any DarwinLocalFSEventStreamLifetime] = [:]
    private var retiredIDs: Set<UUID> = []

    func retain(_ lease: any DarwinLocalFSEventStreamLifetime, for worktreeID: UUID) {
        lock.withLock { leases[worktreeID] = lease }
    }

    func retireOthers(except worktreeID: UUID) {
        let retiredLeases = lock.withLock { leases.filter { $0.key != worktreeID } }
        for (retiredID, lease) in retiredLeases {
            lease.retire()
            _ = lock.withLock { retiredIDs.insert(retiredID) }
        }
    }

    func isRetired(_ worktreeID: UUID) -> Bool { lock.withLock { retiredIDs.contains(worktreeID) } }
}

private final class ConcurrentReplayStreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferedEventPath: String
    private var eventHandlers: [@Sendable ([DarwinLocalFSEventRawEvent]) -> Void] = []

    init(bufferedEventPath: String) { self.bufferedEventPath = bufferedEventPath }

    func makeStream(request: DarwinLocalFSEventStreamRequest) -> (any DarwinLocalFSEventStreamLifetime)? {
        let streamIndex = lock.withLock {
            eventHandlers.append(request.eventHandler)
            return eventHandlers.count
        }
        return ConcurrentReplayStreamLifetime(flush: { [self] in
            if streamIndex == 1 { sendNewest(path: bufferedEventPath, eventID: 100) }
            return true
        })
    }

    func sendNewest(path: String, eventID: UInt64) {
        let handler = lock.withLock { eventHandlers.last }
        handler?([.init(path: path, eventId: eventID, flags: 0)])
    }
}

private final class ConcurrentReplayStreamLifetime: DarwinLocalFSEventStreamLifetime, Sendable {
    private let flushHandler: @Sendable () -> Bool
    init(flush: @escaping @Sendable () -> Bool) { flushHandler = flush }
    func flush() -> Bool { flushHandler() }
    func retire() {}
    func scheduleRetirement() {}
}
