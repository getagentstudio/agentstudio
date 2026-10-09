import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension BridgePaneController {
    static func makeReviewSharedConstructionBinder(
        coordinator: BridgeWorktreeProductConstructionCoordinator?,
        pipeline: BridgeReviewPipeline,
        provider: any BridgeReviewSourceProvider,
        state: BridgePaneState
    ) -> BridgePaneReviewSharedConstructionBinder? {
        guard let coordinator,
            provider is any BridgeSharedReviewConstructionSourceProvider,
            case .workspace(let rootPath, _) = state.source
        else { return nil }
        return BridgePaneReviewSharedConstructionBinder(
            coordinator: coordinator,
            pipeline: pipeline,
            repositoryPath: URL(fileURLWithPath: rootPath)
        )
    }

    func acquireReviewPackage(
        _ unresolvedRequest: BridgeReviewPipelineRequest
    ) async throws -> BridgeReviewPackageConstructionResult {
        let pipeline = reviewPipeline
        let sharedConstructionBinder = reviewSharedConstructionBinder
        let resolution = captureContributionResolutionContext()
        return try await reviewConstructionProgress.acquire { progress in
            let request = try await Self.resolveContributionRequestIfNeeded(
                unresolvedRequest, context: resolution, progress: progress)
            return try await Self.acquireReviewPackage(
                request, pipeline: pipeline, sharedConstructionBinder: sharedConstructionBinder, progress: progress)
        }
    }

    @concurrent
    nonisolated static func acquireReviewPackage(
        _ request: BridgeReviewPipelineRequest,
        pipeline: BridgeReviewPipeline,
        sharedConstructionBinder: BridgePaneReviewSharedConstructionBinder?,
        progress: @escaping BridgeReviewConstructionProgressSink
    ) async throws -> BridgeReviewPackageConstructionResult {
        guard let sharedConstructionBinder else {
            return BridgeReviewPackageConstructionResult(
                result: try await pipeline.loadPackage(request, progress: { phase in progress(phase) }),
                artifactPin: nil
            )
        }
        let binding = try await sharedConstructionBinder.acquire(request, progress: progress)
        return BridgeReviewPackageConstructionResult(
            result: binding.result,
            artifactPin: binding.artifactPin
        )
    }

    func loadReviewPackageForRefresh(
        _ currentPackage: BridgeReviewPackage,
        reviewGeneration: BridgeReviewGeneration,
        reservation: BridgePaneRefreshCatchUpReservation
    ) async throws -> (
        result: BridgeReviewPackageConstructionResult,
        traceContext: BridgeTraceContext?
    ) {
        let packageTraceContext = makeRootTraceContext()
        let packageBuildStart = ContinuousClock.now
        let buildReason = consumePendingReviewPackageBuildReason(default: .filesystemRefresh)
        let unresolvedRequest = makeReviewRefreshPipelineRequest(
            currentPackage: currentPackage,
            reviewGeneration: reviewGeneration,
            reservation: reservation
        )
        let result = try await acquireReviewPackage(unresolvedRequest)
        await recordSwiftTelemetry(
            name: "performance.bridge.swift.package_build",
            phase: "package_build",
            priorityHint: .cold,
            traceContext: packageTraceContext,
            stringAttributes: [
                "agentstudio.bridge.package_build.reason": buildReason.rawValue
            ],
            durationMilliseconds: AgentStudioPerformanceTraceRecorder.milliseconds(
                from: packageBuildStart.duration(to: ContinuousClock.now)
            )
        )
        return (result, packageTraceContext)
    }

    private func makeReviewRefreshPipelineRequest(
        currentPackage: BridgeReviewPackage,
        reviewGeneration: BridgeReviewGeneration,
        reservation: BridgePaneRefreshCatchUpReservation
    ) -> BridgeReviewPipelineRequest {
        BridgeReviewPipelineRequest(
            packageId: currentPackage.packageId,
            query: currentPackage.query,
            baseEndpoint: currentPackage.baseEndpoint,
            headEndpoint: currentPackage.headEndpoint,
            checkpointIds: currentPackage.groups.map(\.groupId),
            reviewGeneration: reviewGeneration,
            generatedAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            reviewAttemptAuthorityGeneration: reservation.authorityGeneration,
            gitRefreshScope:
                reservation.reviewRefreshScope ?? .complete(reason: .nonExactInput),
            gitRefreshSeed: reviewGitRefreshSeedHolder.activeSeed
        )
    }

    func consumePendingReviewPackageBuildReason(
        default defaultReason: BridgeReviewPackageBuildReason
    ) -> BridgeReviewPackageBuildReason {
        let reasonPriority: [BridgeReviewPackageBuildReason] = [
            .initialIntake,
            .productResync,
            .filesystemRefresh,
        ]
        let selected = reasonPriority.first { pendingReviewPackageBuildReasons.contains($0) } ?? defaultReason
        pendingReviewPackageBuildReasons.removeAll()
        return selected
    }
}
