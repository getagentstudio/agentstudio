import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

/// Holds only the external template provider; construction joining and controller
/// catch-up admission remain the real production owners.
actor NativeProgressSharedReviewProvider: BridgeSharedReviewConstructionSourceProvider {
    let source: BridgeReviewSourceProviderFake
    let captureStep = HeldStep<Void>("shared Review template capture", cancellation: .holdThroughCancellation)
    let installStep = HeldStep<Void>("shared Review content installation", cancellation: .holdThroughCancellation)
    let comparisonStep = HeldStep<Void>("shared Review endpoint comparison", cancellation: .holdThroughCancellation)
    private var holdsCapture = false
    private var holdsInstall = false
    private var holdsComparison = false
    private var failsNextCapture = false

    init(source: BridgeReviewSourceProviderFake) { self.source = source }
    func holdCapture() { holdsCapture = true }
    func failNextSharedCapture() { failsNextCapture = true }
    func holdInstall() { holdsInstall = true }
    func holdComparison() { holdsComparison = true }

    func captureReviewComparisonTargets(_ request: BridgeReviewComparisonTargetsCaptureRequest) async throws
        -> BridgeReviewComparisonTargetsCapture
    {
        let target = BridgeReviewComparisonBranchTarget.local(
            branchName: "main", oid: String(repeating: "a", count: 40))
        return .init(
            capturedAtUnixMilliseconds: request.capturedAtUnixMilliseconds,
            cutoffUnixMilliseconds: request.cutoffUnixMilliseconds,
            isTruncated: false, defaultTarget: target, currentTarget: target, branches: [target])
    }

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        try await source.resolveReviewDefaultTarget()
    }
    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        try await source.captureContributionComparison(request)
    }
    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        try await resolveEndpoint(request, freshnessKey: .init(token: "fixture"))
    }
    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest, freshnessKey _: BridgeGitReadFreshnessKey)
        async throws -> BridgeSourceEndpoint
    {
        let endpoint = request.endpoint
        guard endpoint.kind == .gitRef else { return endpoint }
        let identity = endpoint.contentSetHash ?? String(repeating: "a", count: 40)
        return .init(
            endpointId: endpoint.endpointId, kind: endpoint.kind, repoId: endpoint.repoId,
            worktreeId: endpoint.worktreeId, label: endpoint.label,
            createdAtUnixMilliseconds: endpoint.createdAtUnixMilliseconds,
            contentSetHash: identity, providerIdentity: identity)
    }
    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        try await source.compareEndpoints(request)
    }
    func compareEndpoints(_ request: BridgeEndpointComparisonRequest, freshnessKey _: BridgeGitReadFreshnessKey)
        async throws -> BridgeEndpointComparison
    {
        let comparison = try await source.compareEndpoints(request)
        if holdsComparison { try await comparisonStep.arrive(()) }
        return .init(
            baseEndpoint: request.baseEndpoint, headEndpoint: request.headEndpoint,
            changedFiles: comparison.changedFiles)
    }
    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        try await source.readTree(request)
    }
    func readTree(_ request: BridgeTreeReadRequest, freshnessKey _: BridgeGitReadFreshnessKey) async throws
        -> BridgeTreeReadResult
    {
        try await source.readTree(request)
    }
    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        try await source.readReviewItemDescriptor(request)
    }
    func readReviewItemDescriptor(
        _ request: BridgeReviewItemDescriptorRequest, freshnessKey _: BridgeGitReadFreshnessKey
    ) async throws -> BridgeReviewItemDescriptor {
        try await source.readReviewItemDescriptor(request)
    }
    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws -> BridgeSourceEndpoint {
        try await source.resolveCheckpointEndpoint(request)
    }
    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        try await source.loadContent(request)
    }

    func captureSharedContent(handles: [BridgeContentHandle], freshnessKey _: BridgeGitReadFreshnessKey) async throws
        -> BridgeSharedReviewContentBacking
    {
        if failsNextCapture {
            failsNextCapture = false
            throw BridgeProviderFailure.providerUnavailable
        }
        var sources: [BridgeSharedReviewContentIdentity: BridgeSharedReviewContentSource] = [:]
        for handle in handles {
            sources[.init(itemIdentity: handle.itemId, role: handle.role, contentHash: handle.contentHash)] =
                .gitTarget(
                    target: .workingTree, path: handle.itemId,
                    declaredContentHash: handle.contentHash, declaredContentHashAlgorithm: handle.contentHashAlgorithm)
        }
        let backing = BridgeSharedReviewContentBacking(artifactIdentity: UUIDv7.generate(), sourceByIdentity: sources)
        if holdsCapture { try await captureStep.arrive(()) }
        return backing
    }
    func installSharedContent(backing: BridgeSharedReviewContentBacking, handles: [BridgeContentHandle]) async throws {
        for handle in handles {
            _ = try backing.source(
                for: .init(itemIdentity: handle.itemId, role: handle.role, contentHash: handle.contentHash))
        }
        if holdsInstall { try await installStep.arrive(()) }
    }
}

extension BridgeReviewSourceProviderFake {
    func installNativeProgressReadResult(_ result: BridgeContentLoadResult) {
        contentByHandleId[result.handle.handleId] = result
    }
}
