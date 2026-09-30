import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// `drawer.addPane` creates its child in the background through the real
/// layout adapter, executor and workspace owners: the drawer keeps its
/// expansion and selected child, no pane is asked to take focus, and the
/// result names the child a later call can target.
@MainActor
@Suite("App IPC background drawer child", .serialized)
struct AgentStudioIPCBackgroundDrawerChildTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test(
        "a terminal or browser drawer child leaves expansion, selection and focus unchanged",
        arguments: [
            (IPCDrawerChildContent.terminal, true),
            (.terminal, false),
            (.browser(url: "https://example.com/docs"), true),
            (.browser(url: "https://example.com/docs"), false),
        ]
    )
    func backgroundChildKeepsPresentation(content: IPCDrawerChildContent, drawerExpanded: Bool) async throws {
        // Test-scoped core atoms: the focus owner this test reads cannot be
        // written by another suite sharing the process.
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
            let selectedChild = try #require(store.addDrawerPane(to: parent.id))
            store.setActiveDrawerPane(selectedChild.id, in: parent.id)
            if store.paneAtom.pane(parent.id)?.drawer?.isExpanded != drawerExpanded {
                store.paneAtom.toggleDrawer(for: parent.id)
            }
            atoms.workspaceFocusOwner.focusMainPane(parent.id)
            let focusControl = RefusingPaneFocusAppControl()
            let adapter = AgentStudioIPCLayoutAdapter(
                workspaceStore: store,
                windowLifecycleReader: WorkspaceWindowLifecycleReader(lifecycleStore: harness.windowLifecycleStore),
                paneFocusControl: focusControl,
                workspaceActionExecutor: harness.executor
            )
            let focusOwnerBefore = atoms.workspaceFocusOwner.owner

            let result = try await adapter.addDrawerPane(
                IPCDrawerAddPaneParams(
                    parentPaneHandle: "pane:\(parent.id.uuidString)", content: content, correlationId: nil),
                ownPaneAssertion: AppIPCOwnPaneAssertion(boundPaneId: parent.id)
            )

            let child = try #require(store.paneAtom.pane(result.childPaneId))
            #expect(child.parentPaneId == parent.id)
            #expect(result.parentPaneId == parent.id)
            #expect(result.childHandle == result.childPaneId.uuidString)
            switch (content, child.content) {
            case (.terminal, .terminal), (.browser, .webview):
                break
            default:
                Issue.record("drawer child holds \(child.content), requested \(content)")
            }
            #expect(store.paneAtom.pane(parent.id)?.drawer?.paneIds.contains(result.childPaneId) == true)
            #expect(store.paneAtom.pane(parent.id)?.drawer?.isExpanded == drawerExpanded)
            #expect(store.drawerView(forParent: parent.id)?.activeChildId == selectedChild.id)
            #expect(store.tabLayoutAtom.tab(tab.id)?.activePaneId == parent.id)
            #expect(atoms.workspaceFocusOwner.owner == focusOwnerBefore)
            #expect(atom(\.workspaceFocusOwner).owner == focusOwnerBefore)
            #expect(harness.coordinator.pendingPaneRefocusReasonsByPaneId[result.childPaneId] == nil)
            #expect(focusControl.focusedPaneIds.isEmpty)
        }
    }

    @Test(
        "a background child added to an all-minimized drawer is created without a selection",
        arguments: [IPCDrawerChildContent.terminal, .browser(url: "https://example.com/docs")]
    )
    func backgroundChildInAllMinimizedDrawer(content: IPCDrawerChildContent) async throws {
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
            let second = try #require(store.addDrawerPane(to: parent.id))
            #expect(store.minimizeDrawerPane(first.id, in: parent.id))
            #expect(store.minimizeDrawerPane(second.id, in: parent.id))
            #expect(store.drawerView(forParent: parent.id)?.activeChildId == nil)
            let focusControl = RefusingPaneFocusAppControl()
            let adapter = AgentStudioIPCLayoutAdapter(
                workspaceStore: store,
                windowLifecycleReader: WorkspaceWindowLifecycleReader(lifecycleStore: harness.windowLifecycleStore),
                paneFocusControl: focusControl,
                workspaceActionExecutor: harness.executor
            )

            let result = try await adapter.addDrawerPane(
                IPCDrawerAddPaneParams(
                    parentPaneHandle: "pane:\(parent.id.uuidString)", content: content, correlationId: nil),
                ownPaneAssertion: AppIPCOwnPaneAssertion(boundPaneId: parent.id)
            )

            #expect(store.paneAtom.pane(result.childPaneId)?.parentPaneId == parent.id)
            let drawerView = try #require(store.drawerView(forParent: parent.id))
            #expect(drawerView.activeChildId == nil)
            #expect(drawerView.minimizedPaneIds == [first.id, second.id, result.childPaneId])
            #expect(drawerView.layout.paneIds.contains(result.childPaneId))
            #expect(focusControl.focusedPaneIds.isEmpty)
        }
    }

    @Test("the interactive add still expands, selects and requests focus for its new child")
    func interactiveAddKeepsItsPresentation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.tempDir) }
        let store = harness.store
        let parent = store.createPane(title: "Terminal")
        let tab = Tab(paneId: parent.id)
        store.appendTab(tab)
        store.setActiveTab(tab.id)
        store.setActivePane(parent.id, inTab: tab.id)
        let selectedChild = try #require(store.addDrawerPane(to: parent.id))
        store.setActiveDrawerPane(selectedChild.id, in: parent.id)
        store.paneAtom.toggleDrawer(for: parent.id)
        #expect(store.paneAtom.pane(parent.id)?.drawer?.isExpanded == false)
        let panesBefore = store.paneAtom.graphAtom.paneIDs

        #expect(await harness.executor.execute(.addDrawerPane(parentPaneId: parent.id)))

        let added = try #require(store.paneAtom.graphAtom.paneIDs.subtracting(panesBefore).first)
        #expect(store.paneAtom.pane(parent.id)?.drawer?.isExpanded == true)
        #expect(store.drawerView(forParent: parent.id)?.activeChildId == added)
        #expect(harness.coordinator.pendingPaneRefocusReasonsByPaneId[added] != nil)
    }
}

/// Records focus requests; drawer creation must never make one.
@MainActor
private final class RefusingPaneFocusAppControl: PaneFocusAppControlling, @unchecked Sendable {
    private(set) var focusedPaneIds: [UUID] = []

    func focusPane(_ paneId: UUID) async throws {
        focusedPaneIds.append(paneId)
    }
}
