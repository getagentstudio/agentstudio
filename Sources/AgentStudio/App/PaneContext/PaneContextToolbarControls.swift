import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import SwiftUI

struct PaneContextToolbarControls: View {
    struct RefreshInput: Equatable {
        let display: PaneContextDisplay?
        let isDrawer: Bool
    }
    let paneId: PaneId
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    @State private var messageChip: PaneMessageChipModel?

    var body: some View {
        let display = readers.contextDisplayForPane(paneId)
        let input = RefreshInput(
            display: display, isDrawer: readers.isDrawerPane(paneId))
        VStack(alignment: .leading, spacing: AppStyles.Shell.Sidebar.rowContentSpacing) {
            if display != nil, let messageChip {
                PaneContextPopoverHost(
                    paneId: paneId, presentation: .messages(messageChip), location: .pane, readers: readers,
                    octiconLoader: octiconLoader, onGoToPane: onGoToPane, includingDrawers: !input.isDrawer)
            }
        }
        .task(id: input) {
            let shaped = await Self.shapeMessages(display: input.display, isDrawer: input.isDrawer)
            guard !Task.isCancelled else { return }
            messageChip = shaped
        }
    }

    @concurrent nonisolated static func shapeMessages(display: PaneContextDisplay?, isDrawer: Bool) async
        -> PaneMessageChipModel?
    {
        display.map { RepoExplorerPaneMessageCountProjection.make(display: $0, isDrawer: isDrawer) }
    }
}

/// The sidebar's keyed Agent Line, rendered as a readout without an action or help.
struct PaneContextToolbarAgentLine: View {
    let paneId: PaneId
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader

    var body: some View {
        if let detail = readers.contextDisplayForPane(paneId)?.agentLine {
            RepoExplorerPaneContextLineView(
                line: .agent(detail), isAgentLine: true, octiconLoader: octiconLoader, showsTooltip: false
            )
            .background {
                AccessibilityLabelBridge(
                    identifier: "paneSurfaceToolbar.agentLine", label: detail.summary, role: .staticText)
            }
        }
    }
}
