import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Darwin
import Foundation
import Testing

@Suite("Worktree creation large-file command line integration")
struct WorktreeCreationLargeFileCommandLineTests {
    private typealias CreatedDocument = WorktreeCreationCommandLineDocuments.CreatedDocument

    @Test("new fills an LFS pointer from the local store and remains clean through list and remove")
    func fillsLargeFileFromLocalStoreAndRemovesWithoutForce() async throws {
        let fixture = try await WorktreeCreationLargeFileFixture.create(
            named: "cli-lfs-filled",
            includeStoreObject: true
        )
        defer { FilesystemTestGitRepo.destroy(fixture.repository) }

        let branch = "feature/lfs-filled"
        let destination = try siblingDestination(repository: fixture.repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }

        let createProbe = WorktreeCreationCommandLineProbe()
        let createExitCode = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--no-fork", "--repo", fixture.repository.path, "--json"],
            currentDirectory: fixture.repository,
            output: { createProbe.appendOutput($0) },
            errorOutput: { createProbe.appendError($0) }
        )

        #expect(createExitCode == 0)
        #expect(createProbe.errorSnapshot().isEmpty)
        let creationJSON = try #require(createProbe.outputSnapshot().first)
        let created = try JSONDecoder().decode(CreatedDocument.self, from: Data(creationJSON.utf8))
        #expect(created.largeFiles?.materialized == 1)
        #expect(created.largeFiles?.missing.isEmpty == true)
        #expect(created.largeFiles?.missingCount == 0)
        #expect(created.largeFiles?.options == nil)
        #expect(created.largeFiles?.scan == .complete)
        #expect(try WorktreeLargeFileCLIContract.rawScanJSON(in: creationJSON) == #""complete""#)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)

        let listProbe = WorktreeCreationCommandLineProbe()
        let listExitCode = await WorktreeCommandLine.run(
            arguments: ["list", "--repo", fixture.repository.path, "--no-fetch", "--json"],
            currentDirectory: fixture.repository,
            output: { listProbe.appendOutput($0) },
            errorOutput: { listProbe.appendError($0) }
        )
        #expect(listExitCode == 0)
        let listing = try JSONDecoder().decode(
            WorktreeListingSummary.self,
            from: Data(try #require(listProbe.outputSnapshot().first).utf8)
        )
        let listed = try #require(
            listing.worktrees.first { $0.path.standardizedFileURL == destination.standardizedFileURL })
        #expect(listed.changes.status == .clean)

        let removeProbe = WorktreeCreationCommandLineProbe()
        let removeExitCode = await WorktreeCommandLine.run(
            arguments: ["remove", branch, "--repo", fixture.repository.path, "--json"],
            currentDirectory: fixture.repository,
            output: { removeProbe.appendOutput($0) },
            errorOutput: { removeProbe.appendError($0) }
        )
        #expect(removeExitCode == 0)
        #expect(removeProbe.errorSnapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("new and changes-only fork quote pull options for missing LFS objects")
    func reportsQuotedPullOptionsForMissingLargeFiles() async throws {
        let fixture = try await WorktreeCreationLargeFileFixture.create(
            named: "cli lfs ' absent",
            includeStoreObject: false
        )
        defer { FilesystemTestGitRepo.destroy(fixture.repository) }

        let branch = "feature/lfs-absent"
        let destination = try siblingDestination(repository: fixture.repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let probe = WorktreeCreationCommandLineProbe()

        let exitCode = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--no-fork", "--repo", fixture.repository.path],
            currentDirectory: fixture.repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 0)
        #expect(probe.errorSnapshot().isEmpty)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == Data(fixture.pointer.utf8))
        let output = try #require(probe.outputSnapshot().first)
        let expectedHumanPullCommand = WorktreeLargeFileCLIContract.expectedPullCommand(for: destination)
        #expect(destination.path.contains(" "))
        #expect(destination.path.contains("'"))
        #expect(output.contains("LFS: 0 filled, 1 missing"))
        #expect(output.contains(expectedHumanPullCommand))

        let jsonProbe = WorktreeCreationCommandLineProbe()
        let jsonBranch = "feature/lfs-absent-json"
        let jsonDestination = try siblingDestination(repository: fixture.repository, branch: jsonBranch)
        defer { try? FileManager.default.removeItem(at: jsonDestination) }
        let jsonExitCode = await WorktreeCommandLine.run(
            arguments: ["new", jsonBranch, "--no-fork", "--repo", fixture.repository.path, "--json"],
            currentDirectory: fixture.repository,
            output: { jsonProbe.appendOutput($0) },
            errorOutput: { jsonProbe.appendError($0) }
        )
        #expect(jsonExitCode == 0)
        let creationJSON = try #require(jsonProbe.outputSnapshot().first)
        let created = try JSONDecoder().decode(CreatedDocument.self, from: Data(creationJSON.utf8))
        #expect(created.largeFiles?.materialized == 0)
        #expect(created.largeFiles?.missing == [GitLargeFileFillMiss(path: "asset.bin", reason: .objectAbsent)])
        #expect(created.largeFiles?.missingCount == 1)
        #expect(created.largeFiles?.options == [WorktreeLargeFileCLIContract.expectedPullCommand(for: jsonDestination)])
        #expect(created.largeFiles?.scan == .complete)
        #expect(try WorktreeLargeFileCLIContract.rawScanJSON(in: creationJSON) == #""complete""#)

        let forkBranch = "feature/lfs-absent-fork"
        let forkDestination = try siblingDestination(repository: fixture.repository, branch: forkBranch)
        defer { try? FileManager.default.removeItem(at: forkDestination) }
        let forkProbe = WorktreeCreationCommandLineProbe()
        let forkExitCode = await WorktreeCommandLine.run(
            arguments: ["new", forkBranch, "--from", fixture.repository.path, "--changes-only"],
            currentDirectory: fixture.repository,
            output: { forkProbe.appendOutput($0) },
            errorOutput: { forkProbe.appendError($0) }
        )
        #expect(forkExitCode == 0)
        #expect(forkProbe.errorSnapshot().isEmpty)
        #expect(
            forkProbe.outputSnapshot().first?.contains(
                WorktreeLargeFileCLIContract.expectedPullCommand(for: forkDestination)) == true)

        let forkJSONBranch = "feature/lfs-absent-fork-json"
        let forkJSONDestination = try siblingDestination(repository: fixture.repository, branch: forkJSONBranch)
        defer { try? FileManager.default.removeItem(at: forkJSONDestination) }
        let forkJSONProbe = WorktreeCreationCommandLineProbe()
        let forkJSONExitCode = await WorktreeCommandLine.run(
            arguments: ["new", forkJSONBranch, "--from", fixture.repository.path, "--changes-only", "--json"],
            currentDirectory: fixture.repository,
            output: { forkJSONProbe.appendOutput($0) },
            errorOutput: { forkJSONProbe.appendError($0) }
        )
        #expect(forkJSONExitCode == 0)
        #expect(forkJSONProbe.errorSnapshot().isEmpty)
        let forkJSONOutput = try #require(forkJSONProbe.outputSnapshot().first)
        let forkCreated = try JSONDecoder().decode(CreatedDocument.self, from: Data(forkJSONOutput.utf8))
        #expect(forkCreated.largeFiles?.missing == [GitLargeFileFillMiss(path: "asset.bin", reason: .objectAbsent)])
        #expect(
            forkCreated.largeFiles?.options
                == [WorktreeLargeFileCLIContract.expectedPullCommand(for: forkJSONDestination)])
    }

    @Test("changes-only fork reports LFS materialized from the local store")
    func changesOnlyForkReportsLargeFileMaterialization() async throws {
        let fixture = try await WorktreeCreationLargeFileFixture.create(
            named: "cli-lfs-fork",
            includeStoreObject: true
        )
        defer { FilesystemTestGitRepo.destroy(fixture.repository) }

        let branch = "feature/lfs-fork"
        let destination = try siblingDestination(repository: fixture.repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let probe = WorktreeCreationCommandLineProbe()

        let exitCode = await WorktreeCommandLine.run(
            arguments: ["new", branch, "--from", fixture.repository.path, "--changes-only", "--json"],
            currentDirectory: fixture.repository,
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendError($0) }
        )

        #expect(exitCode == 0)
        #expect(probe.errorSnapshot().isEmpty)
        let created = try JSONDecoder().decode(
            CreatedDocument.self, from: Data(try #require(probe.outputSnapshot().first).utf8))
        #expect(created.largeFiles?.materialized == 1)
        #expect(created.largeFiles?.missing.isEmpty == true)
        #expect(created.largeFiles?.missingCount == 0)
        #expect(created.largeFiles?.options == nil)
        #expect(created.largeFiles?.scan == .complete)
        #expect(try Data(contentsOf: destination.appending(path: "asset.bin")) == fixture.payload)
    }

    @Test("incomplete LFS scan is rendered as a successful creation without placeholder misses")
    func rendersIncompleteLargeFileScanFromCreationBoundary() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-lfs-incomplete-scan")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)

        let branch = "feature/incomplete-scan"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }

        let realClient = LibGit2AgentStudioGitLocalClient()
        let snapshots = try await realClient.worktrees(for: repository)
        let snapshot = try #require(snapshots.first)
        let identity = try await realClient.repositoryIdentity(for: repository)
        let incompleteFill = GitLargeFileFill(
            materializedCount: 0,
            missing: [],
            residuePaths: [],
            scan: .incomplete(.readFailed(errno: EIO))
        )
        let client = WorktreeOperationClientStub(
            startPath: repository,
            snapshot: snapshot,
            identity: identity,
            baseClient: realClient,
            largeFileFillOverride: incompleteFill
        )

        let outcome = await WorktreeOperationRunner(client: client).run(
            .create(
                WorktreeCreateRequest(
                    start: repository, branch: branch, source: .mainWorktree,
                    startBranch: nil, materialization: .checkout, fetchPolicy: .skip))
        )
        guard case .created = outcome else {
            Issue.record("expected worktree creation to succeed with an incomplete LFS scan, received \(outcome)")
            return
        }

        let jsonResponse = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        #expect(jsonResponse.exitCode == 0)
        let created = try JSONDecoder().decode(CreatedDocument.self, from: Data(jsonResponse.text.utf8))
        #expect(created.largeFiles?.scan == .incompleteReadFailed(errno: EIO))
        #expect(created.largeFiles?.missing.isEmpty == true)
        #expect(created.largeFiles?.options == ["git -C \(destination.path) lfs pull"])
        #expect(
            try WorktreeLargeFileCLIContract.rawScanJSON(in: jsonResponse.text)
                == "{\"incomplete\":{\"readFailed\":\(EIO)}}")
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let humanResponse = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(humanResponse.exitCode == 0)
        #expect(humanResponse.text.contains("scan incomplete (readFailed errno \(EIO))"))
        #expect(humanResponse.text.contains("git -C \(destination.path) lfs pull"))
    }

    @Test("incomplete Git scan uses the CLI's string failure shape")
    func rendersIncompleteGitFailureScanAtCreationBoundary() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-lfs-incomplete-git-scan")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)

        let branch = "feature/incomplete-git-scan"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }

        let realClient = LibGit2AgentStudioGitLocalClient()
        let snapshots = try await realClient.worktrees(for: repository)
        let snapshot = try #require(snapshots.first)
        let identity = try await realClient.repositoryIdentity(for: repository)
        let incompleteFill = GitLargeFileFill(
            materializedCount: 0,
            missing: [],
            residuePaths: [],
            scan: .incomplete(.gitFailure(kind: .headUnavailable))
        )
        let client = WorktreeOperationClientStub(
            startPath: repository,
            snapshot: snapshot,
            identity: identity,
            baseClient: realClient,
            largeFileFillOverride: incompleteFill
        )
        let outcome = await WorktreeOperationRunner(client: client).run(
            .create(
                WorktreeCreateRequest(
                    start: repository, branch: branch, source: .mainWorktree,
                    startBranch: nil, materialization: .checkout, fetchPolicy: .skip))
        )
        guard case .created = outcome else {
            Issue.record("expected worktree creation to succeed with an incomplete Git scan, received \(outcome)")
            return
        }

        let jsonResponse = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        #expect(jsonResponse.exitCode == 0)
        let created = try JSONDecoder().decode(CreatedDocument.self, from: Data(jsonResponse.text.utf8))
        #expect(created.largeFiles?.materialized == 0)
        #expect(created.largeFiles?.missing.isEmpty == true)
        #expect(created.largeFiles?.missingCount == 0)
        #expect(created.largeFiles?.scan == .incompleteGitFailure(kind: "headUnavailable"))
        #expect(created.largeFiles?.options == ["git -C \(destination.path) lfs pull"])
        #expect(
            try WorktreeLargeFileCLIContract.rawScanJSON(in: jsonResponse.text)
                == #"{"incomplete":{"gitFailure":"headUnavailable"}}"#)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        let humanResponse = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(humanResponse.exitCode == 0)
        #expect(humanResponse.text.contains("scan incomplete (gitFailure headUnavailable)"))
    }

    @Test("nested LFS residue is rooted at the new worktree with zero fills and misses")
    func reportsNestedResidueRelativeToCreatedWorktree() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-lfs-residue-only")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)

        let branch = "feature/lfs-residue-only"
        let destination = try siblingDestination(repository: repository, branch: branch)
        defer { try? FileManager.default.removeItem(at: destination) }
        let residuePath = "assets/.agentstudio-lfs-fill-orphan"
        let residueFile = destination.appending(path: residuePath)

        let realClient = LibGit2AgentStudioGitLocalClient()
        let snapshot = try #require(await realClient.worktrees(for: repository).first)
        let identity = try await realClient.repositoryIdentity(for: repository)
        let fill = GitLargeFileFill(
            materializedCount: 0,
            missing: [],
            residuePaths: [residuePath],
            scan: .complete
        )
        let client = WorktreeOperationClientStub(
            startPath: repository,
            snapshot: snapshot,
            identity: identity,
            baseClient: realClient,
            largeFileFillOverride: fill
        )
        let outcome = await WorktreeOperationRunner(client: client).run(
            .create(
                WorktreeCreateRequest(
                    start: repository, branch: branch, source: .mainWorktree,
                    startBranch: nil, materialization: .checkout, fetchPolicy: .skip))
        )
        guard case .created = outcome else {
            Issue.record("expected creation to report its retained LFS residue, got \(outcome)")
            return
        }

        try FileManager.default.createDirectory(
            at: residueFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("orphaned temporary file".utf8).write(to: residueFile)
        let jsonResponse = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        #expect(jsonResponse.exitCode == 0)
        let document = try #require(JSONSerialization.jsonObject(with: Data(jsonResponse.text.utf8)) as? [String: Any])
        let largeFiles = try #require(document["largeFiles"] as? [String: Any])
        #expect(largeFiles["materialized"] as? Int == 0)
        #expect((largeFiles["missing"] as? [Any])?.isEmpty == true)
        #expect(largeFiles["missingCount"] as? Int == 0)
        #expect(largeFiles["options"] == nil)
        let leftovers = try #require(document["leftovers"] as? [String: Any])
        let item = try #require((leftovers["items"] as? [[String: Any]])?.first)
        #expect(item["base"] as? String == "destination")
        #expect(item["location"] as? String == residuePath)
        #expect(FileManager.default.fileExists(atPath: residueFile.path))

        let humanResponse = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: false)
        #expect(humanResponse.text.contains("temporaryArtifact \(residuePath) (destination)"))
    }

}
