import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

actor RefreshAdmissionTrackingFileMetadataSource: BridgePaneProductFileMetadataProducing {
    func captureKeyedSnapshot(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext
    ) async -> BridgeWorktreeFileKeyedSnapshot? { nil }

    private let failsChangesetPublication: Bool
    private var retryableChangesetFailuresRemaining: Int
    private let changesetPublicationGate: RefreshAdmissionCancellationIgnoringProducerGate?
    private let metadataProducerGate: RefreshAdmissionCancellationIgnoringProducerGate?
    private var changesets: [FileChangeset] = []
    private var statuses: [GitWorkingTreeStatus] = []
    private var changesetPublishAttempts = 0
    private var changesetWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var statusWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var changesetPublishCount: Int { changesets.count }
    var statusPublishCount: Int { statuses.count }
    var changesetPublishAttemptCount: Int { changesetPublishAttempts }

    init(
        failsChangesetPublication: Bool = false,
        retryableChangesetFailureCount: Int = 0,
        changesetPublicationGate: RefreshAdmissionCancellationIgnoringProducerGate? = nil,
        metadataProducerGate: RefreshAdmissionCancellationIgnoringProducerGate? = nil
    ) {
        self.failsChangesetPublication = failsChangesetPublication
        self.retryableChangesetFailuresRemaining = retryableChangesetFailureCount
        self.changesetPublicationGate = changesetPublicationGate
        self.metadataProducerGate = metadataProducerGate
    }

    func currentSource() -> BridgeProductFileSourceCurrentResult {
        .unavailable(.noFileSourceAuthority)
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        await metadataProducerGate?.holdIgnoringCancellation()
    }

    func applyViewDemand(
        subscriptionId _: String,
        demand _: BridgePaneProductFileViewDemand,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission _: BridgePaneRefreshWorkAdmission,
        forceRecapture _: Bool,
        emit _: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {}

    func cancel(subscriptionId _: String) {}

    func publish(
        status: GitWorkingTreeStatus,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> [BridgePaneProductFileMetadataEmission] {
        _ = foregroundWorkAdmission.withValidAdmission {
            statuses.append(status)
            resumeSatisfiedStatusWaiters()
        }
        return []
    }

    func publish(
        changeset: FileChangeset,
        productAdmission _: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) async throws -> [BridgePaneProductFileMetadataEmission] {
        changesetPublishAttempts += 1
        await changesetPublicationGate?.holdIgnoringCancellation()
        if retryableChangesetFailuresRemaining > 0 {
            retryableChangesetFailuresRemaining -= 1
            throw BridgePaneProductFileMetadataSourceError.unavailableAuthority
        }
        if failsChangesetPublication {
            throw RefreshAdmissionInjectedFileMetadataFailure.changesetPublication
        }
        _ = foregroundWorkAdmission.withValidAdmission {
            changesets.append(changeset)
            resumeSatisfiedChangesetWaiters()
        }
        return []
    }

    func authoritativePath(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> String? { nil }

    func contentReadPlan(
        for _: BridgeProductFileContentRequest,
        productAdmission _: BridgeProductAdmissionContext
    ) -> BridgePaneProductFileContentReadPlan? { nil }

    func publishedChangesets() -> [FileChangeset] { changesets }
    func publishedStatuses() -> [GitWorkingTreeStatus] { statuses }

    func waitForChangesetPublishCount(_ expectedCount: Int) async {
        guard changesets.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            changesetWaiters.append((expectedCount, continuation))
        }
    }

    func waitForStatusPublishCount(_ expectedCount: Int) async {
        guard statuses.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            statusWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeSatisfiedChangesetWaiters() {
        var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in changesetWaiters {
            if changesets.count >= expectedCount {
                continuation.resume()
            } else {
                pendingWaiters.append((expectedCount, continuation))
            }
        }
        changesetWaiters = pendingWaiters
    }

    private func resumeSatisfiedStatusWaiters() {
        var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expectedCount, continuation) in statusWaiters {
            if statuses.count >= expectedCount {
                continuation.resume()
            } else {
                pendingWaiters.append((expectedCount, continuation))
            }
        }
        statusWaiters = pendingWaiters
    }
}

final class RefreshAdmissionCancellationIgnoringProducerGate: @unchecked Sendable {
    private struct StartedWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var cancellationRequested = false
        var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        var isReleased = false
        var releaseContinuations: [CheckedContinuation<Void, Never>] = []
        var startedCount = 0
        var startWaiters: [StartedWaiter] = []
    }

    private let lock = NSLock()
    private var state = State()

    func holdIgnoringCancellation() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let outcome = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    state.startedCount += 1
                    let currentStartedCount = state.startedCount
                    var pendingStartWaiters: [StartedWaiter] = []
                    var satisfiedStartWaiters: [CheckedContinuation<Void, Never>] = []
                    for waiter in state.startWaiters {
                        if currentStartedCount >= waiter.expectedCount {
                            satisfiedStartWaiters.append(waiter.continuation)
                        } else {
                            pendingStartWaiters.append(waiter)
                        }
                    }
                    state.startWaiters = pendingStartWaiters
                    if state.isReleased {
                        return (true, satisfiedStartWaiters)
                    }
                    state.releaseContinuations.append(continuation)
                    return (false, satisfiedStartWaiters)
                }
                for waiter in outcome.1 { waiter.resume() }
                if outcome.0 { continuation.resume() }
            }
        } onCancel: {
            self.recordCancellationRequest()
        }
    }

    func waitUntilStarted() async {
        await waitUntilStartedCount(1)
    }

    func waitUntilStartedCount(_ expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard state.startedCount < expectedCount else { return true }
                state.startWaiters.append(
                    StartedWaiter(expectedCount: expectedCount, continuation: continuation)
                )
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func waitUntilCancellationRequested() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard !state.cancellationRequested else { return true }
                state.cancellationWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func releaseAll() {
        let continuations = lock.withLock {
            state.isReleased = true
            let continuations = state.releaseContinuations
            state.releaseContinuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func releaseFirst() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !state.releaseContinuations.isEmpty else { return nil }
            return state.releaseContinuations.removeFirst()
        }
        continuation?.resume()
    }

    func releaseLatest() {
        let continuation = lock.withLock {
            state.releaseContinuations.popLast()
        }
        continuation?.resume()
    }

    private func recordCancellationRequest() {
        let waiters = lock.withLock {
            state.cancellationRequested = true
            let waiters = state.cancellationWaiters
            state.cancellationWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

actor RefreshAdmissionReviewReservationGate {
    private struct StartedWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var heldReservationCount = 0
    private var isEnabled = false
    private var isReleased = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [StartedWaiter] = []

    func enable() {
        isEnabled = true
    }

    func holdIfEnabled() async {
        guard isEnabled else { return }
        heldReservationCount += 1
        resumeSatisfiedStartedWaiters()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitForHeldReservationCount(_ expectedCount: Int) async {
        guard heldReservationCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(
                StartedWaiter(expectedCount: expectedCount, continuation: continuation)
            )
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func resumeSatisfiedStartedWaiters() {
        var pendingWaiters: [StartedWaiter] = []
        for waiter in startedWaiters {
            if heldReservationCount >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pendingWaiters.append(waiter)
            }
        }
        startedWaiters = pendingWaiters
    }
}

actor RefreshAdmissionGatedReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    private let failsReservation: Bool
    private let failsDelivery: Bool
    private let reservationGate: RefreshAdmissionReviewReservationGate?
    private let source = BridgePaneProductReviewMetadataSource()

    init(
        failsReservation: Bool,
        failsDelivery: Bool,
        reservationGate: RefreshAdmissionReviewReservationGate?
    ) {
        self.failsReservation = failsReservation
        self.failsDelivery = failsDelivery
        self.reservationGate = reservationGate
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        try await source.open(
            subscription: subscription,
            productAdmission: productAdmission
        )
    }

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        try await source.applyViewDemand(request)
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        await reservationGate?.holdIfEnabled()
        if failsReservation {
            throw BridgePaneProductReviewMetadataSourceError.metadataEventExceedsByteLimit
        }
        return try await source.reserve(
            package: package,
            publicationId: publicationId,
            productAdmission: productAdmission
        )
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        if failsDelivery {
            throw RefreshAdmissionInjectedReviewMetadataFailure.delivery
        }
        return try await source.deliver(
            publication: publication,
            reservation: reservation,
            productAdmission: productAdmission
        )
    }

    func cancel(subscriptionId: String) async {
        await source.cancel(subscriptionId: subscriptionId)
    }

}

private enum RefreshAdmissionInjectedFileMetadataFailure: Error {
    case changesetPublication
}

private enum RefreshAdmissionInjectedReviewMetadataFailure: Error {
    case delivery
}

enum RefreshAdmissionIntegrationError: Error {
    case expectedMetadataProducerRegistration
    case expectedMetadataFrame
    case expectedSubscriptionAcceptedFrame
    case expectedWorkerSessionExecution
    case fileSubscriptionDidNotOpen
    case metadataStreamDidNotInstall
    case reviewSubscriptionDidNotOpen
}
