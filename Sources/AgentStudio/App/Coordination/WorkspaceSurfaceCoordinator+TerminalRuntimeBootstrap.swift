import AgentStudioCore
import AgentStudioTerminal

extension WorkspaceSurfaceCoordinator {
    func registerTerminalRuntimeIfNeeded(for pane: Pane) {
        guard let preparedRuntime = prepareTerminalRuntimeIfNeeded(for: pane) else { return }
        viewRegistry.terminalView(for: pane.id)?.bind(runtime: preparedRuntime.runtime)
    }

    func prepareTerminalRuntimeForFreshSurfaceIfNeeded(
        for pane: Pane
    ) -> (runtime: TerminalRuntime, wasCreated: Bool)? {
        guard case .terminal = pane.content else { return nil }
        return prepareTerminalRuntimeIfNeeded(for: pane)
    }

    func rollbackPreparedTerminalRuntimeIfNeeded(
        _ preparedRuntime: (runtime: TerminalRuntime, wasCreated: Bool)?
    ) {
        guard let preparedRuntime, preparedRuntime.wasCreated else { return }
        _ = unregisterRuntime(preparedRuntime.runtime.paneId)
    }

    private func prepareTerminalRuntimeIfNeeded(for pane: Pane) -> (runtime: TerminalRuntime, wasCreated: Bool)? {
        guard case .terminal = pane.content else {
            Self.logger.debug(
                "Skipping terminal runtime registration for non-terminal pane \(pane.id.uuidString, privacy: .public)"
            )
            return nil
        }

        let runtimePaneId = PaneId(existingUUID: pane.id)
        if let existingRuntime = runtimeForPane(runtimePaneId) as? TerminalRuntime {
            return (existingRuntime, false)
        }

        let terminalRuntime = TerminalRuntime(
            paneId: runtimePaneId,
            metadata: pane.metadata,
            paneEventBus: paneEventBus,
            surfaceCommandDispatcher: terminalSurfaceCommandDispatcher
        )
        guard terminalRuntime.transitionToReady() else {
            Self.logger.warning(
                "Terminal runtime for pane \(pane.id.uuidString, privacy: .public) failed ready transition; skipping runtime registration"
            )
            return nil
        }
        registerRuntime(terminalRuntime)
        return (terminalRuntime, true)
    }
}
