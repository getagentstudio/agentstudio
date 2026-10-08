import AgentStudioCore
import AgentStudioGit
import AgentStudioInfrastructure
import CryptoKit
import Foundation

private let libGit2NotFoundErrorCode: Int32 = -3

extension AgentStudioGitBridgeReviewDataClient {
    func loadGitCommitRangeCount(
        _ request: GitCommitRangeCountRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitCommitRangeCount {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(domain: "commit-range-count", request: request),
                freshnessKey: freshnessKey
            ) {
                try await client.countCommitRange(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitDiffImpactSummary(
        _ request: GitDiffImpactSummaryRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitDiffImpactSummary {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(domain: "diff-impact-summary", request: request),
                freshnessKey: freshnessKey
            ) {
                try await client.summarizeDiffImpact(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitReviewDefaultTarget(
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitReviewComparisonBranchTarget? {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(
                    domain: "review-comparison-default-target",
                    request: repositoryPath
                ),
                freshnessKey: freshnessKey
            ) {
                try await client.resolveReviewDefaultTarget(for: self.repositoryPath)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitReviewComparisonTargets(
        _ request: GitReviewComparisonTargetCaptureRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitReviewComparisonTargetCapture {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .selectedVisibleContent,
                coalescingKey: try gitReadCoalescingKey(
                    domain: "review-comparison-targets",
                    request: request
                ),
                freshnessKey: freshnessKey
            ) {
                try await client.captureReviewComparisonTargets(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitContributionDiff(
        _ request: GitContributionDiffRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitContributionDiffResult {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReviewReadCoalescingKey(
                    domain: "contribution-diff",
                    repositoryPath: request.repositoryPath,
                    target: request.target
                ),
                freshnessKey: freshnessKey
            ) {
                try await client.contributionDiff(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitDirectReviewComparison(
        _ request: GitDirectReviewComparisonRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitDirectReviewComparisonResult {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReviewReadCoalescingKey(
                    domain: "direct-review-comparison",
                    repositoryPath: request.repositoryPath,
                    target: request.target
                ),
                freshnessKey: freshnessKey
            ) {
                try await client.directReviewComparison(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitResolvedRevision(
        _ request: GitRevisionResolutionRequest,
        unavailableEndpointId: String,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitResolvedRevision {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(domain: "resolve-revision", request: request),
                freshnessKey: freshnessKey
            ) {
                try await client.resolveRevision(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitDataPlaneError.libgit2Failure(let code, _, _)
            where code == libGit2NotFoundErrorCode
        {
            throw BridgeProviderFailure.unavailableEndpoint(endpointId: unavailableEndpointId)
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitDiff(
        _ request: GitDiffRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitDiffSnapshot {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(domain: "diff", request: request),
                freshnessKey: freshnessKey
            ) {
                try await client.diff(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitStatus(
        _ options: GitStatusOptions,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitStatusFactsSnapshot {
        let client = self.client
        let statusPhysicalGate = self.statusPhysicalGate
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(domain: "status", request: options),
                freshnessKey: freshnessKey
            ) {
                try await statusPhysicalGate.withPhysicalRead(for: self.repositoryPath) {
                    try await client.statusFacts(for: self.repositoryPath, options: options).facts
                }
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch AgentStudioGitStatusPhysicalGateError.capacityExceeded,
            AgentStudioGitStatusPhysicalGateError.sameRootAlreadyInFlight
        {
            throw BridgeProviderFailure.sourceCapacityDeferred
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitTree(
        _ request: GitTreeReadRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> GitTreeSnapshot {
        let client = self.client
        do {
            return try await scheduledGitRead(
                operationClass: .reviewMetadata,
                coalescingKey: try gitReadCoalescingKey(domain: "tree", request: request),
                freshnessKey: freshnessKey
            ) {
                try await client.readTree(request)
            }
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitContent(
        _ request: GitContentRequest,
        handle: BridgeContentHandle?,
        freshnessKey: BridgeGitReadFreshnessKey,
        physicalReadLease: (@Sendable () throws -> BridgeSharedReviewContentBacking.ReadLease)? = nil
    ) async throws -> GitContentPayload {
        do {
            return try await loadGitContentPayload(
                request,
                operationClass: .selectedVisibleContent,
                freshnessKey: freshnessKey,
                physicalReadLease: physicalReadLease
            )
        } catch BridgeGitReadSchedulerError.timedOut {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.timeoutMessage)
        } catch BridgeGitReadSchedulerError.capacityReached {
            throw BridgeProviderFailure.providerFailed(message: BridgeGitReadFailure.capacityMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BridgeSharedReviewContentBackingError {
            throw error
        } catch let error as GitDataPlaneError {
            throw bridgeFailure(for: error, handle: handle)
        } catch {
            throw BridgeProviderFailure.providerFailed(message: unexpectedGitDataPlaneErrorMessage(error))
        }
    }

    func loadGitContentPayload(
        _ request: GitContentRequest,
        operationClass: BridgeGitReadOperationClass = .reviewMetadata,
        freshnessKey: BridgeGitReadFreshnessKey,
        physicalReadLease: (@Sendable () throws -> BridgeSharedReviewContentBacking.ReadLease)? = nil
    ) async throws -> GitContentPayload {
        let client = self.client
        return try await scheduledGitRead(
            operationClass: operationClass,
            coalescingKey: try gitReadCoalescingKey(domain: "content", request: request),
            freshnessKey: freshnessKey
        ) {
            let readLease = try physicalReadLease?()
            defer { readLease?.settle() }
            return try await client.content(request)
        }
    }

    private func scheduledGitRead<ReturnValue: Sendable>(
        operationClass: BridgeGitReadOperationClass,
        coalescingKey: BridgeGitReadCoalescingKey,
        freshnessKey: BridgeGitReadFreshnessKey,
        operation: @escaping @Sendable () async throws -> ReturnValue
    ) async throws -> ReturnValue {
        try await gitReadContext.scheduler.read(
            request: BridgeGitReadRequest(
                worktreeKey: gitReadContext.worktreeKey,
                operationClass: operationClass,
                coalescingKey: coalescingKey,
                freshnessKey: freshnessKey,
                deadline: gitDataPlaneReadTimeout
            ),
            operation: operation
        )
    }

    private func gitReadCoalescingKey<Request: Encodable>(
        domain: String,
        request: Request
    ) throws -> BridgeGitReadCoalescingKey {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        var hasher = SHA256()
        hasher.update(data: Data("agentstudio-bridge-git-read-v1:\(domain):".utf8))
        hasher.update(data: requestData)
        return BridgeGitReadCoalescingKey(
            token: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func gitReviewReadCoalescingKey(
        domain: String,
        repositoryPath: URL,
        target: GitRevisionTarget
    ) throws -> BridgeGitReadCoalescingKey {
        try gitReadCoalescingKey(
            domain: domain,
            request: GitReviewReadCoalescingIdentity(
                repositoryPath: repositoryPath,
                target: target
            )
        )
    }

    func gitReadFreshnessKey(
        for reviewGeneration: BridgeReviewGeneration
    ) -> BridgeGitReadFreshnessKey {
        BridgeGitReadFreshnessKey(
            token: "\(gitReadContext.scopeKey.token):review-generation-\(reviewGeneration.rawValue)"
        )
    }

    func gitReadFreshnessKey(
        forReviewAttemptAuthorityGeneration authorityGeneration: UInt64
    ) -> BridgeGitReadFreshnessKey {
        BridgeGitReadFreshnessKey(
            token: "\(gitReadContext.scopeKey.token):review-attempt-\(authorityGeneration)"
        )
    }

    func bridgeFailure(
        for error: GitDataPlaneError,
        handle: BridgeContentHandle? = nil
    ) -> BridgeProviderFailure {
        switch error {
        case .repositoryNotFound:
            return .providerUnavailable
        case .contentTooLarge(_, let sizeBytes, _):
            if let handle {
                return .oversizedContent(handleId: handle.handleId, sizeBytes: byteCount(sizeBytes))
            }
            return .providerFailed(message: "gitDataPlane:contentTooLarge:sizeBytes=\(sizeBytes)")
        case .pathEscapesRepository:
            return .providerFailed(message: "gitDataPlane:pathEscapesRepository")
        case .revisionUnavailable:
            return .providerFailed(message: "gitDataPlane:revisionUnavailable")
        case .headUnavailable:
            return .providerFailed(message: "gitDataPlane:headUnavailable")
        case .requiredObjectNotFound:
            return .providerFailed(message: "gitDataPlane:requiredObjectNotFound")
        case .noSharedHistory:
            return .providerFailed(message: "gitDataPlane:noSharedHistory")
        case .multipleBestMergeBases:
            return .providerFailed(message: "gitDataPlane:multipleBestMergeBases")
        case .libgit2Failure(let code, let klass, let message):
            return .providerFailed(
                message:
                    "gitDataPlane:libgit2Failure:code=\(code):klass=\(klass):reason=\(libGit2FailureReason(message))"
            )
        case .unsupported:
            return .providerFailed(message: "gitDataPlane:unsupported")
        case .locked:
            return .providerFailed(message: "gitDataPlane:locked")
        case .lockHeld, .lockUnidentified:
            return .providerFailed(message: "gitDataPlane:locked")
        case .permissionDenied:
            return .providerFailed(message: "gitDataPlane:permissionDenied")
        case .worktreeNotFound:
            return .providerFailed(message: "gitDataPlane:worktreeNotFound")
        case .worktreeNotPrunable:
            return .providerFailed(message: "gitDataPlane:worktreeNotPrunable")
        case .unsafeWorktreeRemoval:
            return .providerFailed(message: "gitDataPlane:unsafeWorktreeRemoval")
        case .processFailed:
            return .providerFailed(message: "gitDataPlane:processFailed")
        case .processTimedOut:
            return .providerFailed(message: "gitDataPlane:processTimedOut")
        case .processCancelled:
            return .providerFailed(message: "gitDataPlane:processCancelled")
        case .processOutputTooLarge:
            return .providerFailed(message: "gitDataPlane:processOutputTooLarge")
        case .remoteRefTransactionIndeterminate:
            return .providerFailed(message: "gitDataPlane:remoteRefTransactionIndeterminate")
        case .branchMoved:
            return .providerFailed(message: "gitDataPlane:branchMoved")
        case .branchCheckedOut:
            return .providerFailed(message: "gitDataPlane:branchCheckedOut")
        }
    }

    func unexpectedGitDataPlaneErrorMessage(_ error: Error) -> String {
        "gitDataPlane:unexpected:\(String(describing: type(of: error)))"
    }
}

private struct GitReviewReadCoalescingIdentity: Encodable {
    let repositoryPath: URL
    let target: GitRevisionTarget
}

extension AgentStudioGitBridgeReviewDataClient: BridgeReviewRefreshImpactDataClient {
    func countCommitRange(
        _ request: GitCommitRangeCountRequest,
        candidateGeneration: BridgeReviewGeneration
    ) async throws -> GitCommitRangeCount {
        try await loadGitCommitRangeCount(
            request,
            freshnessKey: gitReadFreshnessKey(for: candidateGeneration)
        )
    }

    func summarizeDiffImpact(
        _ request: GitDiffImpactSummaryRequest,
        candidateGeneration: BridgeReviewGeneration
    ) async throws -> GitDiffImpactSummary {
        try await loadGitDiffImpactSummary(
            request,
            freshnessKey: gitReadFreshnessKey(for: candidateGeneration)
        )
    }
}

extension AgentStudioGitBridgeReviewDataClient: WorktreeAnnotationGitEvidenceSource {
    func currentWorktreeAnnotationReviewedSubjectEvidence(
        sourceGeneration: Int
    ) async throws -> WorktreeAnnotationReviewedSubjectEvidence? {
        do {
            let revision = try await loadGitResolvedRevision(
                GitRevisionResolutionRequest(repositoryPath: repositoryPath, target: .named("HEAD")),
                unavailableEndpointId: "worktree-annotation-head",
                freshnessKey: worktreeAnnotationFreshnessKey(sourceGeneration: sourceGeneration)
            )
            return try WorktreeAnnotationReviewedSubjectEvidence(
                branchName: revision.shortName,
                reviewedHeadOID: revision.oid
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    func worktreeAnnotationAncestryDisposition(
        acceptedReviewedHeadOID: String,
        currentReviewedHeadOID: String,
        sourceGeneration: Int
    ) async throws -> WorktreeAnnotationAncestryDisposition {
        do {
            let result = try await loadGitCommitRangeCount(
                GitCommitRangeCountRequest(
                    repositoryPath: repositoryPath,
                    base: .named(acceptedReviewedHeadOID),
                    candidate: .named(currentReviewedHeadOID),
                    maximumCount: AppPolicies.Bridge.worktreeAnnotationContinuityMaximumCommitCount,
                    maximumTraversalCount: AppPolicies.Bridge.worktreeAnnotationContinuityMaximumTraversalCount
                ),
                freshnessKey: worktreeAnnotationFreshnessKey(sourceGeneration: sourceGeneration)
            )
            return switch result {
            case .exact: .exact
            case .atLeastLimit: .atLeastLimit
            case .traversalLimitReached: .traversalLimitReached
            case .unrelated: .unrelated
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .readFailure
        }
    }

    private func worktreeAnnotationFreshnessKey(
        sourceGeneration: Int
    ) -> BridgeGitReadFreshnessKey {
        BridgeGitReadFreshnessKey(
            token: "\(gitReadContext.scopeKey.token):worktree-annotation-source-\(sourceGeneration)"
        )
    }
}
