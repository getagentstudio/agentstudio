import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite(.serialized)
struct PaneManagementTrailingControlTests {
    init() {
        installTestAtomRegistryIfNeeded()
    }

    @Test("main panes use Move to Tab while drawer panes retain Detach")
    func paneManagementTrailingControlMatchesPaneResidency() {
        #expect(PaneManagementTrailingControl.resolve(isDrawerChild: false) == .movePaneToTab)
        #expect(PaneManagementTrailingControl.resolve(isDrawerChild: true) == .detachDrawerPane)
    }

    @Test("Move and Detach use the same management edge-tab geometry")
    func moveAndDetachShareManagementEdgeTabGeometry() throws {
        let moveState = try mountedTrailingControlState(isDrawerChild: false)
        let detachState = try mountedTrailingControlState(isDrawerChild: true)
        let expectedSize = CGSize(
            width: AppStyles.Shell.PaneChrome.paneSplitButtonSize,
            height: AppStyles.Shell.PaneChrome.paneEdgeButtonHeight
        )

        #expect(moveState.controlFrame.size == expectedSize)
        #expect(detachState.controlFrame.size == expectedSize)
    }

    @Test("main-pane Move keeps standard spacing above the identity card")
    func moveControlAnchorsAboveIdentityCard() throws {
        let state = try mountedTrailingControlState(
            isDrawerChild: false,
            worktreeBacked: true
        )
        let identityFrame = try #require(state.identityFrame)

        #expect(
            abs(
                identityFrame.minY - state.controlFrame.maxY
                    - AppStyles.General.Spacing.standard
            ) < 0.5
        )
        #expect(
            abs(
                state.controlFrame.maxX
                    - (state.hostingBounds.maxX - AppStyles.General.Layout.paneGap)
            ) < 0.5
        )
    }

    @Test("main-pane Move accessibility action is disabled without destinations")
    func moveAccessibilityActionMatchesDestinationAvailability() throws {
        let state = try mountedTrailingControlState(
            isDrawerChild: false,
            hasMoveDestination: false
        )

        #expect(!state.isAccessibilityEnabled)
    }

    @Test("management identity overlays pane content above the reserved toolbar")
    func managementIdentityOverlaysPaneContentAboveReservedToolbar() async throws {
        let store = WorkspaceStore()
        let repo = store.addRepo(at: URL(filePath: "/tmp/agent-studio"))
        let worktree = Worktree(
            repoId: repo.id,
            name: "feature-name",
            path: URL(filePath: "/tmp/agent-studio/feature-name")
        )
        store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])
        let storedWorktree = store.repos[0].worktrees[0]
        let pane = store.createPane(
            launchDirectory: storedWorktree.path,
            facets: PaneContextFacets(
                repoId: repo.id,
                repoName: repo.name,
                worktreeId: storedWorktree.id,
                worktreeName: storedWorktree.name,
                cwd: storedWorktree.path
            )
        )
        let tab = Tab(paneId: pane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        let paneHost = PaneHostView(paneId: pane.id)
        paneHost.mountContentView(ManagementIdentityBackdropProbeView())

        atom(\.managementLayer).deactivate()
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
                toolbarPresentation: .terminal(TerminalToolbarModel())
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
            atom(\.managementLayer).deactivate()
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        let inactiveContentFrame = paneHost.swiftUIContainer.convert(
            paneHost.swiftUIContainer.bounds,
            to: hostingView
        )

        atom(\.managementLayer).activate()
        await eventually(
            "management identity should render after activating management mode"
        ) {
            hostingView.layoutSubtreeIfNeeded()
            return findAccessibilityView(
                in: hostingView,
                identifier: "paneManagement.identityStrip"
            ) != nil
        }

        let identityView = try #require(
            findAccessibilityView(
                in: hostingView,
                identifier: "paneManagement.identityStrip"
            )
        )
        let activeContentFrame = paneHost.swiftUIContainer.convert(
            paneHost.swiftUIContainer.bounds,
            to: hostingView
        )
        let identityFrame = identityView.convert(identityView.bounds, to: hostingView)
        let substrateSample = try renderedColor(
            in: hostingView,
            at: CGPoint(x: identityFrame.maxX - 30, y: identityFrame.midY)
        )

        #expect(activeContentFrame == inactiveContentFrame)
        #expect(identityFrame.maxY <= activeContentFrame.maxY)
        #expect(
            abs(
                activeContentFrame.maxY - identityFrame.maxY
                    - AppStyles.General.Spacing.loose
            ) < 0.5
        )
        #expect(colorChannelSpread(of: substrateSample) < 0.03)
        #expect(substrateSample.redComponent < 0.18)
    }

    private func renderedColor(
        in hostingView: NSView,
        at point: CGPoint
    ) throws -> NSColor {
        let renderedBitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: renderedBitmap)
        let bitmapScale = CGFloat(renderedBitmap.pixelsHigh) / hostingView.bounds.height
        return try #require(
            renderedBitmap.colorAt(
                x: Int(point.x * bitmapScale),
                y: Int(point.y * bitmapScale)
            )?.usingColorSpace(.deviceRGB)
        )
    }

    private func colorChannelSpread(of color: NSColor) -> CGFloat {
        max(color.redComponent, color.greenComponent, color.blueComponent)
            - min(color.redComponent, color.greenComponent, color.blueComponent)
    }

    private struct MountedTrailingControlState {
        let controlFrame: CGRect
        let identityFrame: CGRect?
        let hostingBounds: CGRect
        let isAccessibilityEnabled: Bool
    }

    private func mountedTrailingControlState(
        isDrawerChild: Bool,
        worktreeBacked: Bool = false,
        hasMoveDestination: Bool = true
    ) throws -> MountedTrailingControlState {
        let store = WorkspaceStore()
        let parentPane: Pane
        if worktreeBacked {
            let repo = store.addRepo(at: URL(filePath: "/tmp/agent-studio"))
            let worktree = Worktree(
                repoId: repo.id,
                name: "feature-name",
                path: URL(filePath: "/tmp/agent-studio/feature-name")
            )
            store.reconcileDiscoveredWorktrees(repo.id, worktrees: [worktree])
            let storedWorktree = store.repos[0].worktrees[0]
            parentPane = store.createPane(
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
            parentPane = store.createPane()
        }
        let tab = Tab(paneId: parentPane.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)

        let targetPane: Pane
        let accessibilityIdentifier: String
        if isDrawerChild {
            targetPane = try #require(store.addDrawerPane(to: parentPane.id))
            accessibilityIdentifier = "paneManagement.detachDrawerPane"
        } else {
            targetPane = parentPane
            accessibilityIdentifier = "paneManagement.movePaneToTab"
            if hasMoveDestination {
                let destinationPane = store.createPane()
                store.appendTab(Tab(paneId: destinationPane.id))
            }
        }

        atom(\.managementLayer).activate()
        defer { atom(\.managementLayer).deactivate() }

        let hostingView = NSHostingView(
            rootView: PaneLeafContainer(
                paneHost: PaneHostView(paneId: targetPane.id),
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
                toolbarPresentation: .hidden
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
        let controlView = try #require(
            findAccessibilityView(
                in: hostingView,
                identifier: accessibilityIdentifier
            )
        )
        let identityView = findAccessibilityView(
            in: hostingView,
            identifier: "paneManagement.identityStrip"
        )
        return MountedTrailingControlState(
            controlFrame: controlView.convert(controlView.bounds, to: hostingView),
            identityFrame: identityView?.convert(identityView?.bounds ?? .zero, to: hostingView),
            hostingBounds: hostingView.bounds,
            isAccessibilityEnabled: controlView.isAccessibilityEnabled()
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

    private func findAccessibilityView(
        in root: NSView,
        identifier: String
    ) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = findAccessibilityView(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class ManagementIdentityBackdropProbeView: NSView, PaneMountedContent {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor =
            NSColor(
                red: 0.10,
                green: 0.25,
                blue: 0.80,
                alpha: 1
            ).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setContentInteractionEnabled(_: Bool) {}
}
