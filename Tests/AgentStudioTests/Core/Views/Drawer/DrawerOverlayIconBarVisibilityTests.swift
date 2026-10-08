import AgentStudioInfrastructure
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("DrawerOverlay icon bar visibility", .serialized)
struct DrawerOverlayIconBarVisibilityTests {
    @Test("hidden icon bar is structurally absent while visible icon bar is mounted")
    func iconBarVisibilityControlsStructure() throws {
        let visibleMount = mountDrawerOverlay(isIconBarVisible: true)
        defer {
            visibleMount.window.orderOut(nil)
            visibleMount.window.close()
        }

        #expect(visibleMount.hostingView.fittingSize.height > 0)
        let visibleProbe = try #require(
            findView(
                in: visibleMount.hostingView,
                identifier: Self.probeAccessibilityIdentifier
            )
        )
        #expect(visibleProbe.isAccessibilityElement())
        #expect(visibleProbe.accessibilityLabel() == Self.probeAccessibilityLabel)
        #expect(
            visibleProbe.hitTest(
                NSPoint(x: visibleProbe.bounds.midX, y: visibleProbe.bounds.midY)
            ) != nil
        )

        let hiddenMount = mountDrawerOverlay(isIconBarVisible: false)
        defer {
            hiddenMount.window.orderOut(nil)
            hiddenMount.window.close()
        }

        #expect(hiddenMount.hostingView.fittingSize.height == 0)
        #expect(
            findView(
                in: hiddenMount.hostingView,
                identifier: Self.probeAccessibilityIdentifier
            ) == nil
        )
        #expect(
            findAccessibleElement(
                in: hiddenMount.hostingView,
                identifier: Self.probeAccessibilityIdentifier
            ) == nil
        )
    }

    @Test("pane mode precedes adjacent uniform Drawer controls")
    func toolbarControlOrderAndDrawerSpacing() throws {
        let mount = mountDrawerOverlay(isIconBarVisible: true)
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let paneModeView = try #require(
            findView(
                in: mount.hostingView,
                identifier: Self.probeAccessibilityIdentifier
            )
        )
        let drawerToggleView = try #require(
            findView(
                in: mount.hostingView,
                identifier: "paneSurfaceToolbar.drawerToggle"
            )
        )
        let drawerAddView = try #require(
            findView(
                in: mount.hostingView,
                identifier: "paneSurfaceToolbar.drawerAdd"
            )
        )
        let paneModeFrame = paneModeView.convert(paneModeView.bounds, to: mount.hostingView)
        let drawerToggleFrame = drawerToggleView.convert(drawerToggleView.bounds, to: mount.hostingView)
        let drawerAddFrame = drawerAddView.convert(drawerAddView.bounds, to: mount.hostingView)

        #expect(paneModeFrame.maxX < drawerToggleFrame.minX)
        #expect(drawerToggleFrame.maxX < drawerAddFrame.minX)
        #expect(paneModeFrame.size == drawerToggleFrame.size)
        #expect(drawerToggleFrame.size == drawerAddFrame.size)
        #expect(paneModeFrame.width == DrawerLayout.iconButtonSize)
        #expect(paneModeFrame.height == DrawerLayout.iconButtonSize)
        #expect(drawerToggleFrame.width == DrawerLayout.iconButtonSize)
        #expect(drawerToggleFrame.height == DrawerLayout.iconButtonSize)
        #expect(
            abs(
                drawerToggleFrame.minX - paneModeFrame.maxX
                    - expectedToolbarSeparatorWidth
            ) < 0.5
        )
        #expect(
            abs(
                drawerAddFrame.minX - drawerToggleFrame.maxX
                    - AppStyles.Shell.DrawerToolbar.trailingClusterSpacing
            ) < 0.5
        )
    }

    @Test("Zoom toolbar separates leading Drawer controls from trailing pane actions")
    func zoomToolbarUsesAcceptedSemanticGroupOrder() throws {
        let zoomAction = makePaneSurfaceAction(
            label: "Pane Zoom",
            identifier: "paneSurfaceToolbar.zoom"
        )
        let viewerAction = makePaneSurfaceAction(
            label: "Viewer",
            identifier: "paneSurfaceToolbar.viewer"
        )
        let mount = mountDrawerOverlay(
            isIconBarVisible: true,
            trailingActions: makeTrailingActions(),
            paneSurfaceActions: [],
            paneContextActions: [zoomAction, viewerAction],
            width: 720
        )
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let orderedIdentifiers = [
            "paneSurfaceToolbar.drawerToggle",
            "paneSurfaceToolbar.drawerAdd",
            "paneSurfaceToolbar.note",
            "paneSurfaceToolbar.editor",
            "paneSurfaceToolbar.finder",
            "paneSurfaceToolbar.copyPath",
            "paneSurfaceToolbar.zoom",
            "paneSurfaceToolbar.viewer",
        ]
        let orderedFrames = try orderedIdentifiers.map { identifier in
            let view = try #require(findView(in: mount.hostingView, identifier: identifier))
            return view.convert(view.bounds, to: mount.hostingView)
        }

        for (leftFrame, rightFrame) in zip(orderedFrames, orderedFrames.dropFirst()) {
            #expect(leftFrame.maxX < rightFrame.minX)
        }
        #expect(
            findView(in: mount.hostingView, identifier: "paneSurfaceToolbar.inbox") == nil
        )
    }

    @Test("PR blocker precedes the PR action and pane fullscreen controls")
    func pullRequestBlockerPrecedesPullRequestActionAndPaneContextActions() throws {
        let zoomAction = makePaneSurfaceAction(
            label: "Pane Zoom",
            identifier: "paneSurfaceToolbar.zoom"
        )
        let blockerIndicator = PaneSurfaceToolbarStatusIndicator(
            label: "Merge conflicts",
            accessibilityIdentifier: "paneSurfaceToolbar.pullRequestBlocker",
            icon: .system(.xmarkCircleFill),
            tooltip: ControlTooltipRenderValue(
                text: "Merge conflicts",
                shortcutDisplayText: nil
            ),
            iconStatusTone: .danger
        )
        let pullRequestAction = makePaneSurfaceAction(
            label: "Open PR",
            identifier: "paneSurfaceToolbar.pullRequest"
        )
        let mount = mountDrawerOverlay(
            isIconBarVisible: true,
            trailingActions: makeTrailingActions(
                pullRequestBlockerIndicator: blockerIndicator,
                openPullRequestAction: pullRequestAction
            ),
            paneContextActions: [zoomAction],
            width: 640
        )
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let orderedIdentifiers = [
            "paneSurfaceToolbar.drawerToggle",
            "paneSurfaceToolbar.drawerAdd",
            "paneSurfaceToolbar.note",
            "paneSurfaceToolbar.pullRequestBlocker",
            "paneSurfaceToolbar.pullRequest",
            "paneSurfaceToolbar.editor",
            "paneSurfaceToolbar.finder",
            "paneSurfaceToolbar.copyPath",
            "paneSurfaceToolbar.zoom",
        ]
        let orderedFrames = try orderedIdentifiers.map { identifier in
            let view = try #require(findView(in: mount.hostingView, identifier: identifier))
            return view.convert(view.bounds, to: mount.hostingView)
        }

        for (leftFrame, rightFrame) in zip(orderedFrames, orderedFrames.dropFirst()) {
            #expect(leftFrame.maxX < rightFrame.minX)
        }

        let blockerFrame = orderedFrames[3]
        let pullRequestFrame = orderedFrames[4]
        let editorFrame = orderedFrames[5]
        let copyPathFrame = orderedFrames[7]
        let paneContextFrame = orderedFrames[8]
        #expect(
            abs(
                pullRequestFrame.minX - blockerFrame.maxX
                    - AppStyles.Shell.DrawerToolbar.trailingClusterSpacing
            ) < 0.5
        )
        #expect(
            abs(
                editorFrame.minX - pullRequestFrame.maxX
                    - expectedToolbarSeparatorWidth
            ) < 0.5
        )
        #expect(
            abs(
                paneContextFrame.minX - copyPathFrame.maxX
                    - expectedToolbarSeparatorWidth
            ) < 0.5
        )
    }

    @Test("passive Git status precedes PR and action controls without a clean placeholder")
    func passiveGitStatusPrecedesActionsWithoutCleanPlaceholder() throws {
        let presentation = try #require(
            PaneSurfaceGitStatusPresentation.resolve(
                branchStatus: GitBranchStatus(
                    isDirty: true,
                    syncState: .behind(625),
                    prCount: nil,
                    linesAdded: 20,
                    linesDeleted: 14,
                    untrackedFileCount: 0
                )
            )
        )
        let pullRequestAction = makePaneSurfaceAction(
            label: "Open PR",
            identifier: "paneSurfaceToolbar.pullRequest"
        )
        let mount = mountDrawerOverlay(
            isIconBarVisible: true,
            trailingActions: makeTrailingActions(
                gitStatusPresentation: presentation,
                openPullRequestAction: pullRequestAction
            ),
            width: 720
        )
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let gitStatusView = try #require(
            findView(in: mount.hostingView, identifier: "paneSurfaceToolbar.gitStatus")
        )
        let pullRequestView = try #require(
            findView(in: mount.hostingView, identifier: "paneSurfaceToolbar.pullRequest")
        )
        let editorView = try #require(
            findView(in: mount.hostingView, identifier: "paneSurfaceToolbar.editor")
        )
        let gitStatusFrame = gitStatusView.convert(gitStatusView.bounds, to: mount.hostingView)
        let pullRequestFrame = pullRequestView.convert(pullRequestView.bounds, to: mount.hostingView)
        let editorFrame = editorView.convert(editorView.bounds, to: mount.hostingView)

        #expect(gitStatusFrame.maxX < pullRequestFrame.minX)
        #expect(pullRequestFrame.maxX < editorFrame.minX)
        #expect(gitStatusView.accessibilityLabel() == presentation.accessibilityLabel)
        #expect(gitStatusView.accessibilityRole() != .button)

        let cleanMount = mountDrawerOverlay(
            isIconBarVisible: true,
            trailingActions: makeTrailingActions(
                gitStatusPresentation: PaneSurfaceGitStatusPresentation.resolve(
                    branchStatus: GitBranchStatus(
                        isDirty: false,
                        syncState: .synced,
                        prCount: nil,
                        linesAdded: 0,
                        linesDeleted: 0,
                        untrackedFileCount: 0
                    )
                )
            )
        )
        defer {
            cleanMount.window.orderOut(nil)
            cleanMount.window.close()
        }
        #expect(
            findView(in: cleanMount.hostingView, identifier: "paneSurfaceToolbar.gitStatus") == nil
        )
    }

    @Test("toolbar group separators use standard horizontal spacing")
    func toolbarGroupSeparatorsUseStandardHorizontalSpacing() throws {
        let mount = mountDrawerOverlay(isIconBarVisible: true)
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let paneModeView = try #require(
            findView(in: mount.hostingView, identifier: Self.probeAccessibilityIdentifier)
        )
        let drawerToggleView = try #require(
            findView(in: mount.hostingView, identifier: "paneSurfaceToolbar.drawerToggle")
        )
        let paneModeFrame = paneModeView.convert(paneModeView.bounds, to: mount.hostingView)
        let drawerToggleFrame = drawerToggleView.convert(drawerToggleView.bounds, to: mount.hostingView)
        let standardSeparatorWidth = (AppStyles.General.Spacing.standard * 2) + 1

        #expect(
            abs(drawerToggleFrame.minX - paneModeFrame.maxX - standardSeparatorWidth) < 0.5
        )
    }

    @Test("absent pane mode does not leave an empty leading separator")
    func absentPaneModeDoesNotLeaveEmptyLeadingSeparator() throws {
        let mount = mountDrawerOverlay(
            isIconBarVisible: true,
            paneSurfaceActions: []
        )
        defer {
            mount.window.orderOut(nil)
            mount.window.close()
        }

        let drawerToggleView = try #require(
            findView(
                in: mount.hostingView,
                identifier: "paneSurfaceToolbar.drawerToggle"
            )
        )
        let drawerToggleFrame = drawerToggleView.convert(
            drawerToggleView.bounds,
            to: mount.hostingView
        )

        #expect(
            abs(drawerToggleFrame.minX - DrawerLayout.iconBarVerticalPadding) < 0.5
        )
    }

    private static let probeAccessibilityLabel = "VisibilityProbe"
    private static let probeAccessibilityIdentifier = "paneSurfaceToolbar.visibilityprobe"

    private var expectedToolbarSeparatorWidth: CGFloat {
        (AppStyles.Shell.DrawerToolbar.dividerHorizontalPadding * 2) + 1
    }

    private func mountDrawerOverlay(
        isIconBarVisible: Bool,
        trailingActions: DrawerOverlay.TrailingActions? = nil,
        paneSurfaceActions: [PaneSurfaceToolbarAction]? = nil,
        paneContextActions: [PaneSurfaceToolbarAction] = [],
        width: CGFloat = 360
    ) -> DrawerOverlayMount {
        let probeAction = PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: Self.probeAccessibilityLabel,
                accessibilityIdentifier: Self.probeAccessibilityIdentifier,
                icon: .system(.rectangleSplit2x1),
                tooltip: ControlTooltipRenderValue(
                    text: "Visibility probe",
                    shortcutDisplayText: nil
                ),
                isEnabled: true,
                isSelected: false
            ),
            perform: {}
        )
        let hostingView = NSHostingView<AnyView>(
            rootView: AnyView(
                DrawerOverlay(
                    octiconLoader: makeCoreTestOcticonLoader(),
                    drawer: nil,
                    isIconBarVisible: isIconBarVisible,
                    toggleDrawerAction: makeTargetedAction(.toggleDrawer),
                    addDrawerPaneAction: makeTargetedAction(.addDrawerPane),
                    trailingActions: trailingActions,
                    paneSurfaceActions: paneSurfaceActions ?? [probeAction],
                    paneContextActions: paneContextActions
                )
                .frame(width: width)
            )
        )
        hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()

        return DrawerOverlayMount(hostingView: hostingView, window: window)
    }

    private func makeTrailingActions(
        gitStatusPresentation: PaneSurfaceGitStatusPresentation? = nil,
        pullRequestBlockerIndicator: PaneSurfaceToolbarStatusIndicator? = nil,
        openPullRequestAction: PaneSurfaceToolbarAction? = nil
    ) -> DrawerOverlay.TrailingActions {
        DrawerOverlay.TrailingActions(
            editPaneNoteAction: makeTargetedAction(.editPaneNote),
            openEditorMenuAction: makeTargetedAction(.openPaneLocationInEditorMenu),
            openFinderAction: makeTargetedAction(.openPaneLocationInFinder),
            copyPathAction: makeTargetedAction(.copyCurrentPanePath),
            gitStatusPresentation: gitStatusPresentation,
            pullRequestBlockerIndicator: pullRequestBlockerIndicator,
            openPullRequestAction: openPullRequestAction,
            showPaneInboxAction: makeTargetedAction(.showPaneInboxNotifications),
            editorMenuContent: AnyView(EmptyView()),
            editorMenuPresented: .constant(false),
            buttonTitle: nil,
            inboxPopoverContent: AnyView(EmptyView())
        )
    }

    private func makeTargetedAction(
        _ command: AppCommand
    ) -> TargetedCommandControlAction {
        TargetedCommandControlAction(
            commandSpec: command.definition,
            isEnabled: true,
            perform: {}
        )
    }

    private func makePaneSurfaceAction(
        label: String,
        identifier: String
    ) -> PaneSurfaceToolbarAction {
        PaneSurfaceToolbarAction(
            state: PaneSurfaceToolbarAction.State(
                label: label,
                accessibilityIdentifier: identifier,
                icon: .system(.rectangleSplit2x1),
                tooltip: ControlTooltipRenderValue(
                    text: label,
                    shortcutDisplayText: nil
                ),
                isEnabled: true,
                isSelected: false
            ),
            perform: {}
        )
    }
}

@MainActor
private struct DrawerOverlayMount {
    let hostingView: NSHostingView<AnyView>
    let window: NSWindow
}

@MainActor
private func findView(in root: NSView, identifier: String) -> NSView? {
    if root.identifier?.rawValue == identifier {
        return root
    }

    for subview in root.subviews {
        if let match = findView(in: subview, identifier: identifier) {
            return match
        }
    }

    return nil
}

@MainActor
private func findAccessibleElement(in root: AnyObject, identifier: String) -> AnyObject? {
    var visited: Set<ObjectIdentifier> = []
    return findAccessibleElement(
        in: root,
        identifier: identifier,
        visited: &visited
    )
}

@MainActor
private func findAccessibleElement(
    in element: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    let objectIdentifier = ObjectIdentifier(element)
    guard visited.insert(objectIdentifier).inserted else { return nil }

    if element.accessibilityIdentifier?() == identifier {
        return element
    }

    for child in (element.accessibilityChildren?() ?? []).compactMap({ $0 as? NSObject }) {
        if let match = findAccessibleElement(
            in: child,
            identifier: identifier,
            visited: &visited
        ) {
            return match
        }
    }

    return nil
}
