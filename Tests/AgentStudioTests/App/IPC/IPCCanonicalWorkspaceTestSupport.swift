import AgentStudioInfrastructure
import Foundation

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

/// Each live case owns one fresh datastore, shared by its workspace and IPC.
@MainActor
func makeCanonicalIPCWorkspaceCommandHarness(
    workspaceWindowId: UUID? = nil
) throws -> (commandHarness: PaneTabViewControllerCommandHarness, datastore: WorkspaceSQLiteDatastoreActor) {
    let workspaceId = UUIDv7.generate()
    let sqliteFixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceId)
    let datastore = try preparedWorkspaceSQLiteDatastore(from: sqliteFixture.backend)
    let canonicalStore = WorkspaceStore(
        identityAtom: WorkspaceIdentityAtom(workspaceId: workspaceId),
        sqliteDatastore: datastore,
        startsObserving: false
    )
    return (makeHarness(store: canonicalStore, workspaceWindowId: workspaceWindowId), datastore)
}
