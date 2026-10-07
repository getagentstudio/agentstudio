import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import GhosttyKit

extension Ghostty.ActionRouter {
    @MainActor
    static func traceTerminalStartupMilestones(
        actionTag: UInt32,
        event: GhosttyEvent,
        paneID: UUID,
        surfaceID: UUID
    ) {
        let actionName = GhosttyActionTag(rawValue: actionTag).map { String(describing: $0) } ?? "\(actionTag)"
        startupTraceRecorder?.recordFirstGhosttyAction(
            paneID: paneID,
            surfaceID: surfaceID,
            actionName: actionName
        )
        switch event {
        case .cwdChanged:
            startupTraceRecorder?.recordCwdReady(paneID: paneID, surfaceID: surfaceID)
        case .titleChanged, .tabTitleChanged:
            startupTraceRecorder?.recordTitleReady(paneID: paneID, surfaceID: surfaceID)
        default:
            break
        }
    }

    static func scheduleChildExitedStartupTrace(
        actionTag: UInt32,
        target: ghostty_target_s,
        routingLookupProvider: @escaping GhosttyActionRoutingLookupProvider
    ) {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface,
            let resolvedSurfaceView = surfaceView(from: surface)
        else { return }

        let surfaceViewObjectID = ObjectIdentifier(resolvedSurfaceView)
        let actionName = GhosttyActionTag(rawValue: actionTag).map { String(describing: $0) } ?? "\(actionTag)"
        Task { @MainActor in
            let lookup = routingLookupProvider()
            guard let surfaceID = lookup.surfaceId(forViewObjectId: surfaceViewObjectID),
                let paneID = lookup.paneId(for: surfaceID)
            else { return }

            startupTraceRecorder?.recordChildExited(
                paneID: paneID,
                surfaceID: surfaceID,
                actionName: actionName
            )
            // SR5; Program Design item 3: a no-op for a pane with no pending
            // cold-start window (ColdStartAttachExitBinding.reportAttachClientExited
            // is a no-op when unregistered).
            reportColdStartAttachClientExited(paneID: paneID)
        }
    }

}
