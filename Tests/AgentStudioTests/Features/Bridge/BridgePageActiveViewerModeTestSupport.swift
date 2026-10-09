import Foundation

@testable import AgentStudioBridge

@MainActor
func sendPageActiveViewerMode(
    _ mode: BridgeActiveViewerMode,
    controller: BridgePaneController,
    productAdmission: BridgeProductAdmissionContext,
    sequence: Int,
    activeSource: BridgeActiveViewerSource? = nil,
    sessionId: String? = nil
) async {
    await controller.handleCommittedProductActiveViewerModeUpdate(
        sessionId: sessionId ?? controller.paneId.uuidString,
        sequence: sequence,
        mode: mode,
        activeSource: activeSource,
        productAdmission: productAdmission
    )
}
