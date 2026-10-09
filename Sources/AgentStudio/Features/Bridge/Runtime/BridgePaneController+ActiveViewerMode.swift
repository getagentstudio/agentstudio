import AgentStudioInfrastructure
import Foundation

@MainActor
extension BridgePaneController {
    var isReviewShownByPage: Bool {
        activeViewerModeSignalState.acceptedMode == .review
    }

    func handleCommittedProductActiveViewerModeUpdate(
        sessionId: String,
        sequence: Int,
        mode: BridgeActiveViewerMode,
        activeSource: BridgeActiveViewerSource?,
        productAdmission: BridgeProductAdmissionContext,
        nativeSelectionRequestId: String? = nil,
        productCorrelation: BridgeProductControlCorrelation? = nil
    ) async {
        var rejectionReasons: [BridgeActiveViewerModeSignalRejectionReason] = []
        var didAcceptSequence = false
        let previousAcceptedSignal = activeViewerModeSignalState.acceptedSignal
        let isActiveSourceAccepted = activeSource.map { source in
            isCommittedProductActiveViewerSourceAccepted(
                mode: mode,
                source: source,
                productAdmission: productAdmission
            )
        }
        guard
            productAdmission.withValidAdmission({
                if activeViewerModeSignalState.sessionId != sessionId {
                    if activeViewerModeSignalState.sessionId != nil {
                        rejectionReasons.append(.sessionReset)
                    }
                    activeViewerModeSignalState = BridgeActiveViewerModeSignalState(
                        sessionId: sessionId,
                        lastSequence: nil,
                        acceptedMode: nil,
                        acceptedSignal: nil
                    )
                }
                if let lastSequence = activeViewerModeSignalState.lastSequence,
                    sequence <= lastSequence
                {
                    rejectionReasons.append(.staleSequence)
                    return
                }

                activeViewerModeSignalState.lastSequence = sequence
                activeViewerModeSignalState.acceptedMode = mode
                didAcceptSequence = true
                guard let activeSource else {
                    activeViewerModeSignalState.acceptedSignal = nil
                    return
                }
                guard isActiveSourceAccepted == true else {
                    activeViewerModeSignalState.acceptedSignal = nil
                    rejectionReasons.append(.staleGeneration)
                    return
                }
                activeViewerModeSignalState.acceptedSignal = BridgeActiveViewerModeAcceptedSignal(
                    mode: mode,
                    activeSource: activeSource,
                    sequenceFloor: sequence
                )
            }) != nil
        else {
            return
        }
        var surfaceSelectionReceiptDisposition: BridgePaneSurfaceSelectionReceiptDisposition?
        if didAcceptSequence,
            let nativeSelectionRequestId,
            let productCorrelation
        {
            surfaceSelectionReceiptDisposition = productAdmission.withValidAdmission {
                surfaceSelectionAuthority.admitReceipt(
                    nativeSelectionRequestId: nativeSelectionRequestId,
                    mode: mode,
                    paneSessionId: productCorrelation.paneSessionId,
                    workerInstanceId: productCorrelation.workerInstanceId
                )
            }
        }
        if let nativeSelectionRequestId,
            surfaceSelectionReceiptDisposition == .accepted
                || surfaceSelectionReceiptDisposition == .idempotentReplay
        {
            await productSchemeProvider?.settlePaneSurfaceSelectionRequest(
                requestId: nativeSelectionRequestId,
                productAdmission: productAdmission
            )
        }
        if rejectionReasons.isEmpty,
            didAcceptSequence,
            let activeSource,
            let acceptedSignal = activeViewerModeSignalState.acceptedSignal,
            previousAcceptedSignal?.mode != acceptedSignal.mode
                || previousAcceptedSignal?.activeSource != acceptedSignal.activeSource
        {
            await recordActiveViewerModeSignalAccepted(
                mode: mode,
                activeSource: activeSource,
                sequence: sequence
            )
        }
        for rejectionReason in rejectionReasons {
            await recordActiveViewerModeSignalRejected(
                reason: rejectionReason,
                mode: mode,
                activeSource: activeSource
            )
        }
        if didAcceptSequence, activeViewerModeSignalState.acceptedMode == .review {
            if !resumePendingExplicitReviewCommandIfPossible() {
                scheduleInitialReviewPackageLoadIfPossible(reason: .initialIntake)
                scheduleRetainedReviewPackageBuildIfPossible()
                scheduleWorktreeProductCatchUpIfPossible()
            }
        }
    }

    package func setActiveViewerModeAcceptedSignalForExplicitReviewRequestWithoutAdmissionCheck(
        streamId: String,
        generation: Int
    ) {
        setActiveViewerModeAcceptedSignalForExplicitRequestWithoutAdmissionCheck(
            mode: .review,
            activeSource: BridgeActiveViewerSource(
                protocolId: .review,
                streamId: streamId,
                generation: generation
            )
        )
    }

    func clearActiveViewerModeAcceptedSignalForExplicitReviewRequestWithoutAdmissionCheck() {
        activeViewerModeSignalState.acceptedSignal = nil
    }

    private func setActiveViewerModeAcceptedSignalForExplicitRequestWithoutAdmissionCheck(
        mode: BridgeActiveViewerMode,
        activeSource: BridgeActiveViewerSource
    ) {
        let sequenceFloor = (activeViewerModeSignalState.lastSequence ?? 0) + 1
        activeViewerModeSignalState.lastSequence = sequenceFloor
        activeViewerModeSignalState.acceptedSignal = BridgeActiveViewerModeAcceptedSignal(
            mode: mode,
            activeSource: activeSource,
            sequenceFloor: sequenceFloor
        )
    }

    private func recordActiveViewerModeSignalRejected(
        reason: BridgeActiveViewerModeSignalRejectionReason,
        mode: BridgeActiveViewerMode,
        activeSource: BridgeActiveViewerSource?
    ) async {
        guard let telemetryRecorder else {
            return
        }
        await telemetryRecorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.active_viewer_mode_signal_rejected",
                durationMilliseconds: nil,
                traceContext: nil,
                stringAttributes: [
                    "agentstudio.bridge.active_source.protocol": activeSource?.protocolId.rawValue ?? "none",
                    "agentstudio.bridge.active_viewer.mode": mode.rawValue,
                    "agentstudio.bridge.active_viewer.signal_rejection_reason": reason.rawValue,
                    "agentstudio.bridge.phase": "active_viewer_mode_signal_rejected",
                    "agentstudio.bridge.plane": BridgeTelemetryPlane.control.rawValue,
                    "agentstudio.bridge.priority": BridgeTelemetryPriority.warm.rawValue,
                    "agentstudio.bridge.slice": BridgeTelemetrySlice.reviewRPC.rawValue,
                    "agentstudio.bridge.transport": "swift",
                ],
                numericAttributes: [
                    "agentstudio.bridge.active_viewer.signal_rejected.count": 1
                ],
                booleanAttributes: [:]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }

    private func recordActiveViewerModeSignalAccepted(
        mode: BridgeActiveViewerMode,
        activeSource: BridgeActiveViewerSource,
        sequence: Int
    ) async {
        guard let telemetryRecorder else {
            return
        }
        await telemetryRecorder.record(
            sample: BridgeTelemetrySample(
                scope: .swift,
                name: "performance.bridge.swift.active_viewer_mode_signal_accepted",
                durationMilliseconds: nil,
                traceContext: nil,
                stringAttributes: [
                    "agentstudio.bridge.active_source.protocol": activeSource.protocolId.rawValue,
                    "agentstudio.bridge.active_viewer.mode": mode.rawValue,
                    "agentstudio.bridge.phase": "active_viewer_mode_signal_accepted",
                    "agentstudio.bridge.plane": BridgeTelemetryPlane.control.rawValue,
                    "agentstudio.bridge.priority": BridgeTelemetryPriority.warm.rawValue,
                    "agentstudio.bridge.result": "success",
                    "agentstudio.bridge.slice": BridgeTelemetrySlice.reviewRPC.rawValue,
                    "agentstudio.bridge.transport": "swift",
                ],
                numericAttributes: [
                    "agentstudio.bridge.active_viewer.sequence": Double(sequence),
                    "agentstudio.bridge.active_viewer.signal_accepted.count": 1,
                    "agentstudio.bridge.source.generation": Double(activeSource.generation),
                ],
                booleanAttributes: [:]
            ),
            receivedAtUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        )
    }

    private func isCommittedProductActiveViewerSourceAccepted(
        mode: BridgeActiveViewerMode,
        source: BridgeActiveViewerSource,
        productAdmission: BridgeProductAdmissionContext
    ) -> Bool {
        if mode == .file {
            return source.protocolId == .worktreeFile
        }
        guard source.protocolId == .review,
            let publication = reviewPublicationCoordinator.committedPublicationForReplay(
                productAdmission: productAdmission
            )
        else { return false }
        return source.streamId == reviewProtocolStreamId()
            && source.generation == publication.package.reviewGeneration.rawValue
    }

}

private enum BridgeActiveViewerModeSignalRejectionReason: String {
    case staleGeneration = "stale_generation"
    case staleSequence = "stale_sequence"
    case sessionReset = "session_reset"
}
