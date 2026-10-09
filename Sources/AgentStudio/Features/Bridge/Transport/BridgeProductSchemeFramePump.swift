import Foundation

struct BridgeProductProducerRetirementBarrier: Equatable, Sendable {
    private enum Storage: Sendable {
        case completed(Bool)
        case inFlight(Task<Bool, Never>)
    }

    private let id: UUID
    private let storage: Storage

    init(id: UUID, task: Task<Bool, Never>) {
        self.id = id
        self.storage = .inFlight(task)
    }

    init(id: UUID, completedResult: Bool) {
        self.id = id
        self.storage = .completed(completedResult)
    }

    func wait() async -> Bool {
        switch storage {
        case .completed(let result): result
        case .inFlight(let task): await task.value
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

enum BridgeProductSessionProducerRetirementState: Sendable {
    case inFlight(BridgeProductProducerRetirementBarrier)

    var barrier: BridgeProductProducerRetirementBarrier {
        switch self {
        case .inFlight(let barrier):
            barrier
        }
    }
}

struct BridgeProductSessionProducerFrameWaiter {
    let continuation: CheckedContinuation<BridgeProductProducerFramePullResult, Never>
    let token: UUID
}

enum BridgeProductSessionProducerFrameObservation {
    case awaiting(BridgeProductProducerFrameReceipt)
    case observed(BridgeProductProducerFrameReceipt)

    var receipt: BridgeProductProducerFrameReceipt {
        switch self {
        case .awaiting(let receipt), .observed(let receipt):
            receipt
        }
    }
}

struct BridgeProductSchemeFramePump: Sendable {
    private let acknowledgeLifecycle: BridgeProductSession.ProducerLifecycleAcknowledger
    private let producerLease: BridgeProductProducerLease
    private let productAdmission: BridgeProductAdmissionContext
    private let session: BridgeProductSession

    init(
        session: BridgeProductSession,
        producerLease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        acknowledgeLifecycle: @escaping BridgeProductSession.ProducerLifecycleAcknowledger
    ) {
        self.session = session
        self.producerLease = producerLease
        self.productAdmission = productAdmission
        self.acknowledgeLifecycle = acknowledgeLifecycle
    }

    func nextFrame() async -> BridgeProductProducerFramePullResult {
        let result = await session.pullProducerFrame(
            for: producerLease,
            productAdmission: productAdmission
        )
        guard case .finished = result else { return result }
        let retirement = await session.beginProducerRetirement(
            producerLease,
            acknowledgeLifecycle: acknowledgeLifecycle,
            stopRequest: nil,
            abandonOutstandingDelivery: false
        )
        return await retirement.wait() ? .finished : .rejected(.retirementFailed)
    }

    func acknowledgeFrameConsumed(
        _ receipt: BridgeProductProducerFrameReceipt
    ) async -> Bool {
        await session.acknowledgeProducerFrameConsumed(
            receipt,
            productAdmission: productAdmission
        )
    }

    func cancel() async -> Bool {
        let retirement = await session.beginProducerRetirement(
            producerLease,
            acknowledgeLifecycle: acknowledgeLifecycle,
            stopRequest: nil,
            abandonOutstandingDelivery: true
        )
        return await retirement.wait()
    }
}

extension BridgeProductSession {
    func pullProducerFrame(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgeProductProducerFramePullResult {
        let waiterToken = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                    return
                }
                if producerAdmissionMatches(productAdmission, for: lease) {
                    do {
                        try enqueueNextViewFrameIfAvailable(for: lease)
                    } catch {
                        continuation.resume(returning: .rejected(.producerEndedWithoutTerminal))
                        return
                    }
                }
                let admitted =
                    productAdmission.withValidAdmission {
                        guard producerAdmissionMatches(productAdmission, for: lease) else {
                            continuation.resume(returning: .rejected(.unknownLease))
                            return true
                        }
                        switch producerRegistry.prepareFramePull(
                            for: lease,
                            waiterToken: waiterToken
                        ) {
                        case .finished:
                            continuation.resume(returning: .finished)
                        case .frame(let delivery):
                            registerProducerFrameObservation(delivery.receipt)
                            recordContentFramePulled(delivery.receipt)
                            continuation.resume(returning: .frame(delivery))
                        case .rejected(let rejection):
                            continuation.resume(returning: .rejected(rejection))
                        case .wait:
                            producerFrameWaitersByLease[lease] = .init(
                                continuation: continuation,
                                token: waiterToken
                            )
                            producerFrameWaiterRegistrationObserver?(lease)
                        }
                        return true
                    } ?? false
                if !admitted {
                    continuation.resume(returning: .cancelled)
                }
            }
        } onCancel: {
            Task {
                await self.cancelProducerFrameWaiter(
                    for: lease,
                    waiterToken: waiterToken
                )
            }
        }
    }

    func acknowledgeProducerFrameConsumed(
        _ receipt: BridgeProductProducerFrameReceipt,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        productAdmission.withValidAdmission {
            guard producerAdmissionMatches(productAdmission, for: receipt.producerLease) else {
                return false
            }
            return acknowledgeProducerFrameObserved(receipt)
        } ?? false
    }

    func acknowledgeProducerFrameObserved(
        _ receipt: BridgeProductProducerFrameReceipt
    ) -> Bool {
        let lease = receipt.producerLease
        guard let observation = producerFrameObservationByLease[lease],
            observation.receipt == receipt,
            producerRegistry.acknowledgeFrameConsumed(receipt)
        else {
            return false
        }
        switch observation {
        case .awaiting:
            producerFrameObservationByLease[lease] = .observed(receipt)
        case .observed:
            return false
        }
        return true
    }

    func resumeProducerFrameWaiterIfPossible(
        for lease: BridgeProductProducerLease,
        admissionAlreadyHeld: Bool = false
    ) {
        if let waiter = producerFrameWaitersByLease[lease] {
            do {
                try enqueueNextViewFrameIfAvailable(
                    for: lease,
                    admissionAlreadyHeld: admissionAlreadyHeld
                )
            } catch {
                _ = producerRegistry.cancelFrameWaiter(for: lease, waiterToken: waiter.token)
                producerFrameWaitersByLease.removeValue(forKey: lease)
                waiter.continuation.resume(returning: .rejected(.producerEndedWithoutTerminal))
                return
            }
        }
        guard let resolution = producerRegistry.resolveFrameWaiterIfPossible(for: lease),
            let waiter = producerFrameWaitersByLease[lease],
            waiter.token == resolution.waiterToken
        else {
            return
        }
        producerFrameWaitersByLease.removeValue(forKey: lease)
        if case .frame(let delivery) = resolution.result {
            registerProducerFrameObservation(delivery.receipt)
            recordContentFramePulled(delivery.receipt)
        }
        waiter.continuation.resume(returning: resolution.result)
    }

    func beginProducerRetirement(
        _ lease: BridgeProductProducerLease,
        acknowledgeLifecycle: @escaping ProducerLifecycleAcknowledger,
        stopRequest: BridgeProductProducerRegistry.StopRequest?,
        abandonOutstandingDelivery: Bool
    ) -> BridgeProductProducerRetirementBarrier {
        if let existing = producerRetirementStateByLease[lease] {
            return existing.barrier
        }
        guard producerRegistry.hasLifecycleResidue(for: lease) else {
            return BridgeProductProducerRetirementBarrier(
                id: lease.id,
                completedResult: true
            )
        }
        if abandonOutstandingDelivery {
            abandonProducerFrameDelivery(for: lease)
        }

        let retirementId = UUID()
        let task = Task { [self] in
            let result = await completeProducerRetirement(
                lease,
                acknowledgeLifecycle: acknowledgeLifecycle,
                stopRequest: stopRequest
            )
            producerRetirementStateByLease.removeValue(forKey: lease)
            return result
        }
        let barrier = BridgeProductProducerRetirementBarrier(
            id: retirementId,
            task: task
        )
        producerRetirementStateByLease[lease] = .inFlight(barrier)
        return barrier
    }

    private func cancelProducerFrameWaiter(
        for lease: BridgeProductProducerLease,
        waiterToken: UUID
    ) {
        guard
            producerRegistry.cancelFrameWaiter(
                for: lease,
                waiterToken: waiterToken
            ), let waiter = producerFrameWaitersByLease[lease],
            waiter.token == waiterToken
        else {
            return
        }
        producerFrameWaitersByLease.removeValue(forKey: lease)
        waiter.continuation.resume(returning: .cancelled)
    }

    func abandonProducerFrameDelivery(
        for lease: BridgeProductProducerLease
    ) {
        cancelContentCreditWaiter(for: lease)
        resolveProducerFrameObservationCancellation(for: lease)
        let waiterToken = producerRegistry.abandonFrameDelivery(for: lease)
        guard let waiterToken,
            let waiter = producerFrameWaitersByLease[lease],
            waiter.token == waiterToken
        else {
            return
        }
        producerFrameWaitersByLease.removeValue(forKey: lease)
        waiter.continuation.resume(returning: .cancelled)
    }

    private func registerProducerFrameObservation(
        _ receipt: BridgeProductProducerFrameReceipt
    ) {
        let lease = receipt.producerLease
        if case .observed = producerFrameObservationByLease[lease] {
            producerFrameObservationByLease.removeValue(forKey: lease)
        }
        precondition(producerFrameObservationByLease[lease] == nil)
        producerFrameObservationByLease[lease] = .awaiting(receipt)
    }

    private func resolveProducerFrameObservationCancellation(
        for lease: BridgeProductProducerLease
    ) {
        producerFrameObservationByLease.removeValue(forKey: lease)
    }

    private func completeProducerRetirement(
        _ lease: BridgeProductProducerLease,
        acknowledgeLifecycle: @escaping ProducerLifecycleAcknowledger,
        stopRequest: BridgeProductProducerRegistry.StopRequest?
    ) async -> Bool {
        let acknowledgement: BridgeProductProducerLifecycleAcknowledgement
        if let pendingAcknowledgement = producerRegistry.pendingLifecycleAcknowledgement(
            for: lease
        ) {
            acknowledgement = pendingAcknowledgement
        } else {
            guard let stopRequest = stopRequest ?? producerRegistry.requestStop([lease]).first else {
                return false
            }
            await stopRequest.task?.value
            guard producerRegistry.producerIsStopped(lease),
                let newAcknowledgement = producerRegistry.unregister(lease)
            else {
                return false
            }
            acknowledgement = newAcknowledgement
        }
        guard await acknowledgeLifecycle(acknowledgement),
            producerRegistry.acknowledgeLifecycle(acknowledgement)
        else {
            return false
        }
        abandonProducerFrameDelivery(for: lease)
        contentAdmissionByProducerLease.removeValue(forKey: lease)
        productAdmissionByProducerLease.removeValue(forKey: lease)
        return true
    }
}
