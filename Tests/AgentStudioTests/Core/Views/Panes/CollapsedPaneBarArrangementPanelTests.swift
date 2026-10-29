import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Collapsed pane bar Arrangements", .serialized)
struct CollapsedPaneBarArrangementPanelTests {
    @Test("collapsed pane bar keeps the injected arrangement rename state identity")
    func keepsInjectedArrangementRenameStateIdentity() {
        let atoms = makeInstalledTestCoreAtoms()
        let sources = ArrangementPanelSources(
            store: WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout), repoCache: atoms.repoCache)
        let renameState = ArrangementInlineRenameState()
        let actionDispatcher = PaneTabActionDispatcher(
            dispatch: { _ in },
            shouldHandleSplitDragPayload: { _ in false },
            shouldAcceptDrop: { _, _, _, _ in false },
            handleDrop: { _, _, _, _ in }
        )

        let collapsedPaneBar = CollapsedPaneBar(
            paneId: UUID(),
            octiconLoader: makeCoreTestOcticonLoader(),
            tabId: UUID(),
            closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
            actionDispatcher: actionDispatcher,
            arrangementInlineRenameState: renameState,
            commandActionResolver: makeCollapsedPanePresentedCommandAction,
            arrangementPanelSources: sources,
            onFocus: {}
        )

        #expect(collapsedPaneBar.arrangementInlineRenameState === renameState)
    }

    @Test("minimized-bar Arrangements remains open after a panel action")
    func minimizedBarArrangementsRemainsOpenAfterPanelAction() async throws {
        installTestCoreAtomsIfNeeded()
        try await withAsyncTestCoreAtoms(using: CoreAtomScope.store) { atoms in
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
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            var minimizePaneTargets: [UUID] = []
            let actionDispatcher = PaneTabActionDispatcher(
                dispatch: { _ in },
                shouldHandleSplitDragPayload: { _ in false },
                shouldAcceptDrop: { _, _, _, _ in false },
                handleDrop: { _, _, _, _ in }
            )
            let hostingView = NSHostingView(
                rootView: CollapsedPaneBar(
                    paneId: pane.id,
                    octiconLoader: makeCoreTestOcticonLoader(),
                    tabId: tab.id,
                    closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                    actionDispatcher: actionDispatcher,
                    arrangementInlineRenameState: ArrangementInlineRenameState(),
                    commandActionResolver: { command, surface, target, targetType in
                        let commandSpec = command.definition
                        guard
                            commandSpec.shouldPresent(
                                AppCommandPresentationQuery(
                                    surface: surface,
                                    subject: .targeted(targetType)
                                )
                            )
                        else {
                            return nil
                        }
                        return TargetedCommandControlAction(
                            commandSpec: commandSpec,
                            isEnabled: true,
                            perform: {
                                guard command == .minimizePane else { return }
                                minimizePaneTargets.append(target)
                            }
                        )
                    },
                    arrangementPanelSources: ArrangementPanelSources(store: store, repoCache: atoms.repoCache),
                    onFocus: {}
                )
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: CollapsedPaneBar.barWidth, height: 500)
            let window = NSWindow(contentViewController: NSViewController())
            window.contentView = hostingView
            window.setContentSize(hostingView.frame.size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            hostingView.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()

            let arrangementsButton = try #require(
                findAccessibilityElement(
                    in: hostingView,
                    identifier: "collapsed-pane-bar-arrangements"
                )
            )
            #expect(performAccessibilityPress(arrangementsButton))

            let visibilityIdentifier = "arrangement-panel-pane-\(pane.id.uuidString)-visibility"
            await assertEventuallyMain("pane visibility action should mount") {
                findAccessibilityElement(
                    in: NSApp.windows.compactMap(\.contentView),
                    identifier: visibilityIdentifier
                ) != nil
            }
            let visibilityButton = try #require(
                findAccessibilityElement(
                    in: NSApp.windows.compactMap(\.contentView),
                    identifier: visibilityIdentifier
                )
            )

            #expect(performAccessibilityPress(visibilityButton))
            #expect(minimizePaneTargets == [pane.id])
            await assertEventuallyMain("pane visibility action should remain mounted") {
                findAccessibilityElement(
                    in: NSApp.windows.compactMap(\.contentView),
                    identifier: visibilityIdentifier
                ) != nil
            }
        }
    }

    @Test("minimized-bar Arrangements forwards Pane Zoom and remains open")
    func minimizedBarArrangementsForwardsPaneZoom() async throws {
        installTestCoreAtomsIfNeeded()
        try await withAsyncTestCoreAtoms(using: CoreAtomScope.store) { atoms in
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
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            var zoomTargets: [UUID] = []
            let actionDispatcher = PaneTabActionDispatcher(
                dispatch: { _ in },
                shouldHandleSplitDragPayload: { _ in false },
                shouldAcceptDrop: { _, _, _, _ in false },
                handleDrop: { _, _, _, _ in }
            )
            let hostingView = NSHostingView(
                rootView: CollapsedPaneBar(
                    paneId: pane.id,
                    octiconLoader: makeCoreTestOcticonLoader(),
                    tabId: tab.id,
                    closeTransitionCoordinator: PaneCloseTransitionCoordinator(),
                    actionDispatcher: actionDispatcher,
                    arrangementInlineRenameState: ArrangementInlineRenameState(),
                    commandActionResolver: { command, surface, target, targetType in
                        let commandSpec = command.definition
                        guard
                            commandSpec.shouldPresent(
                                AppCommandPresentationQuery(
                                    surface: surface,
                                    subject: .targeted(targetType)
                                )
                            )
                        else {
                            return nil
                        }
                        return TargetedCommandControlAction(
                            commandSpec: commandSpec,
                            isEnabled: true,
                            perform: { zoomTargets.append(target) }
                        )
                    },
                    arrangementPanelSources: ArrangementPanelSources(store: store, repoCache: atoms.repoCache),
                    onFocus: {}
                )
            )
            hostingView.frame = CGRect(x: 0, y: 0, width: CollapsedPaneBar.barWidth, height: 500)
            let window = NSWindow(contentViewController: NSViewController())
            window.contentView = hostingView
            window.setContentSize(hostingView.frame.size)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            hostingView.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()

            let arrangementsButton = try #require(
                findAccessibilityElement(
                    in: hostingView,
                    identifier: "collapsed-pane-bar-arrangements"
                )
            )
            #expect(performAccessibilityPress(arrangementsButton))

            let zoomIdentifier = "arrangement-panel-pane-\(pane.id.uuidString)-zoom"
            await assertEventuallyMain("minimized-bar Arrangements popover should mount") {
                findAccessibilityElement(
                    in: NSApp.windows.compactMap(\.contentView),
                    identifier: zoomIdentifier
                ) != nil
            }
            let zoomButton = try #require(
                findAccessibilityElement(
                    in: NSApp.windows.compactMap(\.contentView),
                    identifier: zoomIdentifier
                )
            )

            #expect(performAccessibilityPress(zoomButton))
            #expect(zoomTargets == [pane.id])
            await assertEventuallyMain("minimized-bar Arrangements popover should remain mounted") {
                findAccessibilityElement(
                    in: NSApp.windows.compactMap(\.contentView),
                    identifier: zoomIdentifier
                ) != nil
            }
        }
    }
}

@MainActor
private func makeCollapsedPanePresentedCommandAction(
    command: AppCommand,
    surface: AppCommandSurface,
    target _: UUID,
    targetType: SearchItemType
) -> TargetedCommandControlAction? {
    let commandSpec = command.definition
    guard
        commandSpec.shouldPresent(
            AppCommandPresentationQuery(
                surface: surface,
                subject: .targeted(targetType)
            )
        )
    else {
        return nil
    }
    return TargetedCommandControlAction(
        commandSpec: commandSpec,
        isEnabled: true,
        perform: {}
    )
}

@MainActor
private func findAccessibilityElement(
    in roots: [NSView],
    identifier: String
) -> AnyObject? {
    for root in roots {
        if let match = findAccessibilityElement(in: root, identifier: identifier) {
            return match
        }
    }
    return nil
}

@MainActor
private func findAccessibilityElement(
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
            if let match = findAccessibilityElement(
                in: child,
                identifier: identifier,
                visited: &visited
            ) {
                return match
            }
        }
    }

    for subview in (root as? NSView)?.subviews ?? [] {
        if let match = findAccessibilityElement(
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
private func findAccessibilityElement(
    in root: AnyObject,
    identifier: String
) -> AnyObject? {
    var visited: Set<ObjectIdentifier> = []
    return findAccessibilityElement(
        in: root,
        identifier: identifier,
        visited: &visited
    )
}

@MainActor
private func performAccessibilityPress(_ element: AnyObject) -> Bool {
    if let view = element as? NSView {
        return view.accessibilityPerformPress()
    }
    if let accessibilityElement = element as? NSAccessibilityElement {
        return accessibilityElement.accessibilityPerformPress()
    }
    return false
}
