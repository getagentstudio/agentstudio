import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

/// A silent provider must not hold admission for independent operations.
@Suite("Bridge product session held-provider recovery (S13)")
struct BridgeProductHeldProviderStallTests {
    @Test("unknown mutation remains watched through a still-unknown observation and late success")
    func unknownMutationPublishesLateOutcomeWithoutSecondSettlement() async throws {
        let harness = try HeldProviderSessionHarness.make()
        try await harness.open()
        await harness.provider.holdNextProductCall()
        let admission = try await harness.admit(bridgeProductSchemeReviewCallBody(requestSequence: 3))
        #expect(try await harness.provider.waitUntilProductCallStarted(count: 1) == 1)

        let resultTask = Task { try await harness.result(operationId: admission.operationId) }
        await harness.clock.waitForPendingSleepCount(atLeast: 1)
        harness.clock.advance(by: AppPolicies.Bridge.productOperationSettlementDeadline)
        #expect(try await resultTask.value.outcome == .outcomeUnknown)
        try await harness.acknowledge(operationId: admission.operationId, requestSequence: 4)

        let firstObservation = Task { try await harness.observe(operationId: admission.operationId, after: 1) }
        await harness.clock.waitForPendingSleepCount(atLeast: 1)
        harness.clock.advance(by: AppPolicies.Bridge.productMutationObservationDeadline)
        guard case .stillUnknown(_, let revision) = try await firstObservation.value else {
            Issue.record("Expected observation deadline to report stillUnknown")
            return
        }
        #expect(revision == 1)

        let secondObservation = Task { try await harness.observe(operationId: admission.operationId, after: 1) }
        await harness.clock.waitForPendingSleepCount(atLeast: 1)
        await harness.provider.releaseHeldProductCall()
        await harness.session.waitForOperationExecution(operationId: admission.operationId)
        guard case .lateOutcome(let late) = try await secondObservation.value else {
            Issue.record("Expected late outcome evidence after provider release")
            return
        }
        #expect(late.revision == 2)
        #expect(late.outcome == .succeeded)
        try await harness.acknowledgeLate(operationId: admission.operationId, requestSequence: 5)
        #expect((await harness.session.operationTable.mutationWatchesById).isEmpty)
        #expect((await harness.session.diagnosticSnapshot).mutationWatchCount == 0)
        #expect((await harness.session.diagnosticSnapshot).observationWaiterCount == 0)
    }

    @Test("cancelling a pending scheme result read preserves its later settlement")
    func cancelledSchemeResultReadPreservesSettlement() async throws {
        let (registrations, registrationContinuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .unbounded
        )
        defer { registrationContinuation.finish() }
        let harness = try HeldProviderSessionHarness.make(
            onResultWaiterRegistered: { operationId in
                registrationContinuation.yield(operationId)
            }
        )
        try await harness.open()
        await harness.provider.holdNextProductCall()
        let admission = try await harness.admit(bridgeProductSchemeReviewCallBody(requestSequence: 3))
        #expect(try await harness.provider.waitUntilProductCallStarted(count: 1) == 1)

        let pendingReply = bridgeProductSchemeReplyWithRoutingTask(
            adapter: harness.adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: harness.capabilityHeader,
                body: try harness.resultRequestBody(operationId: admission.operationId)
            )
        )
        let reader = Task {
            for try await _ in pendingReply.stream {}
        }
        var registrationIterator = registrations.makeAsyncIterator()
        var observedRegistration: String?
        while let registration = await registrationIterator.next() {
            observedRegistration = registration
            if registration == admission.operationId { break }
        }
        #expect(observedRegistration == admission.operationId)
        reader.cancel()
        _ = try? await reader.value
        await pendingReply.routingTask.value
        #expect(
            await harness.session.operationTable.entriesById[admission.operationId]?
                .resultWaiters.isEmpty == true
        )

        await harness.provider.releaseHeldProductCall()
        await harness.session.waitForOperationExecution(operationId: admission.operationId)
        #expect(try await harness.result(operationId: admission.operationId).outcome == .succeeded)
        try await harness.acknowledge(operationId: admission.operationId, requestSequence: 4)
        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
    }

    @Test("a held provider permits the next control to be admitted")
    func heldProviderCallPermitsIndependentAdmission() async throws {
        let harness = try HeldProviderSessionHarness.make()
        try await harness.open()
        await harness.provider.holdNextProductCall()
        let heldAdmission = try await harness.admit(
            bridgeProductSchemeReviewCallBody(requestSequence: 3)
        )
        let firstStartedCount = try await harness.provider.waitUntilProductCallStarted(count: 1)
        #expect(firstStartedCount == 1)

        let secondAdmission = try await harness.admit(
            bridgeProductSchemeReviewCallBody(requestSequence: 4)
        )
        let secondResult = try await harness.result(operationId: secondAdmission.operationId)
        #expect(secondResult.outcome == .succeeded)
        try await harness.acknowledge(operationId: secondAdmission.operationId, requestSequence: 5)

        let heldResult = Task {
            try await harness.result(operationId: heldAdmission.operationId)
        }
        await harness.clock.waitForPendingSleepCount(atLeast: 1)
        #expect(harness.clock.pendingSleepCount >= 1)
        harness.clock.advance(by: AppPolicies.Bridge.productOperationSettlementDeadline)
        #expect(try await heldResult.value.outcome == .outcomeUnknown)

        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
        #expect((await harness.session.snapshot).lifecycle == .revoked)

        await harness.provider.releaseHeldProductCall()
        await harness.session.waitForOperationExecution(operationId: heldAdmission.operationId)
        #expect((await harness.session.diagnosticSnapshot).activeOperationExecutionCount == 0)
        #expect((await harness.session.diagnosticSnapshot).retainedOperationResultCount == 0)
    }

    @Test("a full ordinary result table cannot block subscription cancellation")
    func fullResultTablePermitsCancellation() async throws {
        let harness = try HeldProviderSessionHarness.make()
        try await harness.open()
        let metadataHold = try await harness.installMetadataStream()
        defer { metadataHold.release() }
        let subscriptionId = "subscription-s13-capacity"
        let openAdmission = try await harness.admit(
            s13SubscriptionOpenBody(subscriptionId: subscriptionId, requestSequence: 3)
        )
        #expect(try await harness.result(operationId: openAdmission.operationId).outcome == .succeeded)
        try await harness.acknowledge(operationId: openAdmission.operationId, requestSequence: 4)

        for requestSequence in 5..<(5 + AppPolicies.Bridge.maximumOrdinaryProductOperations) {
            _ = try await harness.admit(bridgeProductSchemeReviewCallBody(requestSequence: requestSequence))
        }
        let cancelSequence = 5 + AppPolicies.Bridge.maximumOrdinaryProductOperations
        let refused = try await harness.send(
            bridgeProductSchemeReviewCallBody(requestSequence: cancelSequence)
        )
        guard
            case .requestError(let error) = try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: refused.body
            )
        else {
            Issue.record("Expected typed capacity refusal before cancellation")
            return
        }
        #expect(error.code == .resultCapacityExhausted)

        let cancelReply = try await harness.send(
            s13SubscriptionCancelBody(subscriptionId: subscriptionId, requestSequence: cancelSequence)
        )
        guard
            case .subscriptionCancelAccepted = try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: cancelReply.body
            )
        else {
            Issue.record("Expected a slot-free cancellation reply")
            return
        }
        #expect(await harness.session.subscriptionSnapshot(subscriptionId: subscriptionId) == nil)
        metadataHold.release()
        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
    }

    @Test("a human-wait operation uses its own pool and has no settlement deadline")
    func humanWaitDoesNotConsumeOrdinaryCapacityOrDeadline() async throws {
        let harness = try HeldProviderSessionHarness.make()
        try await harness.open()
        await harness.provider.holdNextProductCall()

        let humanBody = try s13HumanWaitCallBody(requestSequence: 3)
        let humanAdmission = try await harness.admit(humanBody)
        #expect(humanAdmission.waitKind == .human)
        #expect(try await harness.provider.waitUntilProductCallStarted(count: 1) == 1)

        let ordinaryAdmission = try await harness.admit(
            bridgeProductSchemeReviewCallBody(requestSequence: 4)
        )
        #expect(ordinaryAdmission.waitKind == .ordinary)
        #expect(try await harness.result(operationId: ordinaryAdmission.operationId).outcome == .succeeded)
        try await harness.acknowledge(operationId: ordinaryAdmission.operationId, requestSequence: 5)

        #expect(harness.clock.pendingSleepCount == 0)
        harness.clock.advance(by: AppPolicies.Bridge.productOperationSettlementDeadline)
        #expect(
            await harness.session.operationTable.entriesById[humanAdmission.operationId]?.settlement
                == nil
        )

        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
        #expect((await harness.session.diagnosticSnapshot).retainedOperationResultCount == 0)
        await harness.provider.releaseHeldProductCall()
        await harness.session.waitForOperationExecution(operationId: humanAdmission.operationId)
        #expect((await harness.session.diagnosticSnapshot).activeOperationExecutionCount == 0)
    }

    @Test("a refused operation is retained until its result is acknowledged")
    func refusedResultAcknowledgementReleasesCapacity() async throws {
        let harness = try HeldProviderSessionHarness.make()
        try await harness.open()
        await harness.provider.refuseNextProductCall()

        let admission = try await harness.admit(bridgeProductSchemeReviewCallBody(requestSequence: 3))
        let result = try await harness.result(operationId: admission.operationId)
        #expect(result.outcome == .refused)
        #expect(result.failureCode == .internal)
        #expect((await harness.session.diagnosticSnapshot).retainedOperationResultCount == 1)

        try await harness.acknowledge(operationId: admission.operationId, requestSequence: 4)
        #expect((await harness.session.diagnosticSnapshot).retainedOperationResultCount == 0)
        let nextAdmission = try await harness.admit(
            bridgeProductSchemeReviewCallBody(requestSequence: 5)
        )
        #expect(try await harness.result(operationId: nextAdmission.operationId).outcome == .succeeded)
        try await harness.acknowledge(operationId: nextAdmission.operationId, requestSequence: 6)

        let revocation = await harness.session.revoke(acknowledgeLifecycle: { _ in true })
        #expect(await revocation.wait())
    }

    @Test(
        "page reload and worker replacement serve a successor before the old provider releases",
        arguments: [
            BridgePaneProductSessionRetirementReason.pageReload,
            .workerReplacement,
        ]
    )
    func replacementPrecedesHeldProviderRelease(
        reason: BridgePaneProductSessionRetirementReason
    ) async throws {
        // Arrange
        let log = S13OrderedEventLog()
        let provider = S13HeldProductCallProvider(log: log)
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            didRetireWorkerInstance: { _ in
                await log.record(.workerRetired)
            }
        )
        let productAdmission = try #require(owner.productAdmissionGate.acquire())
        let installation = try await owner.prepareCandidate(productAdmission: productAdmission)
        #expect(
            await owner.activatePreparedCandidate(installation, productAdmission: productAdmission)
                == .activated
        )
        try await openBridgePaneProductSession(installation)
        await provider.holdNextProductCall()
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        let heldCall = Task {
            try await collectBridgeProductSchemeReply(
                adapter: installation.productAdapter,
                request: bridgeProductSchemeRequest(
                    route: BridgeProductWireContract.commandRoute,
                    capability: capabilityHeader,
                    body: s13ProductCallBody(installation: installation, requestSequence: 2)
                )
            )
        }
        let startedCount = try await provider.waitUntilProductCallStarted(count: 1)
        #expect(startedCount == 1)

        // Act
        let retirement = Task { await owner.retire(reason: reason) }
        let invalidationCount = try await log.waitUntilRecorded(.comparisonTargetReservationInvalidated, count: 1)
        #expect(invalidationCount == 1)
        let activeDuringRetirement = await owner.activeInstallation
        let retirementResult = await retirement.value

        // The old installation is fenced, and a successor can open now.
        #expect(activeDuringRetirement == nil)
        #expect(retirementResult == .retired)
        let successor = try await owner.prepareCandidate(productAdmission: productAdmission)
        #expect(
            await owner.activatePreparedCandidate(successor, productAdmission: productAdmission)
                == .activated
        )
        try await openBridgePaneProductSession(successor)
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == successor.bootstrap.workerInstanceId
        )
        #expect(!(await log.events).contains(.providerReleased))

        // Old cleanup completes after its provider answers.
        await log.record(.providerReleased)
        await provider.releaseHeldProductCall()
        _ = try? await heldCall.value
        #expect(await owner.waitForRetirement(of: installation.bootstrap.workerInstanceId))

        let events = await log.events
        let releaseIndex = try #require(events.firstIndex(of: .providerReleased))
        let retiredIndex = try #require(events.firstIndex(of: .workerRetired))
        #expect(releaseIndex < retiredIndex)
        #expect((await installation.session.snapshot).lifecycle == .revoked)
        let oldDiagnostic = await installation.session.diagnosticSnapshot
        #expect(oldDiagnostic.activeOperationExecutionCount == 0)
        #expect(oldDiagnostic.retainedOperationResultCount == 0)
    }
}

private enum S13Event: Equatable, Sendable {
    case comparisonTargetReservationInvalidated
    case providerReleased
    case revocationCompleted
    case workerRetired
}

private actor S13OrderedEventLog {
    private(set) var events: [S13Event] = []
    private let facts = FactRecorder<String, Int>(
        vocabulary: .init(
            describeScope: { $0 }, describeFact: { "event count \($0)" }, isClosing: { _, _ in false }))

    func record(_ event: S13Event) {
        events.append(event)
        facts.append(scope: "\(event)-\(recordedCount(of: event))", fact: recordedCount(of: event))
    }

    func waitUntilRecorded(_ event: S13Event, count: Int) async throws -> Int {
        guard recordedCount(of: event) < count else { return recordedCount(of: event) }
        return try await facts.expectNext(in: "\(event)-\(count)", where: { $0 >= count }, "S13 \(event) recorded")
    }

    private func recordedCount(of event: S13Event) -> Int {
        events.filter { $0 == event }.count
    }
}

private actor S13HeldProductCallProvider: BridgeProductSchemeProvider {
    private let log: S13OrderedEventLog?
    private var heldCallStep: HeldStep<Void>?
    private var holdsNextProductCall = false
    private var refusesNextProductCall = false
    private let starts = FactRecorder<Int, Int>(
        vocabulary: .init(
            describeScope: { "product call \($0)" }, describeFact: { "start \($0)" }, isClosing: { _, _ in false }))
    private(set) var productCallStartCount = 0

    init(log: S13OrderedEventLog? = nil) {
        self.log = log
    }

    func holdNextProductCall() {
        holdsNextProductCall = true
    }

    func refuseNextProductCall() {
        refusesNextProductCall = true
    }

    func waitUntilProductCallStarted(count: Int) async throws -> Int {
        guard productCallStartCount < count else { return productCallStartCount }
        return try await starts.expectNext(in: count, where: { $0 >= count }, "product call started")
    }

    func releaseHeldProductCall() {
        heldCallStep?.release()
        heldCallStep = nil
    }

    func invalidatePendingComparisonTargetReservation() async {
        await log?.record(.comparisonTargetReservationInvalidated)
    }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission _: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        do {
            switch request {
            case .workerSessionOpen:
                return try .workerSessionAccepted(correlating: request)
            case .productCall(let callRequest):
                productCallStartCount += 1
                starts.append(scope: productCallStartCount, fact: productCallStartCount)
                if holdsNextProductCall {
                    holdsNextProductCall = false
                    let step = HeldStep<Void>("silent product call", cancellation: .holdThroughCancellation)
                    heldCallStep = step
                    try await step.arrive(())
                }
                if refusesNextProductCall {
                    refusesNextProductCall = false
                    return try .requestError(
                        correlating: request,
                        code: .internal,
                        nextExpectedRequestSequence: request.requestSequence + 1,
                        retryAfterMilliseconds: nil,
                        retryable: false,
                        safeMessage: nil
                    )
                }
                if case .fileAnnotationsCommand = callRequest.call {
                    return try .requestError(
                        correlating: request,
                        code: .internal,
                        nextExpectedRequestSequence: request.requestSequence + 1,
                        retryAfterMilliseconds: nil,
                        retryable: false,
                        safeMessage: nil
                    )
                }
                return try .callCompleted(correlating: request, result: .reviewMarkFileViewed)
            case .subscriptionOpen(let openRequest):
                let worktreeId: String? =
                    switch openRequest.subscription.subscriptionKind {
                    case .fileAnnotations, .reviewAnnotations: "worktree-1"
                    default: nil
                    }
                return try .subscriptionOpenAccepted(
                    correlating: request,
                    worktreeId: worktreeId
                )
            case .subscriptionCancel:
                return try .subscriptionCancelAccepted(correlating: request)
            case .viewScope, .viewResnapshot, .workerSessionResync:
                preconditionFailure("The S13 provider received an unconfigured control request")
            }
        } catch {
            preconditionFailure("The S13 provider could not build a correlated response")
        }
    }

    func runMetadataProducer(
        request _: BridgeProductMetadataStreamRequest,
        lease _: BridgeProductProducerLease,
        productAdmission _: BridgeProductAdmissionContext,
        session _: BridgeProductSession
    ) async {
        Issue.record("The S13 characterization does not open metadata streams")
    }

    func runContentProducer(
        request _: BridgeProductContentRequest,
        lease _: BridgeProductProducerLease,
        productAdmission _: BridgeProductAdmissionContext,
        session _: BridgeProductSession
    ) async {
        Issue.record("The S13 characterization does not open content")
    }

    func acknowledgeLifecycle(
        _: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        true
    }
}

private struct HeldProviderSessionHarness {
    let adapter: BridgeProductSchemeAdapter
    let capabilityHeader: String
    let clock: TestPushClock
    let provider: S13HeldProductCallProvider
    let session: BridgeProductSession

    static func make(
        onResultWaiterRegistered: (@Sendable (String) -> Void)? = nil
    ) throws -> Self {
        let capabilityBytes = (0..<BridgeProductWireContract.capabilityByteLength).map(UInt8.init)
        let clock = TestPushClock()
        let session = try BridgeProductSession(
            paneSessionId: bridgeProductTestPaneSessionId,
            workerInstanceId: bridgeProductTestWorkerInstanceId,
            capabilityBytes: capabilityBytes,
            deadlineClock: clock,
            resultWaiterRegistrationObserver: onResultWaiterRegistered
        )
        let provider = S13HeldProductCallProvider()
        return try Self(
            adapter: BridgeProductSchemeAdapter(
                session: session,
                provider: provider,
                productAdmissionGate: BridgeProductAdmissionGate(),
                installationAdmissionGate: BridgeProductAdmissionGate()
            ),
            capabilityHeader: BridgeProductCapabilityHeaderEncoding.encode(capabilityBytes),
            clock: clock,
            provider: provider,
            session: session
        )
    }

    func open() async throws {
        let admission = try await admit(bridgeProductSchemeWorkerOpenBody())
        let result = try await result(operationId: admission.operationId)
        #expect(result.outcome == .succeeded)
        try await acknowledge(operationId: admission.operationId, requestSequence: 2)
    }

    func admit(_ body: Data) async throws -> BridgeProductOperationAdmittedResponse {
        let reply = try await send(body)
        #expect(reply.response?.statusCode == 200)
        return try BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: reply.body
        )
    }

    func result(operationId: String) async throws -> BridgeProductOperationResultResponse {
        let reply = try await send(resultRequestBody(operationId: operationId))
        #expect(reply.response?.statusCode == 200)
        return try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultResponse.self,
            from: reply.body
        )
    }

    func resultRequestBody(operationId: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "kind": "operation.result",
                "operationId": operationId,
                "paneSessionId": bridgeProductTestPaneSessionId,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": bridgeProductTestWorkerInstanceId,
            ]
        )
    }

    func acknowledge(operationId: String, requestSequence: Int) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "kind": "operation.resultAcknowledgement",
                "operationId": operationId,
                "paneSessionId": bridgeProductTestPaneSessionId,
                "requestId": "result-ack-\(requestSequence)",
                "requestSequence": requestSequence,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": bridgeProductTestWorkerInstanceId,
            ]
        )
        let reply = try await send(body)
        #expect(reply.response?.statusCode == 200)
        let acknowledged = try BridgeProductStrictJSON.decode(
            BridgeProductOperationResultAcknowledgedResponse.self,
            from: reply.body
        )
        #expect(acknowledged.operationId == operationId)
    }

    func observe(operationId: String, after revision: Int) async throws
        -> BridgeProductOperationObservationResponse
    {
        let body = try JSONSerialization.data(withJSONObject: [
            "kind": "operation.observe",
            "operationId": operationId,
            "after": revision,
            "paneSessionId": bridgeProductTestPaneSessionId,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": bridgeProductTestWorkerInstanceId,
        ])
        let reply = try await send(body)
        #expect(reply.response?.statusCode == 200)
        return try BridgeProductStrictJSON.decode(
            BridgeProductOperationObservationResponse.self,
            from: reply.body
        )
    }

    func acknowledgeLate(operationId: String, requestSequence: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "kind": "operation.lateOutcomeAcknowledgement",
            "operationId": operationId,
            "revision": 2,
            "paneSessionId": bridgeProductTestPaneSessionId,
            "requestId": "late-ack-\(requestSequence)",
            "requestSequence": requestSequence,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": bridgeProductTestWorkerInstanceId,
        ])
        let reply = try await send(body)
        #expect(reply.response?.statusCode == 204)
    }

    func installMetadataStream() async throws -> HeldStep<BridgeProductProducerLease> {
        let heldProducer = HeldStep<BridgeProductProducerLease>("s13MetadataProducer")
        let request = try bridgeProductMetadataStreamRequest(
            metadataStreamId: "metadata-s13-\(UUIDv7.generate().uuidString)",
            resumeFromStreamSequence: nil
        )
        let productAdmission = try #require(adapter.acquireAdmission())
        let registration = await session.registerMetadataProducer(
            request: request,
            productAdmission: productAdmission
        ) { lease in
            try? await heldProducer.arrive(lease)
        }
        guard case .accepted(let lease) = registration else {
            throw BridgeProductSessionError.lifecycleFrameAdmissionFailed
        }
        #expect(try await heldProducer.firstArrival() == lease)
        _ = try await session.enqueueRequiredProducerOpeningFrame(
            for: lease,
            productAdmission: productAdmission,
            build: { sequence in
                try producerRegistryMetadataOpeningFrame(for: request, sequence: sequence)
            }
        )
        return heldProducer
    }

    func send(_ body: Data) async throws -> BridgeProductSchemeReplyObservation {
        try await collectBridgeProductSchemeReply(
            adapter: adapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.commandRoute,
                capability: capabilityHeader,
                body: body
            )
        )
    }
}

private func s13ProductCallBody(
    installation: BridgeProductSessionInstallation,
    requestSequence: Int
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "call": [
                "method": "review.markFileViewed",
                "request": ["itemId": "item-s13-held"],
            ],
            "kind": "product.call",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "requestId": "product-call-s13-held",
            "requestSequence": requestSequence,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 1,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
}

private func s13HumanWaitCallBody(requestSequence: Int) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "call": [
                "method": "file.annotations.command",
                "request": [
                    "operation": [
                        "kind": "output.repeat",
                        "attemptId": UUIDv7.generate().uuidString.lowercased(),
                    ]
                ],
            ],
            "kind": "product.call",
            "paneSessionId": bridgeProductTestPaneSessionId,
            "requestId": "s13-human-wait-\(requestSequence)",
            "requestSequence": requestSequence,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 1,
            "workerInstanceId": bridgeProductTestWorkerInstanceId,
        ],
        options: [.sortedKeys]
    )
}

private func s13SubscriptionOpenBody(subscriptionId: String, requestSequence: Int) -> Data {
    Data(
        """
        {"kind":"subscription.open","wireVersion":2,"paneSessionId":"\(bridgeProductTestPaneSessionId)","workerDerivationEpoch":1,"workerInstanceId":"\(bridgeProductTestWorkerInstanceId)","requestId":"s13-open-\(requestSequence)","requestSequence":\(requestSequence),"subscriptionId":"\(subscriptionId)","subscription":{"subscriptionKind":"review.metadata"}}
        """.utf8
    )
}

private func s13SubscriptionCancelBody(subscriptionId: String, requestSequence: Int) -> Data {
    Data(
        """
        {"kind":"subscription.cancel","wireVersion":2,"paneSessionId":"\(bridgeProductTestPaneSessionId)","workerDerivationEpoch":1,"workerInstanceId":"\(bridgeProductTestWorkerInstanceId)","requestId":"s13-cancel-\(requestSequence)","requestSequence":\(requestSequence),"subscriptionId":"\(subscriptionId)","subscriptionKind":"review.metadata"}
        """.utf8
    )
}
