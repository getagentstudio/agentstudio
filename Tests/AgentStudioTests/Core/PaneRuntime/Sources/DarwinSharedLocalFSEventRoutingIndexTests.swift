import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

extension DarwinSharedLocalFSEventObserverTests {
    @Test("watched-path index agrees with component-boundary containment oracle")
    func watchedPathIndexAgreesWithContainmentOracle() {
        // Arrange
        let watchedPathCases = [
            [
                "/", "/a/b", "/a/b/nested", "/a/bc", "/a/sibling", "/a/b/",
                "/private/tmp/project", "/tmp/project", "/a/Case", "/a/case",
                "relative", "relative/nested", "relative/", "relative//child",
            ],
            ["", "/", "/a", "relative"],
        ]
        let eventPaths =
            watchedPathCases.flatMap { $0 } + [
                "/a", "/a/b/file", "/a/b/nested/file", "/a/bc/file", "/a/bother",
                "/a/b/", "/private/tmp/project/file", "/tmp/project/file", "/a/CASE/file",
                "/elsewhere", "/a/b/nested/",
                "", "relative/nested/file", "relative/", "relative//child/file", "relative-child",
            ]

        for watchedPaths in watchedPathCases {
            // Act
            let index = DarwinFSEventWatchedPathIndex(normalizedPaths: watchedPaths)

            // Assert: the oracle writes the containment rule, independently of the index.
            for eventPath in eventPaths {
                let ancestorPaths = Set(watchedPaths.filter { routingPathContains($0, eventPath) })
                let descendantPaths = Set(watchedPaths.filter { routingPathContains(eventPath, $0) })
                #expect(index.ancestors(of: eventPath) == ancestorPaths)
                #expect(index.descendants(of: eventPath) == descendantPaths)
                #expect(index.intersectingPaths(with: eventPath) == ancestorPaths.union(descendantPaths))
                #expect(index.containsAncestor(of: eventPath) == !ancestorPaths.isEmpty)
            }
        }
    }

    @Test("shared observer routing agrees with a rule-written event table")
    func sharedObserverRoutingAgreesWithRuleWrittenTable() throws {
        // Arrange
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "c1-routing-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let streamFactory = CountingLocalFSEventStreamFactory()
        let registry = DarwinSharedLocalFSEventObserverRegistry(
            streamFactory: streamFactory.makeStream,
            recordPhysicalRawCallback: { _ in }
        )
        defer { registry.shutdown() }
        let registrations = [
            ["/a/b"], ["/a/b/nested"], ["/a/bc"], ["/a/sibling"], ["/a/b"],
            ["/a/b/"], ["/private/tmp/project"], ["/tmp/project"], ["/a/Case", "/a/case"],
            ["/a/b", "/a/b/nested"],
        ].map { paths in paths.map { fixtureRoot.path + $0 } }
        let stagingPath = fixtureRoot.path + "/a/b/.git/refs/agentstudio/staged"
        let deliveries = RoutingTableDeliveryRecorder()
        var leases: [any DarwinLocalFSEventStreamLifetime] = []
        for (registrationIndex, watchedPaths) in registrations.enumerated() {
            leases.append(
                try #require(
                    registry.bind(
                        request: DarwinLocalFSEventStreamRequest(
                            worktreeId: UUIDv7.generate(), lifecycleGeneration: 1,
                            watchedPaths: watchedPaths, privateStagingExclusionPaths: [stagingPath],
                            eventHandler: { deliveries.record(registrationIndex: registrationIndex, events: $0) }
                        )
                    )
                )
            )
        }
        let eventPaths = [
            "/a/b/file", "/a/b/nested/file", "/a/bc/file", "/a/bother", "/a", "/a/b/",
            "/a/b/./nested/../file", "/a/b/.git/refs/agentstudio/staged/attempt/main", "/private/tmp/project/file",
            "/tmp/project/file", "/a/Case/file", "/a/CASE/file", "/elsewhere",
        ].map { fixtureRoot.path + $0 }
        let normalizedEventPaths = [
            "/a/b/file", "/a/b/nested/file", "/a/bc/file", "/a/bother", "/a", "/a/b/",
            "/a/b/file", "/a/b/.git/refs/agentstudio/staged/attempt/main", "/private/tmp/project/file",
            "/tmp/project/file", "/a/Case/file", "/a/CASE/file", "/elsewhere",
        ].map { fixtureRoot.path + $0 }
        let eventFlags = [
            UInt32(kFSEventStreamEventFlagItemModified), UInt32(kFSEventStreamEventFlagRootChanged),
            UInt32(kFSEventStreamEventFlagMustScanSubDirs), UInt32(kFSEventStreamEventFlagMount),
            UInt32(kFSEventStreamEventFlagUnmount), UInt32(kFSEventStreamEventFlagUserDropped),
            UInt32(kFSEventStreamEventFlagKernelDropped), UInt32(kFSEventStreamEventFlagEventIdsWrapped),
            UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped),
        ]
        var events: [DarwinLocalFSEventRawEvent] = []
        var expectedEventIDs: [Int: [UInt64]] = [:]
        for flags in eventFlags {
            for (pathIndex, eventPath) in eventPaths.enumerated() {
                let eventID = UInt64(events.count + 1)
                events.append(.init(path: eventPath, eventId: eventID, flags: flags))
                let normalizedEventPath = normalizedEventPaths[pathIndex]
                let uncertainty =
                    flags
                    & UInt32(
                        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                            | kFSEventStreamEventFlagEventIdsWrapped
                    ) != 0
                let rootChanged = flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                let bypassesStaging =
                    flags
                    & UInt32(
                        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                            | kFSEventStreamEventFlagUnmount
                    ) != 0
                guard bypassesStaging || !routingPathContains(stagingPath, normalizedEventPath) else { continue }
                for (registrationIndex, watchedPaths) in registrations.enumerated() {
                    let matches =
                        uncertainty
                        || watchedPaths.contains { watchedPath in
                            routingPathContains(normalizedEventPath, watchedPath)
                                || (!rootChanged && routingPathContains(watchedPath, normalizedEventPath))
                        }
                    if matches { expectedEventIDs[registrationIndex, default: []].append(eventID) }
                }
            }
        }

        // Act
        #expect(streamFactory.sendToCurrentStream(events))

        // Assert: synchronous callback completion closes this table operation.
        for registrationIndex in registrations.indices {
            #expect(deliveries.eventIDs(for: registrationIndex) == expectedEventIDs[registrationIndex, default: []])
        }
        #expect(leases.count == registrations.count)
    }
}

private func routingPathContains(_ parentPath: String, _ candidatePath: String) -> Bool {
    parentPath == candidatePath || candidatePath.hasPrefix(parentPath == "/" ? "/" : parentPath + "/")
}

private final class RoutingTableDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var eventIDsByRegistration: [Int: [UInt64]] = [:]

    func record(registrationIndex: Int, events: [DarwinLocalFSEventRawEvent]) {
        lock.withLock {
            eventIDsByRegistration[registrationIndex, default: []].append(contentsOf: events.map(\.eventId))
        }
    }

    func eventIDs(for registrationIndex: Int) -> [UInt64] {
        lock.withLock { eventIDsByRegistration[registrationIndex, default: []] }
    }
}
