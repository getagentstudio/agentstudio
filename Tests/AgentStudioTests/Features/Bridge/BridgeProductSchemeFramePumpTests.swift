import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product scheme frame pump")
struct BridgeProductSchemeFramePumpTests {
    @Test("metadata frame consumption releases its exact receipt and rejects duplicate consumption")
    func metadataFrameConsumptionUsesExactReceipt() async throws {
        // Arrange
        let harness = try await BridgeProductSessionProducerHarness.opened()
        let operation = HeldStep<BridgeProductProducerLease>("operation")
        let request = try bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-stream-early-observation",
            resumeFromStreamSequence: nil
        )
        let registration = await harness.session.registerMetadataProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { lease in
            try? await operation.arrive(lease)
        }
        let lease = try bridgeProductAcceptedLease(registration)
        _ = try await operation.firstArrival()
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { sequence in
                try bridgeProductMetadataAcceptedFrame(
                    request: request,
                    streamSequence: sequence,
                    resumeDisposition: .snapshotRequired
                )
            }
        )
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )
        let delivery = try #require(frameDelivery(await pump.nextFrame()))

        // Act
        let exactAccepted = await pump.acknowledgeFrameConsumed(delivery.receipt)
        let duplicateAccepted = await pump.acknowledgeFrameConsumed(delivery.receipt)
        let afterConsumption = await harness.session.producerSnapshot()

        // Assert
        #expect(exactAccepted)
        #expect(!duplicateAccepted)
        #expect(afterConsumption.inFlightFrameReceiptCount == 0)
        #expect(await pump.cancel())
        try await operation.cancellationObserved()
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("local pump consumption releases only the exact in-flight frame")
    func workerObservationRequiresExactReceipt() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "worker-observation")
        _ = try await enqueueContentOpening(fixture)
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )
        let delivery = try #require(frameDelivery(await pump.nextFrame()))
        let forgedReceipt = BridgeProductProducerFrameReceipt(
            producerLease: fixture.lease,
            sequence: delivery.receipt.sequence,
            nonce: UUID()
        )

        // Act
        let forgedAccepted = await fixture.harness.session.acknowledgeProducerFrameObserved(
            forgedReceipt
        )
        let afterForgery = await fixture.harness.session.producerSnapshot()
        let exactAccepted = await fixture.harness.session.acknowledgeProducerFrameObserved(
            delivery.receipt
        )
        let duplicateAccepted = await fixture.harness.session.acknowledgeProducerFrameObserved(
            delivery.receipt
        )
        let afterObservation = await fixture.harness.session.producerSnapshot()

        // Assert
        #expect(!forgedAccepted)
        #expect(afterForgery.queuedFrameCount == 1)
        #expect(afterForgery.inFlightFrameReceiptCount == 1)
        #expect(exactAccepted)
        #expect(!duplicateAccepted)
        #expect(afterObservation.queuedFrameCount == 0)
        #expect(afterObservation.inFlightFrameReceiptCount == 0)

        #expect(await pump.cancel())
        try await fixture.operation.cancellationObserved()
        #expect((await fixture.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("cancellation abandons a pulled frame before local consumption")
    func cancellationResolvesPendingWorkerObservation() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "observation-cancel")
        _ = try await enqueueContentOpening(fixture)
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )
        let delivery = try #require(frameDelivery(await pump.nextFrame()))

        // Act
        let cancelled = await pump.cancel()
        let lateAccepted = await fixture.harness.session.acknowledgeProducerFrameObserved(
            delivery.receipt
        )

        // Assert
        #expect(cancelled)
        #expect(!lateAccepted)
        try await fixture.operation.cancellationObserved()
        #expect((await fixture.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("completed retirement clears a frame claimed after initial abandonment")
    func completedRetirementClearsLateFrameObservation() async throws {
        // Arrange
        let harness = try await BridgeProductSessionProducerHarness.opened()
        // The producer ignores cancellation, so retirement stays in flight
        // after it abandons delivery.
        let producerCompletion = HeldStep<Void>(
            "late-observation producer completion",
            cancellation: .holdThroughCancellation
        )
        let request = try bridgeProductFileContentRequest(identitySuffix: "late-observation")
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { _ in
            try? await producerCompletion.arrive(())
        }
        let lease = try bridgeProductAcceptedLease(registration)
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in
                .content(
                    .init(
                        header: .accepted(for: request.admission),
                        payload: Data()
                    )
                )
            }
        )
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )

        // Act
        async let cancellationSucceeded = pump.cancel()
        try await producerCompletion.cancellationObserved()
        let lateDelivery = frameDelivery(await pump.nextFrame())
        let registeredReceipt: BridgeProductProducerFrameReceipt?
        if lateDelivery != nil {
            registeredReceipt = await harness.session.producerFrameObservationReceipt(
                for: lease
            )
        } else {
            registeredReceipt = nil
        }
        producerCompletion.release()
        let cancellationResult = await cancellationSucceeded
        let requiredLateDelivery = try #require(lateDelivery)
        let lateAcknowledgementAccepted =
            await harness.session.acknowledgeProducerFrameObserved(requiredLateDelivery.receipt)
        let observationRemains = await harness.session.hasProducerFrameObservation(for: lease)
        let finalSnapshot = await harness.session.producerSnapshot()

        // Assert
        #expect(registeredReceipt == requiredLateDelivery.receipt)
        #expect(cancellationResult)
        #expect(!lateAcknowledgementAccepted)
        #expect(!observationRemains)
        #expect(finalSnapshot.hasZeroResidue)
    }

    /// Retirement may report success only after the lifecycle acknowledgement
    /// it awaits has succeeded. The acknowledgement is held; failing it must
    /// fail the retirement with the producer unregistered and its lifecycle
    /// acknowledgement still pending, and releasing it must clear the lease's
    /// frame observation before retirement succeeds.
    @Test("producer retirement reply depends on the lifecycle acknowledgement")
    func producerRetirementReplyDependsOnLifecycleAcknowledgement() async throws {
        try await proveReplyDependsOnStep(
            makeScenario: { () -> ProducerRetirementHeldReply in
                let harness = try await BridgeProductSessionProducerHarness.opened()
                let producerBody = HeldStep<BridgeProductProducerLease>("content producer body until retirement")
                let lifecycleAcknowledgement = HeldStep<BridgeProductProducerLifecycleAcknowledgement>(
                    "frame pump retirement lifecycle acknowledgement"
                )
                let request = try bridgeProductFileContentRequest(identitySuffix: "retirement-causal")
                let registration = await harness.session.registerContentProducer(
                    request: request,
                    productAdmission: harness.productAdmission
                ) { lease in
                    // Retirement stops the producer by cancelling it.
                    try? await producerBody.arrive(lease)
                }
                let lease = try bridgeProductAcceptedLease(registration)
                _ = try await producerBody.firstArrival()
                _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
                    for: lease,
                    productAdmission: harness.productAdmission,
                    build: { _ in
                        .content(.init(header: .accepted(for: request.admission), payload: Data()))
                    }
                )
                let pump = BridgeProductSchemeFramePump(
                    session: harness.session,
                    producerLease: lease,
                    productAdmission: harness.productAdmission,
                    acknowledgeLifecycle: { acknowledgement in
                        do {
                            try await lifecycleAcknowledgement.arrive(acknowledgement)
                            return true
                        } catch {
                            return false
                        }
                    }
                )
                let claimedFrame = try #require(frameDelivery(await pump.nextFrame()))
                let scenario = ProducerRetirementScenario(
                    session: harness.session,
                    lease: lease,
                    claimedReceipt: claimedFrame.receipt
                )
                return HeldReplyScenario(context: scenario, step: lifecycleAcknowledgement) {
                    await pump.cancel()
                }
            },
            replyReportsFailure: { (retired: Bool, scenario: ProducerRetirementScenario) async -> Bool in
                guard !retired else { return false }
                let snapshot = await scenario.session.producerSnapshot()
                #expect(snapshot.activeProducerCount == 0)
                #expect(snapshot.pendingLifecycleAcknowledgementCount == 1)
                #expect(!snapshot.hasZeroResidue)
                return true
            },
            assertCommitted: { (_: Bool, scenario: ProducerRetirementScenario) async in
                let lateObservationAccepted = await scenario.session.acknowledgeProducerFrameObserved(
                    scenario.claimedReceipt
                )
                let observationRemains = await scenario.session.hasProducerFrameObservation(for: scenario.lease)
                let finalSnapshot = await scenario.session.producerSnapshot()
                #expect(!lateObservationAccepted)
                #expect(!observationRemains)
                #expect(finalSnapshot.hasZeroResidue)
            }
        )
    }

    @Test("claimed queue head remains resident until its exact receipt is consumed")
    func claimedFrameRequiresExactConsumptionReceipt() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "receipt")
        _ = try await enqueueContentOpening(fixture)
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )

        // Act
        let firstPull = await pump.nextFrame()
        let delivery = try #require(frameDelivery(firstPull))
        let claimedSnapshot = await fixture.harness.session.producerSnapshot()
        let forgedReceipt = BridgeProductProducerFrameReceipt(
            producerLease: fixture.lease,
            sequence: delivery.frame.sequence,
            nonce: UUID()
        )
        let forgedAccepted = await pump.acknowledgeFrameConsumed(forgedReceipt)
        let afterForgery = await fixture.harness.session.producerSnapshot()
        let exactAccepted = await pump.acknowledgeFrameConsumed(delivery.receipt)
        let duplicateAccepted = await pump.acknowledgeFrameConsumed(delivery.receipt)
        let afterConsumption = await fixture.harness.session.producerSnapshot()

        // Assert
        #expect(claimedSnapshot.queuedFrameCount == 1)
        #expect(claimedSnapshot.inFlightFrameReceiptCount == 1)
        #expect(!forgedAccepted)
        #expect(afterForgery.queuedFrameCount == 1)
        #expect(afterForgery.inFlightFrameReceiptCount == 1)
        #expect(exactAccepted)
        #expect(!duplicateAccepted)
        #expect(afterConsumption.queuedFrameCount == 0)
        #expect(afterConsumption.inFlightFrameReceiptCount == 0)

        #expect(await pump.cancel())
        try await fixture.operation.cancellationObserved()
        #expect((await fixture.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("one pending pull and one in-flight receipt are enforced per lease")
    func concurrentPullsHaveOneWaiterAndOneClaim() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "single-flight")
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )

        // Act
        async let firstPull = pump.nextFrame()
        async let competingPull = pump.nextFrame()
        _ = try await enqueueContentOpening(fixture)
        let results = await [firstPull, competingPull]

        // Assert
        let deliveries = results.compactMap(frameDelivery)
        #expect(deliveries.count == 1)
        #expect(
            results.contains(.rejected(.waiterAlreadyRegistered))
                || results.contains(.rejected(.receiptInFlight))
        )
        let delivery = try #require(deliveries.first)
        #expect(await pump.acknowledgeFrameConsumed(delivery.receipt))
        #expect(await pump.cancel())
        #expect((await fixture.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("stopping producer drains its queued prefix before normal zero-residue finish")
    func stoppingProducerDrainsBeforeFinish() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "drain")
        _ = try await enqueueContentOpening(fixture)
        _ = try await fixture.harness.session.enqueueTerminalProducerFrame(
            for: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            build: { sequence in
                .content(
                    .init(
                        header: try .reset(
                            contentSequence: sequence,
                            reason: .staleSource
                        ),
                        payload: Data()
                    )
                )
            }
        )
        #expect(await fixture.harness.session.stopProducer(fixture.lease))
        let lifecycleProbe = FramePumpLifecycleAcknowledgementProbe()
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { acknowledgement in
                await lifecycleProbe.acknowledge(acknowledgement)
            }
        )

        // Act
        let openingDelivery = try #require(frameDelivery(await pump.nextFrame()))
        let afterOpeningClaim = await fixture.harness.session.producerSnapshot()
        #expect(await pump.acknowledgeFrameConsumed(openingDelivery.receipt))
        let terminalDelivery = try #require(frameDelivery(await pump.nextFrame()))
        #expect(await pump.acknowledgeFrameConsumed(terminalDelivery.receipt))
        let finishResult = await pump.nextFrame()

        // Assert
        #expect(openingDelivery.frame.sequence == 0)
        #expect(terminalDelivery.frame.sequence == 1)
        #expect(terminalDelivery.frame.terminal)
        #expect(afterOpeningClaim.queuedFrameCount == 2)
        #expect(finishResult == .finished)
        #expect(await lifecycleProbe.invocationCount == 1)
        #expect((await fixture.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("pump cancellation and session revocation share lifecycle ownership")
    func cancellationAndRevocationShareRetirementFlight() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "revoke-race")
        let lifecycleProbe = FramePumpLifecycleAcknowledgementProbe()
        let acknowledge: BridgeProductSession.ProducerLifecycleAcknowledger = { acknowledgement in
            await lifecycleProbe.acknowledge(acknowledgement)
        }
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: acknowledge
        )

        // Act
        async let cancelled = pump.cancel()
        async let revocation = fixture.harness.session.revoke(
            acknowledgeLifecycle: acknowledge
        ).wait()
        let outcomes = await (cancelled, revocation)

        // Assert
        #expect(outcomes.0)
        #expect(outcomes.1)
        #expect(await lifecycleProbe.invocationCount == 1)
        #expect((await fixture.harness.session.producerSnapshot()).hasZeroResidue)
    }

    @Test("reentrant revocation does not acknowledge one lifecycle nonce twice")
    func reentrantRevocationDoesNotDoubleAcknowledgeLifecycle() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "reentrant-revoke")
        let lifecycleProbe = FramePumpReentrantRevocationLifecycleProbe(
            session: fixture.harness.session
        )
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { acknowledgement in
                await lifecycleProbe.acknowledge(acknowledgement)
            }
        )

        // Act
        let cancellationSucceeded = await pump.cancel()
        let storedRevocationBarrier = await lifecycleProbe.revocationBarrier
        let revocationBarrier = try #require(storedRevocationBarrier)
        let revocationSucceeded = await revocationBarrier.wait()
        let firstAcknowledgementNonce = try #require(
            await lifecycleProbe.firstAcknowledgementNonce
        )
        let providerInvocationCount = await lifecycleProbe.invocationCount(
            for: firstAcknowledgementNonce
        )
        let finalSnapshot = await fixture.harness.session.producerSnapshot()

        // Assert
        #expect(cancellationSucceeded)
        #expect(revocationSucceeded)
        #expect(providerInvocationCount == 1)
        #expect(finalSnapshot.hasZeroResidue)
    }

    @Test("failed lifecycle acknowledgement is retried exactly and later clears residue")
    func failedLifecycleAcknowledgementCanBeRetried() async throws {
        // Arrange
        let fixture = try await makeFramePumpFixture(identitySuffix: "acknowledgement-retry")
        let lifecycleProbe = FramePumpRetryingLifecycleAcknowledgementProbe()
        let pump = BridgeProductSchemeFramePump(
            session: fixture.harness.session,
            producerLease: fixture.lease,
            productAdmission: fixture.harness.productAdmission,
            acknowledgeLifecycle: { acknowledgement in
                await lifecycleProbe.acknowledge(acknowledgement)
            }
        )

        // Act
        let firstCancellation = await pump.cancel()
        let residueAfterFailure = await fixture.harness.session.producerSnapshot()
        let secondCancellation = await pump.cancel()
        let finalSnapshot = await fixture.harness.session.producerSnapshot()
        let acknowledgementAttempts = await lifecycleProbe.acknowledgements

        // Assert
        #expect(!firstCancellation)
        #expect(residueAfterFailure.activeProducerCount == 0)
        #expect(residueAfterFailure.pendingLifecycleAcknowledgementCount == 1)
        #expect(!residueAfterFailure.hasZeroResidue)
        #expect(secondCancellation)
        #expect(acknowledgementAttempts.count == 2)
        #expect(acknowledgementAttempts.first == acknowledgementAttempts.last)
        #expect(finalSnapshot.hasZeroResidue)
    }

    @Test("provider completion without a consumed terminal frame is rejected")
    func producerCannotFinishAfterDataOnlyPrefix() async throws {
        // Arrange
        let harness = try await BridgeProductSessionProducerHarness.opened()
        let request = try bridgeProductFileContentRequest(identitySuffix: "missing-terminal")
        let producerCompletion = HeldStep<Void>("data-only producer completion")
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission
        ) { _ in
            try? await producerCompletion.arrive(())
        }
        let lease = try bridgeProductAcceptedLease(registration)
        _ = try await harness.session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { _ in
                .content(
                    .init(
                        header: .accepted(for: request.admission),
                        payload: Data()
                    )
                )
            }
        )
        _ = try await harness.session.enqueueProducerFrame(
            for: lease,
            productAdmission: harness.productAdmission,
            build: { sequence in
                .content(
                    .init(
                        header: try .data(
                            contentSequence: sequence,
                            offsetBytes: 0
                        ),
                        payload: Data([0x61])
                    )
                )
            },
            overflowReset: { sequence in
                .content(
                    .init(
                        header: try .reset(
                            contentSequence: sequence,
                            reason: .staleSource
                        ),
                        payload: Data()
                    )
                )
            }
        )
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission,
            acknowledgeLifecycle: { _ in true }
        )

        // Act
        let opening = try #require(frameDelivery(await pump.nextFrame()))
        #expect(await pump.acknowledgeFrameConsumed(opening.receipt))
        let data = try #require(frameDelivery(await pump.nextFrame()))
        #expect(await pump.acknowledgeFrameConsumed(data.receipt))
        producerCompletion.release()
        let finishAttempt = await pump.nextFrame()

        // Assert
        #expect(finishAttempt == .rejected(.producerEndedWithoutTerminal))
        #expect(await pump.cancel())
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }
}

private struct FramePumpFixture {
    let harness: BridgeProductSessionProducerHarness
    let lease: BridgeProductProducerLease
    let operation: HeldStep<BridgeProductProducerLease>
    let request: BridgeProductContentRequest
}

private actor FramePumpLifecycleAcknowledgementProbe {
    private(set) var invocationCount = 0

    func acknowledge(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) -> Bool {
        invocationCount += 1
        return true
    }
}

private actor FramePumpRetryingLifecycleAcknowledgementProbe {
    private(set) var acknowledgements: [BridgeProductProducerLifecycleAcknowledgement] = []

    func acknowledge(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) -> Bool {
        acknowledgements.append(acknowledgement)
        return acknowledgements.count > 1
    }
}

private actor FramePumpReentrantRevocationLifecycleProbe {
    private let session: BridgeProductSession
    private var didStartRevocation = false
    private var invocationCountByNonce: [UUID: Int] = [:]
    private(set) var firstAcknowledgementNonce: UUID?
    private(set) var revocationBarrier: BridgeProductSessionRevocationBarrier?

    init(session: BridgeProductSession) {
        self.session = session
    }

    func acknowledge(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        invocationCountByNonce[acknowledgement.nonce, default: 0] += 1
        if firstAcknowledgementNonce == nil {
            firstAcknowledgementNonce = acknowledgement.nonce
        }
        guard !didStartRevocation else { return true }

        didStartRevocation = true
        revocationBarrier = await session.revoke(
            acknowledgeLifecycle: { acknowledgement in
                await self.acknowledge(acknowledgement)
            }
        )
        return true
    }

    func invocationCount(for nonce: UUID) -> Int {
        invocationCountByNonce[nonce, default: 0]
    }
}

private func makeFramePumpFixture(identitySuffix: String) async throws -> FramePumpFixture {
    let harness = try await BridgeProductSessionProducerHarness.opened()
    let operation = HeldStep<BridgeProductProducerLease>("operation")
    let request = try bridgeProductFileContentRequest(identitySuffix: identitySuffix)
    let registration = await harness.session.registerContentProducer(
        request: request,
        productAdmission: harness.productAdmission
    ) { lease in
        try? await operation.arrive(lease)
    }
    let lease = try bridgeProductAcceptedLease(registration)
    _ = try await operation.firstArrival()
    return .init(
        harness: harness,
        lease: lease,
        operation: operation,
        request: request
    )
}

private func enqueueContentOpening(
    _ fixture: FramePumpFixture
) async throws -> BridgeProductProducerEnqueueResult {
    try await fixture.harness.session.enqueueRequiredProducerOpeningFrame(
        for: fixture.lease,
        productAdmission: fixture.harness.productAdmission,
        build: { _ in
            .content(
                .init(
                    header: .accepted(for: fixture.request.admission),
                    payload: Data()
                )
            )
        }
    )
}

private typealias ProducerRetirementHeldReply = HeldReplyScenario<
    ProducerRetirementScenario, BridgeProductProducerLifecycleAcknowledgement, Bool
>

private struct ProducerRetirementScenario: Sendable {
    let session: BridgeProductSession
    let lease: BridgeProductProducerLease
    let claimedReceipt: BridgeProductProducerFrameReceipt
}

private func frameDelivery(
    _ result: BridgeProductProducerFramePullResult
) -> BridgeProductProducerFrameDelivery? {
    guard case .frame(let delivery) = result else { return nil }
    return delivery
}

extension BridgeProductSession {
    fileprivate func producerFrameObservationReceipt(
        for lease: BridgeProductProducerLease
    ) -> BridgeProductProducerFrameReceipt? {
        producerFrameObservationByLease[lease]?.receipt
    }

    fileprivate func hasProducerFrameObservation(
        for lease: BridgeProductProducerLease
    ) -> Bool {
        producerFrameObservationByLease[lease] != nil
    }
}
