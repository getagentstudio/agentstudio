import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree prune policy with real Git")
struct WorktreePrunePolicyIntegrationTests {
    @Test("preview and apply preserve every blocked linked worktree and remove only the integrated candidate")
    func preservesSkippedWorktreesAndRemovesTheIntegratedCandidate() async throws {
        let scenario = try await WorktreePrunePolicyScenario.create()
        defer { scenario.destroy() }
        let previewOutcome = await scenario.runner.run(
            pruneRequest(
                repository: scenario.repositoryPath,
                callerDirectory: scenario.currentDirtyLockedPath,
                apply: false
            )
        )
        guard case .pruned(let preview) = previewOutcome else {
            Issue.record("expected prune preview summary, got \(previewOutcome)")
            return
        }

        #expect(!preview.applied)
        #expect(preview.fetch == .skipped(reason: .noFetchFlag))
        #expect(preview.target?.ref == "refs/heads/main")
        #expect(preview.entries.count == scenario.linkedWorktreeCount)
        let stateAfterPreview = try await removalRepositorySnapshot(scenario.repository.path)
        #expect(stateAfterPreview.worktrees == scenario.stateBeforePreview.worktrees)
        #expect(stateAfterPreview.branches == scenario.stateBeforePreview.branches)
        #expect(FileManager.default.fileExists(atPath: scenario.integratedPath.path))

        let previewSkips = skipDocuments(in: preview.entries)
        scenario.expectStops(previewSkips)
        scenario.expectOptions(previewSkips)
        #expect(try Data(contentsOf: scenario.lockPath) == scenario.foreignLockBytes)

        let applyOutcome = await scenario.runner.run(
            pruneRequest(
                repository: scenario.repositoryPath,
                callerDirectory: scenario.currentDirtyLockedPath,
                apply: true
            )
        )
        guard case .pruned(let applied) = applyOutcome else {
            Issue.record("expected prune apply summary, got \(applyOutcome)")
            return
        }

        #expect(applied.applied)
        #expect(applied.fetch == .skipped(reason: .noFetchFlag))
        #expect(!FileManager.default.fileExists(atPath: scenario.integratedPath.path))
        #expect(
            try await removalGit(
                scenario.repository.path,
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads/feature/prune-integrated"
            ).isEmpty)
        #expect(
            try await removalGit(
                scenario.repository.path,
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads/feature/prune-unlinked"
            )
                == "refs/heads/feature/prune-unlinked")
        for path in scenario.preservedPaths {
            #expect(FileManager.default.fileExists(atPath: path.path))
        }
        #expect(try Data(contentsOf: scenario.lockPath) == scenario.foreignLockBytes)
    }
}

private struct WorktreePrunePolicyScenario {
    private struct Paths {
        let integrated: URL
        let currentDirtyLocked: URL
        let locked: URL
        let dirty: URL
        let tmpEvidence: URL
        let unknownChanges: URL
        let unknownEvidence: URL
        let unintegrated: URL
        let unknownGrade: URL
        let lockFile: URL
        let defaultBranch: URL
    }

    let repository: WorktreeRemovalRepository
    let integratedPath: URL
    let currentDirtyLockedPath: URL
    let lockedPath: URL
    let dirtyPath: URL
    let tmpEvidencePath: URL
    let unknownChangesPath: URL
    let unknownEvidencePath: URL
    let unintegratedPath: URL
    let unknownGradePath: URL
    let lockFilePath: URL
    let defaultBranchPath: URL
    let detachedPath: URL
    let unknownEvidenceDirectory: URL
    let repositoryPath: URL
    let runner: WorktreePruneRunner
    let stateBeforePreview: (worktrees: String, branches: String)
    let linkedWorktreeCount: Int
    let lockPath: URL
    let foreignLockBytes: Data

    var preservedPaths: [URL] {
        [
            currentDirtyLockedPath, lockedPath, dirtyPath, tmpEvidencePath, unknownChangesPath,
            unknownEvidencePath, unintegratedPath, unknownGradePath, lockFilePath, defaultBranchPath, detachedPath,
        ]
    }

    static func create() async throws -> Self {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-prune-policy")
        var cleanupUnknownEvidenceDirectory: URL?
        let detachedPath = fixture.path.deletingLastPathComponent()
            .appending(path: "worktree-prune-detached", directoryHint: .isDirectory)
        var setupComplete = false
        defer {
            if !setupComplete {
                if let cleanupUnknownEvidenceDirectory {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: cleanupUnknownEvidenceDirectory.path
                    )
                }
                try? FileManager.default.removeItem(at: detachedPath)
                fixture.destroy()
            }
        }

        let paths = try await createWorktrees(in: &fixture)
        let unknownEvidenceDirectory = paths.unknownEvidence.appending(path: "tmp", directoryHint: .isDirectory)
        cleanupUnknownEvidenceDirectory = unknownEvidenceDirectory
        try await configureRepositoryState(
            repositoryPath: fixture.path,
            paths: paths,
            detachedPath: detachedPath,
            unknownEvidenceDirectory: unknownEvidenceDirectory
        )

        let snapshots = try await fixture.client.worktrees(for: fixture.path)
        let lockSnapshot = try #require(
            snapshots.first {
                WorktreeListingProjector.branchName(in: $0.head) == "feature/prune-git-lock"
            }
        )
        let lockPath = URL(fileURLWithPath: lockSnapshot.indexPath.path + ".lock")
        let foreignLockBytes = Data("foreign lock\n".utf8)
        try foreignLockBytes.write(to: lockPath)
        let mainSnapshot = try #require(snapshots.first(where: { $0.isMainWorktree }))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let repositoryPath =
            identity.mainWorktreePath?.standardizedFileURL ?? mainSnapshot.canonicalPath.standardizedFileURL
        let client = WorktreeOperationClientStub(
            startPath: repositoryPath,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            integrationGrades: ["feature/prune-unknown-grade": .unknown(.readFailed)],
            statusFailurePaths: [paths.unknownChanges.standardizedFileURL.path]
        )
        let runner = WorktreePruneRunner(client: client)
        let stateBeforePreview = try await removalRepositorySnapshot(fixture.path)
        let linkedWorktreeCount = snapshots.filter { !$0.isMainWorktree }.count
        setupComplete = true
        return Self(
            repository: fixture,
            integratedPath: paths.integrated,
            currentDirtyLockedPath: paths.currentDirtyLocked,
            lockedPath: paths.locked,
            dirtyPath: paths.dirty,
            tmpEvidencePath: paths.tmpEvidence,
            unknownChangesPath: paths.unknownChanges,
            unknownEvidencePath: paths.unknownEvidence,
            unintegratedPath: paths.unintegrated,
            unknownGradePath: paths.unknownGrade,
            lockFilePath: paths.lockFile,
            defaultBranchPath: paths.defaultBranch,
            detachedPath: detachedPath,
            unknownEvidenceDirectory: unknownEvidenceDirectory,
            repositoryPath: repositoryPath,
            runner: runner,
            stateBeforePreview: stateBeforePreview,
            linkedWorktreeCount: linkedWorktreeCount,
            lockPath: lockPath,
            foreignLockBytes: foreignLockBytes
        )
    }

    func destroy() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: unknownEvidenceDirectory.path
        )
        try? FileManager.default.removeItem(at: detachedPath)
        repository.destroy()
    }

    private static func createWorktrees(in fixture: inout WorktreeRemovalRepository) async throws -> Paths {
        let integrated = try await fixture.addWorktree(branch: "feature/prune-integrated")
        let currentDirtyLocked = try await fixture.addWorktree(branch: "feature/prune-current-dirty-locked")
        let locked = try await fixture.addWorktree(branch: "feature/prune-locked")
        let dirty = try await fixture.addWorktree(branch: "feature/prune-dirty")
        let tmpEvidence = try await fixture.addWorktree(branch: "feature/prune-tmp")
        let unknownChanges = try await fixture.addWorktree(branch: "feature/prune-unknown-changes")
        let unknownEvidence = try await fixture.addWorktree(branch: "feature/prune-unknown-evidence")
        let unintegrated = try await fixture.addWorktree(branch: "feature/prune-unintegrated")
        let unknownGrade = try await fixture.addWorktree(branch: "feature/prune-unknown-grade")
        let lockFile = try await fixture.addWorktree(branch: "feature/prune-git-lock")
        let defaultBranch = try await fixture.addExistingBranchWorktree(
            branch: "main",
            directoryName: "worktree-prune-default-branch"
        )
        return Paths(
            integrated: integrated,
            currentDirtyLocked: currentDirtyLocked,
            locked: locked,
            dirty: dirty,
            tmpEvidence: tmpEvidence,
            unknownChanges: unknownChanges,
            unknownEvidence: unknownEvidence,
            unintegrated: unintegrated,
            unknownGrade: unknownGrade,
            lockFile: lockFile,
            defaultBranch: defaultBranch
        )
    }

    private static func configureRepositoryState(
        repositoryPath: URL,
        paths: Paths,
        detachedPath: URL,
        unknownEvidenceDirectory: URL
    ) async throws {
        try await removalGit(repositoryPath, "worktree", "add", "--detach", detachedPath.path, "refs/heads/main")
        try "dirty change\n".write(
            to: paths.dirty.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "overlap change\n".write(
            to: paths.currentDirtyLocked.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await removalGit(repositoryPath, "worktree", "lock", "--reason", "prune fixture", paths.locked.path)
        try await removalGit(
            repositoryPath,
            "worktree",
            "lock",
            "--reason",
            "prune fixture",
            paths.currentDirtyLocked.path
        )
        _ = try addEvidence("keep this evidence\n", to: paths.tmpEvidence)
        _ = try addEvidence("unreadable evidence\n", to: paths.unknownEvidence)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unknownEvidenceDirectory.path)
        try "unintegrated\n".write(
            to: paths.unintegrated.appending(path: "unintegrated.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await removalGit(paths.unintegrated, "add", "unintegrated.txt")
        try await removalGit(paths.unintegrated, "commit", "-m", "Remaining contribution")
        try await removalGit(repositoryPath, "branch", "feature/prune-unlinked")
    }

    func expectStops(_ skips: [String: WorktreePruneSkip]) {
        #expect(isSkip(skips[currentDirtyLockedPath.path], stop: .targetIsCurrent))
        #expect(isSkip(skips[lockedPath.path], stop: .worktreeLocked))
        #expect(isSkip(skips[dirtyPath.path], stop: .dirty))
        #expect(isSkip(skips[unknownChangesPath.path], stop: .changesUnknown))
        #expect(isSkip(skips[tmpEvidencePath.path], stop: .evidenceInTmp))
        #expect(isSkip(skips[unknownEvidencePath.path], stop: .evidenceUnknown))
        #expect(isSkip(skips[lockFilePath.path], stop: .gitLockHeld))
        #expect(skips[unintegratedPath.path]?.reason == .notIntegrated)
        #expect(skips[unknownGradePath.path]?.reason == .assessmentUnknown(.readFailed))
        #expect(skips[detachedPath.path]?.reason == .detached)
        #expect(skips[defaultBranchPath.path]?.reason == .defaultBranch)
    }

    func expectOptions(_ skips: [String: WorktreePruneSkip]) {
        let repoArgument = repository.path.standardizedFileURL.path
        #expect(
            skips[dirtyPath.path]?.options == [
                "agentstudio worktree remove --repo \(repoArgument) \(dirtyPath.path) -f"
            ])
        #expect(
            skips[unintegratedPath.path]?.options == [
                "agentstudio worktree remove --repo \(repoArgument) \(unintegratedPath.path) -D"
            ])
        #expect(
            skips[unknownGradePath.path]?.options == [
                "agentstudio worktree remove --repo \(repoArgument) \(unknownGradePath.path) -D"
            ])
        #expect(skips[defaultBranchPath.path]?.options.isEmpty == true)
    }
}

@Suite("Worktree prune fetching read failures")
struct WorktreePruneFetchingReadFailureIntegrationTests {
    @Test("an unreadable E4 target returns one unknown skip per linked worktree")
    func keepsEveryWorktreeRowWhenDefaultTargetCannotBeRead() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-prune-unreadable-target")
        defer { fixture.destroy() }
        _ = try await fixture.addWorktree(branch: "feature/prune-target-read-first")
        _ = try await fixture.addWorktree(branch: "feature/prune-target-read-second")
        let snapshots = try await fixture.client.worktrees(for: fixture.path)
        let mainSnapshot = try #require(snapshots.first(where: { $0.isMainWorktree }))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            failsDefaultTargetResolution: true
        )
        let runner = WorktreePruneRunner(client: client)

        let outcome = await runner.run(
            pruneRequest(repository: fixture.path, callerDirectory: fixture.path, apply: false)
        )

        guard case .pruned(let summary) = outcome else {
            Issue.record("expected one prune entry per linked worktree, got \(outcome)")
            return
        }
        #expect(summary.entries.count == 2)
        #expect(summary.fetch == .skipped(reason: .noTarget))
        for entry in summary.entries {
            guard case .skipped(let skipped) = entry else {
                Issue.record("expected unreadable E4 to skip pruning, got \(entry)")
                continue
            }
            #expect(skipped.skip.reason == .assessmentUnknown(.readFailed))
        }
        #expect(try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true).exitCode == 0)
    }

    @Test("a worktree-list read failure after a real fetch retains its fetched status")
    func retainsFetchedStatusWhenWorktreeListCannotBeRead() async throws {
        let fixture = try await WorktreeRemovalRepository.create(named: "worktree-prune-after-fetch-read")
        let bareRemote = fixture.path.deletingLastPathComponent()
            .appending(path: "\(fixture.path.lastPathComponent).origin.git", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: bareRemote)
            fixture.destroy()
        }

        try await removalGit(fixture.path, "init", "--bare", bareRemote.path)
        try await removalGit(fixture.path, "remote", "add", "origin", bareRemote.path)
        try await removalGit(fixture.path, "push", "--set-upstream", "origin", "main")
        try await removalGit(fixture.path, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main")
        #expect(
            !FileManager.default.fileExists(atPath: fixture.path.appending(path: ".git/refs/remotes/origin/HEAD").path))

        let snapshots = try await fixture.client.worktrees(for: fixture.path)
        let mainSnapshot = try #require(snapshots.first(where: { $0.isMainWorktree }))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            failsWorktreeListing: true
        )
        let runner = WorktreePruneRunner(
            client: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )
        let expectedCommit = try await removalGit(fixture.path, "rev-parse", "refs/remotes/origin/main")

        let outcome = await runner.run(
            pruneRequest(
                repository: fixture.path,
                callerDirectory: fixture.path,
                apply: false,
                fetchPolicy: .defaultBranch
            )
        )

        #expect(
            outcome
                == .fetchingReadFailure(
                    WorktreeFetchingReadFailure(fetch: .fetched(commit: expectedCommit))
                )
        )
    }
}

private func pruneRequest(
    repository: URL,
    callerDirectory: URL,
    apply: Bool,
    fetchPolicy: WorktreeFetchPolicy = .skip
) -> WorktreePruneRequest {
    WorktreePruneRequest(
        start: repository,
        callerDirectory: callerDirectory,
        apply: apply,
        evidencePolicy: .requireEmpty,
        fetchPolicy: fetchPolicy
    )
}

private func skipDocuments(in entries: [WorktreePruneEntry]) -> [String: WorktreePruneSkip] {
    Dictionary(
        uniqueKeysWithValues: entries.compactMap { entry in
            guard case .skipped(let skipped) = entry else { return nil }
            return (skipped.target, skipped.skip)
        }
    )
}

private func isSkip(_ skip: WorktreePruneSkip?, stop expectedStop: WorktreeStopReason) -> Bool {
    guard let skip, case .stop(let actualStop) = skip.reason else { return false }
    return actualStop == expectedStop
}
