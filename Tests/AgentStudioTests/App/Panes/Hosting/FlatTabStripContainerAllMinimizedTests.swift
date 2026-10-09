import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioEditorChooser
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("Flat tab strip all-minimized presentation", .serialized)
struct FlatTabStripContainerAllMinimizedTests {
    @Test("Arrangements presentation renders collapsed bars when every pane is minimized")
    func arrangementsPresentationRendersAllMinimizedBars() async {
        await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                identityAtom: atoms.workspaceIdentity,
                windowMemoryAtom: atoms.workspaceWindowMemory,
                repositoryTopologyAtom: atoms.workspaceRepositoryTopology,
                paneAtom: atoms.workspacePane,
                tabLayoutAtom: atoms.workspaceTabLayout,
                mutationCoordinator: atoms.workspaceMutationCoordinator
            )
            let pane = store.createPane()
            let tab = Tab(paneId: pane.id)
            let workspaceWindowId = UUID()
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            _ = atoms.transientKeyboardSurface.present(
                .arrangementPanel(tabId: tab.id),
                workspaceWindowId: workspaceWindowId
            )
            let actionDispatcher = PaneTabActionDispatcher(
                dispatch: { _ in },
                shouldHandleSplitDragPayload: { _ in false },
                shouldAcceptDrop: { _, _, _, _ in false },
                handleDrop: { _, _, _, _ in }
            )
            let hostingView = NSHostingView(
                rootView: FlatTabStripContainer(
                    layout: Layout(paneId: pane.id),
                    octiconLoader: makeTestOcticonLoader(),
                    tabId: tab.id,
                    activePaneId: nil,
                    minimizedPaneIds: [pane.id],
                    visiblePaneIds: [],
                    arrangementInlineRenameState: ArrangementInlineRenameState(),
                    closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                    actionDispatcher: actionDispatcher,
                    commandDispatcher: AppTerminalFixtureCommandDispatcher(), onPaneFocusTrigger: { _ in },
                    onFocusPane: { _ in },
                    store: store,
                    repoCache: RepoCacheAtom(),
                    editorChooser: makeTestAtomRegistry().editorChooser,
                    viewRegistry: ViewRegistry(),
                    appLifecycleStore: AppLifecycleAtom(),
                    onOpenPaneGitHub: { _ in },
                    workspaceWindowId: workspaceWindowId,
                    paneSurfaceToolbarPresentation: { _ in .hidden }
                )
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: 500, height: 500)
            let window = NSWindow(contentViewController: NSViewController())
            window.contentView = hostingView
            window.setContentSize(hostingView.frame.size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            hostingView.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()

            await eventually("all-minimized Arrangements should render collapsed bars") {
                findAllMinimizedAccessibilityElement(
                    in: hostingView,
                    identifier: "collapsed-pane-bar-arrangements"
                ) != nil
            }

            #expect(
                findAllMinimizedAccessibilityElement(
                    in: hostingView,
                    identifier: "collapsed-pane-bar-arrangements"
                ) != nil
            )
        }
    }
}

@MainActor
private func findAllMinimizedAccessibilityElement(
    in root: AnyObject,
    identifier: String,
    visited: inout Set<ObjectIdentifier>
) -> AnyObject? {
    guard visited.insert(ObjectIdentifier(root)).inserted else {
        return nil
    }
    let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
    if root.responds(to: identifierSelector),
        let currentIdentifier = root.perform(identifierSelector)?.takeUnretainedValue() as? String,
        currentIdentifier == identifier
    {
        return root
    }

    let childrenSelector = NSSelectorFromString("accessibilityChildren")
    if root.responds(to: childrenSelector),
        let children = root.perform(childrenSelector)?.takeUnretainedValue() as? [AnyObject]
    {
        for child in children {
            if let match = findAllMinimizedAccessibilityElement(
                in: child,
                identifier: identifier,
                visited: &visited
            ) {
                return match
            }
        }
    }

    for subview in (root as? NSView)?.subviews ?? [] {
        if let match = findAllMinimizedAccessibilityElement(
            in: subview,
            identifier: identifier,
            visited: &visited
        ) {
            return match
        }
    }
    return nil
}

@MainActor
private func findAllMinimizedAccessibilityElement(
    in root: AnyObject,
    identifier: String
) -> AnyObject? {
    var visited: Set<ObjectIdentifier> = []
    return findAllMinimizedAccessibilityElement(
        in: root,
        identifier: identifier,
        visited: &visited
    )
}
