import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree listing with real Git")
struct WorktreeListingIntegrationTests {
    @Test("mixed real worktrees retain independent status and stop facts")
    func listsMixedWorktreeState() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-mixed")
        let client = LibGit2AgentStudioGitLocalClient()
        var temporaryWorktreePaths: [URL] = []
        defer {
            for worktreePath in temporaryWorktreePaths {
                try? FileManager.default.removeItem(at: worktreePath)
            }
            FilesystemTestGitRepo.destroy(repository)
        }

        try await seedMainBranch(in: repository)
        let cleanPath = path(for: "feature/clean", beside: repository)
        let dirtyPath = path(for: "feature/dirty", beside: repository)
        let lockedPath = path(for: "feature/locked", beside: repository)
        let remainingPath = path(for: "feature/remaining", beside: repository)
        let detachedPath = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).detached", directoryHint: .isDirectory)
        temporaryWorktreePaths = [cleanPath, dirtyPath, lockedPath, remainingPath, detachedPath]

        _ = try await createBranchWorktree("feature/clean", at: cleanPath, repository: repository, client: client)
        _ = try await createBranchWorktree("feature/dirty", at: dirtyPath, repository: repository, client: client)
        let locked = try await createBranchWorktree(
            "feature/locked",
            at: lockedPath,
            repository: repository,
            client: client
        )
        _ = try await createBranchWorktree(
            "feature/remaining",
            at: remainingPath,
            repository: repository,
            client: client
        )
        _ = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: repository,
                destinationPath: detachedPath,
                mode: .detached(startPoint: .named("refs/heads/main"))
            ))

        try "changed\n".write(to: dirtyPath.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try "untracked\n".write(to: dirtyPath.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
        let evidencePath = dirtyPath.appending(path: "tmp/evidence.txt")
        try FileManager.default.createDirectory(
            at: evidencePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "keep me\n".write(to: evidencePath, atomically: true, encoding: .utf8)

        try "remaining contribution\n".write(
            to: remainingPath.appending(path: "remaining.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: remainingPath, "add", "remaining.txt")
        try await git(at: remainingPath, "commit", "-m", "Remaining contribution")
        _ = try await client.lockWorktree(GitLockWorktreeRequest(worktreeID: locked.id, reason: "operator hold"))

        let runner = WorktreeOperationRunner(client: client)
        let outcome = await runner.run(
            .list(start: repository, callerDirectory: repository, targets: [], fetchPolicy: .skip)
        )

        guard case .listed(let listing) = outcome else {
            Issue.record("expected a listed outcome, got \(outcome)")
            return
        }

        #expect(listing.target?.ref == "refs/heads/main")
        #expect(listing.fetch == .skipped(reason: .noFetchFlag))
        #expect(listing.worktrees.count == 6)

        try WorktreeListingIntegrationAssertions.expectMixedRows(
            listing,
            repository: repository,
            cleanPath: cleanPath
        )
        try WorktreeListingIntegrationAssertions.expectMixedOutput(outcome)
        try await WorktreeListingIntegrationAssertions.expectTargetAndCurrentDirectoryFiltering(
            runner: runner,
            repository: repository,
            cleanPath: cleanPath
        )
    }

    @Test("an unreadable worktree status fails closed without hiding its row")
    func statusReadFailureBecomesUnknownRow() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-unknown-status")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await seedMainBranch(in: repository)

        let realClient = LibGit2AgentStudioGitLocalClient()
        let mainSnapshot = try #require(
            await realClient.worktrees(for: repository).first(where: \.isMainWorktree)
        )
        let identity = try await realClient.repositoryIdentity(for: repository)
        let syntheticPath = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).unreadable", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: syntheticPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: syntheticPath) }
        let syntheticSnapshot = GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "worktree-list-unreadable"),
            repositoryID: mainSnapshot.repositoryID,
            displayName: "unreadable",
            path: syntheticPath,
            canonicalPath: syntheticPath,
            gitDirectory: mainSnapshot.gitDirectory,
            indexPath: mainSnapshot.indexPath,
            isMainWorktree: false,
            isLocked: false,
            lockReason: nil,
            head: GitHeadSnapshot(kind: .branch, oid: mainSnapshot.head?.oid, shortName: "feature/unreadable")
        )
        let reader = WorktreeOperationClientStub(
            startPath: repository,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            listedWorktrees: [syntheticSnapshot],
            branchSnapshots: [],
            statusFailurePaths: [syntheticPath.standardizedFileURL.path]
        )

        let outcome = await WorktreeOperationRunner(client: reader).run(
            .list(start: repository, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )

        guard case .listed(let listing) = outcome, let row = listing.worktrees.first else {
            Issue.record("expected the unreadable worktree row, got \(outcome)")
            return
        }
        #expect(row.branch == "feature/unreadable")
        #expect(row.changes.status == .unknown)
        #expect(row.integration == .unknown(.noTarget))
        #expect(row.tmp == .empty)
        #expect(row.blockers.map(\.reason) == [.changesUnknown])
        #expect(!row.removable)
        #expect(row.remove == nil)
    }

    @Test("an unreadable E4 target keeps every worktree row with a readFailed assessment")
    func defaultTargetReadFailureKeepsEveryWorktreeRow() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-list-unreadable-target")
        defer { fixture.destroy() }
        let firstWorktreePath = try await fixture.addWorktree(branch: "feature/target-read-first")
        let secondWorktreePath = try await fixture.addWorktree(branch: "feature/target-read-second")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree)
        )
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            failsDefaultTargetResolution: true
        )

        let outcome = await WorktreeOperationRunner(client: client).run(
            .list(start: fixture.path, callerDirectory: nil, targets: [], fetchPolicy: .defaultBranch)
        )

        guard case .listed(let listing) = outcome else {
            Issue.record("expected all worktree rows despite an unreadable E4 target, got \(outcome)")
            return
        }
        #expect(listing.worktrees.count == 3)
        #expect(
            Set(listing.worktrees.map { $0.path.standardizedFileURL.path })
                == Set([fixture.path.path, firstWorktreePath.path, secondWorktreePath.path])
        )
        #expect(listing.target == nil)
        #expect(listing.fetch == .skipped(reason: .noTarget))
        #expect(listing.worktrees.allSatisfy { $0.integration == .unknown(.readFailed) })
        #expect(try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true).exitCode == 0)
    }

    @Test("an unreadable tmp directory becomes an evidenceUnknown blocker")
    func unreadableTmpDirectoryFailsClosed() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-unknown-tmp")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try "tmp/\n".write(to: repository.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try await git(at: repository, "add", ".gitignore")
        try await seedMainBranch(in: repository)

        let temporaryRoot = repository.appending(path: "tmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try "evidence\n".write(to: temporaryRoot.appending(path: "evidence.txt"), atomically: true, encoding: .utf8)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: temporaryRoot.path)
        let originalPermissions = originalAttributes[.posixPermissions] ?? 0o755
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: temporaryRoot.path
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: temporaryRoot.path)

        let outcome = await WorktreeOperationRunner().run(
            .list(start: repository, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )

        guard case .listed(let listing) = outcome,
            let row = listing.worktrees.first(where: { $0.branch == "main" })
        else {
            Issue.record("expected the main worktree row, got \(outcome)")
            return
        }
        #expect(row.changes.status == .clean)
        #expect(row.tmp == .unknown)
        #expect(row.blockers.map(\.reason) == [.mainWorktree, .evidenceUnknown])
        #expect(row.blockers[1].details == .evidenceUnknown(path: temporaryRoot.standardizedFileURL.path))
        #expect(!row.removable)
        #expect(row.remove == nil)
    }

    @Test("tmp evidence scans report symlinks without traversing their targets")
    func tmpEvidenceScannerDoesNotFollowSymlinks() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-tmp-symlink")
        let temporaryRoot = repository.appending(path: "tmp", directoryHint: .isDirectory)
        let externalDirectory = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).external", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            try? FileManager.default.removeItem(at: externalDirectory)
            FilesystemTestGitRepo.destroy(repository)
        }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try "outside evidence\n".write(
            to: externalDirectory.appending(path: "evidence.txt"),
            atomically: true,
            encoding: .utf8
        )
        let escapeLink = temporaryRoot.appending(path: "escape", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: externalDirectory)

        let scanner = WorktreeTmpEvidenceScanner()
        let nestedLinkResult = await scanner.scan(worktreePath: repository)
        guard case .nonEmpty(let fileCount, _, let firstPaths) = nestedLinkResult else {
            Issue.record("expected the tmp symlink to count as evidence without traversal, got \(nestedLinkResult)")
            return
        }
        #expect(fileCount == 1)
        #expect(firstPaths == ["tmp/escape"])

        try FileManager.default.removeItem(at: temporaryRoot)
        try FileManager.default.createSymbolicLink(at: temporaryRoot, withDestinationURL: externalDirectory)
        #expect(await scanner.scan(worktreePath: repository) == .unknown(path: temporaryRoot))
    }

    @Test("shallow history stays unknown for graph based integration")
    func shallowHistoryAssessmentRemainsUnknown() async throws {
        let sourceRepository = try await FilesystemTestGitRepo.create(named: "worktree-list-shallow-source")
        let bareRemote = sourceRepository.deletingLastPathComponent()
            .appending(path: "\(sourceRepository.lastPathComponent).origin.git")
        let shallowRepository = sourceRepository.deletingLastPathComponent()
            .appending(path: "\(sourceRepository.lastPathComponent).shallow-\(UUIDv7.generate())")
        let linkedWorktree = path(for: "feature/shallow", beside: shallowRepository)
        defer {
            try? FileManager.default.removeItem(at: linkedWorktree)
            FilesystemTestGitRepo.destroy(shallowRepository)
            FilesystemTestGitRepo.destroy(bareRemote)
            FilesystemTestGitRepo.destroy(sourceRepository)
        }

        try await seedMainBranch(in: sourceRepository)
        try "history\n".write(
            to: sourceRepository.appending(path: "history.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: sourceRepository, "add", "history.txt")
        try await git(at: sourceRepository, "commit", "-m", "Add history")
        try await FilesystemTestGitRepo.runGit(at: sourceRepository, args: ["init", "--bare", bareRemote.path])
        try await git(at: sourceRepository, "remote", "add", "origin", bareRemote.path)
        try await git(at: sourceRepository, "push", "--set-upstream", "origin", "main")
        try await FilesystemTestGitRepo.runGit(
            at: sourceRepository,
            args: ["--git-dir", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"]
        )
        try await FilesystemTestGitRepo.runGit(
            at: sourceRepository.deletingLastPathComponent(),
            args: ["clone", "--depth", "1", "--branch", "main", "file://\(bareRemote.path)", shallowRepository.path]
        )
        try await git(at: shallowRepository, "config", "user.email", "listing-tests@example.invalid")
        try await git(at: shallowRepository, "config", "user.name", "Listing Tests")
        try await git(at: shallowRepository, "config", "commit.gpgsign", "false")
        try await git(at: shallowRepository, "config", "tag.gpgsign", "false")

        #expect(try await git(at: shallowRepository, "rev-parse", "--is-shallow-repository") == "true")
        let client = LibGit2AgentStudioGitLocalClient()
        _ = try await createBranchWorktree(
            "feature/shallow",
            at: linkedWorktree,
            repository: shallowRepository,
            client: client
        )
        try "after shallow boundary\n".write(
            to: linkedWorktree.appending(path: "after-boundary.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: linkedWorktree, "add", "after-boundary.txt")
        try await git(at: linkedWorktree, "commit", "-m", "Add after boundary")

        let outcome = await WorktreeOperationRunner(client: client).run(
            .list(start: shallowRepository, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )

        guard case .listed(let listing) = outcome,
            let feature = listing.worktrees.first(where: { $0.branch == "feature/shallow" })
        else {
            Issue.record("expected the shallow feature row, got \(outcome)")
            return
        }
        #expect(feature.integration == .unknown(.incompleteHistory))
        #expect(feature.changes.status == .clean)
        #expect(feature.removable)
    }

    @Test("a missing branch object stays unknown without hiding an integrated row")
    func missingBranchObjectDoesNotHideOtherRows() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-missing-object")
        let client = LibGit2AgentStudioGitLocalClient()
        var paths: [URL] = []
        defer {
            for path in paths {
                try? FileManager.default.removeItem(at: path)
            }
            FilesystemTestGitRepo.destroy(repository)
        }
        try await seedMainBranch(in: repository)

        let missingPath = path(for: "feature/missing", beside: repository)
        let integratedPath = path(for: "feature/integrated", beside: repository)
        paths = [missingPath, integratedPath]
        _ = try await createBranchWorktree(
            "feature/missing",
            at: missingPath,
            repository: repository,
            client: client
        )
        _ = try await createBranchWorktree(
            "feature/integrated",
            at: integratedPath,
            repository: repository,
            client: client
        )
        try "missing tip\n".write(
            to: missingPath.appending(path: "missing-tip.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: missingPath, "add", "missing-tip.txt")
        try await git(at: missingPath, "commit", "-m", "Create a missing tip")
        let missingCommit = try await git(at: missingPath, "rev-parse", "HEAD")
        let looseCommitObject = repository.appending(
            path: ".git/objects/\(missingCommit.prefix(2))/\(missingCommit.dropFirst(2))")
        #expect(FileManager.default.fileExists(atPath: looseCommitObject.path))
        try FileManager.default.removeItem(at: looseCommitObject)
        #expect(!FileManager.default.fileExists(atPath: looseCommitObject.path))

        let outcome = await WorktreeOperationRunner(client: client).run(
            .list(start: repository, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )

        guard case .listed(let listing) = outcome else {
            Issue.record("expected both branch rows, got \(outcome)")
            return
        }
        let rowsByBranch = Dictionary(
            uniqueKeysWithValues: listing.worktrees.compactMap { row in
                row.branch.map { ($0, row) }
            })
        let missing = try #require(rowsByBranch["feature/missing"])
        let integrated = try #require(rowsByBranch["feature/integrated"])
        #expect(missing.integration == .unknown(.missingObjects))
        #expect(integrated.integration == .integrated(.sameCommit))
    }

    @Test("list fetches main's upstream when origin HEAD is absent")
    func fetchesAndAssessesUpstreamWithoutOriginHead() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-upstream-fetch")
        let bareRemote = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).origin.git")
        let remoteWriter = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).squash-writer", directoryHint: .isDirectory)
        let featurePath = path(for: "feature/squash", beside: repository)
        defer {
            try? FileManager.default.removeItem(at: featurePath)
            FilesystemTestGitRepo.destroy(remoteWriter)
            FilesystemTestGitRepo.destroy(repository)
            FilesystemTestGitRepo.destroy(bareRemote)
        }
        try await seedMainBranch(in: repository)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["init", "--bare", bareRemote.path])
        try await git(at: repository, "remote", "add", "origin", bareRemote.path)
        try await git(at: repository, "push", "--set-upstream", "origin", "main")
        try await git(at: repository, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main")
        try await FilesystemTestGitRepo.runGit(
            at: repository,
            args: ["--git-dir", bareRemote.path, "symbolic-ref", "HEAD", "refs/heads/main"]
        )
        try await FilesystemTestGitRepo.runGit(
            at: repository.deletingLastPathComponent(),
            args: ["clone", bareRemote.path, remoteWriter.path]
        )
        try await git(at: remoteWriter, "config", "user.email", "listing-tests@example.invalid")
        try await git(at: remoteWriter, "config", "user.name", "Listing Tests")
        try await git(at: remoteWriter, "config", "commit.gpgsign", "false")
        let oldTargetCommit = try await git(at: repository, "rev-parse", "refs/remotes/origin/main")
        let originHeadPath = repository.appending(path: ".git/refs/remotes/origin/HEAD")
        #expect(!FileManager.default.fileExists(atPath: originHeadPath.path))

        let client = LibGit2AgentStudioGitLocalClient()
        _ = try await createBranchWorktree(
            "feature/squash",
            at: featurePath,
            repository: repository,
            client: client
        )
        try "squash payload\n".write(
            to: featurePath.appending(path: "feature.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: featurePath, "add", "feature.txt")
        try await git(at: featurePath, "commit", "-m", "Feature change")

        try "squash payload\n".write(
            to: remoteWriter.appending(path: "feature.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: remoteWriter, "add", "feature.txt")
        try await git(at: remoteWriter, "commit", "-m", "Squash feature")
        let squashCommit = try await git(at: remoteWriter, "rev-parse", "HEAD")
        try "after squash\n".write(
            to: remoteWriter.appending(path: "after-squash.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: remoteWriter, "add", "after-squash.txt")
        try await git(at: remoteWriter, "commit", "-m", "Advance after squash")
        let fetchedCommit = try await git(at: remoteWriter, "rev-parse", "HEAD")
        try await git(at: remoteWriter, "push", "origin", "main")

        let runner = WorktreeOperationRunner(
            client: client,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )
        let withoutFetch = await runner.run(
            .list(start: repository, callerDirectory: nil, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let staleListing) = withoutFetch,
            let staleFeature = staleListing.worktrees.first(where: { $0.branch == "feature/squash" })
        else {
            Issue.record("expected a no-fetch listing, got \(withoutFetch)")
            return
        }
        #expect(staleListing.fetch == .skipped(reason: .noFetchFlag))
        #expect(staleListing.target?.commit == oldTargetCommit)
        #expect(staleFeature.integration == .hasRemainingContribution)

        let fetchedOutcome = await runner.run(
            .list(start: repository, callerDirectory: nil, targets: [], fetchPolicy: .defaultBranch)
        )
        guard case .listed(let fetchedListing) = fetchedOutcome,
            let fetchedFeature = fetchedListing.worktrees.first(where: { $0.branch == "feature/squash" })
        else {
            Issue.record("expected a fetched listing, got \(fetchedOutcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: originHeadPath.path) == false)
        #expect(fetchedListing.fetch == .fetched(commit: fetchedCommit))
        #expect(fetchedListing.target?.ref == "refs/remotes/origin/main")
        #expect(fetchedListing.target?.commit == fetchedCommit)
        #expect(fetchedFeature.integration == .integrated(.squash(commit: squashCommit)))
    }

    @Test("a failed worktree-list read retains the successful fetch status")
    func worktreeReadFailureCarriesFetchStatus() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-failed-read")
        let remote = repository.deletingLastPathComponent()
            .appending(path: "\(repository.lastPathComponent).origin.git")
        defer {
            FilesystemTestGitRepo.destroy(repository)
            FilesystemTestGitRepo.destroy(remote)
        }
        try await seedMainBranch(in: repository)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["init", "--bare", remote.path])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["remote", "add", "origin", remote.path])
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["push", "--set-upstream", "origin", "main"])
        try await FilesystemTestGitRepo.runGit(
            at: repository,
            args: ["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"]
        )
        try await FilesystemTestGitRepo.runGit(
            at: repository,
            args: ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]
        )
        try "advanced remote\n".write(
            to: repository.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await git(at: repository, "add", "tracked.txt")
        try await git(at: repository, "commit", "-m", "Advance remote")
        let fetchedCommit = try await git(at: repository, "rev-parse", "HEAD")
        try await git(at: repository, "push", "origin", "main")

        let realClient = LibGit2AgentStudioGitLocalClient()
        let mainSnapshot = try #require(await realClient.worktrees(for: repository).first(where: \.isMainWorktree))
        let identity = try await realClient.repositoryIdentity(for: repository)
        let reader = WorktreeOperationClientStub(
            startPath: repository,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            failsWorktreeListing: true
        )
        let runner = WorktreeOperationRunner(
            client: reader,
            remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
        )

        let outcome = await runner.run(
            .list(start: repository, callerDirectory: repository, targets: [], fetchPolicy: .defaultBranch)
        )

        guard case .fetchingReadFailure(let failure) = outcome else {
            Issue.record("expected fetchingReadFailure after the successful fetch, got \(outcome)")
            return
        }
        #expect(failure.fetch == .fetched(commit: fetchedCommit))
        let response = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        #expect(response.exitCode == 2)
        #expect(response.text.contains(#""kind":"readFailed""#))
        #expect(response.text.contains(#""status":"fetched""#))
        #expect(response.text.contains(fetchedCommit))
    }

    @Test("a repository without an integration target reports noTarget for every branch row")
    func missingTargetMakesAssessmentsUnknown() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "worktree-list-no-target")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let runner = WorktreeOperationRunner()

        for arguments in [["list"], ["list", "--no-fetch"]] {
            let invocation = try WorktreeCommandLineArgumentParser.parse(
                arguments,
                currentDirectory: repository
            )
            let outcome = await runner.run(invocation.request)
            guard case .listed(let listing) = outcome else {
                Issue.record("expected a listed no-target outcome, got \(outcome)")
                continue
            }
            #expect(listing.target == nil)
            #expect(listing.fetch == .skipped(reason: .noTarget))
            #expect(listing.worktrees.allSatisfy { $0.integration == nil || $0.integration == .unknown(.noTarget) })
            let json = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
            #expect(json.text.contains(#""reason":"noTarget","status":"skipped""#))
        }
    }
}

@discardableResult
private func git(at directory: URL, _ arguments: String...) async throws -> String {
    try await FilesystemTestGitRepo.runGit(at: directory, args: arguments)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
