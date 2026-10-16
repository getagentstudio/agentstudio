import Foundation

/// The command bar needs local branch names, while the App owner retains SDK snapshots.
package protocol WorktreeBranchListing: Sendable {
    func branchNames(
        forRepositoryId repositoryId: UUID,
        repositoryPath: URL,
        openingToken: UUID
    ) async throws -> [String]
}
