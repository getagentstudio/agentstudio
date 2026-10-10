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
struct ZoomPresentationContainerTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("Zoom management title preserves the pane, arrangement, and Zoom convention")
    func zoomManagementTitleUsesLiveArrangementConvention() {
        #expect(
            ZoomManagementTitle.text(
                sourceOrdinal: 1,
                activeArrangementName: "Default"
            ) == "1 · Default · Zoom"
        )
        #expect(
            ZoomManagementTitle.text(
                sourceOrdinal: 1,
                activeArrangementName: "Layout 1"
            ) == "1 · Layout 1 · Zoom"
        )
    }

    @Test("visible unavailable Viewer renders the watched-worktree boundary message")
    func visibleUnavailableViewerRendersBoundaryMessage() {
        let state = mountedSingleTabState(
            viewerPresentationOverride: .unavailableVisible
        )

        #expect(state.accessibilityIdentifiers.contains("zoomViewer.unavailable"))
    }

    @Test("mounted Zoom container renders optional companion under one parent toolbar")
    func mountedContainerRendersOneParentToolbar() {
        let visibleIdentifiers = mountedAccessibilityIdentifiers(
            companionContent: AnyView(
                AccessibilityPressBridge(
                    identifier: "zoom-companion-region-probe",
                    label: "Companion",
                    action: {}
                )
            )
        )

        #expect(visibleIdentifiers.filter { $0 == "zoom-source-region-probe" }.count == 1)
        #expect(visibleIdentifiers.filter { $0 == "zoom-companion-region-probe" }.count == 1)
        #expect(visibleIdentifiers.filter { $0 == "paneSurfaceToolbar.viewer" }.count == 1)
        #expect(visibleIdentifiers.filter { $0 == "paneSurfaceToolbar.zoom" }.count == 1)

        let hiddenIdentifiers = mountedAccessibilityIdentifiers(companionContent: nil)

        #expect(hiddenIdentifiers.filter { $0 == "zoom-source-region-probe" }.count == 1)
        #expect(!hiddenIdentifiers.contains("zoom-companion-region-probe"))
        #expect(hiddenIdentifiers.filter { $0 == "paneSurfaceToolbar.viewer" }.count == 1)
        #expect(hiddenIdentifiers.filter { $0 == "paneSurfaceToolbar.zoom" }.count == 1)
    }

    @Test("mounted Zoom toolbar omits each denied command without hiding the other")
    func mountedZoomToolbarOmitsDeniedCommandsIndependently() {
        let zoomOnlyIdentifiers = mountedAccessibilityIdentifiers(
            companionContent: nil,
            includesViewerAction: false
        )
        #expect(!zoomOnlyIdentifiers.contains("paneSurfaceToolbar.viewer"))
        #expect(zoomOnlyIdentifiers.filter { $0 == "paneSurfaceToolbar.zoom" }.count == 1)

        let viewerOnlyIdentifiers = mountedAccessibilityIdentifiers(
            companionContent: nil,
            includesZoomAction: false
        )
        #expect(viewerOnlyIdentifiers.filter { $0 == "paneSurfaceToolbar.viewer" }.count == 1)
        #expect(!viewerOnlyIdentifiers.contains("paneSurfaceToolbar.zoom"))
    }

    @Test("active per-tab Zoom replaces ordinary tab content with one parent toolbar")
    func activePerTabZoomReplacesOrdinaryTabContent() {
        let identifiers = mountedSingleTabAccessibilityIdentifiers()

        #expect(identifiers.filter { $0 == "paneSurfaceToolbar.viewer" }.count == 1)
        #expect(identifiers.filter { $0 == "paneSurfaceToolbar.zoom" }.count == 1)
    }

    @Test("Zoom owns ordered source toolbar controls and exact Management chrome")
    func zoomOwnsOrderedSourceToolbarControlsAndManagementChrome() {
        let identifiers = mountedSingleTabAccessibilityIdentifiers(
            viewerVisible: true,
            managementActive: true,
            paneInboxPresentation: makePaneInboxPresentation()
        )

        let toolbarIdentifiers = identifiers.filter { $0.hasPrefix("paneSurfaceToolbar.") }
        #expect(
            toolbarIdentifiers == [
                "paneSurfaceToolbar.drawerToggle",
                "paneSurfaceToolbar.drawerAdd",
                "paneSurfaceToolbar.pinPane",
                "paneSurfaceToolbar.note",
                "paneSurfaceToolbar.editor",
                "paneSurfaceToolbar.finder",
                "paneSurfaceToolbar.copyPath",
                "paneSurfaceToolbar.zoom",
                "paneSurfaceToolbar.viewer",
            ]
        )
        #expect(toolbarIdentifiers.filter { $0 == "paneSurfaceToolbar.drawerToggle" }.count == 1)
        #expect(toolbarIdentifiers.filter { $0 == "paneSurfaceToolbar.drawerAdd" }.count == 1)

        let managementIdentifiers = identifiers.filter {
            $0 == "paneManagement.zoom" || $0 == "paneManagement.showArrangements"
        }
        #expect(managementIdentifiers == ["paneManagement.zoom", "paneManagement.showArrangements"])
        #expect(identifiers.filter { $0 == "paneManagement.zoomTitle" }.count == 1)
        #expect(!identifiers.contains("paneManagement.cancelZoom"))
        #expect(!identifiers.contains("paneManagement.ordinal"))
        #expect(!identifiers.contains("paneManagement.zoomPill"))

        #expect(!identifiers.contains("paneManagement.minimize"))
        #expect(!identifiers.contains("paneManagement.close"))
        #expect(!identifiers.contains("paneManagement.dragHandle"))
        #expect(!identifiers.contains("paneManagement.addPane"))
        #expect(!identifiers.contains("paneManagement.openBrowser"))
    }

    @Test("normal terminal groups note and location controls before Zoom and Viewer")
    func normalPaneOrdersOwnedToolbarControls() {
        let state = mountedPaneLeafState(
            toolbarPresentation: PaneSurfaceToolbarResolver.resolve(
                content: .terminal(
                    TerminalState(
                        provider: .ghostty,
                        lifetime: .temporary,
                        zmxSessionID: .generateUUIDv7()
                    )
                ),
                placement: .normalMainPane,
                terminalModeActions: TerminalModeToolbarActions(
                    zoomAction: makeProbeAction(label: "Pane Zoom"),
                    viewerAction: makeProbeAction(label: "Viewer")
                )
            )
        )

        #expect(
            state.accessibilityIdentifiers.filter { $0.hasPrefix("paneSurfaceToolbar.") } == [
                "paneSurfaceToolbar.drawerToggle",
                "paneSurfaceToolbar.drawerAdd",
                "paneSurfaceToolbar.pinPane",
                "paneSurfaceToolbar.note",
                "paneSurfaceToolbar.editor",
                "paneSurfaceToolbar.finder",
                "paneSurfaceToolbar.copyPath",
                "paneSurfaceToolbar.zoom",
                "paneSurfaceToolbar.viewer",
            ]
        )
    }

    @Test("normal terminal toolbar has exact hit frames, group gaps, and separators")
    func normalTerminalToolbarGeometry() throws {
        let state = mountedPaneLeafState(
            toolbarPresentation: PaneSurfaceToolbarResolver.resolve(
                content: .terminal(
                    TerminalState(
                        provider: .ghostty,
                        lifetime: .temporary,
                        zmxSessionID: .generateUUIDv7()
                    )
                ),
                placement: .normalMainPane,
                terminalModeActions: TerminalModeToolbarActions(
                    zoomAction: makeProbeAction(label: "Pane Zoom"),
                    viewerAction: makeProbeAction(label: "Viewer")
                )
            ),
            paneInboxPresentation: makePaneInboxPresentation()
        )

        try expectToolbarGeometry(
            state.toolbarControlFrames,
            expectedControlOrder: [
                "paneSurfaceToolbar.drawerToggle",
                "paneSurfaceToolbar.drawerAdd",
                "paneSurfaceToolbar.pinPane",
                "paneSurfaceToolbar.note",
                "paneSurfaceToolbar.editor",
                "paneSurfaceToolbar.finder",
                "paneSurfaceToolbar.copyPath",
                "paneSurfaceToolbar.zoom",
                "paneSurfaceToolbar.viewer",
            ],
            paneModeIdentifiers: ["paneSurfaceToolbar.zoom", "paneSurfaceToolbar.viewer"]
        )
    }

    @Test("Copy Path copies the source terminal's actual CWD")
    func copyPathCopiesSourceTerminalCWD() async throws {
        let sourceCWD = URL(
            filePath: "/tmp/agentstudio-pane-toolbar/source-cwd",
            directoryHint: .isDirectory
        )
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let pane = harness.store.createPane(launchDirectory: sourceCWD)
        let tab = Tab(paneId: pane.id)
        harness.store.appendTab(tab)
        harness.store.setActiveTab(tab.id)

        try await withCommandDispatcher(
            harness.commandDispatcher,
            body: { _ in
                let hostingView = NSHostingView(
                    rootView: PaneSurfaceToolbarHost(
                        anchorPaneId: pane.id,
                        locationTargetPaneId: pane.id,
                        toolbarSurface: .pane,
                        drawer: nil,
                        leadingToolbarActions: [],
                        contextToolbarActions: [],
                        store: harness.store,
                        repoCache: harness.atomRegistry.core.repoCache,
                        octiconLoader: makeTestOcticonLoader(),
                        editorChooser: harness.atomRegistry.editorChooser,
                        paneInboxPresentation: nil,
                        workspaceWindowId: nil,
                        actionDispatcher: makeNoOpPaneActionDispatcher(),
                        commandDispatcher: harness.commandDispatcher, onPaneFocusTrigger: { _ in }
                    )
                    .frame(width: 640, height: 44)
                )
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 640, height: 44),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = hostingView
                window.makeKeyAndOrderFront(nil)
                defer {
                    window.orderOut(nil)
                    window.close()
                }
                hostingView.layoutSubtreeIfNeeded()

                let copyPathView = try #require(
                    zoomTestAccessibilityPressBridgeView(
                        in: hostingView,
                        identifier: "paneSurfaceToolbar.copyPath"
                    )
                )
                #expect(copyPathView.accessibilityPerformPress())
                #expect(
                    harness.launchRecorder.copiedPaths.map(\.standardizedFileURL) == [
                        sourceCWD.standardizedFileURL
                    ]
                )
            }
        )
    }

    @Test(
        "Zoom toolbar geometry is exact with Viewer hidden and visible",
        arguments: [false, true]
    )
    func zoomToolbarGeometry(viewerVisible: Bool) throws {
        let state = mountedSingleTabState(
            viewerVisible: viewerVisible,
            paneInboxPresentation: makePaneInboxPresentation()
        )

        try expectToolbarGeometry(
            state.toolbarControlFrames,
            expectedControlOrder: [
                "paneSurfaceToolbar.drawerToggle",
                "paneSurfaceToolbar.drawerAdd",
                "paneSurfaceToolbar.pinPane",
                "paneSurfaceToolbar.note",
                "paneSurfaceToolbar.editor",
                "paneSurfaceToolbar.finder",
                "paneSurfaceToolbar.copyPath",
                "paneSurfaceToolbar.zoom",
                "paneSurfaceToolbar.viewer",
            ],
            paneModeIdentifiers: ["paneSurfaceToolbar.zoom", "paneSurfaceToolbar.viewer"]
        )
    }

    @Test("ordinary main-pane Management omits Pane Zoom")
    func ordinaryMainPaneManagementOmitsPaneZoom() {
        let state = mountedPaneLeafState(
            toolbarPresentation: .terminal(
                TerminalToolbarModel(
                    modeActions: nil,
                    showArrangementsAction: makeProbeAction(label: "Show Arrangements")
                )
            ),
            managementActive: true
        )

        #expect(state.accessibilityIdentifiers.filter { $0 == "paneManagement.minimize" }.count == 1)
        #expect(state.accessibilityIdentifiers.filter { $0 == "paneManagement.close" }.count == 1)
        let managementIdentifiers = state.accessibilityIdentifiers.filter {
            $0 == "paneManagement.zoom" || $0 == "paneManagement.showArrangements"
        }
        #expect(managementIdentifiers == ["paneManagement.showArrangements"])
    }

    @Test("pane Show Arrangements action retains its source tab after active-tab change")
    func paneShowArrangementsActionRetainsSourceTabContext() throws {
        let presentation = ArrangementPanelPresentationAtom()
        let windowId = UUID()
        let harness = makeHarness(
            arrangementPanelPresentation: presentation,
            workspaceWindowId: windowId
        )
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let sourcePanes = (0..<2).map { index in
            harness.store.createPane(title: "Source Pane \(index + 1)")
        }
        let sourceTab = Tab(paneId: sourcePanes[0].id)
        harness.store.appendTab(sourceTab)
        harness.store.insertPane(
            sourcePanes[1].id,
            inTab: sourceTab.id,
            at: sourcePanes[0].id,
            direction: .horizontal,
            position: .after,
            sizingMode: .halveTarget
        )
        harness.store.setActiveTab(sourceTab.id)
        let destinationPane = harness.store.createPane()
        let destinationTab = Tab(paneId: destinationPane.id)
        harness.store.appendTab(destinationTab)

        let action = harness.controller.paneShowArrangementsAction(
            sourcePaneId: sourcePanes[0].id,
            sourceTabId: sourceTab.id
        )
        harness.store.setActiveTab(destinationTab.id)

        action.perform()

        #expect(action.state.label == "Show Arrangements")
        #expect(action.state.icon == .system(.rectangle3GroupFill))
        #expect(action.state.tooltip.text == "Show Arrangements (⌘⌥I)")
        #expect(action.state.isEnabled)
        #expect(presentation.pendingRequest?.tabId == sourceTab.id)
        #expect(presentation.pendingRequest?.workspaceWindowId == windowId)
    }

    @Test("hidden Zoom child toolbar reserves no leaf layout height or accessibility")
    func hiddenZoomChildToolbarIsStructurallyAbsent() {
        let hiddenState = mountedPaneLeafState(toolbarPresentation: .hidden)
        let ordinaryState = mountedPaneLeafState(
            toolbarPresentation: .terminal(
                TerminalToolbarModel(
                    modeActions: TerminalModeToolbarActions(
                        zoomAction: makeProbeAction(label: "NormalProbe"),
                        viewerAction: makeProbeAction(label: "Viewer")
                    )
                )
            )
        )

        #expect(hiddenState.contentHeight > ordinaryState.contentHeight)
        #expect(!hiddenState.accessibilityIdentifiers.contains("paneSurfaceToolbar.normalprobe"))
        #expect(ordinaryState.accessibilityIdentifiers.contains("paneSurfaceToolbar.normalprobe"))
    }

    @Test("Zoom management keeps the source worktree identity above the toolbar in every Viewer state")
    func zoomManagementKeepsSourceWorktreeIdentity() {
        for viewerVisible in [false, true] {
            let state = mountedSingleTabState(
                viewerVisible: viewerVisible,
                managementActive: true,
                worktreeBacked: true
            )

            #expect(state.accessibilityIdentifiers.contains("paneManagement.identityStrip"))
            #expect(!state.accessibilityIdentifiers.contains("paneManagement.movePaneToTab"))
        }
    }
}

extension ZoomPresentationContainerTests {
    private func mountedAccessibilityIdentifiers(
        companionContent: AnyView?,
        includesViewerAction: Bool = true,
        includesZoomAction: Bool = true
    ) -> [String] {
        let store = WorkspaceStore()
        let viewRegistry = ViewRegistry()
        let sourcePaneId = UUID()
        let companionPaneId = UUID()
        let hostingView = NSHostingView(
            rootView: ZoomPresentationContainer(
                sourcePaneId: sourcePaneId,
                sourceOrdinal: 1,
                sourceContent: AnyView(
                    AccessibilityPressBridge(
                        identifier: "zoom-source-region-probe",
                        label: "Source",
                        action: {}
                    )
                ),
                companionContent: companionContent,
                parentToolbarPresentation: .zoom(
                    ZoomToolbarModel(
                        viewerAction: includesViewerAction
                            ? makeProbeAction(label: "Viewer")
                            : nil,
                        zoomAction: includesZoomAction
                            ? makeProbeAction(label: "Pane Zoom")
                            : nil
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
                surfaceId: "zoom-container-mount-test",
                renderedPaneIds: companionContent == nil
                    ? [sourcePaneId]
                    : [sourcePaneId, companionPaneId]
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
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()

        return zoomTestAccessibilityIdentifiers(in: hostingView)
    }

    private func mountedSingleTabAccessibilityIdentifiers(
        viewerVisible: Bool = false,
        managementActive: Bool = false,
        paneInboxPresentation: PaneInboxPresentation? = nil
    ) -> [String] {
        mountedSingleTabState(
            viewerVisible: viewerVisible,
            managementActive: managementActive,
            paneInboxPresentation: paneInboxPresentation
        ).accessibilityIdentifiers
    }

    private func mountedSingleTabState(
        viewerVisible: Bool = false,
        viewerPresentationOverride: ZoomViewerPresentation? = nil,
        managementActive: Bool = false,
        worktreeBacked: Bool = false,
        paneInboxPresentation: PaneInboxPresentation? = nil
    ) -> MountedToolbarState {
        let store = WorkspaceStore()
        let sourcePane: Pane
        if worktreeBacked {
            let repo = store.addRepo(at: URL(filePath: "/tmp/agent-studio"))
            let worktree = Worktree(
                repoId: repo.id,
                name: "feature-name",
                path: URL(filePath: "/tmp/agent-studio/feature-name")
            )
            store.reconcileDiscoveredWorktrees(repo.id, worktrees: repo.worktrees + [worktree])
            let storedWorktree = worktree
            sourcePane = store.createPane(
                launchDirectory: storedWorktree.path,
                facets: PaneContextFacets(
                    repoId: repo.id,
                    repoName: repo.name,
                    worktreeId: storedWorktree.id,
                    worktreeName: storedWorktree.name,
                    cwd: storedWorktree.path
                )
            )
        } else {
            sourcePane = store.createPane()
        }
        if worktreeBacked {
            let managementContext = PaneManagementContext.project(
                paneId: sourcePane.id,
                store: store
            )
            #expect(managementContext.showsIdentityBlock)
            #expect(
                managementContext.identityRows.contains {
                    $0.id == "worktree" && $0.text == "feature-name"
                }
            )
        }
        let tab = Tab(paneId: sourcePane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let companionPaneId = UUID()
        let viewerPresentation =
            viewerPresentationOverride
            ?? (viewerVisible
                ? .retainedVisible(companionPaneId: companionPaneId)
                : .unavailable)
        store.panePresentationAtom.enterZoom(
            inTab: tab.id,
            sourcePaneId: sourcePane.id,
            viewerPresentation: viewerPresentation
        )

        let viewRegistry = ViewRegistry()
        viewRegistry.register(PaneHostView(paneId: sourcePane.id), for: sourcePane.id)
        if viewerPresentation.companionPaneId != nil {
            viewRegistry.register(PaneHostView(paneId: companionPaneId), for: companionPaneId)
        }
        let zoomToolbarPresentation = PaneSurfaceToolbarResolver.resolveZoom(
            viewerPresentation: viewerPresentation,
            viewerAction: makeProbeAction(label: "Viewer"),
            zoomAction: makeProbeAction(label: "Pane Zoom"),
            showArrangementsAction: makeProbeAction(label: "Show Arrangements")
        )
        if managementActive {
            atom(\.managementLayer).activate()
        }
        defer {
            if managementActive {
                atom(\.managementLayer).deactivate()
            }
        }
        let hostingView = NSHostingView(
            rootView: SingleTabContent(
                tabId: tab.id,
                octiconLoader: makeTestOcticonLoader(),
                store: store,
                repoCache: RepoCacheAtom(),
                editorChooser: makeTestAtomRegistry().editorChooser,
                viewRegistry: viewRegistry,
                heldPanePreviewState: HeldPanePreviewState(),
                appLifecycleStore: AppLifecycleAtom(),
                closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                actionDispatcher: makeNoOpPaneActionDispatcher(),
                commandDispatcher: AppTerminalFixtureCommandDispatcher(),
                arrangementInlineRenameState: ArrangementInlineRenameState(),
                onPaneFocusTrigger: { _ in },
                onFocusPane: { _ in },
                paneInboxPresentation: paneInboxPresentation,
                onOpenPaneGitHub: { _ in },
                paneSurfaceToolbarPresentation: { _ in .hidden },
                zoomPaneSurfaceToolbarPresentation: { _, _ in zoomToolbarPresentation }
            )
            .frame(width: 640, height: 360)
        )

        return mountedToolbarState(
            hostingView: hostingView,
            size: CGSize(width: 640, height: 360)
        )
    }

    private func mountedPaneLeafState(
        toolbarPresentation: PaneSurfaceToolbarPresentation,
        managementActive: Bool = false,
        paneInboxPresentation: PaneInboxPresentation? = nil
    ) -> MountedPaneLeafState {
        let store = WorkspaceStore()
        let pane = store.createPane()
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        if managementActive {
            atom(\.managementLayer).activate()
        }
        defer {
            if managementActive {
                atom(\.managementLayer).deactivate()
            }
        }

        let paneHost = PaneHostView(paneId: pane.id)
        let hostingView = NSHostingView(
            rootView: PaneLeafContainer(
                paneHost: paneHost,
                octiconLoader: makeTestOcticonLoader(),
                tabId: tab.id,
                isActive: true,
                isSplit: false,
                isSplitResizing: false,
                store: store,
                repoCache: RepoCacheAtom(),
                editorChooser: makeTestAtomRegistry().editorChooser,
                closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                actionDispatcher: makeNoOpPaneActionDispatcher(),
                commandDispatcher: AppTerminalFixtureCommandDispatcher(), onPaneFocusTrigger: { _ in },
                onOpenPaneGitHub: { _ in },
                paneInboxPresentation: paneInboxPresentation,
                toolbarPresentation: toolbarPresentation
            )
            .frame(width: 640, height: 360)
        )
        let mountedToolbarState = mountedToolbarState(
            hostingView: hostingView,
            size: CGSize(width: 640, height: 360)
        )

        return MountedPaneLeafState(
            contentHeight: paneHost.swiftUIContainer.frame.height,
            accessibilityIdentifiers: mountedToolbarState.accessibilityIdentifiers,
            toolbarControlFrames: mountedToolbarState.toolbarControlFrames
        )
    }

    private func makePaneInboxPresentation() -> PaneInboxPresentation {
        PaneInboxPresentation(
            unreadCount: { _ in 0 },
            clear: { _, _ in },
            open: { _, _ in },
            openRollUpAlerts: { _, _ in },
            toggle: { _, _ in },
            setPresented: { _, _, _ in },
            pendingRequest: { nil },
            clearRequest: { _ in },
            popoverContent: { _, _, _ in AnyView(Text("Pane inbox")) },
            pruneFilterModes: { _ in }
        )
    }

    private func mountedAccessibilityIdentifiers<Content: View>(
        hostingView: NSHostingView<Content>,
        size: CGSize
    ) -> [String] {
        mountedToolbarState(
            hostingView: hostingView,
            size: size
        ).accessibilityIdentifiers
    }

    private func mountedToolbarState<Content: View>(
        hostingView: NSHostingView<Content>,
        size: CGSize
    ) -> MountedToolbarState {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()

        return MountedToolbarState(
            accessibilityIdentifiers: zoomTestAccessibilityIdentifiers(in: hostingView),
            toolbarControlFrames: zoomTestToolbarControlFrames(in: hostingView)
        )
    }

    private func expectToolbarGeometry(
        _ controlFrames: [String: CGRect],
        expectedControlOrder: [String],
        paneModeIdentifiers: [String]
    ) throws {
        let actualControlOrder =
            controlFrames
            .sorted { lhs, rhs in lhs.value.minX < rhs.value.minX }
            .map(\.key)
        #expect(actualControlOrder == expectedControlOrder)

        for identifier in expectedControlOrder {
            let frame = try #require(controlFrames[identifier])
            #expect(abs(frame.height - DrawerLayout.iconButtonSize) < 0.5)
        }

        for identifier in [
            "paneSurfaceToolbar.viewer",
            "paneSurfaceToolbar.drawerToggle",
            "paneSurfaceToolbar.drawerAdd",
            "paneSurfaceToolbar.pinPane",
            "paneSurfaceToolbar.note",
            "paneSurfaceToolbar.finder",
            "paneSurfaceToolbar.copyPath",
        ] where expectedControlOrder.contains(identifier) {
            let frame = try #require(controlFrames[identifier])
            #expect(abs(frame.width - DrawerLayout.iconButtonSize) < 0.5)
            #expect(abs(frame.height - DrawerLayout.iconButtonSize) < 0.5)
        }

        let zoomFrame = try #require(controlFrames["paneSurfaceToolbar.zoom"])
        #expect(abs(zoomFrame.width - DrawerLayout.iconButtonSize) < 0.5)

        if paneModeIdentifiers.count == 2 {
            try expectHorizontalGap(
                between: paneModeIdentifiers[0],
                and: paneModeIdentifiers[1],
                equals: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing,
                in: controlFrames
            )
        }

        try expectHorizontalGap(
            between: "paneSurfaceToolbar.drawerToggle",
            and: "paneSurfaceToolbar.drawerAdd",
            equals: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing,
            in: controlFrames
        )
        try expectHorizontalGap(
            between: "paneSurfaceToolbar.finder",
            and: "paneSurfaceToolbar.copyPath",
            equals: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing,
            in: controlFrames
        )
        try expectHorizontalGap(
            between: "paneSurfaceToolbar.drawerAdd",
            and: "paneSurfaceToolbar.pinPane",
            equals: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing,
            in: controlFrames
        )
        try expectHorizontalGap(
            between: "paneSurfaceToolbar.pinPane",
            and: "paneSurfaceToolbar.note",
            equals: expectedToolbarSeparatorWidth,
            in: controlFrames
        )
        try expectHorizontalGap(
            between: "paneSurfaceToolbar.editor",
            and: "paneSurfaceToolbar.finder",
            equals: AppStyles.Shell.DrawerToolbar.trailingClusterSpacing,
            in: controlFrames
        )
        try expectHorizontalGap(
            between: "paneSurfaceToolbar.copyPath",
            and: paneModeIdentifiers[0],
            equals: expectedToolbarSeparatorWidth,
            in: controlFrames
        )
    }

    private var expectedToolbarSeparatorWidth: CGFloat {
        (AppStyles.Shell.DrawerToolbar.dividerHorizontalPadding * 2) + 1
    }

    private func expectHorizontalGap(
        between leadingIdentifier: String,
        and trailingIdentifier: String,
        equals expectedGap: CGFloat,
        in controlFrames: [String: CGRect]
    ) throws {
        let leadingFrame = try #require(controlFrames[leadingIdentifier])
        let trailingFrame = try #require(controlFrames[trailingIdentifier])
        #expect(abs(trailingFrame.minX - leadingFrame.maxX - expectedGap) < 0.5)
    }

    private func makeNoOpPaneActionDispatcher() -> PaneTabActionDispatcher {
        PaneTabActionDispatcher(
            dispatch: { _ in },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )
    }

    private func makeProbeAction(label: String) -> PaneSurfaceToolbarAction {
        PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: label,
                accessibilityIdentifier: "paneSurfaceToolbar.\(label == "Pane Zoom" ? "zoom" : label.lowercased())",
                icon: .system(.rectangleSplit2x1),
                tooltip: ControlTooltipRenderValue(text: label, shortcutDisplayText: nil),
                isEnabled: true,
                isSelected: false
            ),
            perform: {}
        )
    }

}
