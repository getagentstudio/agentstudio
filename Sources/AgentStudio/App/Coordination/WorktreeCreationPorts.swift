import AgentStudioCommandBar
import AgentStudioCore
import AgentStudioGit
import Foundation

/// The SDK reads and writes worktree creation needs, narrowed so the coordinator can be
/// proven with a fake and the production path stays the SDK's serial writer lane.
protocol WorktreeCreationGitClient: Sendable {
    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeCreation
    /// Copy-on-write fork of the source's current files at its captured HEAD.
    func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError) -> GitForkWorktreeResult
}

/// Keeps a destination out of watched-folder publication while it is being built, then
/// rescans the one watched folder that owns it.
protocol WorktreePublicationHolding: AnyObject, Sendable {
    func holdPublication(of destination: URL) async -> WatchedFolderPublicationHoldID
    func releasePublicationHold(_ holdID: WatchedFolderPublicationHoldID) async
    /// Returns after the rescan result for `watchedPathID` has been applied and posted.
    func refreshWatchedFolder(_ watchedPathID: UUID, among watchedPaths: [WatchedPath]) async
}

struct LibGit2WorktreeCreationGitClient: WorktreeCreationGitClient {
    private let client: any AgentStudioGitLocalClient

    init(client: any AgentStudioGitLocalClient = LibGit2AgentStudioGitLocalClient()) {
        self.client = client
    }

    func createWorktree(_ request: GitCreateWorktreeRequest) async throws(GitDataPlaneError) -> GitWorktreeCreation {
        try await client.createWorktree(request)
    }

    func forkWorktree(_ request: GitForkWorktreeRequest) async throws(GitWorktreeForkError) -> GitForkWorktreeResult {
        try await client.forkWorktree(request)
    }
}

/// Lazy, repository-keyed branch listing. Each opened level owns one immutable snapshot;
/// concurrent requests in that opening share its query, and older responses cannot replace it.
actor WorktreeBranchListingCache: WorktreeBranchListing {
    typealias BranchQuery = @Sendable (URL) async throws -> [GitBranchSnapshot]

    private struct CachedListing {
        let openingToken: UUID
        let snapshots: [GitBranchSnapshot]
    }

    private struct InFlightListing {
        let openingToken: UUID
        let task: Task<[GitBranchSnapshot], Error>
    }

    private let query: BranchQuery
    private var cachedListingsByRepositoryId: [UUID: CachedListing] = [:]
    private var inFlightListingsByRepositoryId: [UUID: InFlightListing] = [:]

    init(
        query: @escaping BranchQuery = { repositoryPath in
            try await LibGit2AgentStudioGitLocalClient().branches(for: repositoryPath)
        }
    ) {
        self.query = query
    }

    func branchNames(
        forRepositoryId repositoryId: UUID,
        repositoryPath: URL,
        openingToken: UUID
    ) async throws -> [String] {
        if let cached = cachedListingsByRepositoryId[repositoryId],
            cached.openingToken == openingToken
        {
            return cached.snapshots.map(\.name)
        }
        cachedListingsByRepositoryId.removeValue(forKey: repositoryId)

        if let inFlight = inFlightListingsByRepositoryId[repositoryId],
            inFlight.openingToken == openingToken
        {
            return try await inFlight.task.value.map(\.name)
        }

        let query = query
        let task = Task { try await query(repositoryPath) }
        inFlightListingsByRepositoryId[repositoryId] = InFlightListing(
            openingToken: openingToken, task: task)
        do {
            let snapshots = try await task.value
            if inFlightListingsByRepositoryId[repositoryId]?.openingToken == openingToken {
                cachedListingsByRepositoryId[repositoryId] = CachedListing(
                    openingToken: openingToken, snapshots: snapshots)
                inFlightListingsByRepositoryId.removeValue(forKey: repositoryId)
            }
            return snapshots.map(\.name)
        } catch {
            if inFlightListingsByRepositoryId[repositoryId]?.openingToken == openingToken {
                inFlightListingsByRepositoryId.removeValue(forKey: repositoryId)
            }
            throw error
        }
    }
}

/// Live fork-eligibility port over the SDK's read-only `forkWorktreeEligibility` query:
/// host, volume, and File Provider facts only. The app never re-implements those rules;
/// it turns the SDK's reason into row copy, and `forkWorktree`'s own preflight rejection
/// stays authoritative after `.available`.
struct SDKWorktreeForkEligibilityChecker: WorktreeForkEligibilityChecking {
    typealias EligibilityQuery =
        @Sendable (
            _ sourceWorktreePath: URL,
            _ destinationPath: URL,
            _ materialization: GitWorktreeForkMaterialization
        ) async -> GitWorktreeForkEligibility

    /// The branch name is not typed yet when the source is chosen, so the query names a
    /// placeholder leaf in the directory every sibling destination shares.
    static let destinationProbeName = "agentstudio-fork-eligibility-probe"

    private let query: EligibilityQuery

    init(
        query: @escaping EligibilityQuery = { sourceWorktreePath, destinationPath, materialization in
            await LibGit2AgentStudioGitLocalClient().forkWorktreeEligibility(
                sourceWorktreePath: sourceWorktreePath,
                destinationPath: destinationPath,
                materialization: materialization
            )
        }
    ) {
        self.query = query
    }

    @concurrent
    func forkEligibility(sourceWorktreePath: URL, destinationDirectory: URL) async -> WorktreeForkEligibility {
        let destinationPath = destinationDirectory.appending(
            path: Self.destinationProbeName, directoryHint: .isDirectory)
        switch await query(sourceWorktreePath, destinationPath, .copyOnWrite) {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: WorktreeForkRejectionCopy.phrase(for: reason))
        }
    }
}
