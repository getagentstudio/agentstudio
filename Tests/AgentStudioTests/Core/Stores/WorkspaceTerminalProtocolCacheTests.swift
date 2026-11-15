import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioCore

@MainActor
@Suite("Workspace terminal protocol metadata cache", .serialized)
struct WorkspaceTerminalProtocolCacheTests {
    @Test("boot loads recorded versions without promoting NULL and writes stay visible synchronously")
    func bootAndWritesKeepProtocolMetadataCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "protocol-cache-\(UUIDv7.generate())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: root.appending(path: "core.sqlite"), localDatabaseURL: root.appending(path: "local.sqlite")
        )
        let datastore = factory.makeDatastore()
        guard case .prepared = await datastore.prepareDatabasesForBoot() else {
            Issue.record("Expected the private datastore to prepare")
            return
        }
        let store = WorkspaceStore(sqliteDatastore: datastore, startsObserving: false)
        guard case .initializedDefaultWorkspace = await store.loadCanonicalComposition() else {
            Issue.record("Expected a fresh canonical workspace")
            return
        }
        let untracked = store.createPane(launchDirectory: root)
        let untrackedID = try #require(untracked.terminalState?.zmxSessionID)
        store.appendTab(Tab(paneId: untracked.id))
        let mismatched = store.createPane(launchDirectory: root)
        let mismatchedID = try #require(mismatched.terminalState?.zmxSessionID)
        store.appendTab(Tab(paneId: mismatched.id))
        try #require(await store.flushAsync() == .persisted)
        let created = try await store.createTerminalPane(
            metadata: PaneMetadata(launchDirectory: root, title: "Current"), placement: .newTab,
            nameForPane: { _ in "Current" },
            willPublish: { pane in
                guard let sessionID = pane.terminalState?.zmxSessionID else {
                    Issue.record("A newly committed terminal must have its durable session")
                    return
                }
                #expect(store.cachedTerminalSessionProtocolVersion(sessionID) == ZmxProtocol.version)
            })
        let createdID = try #require(created.terminalState?.zmxSessionID)
        #expect(store.cachedTerminalSessionProtocolVersion(untrackedID) == nil)
        #expect(store.cachedTerminalSessionProtocolVersion(createdID) == ZmxProtocol.version)
        try await store.recordTerminalSessionProtocolVersion(mismatchedID, version: 0)
        #expect(store.cachedTerminalSessionProtocolVersion(mismatchedID) == 0)

        let reopenedDatastore = factory.makeDatastore()
        guard case .prepared = await reopenedDatastore.prepareDatabasesForBoot() else {
            Issue.record("Expected the persisted datastore to reopen")
            return
        }
        let reopened = WorkspaceStore(sqliteDatastore: reopenedDatastore, startsObserving: false)
        guard case .loaded = await reopened.loadCanonicalComposition() else {
            Issue.record("Expected the persisted composition to load")
            return
        }
        #expect(reopened.cachedTerminalSessionProtocolVersion(createdID) == ZmxProtocol.version)
        #expect(reopened.cachedTerminalSessionProtocolVersion(untrackedID) == nil)
        #expect(reopened.cachedTerminalSessionProtocolVersion(mismatchedID) == 0)
        let absentID = ZmxSessionID.generateUUIDv7()
        #expect(reopened.cachedTerminalSessionProtocolVersion(absentID) == nil)
        try await reopened.recordTerminalSessionProtocolVersion(untrackedID, version: ZmxProtocol.version)
        #expect(reopened.cachedTerminalSessionProtocolVersion(untrackedID) == ZmxProtocol.version)
        #expect(try await reopened.terminalSessionProtocolVersion(untrackedID) == ZmxProtocol.version)
        await #expect(throws: (any Error).self) {
            try await reopened.recordTerminalSessionProtocolVersion(absentID, version: ZmxProtocol.version)
        }
        #expect(reopened.cachedTerminalSessionProtocolVersion(absentID) == nil)
    }
}
