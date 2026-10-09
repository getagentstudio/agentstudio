import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension Ghostty.ActionRouter {
    func retireLocalActions(for surfaceID: UUID) {
        localActionDrainScheduler.cancel(for: surfaceID)
        localActionAccumulator.removeSurface(surfaceID)
    }

    @MainActor
    func closeLocalActions(surfaceID: UUID, paneID: UUID) {
        guard taskOwner.isAcceptingWork else {
            retireLocalActions(for: surfaceID)
            return
        }
        localActionDrainScheduler.cancel(for: surfaceID)
        let aggregate = localActionAccumulator.detachActivityForSurfaceClose(
            surfaceID, defaultActivityContext: host.activityContext(paneID)
        )
        // fire-and-forget: the callback task owner retains this handle and joins it during retirement.
        _ = taskOwner.enqueueTask { @MainActor [host] in
            guard
                Self.shouldSubmitSurfaceClose(
                    currentPaneID: host.routingLookup.paneId(for: surfaceID), closingPaneID: paneID
                )
            else { return }
            await host.submitActivityInput(
                .orderedControl(
                    surfaceID: surfaceID, paneID: paneID, precedingAggregate: aggregate, control: .surfaceClosed)
            )
        }
    }

    @MainActor
    func applyOrderedActivityControl(
        surfaceID: UUID,
        paneID: UUID,
        control: TerminalActivityOrderedControl,
        contextBeforeControl: TerminalActivityProjectionContext? = nil,
        contextAfterControl: TerminalActivityProjectionContext? = nil
    ) async -> GhosttyDeferredApplyResult {
        guard
            let task = taskOwner.enqueueTask({ @MainActor [host, localActionAccumulator] in
                await host.applyOrderedActivityControl(
                    surfaceID: surfaceID, paneID: paneID, control: control,
                    contextBeforeControl: contextBeforeControl, contextAfterControl: contextAfterControl,
                    accumulator: localActionAccumulator
                )
                return GhosttyDeferredApplyResult.applied
            })
        else { return .dropped(.retiredHandling) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
