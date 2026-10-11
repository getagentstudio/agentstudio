import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

final class WorktreeCreationCommandLineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String] = []
    private var errors: [String] = []

    func appendOutput(_ output: String) {
        lock.lock()
        outputs.append(output)
        lock.unlock()
    }

    func appendError(_ error: String) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func outputSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }

    func errorSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}

func siblingDestination(repository: URL, branch: String) throws -> URL {
    let branchName = try WorktreeBranchName.validated(branch).get()
    return try #require(
        WorktreeDestinationNaming.siblingPath(
            repositoryPath: repository,
            branchName: branchName
        ))
}

@discardableResult
func worktreeCreationGit(at repository: URL, arguments: [String]) async throws -> String {
    try await FilesystemTestGitRepo.runGit(at: repository, args: arguments)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A created summary for formatter tests: a new branch at the source's HEAD with nothing fetched
/// unless a test says otherwise.
func makeCreatedSummary(
    branch: String,
    path: URL,
    repository: URL,
    materialization: WorktreeCreatedMaterialization,
    branchStatus: WorktreeCreatedBranchStatus = .created,
    upstream: String? = nil,
    start: WorktreeCreationStart = WorktreeCreationStart(
        commit: "1111111111111111111111111111111111111111", source: .sourceHead, reference: nil,
        localOnlyCommits: nil),
    fetch: WorktreeCreationFetchStatus = .skipped(.noRemote)
) -> WorktreeCreatedSummary {
    WorktreeCreatedSummary(
        operation: .new,
        branch: WorktreeCreatedBranch(name: branch, status: branchStatus, upstream: upstream),
        path: path,
        repository: repository,
        materialization: materialization,
        start: start,
        fetch: fetch
    )
}
