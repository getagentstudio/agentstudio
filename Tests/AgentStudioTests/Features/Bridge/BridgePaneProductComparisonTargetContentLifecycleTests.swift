import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge comparison-target content lifecycle")
struct BridgeComparisonTargetContentLifecycleTests {
    @Test("held catalog production leaves the control lane available")
    func heldCatalogProductionLeavesControlLaneAvailable() async throws {
        let fixture = try makeCapture(
            body: Data("comparison-target-body".utf8),
            suffix: "held-production"
        )
        let producer = HeldComparisonTargetCatalogProducer(fixture: fixture)
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { fixture.authorization },
            reviewComparisonTargetCatalogProducer: producer,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes,
            deadlineClock: TestPushClock()
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let openAdmission = try await dispatcher.dispatch(
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let openResult = try await awaitBridgeProductAdmittedControlResult(
            openAdmission,
            session: session,
            productAdmission: productAdmission
        )
        #expect(openResult.outcome == .succeeded)
        let firstQueryResult = try await dispatcher.dispatch(
            exactRequestBytes: JSONEncoder().encode(try queryRequest(sequence: 2)),
            presentedCapability: capabilityHeader
        )
        let queryResult = try await awaitBridgeProductAdmittedControlResult(
            firstQueryResult,
            session: session,
            productAdmission: productAdmission
        )
        #expect(queryResult.outcome == .succeeded)

        let request = try contentRequest(
            descriptor: fixture.descriptor,
            suffix: "held-production"
        )
        let operation = provider.makeContentProducerOperation(
            request: request,
            productAdmission: productAdmission,
            session: session
        )
        let registration = await session.registerContentProducer(
            request: request,
            productAdmission: productAdmission
        ) { lease in await operation(lease) }
        let lease = try bridgeProductAcceptedLease(registration)
        let openingDelivery = try await nextFrame(
            for: lease,
            from: session,
            productAdmission: productAdmission
        )
        #expect(openingDelivery.frame.sequence == 0)
        #expect(
            await session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: openingDelivery.frame.sequence
                ),
                productAdmission: productAdmission
            )
        )
        await producer.waitUntilStarted()

        let unrelatedControl = try await dispatcher.dispatch(
            exactRequestBytes: JSONEncoder().encode(try activeViewerModeUpdateRequest(sequence: 3)),
            presentedCapability: capabilityHeader
        )

        let modeResult = try await awaitBridgeProductAdmittedControlResult(
            unrelatedControl,
            session: session,
            productAdmission: productAdmission
        )
        #expect(modeResult.outcome == .succeeded)
        #expect(await provider.pendingComparisonTargetReservation == nil)
        await producer.release()
        try await acknowledgeRemainingFramesAndRetire(
            lease: lease,
            request: request,
            session: session,
            productAdmission: productAdmission,
            provider: provider
        )
    }

    @Test("exact descriptor identity streams the pending body")
    func exactDescriptorIdentityStreamsPendingBody() async throws {
        let body = Data("comparison-target-body".utf8)
        let capture = try makeCapture(body: body, suffix: "exact")
        let traceProbe = ComparisonTargetCatalogTraceProbe()
        let provider = await makeProvider(capture: capture, traceRecorder: traceProbe)
        _ = await provider.response(for: try queryRequest())

        let result = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: capture.descriptor, suffix: "exact")
        )

        #expect(result.body == body)
        #expect(result.accepted)
        #expect(result.observedByteLength == body.count)
        #expect(result.observedSha256 == capture.sha256)
        #expect(result.errorMessage == nil)
        await traceProbe.waitForEventCount(3)
        let events = await traceProbe.events
        #expect(events.first { $0.stage == .authorization }?.outcome == .success)
        #expect(events.first { $0.stage == .reservationClaim }?.outcome == .claimed)
        let terminalEvent = events.first { $0.stage == .terminal }
        #expect(terminalEvent?.outcome == .complete)
        #expect(events.compactMap(\.queryRequestSequence).allSatisfy { $0 == 1 })
        #expect(terminalEvent?.observedByteCount == body.count)
    }

    @Test("same descriptor id with a changed maximum is rejected without detaching the active descriptor")
    func changedMetadataIsRejectedWithoutDetachingActiveDescriptor() async throws {
        let body = Data("comparison-target-body".utf8)
        let capture = try makeCapture(body: body, suffix: "metadata")
        let captureQueue = ComparisonTargetFixtureSource(fixtures: [capture])
        let provider = await makeProvider(captureQueue: captureQueue)
        _ = await provider.response(for: try queryRequest())
        let alteredDescriptor = try BridgeProductReviewComparisonTargetsContentDescriptor(
            descriptorId: capture.descriptor.descriptorId,
            maximumBytes: capture.descriptor.maximumBytes - 1
        )

        let mismatch = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: alteredDescriptor, suffix: "metadata-mismatch")
        )
        let secondOpen = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: capture.descriptor, suffix: "metadata-replay")
        )

        #expect(mismatch.body.isEmpty)
        #expect(mismatch.accepted)
        #expect(mismatch.errorCode == .unsupportedContent)
        #expect(mismatch.retryable == false)
        #expect(mismatch.errorMessage == "Content descriptor is not active")
        #expect(secondOpen.body == body)
        #expect(secondOpen.errorMessage == nil)
        #expect(await captureQueue.productionAttemptCount == 1)
    }

    @Test("newer Review authority cannot claim an older comparison reservation")
    func newerReviewAuthorityCannotClaimOlderReservation() async throws {
        let body = Data("comparison-target-body".utf8)
        let capture = try makeCapture(body: body, suffix: "authority")
        let captureQueue = ComparisonTargetFixtureSource(fixtures: [capture])
        let provider = await makeProvider(captureQueue: captureQueue)
        _ = await provider.response(for: try queryRequest())

        let newerAuthorityOpen = try await openContent(
            provider: provider,
            request: contentRequest(
                descriptor: capture.descriptor,
                suffix: "newer-authority",
                workerDerivationEpoch: 1
            )
        )
        let exactAuthorityOpen = try await openContent(
            provider: provider,
            request: contentRequest(
                descriptor: capture.descriptor,
                suffix: "exact-authority"
            )
        )

        #expect(newerAuthorityOpen.errorMessage == "Content descriptor is not active")
        #expect(newerAuthorityOpen.accepted)
        #expect(newerAuthorityOpen.errorCode == .unsupportedContent)
        #expect(newerAuthorityOpen.retryable == false)
        #expect(exactAuthorityOpen.body == body)
        #expect(exactAuthorityOpen.errorMessage == nil)
        #expect(await captureQueue.productionAttemptCount == 1)
    }

    @Test("different descriptor identity is rejected without detaching the active descriptor")
    func differentDescriptorIdentityIsRejectedWithoutDetachingActiveDescriptor() async throws {
        let body = Data("comparison-target-body".utf8)
        let capture = try makeCapture(body: body, suffix: "different")
        let captureQueue = ComparisonTargetFixtureSource(fixtures: [capture])
        let provider = await makeProvider(captureQueue: captureQueue)
        _ = await provider.response(for: try queryRequest())
        let differentDescriptor = try makeCapture(body: body, suffix: "other").descriptor

        let mismatch = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: differentDescriptor, suffix: "different-mismatch")
        )
        let replay = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: capture.descriptor, suffix: "different-replay")
        )

        #expect(mismatch.errorMessage == "Content descriptor is not active")
        #expect(mismatch.accepted)
        #expect(mismatch.errorCode == .unsupportedContent)
        #expect(mismatch.retryable == false)
        #expect(replay.body == body)
        #expect(replay.errorMessage == nil)
        #expect(await captureQueue.productionAttemptCount == 1)
    }

    @Test("late stale open does not detach the newest query")
    func lateStaleOpenDoesNotDetachNewestQuery() async throws {
        let firstCapture = try makeCapture(
            body: Data("first-comparison-target-body".utf8),
            suffix: "exact"
        )
        let newestBody = Data("newest-comparison-target-body".utf8)
        let newestCapture = try makeCapture(body: newestBody, suffix: "other")
        let captureQueue = ComparisonTargetFixtureSource(fixtures: [firstCapture, newestCapture])
        let provider = await makeProvider(captureQueue: captureQueue)
        _ = await provider.response(for: try queryRequest(suffix: "first", sequence: 1))
        _ = await provider.response(for: try queryRequest(suffix: "newest", sequence: 2))

        let staleOpen = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: firstCapture.descriptor, suffix: "stale-open")
        )
        let newestOpen = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: newestCapture.descriptor, suffix: "newest-open")
        )

        #expect(staleOpen.errorMessage == "Content descriptor is not active")
        #expect(staleOpen.accepted)
        #expect(staleOpen.errorCode == .unsupportedContent)
        #expect(staleOpen.retryable == false)
        #expect(newestOpen.body == newestBody)
        #expect(newestOpen.errorMessage == nil)
        #expect(await captureQueue.productionAttemptCount == 1)
    }

    @Test("second exact open is rejected after the first consumes the pending body")
    func secondExactOpenIsRejected() async throws {
        let body = Data("comparison-target-body".utf8)
        let capture = try makeCapture(body: body, suffix: "second")
        let captureQueue = ComparisonTargetFixtureSource(fixtures: [capture])
        let traceProbe = ComparisonTargetCatalogTraceProbe()
        let provider = await makeProvider(captureQueue: captureQueue, traceRecorder: traceProbe)
        _ = await provider.response(for: try queryRequest())

        let first = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: capture.descriptor, suffix: "first")
        )
        let second = try await openContent(
            provider: provider,
            request: contentRequest(descriptor: capture.descriptor, suffix: "second")
        )

        #expect(first.body == body)
        #expect(second.errorMessage == "Content descriptor is not active")
        #expect(second.accepted)
        #expect(second.errorCode == .unsupportedContent)
        #expect(second.retryable == false)
        #expect(await captureQueue.productionAttemptCount == 1)
        await traceProbe.waitForEventCount(5)
        let traceEvents = await traceProbe.events
        let inactiveClaim = traceEvents.first {
            $0.stage == .reservationClaim && $0.outcome == .inactive
        }
        let unsupportedTerminal = traceEvents.first {
            $0.stage == .terminal && $0.outcome == .unsupportedContent
        }
        #expect(inactiveClaim?.queryRequestSequence == nil)
        #expect(unsupportedTerminal?.queryRequestSequence == nil)
    }

    @Test("rejected registration leaves the comparison reservation unclaimed")
    func rejectedRegistrationLeavesReservationUnclaimed() async throws {
        let body = Data("comparison-target-body".utf8)
        let capture = try makeCapture(body: body, suffix: "registration-rejection")
        let provider = await makeProvider(capture: capture)
        _ = await provider.response(for: try queryRequest())
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let rejectedRequest = try contentRequest(
            descriptor: capture.descriptor,
            suffix: "registration-rejection",
            workerInstanceId: "worker-instance-other"
        )
        let rejectedOperation = provider.makeContentProducerOperation(
            request: rejectedRequest,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )

        let rejectedRegistration = await harness.session.registerContentProducer(
            request: rejectedRequest,
            productAdmission: harness.productAdmission.context
        ) { lease in await rejectedOperation(lease) }
        let acceptedAfterRejection = try await openContent(
            provider: provider,
            request: contentRequest(
                descriptor: capture.descriptor,
                suffix: "accepted-after-rejection"
            )
        )

        #expect(rejectedRegistration == .rejected(.staleWorker))
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
        #expect(acceptedAfterRejection.body == body)
        #expect(acceptedAfterRejection.errorMessage == nil)
    }

    @Test("producer failure is retryable and a newer query can succeed")
    func producerFailureIsRetryableAndNewerQueryCanSucceed() async throws {
        let failedFixture = try makeCapture(
            body: Data("unused-failed-comparison-target-body".utf8),
            suffix: "failure"
        )
        let successfulBody = Data("successful-comparison-target-body".utf8)
        let successfulFixture = try makeCapture(
            body: successfulBody,
            suffix: "other"
        )
        let reservationSource = ComparisonTargetFixtureSource(
            fixtures: [failedFixture, successfulFixture]
        )
        let producer = FailOnceComparisonTargetCatalogProducer(
            successfulFixture: successfulFixture
        )
        let traceProbe = ComparisonTargetCatalogTraceProbe()
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { await reservationSource.nextAuthorization() },
            reviewComparisonTargetCatalogProducer: producer,
            comparisonTargetCatalogTraceRecorder: traceProbe,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )

        _ = await provider.response(for: try queryRequest(suffix: "failure", sequence: 1))
        let failure = try await openContent(
            provider: provider,
            request: contentRequest(
                descriptor: failedFixture.descriptor,
                suffix: "producer-failure"
            )
        )
        _ = await provider.response(for: try queryRequest(suffix: "retry", sequence: 2))
        let retry = try await openContent(
            provider: provider,
            request: contentRequest(
                descriptor: successfulFixture.descriptor,
                suffix: "producer-retry"
            )
        )

        #expect(failure.accepted)
        #expect(failure.body.isEmpty)
        #expect(failure.errorMessage == "Comparison targets are unavailable")
        #expect(failure.retryable == true)
        #expect(retry.body == successfulBody)
        #expect(retry.errorMessage == nil)
        #expect(await producer.productionAttemptCount == 2)
        await traceProbe.waitForEventCount(6)
        let traceEvents = await traceProbe.events
        let terminalOutcomes =
            traceEvents
            .filter { $0.stage == .terminal }
            .map(\.outcome)
        #expect(terminalOutcomes.count == 2)
        #expect(terminalOutcomes.contains(.productionFailed))
        #expect(terminalOutcomes.contains(.complete))
    }

    @Test("foreground loss cancels held comparison target production")
    @MainActor
    func foregroundLossCancelsHeldComparisonTargetProduction() async throws {
        let body = Data("comparison-target-body".utf8)
        let admissionCoordinator = BridgePaneRefreshAdmissionCoordinator(
            initialActivity: .foreground
        )
        _ = try #require(admissionCoordinator.acquireForegroundWork())
        let capture = try makeCapture(body: body, suffix: "foreground-loss")
        let producer = CancellationAwareComparisonTargetCatalogProducer(fixture: capture)
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { capture.authorization },
            reviewComparisonTargetCatalogProducer: producer,
            refreshWorkAdmissionSource: admissionCoordinator.workAdmissionSource
        )
        _ = await provider.response(for: try queryRequest())
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let request = try contentRequest(
            descriptor: capture.descriptor,
            suffix: "foreground-loss"
        )
        let operation = provider.makeContentProducerOperation(
            request: request,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission.context
        ) { lease in await operation(lease) }
        let lease = try bridgeProductAcceptedLease(registration)
        let openingDelivery = try await nextFrame(for: lease, in: harness)
        #expect(
            await harness.session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: openingDelivery.frame.sequence
                ),
                productAdmission: harness.productAdmission.context
            )
        )
        await producer.waitUntilStarted()

        admissionCoordinator.applyActivity(.loadedHidden)
        await producer.waitUntilCancelled()

        let retirement = await harness.session.beginProducerRetirement(
            lease,
            acknowledgeLifecycle: provider.acknowledgeLifecycle,
            stopRequest: nil,
            abandonOutstandingDelivery: true
        )
        #expect(await retirement.wait())
        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }

}

extension BridgeComparisonTargetContentLifecycleTests {
    @Test("worker replacement cancels claimed production and clears an unclaimed reservation")
    func workerReplacementCancelsProductionAndClearsReservation() async throws {
        let claimedCapture = try makeCapture(
            body: Data("claimed-comparison-target-body".utf8),
            suffix: "exact"
        )
        let unclaimedCapture = try makeCapture(
            body: Data("unclaimed-comparison-target-body".utf8),
            suffix: "other"
        )
        let authorizationSource = ComparisonTargetFixtureSource(
            fixtures: [claimedCapture, unclaimedCapture]
        )
        let producer = CancellationAwareComparisonTargetCatalogProducer(fixture: claimedCapture)
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { await authorizationSource.nextAuthorization() },
            reviewComparisonTargetCatalogProducer: producer,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmissionGate = BridgeProductAdmissionGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            operationDeadlineClock: TestPushClock()
        )
        let productAdmission = try #require(productAdmissionGate.acquire())
        let oldInstallation = try await owner.prepareCandidate(productAdmission: productAdmission)
        #expect(
            await owner.activatePreparedCandidate(
                oldInstallation,
                productAdmission: productAdmission
            ) == .activated
        )
        try await openBridgePaneProductSession(oldInstallation)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            oldInstallation.capabilityBytes
        )
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: oldInstallation.session,
            provider: provider,
            productAdmission: productAdmission
        )
        let paneSessionId = oldInstallation.bootstrap.paneSessionId
        let workerInstanceId = oldInstallation.bootstrap.workerInstanceId
        try await admitComparisonTargetQuery(
            suffix: "claimed", sequence: 2, installation: oldInstallation,
            dispatcher: dispatcher, capabilityHeader: capabilityHeader,
            productAdmission: productAdmission
        )
        let contentRequest = try contentRequest(
            descriptor: claimedCapture.descriptor,
            suffix: "claimed",
            paneSessionId: paneSessionId,
            workerInstanceId: workerInstanceId
        )
        _ = try await startComparisonTargetProducer(
            provider: provider,
            session: oldInstallation.session,
            request: contentRequest,
            productAdmission: productAdmission
        )
        await producer.waitUntilStarted()
        try await admitComparisonTargetQuery(
            suffix: "unclaimed", sequence: 3, installation: oldInstallation,
            dispatcher: dispatcher, capabilityHeader: capabilityHeader,
            productAdmission: productAdmission
        )
        #expect(await provider.pendingComparisonTargetReservation?.descriptor == unclaimedCapture.descriptor)

        let replacementCandidate = try await owner.prepareCandidate(productAdmission: productAdmission)
        #expect(
            await owner.activatePreparedCandidate(
                replacementCandidate,
                productAdmission: productAdmission
            ) == .activated
        )
        await producer.waitUntilCancelled()

        let oldSessionRevocation = await oldInstallation.session.revoke(
            acknowledgeLifecycle: provider.acknowledgeLifecycle
        )
        #expect(await oldSessionRevocation.wait())
        #expect((await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        #expect(await provider.pendingComparisonTargetReservation == nil)
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == replacementCandidate.bootstrap.workerInstanceId
        )
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
        #expect((await owner.snapshot()).hasZeroResidue)
    }

    func admitComparisonTargetQuery(
        suffix: String,
        sequence: Int,
        installation: BridgeProductSessionInstallation,
        dispatcher: BridgeProductSchemeControlDispatcher,
        capabilityHeader: String,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        let queryAdmission = try await dispatcher.dispatch(
            exactRequestBytes: JSONEncoder().encode(
                try queryRequest(
                    suffix: suffix,
                    sequence: sequence,
                    paneSessionId: installation.bootstrap.paneSessionId,
                    workerInstanceId: installation.bootstrap.workerInstanceId
                )
            ),
            presentedCapability: capabilityHeader
        )
        let result = try await awaitBridgeProductAdmittedControlResult(
            queryAdmission,
            session: installation.session,
            productAdmission: productAdmission
        )
        #expect(result.outcome == .succeeded)
    }

    private func startComparisonTargetProducer(
        provider: BridgePaneProductSchemeProvider,
        session: BridgeProductSession,
        request: BridgeProductContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeProductProducerLease {
        let operation = provider.makeContentProducerOperation(
            request: request,
            productAdmission: productAdmission,
            session: session
        )
        let registration = await session.registerContentProducer(
            request: request,
            productAdmission: productAdmission
        ) { lease in await operation(lease) }
        let lease = try bridgeProductAcceptedLease(registration)
        let openingDelivery = try await nextFrame(
            for: lease,
            from: session,
            productAdmission: productAdmission
        )
        #expect(
            await session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: openingDelivery.frame.sequence
                ),
                productAdmission: productAdmission
            )
        )
        return lease
    }

    @Test("retire-first worker replacement clears a reservation installed by a late control")
    func retireFirstWorkerReplacementClearsLateReservation() async throws {
        let capture = try makeCapture(
            body: Data("late-comparison-target-body".utf8),
            suffix: "late-retirement"
        )
        let authorizationSource = HeldComparisonTargetAuthorizationSource(
            authorization: capture.authorization
        )
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { await authorizationSource.nextAuthorization() },
            reviewComparisonTargetCatalogProducer: ComparisonTargetFixtureSource(
                fixtures: [capture]
            ),
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmissionGate = BridgeProductAdmissionGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            operationDeadlineClock: TestPushClock()
        )
        let productAdmission = try #require(productAdmissionGate.acquire())
        let oldInstallation = try await owner.prepareCandidate(
            productAdmission: productAdmission
        )
        #expect(
            await owner.activatePreparedCandidate(
                oldInstallation,
                productAdmission: productAdmission
            ) == .activated
        )
        try await openBridgePaneProductSession(oldInstallation)
        let replacementCandidate = try await owner.prepareCandidate(
            productAdmission: productAdmission
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            oldInstallation.capabilityBytes
        )
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: oldInstallation.session,
            provider: provider,
            productAdmission: productAdmission
        )
        let queryTask = Task {
            try await dispatcher.dispatch(
                exactRequestBytes: JSONEncoder().encode(
                    try queryRequest(
                        suffix: "late-retirement",
                        sequence: 2,
                        paneSessionId: oldInstallation.bootstrap.paneSessionId,
                        workerInstanceId: oldInstallation.bootstrap.workerInstanceId
                    )
                ),
                presentedCapability: capabilityHeader
            )
        }
        await authorizationSource.waitUntilRequested()
        let retirementTask = Task {
            await owner.retire(reason: .workerReplacement)
        }
        #expect(await retirementTask.value == .retired)
        #expect((await oldInstallation.session.snapshot).lifecycle == .revoked)

        await authorizationSource.release()
        _ = try await queryTask.value

        #expect(await provider.pendingComparisonTargetReservation == nil)
        try await expectRetiredWorkerQueryRefused(
            provider: provider,
            installation: oldInstallation,
            productAdmission: productAdmission
        )
        #expect(await provider.pendingComparisonTargetReservation == nil)
        #expect(
            await owner.activatePreparedCandidate(
                replacementCandidate,
                productAdmission: productAdmission
            ) == .activated
        )
        try await expectSuccessorComparisonTargetReservation(
            provider: provider,
            installation: replacementCandidate,
            productAdmission: productAdmission
        )
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
        #expect((await owner.snapshot()).hasZeroResidue)
    }

    @Test("close and drain releases a pending comparison reservation")
    func closeAndDrainReleasesPendingReservation() async throws {
        let capture = try makeCapture(body: Data("comparison-target-body".utf8), suffix: "cleanup")
        let provider = await makeProvider(capture: capture)
        _ = await provider.response(for: try queryRequest())
        await provider.closeAndDrain()
        #expect(await provider.pendingComparisonTargetReservation == nil)
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let request = try contentRequest(descriptor: capture.descriptor, suffix: "cleanup-open")
        let operation = provider.makeContentProducerOperation(
            request: request,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission.context
        ) { lease in await operation(lease) }
        let lease = try bridgeProductAcceptedLease(registration)

        try await harness.closeProducer(lease)

        #expect((await harness.session.producerSnapshot()).hasZeroResidue)
    }

    private struct ContentResult {
        let accepted: Bool
        let body: Data
        let errorCode: BridgeProductRequestErrorCode?
        let errorMessage: String?
        let observedByteLength: Int?
        let observedSha256: String?
        let retryable: Bool?
    }

    private func makeProvider(
        capture: ComparisonTargetFixture,
        refreshWorkAdmissionSource: BridgePaneRefreshWorkAdmissionSource
    ) -> BridgePaneProductSchemeProvider {
        BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { capture.authorization },
            reviewComparisonTargetCatalogProducer: ComparisonTargetFixtureSource(
                fixtures: [capture]
            ),
            refreshWorkAdmissionSource: refreshWorkAdmissionSource
        )
    }

    private func makeProvider(
        captureQueue: ComparisonTargetFixtureSource,
        traceRecorder: (any BridgeReviewComparisonTargetCatalogTraceRecording)? = nil
    ) async -> BridgePaneProductSchemeProvider {
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        return BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            authorizeReviewComparisonTargets: { await captureQueue.nextAuthorization() },
            reviewComparisonTargetCatalogProducer: captureQueue,
            comparisonTargetCatalogTraceRecorder: traceRecorder,
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
    }

    private func activeViewerModeUpdateRequest(
        sequence: Int,
        paneSessionId: String = "pane-session-1",
        workerDerivationEpoch: Int = 0,
        workerInstanceId: String = "worker-instance-1"
    ) throws -> BridgeProductControlRequest {
        try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: Data(
                """
                {"call":{"method":"review.activeViewerMode.update","request":{"activeSource":{"generation":1,"streamId":"review-stream-1"},"nativeSelectionRequestId":null,"sequence":1,"sessionId":"viewer-session-1"}},"kind":"product.call","paneSessionId":"\(paneSessionId)","requestId":"unrelated-control","requestSequence":\(sequence),"wireVersion":2,"workerDerivationEpoch":\(workerDerivationEpoch),"workerInstanceId":"\(workerInstanceId)"}
                """.utf8
            )
        )
    }

    func contentRequest(
        descriptor: BridgeProductReviewComparisonTargetsContentDescriptor,
        suffix: String,
        paneSessionId: String = "pane-session-1",
        workerDerivationEpoch: Int = 0,
        workerInstanceId: String = "worker-instance-1"
    ) throws -> BridgeProductContentRequest {
        try BridgeProductStrictJSON.decode(
            BridgeProductContentRequest.self,
            from: JSONEncoder().encode(
                BridgeReviewComparisonTargetsContentRequestTest(
                    descriptor: descriptor,
                    suffix: suffix,
                    paneSessionId: paneSessionId,
                    workerDerivationEpoch: workerDerivationEpoch,
                    workerInstanceId: workerInstanceId
                )
            )
        )
    }

    private func openContent(
        provider: BridgePaneProductSchemeProvider,
        request: BridgeProductContentRequest
    ) async throws -> ContentResult {
        let harness = try await BridgeProductSessionLifecycleHarness.opened()
        let operation = provider.makeContentProducerOperation(
            request: request,
            productAdmission: harness.productAdmission.context,
            session: harness.session
        )
        let registration = await harness.session.registerContentProducer(
            request: request,
            productAdmission: harness.productAdmission.context
        ) { lease in await operation(lease) }
        let lease = try bridgeProductAcceptedLease(registration)
        let decoder = try BridgeProductContentFrameDecoder()
        let openingResult = await harness.session.pullProducerFrame(
            for: lease,
            productAdmission: harness.productAdmission.context
        )
        let openingDelivery: BridgeProductProducerFrameDelivery
        switch openingResult {
        case .frame(let delivery):
            openingDelivery = delivery
        case .cancelled, .finished, .rejected:
            throw TestError.expectedFrame
        }
        #expect(
            await harness.session.acknowledgeProducerFrameConsumed(
                openingDelivery.receipt,
                productAdmission: harness.productAdmission.context
            ))
        let opening = try #require(
            decoder.append(openingDelivery.frame.data).first
        )
        #expect(
            await harness.session.acknowledgeContentFrameObservation(
                try contentFrameAcknowledgement(
                    for: request.admission,
                    contentSequence: openingDelivery.frame.sequence
                ),
                productAdmission: harness.productAdmission.context
            )
        )
        #expect(opening.header.kind == "content.accepted")
        return try await consumeContentFrames(
            request: request,
            lease: lease,
            decoder: decoder,
            harness: harness
        )
    }

    private func consumeContentFrames(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        decoder: BridgeProductContentFrameDecoder,
        harness: BridgeProductSessionLifecycleHarness
    ) async throws -> ContentResult {
        var body = Data()
        while true {
            let delivery = try await nextFrame(for: lease, in: harness)
            let frame = try #require(
                decoder.append(delivery.frame.data).first
            )
            switch frame.header {
            case .data:
                let observed = await harness.session.acknowledgeContentFrameObservation(
                    try contentFrameAcknowledgement(
                        for: request.admission,
                        contentSequence: delivery.frame.sequence
                    ),
                    productAdmission: harness.productAdmission.context
                )
                #expect(observed)
                body.append(frame.payload)
            case .end(let header):
                try await harness.closeProducer(lease)
                #expect((await harness.session.producerSnapshot()).hasZeroResidue)
                return ContentResult(
                    accepted: true,
                    body: body,
                    errorCode: nil,
                    errorMessage: nil,
                    observedByteLength: header.observedByteLength,
                    observedSha256: header.observedSha256,
                    retryable: nil
                )
            case .error(let header):
                try await harness.closeProducer(lease)
                #expect((await harness.session.producerSnapshot()).hasZeroResidue)
                return ContentResult(
                    accepted: true,
                    body: body,
                    errorCode: header.code,
                    errorMessage: header.safeMessage,
                    observedByteLength: nil,
                    observedSha256: nil,
                    retryable: header.retryable
                )
            case .accepted, .reset:
                Issue.record("Unexpected non-terminal comparison content frame")
            }
        }
    }

    private func nextFrame(
        for lease: BridgeProductProducerLease,
        in harness: BridgeProductSessionLifecycleHarness
    ) async throws -> BridgeProductProducerFrameDelivery {
        try await nextFrame(
            for: lease,
            from: harness.session,
            productAdmission: harness.productAdmission.context
        )
    }

    func nextFrame(
        for lease: BridgeProductProducerLease,
        from session: BridgeProductSession,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeProductProducerFrameDelivery {
        let result = await session.pullProducerFrame(
            for: lease,
            productAdmission: productAdmission
        )
        guard case .frame(let delivery) = result else {
            throw TestError.expectedFrame
        }
        #expect(
            await session.acknowledgeProducerFrameConsumed(
                delivery.receipt,
                productAdmission: productAdmission
            ))
        return delivery
    }

    func contentFrameAcknowledgement(
        for admission: BridgeProductContentAdmission,
        contentSequence: Int
    ) throws -> BridgeProductContentFrameAcknowledgement {
        let data = try JSONSerialization.data(withJSONObject: [
            "contentRequestId": admission.contentRequestId,
            "receivedThroughContentSequence": contentSequence,
            "kind": "content.acknowledge",
            "leaseId": admission.leaseId,
            "paneSessionId": admission.paneSessionId,
            "wireVersion": admission.wireVersion,
            "workerInstanceId": admission.workerInstanceId,
        ])
        return try BridgeProductStrictJSON.decode(
            BridgeProductContentFrameAcknowledgement.self,
            from: data
        )
    }

    private enum TestError: Error {
        case expectedFrame
    }
}
