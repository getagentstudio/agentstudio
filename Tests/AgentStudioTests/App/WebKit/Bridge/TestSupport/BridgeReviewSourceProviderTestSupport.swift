import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge

actor BridgeReviewSourceProviderFake: BridgeReviewSourceProvider {
    func resolveReviewDefaultTarget() async throws -> BridgeReviewComparisonDefaultTargetIdentity? {
        defaultTargetReadCount += 1
        await defaultTargetGate?.waitUntilReleased()
        return repositoryDefaultTarget
    }

    func captureContributionComparison(_ request: BridgeContributionComparisonRequest) async throws
        -> BridgeContributionComparisonCapture
    {
        contributionRequests.append(request)
        if nextReviewPackageCancellationCount > 0 {
            nextReviewPackageCancellationCount -= 1
            throw CancellationError()
        }
        if let contributionFailure {
            throw contributionFailure
        }
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
        await contributionCaptureGate?.waitUntilReleased()
        return BridgeContributionComparisonCapture(
            resolvedTargetOID: contributionCapture.resolvedTargetOID,
            reviewedHeadOID: contributionCapture.reviewedHeadOID,
            baseRole: contributionCapture.baseRole,
            baseOID: contributionCapture.baseOID,
            comparison: BridgeEndpointComparison(
                baseEndpoint: baseEndpoint,
                headEndpoint: request.headEndpoint,
                changedFiles: contributionCapture.comparison.changedFiles
            ),
            gitRefreshSeed: contributionCapture.gitRefreshSeed,
            calculationDisposition: contributionCapture.calculationDisposition,
            calculationReason: contributionCapture.calculationReason
        )
    }

    private var contributionCapture: BridgeContributionComparisonCapture?
    private var repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    private var defaultTargetGate: BridgeContributionCaptureGate?
    private var defaultTargetReadCount = 0
    private var contributionCaptureGate: BridgeContributionCaptureGate?
    private let contributionFailure: BridgeProviderFailure?
    var comparison: BridgeEndpointComparison
    var contentByHandleId: [String: BridgeContentLoadResult]
    var treeDescriptors: [BridgeReviewItemDescriptor]
    var itemDescriptorByPath: [String: BridgeReviewItemDescriptor]
    private let comparisonFailureByBaseProviderIdentity: [String: BridgeProviderFailure]
    private let contentLoadGate: HeldStep<Void>?
    private var comparisonGate: BridgeComparisonGate?
    private var nextReviewPackageCancellationCount = 0
    private var throwsCancellationWhenComparisonTaskIsCancelled = false
    private var comparisonStep: HeldStep<BridgeEndpointComparisonRequest>?
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
        contributionCapture: BridgeContributionComparisonCapture? = nil,
        contributionCaptureGate: BridgeContributionCaptureGate? = nil,
        contributionFailure: BridgeProviderFailure? = nil,
        repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity? = nil,
        treeDescriptors: [BridgeReviewItemDescriptor] = [],
        itemDescriptorByPath: [String: BridgeReviewItemDescriptor] = [:],
        comparisonFailureByBaseProviderIdentity: [String: BridgeProviderFailure] = [:],
        contentLoadGate: HeldStep<Void>? = nil,
        comparisonGate: BridgeComparisonGate? = nil,
        checksCancellationAfterGate: Bool = false
    ) {
        self.contributionCapture = contributionCapture
        self.contributionCaptureGate = contributionCaptureGate
        self.contributionFailure = contributionFailure
        self.repositoryDefaultTarget = repositoryDefaultTarget
        self.comparison = comparison
        self.contentByHandleId = contentByHandleId
        self.treeDescriptors = treeDescriptors
        self.itemDescriptorByPath = itemDescriptorByPath
        self.comparisonFailureByBaseProviderIdentity = comparisonFailureByBaseProviderIdentity
        self.contentLoadGate = contentLoadGate
        self.comparisonGate = comparisonGate
        self.checksCancellationAfterGate = checksCancellationAfterGate
    }

    func resolveEndpoint(_ request: BridgeEndpointResolutionRequest) async throws -> BridgeSourceEndpoint {
        request.endpoint
    }

    func compareEndpoints(_ request: BridgeEndpointComparisonRequest) async throws -> BridgeEndpointComparison {
        comparisonRequests.append(request)
        if nextReviewPackageCancellationCount > 0 {
            nextReviewPackageCancellationCount -= 1
            throw CancellationError()
        }
        if let failure = comparisonFailureByBaseProviderIdentity[request.baseEndpoint.providerIdentity] {
            throw failure
        }
        let resolvedComparison = comparison
        try await comparisonStep?.arrive(request)
        await comparisonGate?.waitUntilReleased()
        if throwsCancellationWhenComparisonTaskIsCancelled {
            try Task.checkCancellation()
        }
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

    func setComparisonStep(_ comparisonStep: HeldStep<BridgeEndpointComparisonRequest>?) {
        self.comparisonStep = comparisonStep
    }

    func setRepositoryDefaultTarget(
        _ repositoryDefaultTarget: BridgeReviewComparisonDefaultTargetIdentity?
    ) {
        self.repositoryDefaultTarget = repositoryDefaultTarget
    }

    func setDefaultTargetGate(_ defaultTargetGate: BridgeContributionCaptureGate?) {
        self.defaultTargetGate = defaultTargetGate
    }

    func recordedDefaultTargetReadCount() -> Int {
        defaultTargetReadCount
    }

    func setContributionCapture(_ contributionCapture: BridgeContributionComparisonCapture) {
        self.contributionCapture = contributionCapture
    }

    func setContributionCaptureGate(_ contributionCaptureGate: BridgeContributionCaptureGate?) {
        self.contributionCaptureGate = contributionCaptureGate
    }

    func setComparisonGate(_ comparisonGate: BridgeComparisonGate?) {
        self.comparisonGate = comparisonGate
    }

    func cancelNextReviewPackageBuild() {
        nextReviewPackageCancellationCount += 1
    }

    func throwCancellationWhenComparisonTaskIsCancelled() {
        throwsCancellationWhenComparisonTaskIsCancelled = true
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

actor BridgeContributionCaptureGate {
    private struct StartedCaptureWaiter {
        let requestedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var startedCaptureCount = 0
    private var startedCaptureWaiters: [StartedCaptureWaiter] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func waitUntilReleased() async {
        startedCaptureCount += 1
        resumeSatisfiedStartedCaptureWaiters()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitForStart() async {
        await waitForStartedCaptureCount(1)
    }

    func waitForStartedCaptureCount(_ requestedCount: Int) async {
        guard startedCaptureCount < requestedCount else { return }
        await withCheckedContinuation { continuation in
            startedCaptureWaiters.append(
                StartedCaptureWaiter(
                    requestedCount: requestedCount,
                    continuation: continuation
                )
            )
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func releaseFirst() {
        guard !releaseContinuations.isEmpty else { return }
        releaseContinuations.removeFirst().resume()
    }

    private func resumeSatisfiedStartedCaptureWaiters() {
        var pendingWaiters: [StartedCaptureWaiter] = []
        for waiter in startedCaptureWaiters {
            if startedCaptureCount >= waiter.requestedCount {
                waiter.continuation.resume()
            } else {
                pendingWaiters.append(waiter)
            }
        }
        startedCaptureWaiters = pendingWaiters
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

    func hasStartedComparisonCount(_ requestedCount: Int) -> Bool {
        startedComparisonCount >= requestedCount
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func releaseFirst() {
        guard !releaseContinuations.isEmpty else { return }
        releaseContinuations.removeFirst().resume()
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
