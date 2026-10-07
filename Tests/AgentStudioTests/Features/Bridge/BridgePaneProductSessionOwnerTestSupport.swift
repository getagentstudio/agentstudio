import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

final class BridgePaneProductSessionOwnerFrameWaiterFixture {
    let firstFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>
    let installation: BridgeProductSessionInstallation
    let owner: BridgePaneProductSessionOwner
    let provider: BridgePaneProductSessionProviderGate
    let secondFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>

    init(
        firstFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>,
        installation: BridgeProductSessionInstallation,
        owner: BridgePaneProductSessionOwner,
        provider: BridgePaneProductSessionProviderGate,
        secondFrameWaiterRegistration: HeldStep<BridgeProductProducerLease>
    ) {
        self.firstFrameWaiterRegistration = firstFrameWaiterRegistration
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
    let frameWaiterRegistrationLeases = Mutex<Set<BridgeProductProducerLease>>([])
    let session = try BridgeProductSession(
        paneSessionId: paneSessionId,
        workerInstanceId: workerInstanceId,
        capabilityBytes: capabilityBytes,
        producerFrameWaiterRegistrationObserver: { lease in
            let registrationIndex = frameWaiterRegistrationLeases.withLock { leases -> Int? in
                guard leases.insert(lease).inserted else { return nil }
                return leases.count
            }
            guard let registrationIndex else { return }
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
        activeInstallation: installation,
        retirementClock: TestPushClock()
    )
    return .init(
        firstFrameWaiterRegistration: firstFrameWaiterRegistration,
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
