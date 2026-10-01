import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal branch disposition with real Git")
struct WorktreeRemovalBranchIntegrationTests {
    @Test("retains remaining contribution with its force-delete command")
    func retainsUnintegratedBranchWithOption() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-remaining")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/remaining")
        try "remaining contribution\n".write(
            to: worktree.appending(path: "remaining.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await removalGit(worktree, "add", "remaining.txt")
        try await removalGit(worktree, "commit", "-m", "Remaining contribution")

        let outcome = await WorktreeOperationRunner(client: fixture.client).run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: [worktree.path],
                    callerDirectory: fixture.path
                ))
        )
        guard case .removal(let report) = outcome,
            case .removed(let entry)? = report.entries.first
        else {
            Issue.record("expected a removed worktree with retained branch, got \(outcome)")
            return
        }
        #expect(entry.effects.branch?.disposition == .retained)
        #expect(entry.effects.branch?.reason == .hasRemainingContribution)
        #expect(
            entry.effects.branch?.options == [
                "agentstudio worktree remove --repo \(fixture.path.path) feature/remaining -D"
            ])
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/remaining").isEmpty == false)
    }

    @Test("a branch checked out in another linked worktree returns that worktree's remove command")
    func checkedOutBranchOptionNamesOtherWorktree() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-checked-out")
        defer { fixture.destroy() }
        let primaryPath = try await fixture.addWorktree(
            branch: "feature/checked-out",
            directoryName: "primary checkout with spaces"
        )
        let otherPath = try await fixture.addExistingBranchWorktree(
            branch: "feature/checked-out",
            directoryName: "other checkout with spaces"
        )

        let outcome = await WorktreeOperationRunner(client: fixture.client).run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: [primaryPath.path],
                    callerDirectory: fixture.path
                ))
        )
        guard case .removal(let report) = outcome,
            case .removed(let entry)? = report.entries.first,
            let branch = entry.effects.branch,
            case .checkedOut(let worktreePaths)? = branch.reason
        else {
            Issue.record("expected a checkedOut retention, got \(outcome)")
            return
        }
        #expect(entry.effects.directory == .removed)
        #expect(worktreePaths == [otherPath.path])
        #expect(
            branch.options == [
                "agentstudio worktree remove --repo \(fixture.path.path) '\(otherPath.path)'"
            ])
        #expect(!FileManager.default.fileExists(atPath: primaryPath.path))
        #expect(FileManager.default.fileExists(atPath: otherPath.path))
    }

    @Test("a tip moved after assessment is retained with a reassessment command")
    func retainsMovedBranchAfterAssessment() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-moved-branch")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/moved")
        try "feature tip\n".write(
            to: worktree.appending(path: "feature.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await removalGit(worktree, "add", "feature.txt")
        try await removalGit(worktree, "commit", "-m", "Feature tip")
        let movedCommit = try await removalGit(fixture.path, "rev-parse", "refs/heads/main")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let realClient = fixture.client
        let repositoryPath = fixture.path
        let client = WorktreeOperationClientStub(
            startPath: repositoryPath,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            deleteLocalBranchHandler: { request in
                await mutateBranchThenDeleteThroughSDK(
                    realClient,
                    request: request,
                    repository: repositoryPath,
                    arguments: ["update-ref", "refs/heads/\(request.branchName)", movedCommit]
                )
            }
        )

        let outcome = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .removed(let entry)? = outcome.entries.first,
            let branch = entry.effects.branch
        else {
            Issue.record("expected a removed directory with retained moved branch, got \(outcome)")
            return
        }
        #expect(branch.reason == .movedSinceAssessment)
        #expect(branch.commit == movedCommit)
        #expect(branch.options == ["agentstudio worktree remove --repo \(fixture.path.path) feature/moved"])
        #expect(try await removalGit(fixture.path, "rev-parse", "refs/heads/feature/moved") == movedCommit)
    }

    @Test("a branch that disappears at disposition is reported alreadyAbsent")
    func reportsBranchDeletedByAnotherWriter() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-already-absent")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/disappeared")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let realClient = fixture.client
        let repositoryPath = fixture.path
        let client = WorktreeOperationClientStub(
            startPath: repositoryPath,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            deleteLocalBranchHandler: { request in
                await mutateBranchThenDeleteThroughSDK(
                    realClient,
                    request: request,
                    repository: repositoryPath,
                    arguments: ["update-ref", "-d", "refs/heads/\(request.branchName)"]
                )
            }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .removed(let entry)? = report.entries.first else {
            Issue.record("expected a completed removal with an alreadyAbsent branch, got \(report)")
            return
        }
        #expect(entry.effects.branch?.disposition == .alreadyAbsent)
        #expect(entry.effects.lockResidue.isEmpty)
        #expect(report.exitCode == 0)
        #expect(
            try await removalGit(fixture.path, "for-each-ref", "--format=%(refname)", "refs/heads/feature/disappeared")
                .isEmpty)
    }

    @Test("a known deletion error after directory removal fails with its typed cause")
    func reportsKnownBranchDeletionFailure() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-branch-failure")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/delete-failure")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let realClient = fixture.client
        let repositoryPath = fixture.path
        let permissionPath = repositoryPath.appending(path: ".git/refs/heads/feature/delete-failure")
        let failure = GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>(
            reason: .gitFailure(.permissionDenied(path: permissionPath)),
            lockResidue: []
        )
        let client = WorktreeOperationClientStub(
            startPath: repositoryPath,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            deleteLocalBranchHandler: { _ in .failure(failure) }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .failed(let entry)? = report.entries.first,
            case .branchDeletionFailed(.permissionDenied(let path)) = entry.failure.kind
        else {
            Issue.record("expected branchDeletionFailed(permissionDenied), got \(report)")
            return
        }
        #expect(path?.standardizedFileURL == permissionPath.standardizedFileURL)
        #expect(entry.failure.stop == nil)
        #expect(entry.failure.effects.directory == .removed)
        #expect(entry.failure.effects.administration == .removed)
        #expect(entry.failure.effects.branch?.disposition == .retained)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/delete-failure").isEmpty
                == false)
        #expect(report.exitCode == 2)
    }

    @Test("an exact foreign ref lock is attached to the failed entry and left untouched")
    func reportsExactBranchRefLockAfterWorktreeRemoval() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-ref-lock")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/ref-lock")
        let lockPath = fixture.path.appending(path: ".git/refs/heads/feature/ref-lock.lock")
        let foreignBytes = Data("foreign branch writer\n".utf8)
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try foreignBytes.write(to: lockPath)

        let report = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .failed(let entry)? = report.entries.first,
            let stop = entry.failure.stop,
            case .gitLockHeld(let observation) = stop.details
        else {
            Issue.record("expected branch deletion failure with exact ref lock details, got \(report)")
            return
        }
        #expect(
            entry.failure.kind
                == .branchDeletionFailed(
                    .lockHeld(
                        GitLockFact(path: lockPath, resource: .reference(name: "refs/heads/feature/ref-lock"))
                    )))
        #expect(observation.path == lockPath.standardizedFileURL.path)
        #expect(observation.resource == .reference(name: "refs/heads/feature/ref-lock"))
        #expect(entry.failure.effects.directory == .removed)
        #expect(entry.failure.effects.administration == .removed)
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/ref-lock").isEmpty == false)
    }

    @Test("an unidentified branch lock remains a failed stop with retry as its only option")
    func reportsUnidentifiedBranchLockWithRetry() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-unidentified-lock")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/unidentified-lock")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let resource = GitLockResource.reference(name: "refs/heads/feature/unidentified-lock")
        let lockFailure = GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>(
            reason: .gitFailure(.lockUnidentified(resource)),
            lockResidue: []
        )
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            deleteLocalBranchHandler: { _ in .failure(lockFailure) }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .failed(let entry)? = report.entries.first,
            let stop = entry.failure.stop
        else {
            Issue.record("expected an unidentified-lock failure, got \(report)")
            return
        }
        #expect(entry.failure.kind == .branchDeletionFailed(.lockUnidentified))
        #expect(stop.reason == .gitLockUnidentified)
        #expect(stop.details == .gitLockUnidentified(resource: resource))
        #expect(stop.options.count == 1)
        #expect(stop.options.first?.action == .command("retry"))
    }

    @Test("an unobserved branch deletion outcome remains uncertain")
    func reportsUnobservedBranchDeletionAsUncertain() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-uncertain-delete")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/uncertain-delete")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            deleteLocalBranchHandler: { _ in
                .success(.uncertain(error: .unsupported(message: "test outcome was not observed"), lockResidue: []))
            }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .failed(let entry)? = report.entries.first else {
            Issue.record("expected branchDeletionUncertain, got \(report)")
            return
        }
        #expect(entry.failure.kind == .branchDeletionUncertain)
        #expect(entry.failure.effects.branch?.disposition == .unknown)
        #expect(entry.failure.stop == nil)
        #expect(report.exitCode == 2)
    }

    @Test("branch deletion stops at the default branch even with force, but removes a linked main worktree")
    func protectsDefaultBranchAtDispositionAndBranchOnlyResolution() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-default-branch")
        defer { fixture.destroy() }
        let linkedMainPath = try await fixture.addExistingBranchWorktree(
            branch: "main",
            directoryName: "linked-main"
        )

        let linkedReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [linkedMainPath.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .removed(let linkedEntry)? = linkedReport.entries.first else {
            Issue.record("expected the linked main worktree to be removed, got \(linkedReport)")
            return
        }
        #expect(linkedEntry.effects.branch?.reason == .defaultBranch)
        #expect(linkedEntry.effects.branch?.options.isEmpty == true)
        #expect(try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/main").isEmpty == false)

        try await removalGit(fixture.path, "checkout", "--detach")
        let before = try await removalRepositorySnapshot(fixture.path)
        let branchOnlyReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: ["main"],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .refused(let branchOnlyEntry)? = branchOnlyReport.entries.first else {
            Issue.record("expected a branch-only defaultBranch refusal, got \(branchOnlyReport)")
            return
        }
        #expect(branchOnlyEntry.refusal.reason == .defaultBranch)
        #expect(branchOnlyEntry.refusal.options.isEmpty)
        #expect(try await removalRepositorySnapshot(fixture.path) == before)
    }

    @Test("an unreadable checkout becomes checkoutUnknown with a retry command")
    func mapsCheckoutReadFailureToUnknownRetention() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-checkout-unknown")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/checkout-unknown")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let checkoutFailure = GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>(
            reason: .checkoutUnreadable(worktreePath: nil),
            lockResidue: []
        )
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            deleteLocalBranchHandler: { _ in .failure(checkoutFailure) }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .removed(let entry)? = report.entries.first else {
            Issue.record("expected removal with checkoutUnknown branch retention, got \(report)")
            return
        }
        #expect(entry.effects.branch?.reason == .checkoutUnknown)
        #expect(
            entry.effects.branch?.options == [
                "agentstudio worktree remove --repo \(fixture.path.path) feature/checkout-unknown"
            ])
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/checkout-unknown").isEmpty
                == false)
    }

    @Test("an unknown integration assessment remains actionable without deleting the branch")
    func preservesUnknownAssessmentWithForceOption() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-unknown-grade")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/unknown-grade")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            integrationGrades: ["feature/unknown-grade": .unknown(.readFailed)]
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path
            )
        )
        guard case .removed(let entry)? = report.entries.first else {
            Issue.record("expected removed directory with unknown assessment retention, got \(report)")
            return
        }
        #expect(entry.effects.branch?.reason == .unknownAssessment)
        #expect(
            entry.effects.branch?.options == [
                "agentstudio worktree remove --repo \(fixture.path.path) feature/unknown-grade -D"
            ])
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/unknown-grade").isEmpty
                == false)
    }
}
