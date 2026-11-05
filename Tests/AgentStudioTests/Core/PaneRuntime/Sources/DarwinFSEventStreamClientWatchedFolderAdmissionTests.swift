import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Darwin watched-folder admission snapshots")
struct DarwinWatchedFolderAdmissionTests {
    enum DiscoveryScenario: CaseIterable, Sendable { case removedRoot, newCheckout, releasedHold }

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
