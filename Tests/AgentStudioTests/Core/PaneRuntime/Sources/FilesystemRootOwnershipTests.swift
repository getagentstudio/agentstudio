import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("FilesystemRootOwnership")
struct FilesystemRootOwnershipTests {
    @Test("own and linked-worktree Git metadata routes relative to the main root's .git")
    func gitMetadataRoutesWithGitAsFirstComponent() {
        // Arrange
        let mainWorktreeId = UUIDv7.generate()
        let linkedWorktreeId = UUIDv7.generate()
        let ownership = FilesystemRootOwnership(
            canonicalRootsByWorktree: [mainWorktreeId: "/tmp/repo", linkedWorktreeId: "/tmp/repo.feature"])

        // Act
        let mainGitPath = ownership.route(sourceWorktreeId: mainWorktreeId, rawPath: "/tmp/repo/.git/index")
        let linkedGitPath = ownership.route(
            sourceWorktreeId: linkedWorktreeId, rawPath: "/tmp/repo/.git/worktrees/repo.feature/index")

        // Assert
        #expect(mainGitPath == FilesystemOwnedPath(worktreeId: mainWorktreeId, relativePath: ".git/index"))
        #expect(
            linkedGitPath
                == FilesystemOwnedPath(
                    worktreeId: mainWorktreeId, relativePath: ".git/worktrees/repo.feature/index"))
    }

    @Test("routes to deepest matching root across nested ownership")
    func routesToDeepestMatchingRoot() {
        let parentWorktreeId = UUID()
        let nestedWorktreeId = UUID()
        let deepestWorktreeId = UUID()

        let ownership = FilesystemRootOwnership(
            rootsByWorktree: [
                parentWorktreeId: URL(fileURLWithPath: "/tmp/root"),
                nestedWorktreeId: URL(fileURLWithPath: "/tmp/root/nested"),
                deepestWorktreeId: URL(fileURLWithPath: "/tmp/root/nested/deep"),
            ]
        )

        let owned = ownership.route(
            sourceWorktreeId: parentWorktreeId,
            rawPath: "/tmp/root/nested/deep/src/File.swift"
        )

        #expect(owned?.worktreeId == deepestWorktreeId)
        #expect(owned?.relativePath == "src/File.swift")
    }

    @Test("exact root boundary resolves relative path to dot")
    func exactRootBoundaryResolvesToDot() {
        let worktreeId = UUID()
        let ownership = FilesystemRootOwnership(
            rootsByWorktree: [worktreeId: URL(fileURLWithPath: "/tmp/repo/")]
        )

        let owned = ownership.route(
            sourceWorktreeId: worktreeId,
            rawPath: "/tmp/repo"
        )

        #expect(owned?.worktreeId == worktreeId)
        #expect(owned?.relativePath == ".")
    }

    @Test("comparison is case-insensitive for canonical path ownership")
    func ownershipComparisonIsCaseInsensitive() {
        let worktreeId = UUID()
        let ownership = FilesystemRootOwnership(
            rootsByWorktree: [worktreeId: URL(fileURLWithPath: "/tmp/RepoCase")]
        )

        let owned = ownership.route(
            sourceWorktreeId: worktreeId,
            rawPath: "/tmp/repocase/Sources/App.swift"
        )

        #expect(owned?.worktreeId == worktreeId)
        #expect(owned?.relativePath == "Sources/App.swift")
    }

    @Test("symlinked root canonicalization routes to same owner")
    func symlinkedRootCanonicalizationRoutesToOwner() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appending(path: "ownership-\(UUID().uuidString)")
        let realRoot = tempRoot.appending(path: "real")
        let linkRoot = tempRoot.appending(path: "link")
        defer { try? fileManager.removeItem(at: tempRoot) }

        try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        let worktreeId = UUID()
        let ownership = FilesystemRootOwnership(
            rootsByWorktree: [worktreeId: linkRoot]
        )

        let owned = ownership.route(
            sourceWorktreeId: worktreeId,
            rawPath: realRoot.appending(path: "src/main.swift").path
        )

        #expect(owned?.worktreeId == worktreeId)
        #expect(owned?.relativePath == "src/main.swift")
    }

    @Test("routes a removed descendant through its nearest existing ancestor")
    func routesRemovedDescendantThroughNearestExistingAncestor() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appending(
            path: "removed-path-ownership-\(UUIDv7.generate().uuidString)"
        )
        let realRoot = temporaryRoot.appending(path: "real")
        let linkedRoot = temporaryRoot.appending(path: "linked")
        let removedFile = linkedRoot.appending(path: "tracked.txt")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        try Data("tracked\n".utf8).write(to: removedFile)

        let worktreeId = UUIDv7.generate()
        let ownership = FilesystemRootOwnership(
            rootsByWorktree: [worktreeId: linkedRoot]
        )
        try fileManager.removeItem(at: removedFile)

        let owned = ownership.route(
            sourceWorktreeId: worktreeId,
            rawPath: removedFile.path
        )

        #expect(owned?.worktreeId == worktreeId)
        #expect(owned?.relativePath == "tracked.txt")
    }

    @Test("unknown source worktree returns nil route")
    func unknownSourceWorktreeReturnsNilRoute() {
        let worktreeId = UUID()
        let ownership = FilesystemRootOwnership(
            rootsByWorktree: [worktreeId: URL(fileURLWithPath: "/tmp/repo")]
        )

        let owned = ownership.route(
            sourceWorktreeId: UUID(),
            rawPath: "/tmp/repo/Sources/App.swift"
        )

        #expect(owned == nil)
    }

    @Test("precanonicalized roots preserve deepest ownership")
    func precanonicalizedRootsPreserveDeepestOwnership() {
        let parentWorktreeId = UUID()
        let nestedWorktreeId = UUID()
        let ownership = FilesystemRootOwnership(
            canonicalRootsByWorktree: [
                parentWorktreeId: "/tmp/root",
                nestedWorktreeId: "/tmp/root/nested",
            ]
        )

        let owned = ownership.route(
            sourceWorktreeId: parentWorktreeId,
            rawPath: "/tmp/root/nested/Sources/App.swift"
        )

        #expect(owned?.worktreeId == nestedWorktreeId)
        #expect(owned?.relativePath == "Sources/App.swift")
    }
}
