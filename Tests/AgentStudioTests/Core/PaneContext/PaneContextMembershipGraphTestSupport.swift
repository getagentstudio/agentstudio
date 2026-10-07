import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
final class PaneContextMembershipGraphFixture {
    let workspaceId = UUIDv7.generate()
    let directory = PaneContextMembershipDirectory()
    let graph: WorkspacePaneGraphAtom
    let identity: WorkspaceIdentityAtom
    let seed: Pane

    init(initialPane: Pane? = nil) throws {
        graph = WorkspacePaneGraphAtom(paneContextMembershipDirectory: directory)
        identity = WorkspaceIdentityAtom(workspaceId: UUIDv7.generate())
        seed = initialPane ?? Self.makePane(title: "Seed")
        let arrangement = PaneArrangement(
            id: UUIDv7.generate(), name: "Default", isDefault: true, layout: Layout(paneId: seed.id),
            activePaneId: seed.id)
        let tab = Tab(
            id: UUIDv7.generate(), name: "Membership", allPaneIds: [seed.id], arrangements: [arrangement],
            activeArrangementId: arrangement.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: workspaceId, name: "Membership", panes: [seed], tabs: [tab], activeTabId: tab.id,
            createdAt: Date(timeIntervalSince1970: 100))
        let prepared: PreparedWorkspaceComposition?
        if case .prepared(let value) = WorkspaceCompositionPreparer.prepare(snapshot) {
            prepared = value
        } else {
            prepared = nil
        }
        let composition = try #require(prepared, "Membership fixture must use a validated composition")
        let cursor = WorkspaceTabCursorAtom()
        let applier = WorkspacePreparedCompositionApplier(
            owners: WorkspacePreparedCompositionOwners(
                workspaceIdentityAtom: identity, workspaceWindowMemoryAtom: WorkspaceWindowMemoryAtom(),
                workspacePaneGraphAtom: graph, workspaceDrawerCursorAtom: WorkspaceDrawerCursorAtom(),
                workspaceTabShellAtom: WorkspaceTabShellAtom(cursorAtom: cursor), workspaceTabCursorAtom: cursor,
                workspaceTabGraphAtom: WorkspaceTabGraphAtom(),
                workspaceArrangementCursorAtom: WorkspaceArrangementCursorAtom()))
        let result = applier.apply(composition)
        let accepted: Bool
        if case .accepted = result { accepted = true } else { accepted = false }
        try #require(accepted)
    }

    var seedId: PaneId { PaneId(existingUUID: seed.id) }

    func requireInstalled() throws -> PaneContextMembershipView {
        try #require(directory.view(for: seedId), "RED must fail on missing graph publication before waits")
    }

    func addPane(title: String = "Added") -> PaneGraphState {
        graph.createPane(
            launchDirectory: URL(filePath: "/tmp/pane-context-membership"), title: title,
            zmxSessionID: .generateUUIDv7())
    }

    func addDrawer(to parent: UUID) throws -> PaneGraphState {
        try #require(
            graph.addDrawerPane(
                to: parent,
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/pane-context-drawer"), title: "Drawer")))
    }

    static func makePane(title: String, paneId: UUID = UUIDv7.generate()) -> Pane {
        Pane(
            id: paneId,
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/pane-context-membership"), title: title))
    }
}
