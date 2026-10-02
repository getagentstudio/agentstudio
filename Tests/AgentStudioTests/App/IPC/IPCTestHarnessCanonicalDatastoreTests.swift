import AgentStudioAppIPC
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Live IPC harness canonical datastore", .serialized)
struct IPCTestHarnessCanonicalDatastoreTests {
    enum HarnessKind: Sendable {
        case paneAgent
        case sessions
    }

    init() { installTestCoreAtomsIfNeeded() }

    @Test(
        "workspace and IPC writes share the case's canonical datastore", arguments: [HarnessKind.paneAgent, .sessions])
    func workspaceAndIPCObserveOneDatastore(kind: HarnessKind) async throws {
        switch kind {
        case .paneAgent:
            let harness = try await PaneAgentControlHarness.make(channel: .debug)
            do {
                try await verifySharedWrites(store: harness.store, appDelegate: harness.appDelegate)
            } catch {
                await harness.tearDown()
                throw error
            }
            await harness.tearDown()
        case .sessions:
            let harness = try await SessionsVerticalHarness.make()
            do {
                try await verifySharedWrites(store: harness.commandHarness.store, appDelegate: harness.appDelegate)
            } catch {
                await harness.tearDown()
                throw error
            }
            await harness.tearDown()
        }
    }

    private func verifySharedWrites(store: WorkspaceStore, appDelegate: AppDelegate) async throws {
        let ipcDatastore = try #require(appDelegate.workspaceSQLiteDatastore)
        // The first load deliberately replays the prepared startup image.
        // Consume it before writing so the observation reads the committed DB.
        _ = await ipcDatastore.loadWorkspaceSnapshot()
        store.identityAtom.setWorkspaceName("Written through WorkspaceStore")
        #expect(await store.flushAsync() == .persisted)

        guard case .loaded(var workspace) = await ipcDatastore.loadWorkspaceSnapshot() else {
            Issue.record("The IPC datastore could not observe WorkspaceStore's committed snapshot")
            return
        }
        #expect(workspace.id == store.identityAtom.workspaceId)
        #expect(workspace.name == "Written through WorkspaceStore")

        workspace.name = "Written through the IPC datastore"
        let saveCapture = WorkspaceSQLiteSaveCoordinator(
            identityAtom: store.identityAtom,
            windowMemoryAtom: store.windowMemoryAtom,
            workspacePaneAtom: store.paneAtom,
            workspaceTabLayoutAtom: store.tabLayoutAtom,
            repositoryTopologyAtom: store.repositoryTopologyAtom,
            sqliteDatastore: ipcDatastore
        ).captureCurrentSaveState(persistedAt: workspace.updatedAt)
        try await ipcDatastore.saveWorkspaceSnapshotBundle(
            WorkspaceSQLiteSaveBundle(
                workspace: workspace,
                captureRevision: saveCapture.revision,
                drawerPresentationRevision: saveCapture.drawerPresentationRevision
            )
        )
        guard case .loaded = await store.loadCanonicalComposition() else {
            Issue.record("WorkspaceStore could not reload the IPC datastore's committed snapshot")
            return
        }
        #expect(store.identityAtom.workspaceName == "Written through the IPC datastore")
    }
}
