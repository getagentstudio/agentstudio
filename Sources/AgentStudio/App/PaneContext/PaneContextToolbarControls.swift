import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation
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
struct PaneContextToolbarAgentLine<AgeClock: Clock>: View
where AgeClock.Duration == Duration, AgeClock.Instant == ContinuousClock.Instant {
    let paneId: PaneId
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader
    let clock: AgeClock
    let wallNow: Date?
    @State private var relativeTimeRefresh: PaneRelativeTimeRefresh

    init(
        paneId: PaneId, readers: PaneContextUIReaders, octiconLoader: OcticonLoader,
        clock: AgeClock, wallNow: Date? = nil,
        onRelativeTimeEvent: @escaping @MainActor @Sendable (PaneRelativeTimeRefresh.Event) -> Void = { _ in }
    ) {
        self.paneId = paneId
        self.readers = readers
        self.octiconLoader = octiconLoader
        self.clock = clock
        self.wallNow = wallNow
        _relativeTimeRefresh = State(initialValue: PaneRelativeTimeRefresh(onEvent: onRelativeTimeEvent))
    }

    var body: some View {
        let detail = readers.contextDisplayForPane(paneId)?.agentLine
        ZStack(alignment: .leading) {
            if let detail, let presentation = relativeTimeRefresh.presentation,
                case .agentLine(let line)? = presentation.lines.first
            {
                RepoExplorerPaneContextLineView(
                    line: line, isAgentLine: true, octiconLoader: octiconLoader, showsTooltip: false
                )
                .background {
                    AccessibilityLabelBridge(
                        identifier: "paneSurfaceToolbar.agentLine", label: detail.summary, role: .staticText)
                }
            }
        }
        .onAppear { refresh(detail) }
        .onChange(of: detail) { _, changed in refresh(changed) }
        .onDisappear { relativeTimeRefresh.hide() }
    }

    private func refresh(_ detail: AgentLineDetail?) {
        if let detail {
            relativeTimeRefresh.startOrReplace(
                .message(paneId: paneId.uuid, detail: detail), clock: clock, wallNow: wallNow)
        } else {
            relativeTimeRefresh.hide()
        }
    }
}

extension PaneContextToolbarAgentLine where AgeClock == ContinuousClock {
    init(paneId: PaneId, readers: PaneContextUIReaders, octiconLoader: OcticonLoader) {
        self.init(paneId: paneId, readers: readers, octiconLoader: octiconLoader, clock: ContinuousClock())
    }
}
