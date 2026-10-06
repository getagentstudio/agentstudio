import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product Review metadata availability lifecycle")
struct BridgeProductReviewAvailabilityTests {
    @Test("Review open before publication seals a complete keyed view after delivery")
    @MainActor
    func reviewOpenBeforePackagePublicationStaysAccepted() async throws {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session, producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let reviewSource = AvailabilityHeldReviewMetadataSource()
        let replayProvider = AvailabilityReviewPublicationProvider()
        let traceRecorder = AvailabilityReviewPublicationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: reviewSource,
            reviewPublicationReplay: { _ in replayProvider.publication },
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(), lease: lease,
            productAdmission: harness.productAdmission.context, session: harness.session
        )
        let acceptedFrame = try await openAvailabilityReviewSubscription(
            coordinator: coordinator, harness: harness, pump: pump
        )
        guard case .subscriptionAccepted(let accepted) = acceptedFrame else {
            Issue.record("Expected the E3 Review subscription acceptance")
            return
        }
        #expect((try await traceRecorder.waitUntilReviewBootstrapFinished()).result == .success)
        let reviewPackage = try availabilityReviewPackageFixture()
        let expectedItemIds = await AvailabilityBatchKeyProjection().orderedItemIds(in: reviewPackage)
        let scopeRequest = try reviewTestViewScopeRequest(itemIds: expectedItemIds)
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest, productAdmission: harness.productAdmission.context
            ) == nil
        )
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)

        let traceContext = try BridgeTraceContext(
            traceId: "55555555555555555555555555555555",
            spanId: "6666666666666666", parentSpanId: nil, sampled: true
        )
        let publication = availabilityCorrelatedCommittedPublication(reviewPackage)
        replayProvider.publication = publication
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage, publicationId: publication.publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let disposition = await coordinator.deliverReviewPublication(
            publication, reservation: reservation,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission,
            traceContext: traceContext
        )
        var frames: [BridgeProductMetadataFrame] = []
        for _ in 0..<(expectedItemIds.count + 3) {
            frames.append(try await pullAvailabilityMetadataFrame(from: pump))
        }
        let itemKeys = await AvailabilityBatchKeyProjection().putKeys(in: frames)
        let firstFrame = try #require(frames.first)
        let lastFrame = try #require(frames.last)
        guard case .batch(.begin(let begin)) = firstFrame,
            case .batch(.complete) = lastFrame
        else {
            let observedKinds = await AvailabilityBatchKeyProjection().kindSummary(in: frames)
            Issue.record("Expected one complete W4 Review snapshot; observed \(observedKinds)")
            return
        }
        #expect(accepted.frameIdentity.streamSequence == 1)
        #expect(begin.publicationId == publication.publicationId)
        #expect(begin.identity.handle == scopeRequest.handle)
        #expect(itemKeys == (await AvailabilityBatchKeyProjection().expectedKeys(for: expectedItemIds)))
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        #expect(disposition == .viewBatchSealed)
        #expect(
            await traceRecorder.publicationEvents == [
                .started(retainedSubscriptions: 1, traceContext: traceContext),
                .completed(
                    receipt: BridgeReviewMetadataPublicationReceipt(
                        retained: 1, publishedSubscriptions: 1, emittedEvents: 0,
                        superseded: 0, finalFrames: []
                    ),
                    traceContext: traceContext
                ),
            ]
        )
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("producer rejection returns failed without claiming observation")
    func producerRejectionReturnsFailedWithoutObservation() async throws {
        let traceContext = try BridgeTraceContext(
            traceId: "77777777777777777777777777777777",
            spanId: "8888888888888888",
            parentSpanId: nil,
            sampled: true
        )

        let result = try await exerciseAvailabilityPublicationFailure(
            .producerRejection,
            traceContext: traceContext
        )

        #expect(!result.reservationFailed)
        #expect(result.deliveryDisposition == .failed)
        #expect(
            result.traceEvents == [
                .started(retainedSubscriptions: 1, traceContext: traceContext),
                .failed(
                    failure: .producerRejection,
                    retainedSubscriptions: 1,
                    traceContext: traceContext
                ),
            ]
        )
    }
    @Test("Review event construction failure rejects reservation before delivery")
    func eventConstructionFailureRejectsReservationBeforeDelivery() async throws {
        let traceContext = try BridgeTraceContext(
            traceId: "99999999999999999999999999999999",
            spanId: "aaaaaaaaaaaaaaaa",
            parentSpanId: nil,
            sampled: true
        )

        let result = try await exerciseAvailabilityPublicationFailure(
            .eventConstruction,
            traceContext: traceContext
        )

        #expect(result.reservationFailed)
        #expect(result.deliveryDisposition == nil)
        #expect(result.traceEvents.isEmpty)
    }

    @Test("Review delivery with zero subscriptions is deferred")
    func reviewDeliveryWithZeroSubscriptionsIsDeferred() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let traceRecorder = AvailabilityReviewPublicationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgePaneProductReviewMetadataSource(),
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let reviewPackage = try availabilityReviewPackageFixture()
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage,
            publicationId: availabilityCommittedPublication(reviewPackage).publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Act
        let disposition = await coordinator.deliverReviewPublication(
            availabilityCommittedPublication(reviewPackage),
            reservation: reservation,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        #expect(disposition == .deferred)
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        #expect(
            await traceRecorder.publicationEvents == [
                .started(retainedSubscriptions: 0, traceContext: nil)
            ]
        )
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("committed successor supersedes suspended predecessor delivery before enqueue")
    func committedSuccessorSupersedesSuspendedPredecessorDelivery() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let reviewPackage = try availabilityReviewPackageFixture()
        let predecessor = availabilityCommittedPublication(reviewPackage)
        let successorPublicationId = UUID(uuidString: "33333333-3333-7333-8333-333333333333")!
        let currentPublication = await CoordinatorCurrentReviewPublication(
            publicationId: predecessor.publicationId
        )
        let source = CoordinatorSupersededDeliveryReviewMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: source,
            isReviewPublicationCurrent: { publicationId, productAdmission in
                currentPublication.matches(publicationId, productAdmission: productAdmission)
            },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        _ = try await openAvailabilityReviewSubscription(
            coordinator: coordinator,
            harness: harness,
            pump: pump
        )
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage,
            publicationId: predecessor.publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let delivery = Task {
            await coordinator.deliverReviewPublication(
                predecessor,
                reservation: reservation,
                productAdmission: harness.productAdmission.context,
                foregroundWorkAdmission: refreshWorkAdmission.admission
            )
        }
        await source.waitUntilDeliveryStarted()

        // Act
        await MainActor.run {
            currentPublication.publicationId = successorPublicationId
        }
        await source.releaseDelivery()
        await source.waitUntilDeliveryFinished()
        let queuedFrameCountAfterSuccessorCommit =
            (await harness.session.producerSnapshot()).queuedFrameCount
        if queuedFrameCountAfterSuccessorCommit > 0 {
            _ = try await pullAvailabilityMetadataFrame(from: pump)
        }
        let disposition = await delivery.value

        // Assert
        #expect(queuedFrameCountAfterSuccessorCommit == 0)
        #expect(disposition == .deferred)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("transient queue reset repairs current publication once on the same stream")
    func transientQueueResetRepairsCurrentPublicationOnce() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session,
            producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let reviewPackage = try availabilityReviewPackageFixture()
        let expectedItemIds = await AvailabilityBatchKeyProjection().orderedItemIds(in: reviewPackage)
        let publication = availabilityCommittedPublication(reviewPackage)
        let currentPublication = await CoordinatorCurrentReviewPublication(
            publicationId: publication.publicationId
        )
        let replayProvider = AvailabilityReviewPublicationProvider()
        let source = CoordinatorRepairingReviewMetadataSource()
        let traceRecorder = AvailabilityReviewPublicationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: source,
            reviewPublicationReplay: { _ in replayProvider.publication },
            isReviewPublicationCurrent: { publicationId, productAdmission in
                currentPublication.matches(publicationId, productAdmission: productAdmission)
            },
            refreshWorkAdmissionSource: refreshWorkAdmission.source,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(),
            lease: lease,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let acceptedFrame = try await openAvailabilityReviewSubscription(
            coordinator: coordinator,
            harness: harness,
            pump: pump
        )
        #expect((try await traceRecorder.waitUntilReviewBootstrapFinished()).result == .success)
        let scopeRequest = try reviewTestViewScopeRequest(itemIds: expectedItemIds)
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest, productAdmission: harness.productAdmission.context
            ) == nil
        )
        await MainActor.run { replayProvider.publication = publication }
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage,
            publicationId: publication.publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Act
        let delivery = Task {
            await coordinator.deliverReviewPublication(
                publication,
                reservation: reservation,
                productAdmission: harness.productAdmission.context,
                foregroundWorkAdmission: refreshWorkAdmission.admission
            )
        }
        let disposition = await delivery.value
        let deliveryAttempts = await source.deliveryAttempts

        #expect(deliveryAttempts == 2)
        #expect(disposition == .viewBatchSealed)
        guard disposition == .viewBatchSealed else {
            await coordinator.uninstall(lease: lease)
            #expect(await pump.cancel())
            return
        }
        var frames: [BridgeProductMetadataFrame] = []
        for _ in 0..<(expectedItemIds.count + 3) {
            frames.append(try await pullAvailabilityMetadataFrame(from: pump))
        }
        guard case .subscriptionAccepted(let accepted) = acceptedFrame,
            case .batch(.begin(let begin)) = frames.first,
            case .batch(.complete(let complete)) = frames.last
        else {
            let observedKinds = await AvailabilityBatchKeyProjection().kindSummary(in: frames)
            Issue.record("Expected acceptance and a complete repaired W4 batch; observed \(observedKinds)")
            await coordinator.uninstall(lease: lease)
            #expect(await pump.cancel())
            return
        }
        let itemKeys = await AvailabilityBatchKeyProjection().putKeys(in: frames)

        // Assert
        #expect(begin.identity.frame.metadataStreamId == accepted.frameIdentity.metadataStreamId)
        #expect(begin.identity.frame.streamSequence == accepted.frameIdentity.streamSequence + 1)
        #expect(begin.identity.handle == scopeRequest.handle)
        #expect(begin.publicationId == publication.publicationId)
        #expect(begin.partCount == expectedItemIds.count + 1)
        #expect(complete.identity.batchId == begin.identity.batchId)
        #expect(itemKeys == (await AvailabilityBatchKeyProjection().expectedKeys(for: expectedItemIds)))
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("suspended Review delivery cannot seal its predecessor and foreground return seals the current snapshot")
    @MainActor
    func foregroundReturnReplaysCurrentReviewSnapshot() async throws {
        let activityCoordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let initialForegroundAdmission = try #require(activityCoordinator.acquireForegroundWork())
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let lease = try await harness.admitMetadataFrames(through: 0)
        let pump = BridgeProductSchemeFramePump(
            session: harness.session, producerLease: lease,
            productAdmission: harness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let reviewPackage = try availabilityReviewPackageFixture()
        let expectedItemIds = await AvailabilityBatchKeyProjection().orderedItemIds(in: reviewPackage)
        let predecessor = availabilityCommittedPublication(reviewPackage)
        let successorPackage = replacingReviewSource(
            reviewPackage, packageId: "review-package-after-suspend",
            queryId: "review-query-after-suspend",
            generation: reviewPackage.reviewGeneration.rawValue + 1
        )
        let successorPublicationId = UUID(uuidString: "22222222-2222-7222-8222-222222222222")!
        let successor = reviewMetadataCommittedPublication(
            successorPackage, publicationId: successorPublicationId
        )
        let replayProvider = AvailabilityReviewPublicationProvider()
        let reviewSource = AvailabilityHeldReviewMetadataSource(holdFirstDelivery: true)
        let traceRecorder = AvailabilityReviewPublicationTraceRecorder()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: reviewSource,
            reviewPublicationReplay: { _ in replayProvider.publication },
            refreshWorkAdmissionSource: activityCoordinator.workAdmissionSource,
            lifecycleTraceRecorder: traceRecorder
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(), lease: lease,
            productAdmission: harness.productAdmission.context, session: harness.session
        )
        _ = try await openAvailabilityReviewSubscription(
            coordinator: coordinator, harness: harness, pump: pump
        )
        #expect((try await traceRecorder.waitUntilReviewBootstrapFinished()).result == .success)
        let scopeRequest = try reviewTestViewScopeRequest(itemIds: expectedItemIds)
        #expect(
            await harness.session.acceptViewScope(
                scopeRequest, productAdmission: harness.productAdmission.context
            ) == nil
        )
        replayProvider.publication = predecessor
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage, publicationId: predecessor.publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: initialForegroundAdmission
        )
        let interruptedDelivery = Task {
            await coordinator.deliverReviewPublication(
                predecessor, reservation: reservation,
                productAdmission: harness.productAdmission.context,
                foregroundWorkAdmission: initialForegroundAdmission
            )
        }
        #expect(try await reviewSource.waitUntilFirstDeliveryStarted() == predecessor.publicationId)

        activityCoordinator.applyActivity(.loadedHidden)
        await coordinator.suspendForegroundWork()
        await reviewSource.releaseFirstDelivery()
        #expect(await interruptedDelivery.value == .deferred)
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        #expect(initialForegroundAdmission.withValidAdmission { true } == nil)

        let successorReservation = try await reviewSource.reserve(
            package: successorPackage, publicationId: successorPublicationId,
            productAdmission: harness.productAdmission.context
        )
        _ = try await reviewSource.deliver(
            publication: successor, reservation: successorReservation,
            productAdmission: harness.productAdmission.context
        )
        replayProvider.publication = successor
        activityCoordinator.applyActivity(.foreground)
        await coordinator.resumeForegroundWork()
        var frames: [BridgeProductMetadataFrame] = []
        for _ in 0..<(expectedItemIds.count + 3) {
            frames.append(try await pullAvailabilityMetadataFrame(from: pump))
        }
        let itemKeys = await AvailabilityBatchKeyProjection().putKeys(in: frames)
        let firstFrame = try #require(frames.first)
        let lastFrame = try #require(frames.last)
        guard case .batch(.begin(let begin)) = firstFrame,
            case .batch(.complete) = lastFrame
        else {
            let observedKinds = await AvailabilityBatchKeyProjection().kindSummary(in: frames)
            Issue.record(
                "Expected a complete current Review W4 snapshot after foreground return; observed \(observedKinds)"
            )
            return
        }
        #expect(begin.publicationId == successor.publicationId)
        #expect(begin.publicationId != predecessor.publicationId)
        #expect(begin.identity.handle == scopeRequest.handle)
        #expect(itemKeys == (await AvailabilityBatchKeyProjection().expectedKeys(for: expectedItemIds)))
        #expect((await harness.session.producerSnapshot()).queuedFrameCount == 0)
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
    }

    @Test("failing Review publication cannot reset a replacement metadata stream")
    func failingReviewPublicationCannotResetReplacementMetadataStream() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let firstHarness = try await BridgeProductSessionLifecycleHarness.opened()
        let firstLease = try await firstHarness.admitMetadataFrames(through: 0)
        let firstPump = BridgeProductSchemeFramePump(
            session: firstHarness.session,
            producerLease: firstLease,
            productAdmission: firstHarness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        let source = AvailabilitySuspendedFailingReviewMetadataSource()
        let coordinator = BridgePaneProductMetadataCoordinator(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: source,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(),
            lease: firstLease,
            productAdmission: firstHarness.productAdmission.context,
            session: firstHarness.session
        )
        _ = try await openAvailabilityReviewSubscription(
            coordinator: coordinator,
            harness: firstHarness,
            pump: firstPump
        )
        let reviewPackage = try availabilityReviewPackageFixture()
        let reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage,
            publicationId: availabilityCommittedPublication(reviewPackage).publicationId,
            productAdmission: firstHarness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
        let failingPublication = Task {
            await coordinator.deliverReviewPublication(
                availabilityCommittedPublication(reviewPackage),
                reservation: reservation,
                productAdmission: firstHarness.productAdmission.context,
                foregroundWorkAdmission: refreshWorkAdmission.admission
            )
        }
        #expect(await source.waitUntilDeliverStarted() == reservation.publicationId)

        let replacementHarness = try await BridgeProductSessionLifecycleHarness.opened()
        let replacementLease = try await replacementHarness.admitMetadataFrames(through: 0)
        let replacementPump = BridgeProductSchemeFramePump(
            session: replacementHarness.session,
            producerLease: replacementLease,
            productAdmission: replacementHarness.productAdmission.context,
            acknowledgeLifecycle: { _ in true }
        )
        await coordinator.install(
            request: try availabilityMetadataStreamRequest(),
            lease: replacementLease,
            productAdmission: replacementHarness.productAdmission.context,
            session: replacementHarness.session
        )
        let replacementAcceptedFrame = try await openAvailabilityReviewSubscription(
            coordinator: coordinator,
            harness: replacementHarness,
            pump: replacementPump
        )

        // Act
        await source.releaseDeliverFailure()
        let failingDisposition = await failingPublication.value

        // Assert
        guard case .subscriptionAccepted = replacementAcceptedFrame else {
            Issue.record("Expected the replacement Review subscription to be accepted")
            return
        }
        #expect(failingDisposition == .deferred)
        #expect((await replacementHarness.session.producerSnapshot()).queuedFrameCount == 0)
        await coordinator.uninstall(lease: replacementLease)
        #expect(await firstPump.cancel())
        #expect(await replacementPump.cancel())
    }
}

private enum AvailabilityCoordinatorTestError: Error {
    case expectedFrame
    case publicationFailed
}

private actor AvailabilityBatchKeyProjection {
    func orderedItemIds(in package: BridgeReviewPackage) -> [String] {
        BridgePaneProductReviewMetadataSource.orderedItemIds(in: package)
    }

    func kindSummary(in frames: [BridgeProductMetadataFrame]) -> [String] {
        frames.map(\.kind)
    }

    func expectedKeys(for itemIds: [String]) -> [String] {
        itemIds.sorted() + ["publication"]
    }

    func putKeys(in frames: [BridgeProductMetadataFrame]) -> [String] {
        frames.compactMap { frame in
            guard case .batch(.part(let part)) = frame,
                case .put(let key, _, _) = part.part
            else { return nil }
            return key
        }
    }
}

private enum AvailabilityReviewPublicationFailureMode: Sendable {
    case eventConstruction
    case producerRejection
}

private struct AvailabilityReviewPublicationFailureResult {
    let reservationFailed: Bool
    let deliveryDisposition: BridgeReviewPublicationDeliveryDisposition?
    let traceEvents: [BridgeProductReviewMetadataPublicationTraceEvent]
}

private actor AvailabilityDeliveryDispositionProbe {
    private(set) var disposition: BridgeReviewPublicationDeliveryDisposition?

    func record(_ disposition: BridgeReviewPublicationDeliveryDisposition) {
        self.disposition = disposition
    }
}

private actor AvailabilityThrowingReviewMetadataSource:
    BridgePaneProductReviewMetadataProducing
{
    private let failureMode: AvailabilityReviewPublicationFailureMode

    init(failureMode: AvailabilityReviewPublicationFailureMode) {
        self.failureMode = failureMode
    }

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {}

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        switch failureMode {
        case .eventConstruction:
            throw BridgePaneProductReviewMetadataSourceError.metadataEventExceedsByteLimit
        case .producerRejection:
            return availabilityReservation(for: package, publicationId: publicationId)
        }
    }

    func deliver(
        publication _: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        throw BridgePaneProductMetadataCoordinatorError.producerRejected(.unknownLease)
    }

    func cancel(subscriptionId _: String) {}
}

private actor AvailabilitySuspendedFailingReviewMetadataSource:
    BridgePaneProductReviewMetadataProducing
{
    private var startedPublicationId: UUID?
    private var deliverStartedWaiters: [CheckedContinuation<UUID, Never>] = []
    private var deliverRelease: CheckedContinuation<Void, Never>?

    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {}

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        availabilityReservation(for: package, publicationId: publicationId)
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        startedPublicationId = publication.publicationId
        let waiters = deliverStartedWaiters
        deliverStartedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: publication.publicationId) }
        await withCheckedContinuation { continuation in
            deliverRelease = continuation
        }
        throw AvailabilityCoordinatorTestError.publicationFailed
    }

    func cancel(subscriptionId _: String) {}

    func waitUntilDeliverStarted() async -> UUID {
        if let startedPublicationId { return startedPublicationId }
        return await withCheckedContinuation { continuation in
            deliverStartedWaiters.append(continuation)
        }
    }

    func releaseDeliverFailure() {
        deliverRelease?.resume()
        deliverRelease = nil
    }
}

private func openAvailabilityReviewSubscription(
    coordinator: BridgePaneProductMetadataCoordinator,
    harness: BridgeProductSessionLifecycleHarness,
    pump: BridgeProductSchemeFramePump
) async throws -> BridgeProductMetadataFrame {
    let openRequest = try bridgeProductLifecycleControlRequest(
        bridgeProductLifecycleReviewSubscriptionOpenObject(requestSequence: 2, epoch: 1)
    )
    let token = try #require(availabilityControlExecutionToken(try await harness.begin(openRequest)))
    #expect(await harness.session.admitControlProviderExecution(token: token))
    let response = try BridgeProductControlResponse.subscriptionOpenAccepted(
        correlating: openRequest,
        worktreeId: nil
    )
    let effect = try await harness.session.completeAdmittedControl(
        token: token,
        exactResponseBytes: try JSONEncoder().encode(response)
    )
    let acceptedFrame = try await pullAvailabilityMetadataFrame(from: pump)
    await coordinator.apply(
        effect,
        productAdmission: harness.productAdmission.context
    )
    await harness.session.settleControlProviderDispatch(token: token)
    return acceptedFrame
}

private func pullAvailabilityMetadataFrame(
    from pump: BridgeProductSchemeFramePump
) async throws -> BridgeProductMetadataFrame {
    guard case .frame(let delivery) = await pump.nextFrame() else {
        throw AvailabilityCoordinatorTestError.expectedFrame
    }
    #expect(await pump.acknowledgeFrameConsumed(delivery.receipt))
    let decoder = try BridgeProductMetadataFrameDecoder()
    let frames = try decoder.append(delivery.frame.data)
    return try #require(frames.first)
}
private func exerciseAvailabilityPublicationFailure(
    _ failureMode: AvailabilityReviewPublicationFailureMode,
    traceContext: BridgeTraceContext
) async throws -> AvailabilityReviewPublicationFailureResult {
    let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
    let harness = try await BridgeProductSessionLifecycleHarness.opened()
    let lease = try await harness.admitMetadataFrames(through: 0)
    let pump = BridgeProductSchemeFramePump(
        session: harness.session,
        producerLease: lease,
        productAdmission: harness.productAdmission.context,
        acknowledgeLifecycle: { _ in true }
    )
    let traceRecorder = AvailabilityReviewPublicationTraceRecorder()
    let coordinator = BridgePaneProductMetadataCoordinator(
        fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
        reviewMetadataSource: AvailabilityThrowingReviewMetadataSource(failureMode: failureMode),
        refreshWorkAdmissionSource: refreshWorkAdmission.source,
        lifecycleTraceRecorder: traceRecorder
    )
    await coordinator.install(
        request: try availabilityMetadataStreamRequest(),
        lease: lease,
        productAdmission: harness.productAdmission.context,
        session: harness.session
    )
    _ = try await openAvailabilityReviewSubscription(
        coordinator: coordinator,
        harness: harness,
        pump: pump
    )

    let reviewPackage = try availabilityReviewPackageFixture()
    let reservation: BridgeReviewMetadataPublicationReservation
    do {
        reservation = try await coordinator.reserveReviewPublication(
            package: reviewPackage,
            publicationId: availabilityCommittedPublication(reviewPackage).publicationId,
            productAdmission: harness.productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )
    } catch {
        let traceEvents = await traceRecorder.publicationEvents
        await coordinator.uninstall(lease: lease)
        #expect(await pump.cancel())
        return AvailabilityReviewPublicationFailureResult(
            reservationFailed: true,
            deliveryDisposition: nil,
            traceEvents: traceEvents
        )
    }
    let deliveryDisposition = await coordinator.deliverReviewPublication(
        availabilityCommittedPublication(reviewPackage),
        reservation: reservation,
        productAdmission: harness.productAdmission.context,
        foregroundWorkAdmission: refreshWorkAdmission.admission,
        traceContext: traceContext
    )
    let traceEvents = await traceRecorder.publicationEvents
    await coordinator.uninstall(lease: lease)
    #expect(await pump.cancel())
    return AvailabilityReviewPublicationFailureResult(
        reservationFailed: false,
        deliveryDisposition: deliveryDisposition,
        traceEvents: traceEvents
    )
}
