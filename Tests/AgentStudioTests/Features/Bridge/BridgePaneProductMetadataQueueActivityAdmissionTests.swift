import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductMetadataActivityAdmissionTests {
    @Test("metadata queue mutation rejects an invalidated foreground activity token")
    @MainActor
    func metadataQueueMutationRejectsInvalidatedActivity() async throws {
        // Arrange
        let context = try await makeActivityMetadataContext(
            initialActivity: .foreground,
            suspendFileSourceBeforeEmission: true
        )
        let fileOpen = try await openActivityMetadataSubscription(
            context: context,
            object: bridgeProductLifecycleFileSubscriptionOpenObject(
                requestSequence: 2,
                epoch: 1
            ),
            subscriptionId: "file-subscription-1"
        )
        await context.fileSource.waitUntilEmissionReady()
        let originalForegroundWorkAdmission = try #require(
            context.activityCoordinator.acquireForegroundWork()
        )
        let queueMutationGate = ActivityQueueMutationGate()
        let (precheckEvents, precheckContinuation) = AsyncStream<Void>.makeStream()
        let enqueueTask = Task {
            try await enqueueActivityMetadataResetAfterLoosePrecheck(
                context: context,
                subscriptionId: fileOpen.subscriptionId,
                foregroundWorkAdmission: originalForegroundWorkAdmission,
                precheckContinuation: precheckContinuation,
                queueMutationGate: queueMutationGate
            )
        }
        var precheckIterator = precheckEvents.makeAsyncIterator()
        _ = await precheckIterator.next()

        // Act
        context.activityCoordinator.applyActivity(.loadedHidden)
        await queueMutationGate.release()
        let staleResetResult = try await enqueueTask.value
        await context.fileSource.releaseEmission()
        await context.fileSource.waitUntilEmissionFinished()
        let hiddenSnapshot = await context.harness.session.producerSnapshot()

        // Assert
        #expect(staleResetResult == .rejected(.lifecycleClosed))
        #expect(hiddenSnapshot.queuedFrameCount == 0)
        await context.provider.applyCommittedControlEffect(
            .subscriptionCancelled(fileOpen),
            for: context.fileOpenRequest,
            productAdmission: context.harness.productAdmission.context
        )
        await finishActivityMetadataContext(context)
    }
}

private func enqueueActivityMetadataResetAfterLoosePrecheck(
    context: ActivityMetadataContext,
    subscriptionId: String,
    foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
    precheckContinuation: AsyncStream<Void>.Continuation,
    queueMutationGate: ActivityQueueMutationGate
) async throws -> BridgeProductProducerEnqueueResult {
    guard foregroundWorkAdmission.withValidAdmission({ true }) == true else {
        return .rejected(.lifecycleClosed)
    }
    precheckContinuation.yield()
    precheckContinuation.finish()
    await queueMutationGate.waitUntilReleased()
    return try await context.harness.session.enqueueSubscriptionReset(
        originatingMetadataLease: context.lease,
        subscriptionId: subscriptionId,
        reason: .staleSource,
        productAdmission: context.harness.productAdmission.context,
        foregroundWorkAdmission: foregroundWorkAdmission
    )
}
