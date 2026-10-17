import Foundation

@testable import AgentStudioBridge

extension BridgeProductSession {
    /// Direct session tests use this when their subject is the state transition
    /// after admission rather than the scheme adapter's routing.
    func admitControlProviderExecution(token: BridgeProductControlAdmissionToken) -> Bool {
        (try? admitControlOperation(token: token, execute: { _ in })) != nil
    }

    func completeAdmittedControl(
        token: BridgeProductControlAdmissionToken,
        exactResponseBytes: Data
    ) async throws -> BridgeProductSessionCompletionEffect {
        if let pendingControl, pendingControl.token == token,
            pendingControl.request.isSlotFreeEscape
        {
            let response = try BridgeProductStrictJSON.decode(
                BridgeProductControlResponse.self,
                from: exactResponseBytes
            )
            return try completeEscapeControl(token: token, response: response)
        }
        if operationTable.entry(for: token) == nil {
            _ = try admitControlOperation(token: token, execute: { _ in })
        }
        let effect = try await completeControl(
            token: token,
            exactResponseBytes: exactResponseBytes
        )
        let response = try BridgeProductStrictJSON.decode(
            BridgeProductControlResponse.self,
            from: exactResponseBytes
        )
        if let operationId = operationTable.entry(for: token)?.operationId {
            settleOperation(operationId: operationId, response: response)
        }
        return effect
    }
}
