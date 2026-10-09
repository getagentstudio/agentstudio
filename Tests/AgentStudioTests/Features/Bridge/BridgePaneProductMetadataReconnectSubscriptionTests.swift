import AgentStudioCore
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product metadata reconnect subscription")
struct BridgeMetadataReconnectTests {
    @Test("physical reconnect retains File E3 and resnapshots after a sealed batch was lost")
    func reconnectResnapshotsLostFileBatchWithoutReopeningSubscription() async throws {
        let context = try await makeReconnectSubscriptionContext()
        let observedSequence = context.initialBatch.identity.frame.streamSequence
        let initialSubscription = context.retainedSubscription
        let disposition = await context.provider.publishFileChangeset(
            try reconnectFileChangeset(),
            productAdmission: context.harness.productAdmission.context,
            foregroundWorkAdmission: context.refreshWorkAdmission,
            operationCorrelationID: String(repeating: "d", count: 64),
            operationStageAttempt: 1
        )
        #expect(disposition == .applied)
        guard case .batch(.begin(let lostBegin)) = try await pullMetadataFrame(from: context.firstStream.pump),
            case .batch(.part(let lostPart)) = try await pullMetadataFrame(from: context.firstStream.pump)
        else {
            Issue.record("Expected a sealed File batch to begin before physical retirement")
            await context.provider.closeAndDrain()
            return
        }
        #expect(lostBegin.identity.frame.streamSequence > observedSequence)
        #expect(lostPart.identity.batchId == lostBegin.identity.batchId)
        #expect(lostPart.identity.subscriptionId == initialSubscription.subscriptionId)
        #expect(await context.firstStream.pump.cancel())

        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(
                subscription: context.retainedSubscription,
                lastAcceptedStreamSequence: observedSequence
            ),
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let accepted) = response else {
            await context.provider.closeAndDrain()
            Issue.record("Expected physical stream reconciliation after the lost File batch")
            return
        }
        #expect(accepted.reconciliation.map(\.dispositionName) == ["retained"])
        #expect(
            await context.harness.session.subscriptionSnapshot(
                subscriptionId: initialSubscription.subscriptionId
            ) == initialSubscription
        )
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-after-lost-file-batch",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier
            ),
            provider: context.provider,
            harness: context.harness
        )
        let resnapshotResponse = try await dispatchReconnectControl(
            reconnectFileResnapshotRequest(),
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        let replacementComplete = try await pullPostReconnectPublication(from: replacement.pump)
        let sourceDiagnostics = await context.fileSource.diagnostics
        #expect(await replacement.pump.cancel())
        await context.provider.closeAndDrain()

        #expect(resnapshotResponse.kind == "subscription.resnapshotAccepted")
        #expect(replacementComplete.identity.frame.metadataStreamId == "metadata-after-lost-file-batch")
        #expect(replacementComplete.identity.subscriptionId == initialSubscription.subscriptionId)
        #expect(replacementComplete.identity.handle == lostBegin.identity.handle)
        #expect(replacementComplete.identity.scopeRevision == lostBegin.identity.scopeRevision)
        #expect(sourceDiagnostics.publicationCallCount == 1)
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }

    @Test("metadata reattachment restores subscriptions reconciled while disconnected")
    func restoresReconciledSubscriptionsWhenMetadataReattaches() async throws {
        // Arrange
        let context = try await makeReconnectSubscriptionContext()
        let before = await context.fileSource.diagnostics
        #expect(await context.firstStream.pump.cancel())
        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(
                subscription: context.retainedSubscription,
                lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence),
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let accepted) = response else {
            await context.provider.closeAndDrain()
            Issue.record("Expected reconciliation before stream reattachment")
            return
        }

        // Act
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-reattached",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier
            ),
            provider: context.provider,
            harness: context.harness
        )
        await waitForReconnectSourceActivity(context.fileSource)
        let disposition = await context.provider.publishFileChangeset(
            try reconnectFileChangeset(),
            productAdmission: context.harness.productAdmission.context,
            foregroundWorkAdmission: context.refreshWorkAdmission,
            operationCorrelationID: String(repeating: "c", count: 64),
            operationStageAttempt: 1
        )
        let frame =
            disposition == .applied
            ? try await pullPostReconnectPublication(from: replacement.pump)
            : nil
        await context.fileSource.waitForUpdateCallCount(before.updateCallCount + 1)
        let sourceDiagnostics = await context.fileSource.diagnostics
        #expect(await replacement.pump.cancel())
        await context.provider.closeAndDrain()

        // Assert
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
        #expect(disposition == .applied)
        guard let data = frame else {
            Issue.record("Expected post-reattachment source publication")
            return
        }
        #expect(data.identity.frame.metadataStreamId == "metadata-reattached")
        #expect(sourceDiagnostics.viewHandle == "file-reconnect-view-handle")
        #expect(sourceDiagnostics.scopeRevision == 1)
    }

    @Test("session reconciliation remains available after its metadata response closes")
    func reconcilesSessionAfterMetadataResponseCloses() async throws {
        // Arrange
        let context = try await makeReconnectSubscriptionContext()
        #expect(await context.firstStream.pump.cancel())
        let request = try reconnectResyncRequest(
            subscription: context.retainedSubscription,
            lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence
        )

        // Act
        let response = try await dispatchReconnectControl(
            request,
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        await context.provider.closeAndDrain()

        // Assert
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
        guard case .resyncAccepted(let accepted) = response else {
            Issue.record("A closed metadata response must not disable its session reconciliation command")
            return
        }
        #expect(accepted.metadataStreamSequenceBarrier == context.initialBatch.identity.frame.streamSequence)
        #expect(accepted.reconciliation.map(\.dispositionName) == ["retained"])
    }

    @Test("retained reconciliation resnapshots the accepted File view on the replacement stream")
    func retainedReconciliationResnapshotsAcceptedFileView() async throws {
        let context = try await makeReconnectSubscriptionContext()
        let before = await context.fileSource.diagnostics
        #expect(await context.firstStream.pump.cancel())
        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(
                subscription: context.retainedSubscription,
                lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence
            ),
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let accepted) = response else {
            await context.provider.closeAndDrain()
            Issue.record("Expected retained File reconciliation")
            return
        }
        #expect(accepted.reconciliation.map(\.dispositionName) == ["retained"])
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-resnapshot-file-view",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier
            ),
            provider: context.provider,
            harness: context.harness
        )
        let resnapshotResponse = try await dispatchReconnectControl(
            reconnectFileResnapshotRequest(),
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        let completed = try await pullPostReconnectPublication(from: replacement.pump)
        await context.fileSource.waitForUpdateCallCount(before.updateCallCount + 1)
        let diagnostics = await context.fileSource.diagnostics
        #expect(await replacement.pump.cancel())
        await context.provider.closeAndDrain()

        #expect(resnapshotResponse.kind == "subscription.resnapshotAccepted")
        #expect(completed.identity.frame.metadataStreamId == "metadata-resnapshot-file-view")
        #expect(completed.identity.handle == "file-reconnect-view-handle")
        #expect(completed.identity.scopeRevision == 1)
        #expect(diagnostics.viewHandle == "file-reconnect-view-handle")
        #expect(diagnostics.scopeRevision == 1)
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }

    @Test("retained reconciliation reattaches unchanged interests once after physical response retirement")
    func retainedReconciliationPreservesHealthySource() async throws {
        // Arrange
        let context = try await makeReconnectSubscriptionContext()
        let before = await context.fileSource.diagnostics
        let request = try reconnectResyncRequest(
            subscription: context.retainedSubscription,
            lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence
        )

        // Act
        let response = try await dispatchReconnectControl(
            request,
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let accepted) = response else {
            await context.provider.closeAndDrain()
            Issue.record("Expected retained subscription reconciliation")
            return
        }
        let afterReconciliation = await context.fileSource.diagnostics
        let retained = await context.harness.session.subscriptionSnapshot(
            subscriptionId: context.retainedSubscription.subscriptionId
        )
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
        let retainedScope = await context.harness.session.acceptedViewScope(
            subscriptionId: context.retainedSubscription.subscriptionId
        )
        let openCompletionStep = HeldStep<Void>(
            "reattached File source waits before retained view demand is applied",
            cancellation: .holdThroughCancellation
        )
        await context.fileSource.holdOpenCompletion(
            ordinal: before.openCallCount + 1,
            at: openCompletionStep
        )
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-retained-interests",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier
            ),
            provider: context.provider,
            harness: context.harness
        )
        _ = try await openCompletionStep.firstArrival()
        #expect(retainedScope?.handle == "file-reconnect-view-handle")
        #expect(retainedScope?.revision == 1)

        let publicationTask = Task {
            await context.provider.publishFileChangeset(
                try reconnectFileChangeset(),
                productAdmission: context.harness.productAdmission.context,
                foregroundWorkAdmission: context.refreshWorkAdmission,
                operationCorrelationID: String(repeating: "b", count: 64),
                operationStageAttempt: 1
            )
        }
        let disposition = try await publicationTask.value
        let heldDiagnostics = await context.fileSource.diagnostics
        #expect(heldDiagnostics.updateCallCount == before.updateCallCount)
        #expect(heldDiagnostics.viewHandle == nil)
        openCompletionStep.release()
        await context.fileSource.waitForUpdateCallCount(before.updateCallCount + 1)
        let publication =
            disposition == .applied
            ? try await pullPostReconnectPublication(from: replacement.pump) : nil
        let after = await context.fileSource.diagnostics
        #expect(await context.firstStream.pump.cancel())
        #expect(await replacement.pump.cancel())
        await context.provider.closeAndDrain()

        // Assert
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
        #expect(retained == context.retainedSubscription)
        #expect(afterReconciliation.openCallCount == before.openCallCount)
        #expect(afterReconciliation.updateCallCount == before.updateCallCount)
        #expect(after.openCallCount == before.openCallCount + 1)
        #expect(after.updateCallCount == before.updateCallCount + 1)
        #expect(after.cancellationCount == before.cancellationCount + 1)
        #expect(after.viewHandle == "file-reconnect-view-handle")
        #expect(after.scopeRevision == 1)
        #expect(disposition == .applied)
        guard let data = publication else {
            Issue.record("Expected retained healthy source publication")
            return
        }
        #expect(accepted.reconciliation.map(\.dispositionName) == ["retained"])
        #expect(data.identity.frame.metadataStreamId == "metadata-retained-interests")
    }

    @Test("retained File subscription delivers a certified batch after metadata stream replacement")
    func reconciledFileSubscriptionDeliversAfterMetadataStreamReplacement() async throws {
        // Arrange
        let context = try await makeReconnectSubscriptionContext()
        let before = await context.fileSource.diagnostics
        let openCompletionStep = HeldStep<Void>(
            "replacement File source opens before scope reapplication",
            cancellation: .holdThroughCancellation
        )
        defer { openCompletionStep.release() }
        await context.fileSource.holdOpenCompletion(
            ordinal: before.openCallCount + 1,
            at: openCompletionStep
        )
        #expect(await context.firstStream.pump.cancel())
        let retiredSnapshot = await context.harness.session.producerSnapshot()
        let resyncRequest = try reconnectResyncRequest(
            subscription: context.retainedSubscription,
            lastAcceptedStreamSequence: context.initialBatch.identity.frame.streamSequence
        )

        // Act
        let resyncResponse = try await dispatchReconnectControl(
            resyncRequest,
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let acceptedResync) = resyncResponse else {
            await context.provider.closeAndDrain()
            Issue.record("Expected the production provider resync response")
            return
        }
        let secondStream = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-after-reconnect",
                resumeFromStreamSequence: acceptedResync.metadataStreamSequenceBarrier
            ),
            provider: context.provider,
            harness: context.harness
        )
        await waitForReconnectSourceActivity(context.fileSource)
        _ = try await openCompletionStep.firstArrival()
        let heldDiagnostics = await context.fileSource.diagnostics
        #expect(heldDiagnostics.updateCallCount == before.updateCallCount)
        #expect(heldDiagnostics.viewHandle == nil)
        #expect(heldDiagnostics.scopeRevision == nil)
        let publicationDisposition = await context.provider.publishFileChangeset(
            try reconnectFileChangeset(),
            productAdmission: context.harness.productAdmission.context,
            foregroundWorkAdmission: context.refreshWorkAdmission,
            operationCorrelationID: String(repeating: "a", count: 64),
            operationStageAttempt: 1
        )
        let replacementFrame =
            publicationDisposition == .applied
            ? try await pullPostReconnectPublication(from: secondStream.pump)
            : nil
        openCompletionStep.release()
        await context.fileSource.waitForUpdateCallCount(before.updateCallCount + 1)
        let sourceDiagnostics = await context.fileSource.diagnostics
        #expect(await secondStream.pump.cancel())
        await context.provider.closeAndDrain()
        let finalProducerSnapshot = await context.harness.session.producerSnapshot()

        // Assert
        #expect(finalProducerSnapshot.hasZeroResidue)
        #expect(acceptedResync.reconciliation.map(\.dispositionName) == ["retained"])
        #expect(context.initialBatch.identity.subscriptionKind == .fileMetadata)
        #expect(retiredSnapshot.hasZeroResidue)
        #expect(publicationDisposition == .applied)
        #expect(sourceDiagnostics.openCallCount >= 1)
        #expect(sourceDiagnostics.publicationCallCount == 1)
        #expect(sourceDiagnostics.updateCallCount >= 1)
        #expect(sourceDiagnostics.viewHandle == "file-reconnect-view-handle")
        #expect(sourceDiagnostics.scopeRevision == 1)
        guard let replacementData = replacementFrame else {
            Issue.record("Expected a certified File batch on the replacement metadata stream")
            return
        }
        #expect(replacementData.identity.frame.metadataStreamId == "metadata-after-reconnect")
        #expect(replacementData.identity.subscriptionKind == .fileMetadata)
    }
}
