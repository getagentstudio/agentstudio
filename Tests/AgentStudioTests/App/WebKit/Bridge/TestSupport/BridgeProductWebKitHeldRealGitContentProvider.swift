import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

/// Changes only the fixture's working-tree file at the real provider's read
/// boundary, after the published shared backing has captured its original hash.
/// The released HeldStep records that boundary without parking a live transport
/// read while the test performs startup or JavaScript observations.
actor BridgeProductWebKitHeldRealGitContentProvider: BridgeSharedReviewConstructionSourceProvider {
    private let base: any BridgeSharedReviewConstructionSourceProvider
    private let trackedFileURL: URL
    private var trackedWorkingTreeHandleIds: Set<String> = []
    private var didChangeTrackedContent = false
    let contentRead = HeldStep<BridgeContentHandle>("real Git working-tree content read")
    let contentReadFinished = HeldStep<Result<BridgeContentLoadResult, any Error>>("real Git selected read outcome")
    private(set) var targetReadResult: Result<BridgeContentLoadResult, any Error>?

    init(base: any BridgeSharedReviewConstructionSourceProvider, trackedFileURL: URL) {
        self.base = base
        self.trackedFileURL = trackedFileURL
        contentReadFinished.release()
    }

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        try await base.resolveReviewDefaultTarget()
    }

    func captureReviewComparisonTargets(
        _ request: BridgeReviewComparisonTargetsCaptureRequest
    ) async throws -> BridgeReviewComparisonTargetsCapture {
        try await base.captureReviewComparisonTargets(request)
    }

    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        try await base.captureContributionComparison(request)
    }

    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        try await base.resolveEndpoint(request)
    }

    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        try await base.compareEndpoints(request)
    }

    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        try await base.readTree(request)
    }

    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        try await base.readReviewItemDescriptor(request)
    }

    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws -> BridgeSourceEndpoint {
        try await base.resolveCheckpointEndpoint(request)
    }

    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        if trackedWorkingTreeHandleIds.contains(request.handle.handleId), !didChangeTrackedContent {
            didChangeTrackedContent = true
            try await contentRead.arrive(request.handle)
            try "changed after publication\n".write(to: trackedFileURL, atomically: true, encoding: .utf8)
        }
        do {
            let result = try await base.loadContent(request)
            if trackedWorkingTreeHandleIds.contains(request.handle.handleId), targetReadResult == nil {
                targetReadResult = .success(result)
                try await contentReadFinished.arrive(.success(result))
            }
            return result
        } catch {
            if trackedWorkingTreeHandleIds.contains(request.handle.handleId), targetReadResult == nil {
                targetReadResult = .failure(error)
                try await contentReadFinished.arrive(.failure(error))
            }
            throw error
        }
    }

    func streamContent(
        _ request: BridgeContentStreamRequest,
        chunkByteCount: Int,
        emitChunk: BridgeContentStreamEmitter
    ) async throws -> BridgeContentStreamResult {
        try await base.streamContent(
            request,
            chunkByteCount: chunkByteCount,
            emitChunk: emitChunk
        )
    }
    func resolveEndpoint(
        _ request: BridgeEndpointResolutionRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeSourceEndpoint {
        try await base.resolveEndpoint(request, freshnessKey: freshnessKey)
    }

    func compareEndpoints(
        _ request: BridgeEndpointComparisonRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeEndpointComparison {
        try await base.compareEndpoints(request, freshnessKey: freshnessKey)
    }

    func readTree(
        _ request: BridgeTreeReadRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeTreeReadResult {
        try await base.readTree(request, freshnessKey: freshnessKey)
    }

    func readReviewItemDescriptor(
        _ request: BridgeReviewItemDescriptorRequest,
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeReviewItemDescriptor {
        try await base.readReviewItemDescriptor(request, freshnessKey: freshnessKey)
    }

    func captureSharedContent(
        handles: [BridgeContentHandle],
        freshnessKey: BridgeGitReadFreshnessKey
    ) async throws -> BridgeSharedReviewContentBacking {
        try await base.captureSharedContent(
            handles: handles,
            freshnessKey: freshnessKey
        )
    }

    func installSharedContent(
        backing: BridgeSharedReviewContentBacking,
        handles: [BridgeContentHandle]
    ) async throws {
        try await base.installSharedContent(backing: backing, handles: handles)
        for handle in handles where handle.role == .head || handle.role == .file {
            let identity = BridgeSharedReviewContentIdentity(
                itemIdentity: handle.itemId, role: handle.role, contentHash: handle.contentHash)
            if case .gitTarget(_, let path, _, _) = try backing.source(for: identity), path == "tracked.txt" {
                trackedWorkingTreeHandleIds.insert(handle.handleId)
            }
        }
    }

}
