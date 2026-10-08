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
    case refused(WorktreeOperationRefusal)
    case failed(WorktreeOperationFailure)
}

package struct WorktreeCreatedSummary: Sendable, Equatable {
    package let operation: WorktreeOperationKind
    package let branch: String
    package let path: URL
    package let repository: URL
    package let materialization: WorktreeCreatedMaterialization

    package var largeFiles: GitLargeFileFill? { materialization.largeFiles }

    package init(
        operation: WorktreeOperationKind,
        branch: String,
        path: URL,
        repository: URL,
        materialization: WorktreeCreatedMaterialization
    ) {
        self.operation = operation
        self.branch = branch
        self.path = path
        self.repository = repository
        self.materialization = materialization
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
    /// Interim until the branch resolver and the reset fork land: a request form the runner
    /// can't build yet, named by its flags, refused instead of creating the wrong worktree.
    case creationFormUnsupported(String)
    case destinationExists(URL)
    case destinationParentMissing(URL)
    case unsupportedRepositoryLayout(URL)
    case forkUnavailable(GitWorktreeForkRejectionReason, source: WorktreeCreateSource)
    case unsupportedWorkingState(GitWorktreeWorkingStateRefusal)
}

package struct WorktreeOperationFailure: Sendable, Equatable {
    package let failure: WorktreeFailureKind
    package let leftovers: WorktreeLeftoverStatus

    package init(failure: WorktreeFailureKind, leftovers: WorktreeLeftoverStatus) {
        self.failure = failure
        self.leftovers = leftovers
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

    package init(kind: GitWorktreeForkResidueKind, location: String, base: WorktreeLeftoverBase) {
        self.kind = kind
        self.location = location
        self.base = base
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
