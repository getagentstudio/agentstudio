import Foundation
import Testing

@testable import AgentStudioBridge

/// A control's admission is not its result. The native effect settles before
/// the result becomes readable, so assertions about effects await that result.
func awaitBridgeProductAdmittedControlResult(
    _ dispatchResult: BridgeProductSchemeControlDispatchResult,
    session: BridgeProductSession,
    productAdmission: BridgeProductAdmissionContext
) async throws -> BridgeProductOperationResultResponse {
    guard case .response(let admissionBytes) = dispatchResult else {
        throw BridgeProductAdmissionResultTestError.expectedAdmission
    }
    let admitted = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: admissionBytes
    )
    await session.waitForOperationExecution(operationId: admitted.operationId)
    let requestBody = try JSONSerialization.data(
        withJSONObject: [
            "kind": "operation.result",
            "operationId": admitted.operationId,
            "paneSessionId": admitted.correlation.paneSessionId,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": admitted.correlation.workerInstanceId,
        ]
    )
    let request = try BridgeProductStrictJSON.decode(
        BridgeProductOperationResultRequest.self,
        from: requestBody
    )
    return try #require(await session.readOperationResult(request, productAdmission: productAdmission))
}

private enum BridgeProductAdmissionResultTestError: Error {
    case expectedAdmission
}
