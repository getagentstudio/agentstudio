import AgentStudioInfrastructure
import Foundation
import Security

package struct BridgeProductSessionInstallation: Sendable {
    let bootstrap: BridgeProductSessionBootstrap
    let capabilityBytes: [UInt8]
    let productAdmissionGate: BridgeProductAdmissionGate
    let installationAdmissionGate: BridgeProductAdmissionGate
    let productAdapter: BridgeProductSchemeAdapter
    let session: BridgeProductSession

    var installationFence: BridgeProductInstallationFence {
        .init(workerInstanceId: bootstrap.workerInstanceId, gate: installationAdmissionGate)
    }

    static func make(
        paneSessionId: String,
        provider: any BridgeProductSchemeProvider,
        productAdmissionGate: BridgeProductAdmissionGate,
        telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil,
        deadlineClock: (any Clock<Duration> & Sendable)? = nil
    ) throws -> Self {
        var capabilityBytes = [UInt8](
            repeating: 0,
            count: BridgeProductWireContract.capabilityByteLength
        )
        let randomStatus = capabilityBytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw BridgePaneProductSessionOwnerError.secureRandomGenerationFailed(randomStatus)
        }

        let bootstrap = BridgeProductSessionBootstrap(
            paneSessionId: paneSessionId,
            workerInstanceId: UUID().uuidString
        )
        let session = try BridgeProductSession(
            paneSessionId: paneSessionId,
            workerInstanceId: bootstrap.workerInstanceId,
            capabilityBytes: capabilityBytes,
            deadlineClock: deadlineClock
        )
        let installationAdmissionGate = BridgeProductAdmissionGate()
        return Self(
            bootstrap: bootstrap,
            capabilityBytes: capabilityBytes,
            productAdmissionGate: productAdmissionGate,
            installationAdmissionGate: installationAdmissionGate,
            productAdapter: BridgeProductSchemeAdapter(
                session: session,
                provider: provider,
                productAdmissionGate: productAdmissionGate,
                installationAdmissionGate: installationAdmissionGate,
                telemetryRecorder: telemetryRecorder
            ),
            session: session
        )
    }
}

enum BridgePaneProductSessionOwnerError: Error, Equatable {
    case ownerDisposed
    case secureRandomGenerationFailed(OSStatus)
}

enum BridgePaneProductSessionActivationResult: Equatable, Sendable {
    case activated
    case invalidCandidate
    case ownerDisposed
    case revocationFailed
}

enum BridgePaneProductSessionRetirementReason: Equatable, Sendable {
    case paneDisposal
    case pageReload
    case workerReplacement
}

enum BridgePaneProductSessionRetirementResult: Equatable, Sendable {
    case retired
    case revocationFailed
    case quiescenceDeadlineExceeded(unfinishedExecutionCount: Int)
}

struct BridgePaneProductSessionOwnerSnapshot: Equatable, Sendable {
    let activeSchemeTaskCount: Int
    let activeProducerCount: Int
    let activeProducerTaskCount: Int
    let activeContentLeaseCount: Int
    let activeEscapeEffectCount: Int
    let activeOperationExecutionCount: Int
    let activeTransportLeaseCount: Int
    let queuedFrameCount: Int
    let queuedByteCount: Int
    let pendingFrameWaiterCount: Int
    let inFlightFrameReceiptCount: Int
    let pendingLifecycleAcknowledgementCount: Int
    let preparedInstallationCount: Int
    let pendingControlCount: Int
    let retainedOperationResultCount: Int
    let retiringInstallationCount: Int
    let sessionContentAdmissionCount: Int
    let sessionProductAdmissionCount: Int
    let nextMetadataStreamSequence: Int

    var hasZeroResidue: Bool {
        activeSchemeTaskCount == 0
            && activeProducerCount == 0
            && activeProducerTaskCount == 0
            && activeContentLeaseCount == 0
            && activeEscapeEffectCount == 0
            && activeOperationExecutionCount == 0
            && activeTransportLeaseCount == 0
            && queuedFrameCount == 0
            && queuedByteCount == 0
            && pendingFrameWaiterCount == 0
            && inFlightFrameReceiptCount == 0
            && pendingLifecycleAcknowledgementCount == 0
            && preparedInstallationCount == 0
            && pendingControlCount == 0
            && retainedOperationResultCount == 0
            && retiringInstallationCount == 0
            && sessionContentAdmissionCount == 0
            && sessionProductAdmissionCount == 0
    }

    static let empty = Self(
        activeSchemeTaskCount: 0,
        activeProducerCount: 0,
        activeProducerTaskCount: 0,
        activeContentLeaseCount: 0,
        activeEscapeEffectCount: 0,
        activeOperationExecutionCount: 0,
        activeTransportLeaseCount: 0,
        queuedFrameCount: 0,
        queuedByteCount: 0,
        pendingFrameWaiterCount: 0,
        inFlightFrameReceiptCount: 0,
        pendingLifecycleAcknowledgementCount: 0,
        preparedInstallationCount: 0,
        pendingControlCount: 0,
        retainedOperationResultCount: 0,
        retiringInstallationCount: 0,
        sessionContentAdmissionCount: 0,
        sessionProductAdmissionCount: 0,
        nextMetadataStreamSequence: 0
    )
}

package actor BridgePaneProductSessionOwner {
    let schemeRouter: BridgeProductSchemeSessionRouter
    nonisolated let productAdmissionGate: BridgeProductAdmissionGate
    nonisolated let installationFenceProjection: BridgeProductInstallationFenceProjection

    nonisolated func closeActiveInstallation() -> BridgeProductInstallationFenceSnapshot {
        let snapshot = installationFenceProjection.snapshot
        snapshot.close()
        return snapshot
    }

    private(set) var activeInstallation: BridgeProductSessionInstallation?
    private var activationInFlightWorkerInstanceIds: Set<String> = []
    private var isPaneDisposalRequested = false
    private var lifecycleTransitionTail: Task<Void, Never>?
    private let paneSessionId: String
    private let operationDeadlineClock: (any Clock<Duration> & Sendable)?
    private var preparedInstallationsByWorkerInstanceId: [String: BridgeProductSessionInstallation] = [:]
    private let provider: any BridgeProductSchemeProvider
    private let retirementDelay: AsyncDelay
    private let telemetryRecorder: (any BridgePerformanceTraceRecording)?
    private let didRetireWorkerInstance: @Sendable (String) async -> Void
    private var retiringInstallationsByWorkerInstanceId: [String: BridgeProductSessionInstallation] = [:]
    private var retirementTasksByWorkerInstanceId: [String: Task<Bool, Never>] = [:]

    package func activeBootstrap() -> BridgeProductSessionBootstrap? {
        activeInstallation?.bootstrap
    }

    init(
        paneSessionId: String,
        provider: any BridgeProductSchemeProvider,
        productAdmissionGate: BridgeProductAdmissionGate,
        activeInstallation: BridgeProductSessionInstallation? = nil,
        telemetryRecorder: (any BridgePerformanceTraceRecording)? = nil,
        operationDeadlineClock: (any Clock<Duration> & Sendable)? = nil,
        didRetireWorkerInstance: @escaping @Sendable (String) async -> Void = { _ in },
        retirementClock: (any Clock<Duration> & Sendable)? = nil,
        schemeTaskCensus: BridgeProductSchemeTaskCensus = BridgeProductSchemeTaskCensus()
    ) throws {
        try BridgeProductContractDecoding.validateIdentifier(paneSessionId, codingPath: [])
        precondition(
            activeInstallation == nil
                || activeInstallation?.productAdmissionGate === productAdmissionGate
        )
        self.paneSessionId = paneSessionId
        self.operationDeadlineClock = operationDeadlineClock
        self.provider = provider
        self.retirementDelay = retirementClock.map(AsyncDelay.clock) ?? .taskSleep
        self.telemetryRecorder = telemetryRecorder
        self.didRetireWorkerInstance = didRetireWorkerInstance
        self.productAdmissionGate = productAdmissionGate
        self.activeInstallation = activeInstallation
        self.installationFenceProjection = BridgeProductInstallationFenceProjection(
            activeInstallation?.installationFence)
        self.schemeRouter = BridgeProductSchemeSessionRouter(
            activeInstallation: activeInstallation,
            productAdmissionGate: productAdmissionGate,
            schemeTaskCensus: schemeTaskCensus
        )
    }

    func prepareCandidate(
        productAdmission: BridgeProductAdmissionContext
    ) throws -> BridgeProductSessionInstallation {
        guard productAdmission.wasMinted(by: productAdmissionGate),
            let candidate = try productAdmission.withValidAdmission({
                guard !isPaneDisposalRequested else {
                    throw BridgePaneProductSessionOwnerError.ownerDisposed
                }
                let candidate = try BridgeProductSessionInstallation.make(
                    paneSessionId: paneSessionId,
                    provider: provider,
                    productAdmissionGate: productAdmissionGate,
                    telemetryRecorder: telemetryRecorder,
                    deadlineClock: operationDeadlineClock
                )
                preparedInstallationsByWorkerInstanceId[candidate.bootstrap.workerInstanceId] = candidate
                return candidate
            })
        else {
            throw BridgePaneProductSessionOwnerError.ownerDisposed
        }
        return candidate
    }

    nonisolated func activatePreparedCandidate(
        _ candidate: BridgeProductSessionInstallation,
        productAdmission: BridgeProductAdmissionContext,
        replacing expectedPredecessor: BridgeProductInstallationFenceSnapshot? = nil
    ) async -> BridgePaneProductSessionActivationResult {
        let predecessor = expectedPredecessor ?? installationFenceProjection.snapshot
        predecessor.close()
        return await enqueueActivation(candidate, productAdmission: productAdmission, predecessor: predecessor)
    }

    private func enqueueActivation(
        _ candidate: BridgeProductSessionInstallation,
        productAdmission: BridgeProductAdmissionContext,
        predecessor: BridgeProductInstallationFenceSnapshot
    ) async -> BridgePaneProductSessionActivationResult {
        let workerInstanceId = candidate.bootstrap.workerInstanceId
        guard
            let preparedCandidate = preparedInstallationsByWorkerInstanceId[workerInstanceId],
            preparedCandidate.bootstrap == candidate.bootstrap,
            preparedCandidate.capabilityBytes == candidate.capabilityBytes,
            !activationInFlightWorkerInstanceIds.contains(workerInstanceId)
        else {
            return .invalidCandidate
        }
        guard productAdmission.wasMinted(by: productAdmissionGate),
            (productAdmission.withValidAdmission {
                activationInFlightWorkerInstanceIds.insert(workerInstanceId)
                return true
            }) == true
        else {
            return await rejectPreparedCandidateAfterAdmissionClose(candidate)
        }
        guard !isPaneDisposalRequested else {
            return await rejectPreparedCandidateAfterAdmissionClose(preparedCandidate)
        }

        let precedingTransition = lifecycleTransitionTail
        let transition = Task { [self] in
            if let precedingTransition {
                await precedingTransition.value
            }
            return await performActivation(
                preparedCandidate,
                productAdmission: productAdmission,
                predecessor: predecessor
            )
        }
        lifecycleTransitionTail = Task {
            _ = await transition.value
        }
        return await transition.value
    }

    nonisolated func retire(
        reason: BridgePaneProductSessionRetirementReason,
        installation expectedInstallation: BridgeProductInstallationFenceSnapshot? = nil
    ) async -> BridgePaneProductSessionRetirementResult {
        if reason == .paneDisposal { productAdmissionGate.close() }
        let expected = expectedInstallation ?? closeActiveInstallation()
        expected.close()
        return await enqueueRetirement(reason: reason, expected: expected)
    }

    private func enqueueRetirement(
        reason: BridgePaneProductSessionRetirementReason,
        expected: BridgeProductInstallationFenceSnapshot
    ) async -> BridgePaneProductSessionRetirementResult {
        if reason == .paneDisposal {
            isPaneDisposalRequested = true
        }
        let precedingTransition = lifecycleTransitionTail
        let transition = Task { [self] in
            if let precedingTransition {
                await precedingTransition.value
            }
            return await performRetirement(reason: reason, expected: expected)
        }
        lifecycleTransitionTail = Task {
            _ = await transition.value
        }
        guard reason == .paneDisposal else { return await transition.value }
        let (completionStream, completionSignal) = AsyncStream.makeStream(
            of: BridgePaneProductSessionRetirementResult.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        Task {
            completionSignal.yield(await transition.value)
            completionSignal.finish()
        }
        let deadlineTask = Task { [self] in
            do {
                try await retirementDelay.wait(AppPolicies.Bridge.productRetirementQuiescenceDeadline)
            } catch is CancellationError {
                return
            } catch {
                // A failed clock still resolves disposal through the typed diagnostic.
            }
            let unfinishedExecutionCount = await snapshot().activeOperationExecutionCount
            completionSignal.yield(
                .quiescenceDeadlineExceeded(unfinishedExecutionCount: unfinishedExecutionCount)
            )
            completionSignal.finish()
        }
        var completionIterator = completionStream.makeAsyncIterator()
        let result = await completionIterator.next() ?? .revocationFailed
        deadlineTask.cancel()
        return result
    }

    private func performActivation(
        _ candidate: BridgeProductSessionInstallation,
        productAdmission: BridgeProductAdmissionContext,
        predecessor: BridgeProductInstallationFenceSnapshot
    ) async -> BridgePaneProductSessionActivationResult {
        let workerInstanceId = candidate.bootstrap.workerInstanceId
        defer {
            activationInFlightWorkerInstanceIds.remove(workerInstanceId)
        }
        guard installationFenceProjection.snapshot == predecessor else {
            _ = await rejectPreparedCandidateAfterAdmissionClose(candidate)
            return .invalidCandidate
        }
        guard !isPaneDisposalRequested,
            (productAdmission.withValidAdmission { true }) == true
        else {
            return await rejectPreparedCandidateAfterAdmissionClose(candidate)
        }

        let retiringInstallation = activeInstallation
        guard
            (productAdmission.withValidAdmission {
                activeInstallation = nil
                installationFenceProjection.publish(nil)
                return true
            }) == true
        else {
            return await rejectPreparedCandidateAfterAdmissionClose(candidate)
        }
        if let retiringInstallation {
            await provider.revokeWorkerIdentity(retiringInstallation.bootstrap.workerInstanceId)
        }
        await schemeRouter.clear(installation: retiringInstallation?.installationFence)

        if let retiringInstallation,
            retiringInstallation.bootstrap.workerInstanceId != candidate.bootstrap.workerInstanceId
        {
            await beginRetiring(retiringInstallation)
            await provider.invalidatePendingComparisonTargetReservation()
        }
        for installation in Array(retiringInstallationsByWorkerInstanceId.values)
        where retirementTasksByWorkerInstanceId[installation.bootstrap.workerInstanceId] == nil {
            await beginRetiring(installation)
        }
        guard !isPaneDisposalRequested,
            (productAdmission.withValidAdmission { true }) == true
        else {
            return await rejectPreparedCandidateAfterAdmissionClose(candidate)
        }

        guard
            (productAdmission.withValidAdmission {
                preparedInstallationsByWorkerInstanceId.removeValue(forKey: workerInstanceId)
                activeInstallation = candidate
                installationFenceProjection.publish(candidate.installationFence)
                return true
            }) == true
        else {
            return await rejectPreparedCandidateAfterAdmissionClose(candidate)
        }
        await provider.activateWorkerIdentity(workerInstanceId)
        guard
            await schemeRouter.activate(
                candidate,
                productAdmission: productAdmission
            )
        else {
            activeInstallation = nil
            installationFenceProjection.publish(nil)
            candidate.installationFence.close()
            await provider.revokeWorkerIdentity(workerInstanceId)
            return await rejectPreparedCandidateAfterAdmissionClose(candidate)
        }
        return .activated
    }

    func rejectPreparedCandidateAfterAdmissionClose(
        _ candidate: BridgeProductSessionInstallation
    ) async -> BridgePaneProductSessionActivationResult {
        let workerInstanceId = candidate.bootstrap.workerInstanceId
        candidate.installationFence.close()
        preparedInstallationsByWorkerInstanceId.removeValue(forKey: workerInstanceId)
        activationInFlightWorkerInstanceIds.remove(workerInstanceId)
        let barrier = await candidate.session.revoke(
            acknowledgeLifecycle: provider.acknowledgeLifecycle
        )
        _ = await barrier.wait()
        return .ownerDisposed
    }

    private func beginRetiring(_ installation: BridgeProductSessionInstallation) async {
        installation.installationFence.close()
        let workerInstanceId = installation.bootstrap.workerInstanceId
        guard retirementTasksByWorkerInstanceId[workerInstanceId] == nil else { return }
        retiringInstallationsByWorkerInstanceId[workerInstanceId] = installation
        let barrier = await installation.session.revoke(
            acknowledgeLifecycle: provider.acknowledgeLifecycle
        )
        retirementTasksByWorkerInstanceId[workerInstanceId] = Task { [self] in
            let didRevoke = await barrier.wait()
            await schemeRouter.waitForDrain(of: workerInstanceId)
            await installation.session.waitForOutstandingOperationExecutions()
            await installation.session.waitForOutstandingEscapeEffects()
            if didRevoke {
                await didRetireWorkerInstance(workerInstanceId)
                retiringInstallationsByWorkerInstanceId.removeValue(forKey: workerInstanceId)
            }
            retirementTasksByWorkerInstanceId.removeValue(forKey: workerInstanceId)
            return didRevoke
        }
    }

    private func performRetirement(
        reason: BridgePaneProductSessionRetirementReason,
        expected: BridgeProductInstallationFenceSnapshot
    ) async -> BridgePaneProductSessionRetirementResult {
        guard reason == .paneDisposal || installationFenceProjection.snapshot == expected else { return .retired }
        let retiringInstallation = activeInstallation
        retiringInstallation?.installationFence.close()
        activeInstallation = nil
        installationFenceProjection.publish(nil)
        if let retiringInstallation {
            await provider.revokeWorkerIdentity(retiringInstallation.bootstrap.workerInstanceId)
        }
        await provider.invalidatePendingComparisonTargetReservation()
        await schemeRouter.clear(installation: retiringInstallation?.installationFence)
        if let retiringInstallation {
            await beginRetiring(retiringInstallation)
        }
        for installation in Array(retiringInstallationsByWorkerInstanceId.values)
        where retirementTasksByWorkerInstanceId[installation.bootstrap.workerInstanceId] == nil {
            await beginRetiring(installation)
        }

        // Page reload and worker replacement only fence. Old work may release
        // after the successor is already serving requests.
        guard reason == .paneDisposal else { return .retired }
        let retirementTasks = Array(retirementTasksByWorkerInstanceId.values)
        var didRevokeEveryInstallation = true
        for task in retirementTasks {
            if !(await task.value) { didRevokeEveryInstallation = false }
        }
        await schemeRouter.waitForDrain()
        let didRetirePrepared = await retirePreparedInstallationsForPaneDisposal()
        return didRevokeEveryInstallation && didRetirePrepared
            && retiringInstallationsByWorkerInstanceId.isEmpty
            ? .retired : .revocationFailed
    }

    func waitForRetirement(of workerInstanceId: String) async -> Bool {
        if let task = retirementTasksByWorkerInstanceId[workerInstanceId] {
            return await task.value
        }
        return retiringInstallationsByWorkerInstanceId[workerInstanceId] == nil
    }

    func retryRetirement(of workerInstanceId: String) async -> Bool {
        guard let installation = retiringInstallationsByWorkerInstanceId[workerInstanceId] else {
            return true
        }
        await beginRetiring(installation)
        return await waitForRetirement(of: workerInstanceId)
    }

    private func retirePreparedInstallationsForPaneDisposal() async -> Bool {
        guard isPaneDisposalRequested else { return true }
        for (workerInstanceId, installation) in preparedInstallationsByWorkerInstanceId {
            installation.installationFence.close()
            let barrier = await installation.session.revoke(
                acknowledgeLifecycle: provider.acknowledgeLifecycle
            )
            guard await barrier.wait() else { return false }
            preparedInstallationsByWorkerInstanceId.removeValue(forKey: workerInstanceId)
        }
        return true
    }

    func snapshot() async -> BridgePaneProductSessionOwnerSnapshot {
        let routerSnapshot = await schemeRouter.snapshot
        var installations = retiringInstallationsByWorkerInstanceId
        if let activeInstallation {
            installations[activeInstallation.bootstrap.workerInstanceId] = activeInstallation
        }
        var diagnosticSnapshots: [BridgeProductSessionDiagnosticSnapshot] = []
        for installation in installations.values {
            diagnosticSnapshots.append(await installation.session.diagnosticSnapshot)
        }
        let producerSnapshots = diagnosticSnapshots.map(\.producer)
        func total(_ field: KeyPath<BridgeProductProducerRegistrySnapshot, Int>) -> Int {
            producerSnapshots.reduce(0) { $0 + $1[keyPath: field] }
        }
        func diagnosticTotal(_ field: KeyPath<BridgeProductSessionDiagnosticSnapshot, Int>) -> Int {
            diagnosticSnapshots.reduce(0) { $0 + $1[keyPath: field] }
        }
        return .init(
            activeSchemeTaskCount: routerSnapshot.activeSchemeTaskCount,
            activeProducerCount: total(\.activeProducerCount),
            activeProducerTaskCount: total(\.activeProducerTaskCount),
            activeContentLeaseCount: total(\.activeContentLeaseCount),
            activeEscapeEffectCount: diagnosticTotal(\.activeEscapeEffectCount),
            activeOperationExecutionCount: diagnosticTotal(\.activeOperationExecutionCount),
            activeTransportLeaseCount: routerSnapshot.activeTransportClaimCount,
            queuedFrameCount: total(\.queuedFrameCount),
            queuedByteCount: total(\.queuedByteCount),
            pendingFrameWaiterCount: total(\.pendingFrameWaiterCount),
            inFlightFrameReceiptCount: total(\.inFlightFrameReceiptCount),
            pendingLifecycleAcknowledgementCount: total(\.pendingLifecycleAcknowledgementCount),
            preparedInstallationCount: preparedInstallationsByWorkerInstanceId.count,
            pendingControlCount: diagnosticTotal(\.pendingControlCount),
            retainedOperationResultCount: diagnosticTotal(\.retainedOperationResultCount),
            retiringInstallationCount: retiringInstallationsByWorkerInstanceId.count,
            sessionContentAdmissionCount: total(\.sessionContentAdmissionCount),
            sessionProductAdmissionCount: total(\.sessionProductAdmissionCount),
            nextMetadataStreamSequence: producerSnapshots.map(\.nextMetadataStreamSequence).max() ?? 0
        )
    }
}
