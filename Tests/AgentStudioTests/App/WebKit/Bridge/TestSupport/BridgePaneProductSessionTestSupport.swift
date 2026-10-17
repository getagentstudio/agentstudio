import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioBridge

func openBridgePaneProductSession(
    _ installation: BridgeProductSessionInstallation
) async throws {
    let requestBody = try JSONSerialization.data(
        withJSONObject: [
            "kind": "workerSession.open",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "request": NSNull(),
            "requestId": "request-open-pane-owner",
            "requestSequence": 1,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
        installation.capabilityBytes
    )
    let observation = try await collectBridgeProductSchemeReply(
        adapter: installation.productAdapter,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: requestBody
        )
    )
    #expect(observation.response?.statusCode == 200)
    // HTTP 200 carries operation admission. Metadata needs the committed open.
    let admitted = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self, from: observation.body)
    let resultReply = try await collectBridgeProductSchemeReply(
        adapter: installation.productAdapter,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: JSONSerialization.data(withJSONObject: [
                "kind": "operation.result", "operationId": admitted.operationId,
                "paneSessionId": installation.bootstrap.paneSessionId,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
                "wireVersion": BridgeProductWireContract.version,
            ])))
    #expect(resultReply.response?.statusCode == 200)
    let result = try BridgeProductStrictJSON.decode(
        BridgeProductOperationResultResponse.self, from: resultReply.body)
    try #require(result.operationId == admitted.operationId)
    try #require(result.outcome == .succeeded)
    let committedResponse = try BridgeProductStrictJSON.decode(
        BridgeProductControlResponse.self, from: JSONEncoder().encode(try #require(result.result)))
    let workerSessionWasAccepted =
        if case .workerSessionAccepted = committedResponse { true } else { false }
    try #require(workerSessionWasAccepted)
}

func openBridgePaneProductSessionThroughRouter(
    installation: BridgeProductSessionInstallation,
    handler: BridgeSchemeHandler
) async throws -> BridgeProductControlResponse {
    let reply = try await collectBridgeSchemeHandlerProductReply(
        handler: handler,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes),
            body: try JSONSerialization.data(withJSONObject: [
                "kind": "workerSession.open",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "request": NSNull(),
                "requestId": "request-open-live-successor",
                "requestSequence": 1,
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ])
        )
    )
    #expect(reply.response?.statusCode == 200)
    return try await readAdmittedBridgeProductControlResponse(
        .response(reply.body),
        installation: installation,
        capabilityHeader: BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes)
    )
}

func assertRetiredPaneProductCommandRefusal(
    installation: BridgeProductSessionInstallation,
    handler: BridgeSchemeHandler
) async throws -> BridgeProductSchemeReplyObservation {
    let router = try #require(handler.productSessionRouter)
    let capability = try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes)
    let requestBody = try JSONSerialization.data(withJSONObject: [
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-retired-pane-owner",
        "requestSequence": 2,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
    let controlBefore = await installation.session.snapshot.controlReplay
    let operationsBefore = await installation.session.diagnosticSnapshot
    // E1 closes the retired adapter; the live router rejects its old capability before body admission.
    let admission = await router.claimActiveAdapter(
        presentedCapability: capability,
        schemeTaskId: UUIDv7.generate(),
        route: .command
    )
    if case .unauthorized = admission {
        // BridgeSchemeHandler+RPC maps this typed refusal to HTTP 403.
    } else {
        Issue.record("Expected the live router to reject the retired capability as unauthorized")
        if case .admitted(let claim) = admission { await claim.finish() }
    }
    let reply = try await collectBridgeSchemeHandlerProductReply(
        handler: handler,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capability,
            body: requestBody
        )
    )
    #expect(reply.response?.statusCode == 403)
    #expect(reply.body.isEmpty)
    #expect(
        (try? BridgeProductStrictJSON.decode(
            BridgeProductOperationAdmittedResponse.self,
            from: reply.body
        )) == nil
    )
    let controlAfter = await installation.session.snapshot.controlReplay
    let operationsAfter = await installation.session.diagnosticSnapshot
    #expect(controlAfter.nextExpectedRequestSequence == controlBefore.nextExpectedRequestSequence)
    #expect(controlAfter.inFlightRequestSequence == controlBefore.inFlightRequestSequence)
    #expect(operationsAfter.retainedOperationResultCount == operationsBefore.retainedOperationResultCount)
    #expect(operationsAfter.activeOperationExecutionCount == operationsBefore.activeOperationExecutionCount)
    return reply
}

func startBridgePaneProductMetadataReply(
    installation: BridgeProductSessionInstallation,
    provider: BridgePaneProductSessionProviderGate,
    handler: BridgeSchemeHandler? = nil
) async throws -> Task<BridgeProductSchemeReplyObservation, any Error> {
    let body = try JSONSerialization.data(
        withJSONObject: [
            "kind": "metadataStream.open",
            "metadataStreamId": "metadata-pane-owner",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "resumeFromStreamSequence": NSNull(),
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
        installation.capabilityBytes
    )
    let replyTask = Task {
        try await collectPaneOwnerProductReply(
            handler: handler,
            adapter: installation.productAdapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.streamRoute,
                capability: capabilityHeader,
                body: body
            )
        )
    }
    try await provider.waitUntilMetadataProducerStarted()
    return replyTask
}

private func collectPaneOwnerProductReply(
    handler: BridgeSchemeHandler?,
    adapter: BridgeProductSchemeAdapter,
    request: URLRequest
) async throws -> BridgeProductSchemeReplyObservation {
    if let handler {
        return try await collectBridgeSchemeHandlerProductReply(
            handler: handler,
            request: request
        )
    }
    return try await collectBridgeProductSchemeReply(
        adapter: adapter,
        request: request
    )
}

private func collectBridgeSchemeHandlerProductReply(
    handler: BridgeSchemeHandler,
    request: URLRequest
) async throws -> BridgeProductSchemeReplyObservation {
    var body = Data()
    var events: [BridgeProductSchemeReplyObservation.Event] = []
    var response: HTTPURLResponse?
    for try await result in handler.reply(for: request) {
        switch result {
        case .response(let emittedResponse):
            events.append(.response)
            response = emittedResponse as? HTTPURLResponse
        case .data(let chunk):
            events.append(.data)
            body.append(chunk)
        @unknown default:
            Issue.record("Unexpected URL scheme task result")
        }
    }
    return .init(body: body, events: events, response: response)
}

actor BridgePaneProductSessionProviderGate: BridgeProductSchemeProvider {
    private let workerRevocation: HeldStep<String>?
    private let workerOpenResponse: HeldStep<Void>?

    init(workerRevocation: HeldStep<String>? = nil, workerOpenResponse: HeldStep<Void>? = nil) {
        self.workerRevocation = workerRevocation
        self.workerOpenResponse = workerOpenResponse
    }

    func revokeWorkerIdentity(_ workerInstanceId: String) async {
        try? await workerRevocation?.arrive(workerInstanceId)
    }

    private enum AcknowledgementMode {
        case fail
        case failOnceThenHold
        case hold
        case succeed
    }

    private var acknowledgementMode = AcknowledgementMode.succeed
    private var acknowledgementWaiters: [CheckedContinuation<Bool, Never>] = []
    private var invocationWaiters: [(Int, CheckedContinuation<BridgeProductProducerLifecycleAcknowledgement, Never>)] =
        []
    private let contentOperation = HeldStep<BridgeProductProducerLease>("contentOperation")
    private let metadataOperation = HeldStep<BridgeProductProducerLease>("metadataOperation")
    private var productCallResponseContinuation: CheckedContinuation<Void, Never>?
    private var productCallStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldHoldProductCallResponses = false
    private(set) var lifecycleAcknowledgements: [BridgeProductProducerLifecycleAcknowledgement] = []
    private(set) var lifecycleAcknowledgementsWereReleased = false

    func response(
        for request: BridgeProductControlRequest,
        productAdmission _: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        do {
            switch request {
            case .workerSessionOpen:
                try await workerOpenResponse?.arrive(())
                return try .workerSessionAccepted(correlating: request)
            case .productCall:
                let waiters = productCallStartWaiters
                productCallStartWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                if shouldHoldProductCallResponses {
                    await withCheckedContinuation { continuation in
                        productCallResponseContinuation = continuation
                    }
                }
                return try .callCompleted(
                    correlating: request,
                    result: .reviewMarkFileViewed
                )
            case .subscriptionOpen, .subscriptionCancel,
                .viewScope, .viewResnapshot,
                .workerSessionResync:
                preconditionFailure("Unexpected pane-owner control request")
            }
        } catch {
            preconditionFailure("Could not build pane-owner control response")
        }
    }

    func runMetadataProducer(
        request: BridgeProductMetadataStreamRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        do {
            _ = try await session.enqueueRequiredProducerOpeningFrame(
                for: lease,
                productAdmission: productAdmission,
                build: { sequence in
                    try bridgeProductMetadataAcceptedFrame(
                        request: request,
                        streamSequence: sequence,
                        resumeDisposition: .snapshotRequired
                    )
                }
            )
            try? await metadataOperation.arrive(lease)
        } catch {
            Issue.record("Metadata producer failed before retirement")
        }
    }

    func runContentProducer(
        request: BridgeProductContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        session: BridgeProductSession
    ) async {
        do {
            _ = try await session.enqueueRequiredProducerOpeningFrame(
                for: lease,
                productAdmission: productAdmission,
                build: { _ in producerRegistryContentOpeningFrame(for: request) }
            )
            try? await contentOperation.arrive(lease)
        } catch {
            Issue.record("Content producer failed before retirement")
        }
    }

    func acknowledgeLifecycle(
        _ acknowledgement: BridgeProductProducerLifecycleAcknowledgement
    ) async -> Bool {
        lifecycleAcknowledgements.append(acknowledgement)
        resumeInvocationWaiters()
        switch acknowledgementMode {
        case .fail:
            return false
        case .failOnceThenHold:
            acknowledgementMode = .hold
            return false
        case .hold:
            return await withCheckedContinuation { continuation in
                acknowledgementWaiters.append(continuation)
            }
        case .succeed:
            return true
        }
    }

    func waitUntilMetadataProducerStarted() async throws {
        _ = try await metadataOperation.firstArrival()
    }

    func waitUntilContentProducerStarted() async throws {
        _ = try await contentOperation.firstArrival()
    }

    func holdProductCallResponses() {
        shouldHoldProductCallResponses = true
    }

    func waitUntilProductCallStarted() async {
        if productCallResponseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            productCallStartWaiters.append(continuation)
        }
    }

    func releaseProductCallResponses() {
        shouldHoldProductCallResponses = false
        productCallResponseContinuation?.resume()
        productCallResponseContinuation = nil
    }

    func holdLifecycleAcknowledgements() {
        acknowledgementMode = .hold
        lifecycleAcknowledgementsWereReleased = false
    }

    func failLifecycleAcknowledgements() {
        acknowledgementMode = .fail
    }

    func failNextLifecycleAcknowledgementThenHoldRetries() {
        acknowledgementMode = .failOnceThenHold
        lifecycleAcknowledgementsWereReleased = false
    }

    func succeedLifecycleAcknowledgements() {
        acknowledgementMode = .succeed
    }

    func releaseLifecycleAcknowledgements(result: Bool) {
        acknowledgementMode = result ? .succeed : .fail
        lifecycleAcknowledgementsWereReleased = true
        let waiters = acknowledgementWaiters
        acknowledgementWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func waitForLifecycleAcknowledgement(
        count: Int
    ) async -> BridgeProductProducerLifecycleAcknowledgement {
        if lifecycleAcknowledgements.count >= count {
            return lifecycleAcknowledgements[count - 1]
        }
        return await withCheckedContinuation { continuation in
            invocationWaiters.append((count, continuation))
        }
    }

    private func resumeInvocationWaiters() {
        let readyWaiters = invocationWaiters.filter { $0.0 <= lifecycleAcknowledgements.count }
        invocationWaiters.removeAll { $0.0 <= lifecycleAcknowledgements.count }
        for (count, waiter) in readyWaiters {
            waiter.resume(returning: lifecycleAcknowledgements[count - 1])
        }
    }
}
