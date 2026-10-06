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
        let input = RefreshInput(display: display, isDrawer: readers.isDrawerPane(paneId))
        Group {
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
