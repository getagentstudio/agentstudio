import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Darwin watched-folder admission snapshots")
struct DarwinWatchedFolderAdmissionTests {
    enum DiscoveryScenario: CaseIterable, Sendable { case removedRoot, newCheckout, releasedHold }

    @Test("source filter accumulates mixed and fully dropped batches until the existing drain")
    func sourceFilterAccumulatesOutcomeCounts() throws {
        // Arrange: native delivery is injected; classification, filtering and accumulation stay real.
        let root = DarwinFSEventPathCanonicalizer.canonicalURL(
            FileManager.default.temporaryDirectory.appending(path: "watched-counts-\(UUIDv7.generate())"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = AdmissionSnapshotStreamFactory()
        let client = DarwinFSEventStreamClient(localStreamFactory: factory.makeStream)
        defer { client.shutdown() }
        let callbackID = UUIDv7.generate()
        _ = client.register(worktreeId: callbackID, repoId: UUIDv7.generate(), rootPath: root)
        let checkout = root.appending(path: "known")
        client.updateWatchedFolderAdmission(
            worktreeId: callbackID,
            snapshot: .init(
                root: try registeredRoot(root),
                knownGroups: [.init(clonePath: checkout, linkedWorktreePaths: [])]))
        let deliver = try #require(factory.eventHandler)
        let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
        let irrelevant = DarwinLocalFSEventRawEvent(
            path: checkout.appending(path: "Sources/generated").path, eventId: 1, flags: flags)

        // Act: one mixed batch (three paths, one kept), then one wholly irrelevant batch.
        deliver([
            irrelevant,
            .init(path: checkout.appending(path: "build/output").path, eventId: 2, flags: flags),
            .init(path: root.appending(path: "new-checkout").path, eventId: 3, flags: flags),
        ])
        deliver([irrelevant])
        let attributes = client.snapshotAndResetIngressPerformance().traceAttributes

        // Assert: literal counts from the batches, independent of the filter's implementation.
        let prefix = "agentstudio.performance.filesystem.ingress.watched_folder_filter"
        #expect(attributes["\(prefix).seen.path.count"] == .int(4))
        #expect(attributes["\(prefix).dropped.path.count"] == .int(3))
        #expect(attributes["\(prefix).kept.path.count"] == .int(1))
        #expect(attributes["\(prefix).dropped.batch.count"] == .int(1))
        #expect(client.snapshotAndResetIngressPerformance() == .zero)

        // A registration without a watched-folder snapshot bypasses the filter and its counters.
        client.updateWatchedFolderAdmission(worktreeId: callbackID, snapshot: nil)
        deliver([irrelevant])
        let bypass = client.snapshotAndResetIngressPerformance().traceAttributes
        for suffix in ["seen.path.count", "dropped.path.count", "kept.path.count", "dropped.batch.count"] {
            #expect(bypass["\(prefix).\(suffix)"] == .int(0))
        }
    }

    @Test(
        "routine callbacks leave capacity for discovery with stale and released snapshots",
        arguments: DiscoveryScenario.allCases)
    func sourceFilteringLeavesCapacityForDiscovery(scenario: DiscoveryScenario) async throws {
        // Arrange: real client and capacity-one ingress; only native delivery is injected.
        let root = DarwinFSEventPathCanonicalizer.canonicalURL(
            FileManager.default.temporaryDirectory.appending(path: "watched-client-\(UUIDv7.generate())"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = AdmissionSnapshotStreamFactory()
        let client = DarwinFSEventStreamClient(bufferedFineBatchCapacity: 1, localStreamFactory: factory.makeStream)
        defer { client.shutdown() }
        let callbackID = UUIDv7.generate()
        _ = client.register(worktreeId: callbackID, repoId: UUIDv7.generate(), rootPath: root)
        let descriptor = try registeredRoot(root)
        let checkout = root.appending(path: "known")
        let held = root.appending(path: "held")
        let groups = [RepoScanner.RepoScanGroup(clonePath: checkout, linkedWorktreePaths: [])]
        client.updateWatchedFolderAdmission(
            worktreeId: callbackID,
            snapshot: .init(root: descriptor, knownGroups: groups, heldCheckoutPaths: [held.path]))
        let deliver = try #require(factory.eventHandler)
        let routine = (0..<300).map { index in
            DarwinLocalFSEventRawEvent(
                path: checkout.appending(path: "Sources/generated-\(index)").path,
                eventId: UInt64(index + 1),
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated))
        }

        // Act: snapshot still knows the removed root; new checkout is unknown; released hold becomes unknown.
        deliver(routine)
        let relevantPath: String
        switch scenario {
        case .removedRoot: relevantPath = checkout.path
        case .newCheckout: relevantPath = root.appending(path: "new-checkout/.git").path
        case .releasedHold:
            client.updateWatchedFolderAdmission(
                worktreeId: callbackID, snapshot: .init(root: descriptor, knownGroups: groups))
            relevantPath = held.appending(path: "Sources/new-directory").path
        }
        deliver([
            .init(
                path: relevantPath, eventId: 501,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))
        ])
        client.shutdown()
        var batches: [FSEventBatch] = []
        for await item in client.events() {
            if case .batch(let batch) = item { batches.append(batch) }
        }

        // Assert: filtering after the queue would fill its one slot and lose the positive control.
        #expect(batches.count == 1)
        #expect(
            batches.first?.paths == [
                DarwinFSEventPathCanonicalizer.canonicalURL(URL(fileURLWithPath: relevantPath)).path
            ])
        #expect(batches.first?.observations.map(\.eventID) == [501])
        #expect(client.consumeOverflowRecoveries().isEmpty)
    }

    @Test("clearing the snapshot restores unfiltered delivery")
    func nilSnapshotRestoresUnfilteredDelivery() async throws {
        // Arrange
        let root = DarwinFSEventPathCanonicalizer.canonicalURL(
            FileManager.default.temporaryDirectory.appending(path: "watched-unfiltered-\(UUIDv7.generate())"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = AdmissionSnapshotStreamFactory()
        let client = DarwinFSEventStreamClient(bufferedFineBatchCapacity: 1, localStreamFactory: factory.makeStream)
        defer { client.shutdown() }
        let callbackID = UUIDv7.generate()
        _ = client.register(worktreeId: callbackID, repoId: UUIDv7.generate(), rootPath: root)
        client.updateWatchedFolderAdmission(
            worktreeId: callbackID, snapshot: .init(root: try registeredRoot(root), knownGroups: []))

        // Act
        client.updateWatchedFolderAdmission(worktreeId: callbackID, snapshot: nil)
        let path = root.appending(path: "ordinary.txt").path
        let deliver = try #require(factory.eventHandler)
        deliver([
            .init(path: path, eventId: 601, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        ])
        client.shutdown()
        var batches: [FSEventBatch] = []
        for await item in client.events() {
            if case .batch(let batch) = item { batches.append(batch) }
        }

        // Assert
        #expect(batches.count == 1)
        #expect(batches.first?.observations.map(\.eventID) == [601])
    }

    private func registeredRoot(_ root: URL) throws -> RegisteredRootDescriptor {
        try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                .init(
                    registration: .init(
                        sourceID: .init(kind: .watchedParentMembership, rootID: UUIDv7.generate()),
                        registrationGeneration: 1, rootGeneration: 1),
                    authorizedBoundary: root, registeredRoot: root)))
    }
}

private final class AdmissionSnapshotStreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([DarwinLocalFSEventRawEvent]) -> Void)?

    var eventHandler: (@Sendable ([DarwinLocalFSEventRawEvent]) -> Void)? { lock.withLock { handler } }

    func makeStream(request: DarwinLocalFSEventStreamRequest) -> (any DarwinLocalFSEventStreamLifetime)? {
        lock.withLock { handler = request.eventHandler }
        return AdmissionSnapshotStreamLifetime()
    }
}

private struct AdmissionSnapshotStreamLifetime: DarwinLocalFSEventStreamLifetime {
    func flush() -> Bool { true }
    func retire() {}
    func scheduleRetirement() {}
}
