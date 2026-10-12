import Foundation

/// Native identity copied while callback userdata is valid.
enum GhosttyOwnedTarget: Sendable, Equatable {
    case application
    case surface(surfaceID: UUID, viewObjectID: ObjectIdentifier)
}

/// Deferred callback input contains copied values rather than borrowed native inputs.
enum GhosttyOwnedCallbackWork: Sendable, Equatable {
    case action(target: GhosttyOwnedTarget, tag: UInt32, payload: GhosttyActionPayload)
    case directHost(surfaceID: UUID, viewObjectID: ObjectIdentifier, update: GhosttyDirectHostUpdate)
    case close(surfaceID: UUID, viewObjectID: ObjectIdentifier)
}

package enum GhosttyDirectHostUpdate: Sendable, Equatable {
    case closeRequested
    case workingDirectory(String?)
    case reportedInitialSize(width: UInt32, height: UInt32)
    case reportedCellSize(width: UInt32, height: UInt32)
    case cache(tag: UInt32, payload: GhosttyActionPayload)
}

package enum GhosttyDeferredApplyResult: Sendable, Equatable {
    case applied
    case unchanged
    case dropped(GhosttyDeferredDropReason)
}

package enum GhosttyDeferredDropReason: Sendable, Equatable {
    case retiredHandling
    case staleSurface
    case paneNotMapped
    case runtimeNotFound
    case engineUnavailable
}

package typealias GhosttyNativeViewApplyOperation =
    @MainActor @Sendable (UUID, ObjectIdentifier, GhosttyDirectHostUpdate) async -> GhosttyDeferredApplyResult

package enum GhosttyEngineAvailability: Sendable {
    case available(Ghostty.App)
    case unavailable
}
