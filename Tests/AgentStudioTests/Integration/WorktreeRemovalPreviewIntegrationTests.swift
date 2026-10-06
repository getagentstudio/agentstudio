import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal preview with real Git")
struct WorktreeRemovalPreviewIntegrationTests {
    @Test("dry-run fetches the updated default branch but changes no lifecycle state")
    func fetchesOnlyTheReportedRefDuringPreview() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-preview-fetch")
        let remote = previewPath(fixture.path, suffix: "origin.git")
        let updater = previewPath(fixture.path, suffix: "updater")
        defer {
            fixture.destroy()
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: updater)
        }
        let facts = try await prepareSquashScenario(fixture: &fixture, remote: remote, updater: updater)
        let worktreesBefore = try await removalGit(fixture.path, "worktree", "list", "--porcelain")
        let branchesBefore = try await removalGit(
            fixture.path, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads")

        let report = await previewRunner(fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [facts.featurePath.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteIfIntegrated,
                fetchPolicy: .defaultBranch,
                dryRun: true
            )
        )

        guard case .planned(let entry)? = report.entries.first else {
            Issue.record("expected a planned fetch preview, got \(report)")
            return
        }
        #expect(report.fetch == .fetched(commit: facts.fetchedCommit))
        #expect(entry.plan.stopsAt == nil)
        #expect(entry.plan.steps.first?.kind == .fetch)
        #expect(entry.plan.steps.first { $0.kind == .branchDisposition }?.disposition == .wouldDelete)
        #expect(try await removalGit(fixture.path, "rev-parse", "refs/remotes/origin/main") == facts.fetchedCommit)
        #expect(try await removalGit(fixture.path, "worktree", "list", "--porcelain") == worktreesBefore)
        #expect(
            try await removalGit(
                fixture.path, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"
            ) == branchesBefore
        )
    }

    @Test("no-fetch preview uses local refs and changes no lifecycle state")
    func noFetchPreviewKeepsTheLocalAssessment() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-preview-no-fetch")
        let remote = previewPath(fixture.path, suffix: "origin.git")
        let updater = previewPath(fixture.path, suffix: "updater")
        defer {
            fixture.destroy()
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: updater)
        }
        let facts = try await prepareSquashScenario(fixture: &fixture, remote: remote, updater: updater)
        let remoteRefsBefore = try await removalGit(
            fixture.path, "for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes")
        let worktreesBefore = try await removalGit(fixture.path, "worktree", "list", "--porcelain")

        let report = await previewRunner(fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [facts.featurePath.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteIfIntegrated,
                fetchPolicy: .skip,
                dryRun: true
            )
        )

        guard case .planned(let entry)? = report.entries.first else {
            Issue.record("expected a no-fetch preview, got \(report)")
            return
        }
        #expect(report.fetch == .skipped(reason: .noFetchFlag))
        #expect(entry.plan.steps.first { $0.kind == .branchDisposition }?.detail == "hasRemainingContribution")
        #expect(
            try await removalGit(
                fixture.path, "for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"
            ) == remoteRefsBefore
        )
        #expect(try await removalGit(fixture.path, "worktree", "list", "--porcelain") == worktreesBefore)
        #expect(FileManager.default.fileExists(atPath: facts.featurePath.path))
        #expect(facts.oldRemoteCommit != facts.fetchedCommit)
    }
}

private struct WorktreeRemovalPreviewFacts {
    let featurePath: URL
    let oldRemoteCommit: String
    let fetchedCommit: String
}

private func previewPath(_ repository: URL, suffix: String) -> URL {
    repository.deletingLastPathComponent()
        .appending(path: "\(repository.lastPathComponent).\(suffix)", directoryHint: .isDirectory)
}

private func previewRunner(_ client: any AgentStudioGitLocalClient) -> WorktreeRemovalRunner {
    WorktreeRemovalRunner(
        client: client,
        remoteClient: SystemGitRemoteClient(configuration: .init(allowedProtocols: [.file]))
    )
}

private func prepareSquashScenario(
    fixture: inout WorktreeRemovalRepository,
    remote: URL,
    updater: URL
) async throws -> WorktreeRemovalPreviewFacts {
    try await removalGit(fixture.path, "init", "--bare", remote.path)
    try await removalGit(fixture.path, "remote", "add", "origin", remote.path)
    try await removalGit(fixture.path, "push", "--set-upstream", "origin", "main")
    try await removalGit(remote, "symbolic-ref", "HEAD", "refs/heads/main")
    try await removalGit(fixture.path, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main")
    try await removalGit(fixture.path, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")

    let featurePath = try await fixture.addWorktree(branch: "feature/squash")
    try "squashed content\n".write(
        to: featurePath.appending(path: "feature.txt"),
        atomically: true,
        encoding: .utf8
    )
    try await removalGit(featurePath, "add", "feature.txt")
    try await removalGit(featurePath, "commit", "-m", "Feature change")
    let oldRemoteCommit = try await removalGit(fixture.path, "rev-parse", "refs/remotes/origin/main")

    try await removalGit(fixture.path, "clone", remote.path, updater.path)
    try await removalGit(updater, "config", "user.email", "removal-tests@example.test")
    try await removalGit(updater, "config", "user.name", "Removal Tests")
    try await removalGit(updater, "config", "commit.gpgsign", "false")
    try "squashed content\n".write(
        to: updater.appending(path: "feature.txt"),
        atomically: true,
        encoding: .utf8
    )
    try await removalGit(updater, "add", "feature.txt")
    try await removalGit(updater, "commit", "-m", "Squash feature change")
    try await removalGit(updater, "push", "origin", "main")
    let fetchedCommit = try await removalGit(updater, "rev-parse", "HEAD")
    return WorktreeRemovalPreviewFacts(
        featurePath: featurePath,
        oldRemoteCommit: oldRemoteCommit,
        fetchedCommit: fetchedCommit
    )
}
