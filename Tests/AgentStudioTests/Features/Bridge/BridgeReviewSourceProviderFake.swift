import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

actor BridgeReviewSourceProviderFake: BridgeReviewSourceProvider {
    private let repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    private let comparisonTargetsCapture: BridgeReviewComparisonTargetsCapture?
    private let comparisonTargetsCaptureGate: BridgeComparisonGate?
    private var contributionCapture: BridgeContributionComparisonCapture?
    var comparison: BridgeEndpointComparison
    var contentByHandleId: [String: BridgeContentLoadResult]
    var treeDescriptors: [BridgeReviewItemDescriptor]
    var itemDescriptorByPath: [String: BridgeReviewItemDescriptor]
    private let comparisonFailureByBaseProviderIdentity: [String: BridgeProviderFailure]
    private let contentLoadGate: HeldStep<Void>?
    private var comparisonGate: BridgeComparisonGate?
    private var comparisonStep: HeldStep<Void>?
    private let checksCancellationAfterGate: Bool
    private var contentRequests: [BridgeContentLoadRequest] = []
    private var comparisonRequests: [BridgeEndpointComparisonRequest] = []
    private var treeReadRequests: [BridgeTreeReadRequest] = []
    private var itemDescriptorRequests: [BridgeReviewItemDescriptorRequest] = []
    private var contributionRequests: [BridgeContributionComparisonRequest] = []
    private var observedCancellationCount = 0
    private var finishedContentLoadCount = 0
    private var finishedContentLoadWaiters: [BridgeContentLoadWaiter] = []

    private struct BridgeContentLoadWaiter {
        let requestedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        comparison: BridgeEndpointComparison,
        contentByHandleId: [String: BridgeContentLoadResult],
        repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity? = nil,
        comparisonTargetsCapture: BridgeReviewComparisonTargetsCapture? = nil,
        comparisonTargetsCaptureGate: BridgeComparisonGate? = nil,
        contributionCapture: BridgeContributionComparisonCapture? = nil,
        treeDescriptors: [BridgeReviewItemDescriptor] = [],
        itemDescriptorByPath: [String: BridgeReviewItemDescriptor] = [:],
        comparisonFailureByBaseProviderIdentity: [String: BridgeProviderFailure] = [:],
        contentLoadGate: HeldStep<Void>? = nil,
        comparisonGate: BridgeComparisonGate? = nil,
        comparisonStep: HeldStep<Void>? = nil,
        checksCancellationAfterGate: Bool = false
    ) {
        self.repositoryDefaultTarget = repositoryDefaultTarget
        self.comparisonTargetsCapture = comparisonTargetsCapture
        self.comparisonTargetsCaptureGate = comparisonTargetsCaptureGate
        self.contributionCapture = contributionCapture
        self.comparison = comparison
        self.contentByHandleId = contentByHandleId
        self.treeDescriptors = treeDescriptors
        self.itemDescriptorByPath = itemDescriptorByPath
        self.comparisonFailureByBaseProviderIdentity = comparisonFailureByBaseProviderIdentity
        self.contentLoadGate = contentLoadGate
        self.comparisonGate = comparisonGate
        self.comparisonStep = comparisonStep
        self.checksCancellationAfterGate = checksCancellationAfterGate
    }

    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        repositoryDefaultTarget
    }

    func captureReviewComparisonTargets(
        _: BridgeReviewComparisonTargetsCaptureRequest
    ) async throws -> BridgeReviewComparisonTargetsCapture {
        await comparisonTargetsCaptureGate?.waitUntilReleased()
        guard let comparisonTargetsCapture else {
            throw BridgeProviderFailure.providerFailed(
                message: "Review comparison target capture not configured"
            )
        }
        return comparisonTargetsCapture
    }

    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        contributionRequests.append(request)
        guard let contributionCapture else {
            throw BridgeProviderFailure.providerFailed(message: "Contribution capture not configured")
        }
        let baseEndpoint = BridgeSourceEndpoint(
            endpointId: request.baseEndpoint.endpointId,
            kind: .gitRef,
            repoId: request.baseEndpoint.repoId,
            worktreeId: request.baseEndpoint.worktreeId,
            label: request.baseEndpoint.label,
            createdAtUnixMilliseconds: request.baseEndpoint.createdAtUnixMilliseconds,
            contentSetHash: contributionCapture.baseOID,
            providerIdentity: contributionCapture.baseOID
        )
        return BridgeContributionComparisonCapture(
            resolvedTargetOID: contributionCapture.resolvedTargetOID,
            reviewedHeadOID: contributionCapture.reviewedHeadOID,
            baseRole: contributionCapture.baseRole,
            baseOID: contributionCapture.baseOID,
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: request.headEndpoint,
                changedFiles: contributionCapture.comparison.changedFiles
            )
        )
    }

    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        request.endpoint
    }

    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        comparisonRequests.append(request)
        if let failure = comparisonFailureByBaseProviderIdentity[request.baseEndpoint.providerIdentity] {
            throw failure
        }
        let resolvedComparison = comparison
        await comparisonGate?.waitUntilReleased()
        try? await comparisonStep?.arrive(())
        return BridgeEndpointComparison(
            baseEndpoint: endpoint(
                request.baseEndpoint,
                carryingResolvedIdentityFrom: resolvedComparison.baseEndpoint
            ),
            headEndpoint: endpoint(
                request.headEndpoint,
                carryingResolvedIdentityFrom: resolvedComparison.headEndpoint
            ),
            changedFiles: resolvedComparison.changedFiles
        )
    }

    func readTree(_ request: BridgeTreeReadRequest) async throws -> BridgeTreeReadResult {
        treeReadRequests.append(request)
        return BridgeTreeReadResult(endpoint: request.endpoint, descriptors: treeDescriptors)
    }

    func readReviewItemDescriptor(_ request: BridgeReviewItemDescriptorRequest) async throws
        -> BridgeReviewItemDescriptor
    {
        itemDescriptorRequests.append(request)
        return itemDescriptorByPath[request.path]
            ?? makeBridgeReviewItemDescriptor(itemId: "item-\(request.path)", path: request.path, fileClass: .source)
    }

    func resolveCheckpointEndpoint(_ request: BridgeCheckpointEndpointRequest) async throws -> BridgeSourceEndpoint {
        makeBridgeEndpoint(endpointId: request.checkpointId, kind: .promptCheckpoint)
    }

    func loadContent(_ request: BridgeContentLoadRequest) async throws -> BridgeContentLoadResult {
        contentRequests.append(request)
        defer {
            recordFinishedContentLoad()
        }
        try? await contentLoadGate?.arrive(())
        if checksCancellationAfterGate {
            do {
                try Task.checkCancellation()
            } catch {
                observedCancellationCount += 1
                throw error
            }
        }
        guard let result = contentByHandleId[request.handle.handleId] else {
            throw BridgeProviderFailure.missingContent(handleId: request.handle.handleId)
        }
        guard result.handle.reviewGeneration == request.requestedGeneration else {
            throw BridgeProviderFailure.staleReviewGeneration(
                storedGeneration: result.handle.reviewGeneration,
                requestedGeneration: request.requestedGeneration
            )
        }
        return result
    }

    func recordedContentRequestsCount() -> Int {
        contentRequests.count
    }

    func recordedComparisonRequestsCount() -> Int {
        comparisonRequests.count
    }

    func recordedComparisonRequests() -> [BridgeEndpointComparisonRequest] {
        comparisonRequests
    }

    func recordedContributionRequests() -> [BridgeContributionComparisonRequest] {
        contributionRequests
    }

    func setComparison(_ comparison: BridgeEndpointComparison) {
        self.comparison = comparison
    }

    func setContributionCapture(_ contributionCapture: BridgeContributionComparisonCapture) {
        self.contributionCapture = contributionCapture
    }

    func setComparisonGate(_ comparisonGate: BridgeComparisonGate?) {
        self.comparisonGate = comparisonGate
    }

    func setComparisonStep(_ comparisonStep: HeldStep<Void>?) {
        self.comparisonStep = comparisonStep
    }

    func recordedTreeReadRequestsCount() -> Int {
        treeReadRequests.count
    }

    func recordedItemDescriptorRequestsCount() -> Int {
        itemDescriptorRequests.count
    }

    func recordedContentRequestsCount(handleId: String) -> Int {
        contentRequests.filter { $0.handle.handleId == handleId }.count
    }

    func recordedObservedCancellationCount() -> Int {
        observedCancellationCount
    }

    func waitForFinishedContentLoadCount(_ requestedCount: Int) async {
        guard finishedContentLoadCount < requestedCount else { return }
        await withCheckedContinuation { continuation in
            finishedContentLoadWaiters.append(
                BridgeContentLoadWaiter(requestedCount: requestedCount, continuation: continuation)
            )
        }
    }

    private func recordFinishedContentLoad() {
        finishedContentLoadCount += 1
        var pendingWaiters: [BridgeContentLoadWaiter] = []
        for waiter in finishedContentLoadWaiters {
            if finishedContentLoadCount >= waiter.requestedCount {
                waiter.continuation.resume()
            } else {
                pendingWaiters.append(waiter)
            }
        }
        finishedContentLoadWaiters = pendingWaiters
    }

    private func endpoint(
        _ requestedEndpoint: BridgeSourceEndpoint,
        carryingResolvedIdentityFrom configuredEndpoint: BridgeSourceEndpoint
    ) -> BridgeSourceEndpoint {
        guard requestedEndpoint.kind == configuredEndpoint.kind,
            let contentSetHash = configuredEndpoint.contentSetHash
        else { return requestedEndpoint }
        return BridgeSourceEndpoint(
            endpointId: requestedEndpoint.endpointId,
            kind: requestedEndpoint.kind,
            repoId: requestedEndpoint.repoId,
            worktreeId: requestedEndpoint.worktreeId,
            label: requestedEndpoint.label,
            createdAtUnixMilliseconds: requestedEndpoint.createdAtUnixMilliseconds,
            contentSetHash: contentSetHash,
            providerIdentity: contentSetHash
        )
    }
}

actor BridgeComparisonGate {
    private struct StartedComparisonWaiter {
        let requestedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var startedComparisonCount = 0
    private var startedComparisonWaiters: [StartedComparisonWaiter] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func waitUntilReleased() async {
        startedComparisonCount += 1
        resumeSatisfiedStartedComparisonWaiters()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitForStartedComparisonCount(_ requestedCount: Int) async {
        guard startedComparisonCount < requestedCount else { return }
        await withCheckedContinuation { continuation in
            startedComparisonWaiters.append(
                StartedComparisonWaiter(requestedCount: requestedCount, continuation: continuation)
            )
        }
    }

    func startedComparisonCountSnapshot() -> Int {
        startedComparisonCount
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeSatisfiedStartedComparisonWaiters() {
        var pendingWaiters: [StartedComparisonWaiter] = []
        for waiter in startedComparisonWaiters {
            if startedComparisonCount >= waiter.requestedCount {
                waiter.continuation.resume()
            } else {
                pendingWaiters.append(waiter)
            }
        }
        startedComparisonWaiters = pendingWaiters
    }
}
