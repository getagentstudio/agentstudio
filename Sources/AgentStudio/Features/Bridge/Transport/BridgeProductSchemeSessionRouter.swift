import Foundation

struct BridgeProductSchemeSessionRouterSnapshot: Equatable, Sendable {
    let activeSchemeTaskCount: Int
    let activeTransportClaimCount: Int
    let transportClaimMintCount: Int

    var hasZeroResidue: Bool {
        activeSchemeTaskCount == 0 && activeTransportClaimCount == 0
    }
}

struct BridgeProductSchemeTransportClaim: Sendable {
    let adapter: BridgeProductSchemeAdapter
    let productAdmission: BridgeProductAdmissionContext
    let workerInstanceId: String

    fileprivate let id: UUID
    fileprivate let router: BridgeProductSchemeSessionRouter

    func route(
        _ request: URLRequest,
        continuation: BridgeProductSchemeReplyContinuation
    ) async {
        await adapter.route(
            request,
            productAdmission: productAdmission,
            continuation: continuation,
            contentRequestAccepted: { contentRequestId in
                await associateContentRequest(contentRequestId)
            }
        )
    }

    func finish() async {
        await router.finish(self)
    }

    func associateContentRequest(_ contentRequestId: String) async {
        await router.associateContentRequest(contentRequestId, with: id)
    }
}

enum BridgeProductSchemeTransportAdmission: Sendable {
    case admitted(BridgeProductSchemeTransportClaim)
    case conflict
    case unauthorized
}

actor BridgeProductSchemeSessionRouter {
    private(set) var activeInstallation: BridgeProductSessionInstallation?
    private var activeSchemeTaskIds: Set<UUID> = []
    private var activeTransportClaimIds: Set<UUID> = []
    private var claimInstallationById: [UUID: String] = [:]
    private var activeStreamClaimIds: Set<UUID> = []
    private var contentRequestIdByClaimId: [UUID: String] = [:]
    private var contentClaimFinishObservers: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaitersByInstallation: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var latestCapabilityAuthenticator: BridgeProductCapabilityAuthenticator?
    private let productAdmissionGate: BridgeProductAdmissionGate
    private var streamDrainWaitersById: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextStreamDrainWaiterId: UInt64 = 0
    private var cancelledStreamDrainWaiterIds: Set<UInt64> = []
    private var transportClaimMintCount = 0
    private var transportClaimMintCountByInstallation: [String: Int] = [:]
    private var metadataStreamClaimMintCountByInstallation: [String: Int] = [:]
    private let streamDrainWaiterRegistrationObserver: (@Sendable () -> Void)?

    /// Reachable without an actor hop because `onTermination` is synchronous.
    nonisolated let schemeTaskCensus: BridgeProductSchemeTaskCensus

    init(
        activeInstallation: BridgeProductSessionInstallation? = nil,
        productAdmissionGate: BridgeProductAdmissionGate,
        schemeTaskCensus: BridgeProductSchemeTaskCensus = BridgeProductSchemeTaskCensus(),
        streamDrainWaiterRegistrationObserver: (@Sendable () -> Void)? = nil
    ) {
        self.schemeTaskCensus = schemeTaskCensus
        self.streamDrainWaiterRegistrationObserver = streamDrainWaiterRegistrationObserver
        precondition(
            activeInstallation == nil
                || activeInstallation?.productAdmissionGate === productAdmissionGate
        )
        self.activeInstallation = activeInstallation
        self.latestCapabilityAuthenticator = activeInstallation?.session.capabilityAuthenticator
        self.productAdmissionGate = productAdmissionGate
    }

    func activate(
        _ installation: BridgeProductSessionInstallation,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        guard productAdmission.wasMinted(by: productAdmissionGate) else { return false }
        guard let installationAdmission = productAdmission.withInstallation(installation.installationAdmissionGate)
        else { return false }
        return installationAdmission.withValidAdmission {
            precondition(installation.productAdmissionGate === productAdmissionGate)
            activeInstallation = installation
            latestCapabilityAuthenticator = installation.session.capabilityAuthenticator
            return true
        } ?? false
    }

    func clear() {
        activeInstallation?.installationFence.close()
        activeInstallation = nil
        let waiters = clearWaiters
        clearWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        resumeAllStreamDrainWaiters()
    }

    /// Cleanup for A must never clear B after a suspended lifecycle transition.
    func clear(installation expected: BridgeProductInstallationFence?) {
        guard activeInstallation?.installationFence == expected else { return }
        clear()
    }

    /// Authorization and close run in this actor turn, atomically relative to new metadata claims.
    func closeTerminatedInstallation(
        _ expected: BridgeProductInstallationFence,
        authorization: BridgeDevelopmentBootstrapAuthorizationSnapshot,
        projection: BridgeDevelopmentBootstrapAuthorizationProjection
    ) -> Bool {
        let currentAuthorization = projection.snapshot
        guard !currentAuthorization.isShutdown, currentAuthorization == authorization,
            activeInstallation?.installationFence == expected,
            metadataStreamHasEnded(for: expected.workerInstanceId)
        else { return false }
        expected.close()
        return true
    }

    func waitUntilCleared() async {
        guard activeInstallation != nil else { return }
        await withCheckedContinuation { continuation in
            clearWaiters.append(continuation)
        }
    }

    /// - Parameters:
    ///   - schemeTaskId: minted by the scheme handler before the reply task so
    ///     the census and the claim are the same identity.
    ///   - route: only a metadata stream joins the stream-scoped drain; a live
    ///     content stream must never hold a bootstrap open.
    func claimActiveAdapter(
        presentedCapability: String,
        schemeTaskId: UUID,
        route: BridgeProductSchemeRoute?
    ) -> BridgeProductSchemeTransportAdmission {
        guard latestCapabilityAuthenticator?.matches(presentedCapability) == true else {
            return .unauthorized
        }
        guard let activeInstallation,
            let productAdmission = activeInstallation.productAdapter.acquireAdmission()
        else {
            return .conflict
        }
        let claimId = schemeTaskId
        let workerInstanceId = activeInstallation.bootstrap.workerInstanceId
        activeSchemeTaskIds.insert(claimId)
        activeTransportClaimIds.insert(claimId)
        claimInstallationById[claimId] = workerInstanceId
        if route == .metadataStream {
            activeStreamClaimIds.insert(claimId)
            metadataStreamClaimMintCountByInstallation[workerInstanceId, default: 0] += 1
        }
        transportClaimMintCount += 1
        transportClaimMintCountByInstallation[workerInstanceId, default: 0] += 1
        return .admitted(
            BridgeProductSchemeTransportClaim(
                adapter: activeInstallation.productAdapter,
                productAdmission: productAdmission,
                workerInstanceId: workerInstanceId,
                id: claimId,
                router: self
            )
        )
    }

    /// An unstarted successor is still owned by its tab. Once this installation
    /// has streamed, synchronous termination evidence can release dev-tab
    /// ownership before its asynchronous claim cleanup finishes.
    func metadataStreamHasEnded(for workerInstanceId: String) -> Bool {
        guard metadataStreamClaimMintCountByInstallation[workerInstanceId, default: 0] > 0 else {
            return false
        }
        return activeStreamClaimIds.allSatisfy { claimID in
            claimInstallationById[claimID] != workerInstanceId
                || schemeTaskCensus.isTerminated(claimID)
        }
    }

    func waitForDrain() async {
        guard !snapshot.hasZeroResidue else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    func waitForDrain(of workerInstanceId: String) async {
        guard !snapshot(for: workerInstanceId).hasZeroResidue else { return }
        await withCheckedContinuation { continuation in
            drainWaitersByInstallation[workerInstanceId, default: []].append(continuation)
        }
    }

    func observeContentClaimFinish(for contentRequestId: String) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observationId = UUID()
        contentClaimFinishObservers[contentRequestId, default: [:]][observationId] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContentClaimFinishObserver(
                    contentRequestId: contentRequestId,
                    observationId: observationId
                )
            }
        }
        return stream
    }

    func hasActiveContentClaim(for contentRequestId: String) -> Bool {
        contentRequestIdByClaimId.values.contains(contentRequestId)
    }

    fileprivate func associateContentRequest(_ contentRequestId: String, with claimId: UUID) {
        guard activeTransportClaimIds.contains(claimId) else { return }
        contentRequestIdByClaimId[claimId] = contentRequestId
    }

    private func removeContentClaimFinishObserver(
        contentRequestId: String,
        observationId: UUID
    ) {
        contentClaimFinishObservers[contentRequestId]?.removeValue(forKey: observationId)
        if contentClaimFinishObservers[contentRequestId]?.isEmpty == true {
            contentClaimFinishObservers.removeValue(forKey: contentRequestId)
        }
    }

    /// Resolves when no metadata-stream claim remains.
    ///
    /// Deliberately narrower than `waitForDrain()`: a command or content claim
    /// can legitimately outlive a stream, and waiting on one would hang a caller
    /// that only needs the stream's transport to be gone.
    func waitForStreamClaimDrain() async {
        guard !activeStreamClaimIds.isEmpty else { return }
        let waiterId = mintStreamDrainWaiterId()
        // Cancellation-safe and lost-wakeup-free. The handler can run BEFORE the
        // continuation is stored, so storing re-checks whether this id was already
        // cancelled and resumes immediately; every resume path removes the id
        // first, so exactly one resume happens on every interleaving.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                storeStreamDrainWaiter(continuation, id: waiterId)
            }
        } onCancel: {
            Task { await self.resumeStreamDrainWaiter(id: waiterId) }
        }
    }

    private func mintStreamDrainWaiterId() -> UInt64 {
        nextStreamDrainWaiterId += 1
        return nextStreamDrainWaiterId
    }

    private func storeStreamDrainWaiter(
        _ continuation: CheckedContinuation<Void, Never>,
        id waiterId: UInt64
    ) {
        if cancelledStreamDrainWaiterIds.remove(waiterId) != nil {
            // The cancellation handler already ran for this id.
            continuation.resume()
            return
        }
        streamDrainWaitersById[waiterId] = continuation
        streamDrainWaiterRegistrationObserver?()
    }

    private func resumeStreamDrainWaiter(id waiterId: UInt64) {
        guard let continuation = streamDrainWaitersById.removeValue(forKey: waiterId) else {
            // The handler beat the store; the store will resume immediately.
            cancelledStreamDrainWaiterIds.insert(waiterId)
            return
        }
        continuation.resume()
    }

    /// Resumes every parked stream-drain waiter. Called on every teardown path so
    /// a waiter can never outlive the router that would have woken it.
    private func resumeAllStreamDrainWaiters() {
        let parkedWaiters = streamDrainWaitersById
        streamDrainWaitersById.removeAll()
        for (_, continuation) in parkedWaiters { continuation.resume() }
    }

    var snapshot: BridgeProductSchemeSessionRouterSnapshot {
        .init(
            activeSchemeTaskCount: activeSchemeTaskIds.count,
            activeTransportClaimCount: activeTransportClaimIds.count,
            transportClaimMintCount: transportClaimMintCount
        )
    }

    func snapshot(for workerInstanceId: String) -> BridgeProductSchemeSessionRouterSnapshot {
        let activeClaims = claimInstallationById.values.filter { $0 == workerInstanceId }.count
        return .init(
            activeSchemeTaskCount: activeClaims,
            activeTransportClaimCount: activeClaims,
            transportClaimMintCount: transportClaimMintCountByInstallation[workerInstanceId, default: 0]
        )
    }

    fileprivate func finish(_ claim: BridgeProductSchemeTransportClaim) {
        activeSchemeTaskIds.remove(claim.id)
        activeTransportClaimIds.remove(claim.id)
        claimInstallationById.removeValue(forKey: claim.id)
        if let contentRequestId = contentRequestIdByClaimId.removeValue(forKey: claim.id) {
            let observers = contentClaimFinishObservers.removeValue(forKey: contentRequestId) ?? [:]
            for continuation in observers.values {
                continuation.yield(())
                continuation.finish()
            }
        }
        if activeStreamClaimIds.remove(claim.id) != nil, activeStreamClaimIds.isEmpty {
            resumeAllStreamDrainWaiters()
        }
        if snapshot(for: claim.workerInstanceId).hasZeroResidue {
            let scopedWaiters = drainWaitersByInstallation.removeValue(forKey: claim.workerInstanceId) ?? []
            for waiter in scopedWaiters { waiter.resume() }
        }
        guard snapshot.hasZeroResidue else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
