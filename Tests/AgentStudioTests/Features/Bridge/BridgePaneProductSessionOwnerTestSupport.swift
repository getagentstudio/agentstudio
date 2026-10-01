import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

final class BridgePaneProductSessionOwnerFrameWaiterFixture {
    let firstFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>
    let frameWaiterRegistrationCount: Mutex<Int>
    let installation: BridgeProductSessionInstallation
    let owner: BridgePaneProductSessionOwner
    let provider: BridgePaneProductSessionProviderGate
    let secondFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>

    init(
        firstFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>,
        frameWaiterRegistrationCount: Mutex<Int>,
        installation: BridgeProductSessionInstallation,
        owner: BridgePaneProductSessionOwner,
        provider: BridgePaneProductSessionProviderGate,
        secondFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>
    ) {
        self.firstFrameWaiterRegistration = firstFrameWaiterRegistration
        self.frameWaiterRegistrationCount = frameWaiterRegistrationCount
        self.installation = installation
        self.owner = owner
        self.provider = provider
        self.secondFrameWaiterRegistration = secondFrameWaiterRegistration
    }
}

func makeBridgePaneProductSessionOwnerFrameWaiterFixture() throws
    -> BridgePaneProductSessionOwnerFrameWaiterFixture
{
    let provider = BridgePaneProductSessionProviderGate()
    let paneSessionId = bridgeProductTestPaneSessionId
    let workerInstanceId = UUID().uuidString
    let capabilityBytes = Array(
        repeating: UInt8(7),
        count: BridgeProductWireContract.capabilityByteLength
    )
    let productAdmissionGate = BridgeProductAdmissionGate()
    let installationAdmissionGate = BridgeProductAdmissionGate()
    let firstFrameWaiterRegistration = HeldStep<BridgeProductProducerLease>(
        "first producer waits after its opening frame",
        cancellation: .holdThroughCancellation
    )
    let secondFrameWaiterRegistration = HeldStep<BridgeProductProducerLease>(
        "second producer waits after its opening frame",
        cancellation: .holdThroughCancellation
    )
    let frameWaiterRegistrationSteps = [
        firstFrameWaiterRegistration,
        secondFrameWaiterRegistration,
    ]
    let frameWaiterRegistrationCount = Mutex(0)
    let session = try BridgeProductSession(
        paneSessionId: paneSessionId,
        workerInstanceId: workerInstanceId,
        capabilityBytes: capabilityBytes,
        producerFrameWaiterRegistrationObserver: { lease in
            let registrationIndex = frameWaiterRegistrationCount.withLock { count in
                count += 1
                return count
            }
            guard frameWaiterRegistrationSteps.indices.contains(registrationIndex - 1) else {
                return
            }
            let registrationStep = frameWaiterRegistrationSteps[registrationIndex - 1]
            Task { try? await registrationStep.arrive(lease) }
        }
    )
    let installation = BridgeProductSessionInstallation(
        bootstrap: BridgeProductSessionBootstrap(
            paneSessionId: paneSessionId,
            workerInstanceId: workerInstanceId
        ),
        capabilityBytes: capabilityBytes,
        productAdmissionGate: productAdmissionGate,
        installationAdmissionGate: installationAdmissionGate,
        productAdapter: BridgeProductSchemeAdapter(
            session: session,
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            installationAdmissionGate: installationAdmissionGate
        ),
        session: session
    )
    let owner = try BridgePaneProductSessionOwner(
        paneSessionId: paneSessionId,
        provider: provider,
        productAdmissionGate: productAdmissionGate,
        activeInstallation: installation
    )
    return .init(
        firstFrameWaiterRegistration: firstFrameWaiterRegistration,
        frameWaiterRegistrationCount: frameWaiterRegistrationCount,
        installation: installation,
        owner: owner,
        provider: provider,
        secondFrameWaiterRegistration: secondFrameWaiterRegistration
    )
}

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
    let admitted = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: observation.body
    )
    let resultBody = try JSONSerialization.data(
        withJSONObject: [
            "kind": "operation.result",
            "operationId": admitted.operationId,
            "paneSessionId": installation.bootstrap.paneSessionId,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ]
    )
    let resultReply = try await collectBridgeProductSchemeReply(
        adapter: installation.productAdapter,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: resultBody
        )
    )
    #expect(resultReply.response?.statusCode == 200)
    let result = try BridgeProductStrictJSON.decode(
        BridgeProductOperationResultResponse.self,
        from: resultReply.body
    )
    #expect(result.outcome == .succeeded)
}

func startBridgePaneProductMetadataReply(
    installation: BridgeProductSessionInstallation,
    provider: BridgePaneProductSessionProviderGate,
    handler: BridgeSchemeHandler? = nil,
    firstDataReceipt: HeldStep<Void>? = nil
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
            ),
            firstDataReceipt: firstDataReceipt
        )
    }
    try await provider.waitUntilMetadataProducerStarted()
    return replyTask
}

func startContentReply(
    installation: BridgeProductSessionInstallation,
    provider: BridgePaneProductSessionProviderGate,
    identitySuffix: String,
    handler: BridgeSchemeHandler? = nil,
    firstDataReceipt: HeldStep<Void>? = nil
) async throws -> Task<BridgeProductSchemeReplyObservation, any Error> {
    let request = try paneOwnerContentRequest(
        installation: installation,
        identitySuffix: identitySuffix
    )
    let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
        installation.capabilityBytes
    )
    let replyTask = Task {
        try await collectPaneOwnerProductReply(
            handler: handler,
            adapter: installation.productAdapter,
            request: bridgeProductSchemeRequest(
                route: BridgeProductWireContract.contentRoute,
                capability: capabilityHeader,
                body: try JSONEncoder().encode(request)
            ),
            firstDataReceipt: firstDataReceipt
        )
    }
    try await provider.waitUntilContentProducerStarted()
    return replyTask
}

private func collectPaneOwnerProductReply(
    handler: BridgeSchemeHandler?,
    adapter: BridgeProductSchemeAdapter,
    request: URLRequest,
    firstDataReceipt: HeldStep<Void>? = nil
) async throws -> BridgeProductSchemeReplyObservation {
    if let handler {
        return try await collectBridgeSchemeHandlerProductReply(
            handler: handler,
            request: request,
            firstDataReceipt: firstDataReceipt
        )
    }
    return try await collectBridgeProductSchemeReply(
        adapter: adapter,
        request: request,
        firstDataReceipt: firstDataReceipt
    )
}

func paneOwnerProductCallSchemeRequest(
    installation: BridgeProductSessionInstallation,
    identitySuffix: String
) throws -> URLRequest {
    let body = try JSONSerialization.data(
        withJSONObject: [
            "call": [
                "method": "review.markFileViewed",
                "request": ["itemId": "item-\(identitySuffix)"],
            ],
            "kind": "product.call",
            "paneSessionId": installation.bootstrap.paneSessionId,
            "requestId": "product-call-\(identitySuffix)",
            "requestSequence": 2,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 1,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ],
        options: [.sortedKeys]
    )
    return bridgeProductSchemeRequest(
        route: BridgeProductWireContract.commandRoute,
        capability: try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        ),
        body: body
    )
}

func collectBridgeSchemeHandlerProductReply(
    handler: BridgeSchemeHandler,
    request: URLRequest,
    firstDataReceipt: HeldStep<Void>? = nil
) async throws -> BridgeProductSchemeReplyObservation {
    var body = Data()
    var events: [BridgeProductSchemeReplyObservation.Event] = []
    var response: HTTPURLResponse?
    var hasHeldFirstDataReceipt = false
    for try await result in handler.reply(for: request) {
        switch result {
        case .response(let emittedResponse):
            events.append(.response)
            response = emittedResponse as? HTTPURLResponse
        case .data(let chunk):
            events.append(.data)
            body.append(chunk)
            if !hasHeldFirstDataReceipt, let firstDataReceipt {
                hasHeldFirstDataReceipt = true
                try await firstDataReceipt.arrive(())
            }
        @unknown default:
            Issue.record("Unexpected URL scheme task result")
        }
    }
    return .init(body: body, events: events, response: response)
}

private func paneOwnerContentRequest(
    installation: BridgeProductSessionInstallation,
    identitySuffix: String
) throws -> BridgeProductContentRequest {
    let requestJSON = """
        {
          "kind": "content.open",
          "wireVersion": 2,
          "paneSessionId": "\(installation.bootstrap.paneSessionId)",
          "workerDerivationEpoch": 1,
          "workerInstanceId": "\(installation.bootstrap.workerInstanceId)",
          "contentRequestId": "content-request-\(identitySuffix)",
          "leaseId": "lease-\(identitySuffix)",
          "operationCorrelationId": null,
          "contentKind": "file.content",
          "descriptor": {
            "contentKind": "file.content",
            "declaredByteLength": 3,
            "descriptorId": "file-descriptor-\(identitySuffix)",
            "encoding": "utf-8",
            "expectedSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "fileId": "file-\(identitySuffix)",
            "maximumBytes": 3,
            "source": {
              "repoId": "00000000-0000-4000-8000-000000000001",
              "rootRevisionToken": null,
              "sourceCursor": "source-cursor-\(identitySuffix)",
              "sourceId": "source-\(identitySuffix)",
              "subscriptionGeneration": 11,
              "worktreeId": "00000000-0000-4000-8000-000000000002"
            },
            "window": {
              "kind": "prefix",
              "maximumBytes": 3,
              "maximumLines": 10000,
              "startByte": 0
            }
          }
        }
        """
    return try BridgeProductStrictJSON.decode(
        BridgeProductContentRequest.self,
        from: Data(requestJSON.utf8)
    )
}

actor BridgePaneProductSessionProviderGate: BridgeProductSchemeProvider {
    private let workerRevocation: HeldStep<String>?

    init(workerRevocation: HeldStep<String>? = nil) {
        self.workerRevocation = workerRevocation
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
    private(set) var comparisonTargetReservationInvalidationCount = 0

    func invalidatePendingComparisonTargetReservation() {
        comparisonTargetReservationInvalidationCount += 1
    }

    func response(
        for request: BridgeProductControlRequest,
        productAdmission _: BridgeProductAdmissionContext?
    ) async -> BridgeProductControlResponse {
        do {
            switch request {
            case .workerSessionOpen:
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
