import AgentStudioGit
import Foundation

package enum WorktreeOperationErrorMapper {
    private enum ForkFailure {
        case cancelled
        case gitFailure(GitDataPlaneError)
        case sourceChanged(relativePath: String, reason: GitWorktreeForkSourceRaceReason)
        case entryFailed(relativePath: String, reason: GitWorktreeForkEntryFailureReason, errorNumber: Int32?)
        case validationFailed(reason: GitWorktreeForkValidationFailureReason, relativePath: String?)
        case cleanupIncomplete(primary: GitWorktreeForkError, residue: [GitWorktreeForkResidue])
    }

    private enum ForkFailureKindSource {
        case cancelled
        case gitFailure(GitDataPlaneError)
        case sourceChanged(relativePath: String, reason: GitWorktreeForkSourceRaceReason)
        case entryFailed(relativePath: String, reason: GitWorktreeForkEntryFailureReason, errorNumber: Int32?)
        case validationFailed(reason: GitWorktreeForkValidationFailureReason, relativePath: String?)
        case rejectedAfterChange(GitWorktreeForkRejectionReason)
        /// Only changes-only forks refuse on working state; this CLI forks copy-on-write.
        case workingStateUnsupported
    }

    private struct FlattenedCleanupPrimary {
        let failureKind: ForkFailureKindSource
        let residue: [GitWorktreeForkResidue]
    }

    package static func readFailure(_ error: GitDataPlaneError) -> WorktreeOperationFailure {
        WorktreeOperationFailure(failure: .readFailed(gitErrorKind(for: error)), leftovers: .notNeeded)
    }

    package static func createFailure(_ error: GitDataPlaneError) -> WorktreeOperationFailure {
        WorktreeOperationFailure(failure: .createFailed(gitErrorKind(for: error)), leftovers: .unverified)
    }

    package static func gitErrorKind(for error: GitDataPlaneError) -> WorktreeGitErrorKind {
        switch error {
        case .repositoryNotFound:
            .repositoryNotFound
        case .worktreeNotFound:
            .worktreeNotFound
        case .locked, .lockHeld, .lockUnidentified:
            .locked
        // Raised by worktree removal primitives, which new/fork/list never call.
        case .permissionDenied:
            .libgit2Failure
        case .worktreeNotPrunable:
            .worktreeNotPrunable
        case .unsafeWorktreeRemoval:
            .unsafeWorktreeRemoval
        case .contentTooLarge:
            .contentTooLarge
        case .pathEscapesRepository:
            .pathEscapesRepository
        case .revisionUnavailable:
            .revisionUnavailable
        case .headUnavailable:
            .headUnavailable
        case .requiredObjectNotFound:
            .requiredObjectNotFound
        case .noSharedHistory:
            .noSharedHistory
        case .multipleBestMergeBases:
            .multipleBestMergeBases
        case .processFailed:
            .processFailed
        case .processTimedOut:
            .processTimedOut
        case .processCancelled:
            .processCancelled
        case .processOutputTooLarge:
            .processOutputTooLarge
        case .remoteRefTransactionIndeterminate:
            .remoteRefTransactionIndeterminate
        case .libgit2Failure:
            .libgit2Failure
        case .unsupported:
            .unsupported
        }
    }

    package static func forkRejection(
        _ reason: GitWorktreeForkRejectionReason,
        destinationPath: URL,
        branchName: String
    ) -> WorktreeOperationRefusal {
        switch reason {
        case .destinationExists:
            .destinationExists(destinationPath)
        case .destinationParentMissing:
            .destinationParentMissing(destinationPath.deletingLastPathComponent())
        case .invalidBranchName:
            .invalidBranchName(.rejectedByGit)
        case .branchAlreadyExists:
            .branchAlreadyExists(branchName)
        case .clientCapabilityUnavailable,
            .unsupportedOperatingSystem,
            .sourceFilesystemNotAPFS,
            .destinationFilesystemNotAPFS,
            .crossDevice,
            .cloneCapabilityUnavailable,
            .administrativeStoreOnDifferentDevice,
            .sourceNotWorktreeRoot,
            .sourceHeadUnavailable,
            .invalidDestinationPath,
            .overlappingRoots,
            .linkedWorktreeNameInUse,
            .branchNotFound,
            .branchNotAtCapturedHead,
            .branchCheckedOut,
            .fileProviderManagedLocation,
            .datalessContent:
            .forkUnavailable(reason)
        }
    }

    package static func forkOutcome(
        _ error: GitWorktreeForkError,
        destinationPath: URL,
        branchName: String
    ) -> WorktreeOperationOutcome {
        switch error {
        case .rejected(let reason):
            .refused(forkRejection(reason, destinationPath: destinationPath, branchName: branchName))
        case .cancelled:
            .failed(forkFailure(.cancelled))
        case .gitFailure(let gitError):
            .failed(forkFailure(.gitFailure(gitError)))
        case .sourceChanged(let relativePath, let reason):
            .failed(forkFailure(.sourceChanged(relativePath: relativePath, reason: reason)))
        case .entryFailed(let relativePath, let reason, let errorNumber):
            .failed(forkFailure(.entryFailed(relativePath: relativePath, reason: reason, errorNumber: errorNumber)))
        case .validationFailed(let reason, let relativePath):
            .failed(forkFailure(.validationFailed(reason: reason, relativePath: relativePath)))
        case .cleanupIncomplete(let primary, let residue):
            .failed(forkFailure(.cleanupIncomplete(primary: primary, residue: residue)))
        case .workingStateUnsupported:
            .failed(
                WorktreeOperationFailure(failure: forkFailureKind(.workingStateUnsupported), leftovers: .noLeftovers))
        }
    }

    private static func forkFailure(_ failure: ForkFailure) -> WorktreeOperationFailure {
        switch failure {
        case .cancelled:
            return WorktreeOperationFailure(failure: forkFailureKind(.cancelled), leftovers: .noLeftovers)
        case .gitFailure(let gitError):
            return WorktreeOperationFailure(
                failure: forkFailureKind(.gitFailure(gitError)),
                leftovers: .noLeftovers
            )
        case .sourceChanged(let relativePath, let reason):
            return WorktreeOperationFailure(
                failure: forkFailureKind(.sourceChanged(relativePath: relativePath, reason: reason)),
                leftovers: .noLeftovers
            )
        case .entryFailed(let relativePath, let reason, let errorNumber):
            return WorktreeOperationFailure(
                failure: forkFailureKind(
                    .entryFailed(relativePath: relativePath, reason: reason, errorNumber: errorNumber)),
                leftovers: .noLeftovers
            )
        case .validationFailed(let reason, let relativePath):
            return WorktreeOperationFailure(
                failure: forkFailureKind(.validationFailed(reason: reason, relativePath: relativePath)),
                leftovers: .noLeftovers
            )
        case .cleanupIncomplete(let primary, let residue):
            let flattenedPrimary = flattenCleanupPrimary(primary)
            return WorktreeOperationFailure(
                failure: forkFailureKind(flattenedPrimary.failureKind),
                leftovers: .incomplete((flattenedPrimary.residue + residue).map(cleanupLeftover))
            )
        }
    }

    private static func flattenCleanupPrimary(_ error: GitWorktreeForkError) -> FlattenedCleanupPrimary {
        switch error {
        case .rejected(let reason):
            return FlattenedCleanupPrimary(failureKind: .rejectedAfterChange(reason), residue: [])
        case .cleanupIncomplete(let primary, let residue):
            let flattenedPrimary = flattenCleanupPrimary(primary)
            return FlattenedCleanupPrimary(
                failureKind: flattenedPrimary.failureKind,
                residue: flattenedPrimary.residue + residue
            )
        case .cancelled:
            return FlattenedCleanupPrimary(failureKind: .cancelled, residue: [])
        case .workingStateUnsupported:
            return FlattenedCleanupPrimary(failureKind: .workingStateUnsupported, residue: [])
        case .gitFailure(let gitError):
            return FlattenedCleanupPrimary(failureKind: .gitFailure(gitError), residue: [])
        case .sourceChanged(let relativePath, let reason):
            return FlattenedCleanupPrimary(
                failureKind: .sourceChanged(relativePath: relativePath, reason: reason),
                residue: []
            )
        case .entryFailed(let relativePath, let reason, let errorNumber):
            return FlattenedCleanupPrimary(
                failureKind: .entryFailed(relativePath: relativePath, reason: reason, errorNumber: errorNumber),
                residue: []
            )
        case .validationFailed(let reason, let relativePath):
            return FlattenedCleanupPrimary(
                failureKind: .validationFailed(reason: reason, relativePath: relativePath),
                residue: []
            )
        }
    }

    private static func forkFailureKind(_ source: ForkFailureKindSource) -> WorktreeFailureKind {
        switch source {
        case .gitFailure(let gitError):
            .forkGitFailed(gitErrorKind(for: gitError))
        case .sourceChanged(let relativePath, let reason):
            .sourceChanged(relativePath: relativePath, reason: reason)
        case .entryFailed(let relativePath, let reason, let errorNumber):
            .entryFailed(relativePath: relativePath, reason: reason, errno: errorNumber)
        case .cancelled:
            .cancelled
        case .validationFailed(let reason, let relativePath):
            .validationFailed(reason: reason, relativePath: relativePath)
        case .rejectedAfterChange(let reason):
            .rejectedAfterChange(reason)
        case .workingStateUnsupported:
            .forkGitFailed(.unsupported)
        }
    }

    private static func cleanupLeftover(_ residue: GitWorktreeForkResidue) -> WorktreeCleanupLeftover {
        let base: WorktreeLeftoverBase
        switch residue.kind {
        case .destinationContent:
            base = .destination
        case .linkedWorktreeAdministration, .nestedAdministration:
            base = .repositoryGitDirectory
        case .createdBranch:
            base = .branchReference
        case .temporaryArtifact:
            base = .temporary
        case .lockFile:
            base = .repositoryGitDirectory
        }
        return WorktreeCleanupLeftover(kind: residue.kind, location: residue.location, base: base)
    }
}
