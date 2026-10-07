import AgentStudioGit
import Foundation

package enum WorktreeOperationErrorMapper {
    private enum ForkFailure {
        case cancelled
        case gitFailure(GitDataPlaneError)
        case sourceChanged(relativePath: String, reason: GitWorktreeForkSourceRaceReason)
        case entryFailed(relativePath: String, reason: GitWorktreeForkEntryFailureReason, errorNumber: Int32?)
        case validationFailed(reason: GitWorktreeForkValidationFailureReason, relativePath: String?)
        case workingStateUnsupported(GitWorktreeWorkingStateRefusal)
        case cleanupIncomplete(primary: GitWorktreeForkError, residue: [GitWorktreeForkResidue])
    }

    private enum ForkFailureKindSource {
        case cancelled
        case gitFailure(GitDataPlaneError)
        case sourceChanged(relativePath: String, reason: GitWorktreeForkSourceRaceReason)
        case entryFailed(relativePath: String, reason: GitWorktreeForkEntryFailureReason, errorNumber: Int32?)
        case validationFailed(reason: GitWorktreeForkValidationFailureReason, relativePath: String?)
        case workingStateUnsupported(GitWorktreeWorkingStateRefusal)
        case rejectedAfterChange(GitWorktreeForkRejectionReason)
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
        case .locked:
            .locked
        case .lockHeld(let fact):
            .lockHeld(fact)
        case .lockUnidentified:
            .lockUnidentified
        case .permissionDenied(let path):
            .permissionDenied(path: path)
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
        case .sourceIndexUnreadable:
            .creationStopped(.sourceIndexUnreadable)
        case .sourceIndexUnsupported:
            .creationStopped(.sourceIndexUnsupported)
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
            .forkUnavailable(reason, source: .mainWorktree)
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
        case .workingStateUnsupported(let refusal):
            .refused(.unsupportedWorkingState(refusal))
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
        case .workingStateUnsupported(let refusal):
            return WorktreeOperationFailure(
                failure: forkFailureKind(.workingStateUnsupported(refusal)),
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
        case .workingStateUnsupported(let refusal):
            return FlattenedCleanupPrimary(failureKind: .workingStateUnsupported(refusal), residue: [])
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
        case .workingStateUnsupported(let refusal):
            .workingStateUnsupported(refusal)
        case .rejectedAfterChange(let reason):
            .rejectedAfterChange(reason)
        }
    }

    package static func lockedOperationFailure<Reason: Sendable>(
        _ error: GitLockedOperationFailure<Reason>,
        mapReason: (Reason) -> WorktreeFailureKind
    ) -> WorktreeOperationFailure {
        WorktreeOperationFailure(
            failure: mapReason(error.reason),
            leftovers: lockResidueStatus(error.lockResidue)
        )
    }

    package static func removalDirectoryEffect(for effect: GitRemovalEffect) -> WorktreeDirectoryEffect {
        switch effect {
        case .removed:
            .removed
        case .retained:
            .retained
        case .partial:
            .partial
        case .unknown:
            .unknown
        case .notRequested:
            .notApplicable
        }
    }

    package static func removalAdministrationEffect(for effect: GitRemovalEffect) -> WorktreeAdministrationEffect {
        switch effect {
        case .removed:
            .removed
        case .retained:
            .retained
        case .partial:
            .partial
        case .unknown:
            .unknown
        case .notRequested:
            .notApplicable
        }
    }

    package static func removalFailureKind(
        for failure: GitWorktreeRemovalFailureKind
    ) -> WorktreeRemovalFailureKindDocument {
        switch failure {
        case .pruneFailed(let code, let klass):
            .pruneFailed(code: code, klass: klass)
        case .observationFailed:
            .observationFailed
        case .removalIncomplete:
            .removalIncomplete
        }
    }

    private static func lockResidueStatus(_ residue: [URL]?) -> WorktreeLeftoverStatus {
        guard let residue else { return .unverified }
        guard !residue.isEmpty else { return .noLeftovers }
        return .incomplete(
            residue.map {
                WorktreeCleanupLeftover(
                    kind: .lockFile,
                    location: $0.path,
                    base: .repositoryGitDirectory
                )
            })
    }

    private static func cleanupLeftover(_ residue: GitWorktreeForkResidue) -> WorktreeCleanupLeftover {
        let base: WorktreeLeftoverBase
        switch residue.kind {
        case .destinationContent:
            base = .destination
        case .linkedWorktreeAdministration, .nestedAdministration:
            base = .repositoryGitDirectory
        case .lockFile:
            base = .repositoryGitDirectory
        case .createdBranch:
            base = .branchReference
        case .temporaryArtifact:
            base = .temporary
        }
        return WorktreeCleanupLeftover(kind: residue.kind, location: residue.location, base: base)
    }
}
