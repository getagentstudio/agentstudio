import AgentStudioInfrastructure
import Foundation

struct BridgeProductSessionControlIdleWaiter {
    let afterRequestSequence: Int?
    let continuation: CheckedContinuation<Bool, Never>
}

extension BridgeProductSession {
    func waitUntilProducerFramesQuiescent() async -> Bool {
        if lifecycle == .revoked { return false }
        if producerFramesAreQuiescent { return true }
        let waiterID = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || lifecycle == .revoked {
                    continuation.resume(returning: false)
                } else if producerFramesAreQuiescent {
                    continuation.resume(returning: true)
                } else {
                    producerFrameQuiescenceWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelProducerFrameQuiescenceWaiter(waiterID) }
        }
    }

    private var producerFramesAreQuiescent: Bool {
        let snapshot = producerRegistry.snapshot()
        return snapshot.queuedFrameCount == 0 && snapshot.inFlightFrameReceiptCount == 0
    }

    func resumeProducerFrameQuiescenceWaitersIfReady() {
        guard producerFramesAreQuiescent else { return }
        let waiters = Array(producerFrameQuiescenceWaiters.values)
        producerFrameQuiescenceWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: true) }
    }

    private func cancelProducerFrameQuiescenceWaiter(_ waiterID: UUID) {
        producerFrameQuiescenceWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }

    func waitUntilControlReplayIdle(afterRequestSequence: Int? = nil) async -> Bool {
        if lifecycle == .revoked { return false }
        if controlReplayIsIdle(afterRequestSequence: afterRequestSequence) { return true }
        let waiterID = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || lifecycle == .revoked {
                    continuation.resume(returning: false)
                } else if controlReplayIsIdle(afterRequestSequence: afterRequestSequence) {
                    continuation.resume(returning: true)
                } else {
                    controlReplayIdleWaiters[waiterID] = .init(
                        afterRequestSequence: afterRequestSequence,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelControlReplayIdleWaiter(waiterID) }
        }
    }

    private func controlReplayIsIdle(afterRequestSequence: Int?) -> Bool {
        let snapshot = controlReplay.snapshot
        return snapshot.inFlightRequestSequence == nil
            && (afterRequestSequence.map { snapshot.nextExpectedRequestSequence > $0 } ?? true)
    }

    func resumeControlReplayIdleWaitersIfReady() {
        let readyIDs = controlReplayIdleWaiters.keys.filter { waiterID in
            guard let waiter = controlReplayIdleWaiters[waiterID] else { return false }
            return controlReplayIsIdle(afterRequestSequence: waiter.afterRequestSequence)
        }
        for waiterID in readyIDs {
            controlReplayIdleWaiters.removeValue(forKey: waiterID)?.continuation.resume(returning: true)
        }
    }

    private func cancelControlReplayIdleWaiter(_ waiterID: UUID) {
        controlReplayIdleWaiters.removeValue(forKey: waiterID)?.continuation.resume(returning: false)
    }

    func diagnosticRetainedOperationOutcomes() -> [(BridgeProductOperationWaitKind, BridgeProductOperationSettlement)] {
        operationTable.entriesById.keys.sorted().compactMap { operationID in
            guard let entry = operationTable.entriesById[operationID],
                let settlement = entry.settlement
            else { return nil }
            return (entry.waitKind, settlement.outcome)
        }
    }

    func waitUntilActive() async -> Bool {
        if lifecycle == .active { return true }
        if lifecycle == .revoked { return false }
        let waiterID = UUIDv7.generate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || lifecycle == .revoked {
                    continuation.resume(returning: false)
                } else if lifecycle == .active {
                    continuation.resume(returning: true)
                } else {
                    activeLifecycleWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelActiveLifecycleWaiter(waiterID) }
        }
    }

    private func cancelActiveLifecycleWaiter(_ waiterID: UUID) {
        activeLifecycleWaiters.removeValue(forKey: waiterID)?.resume(returning: false)
    }

    func subscriptionSnapshot(
        subscriptionId: String
    ) -> BridgeProductSubscriptionSnapshot? {
        subscriptionState.snapshot(subscriptionId: subscriptionId)
    }

    var diagnosticSnapshot: BridgeProductSessionDiagnosticSnapshot {
        .init(
            activeEscapeEffectCount: activeEscapeEffectIds.count,
            activeOperationExecutionCount: operationTable.executionTasksById.count,
            mutationWatchCount: operationTable.mutationWatchesById.count,
            observationWaiterCount: operationTable.mutationWatchesById.values.reduce(0) {
                $0 + $1.observers.count
            },
            retainedOperationResultCount: operationTable.entriesById.count,
            pendingControlCount: pendingControl == nil ? 0 : 1,
            activeSubscriptionCount: subscriptionState.snapshots().count,
            producerFrameWaiterCount: producerFrameWaitersByLease.count,
            producerRetirementCount: producerRetirementStateByLease.count,
            producer: producerSnapshot()
        )
    }
}
