import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

private enum ReconnectOpeningFact: Equatable, Sendable {
    case openingEmitReturned
    case deliveryWaitRegistered
    case inventoryEmitReturned
    case recoveryDelivered
}

private final class ReconnectOpeningObservation: Sendable {
    let isArmed = Mutex(false)
}

extension BridgeMetadataReconnectTests {
    @Test("retained source acceptance finishes opening before recovery delivery is drained")
    func sourceAcceptanceDoesNotWaitForRecoveryDelivery() async throws {
        let facts = LocalFactSource<String, ReconnectOpeningFact>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { String(describing: $0) }, isClosing: { _, _ in false }))
        let recorder = try facts.attach()
        let sink = facts.sink
        let observation = ReconnectOpeningObservation()
        let context = try await makeReconnectSubscriptionContext(emissionWaitObserver: { _ in
            if observation.isArmed.withLock({ $0 }) { sink("reconnect", .deliveryWaitRegistered) }
        })
        let before = await context.fileSource.diagnostics
        let beforeEmit = HeldStep<Void>(
            "replacement source acceptance before emit", cancellation: .holdThroughCancellation)
        let afterEmit = HeldStep<Void>("replacement source opening after emit", cancellation: .holdThroughCancellation)
        defer {
            beforeEmit.release()
            afterEmit.release()
        }
        await context.fileSource.holdOpeningEmit(ordinal: before.openCallCount + 1, at: beforeEmit)
        await context.fileSource.holdOpenCompletion(ordinal: before.openCallCount + 1, at: afterEmit)
        #expect(await context.firstStream.pump.cancel())
        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(
                subscription: context.retainedSubscription,
                lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence),
            dispatcher: context.dispatcher, capabilityHeader: context.harness.capabilityHeader)
        guard case .resyncAccepted(let accepted) = response else {
            await context.provider.closeAndDrain()
            Issue.record("Expected retained reconciliation")
            return
        }
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-opening-delivery",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier),
            provider: context.provider, harness: context.harness)
        _ = try await beforeEmit.firstArrival()
        await context.fileSource.observeOpeningEmit { sink("reconnect", .openingEmitReturned) }
        observation.isArmed.withLock { $0 = true }
        beforeEmit.release()
        let first = try await recorder.expectNext(
            in: "reconnect", where: { _ in true }, "Source acceptance returns before delivery wait")
        #expect(
            first == .openingEmitReturned,
            "Source acceptance must not await the recovery snapshot that cannot be drained before open completes")
        if first == .openingEmitReturned {
            _ = try await afterEmit.firstArrival()
            let diagnostics = await context.fileSource.diagnostics
            #expect(diagnostics.viewHandle == nil)
            #expect(diagnostics.updateCallCount == before.updateCallCount)
            let recovery = try await pullReconnectOpeningBatch(from: replacement.pump, harness: context.harness)
            #expect(recovery.begin.mode == .snapshot)
            #expect(recovery.begin.snapshotCause == .recovery)
            #expect(recovery.complete.identity.frame.metadataStreamId == "metadata-opening-delivery")
        } else {
            // A named red closes the delivery wait instead of leaving an orphaned source.
            await context.harness.session.closeViewDomains(subscriptionId: context.retainedSubscription.subscriptionId)
        }
        observation.isArmed.withLock { $0 = false }
        await context.fileSource.observeOpeningEmit(nil)
        afterEmit.release()
        #expect(await replacement.pump.cancel())
        await context.provider.closeAndDrain()
        facts.end()
        try await recorder.finish()
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }

    @Test("inventory capture waits behind the recovery snapshot and keeps delivery backpressure")
    func inventoryCaptureRemainsOrderedBehindRecoveryDelivery() async throws {
        let facts = LocalFactSource<String, ReconnectOpeningFact>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .recoveryDelivered }))
        let recorder = try facts.attach()
        let sink = facts.sink
        let observation = ReconnectOpeningObservation()
        let context = try await makeReconnectSubscriptionContext(emissionWaitObserver: { _ in
            if observation.isArmed.withLock({ $0 }) { sink("recovery", .deliveryWaitRegistered) }
        })
        let before = await context.fileSource.diagnostics
        let inventory = HeldStep<Void>("replacement inventory before data emit", cancellation: .holdThroughCancellation)
        let afterInventory = HeldStep<Void>(
            "replacement source after inventory emit", cancellation: .holdThroughCancellation)
        defer {
            inventory.release()
            afterInventory.release()
        }
        await context.fileSource.holdOpeningInventory(ordinal: before.openCallCount + 1, at: inventory) {
            observation.isArmed.withLock { armed in
                if armed { sink("recovery", .inventoryEmitReturned) }
                sink("inventory", .inventoryEmitReturned)
            }
        }
        await context.fileSource.holdOpenCompletion(ordinal: before.openCallCount + 1, at: afterInventory)
        #expect(await context.firstStream.pump.cancel())
        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(
                subscription: context.retainedSubscription,
                lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence),
            dispatcher: context.dispatcher, capabilityHeader: context.harness.capabilityHeader)
        guard case .resyncAccepted(let accepted) = response else {
            await context.provider.closeAndDrain()
            Issue.record("Expected retained reconciliation")
            return
        }
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-inventory-delivery",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier),
            provider: context.provider, harness: context.harness)
        _ = try await inventory.firstArrival()
        let opening = await recorder.mark("recovery")
        observation.isArmed.withLock { $0 = true }
        inventory.release()
        try await recorder.expectNext(in: "recovery", .deliveryWaitRegistered)
        let scope = try #require(
            await context.harness.session.acceptedViewScope(
                subscriptionId: context.retainedSubscription.subscriptionId))
        #expect(await context.harness.session.pendingFileSnapshotByViewDomain[scope.viewDomain]?.targetRevision == 2)

        let recovery = try await pullReconnectOpeningBatch(from: replacement.pump, harness: context.harness)
        observation.isArmed.withLock { armed in
            sink("recovery", .recoveryDelivered)
            armed = false
        }
        try await recorder.expectNone(
            of: { $0 == .inventoryEmitReturned },
            "inventory emit returning before recovery delivery", from: opening, closedBy: { $0 == .recoveryDelivered })
        #expect(recovery.begin.mode == .snapshot)
        #expect(recovery.begin.snapshotCause == .recovery)
        #expect(recovery.begin.targetRevision == 1)
        #expect(await context.harness.session.pendingFileSnapshotByViewDomain[scope.viewDomain]?.targetRevision == 2)
        #expect(await context.harness.session.viewEmissionWaiterByDomain[scope.viewDomain] != nil)

        let later = try await pullReconnectOpeningBatch(from: replacement.pump, harness: context.harness)
        #expect(later.begin.identity.frame.streamSequence > recovery.complete.identity.frame.streamSequence)
        #expect(later.begin.identity.batchId != recovery.begin.identity.batchId)
        #expect(later.begin.targetRevision == 2)
        #expect(later.begin.mode == .change)
        #expect(later.begin.snapshotCause == nil)
        try await recorder.expectNext(in: "inventory", .inventoryEmitReturned)
        _ = try await afterInventory.firstArrival()
        afterInventory.release()
        #expect(await replacement.pump.cancel())
        await context.provider.closeAndDrain()
        facts.end()
        try await recorder.finish()
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }
}

private func pullReconnectOpeningBatch(
    from pump: BridgeProductSchemeFramePump,
    harness: BridgeProductSessionLifecycleHarness
) async throws -> (begin: BridgeProductBatchBeginFrame, complete: BridgeProductBatchCompleteFrame) {
    while true {
        let frame = try await pullMetadataFrame(from: pump)
        guard case .batch(.begin(let begin)) = frame else { continue }
        guard case .batch(.part(let part)) = try await pullMetadataFrame(from: pump) else {
            throw ReconnectSubscriptionTestError.expectedBatch
        }
        try await acknowledgeReconnectPart(part, harness: harness)
        guard case .batch(.complete(let complete)) = try await pullMetadataFrame(from: pump) else {
            throw ReconnectSubscriptionTestError.expectedBatch
        }
        #expect(part.identity.batchId == begin.identity.batchId)
        #expect(complete.identity.batchId == begin.identity.batchId)
        return (begin, complete)
    }
}
