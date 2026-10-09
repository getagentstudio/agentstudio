import CoreServices
import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Watched folder topology admission")
struct WatchedFolderTopologyAdmissionTests {
    enum Scenario: CaseIterable, Sendable {
        case knownCheckout, ancestor, newDirectory, insideCheckout, metadataOnly, outsideRoot, ordinaryFile, gitMarker

        var shouldScan: Bool {
            switch self {
            case .knownCheckout, .ancestor, .newDirectory: true
            case .insideCheckout, .metadataOnly, .outsideRoot, .ordinaryFile, .gitMarker: false
            }
        }
    }

    @Test(
        "directory admission respects scan boundaries without scanning ordinary checkout changes",
        arguments: Scenario.allCases)
    func directoryAdmissionRespectsKnownCheckoutBoundary(_ scenario: Scenario) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "topology-admission-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = FSEventRegistrationToken(
            sourceID: .init(kind: .watchedParentMembership, rootID: UUIDv7.generate()),
            registrationGeneration: 1, rootGeneration: 1)
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                .init(registration: registration, authorizedBoundary: root, registeredRoot: root)))
        let known = root.appending(path: "container/known")
        let changedDirectory = UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        let event: (URL, UInt32) =
            switch scenario {
            case .knownCheckout: (known, changedDirectory)
            case .ancestor: (root.appending(path: "container"), changedDirectory)
            case .newDirectory: (root.appending(path: "new"), changedDirectory)
            case .insideCheckout: (known.appending(path: "Sources/Renamed"), changedDirectory)
            case .metadataOnly: (known, UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified))
            case .outsideRoot: (root.deletingLastPathComponent().appending(path: "outside"), changedDirectory)
            case .ordinaryFile: (root.appending(path: "notes.txt"), UInt32(kFSEventStreamEventFlagItemCreated))
            case .gitMarker:
                (
                    known.appending(path: ".git/HEAD"),
                    UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed)
                )
            }
        let batch = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [event.0.path],
            observations: [.init(path: event.0.path, eventID: 1, flags: event.1)])

        #expect(
            WatchedFolderTopologyAdmission.shouldScan(
                batch, root: descriptor, knownGroups: [.init(clonePath: known, linkedWorktreePaths: [])])
                == scenario.shouldScan)
    }

    private static let routinePaths = [
        "index", "HEAD", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD",
        "REVERT_HEAD", "REBASE_HEAD", "AUTO_MERGE", "BISECT_LOG", "COMMIT_EDITMSG", "packed-refs",
        "index.lock", "config.lock", "objects/ab/cd", "refs/heads/main", "logs/HEAD",
        "modules/sub/index", "rebase-merge/head-name", "rebase-apply/next", "sequencer/todo",
    ]

    @Test(
        "routine Git content is rejected in main and linked administrative directories",
        arguments: routinePaths.flatMap { [".git/" + $0, ".git/worktrees/feature/" + $0] })
    func routineGitContentDoesNotAdmitScan(relativePath: String) throws {
        // Arrange
        let fixture = try makeGitAdmissionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = fixture.checkout.appending(path: relativePath).path
        let batch = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [path],
            observations: [.init(path: path, eventID: 1, flags: UInt32(kFSEventStreamEventFlagItemModified))])

        // Act / Assert
        #expect(
            !WatchedFolderTopologyAdmission.shouldScan(batch, root: fixture.descriptor, knownGroups: fixture.groups))
        #expect(
            !WatchedFolderTopologyAdmission.shouldScan(
                batch, root: fixture.descriptor, knownGroups: [], heldCheckoutPaths: [fixture.checkout.path]))
    }

    @Test(
        "discovery metadata and unknown Git paths admit by default",
        arguments: [
            ".git", ".git/config", ".git/commondir", ".git/gitdir", ".git/locked",
            ".git/shallow", ".git/info/grafts", ".git/info/unknown", ".git/future-discovery-input",
            ".git/worktrees", ".git/worktrees/new", ".git/worktrees/new/gitdir",
            ".git/worktrees/new/commondir", ".git/worktrees/new/locked",
            ".git/worktrees/new/shallow", ".git/worktrees/new/info/grafts",
            ".git/worktrees/new/future-discovery-input",
        ])
    func discoveryAndUnknownGitPathsAdmitScan(relativePath: String) throws {
        // Arrange
        let fixture = try makeGitAdmissionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = fixture.checkout.appending(path: relativePath).path
        let batch = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [path],
            observations: [.init(path: path, eventID: 1, flags: UInt32(kFSEventStreamEventFlagItemCreated))])

        // Act / Assert
        #expect(WatchedFolderTopologyAdmission.shouldScan(batch, root: fixture.descriptor, knownGroups: fixture.groups))
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(
                batch, root: fixture.descriptor, knownGroups: [], heldCheckoutPaths: [fixture.checkout.path]))
    }

    @Test(
        "structural Git entries admit removal and unknown observations while rejecting routine updates",
        arguments: ["HEAD", "objects", "refs"].flatMap { [".git/" + $0, ".git/worktrees/new/" + $0] })
    func structuralGitEntriesPreserveValidityRecovery(relativePath: String) throws {
        // Arrange
        let fixture = try makeGitAdmissionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = fixture.checkout.appending(path: relativePath).path
        let removed = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [path],
            observations: [.init(path: path, eventID: 1, flags: UInt32(kFSEventStreamEventFlagItemRemoved))])
        let routine = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [path],
            observations: [
                .init(
                    path: path, eventID: 2,
                    flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed))
            ])
        let unknown = FSEventBatch(worktreeId: UUIDv7.generate(), paths: [path])

        // Act / Assert
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(removed, root: fixture.descriptor, knownGroups: fixture.groups))
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(unknown, root: fixture.descriptor, knownGroups: fixture.groups))
        #expect(
            !WatchedFolderTopologyAdmission.shouldScan(routine, root: fixture.descriptor, knownGroups: fixture.groups))
    }

    @Test("nested Git churn stays rejected through the private path alias")
    func nestedGitChurnRejectsCanonicalAndLexicalAliases() throws {
        // Arrange
        let fixture = try makeGitAdmissionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nestedPaths = [
            fixture.checkout.appending(path: ".build-agent-1/checkouts/dep/.git/index").path,
            fixture.checkout.appending(path: ".build-agent-1/checkouts/dep/.git/config").path,
            fixture.checkout.appending(path: "vendor/repo/.git/commondir").path,
        ]
        let paths = nestedPaths + nestedPaths.map { "/private" + $0 }
        let batch = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: paths,
            observations: paths.map { .init(path: $0, eventID: 1, flags: UInt32(kFSEventStreamEventFlagItemModified)) })

        // Act / Assert
        #expect(
            !WatchedFolderTopologyAdmission.shouldScan(batch, root: fixture.descriptor, knownGroups: fixture.groups))
    }

    @Test("Git paths outside known checkouts and loss evidence remain conservative")
    func unknownCheckoutsAndCoverageLossAdmitScan() throws {
        // Arrange
        let fixture = try makeGitAdmissionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let newRepoPath = fixture.root.appending(path: "newrepo/.git/HEAD").path
        let nestedPath = fixture.checkout.appending(path: ".build-agent-1/checkouts/dep/.git/index").path
        let newRepo = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [newRepoPath],
            observations: [.init(path: newRepoPath, eventID: 1, flags: UInt32(kFSEventStreamEventFlagItemModified))])
        let fullRefresh = FSEventBatch(worktreeId: UUIDv7.generate(), paths: [nestedPath], requiresFullGitRefresh: true)
        let coverageLoss = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [nestedPath],
            observations: [.init(path: nestedPath, eventID: 2, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))])

        // Act / Assert
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(newRepo, root: fixture.descriptor, knownGroups: fixture.groups))
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(
                fullRefresh, root: fixture.descriptor, knownGroups: fixture.groups))
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(
                coverageLoss, root: fixture.descriptor, knownGroups: fixture.groups))
    }

    private struct GitAdmissionFixture {
        let root: URL
        let checkout: URL
        let descriptor: RegisteredRootDescriptor
        let groups: [RepoScanner.RepoScanGroup]
    }

    private func makeGitAdmissionFixture() throws -> GitAdmissionFixture {
        let root = URL(fileURLWithPath: "/tmp/git-topology-admission-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registration = FSEventRegistrationToken(
            sourceID: .init(kind: .watchedParentMembership, rootID: UUIDv7.generate()),
            registrationGeneration: 1, rootGeneration: 1)
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(.init(registration: registration, authorizedBoundary: root, registeredRoot: root)))
        let checkout = root.appending(path: "known")
        return GitAdmissionFixture(
            root: root, checkout: checkout, descriptor: descriptor,
            groups: [.init(clonePath: checkout, linkedWorktreePaths: [])])
    }

    @Test("directory creation inside a held destination admits no scan; Git topology paths still admit")
    func heldDestinationIsTreatedAsKnownCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "topology-admission-held-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = FSEventRegistrationToken(
            sourceID: .init(kind: .watchedParentMembership, rootID: UUIDv7.generate()),
            registrationGeneration: 1, rootGeneration: 1)
        let descriptor = try FilesystemSourceConfiguration.registerRoot(
            from: .hostAuthorized(
                .init(registration: registration, authorizedBoundary: root, registeredRoot: root)))
        let heldDestination = root.appending(path: "repo.feature")
        let createdDirectory = heldDestination.appending(path: "Sources/Generated")
        let directoryCreation = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [createdDirectory.path],
            observations: [
                .init(
                    path: createdDirectory.path, eventID: 1,
                    flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated))
            ])
        let gitAdministration = FSEventBatch(
            worktreeId: UUIDv7.generate(), paths: [heldDestination.appending(path: ".git").path])

        #expect(
            !WatchedFolderTopologyAdmission.shouldScan(
                directoryCreation, root: descriptor, knownGroups: [], heldCheckoutPaths: [heldDestination.path]))
        #expect(WatchedFolderTopologyAdmission.shouldScan(directoryCreation, root: descriptor, knownGroups: []))
        #expect(
            WatchedFolderTopologyAdmission.shouldScan(
                gitAdministration, root: descriptor, knownGroups: [], heldCheckoutPaths: [heldDestination.path]))
    }

    @Test("directory topology evidence survives ingress overflow with retained or discarded paths", arguments: [1, 4])
    func directoryEvidenceSurvivesOverflow(pathLimit: Int) {
        let buffer = DarwinFSEventIngressBuffer(capacity: 1, maximumRetainedOverflowPathsPerRegistration: pathLimit)
        let sourceID = UUIDv7.generate()
        buffer.yield(.init(worktreeId: sourceID, paths: ["/watched/ordinary.txt"]))
        buffer.yield(
            .init(
                worktreeId: sourceID, paths: ["/watched/old", "/watched/new"],
                observations: [
                    .init(
                        path: "/watched/old", eventID: 2,
                        flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))
                ]))
        buffer.finish()

        let recoveries = buffer.consumeOverflowRecoveries()
        #expect(recoveries.count == 1)
        #expect(recoveries.first?.requiresWatchedFolderScan == true)
        #expect((recoveries.first?.paths == nil) == (pathLimit == 1))
        #expect(buffer.consumeOverflowRecoveries().isEmpty)
    }
}
