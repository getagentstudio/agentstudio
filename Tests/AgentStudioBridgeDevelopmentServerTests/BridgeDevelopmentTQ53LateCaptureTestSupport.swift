import HummingbirdTesting
import Testing

@testable import AgentStudioBridge

/// Consume each real preceding batch before trying again. Admission and sealing
/// share one session turn, so newer captures cannot coalesce the old capture away.
func sealTQ53LateCapture(
    client: some TestClientProtocol,
    connection: HTTPProductConnection,
    recorder: HTTPMetadataFrameRecorder,
    activeStream: BridgePaneProductMetadataCoordinator.ActiveStream,
    capture: (snapshot: BridgeWorktreeFileKeyedSnapshot, scope: BridgeProductAcceptedViewScopeSnapshot),
    retainedState: inout HTTPFileBatchRetainedState
) async throws {
    while try await !sealTQ53CaptureWithoutCoalescing(
        session: activeStream.session, snapshot: capture.snapshot,
        scope: capture.scope, productAdmission: activeStream.productAdmission)
    {
        _ = try await nextHTTPFileBatchSnapshot(
            client: client, connection: connection, recorder: recorder, retainedState: &retainedState)
    }
}

private func sealTQ53CaptureWithoutCoalescing(
    session: isolated BridgeProductSession,
    snapshot: BridgeWorktreeFileKeyedSnapshot,
    scope: BridgeProductAcceptedViewScopeSnapshot,
    productAdmission: BridgeProductAdmissionContext
) throws -> Bool {
    guard !session.viewSenderState.hasActiveEmission(for: scope.viewDomain) else { return false }
    try #require(
        try session.sealFileCapture(
            subscriptionId: scope.viewDomain.viewId, snapshot: snapshot,
            scope: scope, productAdmission: productAdmission))
    return true
}
