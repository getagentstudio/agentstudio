import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// One prepared owner set is shared by the fixture workspace and IPC authority.
@MainActor
func makeCanonicalIPCWorkspaceOwners() async throws -> (
    core: CoreAtoms, store: WorkspaceStore, datastore: WorkspaceSQLiteDatastoreActor
) {
    let workspaceId = UUIDv7.generate()
    let sqliteFixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceId)
    let datastore = try preparedWorkspaceSQLiteDatastore(from: sqliteFixture.backend)
    let core = CoreAtoms(workspaceIdentity: WorkspaceIdentityAtom(workspaceId: workspaceId))
    let snapshot = WorkspaceSQLiteSnapshot(
        id: workspaceId, name: "IPC fixture", panes: [], tabs: [], activeTabId: nil,
        createdAt: Date(timeIntervalSince1970: 100))
    let prepared: PreparedWorkspaceComposition?
    if case .prepared(let value) = await WorkspaceCompositionPreparer.prepareOffMain(snapshot) {
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
    try #require(accepted, "IPC fixture must install canonical composition before creating panes or identity authority")
    let canonicalStore = WorkspaceStore(
        identityAtom: core.workspaceIdentity, windowMemoryAtom: core.workspaceWindowMemory,
        repositoryTopologyAtom: core.workspaceRepositoryTopology, paneAtom: core.workspacePane,
        tabLayoutAtom: core.workspaceTabLayout, mutationCoordinator: core.workspaceMutationCoordinator,
        sqliteDatastore: datastore
    )
    return (core, canonicalStore, datastore)
}

/// Each live case owns one fresh datastore, shared by its workspace and IPC.
@MainActor
func makeCanonicalIPCWorkspaceCommandHarness(
    workspaceWindowId: UUID? = nil
) async throws -> (commandHarness: PaneTabViewControllerCommandHarness, datastore: WorkspaceSQLiteDatastoreActor) {
    let owners = try await makeCanonicalIPCWorkspaceOwners()
    let harness = CoreAtomScope.$override.withValue(owners.core) {
        makeHarness(store: owners.store, workspaceWindowId: workspaceWindowId)
    }
    try #require(harness.atomRegistry.core.workspacePaneGraph === owners.store.paneAtom.graphAtom)
    return (harness, owners.datastore)
}
