import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

extension GhosttyActionRoutingHost {
    nonisolated func traceGhosttyAction(
        body: String,
        actionTag: UInt32,
        payload: GhosttyActionPayload? = nil,
        event: GhosttyEvent? = nil,
        paneId: UUID? = nil,
        surfaceId: UUID? = nil,
        signalClass: Ghostty.ActionRouter.GhosttyTraceSignalClass,
        routeResult: Bool?,
        reason: String?
    ) {
        guard !Ghostty.ActionRouter.isHighVolumeTraceAction(actionTag) else { return }
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.ghostty.action.tag": .int(Int(actionTag)),
            "agentstudio.ghostty.signal.class": .string(signalClass.rawValue),
        ]
        if let actionName = GhosttyActionTag(rawValue: actionTag).map({ String(describing: $0) }) {
            attributes["agentstudio.ghostty.action.name"] = .string(actionName)
        }
        if let payload {
            attributes["agentstudio.ghostty.action.payload"] = .string(Ghostty.ActionRouter.payloadTraceName(payload))
        }
        if let event {
            attributes["agentstudio.runtime.event"] = .string(event.traceEventName)
        }
        if let paneId {
            attributes["agentstudio.pane.id"] = .string(paneId.uuidString)
        }
        if let surfaceId {
            attributes["agentstudio.surface.id"] = .string(surfaceId.uuidString)
        }
        if let routeResult {
            attributes["agentstudio.ghostty.route.result"] = .bool(routeResult)
        }
        if let reason {
            attributes["agentstudio.ghostty.route.reason"] = .string(reason)
        }
        actionTraceQueueStore.record(
            tag: .terminalSignal,
            body: body,
            attributes: attributes
        )
    }

}
