import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge File surface reconciliation")
struct BridgeFileSurfaceReconcilerTests {
    @Test("same-basis reopen after suspension preserves unchanged-input budget")
    func sameBasisReopenAfterSuspensionPreservesUnchangedInputBudget() async throws {
        let reconciler = BridgeFileSurfaceReconciler(maximumUnchangedInputSupersessions: 1)
        let inputBasis = makeInputBasis()
        guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }
        guard
            case .start(let retryBeforeSuspension) = await reconciler.builderFinished(
                initialAttempt,
                outcome: .superseded(newerInputBasis: inputBasis)
            )
        else {
            Issue.record("Expected one unchanged-input retry before suspension")
            return
        }

        _ = await reconciler.builderCancelled(retryBeforeSuspension)
        guard case .start(let reopenedAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the same-basis File attempt to reopen after suspension")
            return
        }
        #expect(reopenedAttempt.inputGeneration == retryBeforeSuspension.inputGeneration)

        let reopenedOutcome = await reconciler.builderFinished(
            reopenedAttempt,
            outcome: .superseded(newerInputBasis: inputBasis)
        )
        #expect(
            reopenedOutcome
                == .failed(
                    .init(
                        disposition: .retryable,
                        phase: .build,
                        cause: .repeatedSupersession
                    )
                )
        )
    }

    @Test("two admitted same-basis replays after interruption can still certify")
    func twoAdmittedSameBasisReplaysAfterInterruptionCanCertify() async throws {
        let reconciler = BridgeFileSurfaceReconciler(maximumUnchangedInputSupersessions: 1)
        let inputBasis = makeInputBasis()
        guard case .start(let firstAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }
        let inputGeneration = firstAttempt.inputGeneration

        _ = await reconciler.builderCancelled(
            firstAttempt,
            isAutomaticRestartEligible: true
        )
        #expect(await reconciler.activeAttempt == nil)
        #expect(await reconciler.currentFailure == nil)
        #expect(await reconciler.currentInputGeneration == inputGeneration)

        guard case .start(let secondAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the first admitted replay to restart the interrupted attempt")
            return
        }
        #expect(secondAttempt.nonce != firstAttempt.nonce)
        #expect(secondAttempt.inputGeneration == inputGeneration)

        _ = await reconciler.builderCancelled(
            secondAttempt,
            isAutomaticRestartEligible: true
        )
        #expect(await reconciler.activeAttempt == nil)
        #expect(await reconciler.currentInputGeneration == inputGeneration)

        guard case .start(let thirdAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the second admitted replay to restart without a budget charge")
            return
        }
        #expect(thirdAttempt.nonce != secondAttempt.nonce)
        #expect(thirdAttempt.inputGeneration == inputGeneration)
        #expect(
            await reconciler.builderFinished(thirdAttempt, outcome: .built)
                == .completed(thirdAttempt)
        )
        #expect(await reconciler.currentFailure == nil)
        #expect(await reconciler.activeAttempt == nil)
        #expect(await reconciler.currentInputGeneration == inputGeneration)
    }

    @Test("consecutive uncertified interruptions are bounded and Retry restarts")
    func repeatedInterruptionsAreBoundedAndRetryRestarts() async throws {
        let reconciler = BridgeFileSurfaceReconciler()
        let inputBasis = makeInputBasis()
        let maximumAutomaticRestarts = AppPolicies.Bridge.fileSurfaceInterruptionRestartLimit
        #expect(maximumAutomaticRestarts == 3)
        guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }
        var currentAttempt = initialAttempt
        var publishedFailures = 0

        for interruptionIndex in 0...maximumAutomaticRestarts {
            let interruptionAction = await reconciler.builderCancelled(
                currentAttempt,
                phase: .delivery,
                isAutomaticRestartEligible: true
            )
            if case .failed = interruptionAction { publishedFailures += 1 }
            await reconciler.retirementCompleted(currentAttempt)

            if interruptionIndex < maximumAutomaticRestarts {
                #expect(interruptionAction == .rest)
                guard case .start(let restartedAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
                    Issue.record("Expected an admitted replay to restart below the interruption limit")
                    return
                }
                #expect(restartedAttempt.inputGeneration == initialAttempt.inputGeneration)
                #expect(restartedAttempt.nonce != currentAttempt.nonce)
                currentAttempt = restartedAttempt
                continue
            }

            let repeatedInterruptionFailure = BridgeFileSurfaceReconciler.Failure(
                disposition: .retryable,
                phase: .delivery,
                cause: .interruptedRepeatedly
            )
            #expect(interruptionAction == .failed(repeatedInterruptionFailure))
            #expect(await reconciler.currentFailure == repeatedInterruptionFailure)
            #expect(repeatedInterruptionFailure.refreshFailure.retryable)
            #expect(publishedFailures == 1)
            #expect(await reconciler.beginAttempt(inputBasis: inputBasis) == .rest)
            #expect(
                await reconciler.builderCancelled(
                    currentAttempt,
                    phase: .delivery,
                    isAutomaticRestartEligible: true
                ) == .rest
            )
            guard case .start(let retriedAttempt) = await reconciler.retry() else {
                Issue.record("Retry must restart after the interruption limit is reached")
                return
            }
            #expect(retriedAttempt.inputGeneration == initialAttempt.inputGeneration)
            #expect(retriedAttempt.nonce != currentAttempt.nonce)
            #expect(await reconciler.currentFailure == nil)
            #expect(
                await reconciler.builderCancelled(
                    retriedAttempt,
                    phase: .delivery,
                    isAutomaticRestartEligible: true
                ) == .rest
            )
            await reconciler.retirementCompleted(retriedAttempt)
            guard case .start = await reconciler.beginAttempt(inputBasis: inputBasis) else {
                Issue.record("Retry must reset the interruption count before the next replay")
                return
            }
        }
    }

    @Test("a certified File completion resets the interruption restart limit")
    func certifiedCompletionResetsInterruptionRestartLimit() async throws {
        let reconciler = BridgeFileSurfaceReconciler()
        let inputBasis = makeInputBasis()
        let maximumAutomaticRestarts = AppPolicies.Bridge.fileSurfaceInterruptionRestartLimit
        guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }
        var currentAttempt = initialAttempt

        for _ in 0..<maximumAutomaticRestarts {
            #expect(
                await reconciler.builderCancelled(
                    currentAttempt,
                    phase: .delivery,
                    isAutomaticRestartEligible: true
                ) == .rest
            )
            await reconciler.retirementCompleted(currentAttempt)
            guard case .start(let restartedAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
                Issue.record("Expected each admitted replay to restart below the limit")
                return
            }
            currentAttempt = restartedAttempt
        }

        #expect(await reconciler.builderFinished(currentAttempt, outcome: .built) == .completed(currentAttempt))
        guard case .start(let postCertificateAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected a subsequent File attempt after the certified completion")
            return
        }
        #expect(
            await reconciler.builderCancelled(
                postCertificateAttempt,
                phase: .delivery,
                isAutomaticRestartEligible: true
            ) == .rest
        )
        await reconciler.retirementCompleted(postCertificateAttempt)
        guard case .start = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("The interruption count should reset after the certified completion")
            return
        }
    }

    @Test("a material File basis change resets the interruption restart limit")
    func materialBasisChangeResetsInterruptionRestartLimit() async throws {
        let reconciler = BridgeFileSurfaceReconciler()
        let initialBasis = makeInputBasis()
        let maximumAutomaticRestarts = AppPolicies.Bridge.fileSurfaceInterruptionRestartLimit
        guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: initialBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }
        var currentAttempt = initialAttempt

        for _ in 0..<maximumAutomaticRestarts {
            #expect(
                await reconciler.builderCancelled(
                    currentAttempt,
                    phase: .delivery,
                    isAutomaticRestartEligible: true
                ) == .rest
            )
            await reconciler.retirementCompleted(currentAttempt)
            guard case .start(let restartedAttempt) = await reconciler.beginAttempt(inputBasis: initialBasis) else {
                Issue.record("Expected each admitted replay to restart below the limit")
                return
            }
            currentAttempt = restartedAttempt
        }

        let changedBasis = makeInputBasis(rootPathToken: "root-b")
        guard
            case .restart(let retiringAttempt, let changedAttempt) = await reconciler.inputsChanged(
                to: changedBasis
            )
        else {
            Issue.record("A material basis change must start a new File attempt")
            return
        }
        await reconciler.retirementCompleted(retiringAttempt)
        #expect(
            await reconciler.builderCancelled(
                changedAttempt,
                phase: .delivery,
                isAutomaticRestartEligible: true
            ) == .rest
        )
        await reconciler.retirementCompleted(changedAttempt)
        guard case .start(let replayAttempt) = await reconciler.beginAttempt(inputBasis: changedBasis) else {
            Issue.record("The changed basis must get a fresh interruption restart limit")
            return
        }
        #expect(replayAttempt.inputGeneration == changedAttempt.inputGeneration)
    }

    @Test("each material basis change renews the attempt budget")
    func eachMaterialBasisChangeRenewsTheAttemptBudget() async throws {
        let initialBasis = makeInputBasis()
        let changedBases = [
            makeInputBasis(rootPathToken: "root-b"),
            makeInputBasis(filter: .object(["kind": .string("changes")])),
            makeInputBasis(canonicalPathScope: ["Sources"]),
            makeInputBasis(worktreeId: "worktree-b"),
        ]

        for changedBasis in changedBases {
            let reconciler = BridgeFileSurfaceReconciler(maximumUnchangedInputSupersessions: 1)
            guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: initialBasis) else {
                Issue.record("Expected the initial File attempt to start")
                continue
            }
            guard
                case .start(let retryBeforeChange) = await reconciler.builderFinished(
                    initialAttempt,
                    outcome: .superseded(newerInputBasis: initialBasis)
                )
            else {
                Issue.record("Expected one unchanged-input retry before the material basis change")
                continue
            }

            guard
                case .restart(let retiringAttempt, let changedAttempt) = await reconciler.inputsChanged(
                    to: changedBasis
                )
            else {
                Issue.record("Expected a material File basis change to restart the live attempt")
                continue
            }
            #expect(retiringAttempt == retryBeforeChange)
            #expect(changedAttempt.inputGeneration == retryBeforeChange.inputGeneration + 1)

            guard
                case .start(let renewedRetry) = await reconciler.builderFinished(
                    changedAttempt,
                    outcome: .superseded(newerInputBasis: changedBasis)
                )
            else {
                Issue.record("A material basis change must renew the unchanged-input retry budget")
                continue
            }
            #expect(renewedRetry.inputGeneration == changedAttempt.inputGeneration)
            #expect(await reconciler.inputsChanged(to: changedBasis) == .rest)
        }
    }

    @Test("explicit Retry renews a bounded same-basis attempt")
    func explicitRetryRenewsBoundedSameBasisAttempt() async throws {
        let reconciler = BridgeFileSurfaceReconciler(maximumUnchangedInputSupersessions: 1)
        let inputBasis = makeInputBasis()
        guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: inputBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }
        guard
            case .start(let unchangedInputRetry) = await reconciler.builderFinished(
                initialAttempt,
                outcome: .superseded(newerInputBasis: inputBasis)
            )
        else {
            Issue.record("Expected one unchanged-input retry")
            return
        }
        guard
            case .failed(let repeatedSupersessionFailure) = await reconciler.builderFinished(
                unchangedInputRetry,
                outcome: .superseded(newerInputBasis: inputBasis)
            )
        else {
            Issue.record("Repeated supersession at unchanged input must end in a bounded failure")
            return
        }
        #expect(repeatedSupersessionFailure.disposition == .retryable)
        #expect(repeatedSupersessionFailure.cause == .repeatedSupersession)
        #expect(await reconciler.beginAttempt(inputBasis: inputBasis) == .rest)

        guard case .start(let retryAttempt) = await reconciler.retry() else {
            Issue.record("Explicit Retry must renew the unchanged-input attempt budget")
            return
        }
        #expect(retryAttempt.inputGeneration == unchangedInputRetry.inputGeneration)
        #expect(retryAttempt.nonce != unchangedInputRetry.nonce)
    }

    @Test("late success from a superseded attempt leaves the newer failure current")
    func lateSuccessFromSupersededAttemptLeavesNewerFailureCurrent() async throws {
        let reconciler = BridgeFileSurfaceReconciler()
        let initialBasis = makeInputBasis()
        guard case .start(let initialAttempt) = await reconciler.beginAttempt(inputBasis: initialBasis) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }

        let changedBasis = makeInputBasis(rootPathToken: "root-b")
        guard
            case .restart(let retiringAttempt, let currentAttempt) = await reconciler.inputsChanged(
                to: changedBasis
            )
        else {
            Issue.record("A material basis change must supersede the initial attempt")
            return
        }
        #expect(retiringAttempt == initialAttempt)

        let newerFailure = BridgeFileSurfaceReconciler.Failure(
            disposition: .permanent,
            phase: .build,
            cause: .accessRefused
        )
        #expect(
            await reconciler.builderFinished(
                currentAttempt,
                outcome: .failed(newerFailure)
            ) == .failed(newerFailure)
        )

        #expect(await reconciler.builderFinished(initialAttempt, outcome: .built) == .rest)
        #expect(await reconciler.currentFailure == newerFailure)
    }

    @Test("a current progress expiry becomes a retryable surface failure")
    func currentProgressExpiryBecomesRetryableSurfaceFailure() async throws {
        let reconciler = BridgeFileSurfaceReconciler()
        guard case .start(let attempt) = await reconciler.beginAttempt(inputBasis: makeInputBasis()) else {
            Issue.record("Expected the initial File attempt to start")
            return
        }

        let progressFailure = BridgeFileSurfaceReconciler.Failure(
            disposition: .retryable,
            phase: .build,
            cause: .progressExpired
        )
        let action = await reconciler.builderFinished(
            attempt,
            outcome: .failed(progressFailure)
        )

        #expect(action == .failed(progressFailure))
        #expect(await reconciler.currentFailure == progressFailure)
        #expect(progressFailure.refreshFailure.failureKind == .fileSourceUnavailable)
        #expect(progressFailure.refreshFailure.retryable)
    }

    private func makeInputBasis(
        rootPathToken: String = "root-a",
        filter: BridgeProductJSONValue = .object(["kind": .string("none")]),
        canonicalPathScope: [String] = [],
        repoId: String = "repo-a",
        worktreeId: String = "worktree-a",
        cwdScope: String? = nil,
        includeStatuses: Bool = false
    ) -> BridgeFileSurfaceInputBasis {
        BridgeFileSurfaceInputBasis(
            root: .init(rootPathToken: rootPathToken),
            filter: filter,
            canonicalPathScope: canonicalPathScope,
            membership: .init(
                repoId: repoId,
                worktreeId: worktreeId,
                cwdScope: cwdScope,
                includeStatuses: includeStatuses
            )
        )
    }
}
