import AgentStudioTestHarness
import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension DarwinSharedExactItemObserverTests {
    @Test("exact-item index agrees with the lexical ancestor rule")
    func exactItemIndexAgreesWithLexicalAncestorOracle() {
        // Arrange: bindings are already canonical; retain unusual lexical inputs too.
        let exactPaths = [
            "", "/", "/a", "/a/b", "/a/b/", "/a/b/nested", "/a/bc", "/a/sibling",
            "//", "//child", "/a/b//child", "/private/tmp/item", "/tmp/item",
            "/a/Case", "/a/case", "relative", "relative/", "relative/child",
        ]
        let eventPaths = exactPaths + ["/missing", "/a/CASE", "/a/bother", "relative/missing"]
        let index = DarwinFSEventWatchedPathIndex(normalizedPaths: exactPaths)

        for eventPath in eventPaths {
            // Act
            let actual = index.strictDescendants(of: eventPath)

            // Assert: this observer's rule literally appends '/', even for '/'.
            let expected = Set(exactPaths.filter { $0.hasPrefix(eventPath + "/") })
            #expect(actual == expected, Comment(rawValue: "event path: \(eventPath)"))
        }
    }

    @Test("exact-item receive agrees with an independent event by binding table")
    func exactItemReceiveAgreesWithRoutingOracle() async throws {
        // Arrange
        let pathRows: [(raw: String, normalized: String, qualifiesActivity: Bool)] = [
            ("/", "/", false), ("/a", "/a", false), ("/a/b", "/a/b", false),
            ("/a/b/", "/a/b/", false), ("/a/b/nested", "/a/b/nested", false),
            ("/a/bc", "/a/bc", false), ("/a/bother", "/a/bother", false),
            ("/a/./b/child/../nested", "/a/b/nested", false),
            ("/a/HEAD", "/a/HEAD", true), ("/a/HEAD.lock", "/a/HEAD.lock", false),
            ("/a/refs/heads/main", "/a/refs/heads/main", true),
            ("/a/refs/agentstudio/staged/attempt/main", "/a/refs/agentstudio/staged/attempt/main", false),
            ("/private/tmp/item", "/private/tmp/item", false), ("/tmp/item", "/tmp/item", false),
            ("/a/Case", "/a/Case", false), ("/a/CASE", "/a/CASE", false),
            ("/obsolete", "/obsolete", false), ("/obsolete/item", "/obsolete/item", false),
        ]
        let flagRows: [UInt32] = [
            0, UInt32(kFSEventStreamEventFlagOwnEvent), UInt32(kFSEventStreamEventFlagMustScanSubDirs),
            UInt32(kFSEventStreamEventFlagUserDropped), UInt32(kFSEventStreamEventFlagKernelDropped),
            UInt32(kFSEventStreamEventFlagEventIdsWrapped), UInt32(kFSEventStreamEventFlagRootChanged),
            UInt32(kFSEventStreamEventFlagMount), UInt32(kFSEventStreamEventFlagUnmount),
        ]
        for pathRow in pathRows {
            for flags in flagRows {
                let events = [DarwinSharedExactItemRawEvent(path: pathRow.raw, eventId: 101, flags: flags)]
                try await proveExactItemReceive(
                    events, normalizedPaths: [pathRow.normalized],
                    activityPaths: pathRow.qualifiesActivity ? [pathRow.normalized] : [])
            }
        }
        // Cursor regression within a batch, exact hits on both sides, and ancestor
        // ambiguity cancelled by an exact hit in either FSEvents order.
        for paths in [["/a", "/a/b"], ["/a/b", "/a"], ["/a/HEAD", "/a/HEAD"]] {
            let events = zip(paths, [UInt64(102), 101]).map {
                DarwinSharedExactItemRawEvent(path: $0.0, eventId: $0.1, flags: 0)
            }
            try await proveExactItemReceive(events, normalizedPaths: paths, activityPaths: ["/a/HEAD"])
        }
        try await proveExactItemReceive(
            [.init(path: "/a", eventId: 101, flags: 0), .init(path: "/a/b", eventId: 102, flags: 0)],
            normalizedPaths: ["/a", "/a/b"], activityPaths: [])
        try await proveExactItemReceive(
            [.init(path: "/a/b", eventId: 101, flags: 0), .init(path: "/a", eventId: 102, flags: 0)],
            normalizedPaths: ["/a/b", "/a"], activityPaths: [])
    }
}

private enum ExactItemRoutingFact: Equatable, Sendable {
    case ancestor(UUID)
    case activity(Set<UUID>, Set<UUID>, Set<UUID>, UInt64)
    case mutation(UUID, [UInt64])
    case uncertain(UUID)
    case refresh(UUID, Bool)
    case completed
}

private func proveExactItemReceive(
    _ events: [DarwinSharedExactItemRawEvent], normalizedPaths: [String], activityPaths: Set<String>
) async throws {
    // Arrange: shared paths, nested exact items, pending ancestor interest, and
    // one binding whose externally-owned currentness becomes false after bind.
    let source = LocalFactSource<UUID, ExactItemRoutingFact>(
        vocabulary: FactVocabulary(
            describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
            isClosing: { _, fact in fact == .completed }))
    let facts = try source.attach()
    let operationID = UUIDv7.generate()
    let streamFactory = RecordingSharedExactItemStreamFactory()
    let registry = DarwinSharedExactItemObserverRegistry(
        streamFactory: streamFactory.makeStream,
        recordRawEvents: { worktreeID, rawEvents in
            source.sink(operationID, .mutation(worktreeID, rawEvents.map(\.eventId)))
        },
        recordAncestorAmbiguity: { worktreeID in
            source.sink(operationID, .ancestor(worktreeID))
            return 2
        },
        markUncertain: { source.sink(operationID, .uncertain($0)) },
        yieldFullGitRefresh: { source.sink(operationID, .refresh($0, $1 == .sharedUncertainty)) },
        yieldActivityObservations: {
            source.sink(
                operationID,
                .activity(
                    $0.participantWorktreeIds, $0.qualifyingWorktreeIds, $0.coverageLostWorktreeIds,
                    $0.processedThroughEventID))
        },
        performanceAccumulator: DarwinFSEventIngressPerformanceAccumulator())
    defer { registry.shutdown() }
    let parent = DarwinSharedExactItemParentKey(parentPath: "/", volumeSystemNumber: 1)
    let registrationPaths: [Set<String>] = [
        ["/"], ["/a/b"], ["/a/b/nested"], ["/a/bc"], ["/a/sibling"], ["/a/b"],
        ["/a/b/"], ["/a/HEAD"], ["/a/HEAD.lock"], ["/a/refs/heads/main"],
        ["/a/refs/agentstudio/staged/attempt/main"], ["/private/tmp/item"], ["/tmp/item"],
        ["/a/Case"], ["/a/b", "/a/b/nested"],
    ]
    let worktreeIDs = registrationPaths.map { _ in UUIDv7.generate() }
    let originallyBound = registry.bind(
        worktreeId: worktreeIDs[0], bindingGeneration: 1, exactItemsByParent: [parent: ["/obsolete/item"]],
        bindingIsCurrent: { true })
    #expect(originallyBound)
    let originalGeneration = try #require(registry.snapshot().generationByParent[parent])
    for (worktreeID, paths) in zip(worktreeIDs, registrationPaths) {
        let bound = registry.bind(
            worktreeId: worktreeID, bindingGeneration: 1, exactItemsByParent: [parent: paths],
            bindingIsCurrent: { true })
        #expect(bound)
    }
    let inactiveID = UUIDv7.generate()
    let inactiveBinding = ExactItemRoutingBindingCurrentness()
    let boundInactive = registry.bind(
        worktreeId: inactiveID, bindingGeneration: 1, exactItemsByParent: [parent: ["/a/b"]],
        bindingIsCurrent: { inactiveBinding.isCurrent })
    #expect(boundInactive)
    inactiveBinding.invalidate()
    let removedID = UUIDv7.generate()
    let boundRemoved = registry.bind(
        worktreeId: removedID, bindingGeneration: 1, exactItemsByParent: [parent: ["/obsolete/second"]],
        bindingIsCurrent: { true })
    #expect(boundRemoved)
    registry.unbind(worktreeId: removedID)
    let generation = try #require(registry.snapshot().generationByParent[parent])
    #expect(generation == originalGeneration)
    // Seed an in-flight recheck's pending interest at the classification boundary.
    // Its completion is outside this table; no asynchronous recheck task is started.
    let pendingID = worktreeIDs[14]
    registry.lifecycleCondition.withLock {
        registry.observerByParent[parent]?.activeAncestorRecheckGeneration = 1
        registry.observerByParent[parent]?.unresolvedAncestorEntriesByWorktreeId[pendingID] =
            .init(observedEpoch: 1, latestEventId: 100, canonicalItemPaths: ["/a/b", "/a/b/nested"])
    }
    let expected = exactItemReceiveOracle(
        events, normalizedPaths: normalizedPaths, activityPaths: activityPaths,
        registrationPaths: registrationPaths, worktreeIDs: worktreeIDs, pendingIDs: [pendingID])
    let opening = await facts.mark(operationID)

    // Act: synchronous receive return closes all accepted effects in this fixture.
    registry.receive(parentKey: parent, streamGeneration: generation, rawEvents: events)
    source.sink(operationID, .completed)

    // Assert
    for expectedFact in expected.facts { try await facts.expectNext(in: operationID, expectedFact) }
    try await facts.expectNext(in: operationID, .completed)
    try await facts.expectNone(
        of: { $0 != .completed && !expected.facts.contains($0) }, "unmodeled routing effect", from: opening,
        closedBy: { $0 == .completed })
    let retires = events.contains { $0.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
    #expect(streamFactory.retirementCount == (retires ? 1 : 0))
    if !retires {
        #expect(
            registry.lifecycleCondition.withLock { registry.observerByParent[parent]?.latestEventId }
                == events.last?.eventId)
        #expect(
            registry.lifecycleCondition.withLock {
                registry.observerByParent[parent]?.unresolvedAncestorEntriesByWorktreeId
            } == expected.unresolvedEntries)
    }
    try await facts.finish()
}

private func exactItemReceiveOracle(
    _ events: [DarwinSharedExactItemRawEvent], normalizedPaths: [String], activityPaths: Set<String>,
    registrationPaths: [Set<String>], worktreeIDs: [UUID], pendingIDs: Set<UUID>
) -> ExactItemRoutingOracle {
    var mutationIDs: [UUID: [UInt64]] = [:]
    var ancestorIDs: Set<UUID> = []
    var uncertainIDs: Set<UUID> = []
    var qualifyingIDs: Set<UUID> = []
    var ownIDs: Set<UUID> = []
    var exactIDs: Set<UUID> = []
    var cursor: UInt64?
    var ancestorPaths: [UUID: Set<String>] = [:]
    var ancestorEventIDs: [UUID: UInt64] = [:]
    let uncertaintyMask = UInt32(
        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount)
    for (event, normalizedPath) in zip(events, normalizedPaths) {
        let uncertain = event.flags & uncertaintyMask != 0 || cursor.map { event.eventId < $0 } == true
        cursor = event.eventId
        for (worktreeID, exactPaths) in zip(worktreeIDs, registrationPaths) {
            if exactPaths.contains(normalizedPath) {
                mutationIDs[worktreeID, default: []].append(event.eventId)
                exactIDs.insert(worktreeID)
                if activityPaths.contains(normalizedPath) {
                    if event.flags & UInt32(kFSEventStreamEventFlagOwnEvent) != 0 {
                        ownIDs.insert(worktreeID)
                    } else {
                        qualifyingIDs.insert(worktreeID)
                    }
                }
            }
            if uncertain {
                uncertainIDs.insert(worktreeID)
            } else {
                let descendants = exactPaths.filter { $0.hasPrefix(normalizedPath + "/") }
                if !descendants.isEmpty {
                    ancestorIDs.insert(worktreeID)
                    ancestorPaths[worktreeID, default: []].formUnion(descendants)
                    ancestorEventIDs[worktreeID] = max(ancestorEventIDs[worktreeID] ?? event.eventId, event.eventId)
                }
            }
        }
    }
    ancestorIDs.subtract(uncertainIDs.union(exactIDs))
    let lostIDs = uncertainIDs.union(ownIDs).union(exactIDs.intersection(pendingIDs).subtracting(qualifyingIDs))
    func sortedIDs(_ ids: Set<UUID>) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
    var expected = sortedIDs(ancestorIDs).map(ExactItemRoutingFact.ancestor)
    expected.append(.activity(Set(worktreeIDs), qualifyingIDs, lostIDs, events.map(\.eventId).max() ?? 0))
    expected += sortedIDs(exactIDs).map { .mutation($0, mutationIDs[$0, default: []]) }
    expected += sortedIDs(uncertainIDs).map(ExactItemRoutingFact.uncertain)
    expected += sortedIDs(exactIDs.union(uncertainIDs)).map { .refresh($0, uncertainIDs.contains($0)) }
    var unresolvedEntries = Dictionary(
        uniqueKeysWithValues: pendingIDs.map {
            (
                $0,
                DarwinSharedExactItemAncestorUnresolvedEntry(
                    observedEpoch: 1, latestEventId: 100, canonicalItemPaths: ["/a/b", "/a/b/nested"])
            )
        })
    for worktreeID in uncertainIDs { unresolvedEntries.removeValue(forKey: worktreeID) }
    for worktreeID in exactIDs.subtracting(uncertainIDs) {
        guard var entry = unresolvedEntries[worktreeID] else { continue }
        let paths = Set(
            zip(events, normalizedPaths).compactMap { event, path in
                mutationIDs[worktreeID, default: []].contains(event.eventId) ? path : nil
            })
        entry.canonicalItemPaths.subtract(paths)
        unresolvedEntries[worktreeID] = entry.canonicalItemPaths.isEmpty ? nil : entry
    }
    for worktreeID in ancestorIDs {
        let previous = unresolvedEntries[worktreeID]
        unresolvedEntries[worktreeID] = .init(
            observedEpoch: 2, latestEventId: max(previous?.latestEventId ?? 0, ancestorEventIDs[worktreeID] ?? 0),
            canonicalItemPaths: (previous?.canonicalItemPaths ?? []).union(ancestorPaths[worktreeID, default: []]))
    }
    return ExactItemRoutingOracle(facts: expected, unresolvedEntries: unresolvedEntries)
}

private struct ExactItemRoutingOracle: Sendable {
    let facts: [ExactItemRoutingFact]
    let unresolvedEntries: [UUID: DarwinSharedExactItemAncestorUnresolvedEntry]
}

private final class ExactItemRoutingBindingCurrentness: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func invalidate() { lock.withLock { current = false } }
}
