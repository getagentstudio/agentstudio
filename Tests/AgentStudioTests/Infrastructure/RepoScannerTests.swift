import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("RepoScanner")
struct RepoScannerTests {

    @Test("discovers git repos up to 3 levels deep")
    func discoversReposAtDepth() async throws {
        // Arrange
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-test-\(UUID().uuidString)")
        let fm = FileManager.default

        // Level 1: repo-a
        try await initializeGitRepository(at: tmp.appending(path: "repo-a"))
        // Level 2: group/repo-b
        try await initializeGitRepository(at: tmp.appending(path: "group/repo-b"))
        // Level 3: org/team/repo-c
        try await initializeGitRepository(at: tmp.appending(path: "org/team/repo-c"))
        // Level 4 (too deep): org/team/sub/repo-d
        try await initializeGitRepository(at: tmp.appending(path: "org/team/sub/repo-d"))
        // Not a repo: no-git/
        try fm.createDirectory(at: tmp.appending(path: "no-git"), withIntermediateDirectories: true)

        // Act
        let scanner = RepoScanner()
        let repos = await scanner.scanForGitRepos(in: tmp, maxDepth: 3)

        // Assert
        #expect(repos.count == 3)
        let names = Set(repos.map(\.lastPathComponent))
        #expect(names.contains("repo-a"))
        #expect(names.contains("repo-b"))
        #expect(names.contains("repo-c"))
        #expect(!names.contains("repo-d"))

        // Cleanup
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("does not descend into .git directories")
    func skipsGitInternals() async throws {
        // Arrange
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-skip-\(UUID().uuidString)")
        let repoPath = tmp.appending(path: "repo")
        try await initializeGitRepository(at: repoPath)
        try FileManager.default.createDirectory(
            at: repoPath.appending(path: ".git/modules/sub/.git"),
            withIntermediateDirectories: true
        )

        // Act
        let scanner = RepoScanner()
        let repos = await scanner.scanForGitRepos(in: tmp, maxDepth: 3)

        // Assert
        #expect(repos.count == 1)
        #expect(repos.first?.lastPathComponent == "repo")

        // Cleanup
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("returns sorted results by name")
    func sortsByName() async throws {
        // Arrange
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-sort-\(UUID().uuidString)")

        try await initializeGitRepository(at: tmp.appending(path: "zebra"))
        try await initializeGitRepository(at: tmp.appending(path: "alpha"))
        try await initializeGitRepository(at: tmp.appending(path: "middle"))

        // Act
        let repos = await RepoScanner().scanForGitRepos(in: tmp, maxDepth: 3)

        // Assert
        #expect(repos.map(\.lastPathComponent) == ["alpha", "middle", "zebra"])

        // Cleanup
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("empty directory returns empty")
    func emptyDirectory() async throws {
        // Arrange
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Act
        let repos = await RepoScanner().scanForGitRepos(in: tmp, maxDepth: 3)

        // Assert
        #expect(repos.isEmpty)

        // Cleanup
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("scan stops at .git boundary and does not descend further")
    func scanStopsAtGitBoundary() async throws {
        // Arrange
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-worktrees-\(UUID().uuidString)")
        let fm = FileManager.default

        // Parent has a .git marker but is not a valid working tree.
        // Scanner must stop here and never descend into children.
        try fm.createDirectory(
            at: tmp.appending(path: "-worktrees/.git"),
            withIntermediateDirectories: true
        )
        // Child repos under a .git boundary must not be discovered.
        try await initializeGitRepository(at: tmp.appending(path: "-worktrees/agent-studio/feature-a"))
        try await initializeGitRepository(at: tmp.appending(path: "-worktrees/askluna-finance/transaction-table-3"))
        // Sibling repo outside the .git boundary should still be discovered.
        try await initializeGitRepository(at: tmp.appending(path: "standalone-repo"))

        // Act
        let repos = await RepoScanner().scanForGitRepos(in: tmp, maxDepth: 4)

        // Assert
        let discoveredPaths = Set(repos.map(canonicalPath(_:)))
        #expect(!discoveredPaths.contains(canonicalPath(tmp.appending(path: "-worktrees"))))
        #expect(!discoveredPaths.contains(canonicalPath(tmp.appending(path: "-worktrees/agent-studio/feature-a"))))
        #expect(
            !discoveredPaths.contains(
                canonicalPath(tmp.appending(path: "-worktrees/askluna-finance/transaction-table-3"))))
        #expect(discoveredPaths.contains(canonicalPath(tmp.appending(path: "standalone-repo"))))

        // Cleanup
        try? fm.removeItem(at: tmp)
    }

    @Test("ignores stale git marker paths that are not valid worktrees")
    func ignoresInvalidGitMarkers() async throws {
        // Arrange
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-invalid-marker-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let validRepoPath = tmp.appending(path: "valid-repo")
        let invalidWorktreePath = tmp.appending(path: "agent-studio.window-system")
        try fm.createDirectory(at: invalidWorktreePath, withIntermediateDirectories: true)
        try "gitdir: /tmp/non-existent/.git/worktrees/agent-studio.window-system\n".write(
            to: invalidWorktreePath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )

        // Make valid-repo pass real git validation.
        try await initializeGitRepository(at: validRepoPath)

        // Act
        let repos = await RepoScanner().scanForGitRepos(in: tmp, maxDepth: 2)
        let discoveredPaths = Set(repos.map(canonicalPath(_:)))

        // Assert
        #expect(discoveredPaths.contains(canonicalPath(validRepoPath)))
        #expect(!discoveredPaths.contains(canonicalPath(invalidWorktreePath)))

        // Cleanup
        try? fm.removeItem(at: tmp)
    }

    @Test("submodule working trees are filtered out")
    func submoduleWorkingTreesAreFilteredOut() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-submodule-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let submoduleSourcePath = tmp.appending(path: "ghostty-source")
        try await initializeGitRepository(at: submoduleSourcePath)
        try "ghostty\n".write(
            to: submoduleSourcePath.appending(path: "README.md"),
            atomically: true,
            encoding: .utf8
        )
        try await runGit(
            at: submoduleSourcePath,
            args: ["add", "README.md"]
        )
        try await runGit(
            at: submoduleSourcePath,
            args: ["commit", "-m", "Initial commit"]
        )

        let superRepoPath = tmp.appending(path: "agent-studio.window-system")
        try await initializeGitRepository(at: superRepoPath)
        try await runGit(
            at: superRepoPath,
            args: [
                "-c", "protocol.file.allow=always",
                "submodule", "add",
                submoduleSourcePath.path,
                "vendor/ghostty",
            ]
        )

        let repos = await RepoScanner().scanForGitRepos(in: tmp, maxDepth: 4)
        let discoveredPaths = Set(repos.map(canonicalPath(_:)))
        #expect(discoveredPaths.contains(canonicalPath(superRepoPath)))
        #expect(!discoveredPaths.contains(canonicalPath(superRepoPath.appending(path: "vendor/ghostty"))))

        let directlyScannedSubmoduleParent = await RepoScanner().scanForGitRepos(
            in: superRepoPath.appending(path: "vendor"),
            maxDepth: 1
        )
        #expect(
            !directlyScannedSubmoduleParent.map(canonicalPath(_:)).contains(
                canonicalPath(superRepoPath.appending(path: "vendor/ghostty"))))
    }

    @Test("clone-root gitdir indirections outside scanned path are filtered out")
    func cloneRootGitdirIndirectionsOutsideScannedPathAreFilteredOut() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-gitdir-alias-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let externalRepoPath = tmp.appending(path: "external-real-repo")
        try await initializeGitRepository(at: externalRepoPath)
        try "real\n".write(to: externalRepoPath.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await runGit(at: externalRepoPath, args: ["add", "README.md"])
        try await runGit(at: externalRepoPath, args: ["commit", "-m", "Seed external repo"])

        let scannedRoot = tmp.appending(path: "watched")
        let decoyPath = scannedRoot.appending(path: "decoy")
        try fm.createDirectory(at: decoyPath, withIntermediateDirectories: true)
        try "gitdir: \(externalRepoPath.appending(path: ".git").path)\n".write(
            to: decoyPath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )

        let repos = await RepoScanner().scanForGitRepos(in: scannedRoot, maxDepth: 2)
        let discoveredPaths = Set(repos.map(canonicalPath(_:)))

        #expect(!discoveredPaths.contains(canonicalPath(decoyPath)))
    }

    @Test("grouped scan discovers real linked worktrees under their parent clone")
    func groupedScanDiscoversRealLinkedWorktreesUnderParentClone() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-grouped-worktree-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let repoPath = tmp.appending(path: "app")
        let linkedWorktreePath = tmp.appending(path: "app-feature")
        try await initializeGitRepository(at: repoPath)
        try "main\n".write(to: repoPath.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await runGit(at: repoPath, args: ["add", "README.md"])
        try await runGit(at: repoPath, args: ["commit", "-m", "Seed app"])
        try await runGit(at: repoPath, args: ["worktree", "add", "-b", "feature/grouped", linkedWorktreePath.path])

        let groups = await RepoScanner().scanForGitReposGrouped(in: tmp, maxDepth: 2)

        #expect(groups.count == 1)
        #expect(groups.first?.clonePath.standardizedFileURL.path == repoPath.standardizedFileURL.path)
        #expect(groups.first?.linkedWorktreePaths.map(canonicalPath(_:)) == [canonicalPath(linkedWorktreePath)])
    }

    @Test("scanner accepts valid repos discovered through a symlinked parent")
    func scannerAcceptsValidReposDiscoveredThroughSymlinkedParent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-symlink-parent-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let realRoot = tmp.appending(path: "real")
        let linkedRoot = tmp.appending(path: "linked")
        let repoPath = realRoot.appending(path: "app")
        try await initializeGitRepository(at: repoPath)
        try fm.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: realRoot.path)

        let repos = await RepoScanner().scanForGitRepos(in: linkedRoot, maxDepth: 2)

        #expect(repos.map(canonicalPath(_:)) == [canonicalPath(repoPath)])
    }

    @Test("grouped scan uses SDK main path when linked worktree gitdir uses alias")
    func groupedScanUsesSDKMainPathWhenLinkedWorktreeGitdirUsesAlias() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-linked-alias-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let repoPath = tmp.appending(path: "app")
        let linkedWorktreePath = tmp.appending(path: "app-feature")
        let aliasPath = tmp.appending(path: "app-alias")
        try await initializeGitRepository(at: repoPath)
        try "main\n".write(to: repoPath.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await runGit(at: repoPath, args: ["add", "README.md"])
        try await runGit(at: repoPath, args: ["commit", "-m", "Seed linked alias"])
        try await runGit(at: repoPath, args: ["worktree", "add", "-b", "feature/alias", linkedWorktreePath.path])
        try fm.createSymbolicLink(atPath: aliasPath.path, withDestinationPath: repoPath.path)
        try "gitdir: \(aliasPath.path)/.git/worktrees/app-feature\n".write(
            to: linkedWorktreePath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )

        let groups = await RepoScanner().scanForGitReposGrouped(in: tmp, maxDepth: 2)

        #expect(groups.count == 1)
        #expect(groups.first?.clonePath.standardizedFileURL.path == repoPath.standardizedFileURL.path)
        #expect(groups.first?.linkedWorktreePaths.map(canonicalPath(_:)) == [canonicalPath(linkedWorktreePath)])
    }

    @Test("scanner accepts standalone repos with separate git directories")
    func scannerAcceptsStandaloneReposWithSeparateGitDirectories() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-separate-git-dir-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let worktreePath = tmp.appending(path: "separate-worktree")
        let gitDirectoryPath = tmp.appending(path: "shared.git")
        try await runGit(at: tmp, args: ["init", "--separate-git-dir", gitDirectoryPath.path, worktreePath.path])

        let repos = await RepoScanner().scanForGitRepos(in: tmp, maxDepth: 2)

        #expect(repos.map(canonicalPath(_:)) == [canonicalPath(worktreePath)])
    }

    @Test("grouped scan keeps separate-git-dir linked worktrees with their main worktree")
    func groupedScanKeepsSeparateGitDirLinkedWorktreesWithMainWorktree() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-separate-git-dir-linked-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let worktreePath = tmp.appending(path: "separate-worktree")
        let linkedWorktreePath = tmp.appending(path: "separate-feature")
        let gitDirectoryPath = tmp.appending(path: "shared.git")
        try await runGit(at: tmp, args: ["init", "--separate-git-dir", gitDirectoryPath.path, worktreePath.path])
        try await runGit(at: worktreePath, args: ["config", "user.email", "scanner-tests@example.com"])
        try await runGit(at: worktreePath, args: ["config", "user.name", "Scanner Tests"])
        try await runGit(at: worktreePath, args: ["config", "commit.gpgsign", "false"])
        try "main\n".write(to: worktreePath.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try await runGit(at: worktreePath, args: ["add", "README.md"])
        try await runGit(at: worktreePath, args: ["commit", "-m", "Seed separate git dir"])
        try await runGit(
            at: worktreePath, args: ["worktree", "add", "-b", "feature/separate", linkedWorktreePath.path])

        let groups = await RepoScanner().scanForGitReposGrouped(in: tmp, maxDepth: 2)

        #expect(groups.count == 1)
        #expect(groups.first?.clonePath.standardizedFileURL.path == worktreePath.standardizedFileURL.path)
        #expect(groups.first?.linkedWorktreePaths.map(canonicalPath(_:)) == [canonicalPath(linkedWorktreePath)])
    }

    private func initializeGitRepository(at path: URL) async throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try await runGit(at: path, args: ["init"])
        try await runGit(at: path, args: ["config", "user.email", "scanner-tests@example.com"])
        try await runGit(at: path, args: ["config", "user.name", "Scanner Tests"])
        try await runGit(at: path, args: ["config", "commit.gpgsign", "false"])
    }

    private func runGit(at path: URL, args: [String]) async throws {
        let result = try await runFixtureGitToExit(arguments: ["-C", path.path] + args)
        guard result.exitCode == 0 else {
            Issue.record("git command failed: \(args.joined(separator: " ")) stderr=\(result.standardError)")
            throw NSError(domain: "RepoScannerTests", code: Int(result.exitCode))
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

@Suite("RepoScanner classification")
struct RepoScannerClassificationTests {
    @Test(".git directory is classified as a clone root")
    func gitDirectoryIsCloneRoot() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-classification-\(UUID().uuidString)")
        let repoPath = tmp.appending(path: "agent-studio")
        try FileManager.default.createDirectory(
            at: repoPath.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(RepoScanner.classifyGitEntry(at: repoPath) == .cloneRoot)
    }

    @Test(".git file is classified as a linked worktree and preserves the parent clone path")
    func gitFileIsLinkedWorktree() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-linked-\(UUID().uuidString)")
        let clonePath = tmp.appending(path: "agent-studio")
        let worktreePath = tmp.appending(path: "agent-studio.feature-a")
        try FileManager.default.createDirectory(
            at: clonePath.appending(path: ".git/worktrees/feature-a"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        try "gitdir: \(clonePath.path)/.git/worktrees/feature-a\n".write(
            to: worktreePath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard
            case .linkedWorktree(parentClonePath: let parentClonePath) =
                RepoScanner.classifyGitEntry(at: worktreePath)
        else {
            Issue.record("expected linkedWorktree classification")
            return
        }

        #expect(parentClonePath.standardizedFileURL == clonePath.standardizedFileURL)
    }

    @Test("path without a git marker is not classified")
    func pathWithoutGitMarkerIsNotClassified() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-empty-classification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(RepoScanner.classifyGitEntry(at: tmp) == nil)
    }

    @Test("parseParentClonePath trims the worktree suffix from an absolute gitdir")
    func parseParentClonePathFromAbsoluteGitdir() {
        let parentClonePath = RepoScanner.parseParentClonePath(
            fromGitFileContent: "gitdir: /tmp/agent-studio/.git/worktrees/feature-a\n"
        )

        #expect(parentClonePath?.standardizedFileURL == URL(fileURLWithPath: "/tmp/agent-studio"))
    }

    @Test("relative gitdir is resolved against the worktree path")
    func gitFileRelativePathIsLinkedWorktree() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-relative-\(UUID().uuidString)")
        let clonePath = tmp.appending(path: "agent-studio")
        let linkedRoot = tmp.appending(path: "linked")
        let worktreePath = linkedRoot.appending(path: "feature-a")

        try FileManager.default.createDirectory(
            at: clonePath.appending(path: ".git/worktrees/feature-a"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        try "gitdir: ../../agent-studio/.git/worktrees/feature-a\n".write(
            to: worktreePath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard
            case .linkedWorktree(parentClonePath: let parentClonePath) =
                RepoScanner.classifyGitEntry(at: worktreePath)
        else {
            Issue.record("expected linkedWorktree classification for relative gitdir")
            return
        }

        #expect(parentClonePath.standardizedFileURL == clonePath.standardizedFileURL)
    }

    @Test("unreadable git file falls back to clone root boundary")
    func unreadableGitFileFallsBackToCloneRootBoundary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-unreadable-\(UUID().uuidString)")
        let worktreePath = tmp.appending(path: "agent-studio.feature-a")
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

        let gitFilePath = worktreePath.appending(path: ".git")
        try "gitdir: /tmp/agent-studio/.git/worktrees/feature-a\n".write(
            to: gitFilePath,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: gitFilePath.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: gitFilePath.path
            )
            try? FileManager.default.removeItem(at: tmp)
        }

        #expect(RepoScanner.classifyGitEntry(at: worktreePath) == .cloneRoot)
    }

    @Test("malformed git file content falls back to clone root boundary")
    func malformedGitFileFallsBackToCloneRootBoundary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "scanner-malformed-\(UUID().uuidString)")
        let worktreePath = tmp.appending(path: "agent-studio.feature-a")
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        try "not-a-gitdir-file\n".write(
            to: worktreePath.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(RepoScanner.classifyGitEntry(at: worktreePath) == .cloneRoot)
    }

    @Test("parseParentClonePath returns nil when worktrees segment is missing")
    func parseParentClonePathWithoutWorktreesSegmentReturnsNil() {
        let result = RepoScanner.parseParentClonePath(
            fromGitFileContent: "gitdir: /tmp/agent-studio/.git/modules/submodule\n"
        )

        #expect(result == nil)
    }

    @Test("parseParentClonePath uses the closest worktrees segment in nested metadata-like paths")
    func parseParentClonePathUsesClosestWorktreesSegment() {
        let result = RepoScanner.parseParentClonePath(
            fromGitFileContent:
                "gitdir: /tmp/projects/.git/worktrees/my-repo/.git/worktrees/feature-a\n"
        )

        #expect(
            result?.standardizedFileURL
                == URL(fileURLWithPath: "/tmp/projects/.git/worktrees/my-repo").standardizedFileURL
        )
    }

    @Test("parseParentClonePath relative content without base path returns nil")
    func parseParentClonePathRelativeWithoutBasePathReturnsNil() {
        let result = RepoScanner.parseParentClonePath(
            fromGitFileContent: "gitdir: ../../agent-studio/.git/worktrees/feature-a\n"
        )

        #expect(result == nil)
    }

    @Test("groupClassifiedPaths groups linked worktrees under their clone root")
    func groupClassifiedPathsByCloneRoot() {
        let clonePath = URL(fileURLWithPath: "/tmp/agent-studio")
        let linkedWorktreePath = URL(fileURLWithPath: "/tmp/agent-studio.feature-a")
        let standaloneClonePath = URL(fileURLWithPath: "/tmp/other-repo")

        let groups = RepoScanner.groupClassifiedPaths([
            (clonePath, .cloneRoot),
            (linkedWorktreePath, .linkedWorktree(parentClonePath: clonePath)),
            (standaloneClonePath, .cloneRoot),
        ])

        #expect(groups.count == 2)
        let mainGroup = groups.first { $0.clonePath.standardizedFileURL == clonePath.standardizedFileURL }
        #expect(mainGroup?.linkedWorktreePaths == [linkedWorktreePath])
        let standaloneGroup = groups.first {
            $0.clonePath.standardizedFileURL == standaloneClonePath.standardizedFileURL
        }
        #expect(standaloneGroup?.linkedWorktreePaths.isEmpty == true)
    }

    @Test("groupClassifiedPaths keeps orphaned linked worktrees under their parsed parent clone path")
    func groupClassifiedPathsForOrphanedLinkedWorktree() {
        let orphanedParentClonePath = URL(fileURLWithPath: "/tmp/missing-parent")
        let linkedWorktreePath = URL(fileURLWithPath: "/tmp/agent-studio.feature-a")

        let groups = RepoScanner.groupClassifiedPaths([
            (linkedWorktreePath, .linkedWorktree(parentClonePath: orphanedParentClonePath))
        ])

        #expect(groups.count == 1)
        #expect(groups[0].clonePath.standardizedFileURL == orphanedParentClonePath.standardizedFileURL)
        #expect(groups[0].linkedWorktreePaths == [linkedWorktreePath])
    }
}

/// Runs a fixture `git` command to exit with no per-test time limit; the lane's hang
/// bound is the only elapsed-time bound on the child. Both streams go to files so a
/// large output cannot fill a pipe, and `AgentStudioTestHarness` owns cancellable
/// launch and exit observation shared with other test targets.
private func runFixtureGitToExit(arguments: [String]) async throws -> FixtureGitResult {
    let captureDirectory = try FileManager.default.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: FileManager.default.temporaryDirectory,
        create: true
    )
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    let standardErrorURL = captureDirectory.appending(path: "stderr")
    let standardOutputURL = captureDirectory.appending(path: "stdout")
    FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
    FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
    let standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
    let standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
    defer {
        try? standardErrorHandle.close()
        try? standardOutputHandle.close()
    }

    let process = Process()
    process.executableURL = try await TestToolResolver.resolved().git
    process.arguments = arguments
    process.standardOutput = standardOutputHandle
    process.standardError = standardErrorHandle
    let exitCode = try await awaitProcessExit(process)
    return FixtureGitResult(
        exitCode: exitCode,
        standardError: String(data: try Data(contentsOf: standardErrorURL), encoding: .utf8) ?? ""
    )
}

private struct FixtureGitResult {
    let exitCode: Int32
    let standardError: String
}
