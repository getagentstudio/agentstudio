import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension TerminalActivityRouter {
    nonisolated static func makeResumedSessionStartSink(
        projector: TerminalActivityProjector,
        surfaceIDForPaneID: @escaping @MainActor @Sendable (UUID) -> UUID?,
        callbackHandlingAccess: @escaping @MainActor @Sendable () -> Ghostty.ActionRouter?,
        performanceTraceRecorder: AgentStudioPerformanceTraceRecorder? = nil
    ) -> @Sendable (UUID, String, String) async -> Void {
        let recordEnd: @MainActor @Sendable (UUID, RestorePhaseGenerationClaim) -> RestoreGeneration? = { pane, claim in
            AgentStudioPerformanceTraceRecorder.measureRestoreSlice(
                .restoreResumedStartEnd, recorder: performanceTraceRecorder
            ) {
                guard
                    let fallback = claim.withCurrentGeneration({ generation -> RestoreGeneration? in
                        guard let surfaceID = surfaceIDForPaneID(pane), let callbackHandling = callbackHandlingAccess()
                        else {
                            return generation
                        }
                        callbackHandling.localActionAccumulator.markRestorePhaseEnded(
                            surfaceID: surfaceID, generation: generation,
                            contextBeforeControl: callbackHandling.host.activityContext(pane))
                        return nil
                    })
                else { return nil }
                return fallback
            }
        }
        return { paneID, providerIdentifier, providerSessionID in
            await deliverResumedSessionStart(
                paneID: paneID, providerIdentifier: providerIdentifier, providerSessionID: providerSessionID,
                projector: projector, recordEnd: recordEnd)
        }
    }

    @concurrent nonisolated private static func deliverResumedSessionStart(
        paneID: UUID, providerIdentifier: String, providerSessionID: String,
        projector: TerminalActivityProjector,
        recordEnd: @MainActor @Sendable (UUID, RestorePhaseGenerationClaim) -> RestoreGeneration?
    ) async {
        guard
            let claim = await projector.claimMatchingResumeRestoreGeneration(
                paneID: paneID, providerIdentifier: providerIdentifier, providerSessionID: providerSessionID)
        else { return }
        if let generation = await recordEnd(paneID, claim) {
            await projector.endRestorePhase(paneID: paneID, generation: generation)
        }
    }
}
