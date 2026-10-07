import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane context membership ingresses", .serialized)
struct PaneContextMembershipIngressTests {
    @Test("Legacy tab and pane restore publish through their canonical owner", arguments: ["tab", "pane"])
    func legacyRestorePublishesCanonicalMembership(kind: String) throws {
        let fixture = try MembershipIngressFixture()
        let anchor = fixture.addPane(title: "Anchor")
        let parent = fixture.addPane(title: "Restored parent")
        let tab = Tab(paneId: anchor.id)
        fixture.core.workspaceTabLayout.appendTab(tab)
        try #require(
            fixture.core.workspaceTabLayout.insertPane(
                parent.id, inTab: tab.id, at: anchor.id, direction: .horizontal, position: .after,
                sizingMode: .halveTarget))
        let first = try fixture.addDrawer(to: parent.id)
        let second = try fixture.addDrawer(to: parent.id)
        let parentId = PaneId(existingUUID: parent.id)
        let firstId = PaneId(existingUUID: first.id)
        let secondId = PaneId(existingUUID: second.id)
        let expectedSources = [parentId, firstId, secondId]
        try #require(fixture.directory.sources(for: parentId) == expectedSources)

        let restore: () throws -> Void
        if kind == "tab" {
            let snapshot = try #require(fixture.core.workspaceMutationCoordinator.snapshotForClose(tabId: tab.id))
            fixture.core.workspaceTabLayout.removeTab(tab.id)
            try #require(fixture.core.workspacePaneGraph.deletePaneAndOwnedDrawerChildren(parent.id))
            try #require(fixture.core.workspacePaneGraph.deletePaneAndOwnedDrawerChildren(anchor.id))
            restore = { fixture.core.workspaceMutationCoordinator.restoreFromSnapshot(snapshot) }
        } else {
            let snapshot = try #require(
                fixture.core.workspaceMutationCoordinator.snapshotForPaneClose(paneId: parent.id, inTab: tab.id))
            fixture.core.workspaceTabLayout.removePaneFromLayout(
                parent.id, inTab: tab.id, removingDrawerId: snapshot.pane.drawer?.drawerId)
            try #require(fixture.core.workspacePaneGraph.deletePaneAndOwnedDrawerChildren(parent.id))
            restore = {
                try #require(fixture.core.workspaceMutationCoordinator.restoreFromPaneSnapshot(snapshot) == .restored)
            }
        }
        try #require(fixture.directory.view(for: parentId) == nil)
        _ = fixture.directory.takeAffectedOwners()
        try restore()

        let restored = try #require(fixture.directory.view(for: parentId))
        #expect(restored.workspaceId == fixture.workspaceId)
        #expect(restored.sources == expectedSources)
        #expect(fixture.directory.ownerPaneId(for: firstId) == parentId)
        #expect(fixture.directory.ownerPaneId(for: secondId) == parentId)
        #expect(fixture.core.workspacePaneGraph.paneIDs.contains(parent.id))
        let affected = fixture.directory.takeAffectedOwners()
        let owners: Set<PaneId>?
        if case .owners(let values) = affected { owners = values } else { owners = nil }
        #expect(try #require(owners).isSuperset(of: Set(expectedSources)))

        // A second full pane-snapshot layout insertion is not an idempotent
        // command. Exercise the canonical restore owner's duplicate guard.
        let currentParent = try #require(fixture.core.workspacePane.pane(parent.id))
        #expect(!fixture.core.workspacePane.insertRestoredPane(currentParent))
        #expect(fixture.directory.view(for: parentId) == restored)
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
    }

    @Test("A real tab reorder changes its order without invalidating pane membership")
    func tabMoveDoesNotInvalidateMembership() throws {
        let fixture = try MembershipIngressFixture()
        let first = fixture.addPane(title: "First tab")
        let second = fixture.addPane(title: "Second tab")
        let firstTab = Tab(paneId: first.id)
        let secondTab = Tab(paneId: second.id)
        fixture.core.workspaceTabLayout.appendTab(firstTab)
        fixture.core.workspaceTabLayout.appendTab(secondTab)
        let firstId = PaneId(existingUUID: first.id)
        let secondId = PaneId(existingUUID: second.id)
        let firstView = try #require(fixture.directory.view(for: firstId))
        let secondView = try #require(fixture.directory.view(for: secondId))
        _ = fixture.directory.takeAffectedOwners()

        fixture.core.workspaceTabLayout.moveTab(fromId: secondTab.id, insertionIndex: 0)
        #expect(fixture.core.workspaceTabShell.tabShells.map(\.id) == [secondTab.id, firstTab.id])
        #expect(fixture.directory.view(for: firstId) == firstView)
        #expect(fixture.directory.view(for: secondId) == secondView)
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
        fixture.core.workspaceTabLayout.moveTab(fromId: secondTab.id, insertionIndex: 0)
        #expect(fixture.directory.view(for: secondId) == secondView)
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
    }
}

@MainActor
private struct MembershipIngressFixture {
    let workspaceId = UUIDv7.generate()
    let core = CoreAtoms()
    var directory: PaneContextMembershipDirectory { core.workspacePaneGraph.paneContextMembershipDirectory }

    init() throws {
        let snapshot = WorkspaceSQLiteSnapshot(
            id: workspaceId, name: "Ingress", panes: [], tabs: [], activeTabId: nil,
            createdAt: Date(timeIntervalSince1970: 100))
        let prepared: PreparedWorkspaceComposition?
        if case .prepared(let value) = WorkspaceCompositionPreparer.prepare(snapshot) {
            prepared = value
        } else {
            prepared = nil
        }
        let applier = WorkspacePreparedCompositionApplier(
            owners: .init(
                workspaceIdentityAtom: core.workspaceIdentity, workspaceWindowMemoryAtom: core.workspaceWindowMemory,
                workspacePaneGraphAtom: core.workspacePaneGraph, workspaceDrawerCursorAtom: core.workspaceDrawerCursor,
                workspaceTabShellAtom: core.workspaceTabShell, workspaceTabCursorAtom: core.workspaceTabCursor,
                workspaceTabGraphAtom: core.workspaceTabGraph,
                workspaceArrangementCursorAtom: core.workspaceArrangementCursor))
        let result = applier.apply(try #require(prepared))
        let accepted: Bool
        if case .accepted = result { accepted = true } else { accepted = false }
        try #require(accepted)
    }

    func addPane(title: String) -> Pane {
        let pane = PaneContextMembershipGraphFixture.makePane(title: title)
        core.workspacePane.addPane(pane)
        return pane
    }

    func addDrawer(to parent: UUID) throws -> Pane {
        try #require(
            core.workspacePane.addDrawerPane(
                to: parent,
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/membership-ingress"), title: "Drawer")))
    }
}
