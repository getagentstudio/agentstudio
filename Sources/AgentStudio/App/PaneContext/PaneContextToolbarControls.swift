import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation
import SwiftUI

/// One visible selection, shaped by the existing relative-time worker.
struct PaneContextToolbarControls<AgeClock: Clock>: View
where AgeClock.Duration == Duration, AgeClock.Instant == ContinuousClock.Instant {
    struct RefreshInput: Equatable {
        let display: PaneContextDisplay?
        let isDrawer: Bool
    }
    let paneId: PaneId
    let readers: PaneContextUIReaders
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    let clock: AgeClock
    let wallNow: Date?
    @State private var relativeTimeRefresh: PaneRelativeTimeRefresh

    init(
        paneId: PaneId, readers: PaneContextUIReaders, octiconLoader: OcticonLoader,
        clock: AgeClock, wallNow: Date? = nil,
        onRelativeTimeEvent: PaneRelativeTimeRefresh.Observer? = nil,
        onRelativeTimeReady: @escaping PaneRelativeTimeRefresh.PresentationReadyObserver = { _, _ in },
        onGoToPane: @escaping @MainActor (UUID) -> Void
    ) {
        self.paneId = paneId
        self.readers = readers
        self.octiconLoader = octiconLoader
        self.clock = clock
        self.wallNow = wallNow
        self.onGoToPane = onGoToPane
        _relativeTimeRefresh = State(
            initialValue: PaneRelativeTimeRefresh(
                onEvent: onRelativeTimeEvent, onPresentationReady: onRelativeTimeReady))
    }

    var body: some View {
        let input = RefreshInput(display: readers.contextDisplayForPane(paneId), isDrawer: readers.isDrawerPane(paneId))
        ZStack(alignment: .leading) {
            if let prepared = relativeTimeRefresh.presentation {
                ViewThatFits(in: .horizontal) {
                    minimumContents(prepared)
                        .hidden()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            renderedContents(prepared, isDrawer: input.isDrawer)
                        }
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Color.clear.frame(width: 0, height: 0)
        }
        .background {
            if let prepared = relativeTimeRefresh.presentation,
                let application = relativeTimeRefresh.application(for: .pane(prepared))
            {
                NativePresentationApplication(
                    value: application, onApplied: relativeTimeRefresh.didApply,
                    onRetired: relativeTimeRefresh.didRetire)
            }
        }
        .onAppear { refresh(input) }
        .onChange(of: input) { _, changed in refresh(changed) }
        .onDisappear { relativeTimeRefresh.hide() }
    }

    @ViewBuilder private func minimumContents(_ prepared: PaneManagementIdentityCapture.Presentation) -> some View {
        switch prepared.toolbarItem {
        case .none: Color.clear.frame(width: 0, height: 0)
        case .chips(let chips):
            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                divider(exposesIdentity: false)
                ForEach(chips, id: \.kind) { chip in
                    PaneMessageKindChip(
                        model: chip, control: RepoExplorerPaneKindChipProjection.control(chip),
                        octiconLoader: octiconLoader, onOpen: {}
                    ).minimumSizeContent
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        case .agentLine:
            if case .agentLine(let line)? = prepared.lines.first {
                HStack(spacing: 0) {
                    divider(exposesIdentity: false)
                    line.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.Shell.Sidebar.branchIconSize)
                        .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, alignment: .leading)
                    Color.clear.frame(width: AppStyles.Shell.Sidebar.groupIconTitleSpacing, height: 0)
                    Text("… " + (line.ageText ?? ""))
                        .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                        .fixedSize()
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    @ViewBuilder private func renderedContents(
        _ prepared: PaneManagementIdentityCapture.Presentation, isDrawer: Bool
    ) -> some View {
        switch prepared.toolbarItem {
        case .none: EmptyView()
        case .chips(let chips):
            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                divider(exposesIdentity: true)
                ForEach(chips, id: \.kind) { chip in
                    PaneContextPopoverHost(
                        paneId: paneId, presentation: .kind(chip), location: .pane, readers: readers,
                        octiconLoader: octiconLoader, onGoToPane: onGoToPane, includingDrawers: !isDrawer)
                }
            }.fixedSize()
        case .agentLine:
            if case .agentLine(let line)? = prepared.lines.first {
                HStack(spacing: 0) {
                    divider(exposesIdentity: true)
                    RepoExplorerPaneContextLineView(
                        line: line, isAgentLine: true, octiconLoader: octiconLoader, showsTooltip: false,
                        maximumTextWidth: AppStyles.Shell.DrawerToolbar.agentLineMaxWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    AccessibilityLabelBridge(
                        identifier: "paneSurfaceToolbar.agentLine", label: line.text, role: .staticText)
                }
            }
        }
    }

    private func divider(exposesIdentity: Bool) -> some View {
        Divider()
            .frame(
                width: AppStyles.Shell.DrawerToolbar.dividerWidth, height: AppStyles.Shell.DrawerToolbar.dividerHeight
            )
            .background {
                if exposesIdentity {
                    AccessibilityLabelBridge(
                        identifier: "paneSurfaceToolbar.contextDivider", label: "", role: .staticText)
                }
            }
            .padding(.horizontal, AppStyles.Shell.DrawerToolbar.dividerHorizontalPadding)
    }

    private func refresh(_ input: RefreshInput) {
        relativeTimeRefresh.startOrReplace(
            .toolbar(paneId: paneId.uuid, display: input.display, isDrawer: input.isDrawer),
            clock: clock, wallNow: wallNow)
    }
}

extension PaneContextToolbarControls where AgeClock == ContinuousClock {
    init(
        paneId: PaneId, readers: PaneContextUIReaders, octiconLoader: OcticonLoader,
        onGoToPane: @escaping @MainActor (UUID) -> Void
    ) {
        self.init(
            paneId: paneId, readers: readers, octiconLoader: octiconLoader,
            clock: ContinuousClock(), onGoToPane: onGoToPane)
    }
}
