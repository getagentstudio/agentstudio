import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product scheme control completion effects")
struct BridgeProductSchemeControlCompletionEffectsTests {
    @Test("annotation commands mutate only after committed completion and only once")
    func annotationCommandMutationRequiresCommittedCompletion() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let recorder = await MainActor.run { BridgeProductCallMutationRecorder() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            applyWorktreeAnnotationCommand: { request, surface, correlation, _ in
                recorder.record(
                    request.operation,
                    surface: surface,
                    requestID: correlation.requestId
                )
                return BridgeProductWorktreeAnnotationCommandOutcomeDTO(
                    .init(
                        requestID: correlation.requestId,
                        surface: surface,
                        sessionID: nil,
                        status: .committed
                    )
                )
            },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let callBody = bridgeProductCompletionEffectsAnnotationDiscoverBody()
        let decodedCall = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: callBody
        )

        // Act
        _ = await provider.response(for: decodedCall)
        let callsBeforeCommit = await recorder.annotationCalls
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let commandResult = try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        _ = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )

        // Assert
        guard let responseValue = commandResult.result,
            case .callCompleted(let completedResponse) = try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: JSONEncoder().encode(responseValue)
            ),
            case .fileAnnotationsCommand(.completed(let outcome)) = completedResponse.call
        else {
            Issue.record("Expected exact annotation command completion")
            return
        }
        #expect(outcome.status == .committed)
        #expect(callsBeforeCommit.isEmpty)
        #expect(await recorder.annotationCalls.count == 1)
        #expect(await recorder.annotationCalls.first?.surface == .file)
        #expect(await recorder.annotationCalls.first?.operation == .discoverSessions)
        #expect(await recorder.annotationCalls.first?.requestID == "annotation-discover-1")
    }

    @Test("product call mutates only after committed completion and only once")
    func productCallMutationRequiresCommittedCompletion() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let recorder = await MainActor.run { BridgeProductCallMutationRecorder() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { itemId, _ in
                recorder.record(itemId)
            },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let callBody = bridgeProductCompletionEffectsMarkViewedBody()
        let decodedCall = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: callBody
        )

        // Act
        _ = await provider.response(for: decodedCall)
        let countAfterProviderResponse = await recorder.count
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        _ = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        let countAfterCommitAndReplay = await recorder.count
        let revocation = await session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
        _ = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )

        // Assert
        #expect(countAfterProviderResponse == 0)
        #expect(countAfterCommitAndReplay == 1)
        #expect(await recorder.count == 1)
        #expect(await recorder.itemIds == ["item-1"])
    }

    @Test("exact Review publication application mutates only after committed completion")
    func reviewPublicationApplicationRequiresCommittedCompletion() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let recorder = await MainActor.run { BridgeProductCallMutationRecorder() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            recordReviewPublicationApplication: { publicationId, correlation, _ in
                #expect(correlation.workerInstanceId == bridgeProductTestWorkerInstanceId)
                recorder.record(publicationId)
                return .advanced
            },
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let callBody = bridgeProductCompletionEffectsPublicationAppliedBody()
        let decodedCall = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: callBody
        )

        // Act
        let response = await provider.response(for: decodedCall)
        let idsAfterProviderResponse = await recorder.publicationIds
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        _ = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )

        // Assert
        guard case .callCompleted(let completed) = response,
            completed.call == .reviewPublicationApplied
        else {
            Issue.record("Expected a typed Review publication application completion")
            return
        }
        #expect(idsAfterProviderResponse.isEmpty)
        #expect(
            await recorder.publicationIds
                == [UUID(uuidString: "11111111-1111-7111-8111-111111111111")!]
        )
    }

    @Test("Review publication install admission settles once and replays its admission receipt")
    func reviewPublicationInstallAdmissionReturnsExactResponseWithoutReplay() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let recorder = await MainActor.run { BridgeProductCallMutationRecorder() }
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            admitReviewPublicationInstallation: { request, correlation, _ in
                #expect(correlation.workerInstanceId == bridgeProductTestWorkerInstanceId)
                recorder.record(request)
                return .admitted
            },
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let callBody = bridgeProductCompletionEffectsPublicationInstallAdmissionBody()
        let decodedCall = try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: callBody
        )

        // Act
        let responseWithoutAdmission = await provider.response(for: decodedCall)
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let firstResult = try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )
        let replayDispatch = try await dispatcher.dispatch(
            exactRequestBytes: callBody,
            presentedCapability: capabilityHeader
        )

        // Assert
        guard case .callCompleted(let completionWithoutAdmission) = responseWithoutAdmission,
            case .reviewPublicationInstallAdmission(let rejectedResult) = completionWithoutAdmission.call
        else {
            Issue.record("Expected a typed rejected Review install-admission response")
            return
        }
        #expect(rejectedResult.status == .rejected)
        #expect(firstResult.outcome == .succeeded)
        guard case .response(let replayBytes) = replayDispatch else {
            Issue.record("Expected exact operation admission replay")
            return
        }
        let replayAdmission = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: replayBytes
        )
        #expect(replayAdmission.operationId == firstResult.operationId)
        #expect(await recorder.admissionRequests.count == 1)
        let recordedRequest = try #require(await recorder.admissionRequests.first)
        #expect(
            recordedRequest.expectedDisplayedPublicationId
                == UUID(uuidString: "11111111-1111-7111-8111-111111111111")
        )
        #expect(
            recordedRequest.candidatePublicationId
                == UUID(uuidString: "22222222-2222-7222-8222-222222222222")
        )
    }

    @Test("committed effects reach the provider after mutation and only once across replay")
    func committedEffectsAreDeliveredAfterSessionMutation() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let provider = BridgeProductCompletionEffectsRecordingProvider(session: session)
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let subscriptionOpenBody = bridgeProductCompletionEffectsSubscriptionOpenBody()
        let subscriptionCancelBody = bridgeProductCompletionEffectsSubscriptionCancelBody()

        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let metadataStream = try await installCompletionEffectsMetadataStream(
            in: session,
            productAdmission: productAdmission
        )
        defer { metadataStream.operation.release() }
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: subscriptionOpenBody,
            presentedCapability: capabilityHeader
        )

        // Act
        _ = try await dispatcher.dispatch(
            exactRequestBytes: subscriptionCancelBody,
            presentedCapability: capabilityHeader
        )
        await session.waitForOutstandingEscapeEffects()
        _ = try await dispatcher.dispatch(
            exactRequestBytes: subscriptionCancelBody,
            presentedCapability: capabilityHeader
        )
        let observations = await provider.completionEffectObservations

        // Assert
        let observation = try #require(observations.first)
        #expect(observations.count == 1)
        #expect(observation.cancelledSubscriptionId == bridgeProductCompletionEffectsSubscriptionId)
        #expect(!observation.cancelledSubscriptionWasStillRegistered)
        #expect(observation.nextExpectedRequestSequence == 4)
    }

    @Test("a rejected candidate mutation never publishes completion effects")
    func rejectedCandidateMutationDoesNotPublishEffects() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let provider = BridgeProductCompletionEffectsRecordingProvider(
            session: session,
            mismatchedSubscriptionOpenResponse: true
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )

        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )

        // Act
        let result = try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductCompletionEffectsSubscriptionOpenBody(),
            presentedCapability: capabilityHeader
        )

        // Assert
        #expect(result.outcome == .failed)
        #expect(await provider.completionEffectObservations.isEmpty)
        #expect(
            await session.subscriptionSnapshot(
                subscriptionId: bridgeProductCompletionEffectsSubscriptionId
            ) == nil
        )
        let finalSnapshot = await session.snapshot
        #expect((await session.diagnosticSnapshot).activeOperationExecutionCount == 0)
        #expect(finalSnapshot.controlReplay.inFlightRequestSequence == nil)
        #expect(finalSnapshot.controlReplay.replayableRequestSequence == 2)
    }

    @Test("pane provider rejects subscription open until metadata stream is installed")
    func paneProviderRequiresMetadataStreamBeforeSubscriptionOpen() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )

        // Act
        let result = try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductCompletionEffectsSubscriptionOpenBody(),
            presentedCapability: capabilityHeader
        )

        // Assert
        #expect(result.outcome == .refused)
        #expect(result.failureCode == .resyncRequired)
        #expect(
            await session.subscriptionSnapshot(
                subscriptionId: bridgeProductCompletionEffectsSubscriptionId
            ) == nil
        )
        #expect((await session.snapshot).controlReplay.nextExpectedRequestSequence == 3)
    }

    @Test("forced lifecycle admission failure caches only a typed error and no mutation")
    func lifecycleAdmissionFailureCannotCacheAcceptedResponse() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let provider = BridgeProductCompletionEffectsRecordingProvider(session: session)
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        let openBody = bridgeProductCompletionEffectsSubscriptionOpenBody()
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )

        // Act
        let firstResult = try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: openBody,
            presentedCapability: capabilityHeader
        )
        let replayResult = try await dispatcher.dispatch(
            exactRequestBytes: openBody,
            presentedCapability: capabilityHeader
        )

        // Assert
        guard case .response(let replayBytes) = replayResult
        else {
            Issue.record("Expected a replayable operation admission")
            return
        }
        let replayAdmission = try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: replayBytes
        )
        #expect(firstResult.outcome == .failed)
        #expect(firstResult.operationId == replayAdmission.operationId)
        #expect(
            await session.subscriptionSnapshot(
                subscriptionId: bridgeProductCompletionEffectsSubscriptionId
            ) == nil
        )
        #expect((await session.snapshot).controlReplay.replayableRequestSequence == 2)
        #expect(await provider.completionEffectObservations.isEmpty)
    }

    @Test("revocation settles while a committed escape effect is held")
    func revocationDoesNotWaitForCommittedEscapeEffect() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let committedEffectsGate = BridgeProductCommittedEffectsGate()
        let provider = BridgeProductCompletionEffectsRecordingProvider(
            session: session,
            committedEffectsGate: committedEffectsGate
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make().context
        let dispatcher = makeBridgeProductSchemeControlDispatcher(
            session: session,
            provider: provider,
            productAdmission: productAdmission
        )
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        let metadataStream = try await installCompletionEffectsMetadataStream(
            in: session,
            productAdmission: productAdmission
        )
        try await dispatchCompletionEffectsOperation(
            dispatcher: dispatcher,
            session: session,
            exactRequestBytes: bridgeProductCompletionEffectsSubscriptionOpenBody(),
            presentedCapability: capabilityHeader
        )
        let cancelDispatch = Task {
            try await dispatcher.dispatch(
                exactRequestBytes: bridgeProductCompletionEffectsSubscriptionCancelBody(),
                presentedCapability: capabilityHeader
            )
        }
        await committedEffectsGate.waitUntilStarted()
        metadataStream.operation.release()

        // Act
        let revocationBarrier = await session.revoke(acknowledgeLifecycle: { _ in true })
        let whileEffectsAreBlocked = await session.snapshot
        let blockedEffectCount = await session.diagnosticSnapshot.activeEscapeEffectCount
        let revocationResultBeforeEffectsFinished = await revocationBarrier.wait()

        cancelDispatch.cancel()
        await committedEffectsGate.release()
        let cancelledCallerResult = try await cancelDispatch.value
        await session.waitForOutstandingEscapeEffects()
        let afterEffectsFinished = await session.snapshot

        // Assert
        #expect(whileEffectsAreBlocked.lifecycle == .revoked)
        #expect(blockedEffectCount == 1)
        #expect(revocationResultBeforeEffectsFinished)
        guard case .response = cancelledCallerResult else {
            Issue.record("Expected claimed dispatch to finish after caller cancellation")
            return
        }
        #expect((await session.diagnosticSnapshot).activeEscapeEffectCount == 0)
        #expect(afterEffectsFinished.controlReplay.inFlightRequestSequence == nil)
    }

    @Test("claimed open cleanup cannot resurrect a revoked session")
    func claimedOpenCleanupPreservesRevocation() async throws {
        // Arrange
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes)
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes, deadlineClock: TestPushClock()
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make()
        let admission = await productAdmission.beginControl(
            in: session,
            exactRequestBytes: bridgeProductSchemeWorkerOpenBody(),
            presentedCapability: capabilityHeader
        )
        guard case .execute(let token, _) = admission else {
            Issue.record("Expected worker open execution admission")
            return
        }
        #expect(await session.admitControlProviderExecution(token: token))

        // Act
        let revocationBarrier = await session.revoke(acknowledgeLifecycle: { _ in true })
        await session.settleControlProviderDispatch(token: token)
        let didRevoke = await revocationBarrier.wait()

        // Assert
        #expect(didRevoke)
        #expect((await session.snapshot).lifecycle == .revoked)
        #expect(!(await session.authorizes(presentedCapability: capabilityHeader)))
    }
}

private func installCompletionEffectsMetadataStream(
    in session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async throws -> (lease: BridgeProductProducerLease, operation: HeldStep<BridgeProductProducerLease>) {
    let operation = HeldStep<BridgeProductProducerLease>("operation")
    let request = try bridgeProductMetadataStreamRequest(
        metadataStreamId: "metadata-completion-effects-\(UUID().uuidString)",
        resumeFromStreamSequence: nil
    )
    let registration = await session.registerMetadataProducer(
        request: request,
        productAdmission: productAdmission
    ) { lease in
        try? await operation.arrive(lease)
    }
    guard case .accepted(let lease) = registration else {
        throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
    }
    _ = try await operation.firstArrival()
    _ = try await session.enqueueRequiredProducerOpeningFrame(
        for: lease,
        productAdmission: productAdmission,
        build: { sequence in
            try producerRegistryMetadataOpeningFrame(for: request, sequence: sequence)
        }
    )
    return (lease, operation)
}

@MainActor
private final class BridgeProductCallMutationRecorder {
    struct AnnotationCall: Equatable {
        let operation: BridgeProductWorktreeAnnotationOperation
        let surface: BridgeProductSurface
        let requestID: String
    }

    private(set) var annotationCalls: [AnnotationCall] = []
    private(set) var admissionRequests: [BridgeProductReviewInstallAdmissionRequest] = []
    private(set) var itemIds: [String] = []
    private(set) var publicationIds: [UUID] = []
    var count: Int { itemIds.count }

    func record(_ itemId: String) {
        itemIds.append(itemId)
    }

    func record(_ publicationId: UUID) {
        publicationIds.append(publicationId)
    }

    func record(_ request: BridgeProductReviewInstallAdmissionRequest) {
        admissionRequests.append(request)
    }

    func record(
        _ operation: BridgeProductWorktreeAnnotationOperation,
        surface: BridgeProductSurface,
        requestID: String
    ) {
        annotationCalls.append(
            AnnotationCall(operation: operation, surface: surface, requestID: requestID)
        )
    }
}

private func bridgeProductCompletionEffectsAnnotationDiscoverBody() -> Data {
    Data(
        """
        {
          "call": {
            "method": "file.annotations.command",
            "request": { "operation": { "kind": "session.discover" } }
          },
          "kind": "product.call",
          "paneSessionId": "\(bridgeProductTestPaneSessionId)",
          "requestId": "annotation-discover-1",
          "requestSequence": 2,
          "wireVersion": 2,
          "workerDerivationEpoch": 0,
          "workerInstanceId": "\(bridgeProductTestWorkerInstanceId)"
        }
        """.utf8
    )
}

private func bridgeProductCompletionEffectsPublicationAppliedBody() -> Data {
    Data(
        """
        {
          "call": {
            "method": "review.publication.applied",
            "request": { "publicationId": "11111111-1111-7111-8111-111111111111" }
          },
          "kind": "product.call",
          "paneSessionId": "\(bridgeProductTestPaneSessionId)",
          "requestId": "review-publication-applied-1",
          "requestSequence": 2,
          "wireVersion": 2,
          "workerDerivationEpoch": 0,
          "workerInstanceId": "\(bridgeProductTestWorkerInstanceId)"
        }
        """.utf8
    )
}

private func bridgeProductCompletionEffectsPublicationInstallAdmissionBody() -> Data {
    Data(
        """
        {
          "call": {
            "method": "review.publication.install.admit",
            "request": {
              "candidatePublicationId": "22222222-2222-7222-8222-222222222222",
              "expectedDisplayedPublicationId": "11111111-1111-7111-8111-111111111111"
            }
          },
          "kind": "product.call",
          "paneSessionId": "\(bridgeProductTestPaneSessionId)",
          "requestId": "review-publication-install-admit-1",
          "requestSequence": 2,
          "wireVersion": 2,
          "workerDerivationEpoch": 0,
          "workerInstanceId": "\(bridgeProductTestWorkerInstanceId)"
        }
        """.utf8
    )
}

private func bridgeProductCompletionEffectsMarkViewedBody() -> Data {
    Data(
        """
        {
          "call": {
            "method": "review.markFileViewed",
            "request": { "itemId": "item-1" }
          },
          "kind": "product.call",
          "paneSessionId": "\(bridgeProductTestPaneSessionId)",
          "requestId": "mark-viewed-1",
          "requestSequence": 2,
          "wireVersion": 2,
          "workerDerivationEpoch": 0,
          "workerInstanceId": "\(bridgeProductTestWorkerInstanceId)"
        }
        """.utf8
    )
}

private let bridgeProductCompletionEffectsSubscriptionId = "review-subscription-effects-1"
private struct BridgeProductCompletionEffectsObservation: Equatable, Sendable {
    let cancelledSubscriptionId: String?
    let cancelledSubscriptionWasStillRegistered: Bool
    let nextExpectedRequestSequence: Int
}

private actor BridgeProductCompletionEffectsRecordingProvider: BridgeProductSchemeProvider {
    private let committedEffectsGate: BridgeProductCommittedEffectsGate?
    private let session: BridgeProductSession
    private let mismatchedSubscriptionOpenResponse: Bool
    private(set) var completionEffectObservations: [BridgeProductCompletionEffectsObservation] = []

    init(
        session: BridgeProductSession,
        mismatchedSubscriptionOpenResponse: Bool = false,
        committedEffectsGate: BridgeProductCommittedEffectsGate? = nil
    ) {
        self.committedEffectsGate = committedEffectsGate
        self.session = session
        self.mismatchedSubscriptionOpenResponse = mismatchedSubscriptionOpenResponse
    }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission _: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        do {
            switch request {
            case .workerSessionOpen:
                return try .workerSessionAccepted(correlating: request)
            case .subscriptionOpen(let openRequest):
                if mismatchedSubscriptionOpenResponse {
                    return try .subscriptionOpenAccepted(
                        .init(
                            correlation: request.correlation,
                            subscriptionId: "other-subscription",
                            subscriptionKind: openRequest.subscription.subscriptionKind,
                            worktreeId: nil
                        )
                    )
                }
                return try .subscriptionOpenAccepted(
                    correlating: request,
                    worktreeId: nil
                )
            case .subscriptionCancel:
                return try .subscriptionCancelAccepted(correlating: request)
            case .productCall, .viewScope, .viewResnapshot,
                .workerSessionResync:
                preconditionFailure("Unexpected completion-effects control request")
            }
        } catch {
            preconditionFailure("Could not build completion-effects control response")
        }
    }

    func applyCommittedControlEffect(
        _ effect: BridgeProductSessionCompletionEffect,
        for request: BridgeProductControlRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async {
        _ = (request, productAdmission)
        guard case .subscriptionCancelled(let cancelledSubscription) = effect else { return }
        await committedEffectsGate?.waitForReleaseAfterStarting()
        let cancelledSubscriptionId = cancelledSubscription.subscriptionId
        let cancelledSubscriptionWasStillRegistered =
            await session.subscriptionSnapshot(subscriptionId: cancelledSubscriptionId) != nil
        completionEffectObservations.append(
            .init(
                cancelledSubscriptionId: cancelledSubscriptionId,
                cancelledSubscriptionWasStillRegistered: cancelledSubscriptionWasStillRegistered,
                nextExpectedRequestSequence: await session.snapshot.controlReplay.nextExpectedRequestSequence
            )
        )
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        _ = (request, lease, productAdmission, session)
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        _ = (request, lease, productAdmission, session)
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        _ = acknowledgement
        return true
    }
}

private actor BridgeProductCommittedEffectsGate {
    private var didRelease = false
    private var didStart = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func waitForReleaseAfterStarting() async {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        if didRelease { return }
        await withCheckedContinuation { continuation in
            precondition(releaseContinuation == nil)
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            precondition(startContinuation == nil)
            startContinuation = continuation
        }
    }

    func release() {
        guard !didRelease else { return }
        didRelease = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

func makeBridgeProductSchemeControlDispatcher(
    session: BridgeProductSession,
    provider: any BridgeProductSchemeProvider,
    productAdmission: BridgeProductAdmissionContext
) -> BridgeProductSchemeControlDispatcher {
    BridgeProductSchemeControlDispatcher(
        session: session,
        provider: provider,
        productAdmission: productAdmission
    )
}

@discardableResult
private func dispatchCompletionEffectsOperation(
    dispatcher: BridgeProductSchemeControlDispatcher,
    session: BridgeProductSession,
    exactRequestBytes: Data,
    presentedCapability: String
) async throws -> BridgeProductOperationResultResponse {
    let dispatch = try await dispatcher.dispatch(
        exactRequestBytes: exactRequestBytes,
        presentedCapability: presentedCapability
    )
    guard case .response(let responseBytes) = dispatch else {
        Issue.record("Expected a Bridge product operation admission")
        throw BridgeProductSessionError.invalidControlResponse
    }
    let admitted = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: responseBytes
    )
    await session.waitForOperationExecution(operationId: admitted.operationId)
    return try #require(
        await session.operationTable.entriesById[admitted.operationId]?.settlement
    )
}

private func bridgeProductCompletionEffectsSubscriptionOpenBody() -> Data {
    Data(
        """
        {
          "kind":"subscription.open",
          "wireVersion":2,
          "paneSessionId":"\(bridgeProductTestPaneSessionId)",
          "workerDerivationEpoch":1,
          "workerInstanceId":"\(bridgeProductTestWorkerInstanceId)",
          "requestId":"request-review-subscription-effects-open-1",
          "requestSequence":2,
          "subscriptionId":"\(bridgeProductCompletionEffectsSubscriptionId)",
          "subscription":{"subscriptionKind":"review.metadata"}
        }
        """.utf8
    )
}

private func bridgeProductCompletionEffectsSubscriptionCancelBody() -> Data {
    Data(
        """
        {
          "kind":"subscription.cancel",
          "wireVersion":2,
          "paneSessionId":"\(bridgeProductTestPaneSessionId)",
          "workerDerivationEpoch":1,
          "workerInstanceId":"\(bridgeProductTestWorkerInstanceId)",
          "requestId":"request-review-subscription-effects-cancel-1",
          "requestSequence":3,
          "subscriptionId":"\(bridgeProductCompletionEffectsSubscriptionId)",
          "subscriptionKind":"review.metadata"
        }
        """.utf8
    )
}
