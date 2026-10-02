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
