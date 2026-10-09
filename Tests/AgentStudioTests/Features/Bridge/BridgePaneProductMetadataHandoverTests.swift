import Foundation
import Testing
import WebKit

@testable import AgentStudioBridge

@Suite("Bridge pane product metadata stream handover")
struct BridgePaneProductMetadataHandoverTests {
    @Test("an exact resync retry does not retire the already reattached response")
    func exactResyncRetryPreservesReplacementResponse() async throws {
        // Arrange
        let context = try await makeReconnectSubscriptionContext()
        let request = try reconnectResyncRequest(
            subscription: context.retainedSubscription,
            lastAcceptedStreamSequence: 3
        )
        let firstResponse = try await dispatchReconnectControl(
            request,
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let accepted) = firstResponse else {
            #expect(await context.firstStream.pump.cancel())
            await context.provider.closeAndDrain()
            Issue.record("Expected accepted resync")
            return
        }
        let replacement = try await installReconnectMetadataStream(
            request: bridgeProductMetadataStreamRequest(
                metadataStreamId: "metadata-before-exact-resync-retry",
                resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier
            ),
            provider: context.provider,
            harness: context.harness
        )
        await waitForReconnectSourceActivity(context.fileSource)
        let beforeRetry = await context.fileSource.diagnostics

        // Act
        let repeatedResponse = try await dispatchReconnectControl(
            request,
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        let afterRetry = await context.fileSource.diagnostics
        let snapshot = await context.harness.session.producerSnapshot()
        #expect(await replacement.pump.cancel())
        #expect(await context.firstStream.pump.cancel())
        await context.provider.closeAndDrain()

        // Assert
        #expect(repeatedResponse == firstResponse)
        #expect(snapshot.activeProducerCount == 1)
        #expect(afterRetry.cancellationCount == beforeRetry.cancellationCount)
        #expect(afterRetry.openCallCount == beforeRetry.openCallCount)
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }

    @Test("a reconciled replacement stream retires the old response without client close notification")
    func replacesStreamWhoseClientClosureHasNotArrived() async throws {
        // Arrange: native still owns the old physical response. The worker's
        // reconnect command is independent of that response's close callback.
        let context = try await makeReconnectSubscriptionContext()
        let response = try await dispatchReconnectControl(
            reconnectResyncRequest(subscription: context.retainedSubscription, lastAcceptedStreamSequence: 3),
            dispatcher: context.dispatcher,
            capabilityHeader: context.harness.capabilityHeader
        )
        guard case .resyncAccepted(let accepted) = response else {
            #expect(await context.firstStream.pump.cancel())
            await context.provider.closeAndDrain()
            Issue.record("Expected reconciliation before replacing the physical stream")
            return
        }
        let adapter = BridgeProductSchemeAdapter(
            session: context.harness.session,
            provider: context.provider,
            productAdmissionGate: context.harness.productAdmission.gate,
            installationAdmissionGate: BridgeProductAdmissionGate()
        )
        let request = try bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-half-open-replacement",
            resumeFromStreamSequence: accepted.metadataStreamSequenceBarrier
        )

        // Act: exercise the same authenticated adapter used by native and HTTP.
        let reply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.streamRoute,
                capability: context.harness.capabilityHeader,
                body: try JSONEncoder().encode(request)
            )
        )
        var iterator = reply.stream.makeAsyncIterator()
        var statusCode: Int?
        do {
            if case .response(let response) = try await iterator.next() {
                statusCode = (response as? HTTPURLResponse)?.statusCode
            }
        } catch {
            reply.routingTask.cancel()
            await reply.routingTask.value
            #expect(await context.firstStream.pump.cancel())
            await context.provider.closeAndDrain()
            throw error
        }
        let installed = await context.harness.session.producerSnapshot()
        reply.routingTask.cancel()
        await reply.routingTask.value
        #expect(await context.firstStream.pump.cancel())
        await context.provider.closeAndDrain()

        // Assert: never overlap producers or require a backend/worker restart.
        #expect(statusCode == 200)
        #expect(installed.activeProducerCount == 1)
        #expect(installed.pendingLifecycleAcknowledgementCount == 0)
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }
}
