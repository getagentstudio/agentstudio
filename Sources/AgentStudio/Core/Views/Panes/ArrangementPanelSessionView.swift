import AgentStudioInfrastructure
import SwiftUI

/// Both launchers mount this same demanded session; closing removes its capture and worker.
package struct ArrangementPanelSessionView: View {
    let tabId: UUID
    let workspaceWindowId: UUID?
    let octiconLoader: OcticonLoader
    let inlineRenameState: ArrangementInlineRenameState
    let commandActionResolver: TargetedCommandControlActionResolver
    let onPaneAction: (WorkspaceActionCommand) -> Void
    let onDismiss: () -> Void
    let highlightPaneId: UUID?
    @State private var session: ArrangementPanelSession

    package init(
        tabId: UUID, workspaceWindowId: UUID?, octiconLoader: OcticonLoader,
        sources: ArrangementPanelSources, inlineRenameState: ArrangementInlineRenameState,
        commandActionResolver: @escaping TargetedCommandControlActionResolver,
        onPaneAction: @escaping (WorkspaceActionCommand) -> Void, onDismiss: @escaping () -> Void,
        highlightPaneId: UUID? = nil
    ) {
        self.tabId = tabId
        self.workspaceWindowId = workspaceWindowId
        self.octiconLoader = octiconLoader
        self.inlineRenameState = inlineRenameState
        self.commandActionResolver = commandActionResolver
        self.onPaneAction = onPaneAction
        self.onDismiss = onDismiss
        self.highlightPaneId = highlightPaneId
        _session = State(initialValue: ArrangementPanelSession(sources: sources))
    }

    package var body: some View {
        ArrangementPanel(
            tabId: tabId, workspaceWindowId: workspaceWindowId, octiconLoader: octiconLoader,
            panes: session.presentation?.panes ?? [], zoomMode: session.presentation?.zoomMode,
            arrangements: session.presentation?.arrangements ?? [], inlineRenameState: inlineRenameState,
            commandActionResolver: commandActionResolver, onPaneAction: onPaneAction, onDismiss: onDismiss,
            highlightPaneId: highlightPaneId, paneGroups: session.presentation?.groups ?? [],
            tableMetrics: session.presentation?.tableMetrics ?? .minimum
        )
        .task(id: tabId) {
            let producer = session.beginArrangementProjection(tabId: tabId)
            await withTaskCancellationHandler {
                await producer.value
            } onCancel: {
                producer.cancel()
            }
        }
        .onDisappear {
            // fire-and-forget: the SwiftUI task joins this producer; the next opening joins it too.
            _ = session.retireArrangementProjection()
        }
    }
}
