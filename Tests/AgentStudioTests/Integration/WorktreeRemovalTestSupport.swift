import AgentStudioGit
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation

struct WorktreeRemovalRepository {
    let path: URL
    let client = LibGit2AgentStudioGitLocalClient()
    private(set) var linkedWorktreePaths: [URL] = []

    static func create(named name: String) async throws -> Self {
        let repository = try await FilesystemTestGitRepo.create(named: name)
        try "tmp/\n".write(
            to: repository.appending(path: ".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "initial\n".write(
            to: repository.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await removalGit(repository, "add", ".gitignore", "tracked.txt")
        try await removalGit(repository, "commit", "-m", "Initial")
        return Self(path: repository)
    }

    mutating func addWorktree(
        branch: String,
        directoryName: String? = nil
    ) async throws -> URL {
        let name = directoryName ?? "\(path.lastPathComponent).\(branch.replacingOccurrences(of: "/", with: "-"))"
        let worktreePath = path.deletingLastPathComponent()
            .appending(path: name, directoryHint: .isDirectory)
        _ = try await client.createWorktree(
            GitCreateWorktreeRequest(
                repositoryPath: path,
                destinationPath: worktreePath,
                mode: .newBranch(name: branch, startPoint: .named("refs/heads/main"), upstream: nil)
            ))
        linkedWorktreePaths.append(worktreePath)
        return worktreePath
    }

    mutating func addExistingBranchWorktree(
        branch: String,
        directoryName: String
    ) async throws -> URL {
        let worktreePath = path.deletingLastPathComponent()
            .appending(path: directoryName, directoryHint: .isDirectory)
        _ = try await removalGit(path, "worktree", "add", "--force", "--checkout", worktreePath.path, branch)
        linkedWorktreePaths.append(worktreePath)
        return worktreePath
    }

    func destroy() {
        for worktreePath in linkedWorktreePaths {
            try? FileManager.default.removeItem(at: worktreePath)
        }
        FilesystemTestGitRepo.destroy(path)
    }
}

func worktreeRemovalRequest(
    repository: URL,
    targets: [String],
    callerDirectory: URL? = nil,
    discardWorkingChanges: Bool = false,
    branchPolicy: WorktreeBranchPolicy = .deleteIfIntegrated,
    evidencePolicy: WorktreeEvidencePolicy = .requireEmpty,
    fetchPolicy: WorktreeFetchPolicy = .skip,
    removeStaleLock: Bool = false,
    dryRun: Bool = false
) -> WorktreeRemovalRequest {
    WorktreeRemovalRequest(
        start: repository,
        callerDirectory: callerDirectory,
        targets: targets,
        discardWorkingChanges: discardWorkingChanges,
        branchPolicy: branchPolicy,
        evidencePolicy: evidencePolicy,
        fetchPolicy: fetchPolicy,
        removeStaleLock: removeStaleLock,
        closePanes: false,
        removeWithOpenPanes: false,
        dryRun: dryRun
    )
}

@discardableResult
func removalGit(_ directory: URL, _ arguments: String...) async throws -> String {
    try await FilesystemTestGitRepo.runGit(at: directory, args: arguments)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func executeWorktreeRemovalThroughSDK(
    _ client: any AgentStudioGitLocalClient,
    request: GitRemoveWorktreeRequest
) async -> Result<GitWorktreeRemovalResult, GitDataPlaneError> {
    do {
        return .success(try await client.removeWorktree(request))
    } catch {
        return .failure(.unsupported(message: "real SDK worktree removal failed at the test seam"))
    }
}

func executeBranchDeletionThroughSDK(
    _ client: any AgentStudioGitLocalClient,
    request: GitDeleteLocalBranchRequest
) async -> Result<GitDeleteLocalBranchResult, GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>> {
    do {
        return .success(try await client.deleteLocalBranch(request))
    } catch {
        return .failure(
            GitLockedOperationFailure(
                reason: .gitFailure(.unsupported(message: "real SDK branch deletion failed at the test seam")),
                lockResidue: nil
            ))
    }
}

func mutateBranchThenDeleteThroughSDK(
    _ client: any AgentStudioGitLocalClient,
    request: GitDeleteLocalBranchRequest,
    repository: URL,
    arguments: [String]
) async -> Result<GitDeleteLocalBranchResult, GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>> {
    do {
        _ = try await FilesystemTestGitRepo.runGit(at: repository, args: arguments)
    } catch {
        return .failure(
            GitLockedOperationFailure(
                reason: .gitFailure(.unsupported(message: "test Git mutation failed at the branch deletion seam")),
                lockResidue: []
            ))
    }
    return await executeBranchDeletionThroughSDK(client, request: request)
}

func removalRepositorySnapshot(
    _ repository: URL
) async throws -> (worktrees: String, branches: String) {
    let worktrees = try await removalGit(repository, "worktree", "list", "--porcelain")
    let branches = try await removalGit(
        repository,
        "for-each-ref",
        "--format=%(refname) %(objectname)",
        "refs/heads"
    )
    return (worktrees, branches)
}

func addEvidence(_ contents: String, to worktree: URL) throws -> URL {
    let path = worktree.appending(path: "tmp/evidence.txt")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: path)
    return path
}

func setModificationTimeUsingTouch(_ date: Date, at path: URL) async throws {
    try await withoutBlockingCooperativePool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let timestamp = String(
            format: "%04d%02d%02d%02d%02d.%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = ["-t", timestamp, path.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeRemovalTestSupport",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "touch could not set the test lock timestamp"]
            )
        }
    }
}
