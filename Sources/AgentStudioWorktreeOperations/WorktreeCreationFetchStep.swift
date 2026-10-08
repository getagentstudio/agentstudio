import AgentStudioGit
import Foundation

package enum WorktreeCreationFetchSkipReason: String, Codable, Sendable {
    case noFetchFlag
    /// The remote the name needs (origin, for a name without a remote prefix) isn't configured.
    case noRemote
    /// `--changes-only` always starts at the source's HEAD commit.
    case notNeeded
}

/// The one branch `new` refreshes before it picks its branch (LR30), or why it refreshes nothing.
package enum WorktreeCreationFetchTarget: Sendable, Equatable {
    case branch(remoteName: String, branchName: String)
    case skip(WorktreeCreationFetchSkipReason)
}

/// What `new`'s refresh did (LR30). A separate type from LR5's `WorktreeFetchStatus`, so the
/// `list`, `remove` and `prune` outputs are unchanged.
package enum WorktreeCreationFetchStatus: Encodable, Sendable, Equatable {
    case fetched(remoteName: String, branchName: String, commit: String, lockResidue: [String]?)
    /// The remote said it doesn't have the branch: nothing was fetched, and a remote-tracking ref
    /// still on disk for it counts as absent.
    case notOnRemote(remoteName: String, branchName: String)
    case skipped(WorktreeCreationFetchSkipReason)
    /// The question or the fetch failed; `new` continues with the refs on disk.
    case failed(remoteName: String, branchName: String, failure: WorktreeFetchFailure)

    private enum CodingKeys: String, CodingKey {
        case remote
        case branch
        case status
        case commit
        case reason
        case lock
        case lockResidue
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fetched(let remoteName, let branchName, let commit, let lockResidue):
            try container.encode(remoteName, forKey: .remote)
            try container.encode(branchName, forKey: .branch)
            try container.encode("fetched", forKey: .status)
            try container.encode(commit, forKey: .commit)
            if let lockResidue, !lockResidue.isEmpty {
                try container.encode(lockResidue, forKey: .lockResidue)
            }
        case .notOnRemote(let remoteName, let branchName):
            try container.encode(remoteName, forKey: .remote)
            try container.encode(branchName, forKey: .branch)
            try container.encode("notOnRemote", forKey: .status)
        case .skipped(let reason):
            try container.encodeNil(forKey: .remote)
            try container.encodeNil(forKey: .branch)
            try container.encode("skipped", forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .failed(let remoteName, let branchName, let failure):
            try container.encode(remoteName, forKey: .remote)
            try container.encode(branchName, forKey: .branch)
            try container.encode("failed", forKey: .status)
            try container.encode(failure.reason, forKey: .reason)
            try container.encodeIfPresent(failure.lock, forKey: .lock)
            if let lockResidue = failure.lockResidue, !lockResidue.isEmpty {
                try container.encode(lockResidue, forKey: .lockResidue)
            }
        }
    }

    /// The remote whose branch counts as absent even if a remote-tracking ref for it is on disk.
    func confirmsAbsent(remoteName: String, branchName: String) -> Bool {
        self == .notOnRemote(remoteName: remoteName, branchName: branchName)
    }
}

/// LR30: asks the remote whether the branch exists, fetches it alone only when it does (no tags,
/// no pruning, no submodules), and never stops `new`: a failed question or fetch is reported and
/// creation continues with the refs on disk.
package struct WorktreeCreationFetchStep: Sendable {
    private let remoteClient: any AgentStudioGitRemoteClient

    package init(remoteClient: any AgentStudioGitRemoteClient = SystemGitRemoteClient()) {
        self.remoteClient = remoteClient
    }

    @concurrent
    package func run(repositoryPath: URL, target: WorktreeCreationFetchTarget) async -> WorktreeCreationFetchStatus {
        let remoteName: String
        let branchName: String
        switch target {
        case .skip(let reason):
            return .skipped(reason)
        case .branch(let targetRemoteName, let targetBranchName):
            remoteName = targetRemoteName
            branchName = targetBranchName
        }

        let presence: GitRemoteBranchPresence
        do throws(GitDataPlaneError) {
            presence = try await remoteClient.probeRemoteBranch(
                GitRemoteBranchProbeRequest(
                    repositoryPath: repositoryPath,
                    remoteName: remoteName,
                    branchName: branchName
                ))
        } catch {
            return .failed(
                remoteName: remoteName,
                branchName: branchName,
                failure: WorktreeFetchFailureMapper.failure(for: error)
            )
        }
        guard case .present(let probedCommit) = presence else {
            return .notOnRemote(remoteName: remoteName, branchName: branchName)
        }

        do throws(GitLockedOperationFailure<GitDataPlaneError>) {
            let fetched = try await remoteClient.fetch(
                GitFetchRequest(repositoryPath: repositoryPath, remoteName: remoteName, branchName: branchName))
            return .fetched(
                remoteName: remoteName,
                branchName: branchName,
                commit: fetched.fetchedCommit ?? probedCommit,
                lockResidue: WorktreeFetchFailureMapper.nonEmptyPaths(fetched.lockResidue)
            )
        } catch {
            return .failed(
                remoteName: remoteName,
                branchName: branchName,
                failure: WorktreeFetchFailureMapper.failure(for: error)
            )
        }
    }
}
