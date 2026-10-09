import AgentStudioGit
import Foundation

package enum WorktreeOperationRequest: Sendable, Equatable {
    case create(WorktreeCreateRequest)
    case list(
        start: URL,
        callerDirectory: URL?,
        targets: [String],
        fetchPolicy: WorktreeFetchPolicy
    )
    case remove(WorktreeRemovalRequest)
    case prune(WorktreePruneRequest)
}

package enum WorktreeBranchNameProblem: Sendable, Equatable {
    case local(WorktreeBranchNameRejection)
    case rejectedByGit
}

package enum WorktreeOperationKind: String, Sendable, Equatable {
    case new
}

package enum WorktreeOperationOutcome: Sendable, Equatable {
    case created(WorktreeCreatedSummary)
    case listed(WorktreeListingSummary)
    case fetchingReadFailure(WorktreeFetchingReadFailure)
    case removal(WorktreeRemovalReport)
    case pruned(WorktreePruneSummary)
    /// `creationFetch` is set once `new`'s fetch has run: a refusal after it still reports it (LR30).
    case refused(WorktreeOperationRefusal, creationFetch: WorktreeCreationFetchStatus? = nil)
    case failed(WorktreeOperationFailure)

    /// The same outcome reporting `new`'s fetch, for a refusal or failure that came after it.
    func carryingCreationFetch(_ fetch: WorktreeCreationFetchStatus) -> Self {
        switch self {
        case .refused(let refusal, _):
            .refused(refusal, creationFetch: fetch)
        case .failed(let failure):
            .failed(
                WorktreeOperationFailure(failure: failure.failure, leftovers: failure.leftovers, creationFetch: fetch))
        case .created, .listed, .fetchingReadFailure, .removal, .pruned:
            self
        }
    }
}

package struct WorktreeCreatedSummary: Sendable, Equatable {
    package let operation: WorktreeOperationKind
    package let branch: WorktreeCreatedBranch
    package let path: URL
    package let repository: URL
    package let materialization: WorktreeCreatedMaterialization
    package let start: WorktreeCreationStart
    package let fetch: WorktreeCreationFetchStatus

    package var largeFiles: GitLargeFileFill? { materialization.largeFiles }

    package init(
        operation: WorktreeOperationKind,
        branch: WorktreeCreatedBranch,
        path: URL,
        repository: URL,
        materialization: WorktreeCreatedMaterialization,
        start: WorktreeCreationStart,
        fetch: WorktreeCreationFetchStatus
    ) {
        self.operation = operation
        self.branch = branch
        self.path = path
        self.repository = repository
        self.materialization = materialization
        self.start = start
        self.fetch = fetch
    }
}

package enum WorktreeOperationRefusal: Sendable, Equatable {
    case creationStopped(WorktreeCreationStop)
    case notInRepository(URL)
    case notInWorktree(URL)
    case noDefaultBranch
    case invalidBranchName(WorktreeBranchNameProblem)
    case emptyBranchSlug
    case startBranchNotFound(String)
    case destinationExists(URL)
    case destinationParentMissing(URL)
    case unsupportedRepositoryLayout(URL)
    /// `offersChangesOnly` only when `--changes-only` would be a valid continuation: `--from`, no
    /// `--from-branch`, and a new branch at the source's HEAD.
    case forkUnavailable(GitWorktreeForkRejectionReason, offersChangesOnly: Bool)
    case unsupportedWorkingState(GitWorktreeWorkingStateRefusal)
}

package struct WorktreeOperationFailure: Sendable, Equatable {
    package let failure: WorktreeFailureKind
    package let leftovers: WorktreeLeftoverStatus
    /// Set once `new`'s fetch has run (LR30); the fork's own cleanup evidence stays in `leftovers`.
    package let creationFetch: WorktreeCreationFetchStatus?

    package init(
        failure: WorktreeFailureKind,
        leftovers: WorktreeLeftoverStatus,
        creationFetch: WorktreeCreationFetchStatus? = nil
    ) {
        self.failure = failure
        self.leftovers = leftovers
        self.creationFetch = creationFetch
    }
}

package enum WorktreeFailureKind: Sendable, Equatable {
    case readFailed(WorktreeGitErrorKind)
    case createFailed(WorktreeGitErrorKind)
    case forkGitFailed(WorktreeGitErrorKind)
    case sourceChanged(relativePath: String, reason: GitWorktreeForkSourceRaceReason)
    case entryFailed(relativePath: String, reason: GitWorktreeForkEntryFailureReason, errno: Int32?)
    case validationFailed(reason: GitWorktreeForkValidationFailureReason, relativePath: String?)
    case workingStateUnsupported(GitWorktreeWorkingStateRefusal)
    case cancelled
    case rejectedAfterChange(GitWorktreeForkRejectionReason)
    /// The branch was taken by the worktree at `path` at the attach, and rollback is incomplete.
    case branchCheckedOutAfterChange(path: String)
    /// A plain checkout fast-forwarded `branch` and couldn't confirm moving it back (D22); the SDK reports this
    /// in place of the creation's own error.
    case branchMoveNotUndone(branch: String, move: WorktreeBranchMove)
}

/// A fast-forward a failed creation made and couldn't confirm undone: from `fromCommit` to `toCommit`. It is the
/// attempted move, not a verified final position; read the branch for that.
package struct WorktreeBranchMove: Sendable, Equatable {
    package let fromCommit: String
    package let toCommit: String

    package init(fromCommit: String, toCommit: String) {
        self.fromCommit = fromCommit
        self.toCommit = toCommit
    }
}

package enum WorktreeLeftoverStatus: Sendable, Equatable {
    case notNeeded
    case noLeftovers
    case unverified
    case incomplete([WorktreeCleanupLeftover])
}

package struct WorktreeCleanupLeftover: Sendable, Equatable {
    package let kind: GitWorktreeForkResidueKind
    package let location: String
    package let base: WorktreeLeftoverBase
    /// For a `branchMoveNotUndone` leftover whose move `new` planned: both commits of that fast-forward.
    package let branchMove: WorktreeBranchMove?

    package init(
        kind: GitWorktreeForkResidueKind,
        location: String,
        base: WorktreeLeftoverBase,
        branchMove: WorktreeBranchMove? = nil
    ) {
        self.kind = kind
        self.location = location
        self.base = base
        self.branchMove = branchMove
    }
}

package enum WorktreeLeftoverBase: Sendable, Equatable {
    case destination
    case repositoryGitDirectory
    case branchReference
    case temporary
}

package enum WorktreeGitErrorKind: Sendable, Equatable {
    case repositoryNotFound
    case worktreeNotFound
    case locked
    case lockHeld(GitLockFact)
    case lockUnidentified
    case permissionDenied(path: URL?)
    case worktreeNotPrunable
    case unsafeWorktreeRemoval
    case contentTooLarge
    case pathEscapesRepository
    case revisionUnavailable
    case headUnavailable
    case requiredObjectNotFound
    case noSharedHistory
    case multipleBestMergeBases
    case processFailed
    case processTimedOut
    case processCancelled
    case processOutputTooLarge
    case remoteRefTransactionIndeterminate
    case libgit2Failure
    case unsupported
    case branchMoved
    case branchCheckedOut
    case branchMoveNotUndone

    package var name: String {
        switch self {
        case .repositoryNotFound:
            "repositoryNotFound"
        case .worktreeNotFound:
            "worktreeNotFound"
        case .locked:
            "locked"
        case .lockHeld:
            "lockHeld"
        case .lockUnidentified:
            "lockUnidentified"
        case .permissionDenied:
            "permissionDenied"
        case .worktreeNotPrunable:
            "worktreeNotPrunable"
        case .unsafeWorktreeRemoval:
            "unsafeWorktreeRemoval"
        case .contentTooLarge:
            "contentTooLarge"
        case .pathEscapesRepository:
            "pathEscapesRepository"
        case .revisionUnavailable:
            "revisionUnavailable"
        case .headUnavailable:
            "headUnavailable"
        case .requiredObjectNotFound:
            "requiredObjectNotFound"
        case .noSharedHistory:
            "noSharedHistory"
        case .multipleBestMergeBases:
            "multipleBestMergeBases"
        case .processFailed:
            "processFailed"
        case .processTimedOut:
            "processTimedOut"
        case .processCancelled:
            "processCancelled"
        case .processOutputTooLarge:
            "processOutputTooLarge"
        case .remoteRefTransactionIndeterminate:
            "remoteRefTransactionIndeterminate"
        case .libgit2Failure:
            "libgit2Failure"
        case .unsupported:
            "unsupported"
        case .branchMoved:
            "branchMoved"
        case .branchCheckedOut:
            "branchCheckedOut"
        case .branchMoveNotUndone:
            "branchMoveNotUndone"
        }
    }

    package var lockFact: GitLockFact? {
        guard case .lockHeld(let fact) = self else { return nil }
        return fact
    }

    package var permissionPath: URL? {
        guard case .permissionDenied(let path) = self else { return nil }
        return path
    }
}
