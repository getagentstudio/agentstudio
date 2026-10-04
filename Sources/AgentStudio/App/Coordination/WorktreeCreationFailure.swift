import AgentStudioCore
import AgentStudioGit
import Foundation

/// Why a worktree was not created. Every case is shown to the user once, in a sheet on
/// the workspace window; nothing here is retried.
enum WorktreeCreationFailure: Error, Equatable, Sendable {
    case sourceUnavailable
    case noDefaultBranch
    case destinationRejected(WorktreeDestinationRejection)
    case alreadyInProgress(destination: URL)
    case gitFailure(GitDataPlaneError)
    case forkFailure(GitWorktreeForkError)
}

struct WorktreeCreationFailureMessage: Equatable, Sendable {
    let title: String
    let detail: String
}

extension WorktreeCreationFailure {
    var message: WorktreeCreationFailureMessage {
        switch self {
        case .forkFailure:
            WorktreeCreationFailureMessage(title: "Worktree Fork not created", detail: detail)
        case .sourceUnavailable, .noDefaultBranch, .destinationRejected, .alreadyInProgress, .gitFailure:
            WorktreeCreationFailureMessage(title: "Worktree not created", detail: detail)
        }
    }

    private var detail: String {
        switch self {
        case .sourceUnavailable:
            "The repository or source worktree is no longer available."
        case .noDefaultBranch:
            "This repository has no origin/HEAD, local main, or local master branch."
        case .destinationRejected(.emptyFolderSlug):
            "The branch name has no characters that can name a folder."
        case .destinationRejected(.undiscoverableDestination(let destination)):
            "\(destination.path) is not inside a watched folder, so it would never appear in the sidebar."
        case .destinationRejected(.beyondScannerDepth(let destination, let maximumDepth)):
            "\(destination.path) is more than \(maximumDepth) folders below its watched folder, so it would never appear in the sidebar."
        case .destinationRejected(.destinationExists(let destination)):
            "\(destination.path) already exists."
        case .alreadyInProgress(let destination):
            "A worktree is already being created at \(destination.path)."
        case .gitFailure(let error):
            Self.gitFailureDetail(error)
        case .forkFailure(let error):
            Self.forkFailureDetail(error)
        }
    }

    static func gitFailureDetail(_ error: GitDataPlaneError) -> String {
        switch error {
        case .lockHeld(let fact):
            "Git is using the repository lock at \(fact.path.path)."
        case .lockUnidentified:
            "Git could not identify the repository lock."
        case .permissionDenied(let path):
            if let path {
                "Git does not have permission to access \(path.path)."
            } else {
                "Git does not have permission to access the repository."
            }
        case .headUnavailable:
            "The source worktree has no commit to branch from."
        case .repositoryNotFound(let path):
            "No Git repository was found at \(path.path)."
        case .revisionUnavailable(let target):
            "The start commit \(target.name) could not be resolved."
        case .locked(let message):
            "The repository is locked: \(message)"
        case .libgit2Failure(_, _, let message):
            "Git reported: \(message)"
        case .unsupported(let message):
            message
        case .worktreeNotFound, .worktreeNotPrunable, .unsafeWorktreeRemoval, .contentTooLarge,
            .pathEscapesRepository, .requiredObjectNotFound, .noSharedHistory, .multipleBestMergeBases,
            .processFailed, .processTimedOut, .processCancelled, .processOutputTooLarge,
            .remoteRefTransactionIndeterminate:
            "Git could not create the worktree (\(error))."
        }
    }

    /// A preflight rejection changed nothing; every later failure rolled back unless the
    /// SDK reports residue, which is listed so the user can clean it up.
    static func forkFailureDetail(_ error: GitWorktreeForkError) -> String {
        switch error {
        case .workingStateUnsupported(let refusal):
            "Nothing was changed: \(workingStateUnsupportedCause(refusal))"
        case .rejected(let reason):
            "Nothing was changed: \(WorktreeForkRejectionCopy.phrase(for: reason))."
        case .gitFailure(let gitError):
            "\(gitFailureDetail(gitError)) The fork was rolled back."
        case .sourceChanged(let relativePath, _):
            "The source changed while it was being copied (\(relativePath)). The fork was rolled back."
        case .entryFailed(let relativePath, let reason, _):
            "\(relativePath) could not be copied (\(reason.rawValue)). The fork was rolled back."
        case .cancelled:
            "The fork was cancelled and rolled back."
        case .validationFailed(let reason, _):
            "The forked worktree failed validation (\(reason.rawValue)). The fork was rolled back."
        case .cleanupIncomplete(let primary, let residue):
            "\(forkFailureCause(primary)) Cleanup is incomplete; left behind: "
                + residue.map { "\($0.kind.rawValue) \($0.location)" }.joined(separator: ", ") + "."
        }
    }

    /// The primary failure of an incomplete rollback, without claiming the rollback finished.
    private static func workingStateUnsupportedCause(_ refusal: GitWorktreeWorkingStateRefusal) -> String {
        let location = refusal.relativePath.map { " at \($0)" } ?? ""
        return "The source has unsupported Git state (\(refusal.reason.rawValue))\(location)."
    }

    private static func forkFailureCause(_ error: GitWorktreeForkError) -> String {
        switch error {
        case .workingStateUnsupported(let refusal):
            workingStateUnsupportedCause(refusal)
        case .rejected(let reason):
            "The fork was rejected: \(WorktreeForkRejectionCopy.phrase(for: reason))."
        case .gitFailure(let gitError):
            gitFailureDetail(gitError)
        case .sourceChanged(let relativePath, _):
            "The source changed while it was being copied (\(relativePath))."
        case .entryFailed(let relativePath, let reason, _):
            "\(relativePath) could not be copied (\(reason.rawValue))."
        case .cancelled:
            "The fork was cancelled."
        case .validationFailed(let reason, _):
            "The forked worktree failed validation (\(reason.rawValue))."
        case .cleanupIncomplete(let primary, _):
            forkFailureCause(primary)
        }
    }
}

/// User-facing phrases for the SDK's fork preflight reasons. The eligibility fallback row
/// reuses them, so a reason reads the same before and after the user presses Return.
enum WorktreeForkRejectionCopy {
    static func phrase(for reason: GitWorktreeForkRejectionReason) -> String {
        switch reason {
        case .clientCapabilityUnavailable: "this Git client cannot fork worktrees"
        case .unsupportedOperatingSystem: "this macOS version cannot fork worktrees"
        case .sourceFilesystemNotAPFS: "the source is not on an APFS volume"
        case .destinationFilesystemNotAPFS: "the destination is not on an APFS volume"
        case .crossDevice: "the destination is on a different volume than the source"
        case .cloneCapabilityUnavailable: "the volume cannot clone files"
        case .administrativeStoreOnDifferentDevice: "the repository's Git data is on a different volume"
        case .sourceNotWorktreeRoot: "the source is not the root of a worktree"
        case .sourceHeadUnavailable: "the source worktree has no commit to fork from"
        case .invalidDestinationPath: "the destination path is not valid"
        case .destinationParentMissing: "the destination folder's parent does not exist"
        case .destinationExists: "the destination already exists"
        case .overlappingRoots: "the destination overlaps the source"
        case .linkedWorktreeNameInUse: "a worktree with that folder name is already registered"
        case .invalidBranchName: "the branch name is not valid"
        case .branchNotFound: "the branch does not exist"
        case .branchAlreadyExists: "a branch with that name already exists"
        case .branchNotAtCapturedHead: "the branch does not point at the source's HEAD"
        case .branchCheckedOut: "the branch is checked out in another worktree"
        case .fileProviderManagedLocation: "the location is managed by iCloud Drive or another File Provider"
        case .datalessContent: "some files have not been downloaded to this Mac"
        }
    }
}
