import AgentStudioCore
import Foundation

/// Instance-owned attach-exit observers. App composes the native callback with the
/// coordinator's startup windows and post-attach checks before creating surfaces.
@MainActor
package final class ColdStartAttachExitBinding {
    private var observersByPaneID: [UUID: ColdStartObserver] = [:]
    private var attachClientExitedHandler: (@MainActor (UUID) -> Void)?

    package init() {}

    /// Registered when a cold pane's startup window begins (alongside
    /// arming its restore phase), before the surface that runs the attach
    /// command is created — a `showChildExited` that races registration
    /// would otherwise be missed.
    package func register(paneID: UUID, observer: ColdStartObserver) {
        observersByPaneID[paneID] = observer
    }

    /// Unregistered once the window settles or the pane is torn down, so a
    /// later, unrelated pane reusing the same slot never reaches a stale
    /// observer.
    package func unregister(paneID: UUID) {
        observersByPaneID.removeValue(forKey: paneID)
    }

    package func bindAttachClientExitedHandler(_ handler: (@MainActor (UUID) -> Void)?) {
        attachClientExitedHandler = handler
    }

    package func reportAttachClientExited(paneID: UUID) {
        if let observer = observersByPaneID[paneID] {
            Task { await observer.reportAttachClientExited() }
        }
        attachClientExitedHandler?(paneID)
    }

    /// Program Design item 4, "removes its kqueue registrations and settles
    /// the slot": retirement or activation cancellation for a pane with a
    /// pending cold start. `cancel()` unblocks the observer's own
    /// `observeColdStart` awaiter, whose completion handler releases the
    /// start slot and unregisters from this binding — this call site does
    /// not need to duplicate that cleanup.
    package func cancelPendingColdStart(paneID: UUID) {
        guard let observer = observersByPaneID[paneID] else { return }
        Task { await observer.cancel() }
    }
}
