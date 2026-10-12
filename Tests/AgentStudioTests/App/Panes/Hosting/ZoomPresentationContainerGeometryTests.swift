import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioSharedComponents
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct ZoomPresentationContainerGeometryTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("Zoom management identity spans the full content above the toolbar")
    func zoomManagementIdentitySpansFullContentAboveToolbar() throws {
        let (frames, devicePixel) = mountedZoomManagementRegionFrames()
        let identityFrame = try #require(frames["paneManagement.identityStrip"])
        let sourceFrame = try #require(frames["zoom-source-region-probe"])
        let companionFrame = try #require(frames["zoom-companion-region-probe"])
        let toolbarFrame = try #require(frames["paneSurfaceToolbar.pane zoom"])

        #expect(identityFrame.maxX > companionFrame.minX)
        #expect(
            abs(
                companionFrame.maxX - identityFrame.maxX
                    - AppStyles.General.Spacing.loose
            ) < devicePixel
        )
        #expect(identityFrame.maxY <= toolbarFrame.minY)
        #expect(abs(sourceFrame.height - companionFrame.height) < devicePixel)
    }

    @Test("Zoom drawer outline sits on the terminal region bottom with no footer gap and no resize target")
    func zoomDrawerOutlineSitsOnTerminalRegionBottom() throws {
        let frames = try mountedZoomDrawerFrames(zoomSide: .terminal)
        let outline = try #require(frames.outline)
        let region = frames.terminalRegion
        let devicePixel = frames.devicePixel
        // The split area ends where the shared toolbar begins, so the complete
        // outline sitting on the region bottom leaves no gap above the toolbar.
        #expect(abs(outline.maxY - region.maxY) < devicePixel)
        #expect(outline.maxY <= frames.zoomToolbarButton.minY)
        // Upper 15% of the region stays exposed; 97% of its width, centered.
        #expect(abs(outline.minY - (region.minY + region.height * 0.15)) < devicePixel)
        #expect(abs(outline.width - region.width * 0.97) < devicePixel)
        #expect(abs(outline.midX - region.midX) < devicePixel)
        #expect(frames.hasResizeHandle == false)
    }

    @Test("Zoom drawer moved to Bridge fits the unequal Bridge region")
    func zoomDrawerOutlineFitsBridgeRegion() throws {
        let frames = try mountedZoomDrawerFrames(zoomSide: .bridge)
        let outline = try #require(frames.outline)
        let region = frames.bridgeRegion
        let devicePixel = frames.devicePixel

        #expect(abs(outline.maxY - region.maxY) < devicePixel)
        #expect(abs(outline.width - region.width * 0.97) < devicePixel)
        #expect(abs(outline.midX - region.midX) < devicePixel)
        #expect(outline.minX > region.minX)
        #expect(outline.maxX < region.maxX)
    }

    @Test("Zoom drawer paint and bootstrap resolve the same outline for the same input")
    func zoomDrawerPaintMatchesBootstrapGeometry() throws {
        for side in DrawerZoomSide.allCases {
            let frames = try mountedZoomDrawerFrames(zoomSide: side)
            let painted = try #require(frames.outline)
            let bootstrap = try bootstrapGeometry(zoomSide: side)
            let devicePixel = frames.devicePixel
            #expect(abs(painted.minX - bootstrap.outlineFrame.minX) < devicePixel, "\(side)")
            #expect(abs(painted.minY - bootstrap.outlineFrame.minY) < devicePixel, "\(side)")
            #expect(abs(painted.width - bootstrap.outlineFrame.width) < devicePixel, "\(side)")
            #expect(abs(painted.height - bootstrap.outlineFrame.height) < devicePixel, "\(side)")
        }
    }

    @Test("Zoom move tab stacks directly above the child's detach tab on both sides, clear of every child tab")
    func zoomMoveTabStacksAboveDetachOnBothSides() throws {
        for side in DrawerZoomSide.allCases {
            let frames = try mountedZoomDrawerFrames(zoomSide: side, managementLayerActive: true)
            let moveTab = try #require(frames.moveTab, "\(side)")
            let childAddTab = try #require(frames.childAddTab, "\(side)")
            let childDetachTab = try #require(frames.childDetachTab, "\(side)")
            let devicePixel = frames.devicePixel

            // Same column and size as detach, one standard gap above it.
            #expect(abs(moveTab.maxX - childDetachTab.maxX) < devicePixel, "\(side)")
            let expectedMaxY = childDetachTab.minY - AppStyles.General.Spacing.standard
            #expect(abs(moveTab.maxY - expectedMaxY) < devicePixel, "\(side)")
            #expect(moveTab.size == childDetachTab.size, "\(side)")
            // The globe tab stacks directly under the `+` tab in the same column.
            let childGlobeTab = childAddTab.offsetBy(
                dx: 0,
                dy: childAddTab.height + AppStyles.General.Spacing.standard
            )
            for childTab in [childAddTab, childGlobeTab, childDetachTab] {
                #expect(!moveTab.intersects(childTab), "\(side) overlaps \(childTab)")
            }
        }
    }

    /// Bootstrap derives the split area from the container and the shared
    /// toolbar metric, never from SwiftUI measurement.
    private func bootstrapGeometry(zoomSide: DrawerZoomSide) throws -> DrawerPresentationGeometry {
        let regions = DrawerPresentationGeometryResolver.zoomRegions(
            splitArea: CGRect(x: 0, y: 0, width: 1000, height: 640 - DrawerLayout.iconBarFrameHeight),
            sourceSplitRatio: 0.7,
            reservesCompanionSpace: true,
            isCompanionVisible: true
        )
        return try #require(
            DrawerPresentationGeometryResolver.resolve(
                DrawerPresentationGeometryInput(
                    containerBounds: CGRect(x: 0, y: 0, width: 1000, height: 640),
                    preference: DrawerPresentationPreference.default.replacingZoomSide(zoomSide),
                    placement: .zoom(terminalRegion: regions.terminal, visibleBridgeRegion: regions.bridge)
                )
            )
        )
    }

    private struct MountedZoomDrawerFrames {
        let outline: CGRect?
        let terminalRegion: CGRect
        let bridgeRegion: CGRect
        let zoomToolbarButton: CGRect
        let hasResizeHandle: Bool
        let moveTab: CGRect?
        let childAddTab: CGRect?
        let childDetachTab: CGRect?
        let devicePixel: CGFloat
    }

    /// Native layout snaps every edge to the device pixel grid, so painted
    /// frames agree with the resolver's exact arithmetic, and paint agrees with
    /// bootstrap, to within one device pixel: 1 pt at 1x (CI runners), 0.5 pt
    /// at 2x.
    private static func devicePixel(of hostingView: NSView) -> CGFloat {
        1 / (hostingView.window?.backingScaleFactor ?? 1)
    }

    private func mountedZoomDrawerFrames(
        zoomSide: DrawerZoomSide,
        managementLayerActive: Bool = false
    ) throws -> MountedZoomDrawerFrames {
        try withTestCoreAtoms { coreAtoms in
            let store = WorkspaceStore(
                identityAtom: coreAtoms.workspaceIdentity,
                windowMemoryAtom: coreAtoms.workspaceWindowMemory,
                repositoryTopologyAtom: coreAtoms.workspaceRepositoryTopology,
                paneAtom: coreAtoms.workspacePane,
                tabLayoutAtom: coreAtoms.workspaceTabLayout,
                mutationCoordinator: coreAtoms.workspaceMutationCoordinator,
                startsObserving: false
            )
            let sourcePane = store.createPane()
            let tab = Tab(paneId: sourcePane.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            let drawerChild = try #require(store.addDrawerPane(to: sourcePane.id))
            let viewRegistry = ViewRegistry()
            if managementLayerActive {
                // A mounted host renders the child's management edge tabs.
                viewRegistry.register(PaneHostView(paneId: drawerChild.id), for: drawerChild.id)
                atom(\.managementLayer).activate()
            } else {
                viewRegistry.ensureSlot(for: drawerChild.id)
            }
            #expect(store.paneAtom.pane(sourcePane.id)?.drawer?.isExpanded == true)
            store.paneAtom.setDrawerZoomSide(zoomSide, forOwner: sourcePane.id)
            let companionPaneId = UUIDv7.generate()

            let hostingView = NSHostingView(
                rootView: ZoomPresentationContainer(
                    tabId: tab.id,
                    sourcePaneId: sourcePane.id,
                    sourceOrdinal: 1,
                    sourceContent: AnyView(
                        Color.clear.background {
                            AccessibilityLabelBridge(identifier: "zoom-source-region-probe", label: "Source")
                        }
                    ),
                    companionContent: AnyView(
                        Color.clear.background {
                            AccessibilityLabelBridge(identifier: "zoom-companion-region-probe", label: "Companion")
                        }
                    ),
                    parentToolbarPresentation: .zoom(
                        ZoomToolbarModel(
                            viewerAction: probeAction(label: "Viewer"),
                            zoomAction: probeAction(label: "Pane Zoom")
                        )
                    ),
                    splitRatio: 0.7,
                    store: store,
                    octiconLoader: makeTestOcticonLoader(),
                    editorChooser: makeTestAtomRegistry().editorChooser,
                    actionDispatcher: makeNoOpPaneActionDispatcher(),
                    commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                    arrangementInlineRenameState: ArrangementInlineRenameState(),
                    onPaneFocusTrigger: { _ in },
                    viewRegistry: viewRegistry,
                    surfaceId: "zoom-drawer-geometry-test",
                    renderedPaneIds: [sourcePane.id, companionPaneId]
                )
                .frame(width: 1000, height: 640)
            )
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            defer {
                atom(\.managementLayer).deactivate()
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            // The first pass measures the split area; the second lays the
            // overlay out from those measured regions.
            hostingView.layoutSubtreeIfNeeded()
            hostingView.layoutSubtreeIfNeeded()

            @MainActor func frame(_ identifier: String) -> CGRect? {
                findView(in: hostingView, identifier: identifier).map { view in
                    view.convert(view.bounds, to: hostingView)
                }
            }
            return MountedZoomDrawerFrames(
                outline: frame(DrawerPanelOverlay.outlineAccessibilityIdentifier),
                terminalRegion: try #require(frame("zoom-source-region-probe")),
                bridgeRegion: try #require(frame("zoom-companion-region-probe")),
                zoomToolbarButton: try #require(frame("paneSurfaceToolbar.pane zoom")),
                hasResizeHandle: frame(DrawerResizeHandle.accessibilityIdentifier) != nil,
                moveTab: frame(DrawerPanelOverlay.moveControlAccessibilityIdentifier),
                childAddTab: frame("paneManagement.addPane"),
                childDetachTab: frame("paneManagement.detachDrawerPane"),
                devicePixel: Self.devicePixel(of: hostingView)
            )
        }
    }

    private func mountedZoomManagementRegionFrames() -> (frames: [String: CGRect], devicePixel: CGFloat) {
        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(filePath: "/tmp/agent-studio"))
        let worktree = Worktree(
            repoId: repo.id,
            name: "feature-name",
            path: URL(filePath: "/tmp/agent-studio/feature-name")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])
        let storedWorktree = store.repos[0].worktrees[0]
        let sourcePane = store.createPane(
            launchDirectory: storedWorktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                repoName: repo.name,
                worktreeId: storedWorktree.id,
                worktreeName: storedWorktree.name,
                cwd: storedWorktree.path
            )
        )
        let companionPaneId = UUIDv7.generate()
        let viewRegistry = ViewRegistry()
        let hostingView = NSHostingView(
            rootView: ZoomPresentationContainer(
                sourcePaneId: sourcePane.id,
                sourceOrdinal: 1,
                sourceContent: AnyView(
                    Color.clear.background {
                        AccessibilityLabelBridge(
                            identifier: "zoom-source-region-probe",
                            label: "Source"
                        )
                    }
                ),
                companionContent: AnyView(
                    Color.clear.background {
                        AccessibilityLabelBridge(
                            identifier: "zoom-companion-region-probe",
                            label: "Companion"
                        )
                    }
                ),
                parentToolbarPresentation: .zoom(
                    ZoomToolbarModel(
                        viewerAction: probeAction(label: "Viewer"),
                        zoomAction: probeAction(label: "Pane Zoom")
                    )
                ),
                splitRatio: 0.35,
                store: store,
                octiconLoader: makeTestOcticonLoader(),
                editorChooser: makeTestAtomRegistry().editorChooser,
                actionDispatcher: makeNoOpPaneActionDispatcher(),
                commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                arrangementInlineRenameState: ArrangementInlineRenameState(),
                onPaneFocusTrigger: { _ in },
                viewRegistry: viewRegistry,
                surfaceId: "zoom-management-identity-geometry-test",
                renderedPaneIds: [sourcePane.id, companionPaneId]
            )
            .frame(width: 640, height: 360)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        atom(\.managementLayer).activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            atom(\.managementLayer).deactivate()
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()

        let frames: [String: CGRect] = Dictionary(
            uniqueKeysWithValues: [
                "paneManagement.identityStrip",
                "zoom-source-region-probe",
                "zoom-companion-region-probe",
                "paneSurfaceToolbar.pane zoom",
            ].compactMap { identifier in
                guard let view = findView(in: hostingView, identifier: identifier) else {
                    return nil
                }
                return (identifier, view.convert(view.bounds, to: hostingView))
            }
        )
        return (frames, Self.devicePixel(of: hostingView))
    }

    private func probeAction(label: String) -> PaneSurfaceToolbarAction {
        PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: label,
                accessibilityIdentifier: "paneSurfaceToolbar.\(label.lowercased())",
                icon: .system(.rectangleSplit2x1),
                tooltip: ControlTooltipRenderValue(text: label, shortcutDisplayText: nil),
                isEnabled: true,
                isSelected: false
            ),
            perform: {}
        )
    }

    private func makeNoOpPaneActionDispatcher() -> PaneTabActionDispatcher {
        PaneTabActionDispatcher(
            dispatch: { _ in },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if root.identifier?.rawValue == identifier {
            return root
        }
        for subview in root.subviews {
            if let matchingView = findView(in: subview, identifier: identifier) {
                return matchingView
            }
        }
        return nil
    }
}
