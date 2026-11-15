import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

actor BridgeProductWebKitGatedReviewSourceProvider: BridgeReviewSourceProvider {
    nonisolated let comparisonEvents = BridgeProductWebKitReviewComparisonEvents()
    private let base: any BridgeReviewSourceProvider
    private var blockedComparisonCount = 0
    private var comparisonCount = 0
    private var isNextComparisonArmed = false
    private var blockedSteps: [HeldStep<Void>] = []

    init(base: any BridgeReviewSourceProvider) {
        self.base = base
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
        await recordAndBlockComparisonIfArmed()
        return try await base.captureContributionComparison(request)
    }

    func armNextComparison() {
        isNextComparisonArmed = true
        comparisonEvents.arm(blockedComparisonCount + 1)
    }

    @discardableResult
    func releaseBlockedComparisons() -> Int {
        let steps = blockedSteps
        blockedSteps.removeAll()
        for step in steps { step.release() }
        return steps.count
    }

    func snapshot() -> (comparisonCount: Int, blockedComparisonCount: Int) {
        (comparisonCount, blockedComparisonCount)
    }

    nonisolated func waitForBlockedComparisonCount(_ count: Int) async throws -> BridgeProductWebKitBlockedComparison {
        try await comparisonEvents.waitForBlockedComparisonCount(count)
    }

    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws
        -> BridgeSourceEndpoint
    {
        try await base.resolveEndpoint(request)
    }

    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws
        -> BridgeEndpointComparison
    {
        await recordAndBlockComparisonIfArmed()
        return try await base.compareEndpoints(request)
    }

    private func recordAndBlockComparisonIfArmed() async {
        comparisonCount += 1
        if isNextComparisonArmed {
            isNextComparisonArmed = false
            let step = HeldStep<Void>("blocked review comparison", cancellation: .holdThroughCancellation)
            blockedSteps.append(step)
            blockedComparisonCount += 1
            comparisonEvents.arrived(blockedComparisonCount)
            try? await step.arrive(())
        }
    }

    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        try await base.readTree(request)
    }

    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        try await base.readReviewItemDescriptor(request)
    }

    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws
        -> BridgeSourceEndpoint
    {
        try await base.resolveCheckpointEndpoint(request)
    }

    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        try await base.loadContent(request)
    }

    func streamContent(
        _ request: BridgeContentStreamRequest,
        chunkByteCount: Int,
        emitChunk: BridgeContentStreamEmitter
    ) async throws -> BridgeContentStreamResult {
        try await base.streamContent(request, chunkByteCount: chunkByteCount, emitChunk: emitChunk)
    }
}
