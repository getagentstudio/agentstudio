import AgentStudioCore
import AgentStudioTerminal
import Foundation

extension WorkspaceSurfaceCoordinator {
    func shutdownTerminalProtocolWork() async {
        for task in incompatibleTerminalRestartTasksByPaneID.values { task.cancel() }
        for task in terminalProtocolClassificationTasksByPaneID.values { task.cancel() }
        for task in incompatibleTerminalRestartTasksByPaneID.values { await task.value }
        incompatibleTerminalRestartTasksByPaneID.removeAll()
        for task in terminalProtocolClassificationTasksByPaneID.values { await task.value }
        terminalProtocolClassificationTasksByPaneID.removeAll()
    }

    /// Only untracked or mismatched sessions wait here; persisted current sessions never start a task.
    func beginTerminalProtocolClassification(for pane: Pane, treatAsRestoredSessionStart: Bool) {
        _ = registerTerminalPlaceholderIfNeeded(for: pane, mode: .preparing)
        guard terminalProtocolClassificationTasksByPaneID[pane.id] == nil else { return }
        guard let scrollbackStore else {
            _ = registerTerminalPlaceholderIfNeeded(for: pane, mode: .failedToStart)
            return
        }
        let generation = acceptedPreparedContentMountGeneration
        let resolver = TerminalRestoreKindResolver(
            sessionConfiguration: sessionConfig, scrollbackStore: scrollbackStore, store: store)
        terminalProtocolClassificationTasksByPaneID[pane.id] = Task { [weak self] in
            guard let self else { return }
            defer { terminalProtocolClassificationTasksByPaneID.removeValue(forKey: pane.id) }
            let kind = await resolver.resolveRestoreKind(for: pane)
            guard !Task.isCancelled, acceptedPreparedContentMountGeneration == generation,
                isCurrentTerminalPane(pane),
                let currentPane = store.paneAtom.pane(pane.id),
                let authority = terminalSurfaceCreationAuthority(for: currentPane)
            else { return }
            guard let kind else {
                _ = registerTerminalPlaceholderIfNeeded(for: currentPane, mode: .failedToStart)
                return
            }
            if case .incompatible(_, let plan) = kind {
                incompatibleTerminalPlansByPaneID[pane.id] = plan
                _ = registerTerminalPlaceholderIfNeeded(for: currentPane, mode: .incompatibleSessionVersion)
                return
            }
            if case .cold(let plan) = kind { coldRestartPlansByPaneID[pane.id] = plan }
            let frames = resolveInitialFramesByTabId(in: windowLifecycleStore.terminalContainerBounds)
            guard let frame = initialFrame(for: currentPane, resolvedPaneFramesByTabId: frames) else { return }
            if mountCurrentTerminalContent(
                pane: currentPane, initialFrame: frame,
                treatAsRestoredSessionStart: treatAsRestoredSessionStart, authority: authority,
                classifiedRestoreKind: kind) == nil
            {
                _ = registerTerminalPlaceholderIfNeeded(for: currentPane, mode: .failedToStart)
            }
        }
    }
}
