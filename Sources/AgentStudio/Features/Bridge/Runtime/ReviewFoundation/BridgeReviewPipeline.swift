import AgentStudioGit
import Foundation

/// Off-main review package assembly boundary for Bridge panes.
///
/// Keep this actor protocol-first unless a backend's public `Sendable` DTOs
/// exactly match Bridge review contracts. When they differ, the mapper belongs
/// behind `BridgeReviewSourceProvider`, not in the pipeline.
actor BridgeReviewPipeline {
    private let provider: any BridgeReviewSourceProvider

    init(provider: any BridgeReviewSourceProvider) {
        self.provider = provider
    }

    func resolveSharedConstructionRequest(
        _ request: BridgeReviewPipelineRequest,
        freshnessKey: BridgeGitReadFreshnessKey,
        progress: BridgeReviewConstructionProgressReporter = { _ in }
    ) async throws -> BridgeReviewPipelineRequest {
        guard let sharedProvider = provider as? any BridgeSharedReviewConstructionSourceProvider else {
            throw unsupportedSharedConstruction()
        }
        if let preparedComparison = request.preparedComparison {
            guard request.baseEndpoint == preparedComparison.baseEndpoint,
                request.headEndpoint == preparedComparison.headEndpoint
            else {
                throw BridgeProviderFailure.providerFailed(
                    message: "Prepared comparison endpoints do not match the request endpoints"
                )
            }
            return request
        }
        let baseEndpoint = try await sharedProvider.resolveEndpoint(
            BridgeEndpointResolutionRequest(endpoint: request.baseEndpoint),
            freshnessKey: freshnessKey
        )
        let headEndpoint = try await sharedProvider.resolveEndpoint(
            BridgeEndpointResolutionRequest(endpoint: request.headEndpoint),
            freshnessKey: freshnessKey
        )
        await progress(.endpointsResolved)
        let query = BridgeReviewQuery(
            queryId: request.query.queryId,
            queryKind: request.query.queryKind,
            repoId: request.query.repoId,
            worktreeId: request.query.worktreeId,
            baseEndpointId: baseEndpoint.endpointId,
            headEndpointId: headEndpoint.endpointId,
            comparisonSemantics: request.query.comparisonSemantics,
            pathScope: request.query.pathScope,
            fileTarget: request.query.fileTarget,
            viewFilter: request.query.viewFilter,
            grouping: request.query.grouping,
            provenanceFilter: request.query.provenanceFilter
        )
        return BridgeReviewPipelineRequest(
            packageId: request.packageId,
            query: query,
            baseEndpoint: baseEndpoint,
            headEndpoint: headEndpoint,
            checkpointIds: request.checkpointIds,
            reviewGeneration: request.reviewGeneration,
            generatedAtUnixMilliseconds: request.generatedAtUnixMilliseconds,
            preparedComparison: request.preparedComparison,
            comparisonOrigin: request.comparisonOrigin,
            reviewedSubjectLabel: request.reviewedSubjectLabel,
            reviewAttemptAuthorityGeneration: request.reviewAttemptAuthorityGeneration,
            gitRefreshScope: request.gitRefreshScope,
            gitRefreshSeed: request.gitRefreshSeed
        )
    }

    func buildSharedTemplate(
        request: BridgeReviewPipelineRequest,
        baseEndpointKey: BridgeResolvedReviewEndpointKey,
        headEndpointKey: BridgeResolvedReviewEndpointKey,
        freshnessKey: BridgeGitReadFreshnessKey,
        progress: BridgeReviewConstructionProgressReporter = { _ in }
    ) async throws -> BridgeSharedReviewPackageTemplate {
        guard let sharedProvider = provider as? any BridgeSharedReviewConstructionSourceProvider else {
            throw unsupportedSharedConstruction()
        }
        let result = try await loadPackage(request, freshnessKey: freshnessKey, progress: progress)
        let backing = try await sharedProvider.captureSharedContent(
            handles: result.registeredContentHandles,
            freshnessKey: freshnessKey
        )
        await progress(.sharedContentCaptured)
        return BridgeSharedReviewPackageTemplate.make(
            result: result,
            baseEndpointKey: baseEndpointKey,
            headEndpointKey: headEndpointKey,
            backing: backing
        )
    }

    func bindSharedTemplate(
        _ template: BridgeSharedReviewPackageTemplate,
        request: BridgeReviewPipelineRequest,
        progress: BridgeReviewConstructionProgressReporter = { _ in }
    ) async throws -> BridgeReviewPipelineResult {
        guard let sharedProvider = provider as? any BridgeSharedReviewConstructionSourceProvider,
            let backing = template.backing
        else {
            throw BridgeProviderFailure.providerFailed(
                message: "Review provider does not support shared construction"
            )
        }
        let result = try template.bind(request)
        try await sharedProvider.installSharedContent(
            backing: backing,
            handles: result.registeredContentHandles
        )
        await progress(.sharedContentInstalled)
        return result
    }

    func loadPackage(
        _ request: BridgeReviewPipelineRequest,
        progress: BridgeReviewConstructionProgressReporter = { _ in }
    ) async throws -> BridgeReviewPipelineResult {
        try await loadPackage(request, freshnessKey: nil, progress: progress)
    }

    private func loadPackage(
        _ request: BridgeReviewPipelineRequest,
        freshnessKey: BridgeGitReadFreshnessKey?,
        progress: BridgeReviewConstructionProgressReporter
    ) async throws -> BridgeReviewPipelineResult {
        let package: BridgeReviewPackage
        switch request.query.queryKind {
        case .compare, .filterPackage, .groupPackage:
            let comparison = try await preparedOrComparedEndpoints(
                for: request,
                freshnessKey: freshnessKey,
                progress: progress
            )
            package = try buildPackage(request: request, comparison: comparison)
        case .browseTree:
            let tree = try await readTree(
                request: BridgeTreeReadRequest(
                    endpoint: request.headEndpoint,
                    pathScope: request.query.pathScope,
                    reviewGeneration: request.reviewGeneration
                ),
                freshnessKey: freshnessKey
            )
            await progress(.treeRead)
            package = try buildDescriptorPackage(
                request: request,
                headEndpoint: tree.endpoint,
                descriptors: tree.descriptors
            )
        case .openFile:
            guard let fileTarget = request.query.fileTarget else {
                throw BridgeProviderFailure.providerFailed(message: "openFile query requires fileTarget")
            }
            let comparison = try await preparedOrComparedEndpoints(
                for: request,
                freshnessKey: freshnessKey,
                progress: progress
            )
            if let changedFile = BridgeReviewPipeline.changedFile(in: comparison, matching: fileTarget) {
                package = try buildPackage(
                    request: request,
                    comparison: BridgeEndpointComparison(
                        baseEndpoint: comparison.baseEndpoint,
                        headEndpoint: comparison.headEndpoint,
                        changedFiles: [changedFile]
                    )
                )
            } else {
                let descriptor = try await readReviewItemDescriptor(
                    request: BridgeReviewItemDescriptorRequest(
                        endpoint: request.headEndpoint,
                        path: fileTarget,
                        reviewGeneration: request.reviewGeneration
                    ),
                    freshnessKey: freshnessKey
                )
                await progress(.descriptorRead)
                package = try buildDescriptorPackage(
                    request: request,
                    headEndpoint: request.headEndpoint,
                    descriptors: [descriptor]
                )
            }
        }
        let result = pipelineResult(package: package, gitRefreshSeed: request.gitRefreshSeed)
        await progress(.packageBuilt)
        return result
    }

    private func compareEndpoints(
        _ request: BridgeEndpointComparisonRequest,
        freshnessKey: BridgeGitReadFreshnessKey?
    ) async throws -> BridgeEndpointComparison {
        guard let freshnessKey else { return try await provider.compareEndpoints(request) }
        guard let sharedProvider = provider as? any BridgeSharedReviewConstructionSourceProvider else {
            throw unsupportedSharedConstruction()
        }
        return try await sharedProvider.compareEndpoints(request, freshnessKey: freshnessKey)
    }

    private func preparedOrComparedEndpoints(
        for request: BridgeReviewPipelineRequest,
        freshnessKey: BridgeGitReadFreshnessKey?,
        progress: BridgeReviewConstructionProgressReporter
    ) async throws -> BridgeEndpointComparison {
        if let preparedComparison = request.preparedComparison {
            return preparedComparison
        }
        let comparison = try await compareEndpoints(
            comparisonRequest(for: request),
            freshnessKey: freshnessKey
        )
        await progress(.comparisonResolved)
        return comparison
    }

    private func readTree(
        request: BridgeTreeReadRequest,
        freshnessKey: BridgeGitReadFreshnessKey?
    ) async throws -> BridgeTreeReadResult {
        guard let freshnessKey else { return try await provider.readTree(request) }
        guard let sharedProvider = provider as? any BridgeSharedReviewConstructionSourceProvider else {
            throw unsupportedSharedConstruction()
        }
        return try await sharedProvider.readTree(request, freshnessKey: freshnessKey)
    }

    private func readReviewItemDescriptor(
        request: BridgeReviewItemDescriptorRequest,
        freshnessKey: BridgeGitReadFreshnessKey?
    ) async throws -> BridgeReviewItemDescriptor {
        guard let freshnessKey else { return try await provider.readReviewItemDescriptor(request) }
        guard let sharedProvider = provider as? any BridgeSharedReviewConstructionSourceProvider else {
            throw unsupportedSharedConstruction()
        }
        return try await sharedProvider.readReviewItemDescriptor(request, freshnessKey: freshnessKey)
    }

    private func comparisonRequest(
        for request: BridgeReviewPipelineRequest
    ) -> BridgeEndpointComparisonRequest {
        BridgeEndpointComparisonRequest(
            query: request.query,
            baseEndpoint: request.baseEndpoint,
            headEndpoint: request.headEndpoint,
            reviewGeneration: request.reviewGeneration
        )
    }

    private func buildPackage(
        request: BridgeReviewPipelineRequest,
        comparison: BridgeEndpointComparison
    ) throws -> BridgeReviewPackage {
        try BridgeReviewPackageBuilder.build(
            request: BridgeReviewPackageBuildRequest(
                packageId: request.packageId,
                query: request.query,
                comparison: comparison,
                checkpointIds: request.checkpointIds,
                reviewGeneration: request.reviewGeneration,
                generatedAtUnixMilliseconds: request.generatedAtUnixMilliseconds,
                comparisonOrigin: request.comparisonOrigin,
                reviewedSubjectLabel: request.reviewedSubjectLabel
            )
        )
    }

    private func buildDescriptorPackage(
        request: BridgeReviewPipelineRequest,
        headEndpoint: BridgeSourceEndpoint,
        descriptors: [BridgeReviewItemDescriptor]
    ) throws -> BridgeReviewPackage {
        try BridgeReviewPackageBuilder.buildFromDescriptors(
            request: BridgeReviewDescriptorPackageBuildRequest(
                packageId: request.packageId,
                query: request.query,
                baseEndpoint: request.baseEndpoint,
                headEndpoint: headEndpoint,
                descriptors: descriptors,
                checkpointIds: request.checkpointIds,
                reviewGeneration: request.reviewGeneration,
                generatedAtUnixMilliseconds: request.generatedAtUnixMilliseconds,
                comparisonOrigin: request.comparisonOrigin,
                reviewedSubjectLabel: request.reviewedSubjectLabel
            )
        )
    }

    private func pipelineResult(
        package: BridgeReviewPackage,
        gitRefreshSeed: GitReviewRefreshSeed?
    ) -> BridgeReviewPipelineResult {
        BridgeReviewPipelineResult(
            package: package,
            registeredContentHandles: package.itemsById.values
                .sorted { $0.itemId < $1.itemId }
                .flatMap { $0.contentRoles.allHandles },
            gitRefreshSeed: gitRefreshSeed
        )
    }

    private func unsupportedSharedConstruction() -> BridgeProviderFailure {
        BridgeProviderFailure.providerFailed(
            message: "Review provider does not support shared construction"
        )
    }

    private static func changedFile(
        in comparison: BridgeEndpointComparison,
        matching fileTarget: String
    ) -> BridgeEndpointChangedFile? {
        comparison.changedFiles.first { changedFile in
            changedFile.path == fileTarget || changedFile.oldPath == fileTarget
        }
    }
}
