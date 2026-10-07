import Foundation

/// `package` (not `private`) so `GhosttyActionRouterTerminalActivityInputTests`
/// can construct a fresh instance and prove the "waits, then arms" mechanic
/// (SR6b) in isolation, without touching the shared global singleton below —
/// which several other test files already bind/unbind against.
@MainActor
package final class GhosttyTerminalActivityInputBinding {
    var id: UUID?
    var context: (@MainActor @Sendable (UUID) -> TerminalActivityProjectionContext)?
    var sink: (@MainActor @Sendable (TerminalActivitySourceInput) async -> Void)?
    /// SR6b (Program Design item 13, "Arming"): waiters registered before the
    /// router ever binds in this launch. Resumed in `bind`'s publication
    /// order, or individually on cancellation — never left leaked.
    private var boundWaitersByID: [UUID: CheckedContinuation<Void, Never>] = [:]

    package init() {}

    var isBound: Bool { sink != nil }

    func bind(
        id: UUID,
        context: @escaping @MainActor @Sendable (UUID) -> TerminalActivityProjectionContext,
        sink: @escaping @MainActor @Sendable (TerminalActivitySourceInput) async -> Void
    ) {
        self.id = id
        self.context = context
        self.sink = sink
        let waiters = boundWaitersByID
        boundWaitersByID.removeAll()
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    func unbind(id: UUID) {
        guard self.id == id else { return }
        self.id = nil
        context = nil
        sink = nil
    }

    /// Awaits the router's bound fact when not already bound (SR6b, choice
    /// 13: "activation waits for the router's bound fact ... and then
    /// arms"). Cancellation-safe: a cancelled waiter resumes immediately
    /// instead of leaking, leaving `sink` nil for the caller to observe.
    ///
    /// `onWaiterRegistered` (F7, review round 1): fires synchronously, still
    /// inside the continuation's own setup closure, the instant this
    /// waiter's continuation is actually stored in `boundWaitersByID` — a
    /// real registration fact a test can wait on instead of guessing with a
    /// yield. `nil` in every production call.
    func awaitBound(onWaiterRegistered: (@Sendable () -> Void)? = nil) async {
        guard sink == nil else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard sink == nil else {
                    continuation.resume()
                    return
                }
                boundWaitersByID[waiterID] = continuation
                onWaiterRegistered?()
            }
        } onCancel: {
            Task { @MainActor in
                self.resumeWaiter(waiterID)
            }
        }
    }

    private func resumeWaiter(_ waiterID: UUID) {
        guard let continuation = boundWaitersByID.removeValue(forKey: waiterID) else { return }
        continuation.resume()
    }
}

@MainActor private let ghosttyTerminalActivityInputBinding = GhosttyTerminalActivityInputBinding()

extension Ghostty.ActionRouter {
    @MainActor
    static func bindTerminalActivityInput(
        id: UUID,
        context: @escaping @MainActor @Sendable (UUID) -> TerminalActivityProjectionContext,
        sink: @escaping @MainActor @Sendable (TerminalActivitySourceInput) async -> Void
    ) {
        ghosttyTerminalActivityInputBinding.bind(id: id, context: context, sink: sink)
    }

    @MainActor
    static func unbindTerminalActivityInput(id: UUID) {
        ghosttyTerminalActivityInputBinding.unbind(id: id)
    }

    @MainActor
    static func submitTerminalActivityInput(_ input: TerminalActivitySourceInput) async {
        await ghosttyTerminalActivityInputBinding.sink?(input)
    }

    @MainActor
    static func terminalActivityProjectionContext(paneID: UUID) -> TerminalActivityProjectionContext? {
        ghosttyTerminalActivityInputBinding.context?(paneID)
    }

    /// SR6b, choice 13's "Arming": submits `.restorePhaseArmed` with an
    /// acknowledgment instead of `Void`. Never creates a cold surface
    /// unarmed — if the router isn't bound yet, this waits for its bound
    /// fact first (no poll, no timeout) and arms as soon as it is.
    /// `.projectorUnbound` is reached only when that wait is cancelled
    /// before the router ever bound.
    @MainActor
    package static func armRestorePhase(
        paneID: UUID,
        restoreGeneration: RestoreGeneration
    ) async -> RestorePhaseArmAcknowledgment {
        if !ghosttyTerminalActivityInputBinding.isBound {
            await ghosttyTerminalActivityInputBinding.awaitBound()
        }
        guard let sink = ghosttyTerminalActivityInputBinding.sink else {
            return .projectorUnbound
        }
        await sink(.restorePhaseArmed(paneID: paneID, restoreGeneration: restoreGeneration))
        return .armed
    }

    /// SR6b: permanent pane retirement (`WorkspaceSurfaceCoordinator
    /// .retirePanesPermanently`) submits this fact so the projector clears
    /// `restorePhaseByPane` for the pane — the ingress half of the
    /// "permanent close vs. surface replacement" distinction Panes' consumer
    /// depends on. Unlike `armRestorePhase`, this never waits for the router
    /// to bind: a pane can only be retired after having existed, so the
    /// router was already bound at some point in this launch; if it is
    /// unbound now (router stopped), the fact is dropped, matching every
    /// other fire-and-forget submission through this binding.
    @MainActor
    package static func retirePanePermanently(paneID: UUID) async {
        await ghosttyTerminalActivityInputBinding.sink?(.paneRetiredPermanently(paneID: paneID))
    }
}
