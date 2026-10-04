import AgentStudioGit
import Foundation

extension WorktreeOperationRunner {
    func preflightCreation(
        start: URL,
        branch: String,
        forkSource: Bool
    ) async -> WorktreeCreationPreparation {
        let discovery: WorktreeDiscovery
        switch await discover(start: start, forkSource: forkSource) {
        case .outcome(let outcome):
            return .outcome(outcome)
        case .found(let value):
            discovery = value
        }

        guard let mainWorktreePath = discovery.identity.mainWorktreePath?.standardizedFileURL else {
            return .outcome(.refused(.unsupportedRepositoryLayout(discovery.sourceWorktreePath)))
        }

        let branchName: WorktreeBranchName
        switch WorktreeBranchName.validated(branch) {
        case .success(let value):
            branchName = value
        case .failure(let rejection):
            return .outcome(.refused(.invalidBranchName(.local(rejection))))
        }

        guard
            let destinationPath = WorktreeDestinationNaming.siblingPath(
                repositoryPath: mainWorktreePath,
                branchName: branchName
            )
        else {
            return .outcome(.refused(.emptyBranchSlug))
        }

        if FileManager.default.fileExists(atPath: destinationPath.path) {
            return .outcome(.refused(.destinationExists(destinationPath)))
        }

        let destinationParent = destinationPath.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue
        else {
            return .outcome(.refused(.destinationParentMissing(destinationParent)))
        }

        let branches: [GitBranchSnapshot]
        do {
            branches = try await client.branches(for: discovery.repositoryPath)
            guard !branches.contains(where: { $0.name == branchName.rawValue }) else {
                return .outcome(.refused(.branchAlreadyExists(branchName.rawValue)))
            }
        } catch {
            return .outcome(.failed(WorktreeOperationErrorMapper.readFailure(error)))
        }

        return .ready(
            PreparedWorktreeCreation(
                branchName: branchName,
                sourceWorktreePath: discovery.sourceWorktreePath,
                repositoryPath: discovery.repositoryPath,
                destinationPath: destinationPath,
                branches: branches
            ))
    }

}

struct PreparedWorktreeCreation {
    let branchName: WorktreeBranchName
    let sourceWorktreePath: URL
    let repositoryPath: URL
    let destinationPath: URL
    let branches: [GitBranchSnapshot]
}

enum WorktreeCreationPreparation {
    case ready(PreparedWorktreeCreation)
    case outcome(WorktreeOperationOutcome)
}
