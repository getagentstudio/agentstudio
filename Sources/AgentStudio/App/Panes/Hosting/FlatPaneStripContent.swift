import AgentStudioCore
import AgentStudioEditorChooser
import AgentStudioInfrastructure
import SwiftUI
import os.log

private let flatPaneStripLogger = Logger(subsystem: "com.agentstudio", category: "FlatPaneStripContent")

enum PaneSegmentMissingHostDisposition: Equatable {
    case deferredInitialRestore
    case deferredInactiveTabRestore
    case retiredTransition
    case unexpectedMissingHost

    static func resolve(isRetired: Bool, isInitialRestorePending: Bool, isInactivePersistentTab: Bool) -> Self {
        if isRetired {
            return .retiredTransition
        }
        if isInitialRestorePending {
            return .deferredInitialRestore
        }
        if isInactivePersistentTab {
            return .deferredInactiveTabRestore
        }
        return .unexpectedMissingHost
    }
}

struct FlatPaneStripContent: View {
    let layout: AgentStudioCore.Layout
    let octiconLoader: OcticonLoader
    let tabId: UUID
    let activePaneId: UUID?
    let minimizedPaneIds: Set<UUID>
    let adjacentResizeTargeting: FlatTabStripMetrics.AdjacentResizeTargeting
    let ordinalMap: PaneOrdinalMap
    let collapsedPaneWidth: CGFloat
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let commandActionResolver: TargetedCommandControlActionResolver
    let commandDispatcher: any AppCommandDispatching
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let actionDispatcher: PaneActionDispatching
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusPane: (UUID) -> Void
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let viewRegistry: ViewRegistry
    let coordinateSpaceName: String?
    let useDrawerFramePreference: Bool
    let isInactivePersistentTab: Bool
    let paneInboxPresentation: PaneInboxPresentation?
    let paneNotePresentation: PaneNotePresentation?
    let onOpenPaneGitHub: (UUID) -> Void
    let workspaceWindowId: UUID?
    let paneSurfaceToolbarPresentation: (UUID) -> PaneSurfaceToolbarPresentation
    @State private var isSplitResizing = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = FlatTabStripMetrics.compute(
                layout: layout,
                in: CGRect(origin: .zero, size: geometry.size),
                dividerThickness: AppStyles.General.Layout.paneGap,
                minimizedPaneIds: minimizedPaneIds,
                collapsedPaneWidth: collapsedPaneWidth,
                adjacentResizeTargeting: adjacentResizeTargeting
            )
            // swiftlint:disable:next redundant_discardable_let
            let _ = RestoreTrace.log(
                "FlatPaneStripContent.body paneCount=\(layout.panes.count) segmentCount=\(metrics.paneSegments.count) geoSize=\(NSStringFromSize(geometry.size))"
            )

            if metrics.allMinimized {
                if collapsedPaneWidth > 0 {
                    HStack(spacing: 0) {
                        ForEach(layout.paneIds, id: \.self) { paneId in
                            CollapsedPaneBar(
                                paneId: paneId,
                                octiconLoader: octiconLoader,
                                tabId: tabId,
                                closeTransitionCoordinator: closeTransitionCoordinator,
                                actionDispatcher: actionDispatcher,
                                arrangementInlineRenameState: arrangementInlineRenameState,
                                commandActionResolver: commandActionResolver,
                                onFocus: { onFocusPane(paneId) },
                                dropTargetCoordinateSpace: coordinateSpaceName,
                                useDrawerFramePreference: useDrawerFramePreference,
                                workspaceWindowId: workspaceWindowId
                            )
                            .frame(width: collapsedPaneWidth)
                        }
                        Spacer()
                    }
                }
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(metrics.paneSegments, id: \.paneId) { segment in
                        let paneSlot = viewRegistry.slot(for: segment.paneId)
                        PaneSegmentSlotView(
                            segment: segment,
                            octiconLoader: octiconLoader,
                            tabId: tabId,
                            activePaneId: activePaneId,
                            layout: layout,
                            collapsedPaneWidth: collapsedPaneWidth,
                            arrangementInlineRenameState: arrangementInlineRenameState,
                            commandActionResolver: commandActionResolver,
                            commandDispatcher: commandDispatcher,
                            closeTransitionCoordinator: closeTransitionCoordinator,
                            actionDispatcher: actionDispatcher,
                            onPaneFocusTrigger: onPaneFocusTrigger,
                            onFocusPane: onFocusPane,
                            store: store,
                            repoCache: repoCache,
                            editorChooser: editorChooser,
                            isSplitResizing: isSplitResizing,
                            coordinateSpaceName: coordinateSpaceName,
                            useDrawerFramePreference: useDrawerFramePreference,
                            isInactivePersistentTab: isInactivePersistentTab,
                            paneInboxPresentation: paneInboxPresentation,
                            paneNotePresentation: paneNotePresentation,
                            onOpenPaneGitHub: onOpenPaneGitHub,
                            viewRegistry: viewRegistry,
                            paneSlot: paneSlot,
                            ordinal: ordinalMap.ordinal(forPaneId: segment.paneId),
                            workspaceWindowId: workspaceWindowId,
                            paneSurfaceToolbarPresentation: paneSurfaceToolbarPresentation
                        )
                        // ForEach owns stable pane identity. Host arrival updates the slot;
                        // only PaneLeafContainer replaces the representable for a new host.
                        .frame(width: segment.frame.width, height: segment.frame.height)
                        .offset(x: segment.frame.minX, y: segment.frame.minY)
                    }

                    ForEach(metrics.dividerSegments, id: \.dividerId) { divider in
                        FlatPaneDivider(
                            dividerId: divider.dividerId,
                            frame: divider.frame,
                            resizeIntent: divider.resizeIntent,
                            resizeLeftPaneWidth: divider.resizeLeftPaneWidth,
                            resizeRightPaneWidth: divider.resizeRightPaneWidth,
                            layout: layout,
                            isSplitResizing: $isSplitResizing,
                            tabId: tabId,
                            actionDispatcher: actionDispatcher
                        )
                    }
                }
            }
        }
    }
}

private struct PaneSegmentSlotView: View {
    let segment: FlatTabStripMetrics.PaneSegment
    let octiconLoader: OcticonLoader
    let tabId: UUID
    let activePaneId: UUID?
    let layout: AgentStudioCore.Layout
    let collapsedPaneWidth: CGFloat
    let arrangementInlineRenameState: ArrangementInlineRenameState
    let commandActionResolver: TargetedCommandControlActionResolver
    let commandDispatcher: any AppCommandDispatching
    let closeTransitionCoordinator: PaneCloseTransitionCoordinator
    let actionDispatcher: PaneActionDispatching
    let onPaneFocusTrigger: PaneFocusTriggerHandler
    let onFocusPane: (UUID) -> Void
    let store: WorkspaceStore
    let repoCache: RepoCacheAtom
    let editorChooser: EditorChooserState
    let isSplitResizing: Bool
    let coordinateSpaceName: String?
    let useDrawerFramePreference: Bool
    let isInactivePersistentTab: Bool
    let paneInboxPresentation: PaneInboxPresentation?
    let paneNotePresentation: PaneNotePresentation?
    let onOpenPaneGitHub: (UUID) -> Void
    let viewRegistry: ViewRegistry
    @Bindable var paneSlot: ViewRegistry.PaneViewSlot
    let ordinal: Int?
    let workspaceWindowId: UUID?
    let paneSurfaceToolbarPresentation: (UUID) -> PaneSurfaceToolbarPresentation

    var body: some View {
        ZStack {
            if segment.isMinimized {
                if collapsedPaneWidth > 0 {
                    CollapsedPaneBar(
                        paneId: segment.paneId,
                        octiconLoader: octiconLoader,
                        tabId: tabId,
                        closeTransitionCoordinator: closeTransitionCoordinator,
                        actionDispatcher: actionDispatcher,
                        arrangementInlineRenameState: arrangementInlineRenameState,
                        commandActionResolver: commandActionResolver,
                        onFocus: { onFocusPane(segment.paneId) },
                        dropTargetCoordinateSpace: coordinateSpaceName,
                        useDrawerFramePreference: useDrawerFramePreference,
                        workspaceWindowId: workspaceWindowId
                    )
                }
            } else if let paneHost = paneSlot.host {
                PaneLeafContainer(
                    paneHost: paneHost,
                    octiconLoader: octiconLoader,
                    tabId: tabId,
                    isActive: segment.paneId == activePaneId,
                    isSplit: layout.isSplit,
                    isSplitResizing: isSplitResizing,
                    store: store,
                    repoCache: repoCache,
                    editorChooser: editorChooser,
                    closeTransitionCoordinator: closeTransitionCoordinator,
                    actionDispatcher: actionDispatcher,
                    commandDispatcher: commandDispatcher,
                    onPaneFocusTrigger: onPaneFocusTrigger,
                    onOpenPaneGitHub: onOpenPaneGitHub,
                    dropTargetCoordinateSpace: coordinateSpaceName,
                    useDrawerFramePreference: useDrawerFramePreference,
                    paneInboxPresentation: paneInboxPresentation,
                    paneNotePresentation: paneNotePresentation,
                    ordinal: ordinal,
                    workspaceWindowId: workspaceWindowId,
                    toolbarPresentation: paneSurfaceToolbarPresentation(segment.paneId)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
            } else {
                switch PaneSegmentMissingHostDisposition.resolve(
                    isRetired: viewRegistry.isRetired(for: segment.paneId),
                    isInitialRestorePending: viewRegistry.isInitialRestorePending,
                    isInactivePersistentTab: isInactivePersistentTab
                ) {
                case .deferredInitialRestore:
                    Color.clear

                case .deferredInactiveTabRestore:
                    Color.clear

                case .retiredTransition:
                    Color.clear

                case .unexpectedMissingHost:
                    UnexpectedMissingPaneHostPlaceholder(paneId: segment.paneId)
                }
            }
        }
    }
}

private struct UnexpectedMissingPaneHostPlaceholder: View {
    let paneId: UUID

    var body: some View {
        Color.clear
            .onAppear {
                Self.reportUnexpectedMissingHost(paneId: paneId)
            }
    }

    private static func reportUnexpectedMissingHost(paneId: UUID) {
        let message = "FlatPaneStripContent: missing host for non-retired pane \(paneId)"
        flatPaneStripLogger.error(
            "FlatPaneStripContent: missing host for non-retired pane \(paneId.uuidString, privacy: .public)"
        )
        RestoreTrace.log(message)
    }
}
