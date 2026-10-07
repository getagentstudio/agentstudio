import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@Suite("App IPC shutdown idempotence")
struct AgentStudioAppIPCShutdownIdempotenceTests {
    @Test("F10 graceful shutdown snapshots an undurable credential only once")
    func gracefulShutdownSnapshotsOnlyOnce() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture() },
            body: { fixture in
                let recordID = try registerUndurableCredential(in: fixture)
                let registry = fixture.server.principalRegistry
                let first = registry.beginGracefulShutdownAndSnapshotUnsavedCredentials()
                let second = registry.beginGracefulShutdownAndSnapshotUnsavedCredentials()
                #expect(first.map(\.credentialRecordID) == [recordID])
                #expect(second.isEmpty)
            }
        )
    }

    @Test("F10 stopping the server consumes the registry's one graceful snapshot")
    func serverStopConsumesTheOnlySnapshot() async throws {
        try await withLiveServer(
            makeFixture: { try LiveServerFixture(credentialContinuityPort: UndurableCredentialPort()) },
            body: { fixture in
                try fixture.server.start()
                _ = try registerUndurableCredential(in: fixture)
                await fixture.stopAcceptingConnections()
                #expect(await fixture.server.drainCredentialPersistence().failedOperationCount == 0)
                #expect(fixture.server.principalRegistry.beginGracefulShutdownAndSnapshotUnsavedCredentials().isEmpty)
            }
        )
    }

    private func registerUndurableCredential(in fixture: LiveServerFixture) throws -> UUID {
        let recordID = UUIDv7.generate()
        try fixture.server.principalRegistry.registerIssuedPaneCredential(
            paneID: fixture.boundPaneId,
            workspaceID: fixture.workspaceId,
            credentialRecordID: recordID,
            verifierSHA256: Data(repeating: 0xA5, count: 32)
        )
        return recordID
    }
}

private struct UndurableCredentialPort: AgentStudioIPCCredentialContinuityPort {
    func registerIssuedPaneCredential(
        _: AgentStudioIPCIssuedPaneCredential,
        if _: @escaping @Sendable () -> Bool
    ) async throws -> Bool { false }

    func revokeAllPaneCredentials(paneID _: UUID) async throws {}
}
