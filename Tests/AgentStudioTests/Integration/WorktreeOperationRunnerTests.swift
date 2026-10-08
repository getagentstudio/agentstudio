import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree operation runner")
struct WorktreeOperationRunnerTests {
    @Test("new discovers a nested repository, creates the sibling branch, and list finds it")
    func createsAndListsWorktreeFromNestedDirectory() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-new")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)
        let nestedStart = try makeNestedDirectory(in: repository)
        let branch = "feature/operation-new"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling path for the validated branch")
            return
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        let runner = WorktreeOperationRunner()
        let outcome = await runner.run(
            .create(
                WorktreeCreateRequest(
                    start: nestedStart, branch: branch, source: .mainWorktree,
                    startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))

        guard case .created(let created) = outcome else {
            Issue.record("expected created outcome, received \(outcome)")
            return
        }
        #expect(created.operation == .new)
        #expect(created.branch == branch)
        #expect(canonicalPath(created.path) == canonicalPath(destination))
        #expect(canonicalPath(created.repository) == canonicalPath(repository))
        #expect(created.materialization.largeFiles != nil)
        #expect(try await git(at: destination, "rev-parse", "--abbrev-ref", "HEAD") == branch)
        let destinationHead = try await git(at: destination, "rev-parse", "HEAD")
        let defaultBranchHead = try await git(at: repository, "rev-parse", "refs/heads/main")
        #expect(destinationHead == defaultBranchHead)

        let listOutcome = await runner.run(
            .list(start: nestedStart, callerDirectory: nestedStart, targets: [], fetchPolicy: .skip)
        )
        guard case .listed(let listing) = listOutcome else {
            Issue.record("expected listed outcome, received \(listOutcome)")
            return
        }
        #expect(canonicalPath(listing.repository) == canonicalPath(repository))
        #expect(listing.worktrees.count == 2)
        #expect(
            listing.worktrees.contains {
                canonicalPath($0.path) == canonicalPath(repository) && $0.branch == "main" && $0.isMain
            })
        #expect(
            listing.worktrees.contains {
                canonicalPath($0.path) == canonicalPath(destination) && $0.branch == branch && !$0.isMain
            })
    }

    @Test("fork discovers and copies a linked source worktree, or reports the SDK's capability refusal")
    func forksTheSelectedLinkedWorktree() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-fork")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)

        let sourceWorktree = siblingPath(repository: repository, suffix: "source")
        defer { try? FileManager.default.removeItem(at: sourceWorktree) }
        let client = LibGit2AgentStudioGitLocalClient()
        _ = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: repository,
                destinationPath: sourceWorktree,
                mode: .newBranch(
                    name: "feature/source",
                    startPoint: GitRevisionTarget.named("refs/heads/main")
                )
            ))
        let nestedStart = try makeNestedDirectory(in: sourceWorktree)
        try "linked source\n".write(
            to: sourceWorktree.appending(path: "linked-only.txt"),
            atomically: true,
            encoding: .utf8
        )

        let branch = "fork/from-linked"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling path for the validated branch")
            return
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        let outcome = await WorktreeOperationRunner(client: client).run(
            .create(
                WorktreeCreateRequest(
                    start: nestedStart, branch: branch, source: .worktree(nestedStart), startBranch: nil,
                    materialization: .copyOnWrite, fetchPolicy: .skip)))

        switch outcome {
        case .created(let created):
            #expect(created.operation == .new)
            #expect(canonicalPath(created.path) == canonicalPath(destination))
            #expect(canonicalPath(created.repository) == canonicalPath(repository))
            switch created.materialization {
            case .copyOnWrite:
                #expect(true)
            case .changesOnly, .checkout:
                Issue.record("expected the existing fork command to select copy-on-write materialization")
            }
            #expect(
                try String(contentsOf: destination.appending(path: "linked-only.txt"), encoding: .utf8)
                    == "linked source\n")
            #expect(!FileManager.default.fileExists(atPath: repository.appending(path: "linked-only.txt").path))
            let destinationHead = try await git(at: destination, "rev-parse", "HEAD")
            let sourceHead = try await git(at: sourceWorktree, "rev-parse", "HEAD")
            #expect(destinationHead == sourceHead)

            let listOutcome = await WorktreeOperationRunner(client: client).run(
                .list(start: nestedStart, callerDirectory: nestedStart, targets: [], fetchPolicy: .skip)
            )
            guard case .listed(let listing) = listOutcome else {
                Issue.record("expected listed outcome from linked source, received \(listOutcome)")
                return
            }
            #expect(listing.worktrees.count == 3)
            #expect(
                listing.worktrees.contains {
                    canonicalPath($0.path) == canonicalPath(sourceWorktree)
                        && $0.branch == "feature/source" && !$0.isMain
                })
            #expect(
                listing.worktrees.contains {
                    canonicalPath($0.path) == canonicalPath(destination) && $0.branch == branch && !$0.isMain
                })
        case .refused(.forkUnavailable(let reason, _)):
            #expect(Self.isEnvironmentForkUnavailable(reason))
        default:
            Issue.record("expected a successful fork or an environment capability refusal, received \(outcome)")
        }
    }

    @Test("new and list distinguish a path outside Git from fork's non-worktree source")
    func refusesOutsideRepositoryAndWorktreePaths() async throws {
        let outsideRepository = FileManager.default.temporaryDirectory
            .appending(path: "worktree-operation-outside-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: outsideRepository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRepository) }
        let runner = WorktreeOperationRunner()

        #expect(
            await runner.run(
                .list(
                    start: outsideRepository,
                    callerDirectory: outsideRepository,
                    targets: [],
                    fetchPolicy: .skip
                )
            ) == .refused(.notInRepository(outsideRepository))
        )
        #expect(
            await runner.run(
                .create(
                    WorktreeCreateRequest(
                        start: outsideRepository, branch: "feature/outside", source: .worktree(outsideRepository),
                        startBranch: nil, materialization: .copyOnWrite, fetchPolicy: .skip))
            )
                == .refused(.notInWorktree(outsideRepository)))
    }

    @Test("branch validation and empty folder slugs are refused before mutation")
    func refusesInvalidBranchAndEmptySlug() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-invalid-branch")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let runner = WorktreeOperationRunner()

        #expect(
            await runner.run(
                .create(
                    WorktreeCreateRequest(
                        start: repository, branch: "feature/invalid..name", source: .mainWorktree,
                        startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
                == .refused(.invalidBranchName(.local(.containsForbiddenSequence("..")))))
        #expect(
            await runner.run(
                .create(
                    WorktreeCreateRequest(
                        start: repository, branch: "東京", source: .mainWorktree,
                        startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
                == .refused(.emptyBranchSlug))
    }

    @Test("an existing sibling destination is refused")
    func refusesExistingDestination() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-destination-exists")
        defer { FilesystemTestGitRepo.destroy(repository) }
        let branch = "feature/occupied"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling path for the validated branch")
            return
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        #expect(
            await WorktreeOperationRunner().run(
                .create(
                    WorktreeCreateRequest(
                        start: repository, branch: branch, source: .mainWorktree,
                        startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
                == .refused(.destinationExists(destination)))
    }

    @Test("an existing Git branch is refused")
    func refusesExistingBranch() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-branch-exists")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)
        let branch = "feature/already-exists"
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["branch", branch])

        #expect(
            await WorktreeOperationRunner().run(
                .create(
                    WorktreeCreateRequest(
                        start: repository, branch: branch, source: .mainWorktree,
                        startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
                == .refused(.creationStopped(.branchAlreadyExists(branch: branch))))
    }

    /// Interim: these forms need the branch resolver and the SDK's reset fork. Until then the
    /// runner refuses them by their flags before reading the repository.
    @Test("forms the runner cannot build yet are refused by their flags")
    func refusesFormsAwaitingBranchResolution() async {
        let start = URL(fileURLWithPath: "/tmp/worktree-operation-interim-forms")
        let source = WorktreeCreateSource.worktree(start.appending(path: "linked"))
        let cases: [(startBranch: String?, materialization: WorktreeCreateMaterialization, form: String)] = [
            (nil, .checkout, "--no-fork with --from"),
            ("release", .checkout, "--no-fork with --from"),
            ("release", .copyOnWrite, "--from with --from-branch"),
            ("release", .changesOnly, "--changes-only with --from-branch"),
        ]
        for testCase in cases {
            let outcome = await WorktreeOperationRunner().run(
                .create(
                    WorktreeCreateRequest(
                        start: start, branch: "feature/interim", source: source, startBranch: testCase.startBranch,
                        materialization: testCase.materialization, fetchPolicy: .skip)))
            #expect(outcome == .refused(.creationFormUnsupported(testCase.form)))
        }
    }

    @Test("new refuses when the repository has no default branch")
    func refusesRepositoryWithoutDefaultBranch() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-no-default")
        defer { FilesystemTestGitRepo.destroy(repository) }

        #expect(
            await WorktreeOperationRunner().run(
                .create(
                    WorktreeCreateRequest(
                        start: repository, branch: "feature/no-default", source: .mainWorktree,
                        startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
                == .refused(.noDefaultBranch))
    }

    @Test("new and fork refuse repositories with a separate Git directory")
    func refusesUnsupportedSeparateGitDirectory() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "operation-separate-gitdir")
        let separateGitDirectory = siblingPath(repository: repository, suffix: "git-store")
        defer { try? FileManager.default.removeItem(at: separateGitDirectory) }
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)
        try FileManager.default.moveItem(at: repository.appending(path: ".git"), to: separateGitDirectory)
        try "gitdir: \(separateGitDirectory.path)\n".write(
            to: repository.appending(path: ".git"), atomically: true, encoding: .utf8)
        try await FilesystemTestGitRepo.runGit(at: repository, args: ["config", "core.worktree", repository.path])
        #expect(try await git(at: repository, "rev-parse", "--show-toplevel") == repository.path)

        let runner = WorktreeOperationRunner()
        let newOutcome = await runner.run(
            .create(
                WorktreeCreateRequest(
                    start: repository, branch: "feature/unsupported-layout", source: .mainWorktree,
                    startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
        let forkOutcome = await runner.run(
            .create(
                WorktreeCreateRequest(
                    start: repository, branch: "fork/unsupported-layout", source: .worktree(repository),
                    startBranch: nil, materialization: .copyOnWrite, fetchPolicy: .skip))
        )
        expectUnsupportedLayout(newOutcome, repository: repository)
        expectUnsupportedLayout(forkOutcome, repository: repository)
    }

    @Test("a missing sibling parent is refused before later Git reads")
    func refusesMissingDestinationParent() async {
        let start = URL(fileURLWithPath: "/tmp/worktree-operation-client-fixture")
        let repository = URL(fileURLWithPath: "/tmp/worktree-operation-missing-parent/repository")
        let repositoryID = GitRepositoryID(rawValue: "common:/tmp/worktree-operation-missing-parent/repository.git")
        let snapshot = GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "fixture|worktree:source"),
            repositoryID: repositoryID,
            displayName: "main",
            path: start,
            canonicalPath: start,
            gitDirectory: start.appending(path: ".git"),
            indexPath: start.appending(path: ".git/index"),
            isMainWorktree: true,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
        let identity = GitRepositoryIdentity(
            id: repositoryID,
            canonicalCommonDirectory: URL(fileURLWithPath: "/tmp/worktree-operation-missing-parent/repository.git"),
            mainWorktreePath: repository
        )
        let client = WorktreeOperationClientStub(startPath: start, snapshot: snapshot, identity: identity)
        let runner = WorktreeOperationRunner(
            client: client,
            defaultStartPointResolver: WorktreeOperationStartPointStub(.noDefaultBranch)
        )

        let outcome = await runner.run(
            .create(
                WorktreeCreateRequest(
                    start: start, branch: "feature/missing-parent", source: .mainWorktree,
                    startBranch: nil, materialization: .checkout, fetchPolicy: .skip)))
        guard case .refused(.destinationParentMissing(let missingParent)) = outcome else {
            Issue.record("expected missing destination parent refusal, received \(outcome)")
            return
        }
        #expect(canonicalPath(missingParent) == canonicalPath(repository.deletingLastPathComponent()))
    }

    private static func isEnvironmentForkUnavailable(_ reason: GitWorktreeForkRejectionReason) -> Bool {
        switch reason {
        case .unsupportedOperatingSystem,
            .sourceFilesystemNotAPFS,
            .destinationFilesystemNotAPFS,
            .crossDevice,
            .cloneCapabilityUnavailable,
            .administrativeStoreOnDifferentDevice,
            .fileProviderManagedLocation,
            .datalessContent:
            true
        default:
            false
        }
    }

    private func expectUnsupportedLayout(_ outcome: WorktreeOperationOutcome, repository: URL) {
        guard case .refused(.unsupportedRepositoryLayout(let path)) = outcome else {
            Issue.record("expected unsupported layout refusal, received \(outcome)")
            return
        }
        #expect(canonicalPath(path) == canonicalPath(repository))
    }
}

private func makeNestedDirectory(in worktree: URL) throws -> URL {
    let nested = worktree.appending(path: "nested/deep", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    return nested
}

private func siblingPath(repository: URL, suffix: String) -> URL {
    repository.deletingLastPathComponent().appending(
        path: "\(repository.lastPathComponent).\(suffix)",
        directoryHint: .isDirectory
    )
}

private func git(at directory: URL, _ arguments: String...) async throws -> String {
    try await FilesystemTestGitRepo.runGit(at: directory, args: arguments)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func canonicalPath(_ url: URL) -> String {
    var path = url.resolvingSymlinksInPath().standardizedFileURL.path
    if path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

private struct WorktreeOperationStartPointStub: WorktreeDefaultStartPointResolving {
    let startPoint: WorktreeDefaultStartPoint

    init(_ startPoint: WorktreeDefaultStartPoint) {
        self.startPoint = startPoint
    }

    func resolveDefaultStartPoint(repositoryPath _: URL) async throws(GitDataPlaneError) -> WorktreeDefaultStartPoint {
        startPoint
    }
}
