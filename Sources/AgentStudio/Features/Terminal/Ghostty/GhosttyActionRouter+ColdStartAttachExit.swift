import AgentStudioCore
import Foundation

/// `package` (not `private`), matching `GhosttyTerminalActivityInputBinding`'s
/// own reasoning: a dedicated test suite constructs a fresh instance to
/// prove the routing mechanic in isolation, without touching the shared
/// global singleton below.
///
/// SR5; Program Design item 3, "the surface's command exits before
/// handoff, including while discovering": Ghostty's `showChildExited`
/// action is the one event-driven fact present whether the attach client
/// dies during discovery or after (`GhosttyActionRouter+StartupTracing
/// .swift`'s `scheduleChildExitedStartupTrace` already resolves the pane
/// for its own trace call; this binding is fed through that same
/// resolution, not a second lookup).
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

@MainActor private let coldStartAttachExitBinding = ColdStartAttachExitBinding()

extension Ghostty.ActionRouter {
    @MainActor
    package static func bindAttachClientExitedHandler(_ handler: (@MainActor (UUID) -> Void)?) {
        coldStartAttachExitBinding.bindAttachClientExitedHandler(handler)
    }

    @MainActor
    package static func registerColdStartAttachExitObserver(paneID: UUID, observer: ColdStartObserver) {
        coldStartAttachExitBinding.register(paneID: paneID, observer: observer)
    }

    @MainActor
    package static func unregisterColdStartAttachExitObserver(paneID: UUID) {
        coldStartAttachExitBinding.unregister(paneID: paneID)
    }

    @MainActor
    static func reportColdStartAttachClientExited(paneID: UUID) {
        coldStartAttachExitBinding.reportAttachClientExited(paneID: paneID)
    }

    @MainActor
    package static func cancelPendingColdStart(paneID: UUID) {
        coldStartAttachExitBinding.cancelPendingColdStart(paneID: paneID)
    }
}
