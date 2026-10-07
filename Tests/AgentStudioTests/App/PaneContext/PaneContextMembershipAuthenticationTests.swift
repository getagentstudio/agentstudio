import AgentStudioAppIPC
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Pane context membership authentication", .serialized)
struct PaneContextMembershipAuthenticationTests {
    @Test("Directory presence matches canonical auth for a pane without a tab", arguments: [false, true])
    func noTabPaneRetainsAuthentication(orphan: Bool) async throws {
        let fixture = try PaneContextAuthenticationFixture()
        try fixture.requireInstalled()
        let added = fixture.graph.createPane(
            launchDirectory: URL(filePath: "/tmp/pane-context-auth"), title: "No tab", zmxSessionID: .generateUUIDv7())
        fixture.graph.setResidency(
            orphan ? .orphaned(reason: .worktreeNotFound(path: "/tmp/missing")) : .backgrounded, for: added.id)
        let registry = fixture.registry(for: added.id)
        defer { registry.shutdown() }
        let context = try await registry.authenticate(subjectToken: .init(rawValue: "membership-test"))
        #expect(
            fixture.directory.contains(paneID: added.id, inWorkspace: fixture.workspaceId)
                == (fixture.graph.paneState(added.id) != nil))
        #expect(await registry.contextRemainsAuthorized(context))
        #expect(!fixture.directory.contains(paneID: added.id, inWorkspace: UUIDv7.generate()))
        try #require(fixture.graph.deletePaneAndOwnedDrawerChildren(added.id))
        #expect(!fixture.directory.contains(paneID: added.id, inWorkspace: fixture.workspaceId))
        #expect(
            fixture.directory.contains(paneID: added.id, inWorkspace: fixture.workspaceId)
                == (fixture.graph.paneState(added.id) != nil))
        #expect(!(await registry.contextRemainsAuthorized(context)))
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            _ = try await registry.authenticate(subjectToken: .init(rawValue: "membership-test"))
        }
    }

    @Test("Presence cannot reauthorize an invalidated lease, but a fresh lease can authenticate")
    func leaseInvalidationRemainsIndependentOfPresence() async throws {
        let fixture = try PaneContextAuthenticationFixture()
        try fixture.requireInstalled()
        let registry = fixture.registry(for: fixture.seed.id)
        defer { registry.shutdown() }
        let token = AgentStudioIPCSubjectToken(rawValue: "membership-test")
        let old = try await registry.authenticate(subjectToken: token)
        registry.invalidatePrincipals(boundToPaneId: fixture.seed.id.uuidString)
        #expect(fixture.directory.contains(paneID: fixture.seed.id, inWorkspace: fixture.workspaceId))
        #expect(!(await registry.contextRemainsAuthorized(old)))
        let fresh = try await registry.authenticate(subjectToken: token)
        #expect(await registry.contextRemainsAuthorized(fresh))
        #expect(old.principal.principalId != fresh.principal.principalId)
    }

    @Test("Restored presence cannot bypass final credential revocation")
    func finalRevocationSurvivesRestore() async throws {
        let fixture = try PaneContextAuthenticationFixture()
        try fixture.requireInstalled()
        let registry = fixture.registry(for: fixture.seed.id)
        defer { registry.shutdown() }
        let token = AgentStudioIPCSubjectToken(rawValue: "membership-test")
        let context = try await registry.authenticate(subjectToken: token)
        registry.finalRevokePane(fixture.seed.id)
        try #require(fixture.graph.deletePaneAndOwnedDrawerChildren(fixture.seed.id))
        try #require(fixture.graph.insertRestoredPane(fixture.seed))
        #expect(fixture.directory.contains(paneID: fixture.seed.id, inWorkspace: fixture.workspaceId))
        #expect(!(await registry.contextRemainsAuthorized(context)))
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            _ = try await registry.authenticate(subjectToken: token)
        }
    }
}

private struct PaneContextAuthenticationCredentialResolver: AgentStudioIPCCredentialResolving {
    let paneId: UUID
    let workspaceId: UUID
    let recordId = UUIDv7.generate()

    func resolveCredential(_ credential: AgentStudioIPCSubjectToken, serverRuntimeID: UUID) async throws
        -> AgentStudioIPCCredentialResolution
    {
        guard credential.rawValue == "membership-test" else {
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }
        return .pane(paneID: paneId, workspaceID: workspaceId, credentialRecordID: recordId, status: .registered)
    }
}

@MainActor
private struct PaneContextAuthenticationFixture {
    let workspaceId = UUIDv7.generate()
    let directory = PaneContextMembershipDirectory()
    let graph: WorkspacePaneGraphAtom
    let seed: Pane

    init() throws {
        graph = WorkspacePaneGraphAtom(paneContextMembershipDirectory: directory)
        seed = Pane(
            id: UUIDv7.generate(),
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/pane-context-auth"), title: "Seed"))
        let arrangement = PaneArrangement(
            id: UUIDv7.generate(), name: "Default", isDefault: true,
            layout: Layout(paneId: seed.id), activePaneId: seed.id)
        let tab = Tab(
            id: UUIDv7.generate(), name: "Auth", allPaneIds: [seed.id],
            arrangements: [arrangement], activeArrangementId: arrangement.id)
        let snapshot = WorkspaceSQLiteSnapshot(
            id: workspaceId, name: "Auth", panes: [seed], tabs: [tab],
            activeTabId: tab.id, createdAt: Date(timeIntervalSince1970: 100))
        let prepared: PreparedWorkspaceComposition?
        if case .prepared(let value) = WorkspaceCompositionPreparer.prepare(snapshot) {
            prepared = value
        } else {
            prepared = nil
        }
        let cursor = WorkspaceTabCursorAtom()
        let applier = WorkspacePreparedCompositionApplier(
            owners: .init(
                workspaceIdentityAtom: WorkspaceIdentityAtom(workspaceId: UUIDv7.generate()),
                workspaceWindowMemoryAtom: WorkspaceWindowMemoryAtom(), workspacePaneGraphAtom: graph,
                workspaceDrawerCursorAtom: WorkspaceDrawerCursorAtom(),
                workspaceTabShellAtom: WorkspaceTabShellAtom(cursorAtom: cursor), workspaceTabCursorAtom: cursor,
                workspaceTabGraphAtom: WorkspaceTabGraphAtom(),
                workspaceArrangementCursorAtom: WorkspaceArrangementCursorAtom()))
        let result = applier.apply(try #require(prepared))
        let accepted: Bool
        if case .accepted = result { accepted = true } else { accepted = false }
        try #require(accepted)
    }

    func requireInstalled() throws {
        try #require(
            directory.view(for: PaneId(existingUUID: seed.id)) != nil,
            "Inert graph publisher fails before authentication work starts")
    }

    func registry(for paneId: UUID) -> AgentStudioIPCPrincipalRegistry {
        let directory = self.directory
        return AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: PaneContextAuthenticationCredentialResolver(paneId: paneId, workspaceId: workspaceId),
            canonicalPaneMembership: { pane, workspace in directory.contains(paneID: pane, inWorkspace: workspace) })
    }
}
