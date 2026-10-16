import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

struct PaneContextToolbarControls: View {
    struct RefreshInput: Equatable {
        let display: PaneContextDisplay?
        let isDrawer: Bool
        let agentStatus: PaneAgentStatusPresentation?
    }
    let paneId: PaneId
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    @State private var messageChip: PaneMessageChipModel?
    @State private var statusLine: RepoExplorerPaneContextLine?
    @State private var connectionLine: RepoExplorerPaneContextLine?

    var body: some View {
        let display = readers.contextDisplayForPane(paneId)
        let input = RefreshInput(
            display: display, isDrawer: readers.isDrawerPane(paneId), agentStatus: readers.sessionStatusForPane(paneId))
        VStack(alignment: .leading, spacing: AppStyles.Shell.Sidebar.rowContentSpacing) {
            if let statusLine {
                RepoExplorerPaneContextLineView(line: statusLine, isAgentLine: false, octiconLoader: octiconLoader)
            }
            if let connectionLine {
                RepoExplorerPaneContextLineView(line: connectionLine, isAgentLine: false, octiconLoader: octiconLoader)
            }
            if display != nil, let messageChip {
                PaneContextPopoverHost(
                    paneId: paneId, presentation: .messages(messageChip), location: .pane, readers: readers,
                    octiconLoader: octiconLoader, onGoToPane: onGoToPane, includingDrawers: !input.isDrawer)
            }
        }
        .task(id: input) {
            let shaped = await Self.shapeMessages(display: input.display, isDrawer: input.isDrawer)
            guard !Task.isCancelled else { return }
            let lines = await Self.shapeStatus(input.agentStatus)
            guard !Task.isCancelled else { return }
            messageChip = shaped
            statusLine = lines.status
            connectionLine = lines.connection
        }
    }

    @concurrent nonisolated static func shapeStatus(_ presentation: PaneAgentStatusPresentation?) async
        -> (status: RepoExplorerPaneContextLine?, connection: RepoExplorerPaneContextLine?)
    {
        (
            presentation.flatMap { RepoExplorerPaneContextLine.session($0.status) },
            presentation.flatMap(\.connectionIssue).map(RepoExplorerPaneContextLine.connection)
        )
    }

    @concurrent nonisolated static func shapeMessages(display: PaneContextDisplay?, isDrawer: Bool) async
        -> PaneMessageChipModel?
    {
        display.map { RepoExplorerPaneMessageCountProjection.make(display: $0, isDrawer: isDrawer) }
    }
}
