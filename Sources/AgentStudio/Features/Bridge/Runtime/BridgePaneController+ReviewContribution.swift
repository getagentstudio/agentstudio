import AgentStudioCore
import Foundation

private enum BridgePaneReviewComparisonTargetAdmission {
    case superseded
    case committed(BridgePaneStateMutationResult)
}

@MainActor
extension BridgePaneController {
    func handleCommittedProductReviewComparisonUpdate(
        _ request: BridgeProductReviewComparisonUpdateRequest,
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePaneReviewComparisonEffectDisposition {
        guard productAdmission.withValidAdmission({ true }) == true else { return .rejected }
        guard let contributionTargetCommit
        else {
            return failCurrentReviewComparisonTarget(
                request.target,
                workerDerivationEpoch: workerDerivationEpoch,
                productAdmission: productAdmission,
                failureKind: "targetCommitUnavailable",
                retryable: true
            )
        }
        guard
            let targetAdmission = productAdmission.withValidAdmission({
                refreshAdmissionCoordinator.workAdmissionSource.withCurrentReviewComparisonIntent(
                    workerDerivationEpoch: workerDerivationEpoch,
                    productAdmission: productAdmission
                ) {
                    BridgePaneReviewComparisonTargetAdmission.committed(
                        contributionTargetCommit(request.target)
                    )
                } ?? .superseded
            })
        else { return .rejected }
        let mutationResult: BridgePaneStateMutationResult
        switch targetAdmission {
        case .superseded:
            return .superseded
        case .committed(let committedResult):
            mutationResult = committedResult
        }
        guard productAdmission.withValidAdmission({ true }) == true else { return .rejected }
        let canonicalState: BridgePaneState
        let replacedLineage: Bool
        switch mutationResult {
        case .applied(let state):
            canonicalState = state
            replacedLineage = true
        case .unchanged(let state):
            canonicalState = state
            replacedLineage = false
        case .paneMissing, .notBridgePane, .notWorkspaceSource:
            reviewGitRefreshSeedHolder.retire()
            return .rejected
        }
        guard case .workspace(_, let canonicalBaseline) = canonicalState.source,
            canonicalBaseline?.contributionTarget == request.target
        else {
            return failCurrentReviewComparisonTarget(
                request.target,
                workerDerivationEpoch: workerDerivationEpoch,
                productAdmission: productAdmission,
                failureKind: "targetMismatch",
                retryable: false
            )
        }

        guard
            productAdmission.withValidAdmission({
                bridgePaneState = canonicalState
                reviewComparisonTargetProjection.update(state: canonicalState)
                return true
            }) == true
        else { return .rejected }
        guard replacedLineage else { return .applied }
        reviewGitRefreshSeedHolder.retire()
        let reviewGeneration = nextReviewGeneration.next()
        nextReviewGeneration = reviewGeneration
        pendingComparisonReviewGeneration = reviewGeneration
        guard
            productAdmission.withValidAdmission({
                refreshAdmissionCoordinator.beginReviewComparisonAttempt(
                    activeTarget: request.target,
                    reviewGeneration: reviewGeneration.rawValue
                )
                return true
            }) == true
        else { return .rejected }
        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = scheduleProductPresentationPublication()
        pendingReviewPackageBuildReasons.insert(.productResync)
        refreshAdmissionCoordinator.advanceAuthority(for: .review)
        retireActiveReviewRefreshTask()
        scheduleRetainedReviewPackageBuildIfPossible(admissionInput: .explicitTarget)
        return .applied
    }

    private func failCurrentReviewComparisonTarget(
        _ target: WorkspaceReviewContributionTarget,
        workerDerivationEpoch: Int,
        productAdmission: BridgeProductAdmissionContext,
        failureKind: String,
        retryable: Bool
    ) -> BridgePaneReviewComparisonEffectDisposition {
        let didFailCurrentTarget =
            productAdmission.withValidAdmission {
                refreshAdmissionCoordinator.workAdmissionSource.withCurrentReviewComparisonIntent(
                    workerDerivationEpoch: workerDerivationEpoch,
                    productAdmission: productAdmission
                ) {
                    let reviewGeneration = nextReviewGeneration.next()
                    nextReviewGeneration = reviewGeneration
                    refreshAdmissionCoordinator.beginAndFailReviewComparisonAttempt(
                        activeTarget: target,
                        reviewGeneration: reviewGeneration.rawValue,
                        failureKind: failureKind,
                        retryable: retryable
                    )
                    return true
                } ?? false
            } ?? false
        guard didFailCurrentTarget else { return .superseded }
        reviewGitRefreshSeedHolder.retire()
        refreshAdmissionCoordinator.advanceAuthority(for: .review)
        retireActiveReviewRefreshTask()
        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = scheduleProductPresentationPublication()
        return .applied
    }

    func adoptInitialContributionTargetIfEligible(
        reset: ReviewPackageLoadReset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws {
        guard case .workspace(_, let baseline) = bridgePaneState.source else { return }
        let resolvedDefaultTarget = try await resolveAndPublishReviewComparisonDefaultTargetIfCurrent(
            reset: reset,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission
        )
        guard baseline == nil else { return }
        guard
            let resolvedDefaultTarget,
            let initialContributionTargetCommit
        else { return }
        let mutationResult = initialContributionTargetCommit(
            .originDefaultBranch(
                remoteName: resolvedDefaultTarget.remoteName,
                branchName: resolvedDefaultTarget.branchName,
                basis: .commonCommit
            )
        )
        guard
            isReviewPackageLoadCurrent(
                reset: reset,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return }
        switch mutationResult {
        case .applied(let canonicalState), .unchanged(let canonicalState):
            bridgePaneState = canonicalState
            reviewComparisonTargetProjection.update(state: canonicalState)
            guard case .workspace(_, let canonicalBaseline) = canonicalState.source,
                let activeTarget = canonicalBaseline?.contributionTarget
            else { return }
            refreshAdmissionCoordinator.beginReviewComparisonAttempt(
                activeTarget: activeTarget,
                reviewGeneration: reset.reviewGeneration.rawValue
            )
            // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
            _ = scheduleProductPresentationPublication()
        case .paneMissing, .notBridgePane, .notWorkspaceSource:
            break
        }
    }

    func resolveAndPublishReviewComparisonDefaultTargetIfCurrent(
        reset: ReviewPackageLoadReset,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        guard
            isReviewPackageLoadCurrent(
                reset: reset,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return nil }
        let resolvedDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
        do {
            resolvedDefaultTarget = try await reviewSourceProvider.resolveReviewDefaultTarget()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            resolvedDefaultTarget = nil
        }
        guard
            isReviewPackageLoadCurrent(
                reset: reset,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission
            )
        else { return nil }
        refreshAdmissionCoordinator.publishReviewComparisonDefaultTarget(resolvedDefaultTarget)
        // fire-and-forget: publication joins the presentation tail; closeAndDrain awaits it
        _ = scheduleProductPresentationPublication()
        return resolvedDefaultTarget
    }

    func captureContributionResolutionContext() -> BridgeReviewContributionResolutionContext {
        .init(
            source: bridgePaneState.source, provider: reviewSourceProvider, reviewedSubjectLabel: reviewedSubjectLabel)
    }

    @concurrent
    nonisolated static func resolveContributionRequestIfNeeded(
        _ request: BridgeReviewPipelineRequest,
        context: BridgeReviewContributionResolutionContext,
        progress: BridgeReviewConstructionProgressSink
    ) async throws -> BridgeReviewPipelineRequest {
        guard case .workspace(_, let baseline) = context.source else { return request }
        guard let baseline else {
            throw BridgeProviderFailure.providerFailed(
                message: "Contribution target selection required"
            )
        }
        guard let symbolicTarget = baseline.contributionTarget else { return request }
        let capture = try await context.provider.captureContributionComparison(
            BridgeContributionComparisonRequest(
                symbolicTarget: symbolicTarget,
                baseEndpoint: request.baseEndpoint,
                headEndpoint: request.headEndpoint,
                reviewGenerationValue: request.reviewGeneration.rawValue,
                reviewAttemptAuthorityGeneration: request.reviewAttemptAuthorityGeneration,
                gitRefreshScope: request.gitRefreshScope,
                gitRefreshSeed: request.gitRefreshSeed
            )
        )
        let resolved = try BridgeResolvedContributionRequestBuilder.build(
            request: request,
            symbolicTarget: symbolicTarget,
            capture: capture,
            reviewedSubjectLabel: context.reviewedSubjectLabel
        )
        progress(.contributionResolved)
        return resolved
    }

    private var reviewedSubjectLabel: String? {
        normalizedReviewedSubject(runtime.metadata.facets.worktreeName)
            ?? normalizedReviewedSubject(runtime.metadata.checkoutRef)
    }

    private func normalizedReviewedSubject(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty
        else { return nil }
        return normalized
    }
}

struct BridgeReviewContributionResolutionContext: Sendable {
    let source: BridgePaneSource?
    let provider: any BridgeReviewSourceProvider
    let reviewedSubjectLabel: String?
}
