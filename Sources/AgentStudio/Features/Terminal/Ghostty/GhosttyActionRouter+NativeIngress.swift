import AgentStudioInfrastructure
import Foundation
import GhosttyKit

extension Ghostty.ActionRouter {
    /// Audited immediate boundary: no target/action pointer survives this call.
    func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let tag = UInt32(truncatingIfNeeded: action.tag.rawValue)
        let decoded = GhosttyCallbackPayloadDecoder.decode(action)
        switch decoded {
        case .intercepted(let interceptedTag):
            if interceptedTag == .showChildExited, let copiedTarget = Self.copyNativeTarget(target) {
                // fire-and-forget: the callback task owner retains this handle and joins it during retirement.
                _ = taskOwner.enqueueTask { @MainActor [host] in
                    guard case .surface(let surfaceID, let viewObjectID) = copiedTarget,
                        host.isCurrentSurfaceLifetime(surfaceID: surfaceID, viewObjectID: viewObjectID),
                        let paneID = host.routingLookup.paneId(for: surfaceID)
                    else { return }
                    host.startupTraceRecorder?.recordChildExited(
                        paneID: paneID, surfaceID: surfaceID, actionName: String(describing: interceptedTag)
                    )
                }
            }
            return true
        case .rejected:
            if let knownTag = GhosttyActionTag(rawValue: tag), !Self.unsupportedTags.contains(knownTag) {
                ghosttyLogger.warning("Malformed payload for Ghostty action \(String(describing: knownTag))")
                return false
            }
            host.traceGhosttyAction(
                body: "ghostty.action.received", actionTag: tag,
                signalClass: .unhandled, routeResult: false,
                reason: GhosttyActionTag(rawValue: tag) == nil ? "unknown_action" : "unsupported_action"
            )
            return false
        case .payload(let payload, let handled):
            guard target.tag == GHOSTTY_TARGET_SURFACE, target.target.surface != nil else { return false }
            guard let copiedTarget = Self.copyNativeTarget(target) else { return handled }
            _ = accept(.action(target: copiedTarget, tag: tag, payload: payload))
            return handled
        case .directHost(let update, let handled):
            if let copiedTarget = Self.copyNativeTarget(target),
                case .surface(let surfaceID, let viewObjectID) = copiedTarget
            {
                _ = accept(.directHost(surfaceID: surfaceID, viewObjectID: viewObjectID, update: update))
            }
            return handled
        }
    }

    private static func copyNativeTarget(_ target: ghostty_target_s) -> GhosttyOwnedTarget? {
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            return .application
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface, let userdata = ghostty_surface_userdata(surface) else {
                return nil
            }
            let view = Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            return .surface(surfaceID: view.managedSurfaceID, viewObjectID: ObjectIdentifier(view))
        default:
            return nil
        }
    }

    static func copiedSetTitlePayload(from action: ghostty_action_s) -> GhosttyActionPayload? {
        action.action.set_title.title.map { .titleChanged(String(cString: $0)) }
    }
}
