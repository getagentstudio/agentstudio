import Foundation
import Testing

@testable import AgentStudioBridge

/// Installs one metadata stream on a coordinator, varying ONLY the request's
/// `resumeFromStreamSequence` so that is the single discriminator under test.
private func installMetadataStream(
    on harness: BridgeProductSessionLifecycleHarness,
    metadataStreamId: String,
    resumeFromStreamSequence: Int?
) async throws -> BridgePaneProductMetadataCoordinator {
    let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    let coordinator = BridgePaneProductMetadataCoordinator(
        fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
        reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
        refreshWorkAdmissionSource: refreshWorkAdmission.source
    )
    let lease = try await harness.admitMetadataFrames(through: 0)
    await coordinator.install(
        request: try bridgeProductMetadataStreamRequest(
            metadataStreamId: metadataStreamId,
            resumeFromStreamSequence: resumeFromStreamSequence
        ),
        lease: lease,
        productAdmission: harness.productAdmission.context,
        session: harness.session
    )
    return coordinator
}

private func openOutgoingReviewSubscription(
    on harness: BridgeProductSessionLifecycleHarness
) async throws {
    let outgoingLease = try await harness.admitMetadataFrames(through: 0)
    try await harness.openSubscription(
        bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    )
    try await harness.closeProducer(outgoingLease)
}

@Suite("Bridge product metadata stream subscription replay")
struct BridgePaneProductMetadataStreamReplayTests {
    @Test("resuming a retained File view owes recovery rather than a new open")
    func retainedFileResumeCarriesRecovery() async throws {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        try await fixture.seal(fixture.snapshot(target: 1, complete: true))
        _ = try await fixture.consumeBatch(partCount: 10)
        try await harness.closeProducer(fixture.lease)
        let coordinator = try await installMetadataStream(
            on: harness, metadataStreamId: "metadata-stream-recovery-cause", resumeFromStreamSequence: 1
        )
        await coordinator.replaySubscriptionsForInstalledStream()
        let pending = await harness.session.viewSenderState.pending(for: fixture.domain)
        #expect(pending == .snapshotRequired(.recovery))
        await coordinator.closeAndDrain()
    }

    /// A fresh open means the worker poisoned its metadata session (or is a new
    /// worker) and holds NO subscription ids. Replaying the pane session's earlier
    /// ids would reach a client that cannot name them, and the client treats an
    /// unknown id as fatal for the WHOLE stream — the defect behind CI run
    /// 35305271084, where the pane stuck on "Update unavailable / Retry".
    @Test("a fresh metadata stream retires earlier subscriptions instead of replaying them")
    func freshMetadataStreamRetiresEarlierSubscriptions() async throws {
        // Arrange -- a session still holding a subscription from a stream that died.
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        try await openOutgoingReviewSubscription(on: harness)
        #expect(
            await harness.session.subscriptionSnapshots().map(\.subscriptionId)
                == ["review-subscription-1"]
        )
        let coordinator = try await installMetadataStream(
            on: harness,
            metadataStreamId: "metadata-stream-fresh-after-poison",
            resumeFromStreamSequence: nil
        )

        // Act
        await coordinator.replaySubscriptionsForInstalledStream()

        // Assert
        #expect(await harness.session.subscriptionSnapshots().isEmpty)
        #expect(await harness.session.producerSnapshot().queuedFrameCount == 0)
        #expect(await coordinator.subscriptionKindById.isEmpty)
    }

    /// A resume means the worker still holds its ids and expects the replay.
    @Test("an exact-head resume replays the session's subscriptions")
    func exactHeadResumeReplaysSubscriptions() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        try await openOutgoingReviewSubscription(on: harness)
        let coordinator = try await installMetadataStream(
            on: harness,
            metadataStreamId: "metadata-stream-resumed",
            resumeFromStreamSequence: 1
        )

        // Act
        await coordinator.replaySubscriptionsForInstalledStream()

        // Assert
        #expect(
            await harness.session.subscriptionSnapshots().map(\.subscriptionId)
                == ["review-subscription-1"]
        )
        #expect(await coordinator.subscriptionKindById["review-subscription-1"] != nil)
    }

    /// The new client can open a subscription between install and replay: it learns the
    /// stream exists from the opening frame, and the replay is a separate step after it.
    /// Retirement therefore uses the set captured at INSTALL, when the session could only
    /// have held the outgoing client's ids. Reading the session again at replay time
    /// would retire a subscription the new client opened and still holds, leaving it
    /// waiting forever for data — the same stuck pane this retirement exists to prevent.
    @Test("a subscription opened after install survives the fresh stream's retirement")
    func subscriptionOpenedAfterInstallSurvivesRetirement() async throws {
        // Arrange -- the outgoing client's subscription, then a fresh stream installed.
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        try await openOutgoingReviewSubscription(on: harness)
        let coordinator = try await installMetadataStream(
            on: harness,
            metadataStreamId: "metadata-stream-fresh-with-late-subscription",
            resumeFromStreamSequence: nil
        )

        // Act -- the NEW client opens its own subscription before the replay runs.
        try await harness.openSubscription(
            bridgeProductLifecycleFileSubscriptionOpenObject(requestSequence: 3, epoch: 1)
        )
        #expect(
            await harness.session.subscriptionSnapshots().map(\.subscriptionId).sorted()
                == ["file-subscription-1", "review-subscription-1"]
        )
        await coordinator.replaySubscriptionsForInstalledStream()

        // Assert -- only the outgoing client's subscription is retired.
        #expect(
            await harness.session.subscriptionSnapshots().map(\.subscriptionId)
                == ["file-subscription-1"]
        )
    }

    /// A resume with a sequence gap registers as `.snapshotRequired`, exactly like a
    /// fresh open — which is why the discriminator is `resumeFromStreamSequence == nil`
    /// and NOT the registry disposition. This gapped resume must still replay.
    @Test("a gapped resume still replays the session's subscriptions")
    func gappedResumeStillReplaysSubscriptions() async throws {
        // Arrange
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        try await openOutgoingReviewSubscription(on: harness)
        let coordinator = try await installMetadataStream(
            on: harness,
            metadataStreamId: "metadata-stream-resumed-with-gap",
            resumeFromStreamSequence: 0
        )

        // Act
        await coordinator.replaySubscriptionsForInstalledStream()

        // Assert
        #expect(
            await harness.session.subscriptionSnapshots().map(\.subscriptionId)
                == ["review-subscription-1"]
        )
        #expect(await coordinator.subscriptionKindById["review-subscription-1"] != nil)
    }
}
