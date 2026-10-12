import Foundation

/// Retained by the engine through native free; native ingress captures it synchronously.
final class GhosttyCallbackContext: Sendable {
    let handling: Ghostty.ActionRouter
    @MainActor private weak var engineTarget: Ghostty.App?

    init(handling: Ghostty.ActionRouter) {
        self.handling = handling
    }

    @MainActor
    func installEngineTarget(_ engine: Ghostty.App) {
        engineTarget = engine
    }

    @MainActor
    func clearEngineTarget() {
        engineTarget = nil
    }

    func wakeup() {
        // fire-and-forget: the callback task owner retains this handle and joins it during retirement.
        _ = handling.taskOwner.enqueueTask { @MainActor [self] in
            guard let engineTarget, engineTarget.app != nil else { return }
            engineTarget.tick()
        }
    }
}
