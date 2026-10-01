import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal target resolver")
struct WorktreeRemovalTargetResolverTests {
    @Test("merges branch and directory inputs that identify the same linked worktree")
    func mergesTargetsForOneWorktree() throws {
        let fixture = try TargetFixture.make()
        defer { fixture.destroy() }
        let nestedDirectory = fixture.linkedWorktree.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let resolver = WorktreeRemovalTargetResolver()

        let targets = resolver.resolve(
            ["feature/linked", fixture.linkedWorktree.path, nestedDirectory.path, "feature/branch-only"],
            callerDirectory: fixture.root,
            repositoryPath: fixture.mainWorktree,
            worktrees: [fixture.mainSnapshot, fixture.linkedSnapshot],
            branches: fixture.branches
        )

        #expect(targets.count == 2)
        guard case .worktree(let linked, let inputs) = targets[0] else {
            Issue.record("expected branch and directory inputs to resolve to the linked worktree")
            return
        }
        #expect(linked.id == fixture.linkedSnapshot.id)
        #expect(inputs == ["feature/linked", fixture.linkedWorktree.path, nestedDirectory.path])
        #expect(targets[1] == .branch(name: "feature/branch-only", inputs: ["feature/branch-only"]))
    }

    @Test("distinguishes an absent repeat from an unregistered sibling directory")
    func distinguishesAlreadyRemovedAndNotFound() throws {
        let fixture = try TargetFixture.make()
        defer { fixture.destroy() }
        let unregisteredBranch = try WorktreeBranchName.validated("feature/unregistered").get()
        let siblingPath = try #require(
            WorktreeDestinationNaming.siblingPath(repositoryPath: fixture.mainWorktree, branchName: unregisteredBranch))
        try FileManager.default.createDirectory(at: siblingPath, withIntermediateDirectories: true)
        let resolver = WorktreeRemovalTargetResolver()

        let targets = resolver.resolve(
            ["feature/gone", "feature/unregistered"],
            callerDirectory: fixture.root,
            repositoryPath: fixture.mainWorktree,
            worktrees: [fixture.mainSnapshot],
            branches: fixture.branches.filter { $0.name == "main" }
        )

        #expect(
            targets == [
                .alreadyRemoved(target: "feature/gone", inputs: ["feature/gone"]),
                .notFound(target: "feature/unregistered", inputs: ["feature/unregistered"]),
            ])
    }
}

private struct TargetFixture {
    let root: URL
    let mainWorktree: URL
    let linkedWorktree: URL
    let mainSnapshot: GitWorktreeSnapshot
    let linkedSnapshot: GitWorktreeSnapshot
    let branches: [GitBranchSnapshot]

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "worktree-removal-targets-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        let mainWorktree = root.appending(path: "repo", directoryHint: .isDirectory)
        let linkedWorktree = root.appending(path: "repo.feature-linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mainWorktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedWorktree, withIntermediateDirectories: true)

        let repositoryID = GitRepositoryID(rawValue: "repository")
        let mainSnapshot = GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "main-worktree"),
            repositoryID: repositoryID,
            displayName: "repo",
            path: mainWorktree,
            canonicalPath: mainWorktree,
            gitDirectory: mainWorktree.appending(path: ".git"),
            indexPath: mainWorktree.appending(path: ".git/index"),
            isMainWorktree: true,
            isLocked: false,
            lockReason: nil,
            head: GitHeadSnapshot(kind: .branch, oid: "main-oid", shortName: "main")
        )
        let linkedSnapshot = GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "linked-worktree"),
            repositoryID: repositoryID,
            displayName: "repo.feature-linked",
            path: linkedWorktree,
            canonicalPath: linkedWorktree,
            gitDirectory: mainWorktree.appending(path: ".git/worktrees/feature-linked"),
            indexPath: mainWorktree.appending(path: ".git/worktrees/feature-linked/index"),
            isMainWorktree: false,
            isLocked: false,
            lockReason: nil,
            head: GitHeadSnapshot(kind: .branch, oid: "feature-oid", shortName: "feature/linked")
        )
        return Self(
            root: root,
            mainWorktree: mainWorktree,
            linkedWorktree: linkedWorktree,
            mainSnapshot: mainSnapshot,
            linkedSnapshot: linkedSnapshot,
            branches: [
                GitBranchSnapshot(name: "main", isCurrent: true, upstreamName: nil),
                GitBranchSnapshot(name: "feature/linked", isCurrent: false, upstreamName: nil),
                GitBranchSnapshot(name: "feature/branch-only", isCurrent: false, upstreamName: nil),
            ]
        )
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}
