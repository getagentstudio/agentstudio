import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product session lifecycle integration")
struct BridgeProductSessionLifecycleTests {
    @Test("cancelling an already retired subscription accepts without a second effect")
    func unknownSubscriptionCancelIsIdempotent() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let cancelRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleSubscriptionCancelObject(requestSequence: 2, epoch: 7)
        )
        let cancelToken = try #require(try await harness.begin(cancelRequest).executionToken)
        let response = try BridgeProductControlResponse.subscriptionCancelAccepted(
            correlating: cancelRequest
        )

        let effect = try await harness.session.completeEscapeControl(
            token: cancelToken,
            response: response
        )

        #expect(effect == .noEffect)
        #expect(
            await harness.session.subscriptionSnapshot(subscriptionId: "review-subscription-1") == nil
        )
    }

    @Test("subscription responses must match exact request identity before mutation")
    func subscriptionResponseCorrelationGuardsMutation() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let metadataLease = try await harness.admitMetadataFrames(through: 0)
        let openRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 7)
        )
        let openToken = try #require(
            try await harness.begin(openRequest).executionToken
        )
        let mismatchedOpenResponse = BridgeProductControlResponse.subscriptionOpenAccepted(
            try .init(
                correlation: openRequest.correlation,
                subscriptionId: "review-subscription-other",
                subscriptionKind: .reviewMetadata,
                worktreeId: nil
            )
        )

        // Act / Assert
        await #expect(throws: BridgeProductSessionError.mismatchedControlResponse) {
            _ = try await harness.session.completeAdmittedControl(
                token: openToken,
                exactResponseBytes: try JSONEncoder().encode(mismatchedOpenResponse)
            )
        }
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            ) == nil
        )

        let openResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: openRequest,
            worktreeId: nil
        )
        _ = try await harness.session.completeAdmittedControl(
            token: openToken,
            exactResponseBytes: try JSONEncoder().encode(openResponse)
        )
        let openedSubscription = try #require(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            )
        )
        #expect(openedSubscription.subscription == .reviewMetadata)

        let cancelRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleSubscriptionCancelObject(requestSequence: 3, epoch: 7)
        )
        let cancelToken = try #require(
            try await harness.begin(cancelRequest).executionToken
        )
        let mismatchedCancelResponse = BridgeProductControlResponse.subscriptionCancelAccepted(
            .init(
                correlation: cancelRequest.correlation,
                subscriptionId: "review-subscription-1",
                subscriptionKind: .fileMetadata
            )
        )
        await #expect(throws: BridgeProductSessionError.mismatchedControlResponse) {
            _ = try await harness.session.completeAdmittedControl(
                token: cancelToken,
                exactResponseBytes: try JSONEncoder().encode(mismatchedCancelResponse)
            )
        }
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            ) != nil
        )

        let cancelResponse = try BridgeProductControlResponse.subscriptionCancelAccepted(
            correlating: cancelRequest
        )
        _ = try await harness.session.completeAdmittedControl(
            token: cancelToken,
            exactResponseBytes: try JSONEncoder().encode(cancelResponse)
        )
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            ) == nil
        )
        try await harness.closeProducer(metadataLease)
    }

    @Test("ordinary epoch advance resets only the admitted surface")
    func ordinaryEpochAdvanceIsSurfaceScoped() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let metadataLease = try await harness.admitMetadataFrames(through: 0)
        try await harness.openSubscription(
            bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 7)
        )
        try await harness.openSubscription(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 3, epoch: 2)
        )
        let advancedReviewRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewCallObject(requestSequence: 4, epoch: 8)
        )

        // Act
        let advancedAdmission = try await harness.begin(advancedReviewRequest)
        let advancedToken = try #require(advancedAdmission.executionToken)

        // Assert
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            ) == nil
        )
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "file-subscription-1"
            ) != nil
        )
        let advancedSnapshot = await harness.session.snapshot
        #expect(advancedSnapshot.workerDerivationEpochBySurface[.review] == 8)
        #expect(advancedSnapshot.workerDerivationEpochBySurface[.file] == 2)

        try await harness.session.abandonControl(token: advancedToken)
        let staleReviewRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleReviewCallObject(requestSequence: 4, epoch: 7)
        )
        let staleAdmission = try await harness.begin(staleReviewRequest)
        #expect(
            staleAdmission
                == .rejected(
                    .init(
                        reason: .staleDerivationEpoch(
                            currentWorkerDerivationEpoch: 8,
                            surface: .review
                        ),
                        request: staleReviewRequest
                    )
                )
        )
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "file-subscription-1"
            ) != nil
        )
        try await harness.closeProducer(metadataLease)
    }

    @Test("resync reopens a File subscription after its delivered reset becomes terminal")
    func resyncReopensFileSubscriptionAfterDeliveredReset() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let metadataLease = try await harness.admitMetadataFrames(through: 0)
        let fileOpenRequest = try bridgeProductLifecycleControlRequest(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 2, epoch: 2)
        )
        let fileOpenToken = try #require(
            try await harness.begin(fileOpenRequest).executionToken
        )
        #expect(await harness.session.admitControlProviderExecution(token: fileOpenToken))
        let fileOpenResponse = try BridgeProductControlResponse.subscriptionOpenAccepted(
            correlating: fileOpenRequest,
            worktreeId: nil
        )
        _ = try await harness.session.completeAdmittedControl(
            token: fileOpenToken,
            exactResponseBytes: try JSONEncoder().encode(fileOpenResponse)
        )
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: metadataLease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )?.sequence == 1
        )
        await harness.session.settleControlProviderDispatch(token: fileOpenToken)
        let foregroundWork = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let resetResult = try await harness.session.enqueueSubscriptionReset(
            originatingMetadataLease: metadataLease,
            subscriptionId: "file-subscription-1",
            reason: .staleSource,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: foregroundWork.admission
        )
        guard case .enqueued = resetResult else {
            Issue.record("Expected subscription.reset to remove the live File delivery")
            try await harness.closeProducer(metadataLease)
            return
        }
        let resyncRequest = try bridgeProductLifecycleControlRequest([
            "activeSubscriptions": [
                [
                    "subscriptionId": "file-subscription-1",
                    "subscriptionKind": "file.metadata",
                    "workerDerivationEpoch": 2,
                ]
            ],
            "kind": "workerSession.resync",
            "lastAcceptedRequestSequence": 2,
            "lastAcceptedStreamSequence": 1,
            "paneSessionId": "pane-session-1",
            "requestId": "request-resync-3",
            "requestSequence": 3,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": "worker-instance-1",
        ])

        // Act
        let resyncToken = try #require(
            try await harness.begin(resyncRequest).executionToken
        )
        let resyncResponse = try await harness.authoritativeResyncResponse(
            request: resyncRequest,
            token: resyncToken
        )
        _ = try await harness.session.completeAdmittedControl(
            token: resyncToken,
            exactResponseBytes: try JSONEncoder().encode(resyncResponse)
        )
        let survivingFileSubscription = await harness.session.subscriptionSnapshot(
            subscriptionId: "file-subscription-1"
        )
        try await harness.closeProducer(metadataLease)

        // Assert
        guard case .resyncAccepted(let acceptedResponse) = resyncResponse else {
            Issue.record("Expected resync.accepted")
            return
        }
        #expect(
            (
                acceptedResponse.reconciliation.map(\.dispositionName),
                survivingFileSubscription == nil
            ) == (["reopenRequired"], true)
        )
    }

    @Test("resync validates sequence and response facts before atomic surface reconciliation")
    func resyncIsAtomicAcrossIndependentSurfaceEpochs() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let metadataLease = try await prepareMetadataForAtomicResync(on: harness)
        try await harness.expectStreamSequenceRejectionPreservesState(
            .init(
                requestSequence: 4,
                lastAcceptedRequestSequence: 3,
                lastAcceptedStreamSequence: 7,
                nextMetadataStreamSequence: 7,
                reviewEpoch: 8,
                fileEpoch: 2
            )
        )

        let resyncRequest = try bridgeProductLifecycleControlRequest(
            try bridgeProductLifecycleResyncObject(
                requestSequence: 4,
                lastAcceptedRequestSequence: 3,
                lastAcceptedStreamSequence: 6,
                reviewEpoch: 8,
                fileEpoch: 2
            )
        )
        let resyncToken = try #require(
            try await harness.begin(resyncRequest).executionToken
        )
        _ = try await harness.session.admitControlOperation(token: resyncToken, execute: { _ in })
        let beforeCompletion = await harness.session.snapshot
        let mismatchedResponse = try BridgeProductControlResponse.resyncAccepted(
            correlating: resyncRequest,
            metadataStreamSequenceBarrier: 5,
            nextExpectedRequestSequence: 5,
            reconciliation: []
        )

        #expect(beforeCompletion.workerDerivationEpochBySurface[.review] == 7)
        #expect(beforeCompletion.workerDerivationEpochBySurface[.file] == 2)
        await #expect(throws: BridgeProductSessionError.mismatchedControlResponse) {
            _ = try await harness.session.completeAdmittedControl(
                token: resyncToken,
                exactResponseBytes: try JSONEncoder().encode(mismatchedResponse)
            )
        }
        #expect((await harness.session.snapshot) == beforeCompletion)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            ) != nil
        )

        let acceptedResponse = try await harness.authoritativeResyncResponse(
            request: resyncRequest,
            token: resyncToken
        )
        _ = try await harness.session.completeAdmittedControl(
            token: resyncToken,
            exactResponseBytes: try JSONEncoder().encode(acceptedResponse)
        )
        let acceptedSnapshot = await harness.session.snapshot
        #expect(acceptedSnapshot.workerDerivationEpochBySurface[.review] == 8)
        #expect(acceptedSnapshot.workerDerivationEpochBySurface[.file] == 2)
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "review-subscription-1"
            ) == nil
        )
        #expect(
            await harness.session.subscriptionSnapshot(
                subscriptionId: "file-subscription-1"
            ) != nil
        )

        let conflictingSequenceRequest = try bridgeProductLifecycleControlRequest(
            try bridgeProductLifecycleResyncObject(
                requestSequence: 5,
                lastAcceptedRequestSequence: 3,
                lastAcceptedStreamSequence: 6,
                reviewEpoch: 8,
                fileEpoch: 2
            )
        )
        let conflictAdmission = try await harness.begin(conflictingSequenceRequest)
        #expect(
            conflictAdmission
                == .rejected(
                    .init(
                        reason: .sequenceConflict(nextExpectedRequestSequence: 5),
                        request: conflictingSequenceRequest
                    )
                )
        )
        #expect((await harness.session.snapshot) == acceptedSnapshot)
        try await harness.closeProducer(metadataLease)
    }

    @Test("resync requires admitted metadata progress and permits a lagging cursor")
    func resyncStreamProgressRequiresProvenanceWithoutRequiringEquality() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        try await harness.expectStreamSequenceRejectionPreservesState(
            .init(
                requestSequence: 2,
                lastAcceptedRequestSequence: 1,
                lastAcceptedStreamSequence: 0,
                nextMetadataStreamSequence: 0,
                reviewEpoch: 1,
                fileEpoch: 1
            )
        )

        // Act / Assert
        let metadataLease = try await harness.admitMetadataFrames(through: 6)
        let laggingRequest = try bridgeProductLifecycleControlRequest(
            try bridgeProductLifecycleResyncObject(
                requestSequence: 2,
                lastAcceptedRequestSequence: 1,
                lastAcceptedStreamSequence: 5,
                reviewEpoch: 1,
                fileEpoch: 1
            )
        )
        let laggingToken = try #require(
            try await harness.begin(laggingRequest).executionToken
        )
        let laggingResponse = try await harness.authoritativeResyncResponse(
            request: laggingRequest,
            token: laggingToken
        )
        let effects = try await harness.session.completeAdmittedControl(
            token: laggingToken,
            exactResponseBytes: try JSONEncoder().encode(laggingResponse)
        )
        guard case .resynced = effects else {
            Issue.record("Expected a committed session-resync effect")
            return
        }
        #expect((await harness.session.producerSnapshot()).nextMetadataStreamSequence == 7)
        try await harness.closeProducer(metadataLease)
    }
}

private func prepareMetadataForAtomicResync(
    on harness: BridgeProductSessionLifecycleHarness
) async throws -> BridgeProductProducerLease {
    let lease = try await harness.admitMetadataFrames(through: 0)
    try await harness.openSubscription(
        bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 7)
    )
    try await harness.openSubscription(
        bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 3, epoch: 2)
    )
    for expectedSequence in 1...2 {
        #expect(
            await consumeNextBridgeProductProducerFrame(
                for: lease,
                from: harness.session,
                productAdmission: harness.productAdmission.context
            )?.sequence == expectedSequence
        )
    }
    try await harness.admitMetadataProgress(through: 6, on: lease)
    return lease
}

extension BridgeProductSessionControlAdmission {
    fileprivate var executionToken: BridgeProductControlAdmissionToken? {
        guard case .execute(let token, _) = self else { return nil }
        return token
    }
}
