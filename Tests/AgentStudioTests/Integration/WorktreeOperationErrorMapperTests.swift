import AgentStudioGit
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree operation SDK error mapping")
struct WorktreeOperationErrorMapperTests {
    @Test("all GitDataPlaneError cases project to a closed, redacted kind")
    func projectsEveryGitDataPlaneErrorCase() {
        let repositoryPath = URL(fileURLWithPath: "/tmp/worktree-error-mapping")
        let worktreeID = GitWorktreeID(rawValue: "repository|worktree:fixture")
        let processFailure = GitRemoteProcessFailure(
            executable: "git",
            redactedArguments: ["status"],
            exitCode: 1,
            redactedStderr: "private detail"
        )
        let errors: [(WorktreeGitErrorKind, GitDataPlaneError)] = [
            (.repositoryNotFound, .repositoryNotFound(path: repositoryPath)),
            (.worktreeNotFound, .worktreeNotFound(id: worktreeID)),
            (.locked, .locked(message: "private detail")),
            (
                .lockHeld,
                .lockHeld(
                    GitLockFact(
                        path: repositoryPath.appending(path: "refs/heads/main.lock"),
                        resource: .reference(name: "refs/heads/main")
                    ))
            ),
            (.lockUnidentified, .lockUnidentified(.packedRefs)),
            (.permissionDenied, .permissionDenied(path: repositoryPath)),
            (.worktreeNotPrunable, .worktreeNotPrunable(id: worktreeID, reason: .liveWorktree)),
            (.unsafeWorktreeRemoval, .unsafeWorktreeRemoval(reason: .dirtyTrackedChanges)),
            (.contentTooLarge, .contentTooLarge(path: "large.bin", sizeBytes: 2, maxSizeBytes: 1)),
            (.pathEscapesRepository, .pathEscapesRepository(path: "../outside")),
            (.revisionUnavailable, .revisionUnavailable(target: GitRevisionTarget.named("missing-ref"))),
            (.headUnavailable, .headUnavailable),
            (.requiredObjectNotFound, .requiredObjectNotFound(oid: "missing-oid")),
            (.noSharedHistory, .noSharedHistory(targetOID: "target", headOID: "head")),
            (.multipleBestMergeBases, .multipleBestMergeBases(targetOID: "target", headOID: "head", count: 2)),
            (.processFailed, .processFailed(processFailure)),
            (.processTimedOut, .processTimedOut(processFailure)),
            (.processCancelled, .processCancelled(processFailure)),
            (.processOutputTooLarge, .processOutputTooLarge(stream: .stderr, sizeBytes: 2, maxSizeBytes: 1)),
            (.remoteRefTransactionIndeterminate, .remoteRefTransactionIndeterminate(message: "private detail")),
            (.libgit2Failure, .libgit2Failure(code: 1, klass: 2, message: "private detail")),
            (.unsupported, .unsupported(message: "private detail")),
        ]

        #expect(errors.count == 22)
        for (expectedKind, error) in errors {
            #expect(WorktreeOperationErrorMapper.gitErrorKind(for: error) == expectedKind)
        }
    }

    @Test("read and create errors report their distinct cleanup knowledge")
    func distinguishesReadAndCreateFailureLeftovers() {
        let gitError = GitDataPlaneError.libgit2Failure(code: 9, klass: 3, message: "private detail")

        #expect(
            WorktreeOperationErrorMapper.readFailure(gitError)
                == WorktreeOperationFailure(failure: .readFailed(.libgit2Failure), leftovers: .notNeeded))
        #expect(
            WorktreeOperationErrorMapper.createFailure(gitError)
                == WorktreeOperationFailure(failure: .createFailed(.libgit2Failure), leftovers: .unverified))
    }

    @Test("every typed fork rejection maps to its refusal without losing the SDK reason")
    func mapsEveryForkRejectionReason() {
        let destination = URL(fileURLWithPath: "/tmp/worktree-error-mapping/repo.feature")
        let parent = destination.deletingLastPathComponent()
        let branch = "feature/example"

        for reason in GitWorktreeForkRejectionReason.allCases {
            let expectedRefusal: WorktreeOperationRefusal
            switch reason {
            case .destinationExists:
                expectedRefusal = .destinationExists(destination)
            case .destinationParentMissing:
                expectedRefusal = .destinationParentMissing(parent)
            case .invalidBranchName:
                expectedRefusal = .invalidBranchName(.rejectedByGit)
            case .branchAlreadyExists:
                expectedRefusal = .branchAlreadyExists(branch)
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
                expectedRefusal = .forkUnavailable(reason)
            }

            #expect(
                WorktreeOperationErrorMapper.forkRejection(
                    reason,
                    destinationPath: destination,
                    branchName: branch
                ) == expectedRefusal)
            #expect(
                WorktreeOperationErrorMapper.forkOutcome(
                    .rejected(reason: reason),
                    destinationPath: destination,
                    branchName: branch
                ) == .refused(expectedRefusal))
        }
    }

    @Test("working-state fork refusals retain their reason and repository-relative path")
    func mapsWorkingStateForkRefusals() {
        let refusal = GitWorktreeWorkingStateRefusal(reason: .attributesChanged, relativePath: ".gitattributes")
        let destination = URL(fileURLWithPath: "/tmp/worktree-error-mapping/repo.feature")

        #expect(
            WorktreeOperationErrorMapper.forkOutcome(
                .workingStateUnsupported(refusal),
                destinationPath: destination,
                branchName: "feature/example"
            ) == .refused(.unsupportedWorkingState(refusal)))
    }

    @Test("compensated fork failures say no leftovers and preserve typed details")
    func mapsCompensatedForkFailures() {
        let errors: [(GitWorktreeForkError, WorktreeFailureKind)] = [
            (.cancelled, .cancelled),
            (.gitFailure(.unsupported(message: "private detail")), .forkGitFailed(.unsupported)),
            (
                .sourceChanged(relativePath: "tracked.txt", reason: .entryIdentityChanged),
                .sourceChanged(relativePath: "tracked.txt", reason: .entryIdentityChanged)
            ),
            (
                .entryFailed(relativePath: "nested/file.txt", reason: .unreadableEntry, errorNumber: 13),
                .entryFailed(relativePath: "nested/file.txt", reason: .unreadableEntry, errno: 13)
            ),
            (
                .validationFailed(reason: .entryCountMismatch, relativePath: "nested"),
                .validationFailed(reason: .entryCountMismatch, relativePath: "nested")
            ),
        ]
        let destination = URL(fileURLWithPath: "/tmp/worktree-error-mapping/repo.feature")

        for (error, expectedFailure) in errors {
            #expect(
                WorktreeOperationErrorMapper.forkOutcome(
                    error,
                    destinationPath: destination,
                    branchName: "feature/example"
                ) == .failed(WorktreeOperationFailure(failure: expectedFailure, leftovers: .noLeftovers)))
        }
    }

    @Test("cleanup residue kinds keep their relative base and primary failure")
    func mapsEveryCleanupResidueKind() {
        let residueLocations: [(GitWorktreeForkResidueKind, String, WorktreeLeftoverBase)] = [
            (.destinationContent, "nested/file.txt", .destination),
            (.linkedWorktreeAdministration, "worktrees/repo.feature", .repositoryGitDirectory),
            (.nestedAdministration, "modules/nested/worktrees/repo", .repositoryGitDirectory),
            (.createdBranch, "refs/heads/feature/example", .branchReference),
            (.temporaryArtifact, "worktrees/.temporary-artifact", .temporary),
            (.lockFile, "worktrees/repo/index.lock", .repositoryGitDirectory),
        ]

        for (kind, location, base) in residueLocations {
            let residue = GitWorktreeForkResidue(kind: kind, location: location)
            let error = GitWorktreeForkError.cleanupIncomplete(primary: .cancelled, residue: [residue])
            #expect(
                WorktreeOperationErrorMapper.forkOutcome(
                    error,
                    destinationPath: URL(fileURLWithPath: "/tmp/worktree-error-mapping/repo.feature"),
                    branchName: "feature/example"
                )
                    == .failed(
                        WorktreeOperationFailure(
                            failure: .cancelled,
                            leftovers: .incomplete([
                                WorktreeCleanupLeftover(kind: kind, location: location, base: base)
                            ])
                        )))
        }
    }

    @Test("nested cleanup flattens residues and rejected cleanup primaries remain failures")
    func mapsNestedCleanupAndRejectedPrimary() {
        let destination = URL(fileURLWithPath: "/tmp/worktree-error-mapping/repo.feature")
        let branch = "feature/example"
        let innerResidue = GitWorktreeForkResidue(kind: .destinationContent, location: "inner.txt")
        let outerResidue = GitWorktreeForkResidue(kind: .createdBranch, location: "refs/heads/feature/example")
        let nestedCleanup = GitWorktreeForkError.cleanupIncomplete(
            primary: .cleanupIncomplete(primary: .cancelled, residue: [innerResidue]),
            residue: [outerResidue]
        )

        #expect(
            WorktreeOperationErrorMapper.forkOutcome(
                nestedCleanup,
                destinationPath: destination,
                branchName: branch
            )
                == .failed(
                    WorktreeOperationFailure(
                        failure: .cancelled,
                        leftovers: .incomplete([
                            WorktreeCleanupLeftover(
                                kind: .destinationContent, location: "inner.txt", base: .destination),
                            WorktreeCleanupLeftover(
                                kind: .createdBranch,
                                location: "refs/heads/feature/example",
                                base: .branchReference
                            ),
                        ])
                    )
                ))

        let rejectedPrimary = GitWorktreeForkError.cleanupIncomplete(
            primary: .rejected(reason: .branchAlreadyExists),
            residue: [outerResidue]
        )
        #expect(
            WorktreeOperationErrorMapper.forkOutcome(
                rejectedPrimary,
                destinationPath: destination,
                branchName: branch
            )
                == .failed(
                    WorktreeOperationFailure(
                        failure: .rejectedAfterChange(.branchAlreadyExists),
                        leftovers: .incomplete([
                            WorktreeCleanupLeftover(
                                kind: .createdBranch,
                                location: "refs/heads/feature/example",
                                base: .branchReference
                            )
                        ])
                    )
                ))
    }

    @Test("cleanup preserves a working-state primary and lock-file residue")
    func mapsWorkingStateCleanupWithLockResidue() {
        let refusal = GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "tracked.bin")
        let lockResidue = GitWorktreeForkResidue(kind: .lockFile, location: "worktrees/repo/index.lock")
        let error = GitWorktreeForkError.cleanupIncomplete(
            primary: .workingStateUnsupported(refusal),
            residue: [lockResidue]
        )

        #expect(
            WorktreeOperationErrorMapper.forkOutcome(
                error,
                destinationPath: URL(fileURLWithPath: "/tmp/worktree-error-mapping/repo.feature"),
                branchName: "feature/example"
            )
                == .failed(
                    WorktreeOperationFailure(
                        failure: .workingStateUnsupported(refusal),
                        leftovers: .incomplete([
                            WorktreeCleanupLeftover(
                                kind: .lockFile,
                                location: "worktrees/repo/index.lock",
                                base: .repositoryGitDirectory
                            )
                        ])
                    )
                ))
    }

    @Test("locked operation residue distinguishes unobserved, empty, and retained states")
    func mapsLockedOperationFailureResidue() {
        let repositoryPath = URL(fileURLWithPath: "/tmp/worktree-error-mapping")
        let error = GitDataPlaneError.lockUnidentified(.packedRefs)
        let unobserved = GitLockedOperationFailure<GitDataPlaneError>(reason: error, lockResidue: nil)
        let noneRetained = GitLockedOperationFailure<GitDataPlaneError>(reason: error, lockResidue: [])
        let retainedPath = repositoryPath.appending(path: "packed-refs.lock")
        let retained = GitLockedOperationFailure<GitDataPlaneError>(reason: error, lockResidue: [retainedPath])
        let mapReason: (GitDataPlaneError) -> WorktreeFailureKind = {
            .createFailed(WorktreeOperationErrorMapper.gitErrorKind(for: $0))
        }

        #expect(
            WorktreeOperationErrorMapper.lockedOperationFailure(unobserved, mapReason: mapReason)
                == WorktreeOperationFailure(failure: .createFailed(.lockUnidentified), leftovers: .unverified))
        #expect(
            WorktreeOperationErrorMapper.lockedOperationFailure(noneRetained, mapReason: mapReason)
                == WorktreeOperationFailure(failure: .createFailed(.lockUnidentified), leftovers: .noLeftovers))
        #expect(
            WorktreeOperationErrorMapper.lockedOperationFailure(retained, mapReason: mapReason)
                == WorktreeOperationFailure(
                    failure: .createFailed(.lockUnidentified),
                    leftovers: .incomplete([
                        WorktreeCleanupLeftover(
                            kind: .lockFile,
                            location: retainedPath.path,
                            base: .repositoryGitDirectory
                        )
                    ])
                ))
    }

    @Test("SDK removal effects map every effect and failure to the leaf documents")
    func mapsSDKRemovalEffects() {
        let effectCases: [(GitRemovalEffect, WorktreeDirectoryEffect, WorktreeAdministrationEffect)] = [
            (.removed, .removed, .removed),
            (.retained, .retained, .retained),
            (.partial, .partial, .partial),
            (.unknown, .unknown, .unknown),
            (.notRequested, .notApplicable, .notApplicable),
        ]
        for (sdkEffect, directory, administration) in effectCases {
            #expect(WorktreeOperationErrorMapper.removalDirectoryEffect(for: sdkEffect) == directory)
            #expect(WorktreeOperationErrorMapper.removalAdministrationEffect(for: sdkEffect) == administration)
        }

        let failureCases: [(GitWorktreeRemovalFailureKind, WorktreeRemovalFailureKindDocument)] = [
            (.pruneFailed(code: 1, klass: 2), .pruneFailed(code: 1, klass: 2)),
            (.observationFailed, .observationFailed),
            (.removalIncomplete, .removalIncomplete),
        ]
        for (sdkFailure, documentFailure) in failureCases {
            #expect(WorktreeOperationErrorMapper.removalFailureKind(for: sdkFailure) == documentFailure)
        }
    }
}
