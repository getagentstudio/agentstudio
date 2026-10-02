import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// A pane agent closing its own drawer child takes the drawer-close semantics
/// on both IPC surfaces, through the real executor and SQLite-backed store:
/// the close lands, and selection moves to an unminimized sibling exactly as
/// the catalog's drawer close does.
@MainActor
@Suite("App IPC drawer child close", .serialized)
struct AgentStudioIPCDrawerChildCloseTests {
    init() { installTestCoreAtomsIfNeeded() }

    enum CloseSurface: String, CaseIterable, Sendable {
        case paneClose
        case closeDrawerPane
    }

    @Test(
        "closing the selected own drawer child beside a minimized sibling selects the visible sibling",
        arguments: CloseSurface.allCases
    )
    func closeSelectsVisibleSiblingPastMinimizedOne(surface: CloseSurface) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let windowId = UUIDv7.generate()
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle, workspaceWindowId: windowId)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            harness.windowLifecycleStore.recordWindowRegistered(windowId)
            let store = harness.store
            let parent = store.createPane(title: "Agent terminal")
            let tab = Tab(paneId: parent.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(parent.id, inTab: tab.id)
            let first = try #require(store.addDrawerPane(to: parent.id))
            let selected = try #require(store.addDrawerPane(to: parent.id))
            let last = try #require(store.addDrawerPane(to: parent.id))
            store.setActiveDrawerPane(selected.id, in: parent.id)
            #expect(store.minimizeDrawerPane(first.id, in: parent.id))
            #expect(store.drawerView(forParent: parent.id)?.activeChildId == selected.id)
            #expect(store.drawerView(forParent: parent.id)?.minimizedPaneIds == [first.id])

            switch surface {
            case .paneClose:
                let focusControl = UnusedPaneFocusAppControl()
                let adapter = AgentStudioIPCLayoutAdapter(
                    workspaceStore: store,
                    windowLifecycleReader: WorkspaceWindowLifecycleReader(
                        lifecycleStore: harness.windowLifecycleStore),
                    paneFocusControl: focusControl,
                    workspaceActionExecutor: harness.executor
                )
                let result = try await adapter.closePane(
                    IPCPaneCloseParams(handle: "pane:\(selected.id.uuidString)", correlationId: nil),
                    ownPaneAssertion: AppIPCOwnPaneAssertion(boundPaneId: parent.id)
                )
                #expect(result.paneId == selected.id)
                withExtendedLifetime(focusControl) {}
            case .closeDrawerPane:
                let outcome = await harness.controller.executeHeadlessIPC(
                    AppCommandExecutionRequest(
                        command: .closeDrawerPane,
                        arguments: .typedIPC(
                            .drawerPane(
                                .init(
                                    workspaceWindowId: windowId,
                                    parentPaneSelector: try IPCPaneSelector(rawValue: parent.id.uuidString),
                                    drawerPaneSelector: try IPCPaneSelector(rawValue: selected.id.uuidString)
                                ))),
                        executionContext: .headlessIPC(admitsDebugTestingCommands: false),
                        ownPaneAssertion: WorkspaceOwnPaneAssertion(boundPaneId: parent.id)
                    ))
                #expect(outcome == .applied)
            }

            #expect(store.paneAtom.pane(selected.id) == nil)
            #expect(store.paneAtom.pane(parent.id)?.drawer?.paneIds == [first.id, last.id])
            #expect(store.drawerView(forParent: parent.id)?.activeChildId == last.id)
            #expect(store.drawerView(forParent: parent.id)?.minimizedPaneIds == [first.id])
        }
    }

    @Test(
        "automation drawer child close skips minimized siblings and preserves pane undo",
        arguments: [false, true]
    )
    func automationCloseSkipsMinimizedSiblingsPreservesUndo(allSiblingsMinimized: Bool) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let windowId = UUIDv7.generate()
            let harness = makeHarness(windowLifecycleStore: atoms.windowLifecycle, workspaceWindowId: windowId)
            defer { try? FileManager.default.removeItem(at: harness.tempDir) }
            harness.windowLifecycleStore.recordWindowRegistered(windowId)
            let store = harness.store
            let parent = store.createPane()
            let tab = Tab(paneId: parent.id)
            store.appendTab(tab)
            store.setActiveTab(tab.id)
            store.setActivePane(parent.id, inTab: tab.id)
            let first = try #require(store.addDrawerPane(to: parent.id))
            let selected = try #require(store.addDrawerPane(to: parent.id))
            let last = try #require(store.addDrawerPane(to: parent.id))
            store.setActiveDrawerPane(selected.id, in: parent.id)
            #expect(store.minimizeDrawerPane(first.id, in: parent.id))
            if allSiblingsMinimized {
                #expect(store.minimizeDrawerPane(last.id, in: parent.id))
            }
            #expect(store.drawerView(forParent: parent.id)?.activeChildId == selected.id)
            let focusControl = UnusedPaneFocusAppControl()
            let adapter = AgentStudioIPCLayoutAdapter(
                workspaceStore: store,
                windowLifecycleReader: WorkspaceWindowLifecycleReader(
                    lifecycleStore: harness.windowLifecycleStore),
                paneFocusControl: focusControl,
                workspaceActionExecutor: harness.executor
            )

            let result = try await adapter.closePane(
                IPCPaneCloseParams(handle: "pane:\(selected.id.uuidString)", correlationId: nil),
                ownPaneAssertion: nil
            )

            #expect(result.paneId == selected.id)
            #expect(store.paneAtom.pane(selected.id) == nil)
            #expect(store.paneAtom.pane(parent.id)?.drawer?.paneIds == [first.id, last.id])
            let remainingView = try #require(store.drawerView(forParent: parent.id))
            #expect(remainingView.activeChildId == (allSiblingsMinimized ? nil : last.id))
            #expect(remainingView.minimizedPaneIds == (allSiblingsMinimized ? [first.id, last.id] : [first.id]))
            guard case .pane(let snapshot)? = harness.coordinator.undoStack.last else {
                Issue.record("Expected automation drawer close to preserve pane undo")
                return
            }
            #expect(snapshot.pane.id == selected.id)
            withExtendedLifetime(focusControl) {}
        }
    }
}

/// The layout adapter needs a focus owner; a drawer close never calls it.
@MainActor
private final class UnusedPaneFocusAppControl: PaneFocusAppControlling, @unchecked Sendable {
    func focusPane(_: UUID) async throws {
        Issue.record("drawer close must not request pane focus")
    }
}
