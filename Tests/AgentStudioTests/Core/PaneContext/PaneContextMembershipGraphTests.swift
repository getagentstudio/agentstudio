import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane context membership graph", .serialized)
struct PaneContextMembershipGraphTests {
    @Test("The real composition applier atomically installs workspace presence")
    func bootSeedUsesCanonicalComposition() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        let view = try fixture.requireInstalled()
        #expect(view.workspaceId == fixture.identity.workspaceId)
        #expect(view.workspaceId == fixture.workspaceId)
        #expect(view.sources == [fixture.seedId])
        #expect(fixture.directory.contains(paneID: fixture.seed.id, inWorkspace: fixture.workspaceId))
    }

    @Test("Every insertion writer reaches the mirror", arguments: ["create", "add", "restore", "replace"])
    func insertionWritersPublish(writer: String) throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        _ = fixture.directory.takeAffectedOwners()
        let added: UUID
        switch writer {
        case "create": added = fixture.addPane().id
        case "add":
            let pane = PaneContextMembershipGraphFixture.makePane(title: "Fixture add")
            fixture.graph.addPane(pane)
            added = pane.id
        case "restore":
            let pane = PaneContextMembershipGraphFixture.makePane(title: "Restored")
            try #require(fixture.graph.insertRestoredPane(pane))
            added = pane.id
        default:
            let pane = PaneContextMembershipGraphFixture.makePane(title: "Replacement")
            var states = fixture.graph.paneStateSnapshot()
            states[pane.id] = PaneGraphState(pane: pane)
            let replacement: WorkspacePaneGraphReplacement?
            if case .success(let value) = WorkspacePaneGraphReplacement.prepare(states) {
                replacement = value
            } else {
                replacement = nil
            }
            fixture.graph.replacePaneStates(try #require(replacement))
            added = pane.id
        }
        let id = PaneId(existingUUID: added)
        #expect(fixture.directory.contains(paneID: added, inWorkspace: fixture.workspaceId))
        #expect(fixture.directory.sources(for: id) == [id])
        #expect(fixture.directory.takeAffectedOwners() == .owners([id]))
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
    }

    @Test("Backgrounded and orphan panes without a tab stay present", arguments: [false, true])
    func noTabAndResidencyDoNotRemovePresence(orphan: Bool) throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let pane = fixture.addPane()
        let id = PaneId(existingUUID: pane.id)
        let before = try #require(fixture.directory.view(for: id))
        _ = fixture.directory.takeAffectedOwners()
        fixture.graph.setResidency(
            orphan ? .orphaned(reason: .worktreeNotFound(path: "/tmp/missing")) : .backgrounded, for: pane.id)
        #expect(fixture.directory.view(for: id) == before)
        #expect(fixture.directory.contains(paneID: pane.id, inWorkspace: fixture.workspaceId))
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
    }

    @Test("Title, cwd, note and repository association writes are membership no-ops")
    func unrelatedStructuralFieldsDoNotWakeMembership() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        let before = try fixture.requireInstalled()
        _ = fixture.directory.takeAffectedOwners()
        fixture.graph.updatePaneTitle(fixture.seed.id, title: "Changed")
        fixture.graph.updatePaneCWD(fixture.seed.id, cwd: URL(filePath: "/tmp/changed"))
        fixture.graph.updatePaneNote(fixture.seed.id, note: "Changed")
        let revision = try #require(fixture.graph.reservePaneAssociationRevision(fixture.seed.id))
        _ = fixture.graph.applyPaneAssociationUpdate(
            fixture.seed.id, cwd: URL(filePath: "/tmp/changed"),
            resolution: .matched(repoId: UUIDv7.generate(), worktreeId: UUIDv7.generate()), revision: revision)
        #expect(fixture.directory.view(for: fixture.seedId) == before)
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
    }

    @Test("Closing removes presence immediately; an undo restore publishes it again")
    func closeAndUndoRestoreHaveSeparateVersions() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        try #require(fixture.graph.deletePaneAndOwnedDrawerChildren(fixture.seed.id))
        #expect(!fixture.directory.contains(paneID: fixture.seed.id, inWorkspace: fixture.workspaceId))
        #expect(fixture.directory.view(for: fixture.seedId) == nil)
        try #require(fixture.graph.insertRestoredPane(fixture.seed))
        #expect(fixture.directory.contains(paneID: fixture.seed.id, inWorkspace: fixture.workspaceId))
    }

    @Test("Drawer attach, detach and rollback invalidate the source and both owners")
    func drawerMoveAndRollbackKeepOwnershipConsistent() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let second = fixture.addPane(title: "Second owner")
        let child = try fixture.addDrawer(to: fixture.seed.id)
        let childId = PaneId(existingUUID: child.id)
        let secondId = PaneId(existingUUID: second.id)
        #expect(fixture.directory.sources(for: fixture.seedId) == [fixture.seedId, childId])
        #expect(fixture.directory.sources(for: childId) == [childId])
        #expect(fixture.directory.ownerPaneId(for: childId) == fixture.seedId)
        _ = fixture.directory.takeAffectedOwners()
        let detached = try #require(fixture.graph.detachDrawerPane(child.id, from: fixture.seed.id))
        #expect(fixture.directory.ownerPaneId(for: childId) == nil)
        try #require(fixture.graph.restoreDrawerPane(detached.pane(isDrawerExpanded: false), to: second.id))
        #expect(fixture.directory.sources(for: fixture.seedId) == [fixture.seedId])
        #expect(fixture.directory.sources(for: secondId) == [secondId, childId])
        #expect(fixture.directory.ownerPaneId(for: childId) == secondId)
        #expect(fixture.directory.takeAffectedOwners() == .owners([fixture.seedId, secondId, childId]))
        let rollback = try #require(fixture.graph.detachDrawerPane(child.id, from: second.id))
        try #require(fixture.graph.restoreDrawerPane(rollback.pane(isDrawerExpanded: false), to: fixture.seed.id))
        #expect(fixture.directory.sources(for: fixture.seedId) == [fixture.seedId, childId])
        #expect(fixture.directory.sources(for: secondId) == [secondId])
        #expect(fixture.directory.ownerPaneId(for: childId) == fixture.seedId)
    }

    @Test("Removing an owner removes its drawer children in the same version")
    func ownerRemovalIncludesChildren() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let child = try fixture.addDrawer(to: fixture.seed.id)
        try #require(fixture.graph.deletePaneAndOwnedDrawerChildren(fixture.seed.id))
        #expect(!fixture.directory.contains(paneID: child.id, inWorkspace: fixture.workspaceId))
        #expect(fixture.directory.sources(for: fixture.seedId) == nil)
        #expect(fixture.directory.sources(for: PaneId(existingUUID: child.id)) == nil)
    }

    @Test("Drawer insertion and removal publish through the canonical graph commit")
    func drawerInsertionAndRemovalAreMirrored() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let first = try fixture.addDrawer(to: fixture.seed.id)
        let added = try #require(
            fixture.graph.insertDrawerPane(
                in: fixture.seed.id, at: first.id,
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/pane-context-insert"), title: "Inserted")))
        let firstId = PaneId(existingUUID: first.id)
        let addedId = PaneId(existingUUID: added.id)
        #expect(fixture.directory.sources(for: fixture.seedId) == [fixture.seedId, firstId, addedId])
        fixture.graph.removeDrawerPane(first.id, from: fixture.seed.id)
        #expect(fixture.directory.sources(for: fixture.seedId) == [fixture.seedId, addedId])
        #expect(fixture.directory.ownerPaneId(for: firstId) == nil)
        #expect(!fixture.directory.contains(paneID: first.id, inWorkspace: fixture.workspaceId))
    }

    @Test("Purging a backgrounded orphan removes presence at the graph's actual delete")
    func orphanPurgeRemovesMembership() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let pane = fixture.addPane()
        fixture.graph.setResidency(.backgrounded, for: pane.id)
        fixture.graph.purgeOrphanedPane(pane.id)
        #expect(!fixture.directory.contains(paneID: pane.id, inWorkspace: fixture.workspaceId))
        #expect(fixture.directory.ownerPaneId(for: PaneId(existingUUID: pane.id)) == nil)
    }

    @Test("A held consumer deduplicates repeated detach and restore changes")
    func repeatedMovesStayOwners() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let child = try fixture.addDrawer(to: fixture.seed.id)
        _ = fixture.directory.takeAffectedOwners()
        for _ in 0..<5 {
            let detached = try #require(fixture.graph.detachDrawerPane(child.id, from: fixture.seed.id))
            try #require(fixture.graph.restoreDrawerPane(detached.pane(isDrawerExpanded: false), to: fixture.seed.id))
        }
        #expect(fixture.directory.takeAffectedOwners() == .owners([fixture.seedId, PaneId(existingUUID: child.id)]))
    }

    @Test("Unique transient owners collapse to all; compact current facts omit deleted keys")
    func overflowReconcilesCurrentPresence() throws {
        let fixture = try PaneContextMembershipGraphFixture()
        _ = try fixture.requireInstalled()
        let deleted = fixture.addPane(title: "Deleted during hold")
        _ = fixture.directory.takeAffectedOwners()
        try #require(fixture.graph.deletePaneAndOwnedDrawerChildren(deleted.id))
        for _ in 0...AppPolicies.PaneContext.maximumPendingAffectedOwners { _ = fixture.addPane() }
        #expect(fixture.directory.takeAffectedOwners() == .all)
        let current = Set(fixture.directory.currentOwners().map(\.paneId))
        #expect(!current.contains(PaneId(existingUUID: deleted.id)))
        #expect(current.contains(fixture.seedId))
        #expect(current == Set(fixture.graph.paneIDs.map(PaneId.init(existingUUID:))))
        #expect(fixture.directory.takeAffectedOwners() == .owners([]))
    }
}
