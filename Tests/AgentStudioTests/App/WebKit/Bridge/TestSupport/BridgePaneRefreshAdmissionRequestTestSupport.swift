import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

func installRefreshAdmissionMetadataProducer(
    installation: BridgeProductSessionInstallation,
    productProvider: BridgePaneProductSchemeProvider,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductProducerLease {
    let workerOpenRequest = try refreshAdmissionControlRequest([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "request-open-refresh-admission",
        "requestSequence": 1,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
    let workerOpenAdmission = await installation.session.beginControl(
        exactRequestBytes: try JSONEncoder().encode(workerOpenRequest),
        presentedCapability: try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        ),
        productAdmission: productAdmission
    )
    guard case .execute(let workerOpenToken, _) = workerOpenAdmission else {
        throw RefreshAdmissionIntegrationError.expectedWorkerSessionExecution
    }
    let admitted = try await installation.session.admitControlOperation(token: workerOpenToken) { _ in }
    let workerOpenResponse = try BridgeProductControlResponse.workerSessionAccepted(
        correlating: workerOpenRequest
    )
    _ = try await installation.session.completeControl(
        token: workerOpenToken,
        exactResponseBytes: try JSONEncoder().encode(workerOpenResponse)
    )
    await installation.session.settleOperation(
        operationId: admitted.operationId,
        response: workerOpenResponse
    )
    await installation.session.waitForOperationExecution(operationId: admitted.operationId)
    guard (await installation.session.snapshot).lifecycle == .active else {
        throw RefreshAdmissionIntegrationError.expectedWorkerSessionExecution
    }

    let metadataRequest = try refreshAdmissionMetadataRequest(installation: installation)
    let registration = await installation.session.registerMetadataProducer(
        request: metadataRequest,
        productAdmission: productAdmission
    ) { lease in
        await productProvider.runMetadataProducer(
            request: metadataRequest,
            lease: lease,
            productAdmission: productAdmission,
            session: installation.session
        )
    }
    guard case .accepted(let lease) = registration else {
        throw RefreshAdmissionIntegrationError.expectedMetadataProducerRegistration
    }
    _ = await consumeNextBridgeProductProducerFrame(
        for: lease,
        from: installation.session,
        productAdmission: productAdmission
    )
    try await waitForRefreshAdmissionMetadataStream(
        provider: productProvider,
        installation: installation
    )
    return lease
}

private func waitForRefreshAdmissionMetadataStream(
    provider: BridgePaneProductSchemeProvider,
    installation: BridgeProductSessionInstallation,
    maxTurns: Int = 200
) async throws {
    let request = try refreshAdmissionControlRequest([
        "activeSubscriptions": [],
        "kind": "workerSession.resync",
        "lastAcceptedRequestSequence": 1,
        "lastAcceptedStreamSequence": 0,
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-resync-refresh-admission",
        "requestSequence": 2,
        "wireVersion": BridgeProductWireContract.version,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
    for _ in 0..<maxTurns {
        if case .resyncAccepted = await provider.response(for: request) {
            return
        }
        await Task.yield()
    }
    throw RefreshAdmissionIntegrationError.metadataStreamDidNotInstall
}

private func refreshAdmissionControlRequest(
    _ object: [String: Any]
) throws -> BridgeProductControlRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductControlRequest.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func refreshAdmissionMetadataRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductMetadataStreamRequest {
    try BridgeProductStrictJSON.decode(
        BridgeProductMetadataStreamRequest.self,
        from: JSONSerialization.data(
            withJSONObject: [
                "kind": "metadataStream.open",
                "metadataStreamId": "metadata-refresh-admission",
                "paneSessionId": installation.bootstrap.paneSessionId,
                "resumeFromStreamSequence": NSNull(),
                "wireVersion": BridgeProductWireContract.version,
                "workerInstanceId": installation.bootstrap.workerInstanceId,
            ],
            options: [.sortedKeys]
        )
    )
}

func refreshAdmissionFileSubscriptionOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try refreshAdmissionControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-file-open-refresh-admission",
        "requestSequence": 2,
        "subscription": [
            "source": [
                "cwdScope": NSNull(),
                "freshness": "live",
                "includeStatuses": true,
                "repoId": "00000000-0000-4000-8000-000000000001",
                "rootPathToken": "root-token-refresh-admission",
                "worktreeId": "00000000-0000-4000-8000-000000000002",
            ],
            "subscriptionKind": "file.metadata",
        ],
        "subscriptionId": "file-subscription-refresh-admission",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

func refreshAdmissionReviewSubscriptionOpenRequest(
    installation: BridgeProductSessionInstallation
) throws -> BridgeProductControlRequest {
    try refreshAdmissionControlRequest([
        "kind": "subscription.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "request-review-open-refresh-admission",
        "requestSequence": 3,
        "subscription": ["subscriptionKind": "review.metadata"],
        "subscriptionId": "review-subscription-refresh-admission",
        "wireVersion": BridgeProductWireContract.version,
        "workerDerivationEpoch": 1,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}
