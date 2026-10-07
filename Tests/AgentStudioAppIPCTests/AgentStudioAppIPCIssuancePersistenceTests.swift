import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import CryptoKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("App IPC issuance persistence", .serialized)
struct AgentStudioAppIPCIssuancePersistenceTests {
    @Test("an unused token issued after readiness authenticates after reopen without a graceful snapshot")
    func unusedTokenIssuedAfterReadinessAuthenticatesAfterReopen() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        try #require(await fixture.prepareDatastoreForIPC(datastore))
        let repository = IPCContinuityRepository(datastore: datastore)

        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: repository,
            body: { serverFixture in
                let paneID = serverFixture.boundPaneId
                let workspaceID = serverFixture.workspaceId
                try await datastore.saveWorkspaceSnapshotBundle(
                    WorkspaceSQLiteSaveBundle(
                        workspace: .init(id: workspaceID, name: "IPC issuance reopen")
                    )
                )
                let owner = makeIdentityOwner(serverFixture: serverFixture)
                try serverFixture.server.start()

                let environment = try owner.environment(paneID: paneID, workspaceID: workspaceID)
                let token = AgentStudioIPCSubjectToken(
                    rawValue: try #require(environment.environmentVariables["AGENTSTUDIO_PANE_TOKEN"])
                )
                #expect(await serverFixture.server.drainCredentialPersistence().failedOperationCount == 0)
                // stop(), unlike stopAcceptingConnections(), takes no credential
                // snapshot. The fixture's later teardown sees an already-stopped
                // server and cannot save this unused token for us.
                await serverFixture.server.stop()
                await serverFixture.server.joinConnectionHandlers()

                let reopenedDatastore = fixture.makeDatastore()
                try #require(await fixture.prepareDatastoreForIPC(reopenedDatastore))
                let reopenedRepository = IPCContinuityRepository(datastore: reopenedDatastore)
                let reopenedRegistry = AgentStudioIPCPrincipalRegistry(
                    runtimeId: UUIDv7.generate(),
                    credentialResolver: IPCContinuityCredentialResolver(repository: reopenedRepository),
                    canonicalPaneMembership: { candidatePaneID, candidateWorkspaceID in
                        candidatePaneID == paneID && candidateWorkspaceID == workspaceID
                    }
                )
                defer { reopenedRegistry.shutdown() }

                // On the unfixed code this throws unauthenticated: the token is
                // unknown after reopen. No login or graceful save preceded it.
                let context = try await reopenedRegistry.authenticate(subjectToken: token)
                #expect(context.credentialIdentity == .pane(recordID: environment.credentialRecordID))
                #expect(
                    context.principal.kind
                        == .spawnedPaneAgent(boundPaneId: paneID.uuidString, boundWorkspaceId: workspaceID)
                )
                let stored = try #require(
                    try await reopenedRepository.paneCredential(
                        paneID: paneID, credentialRecordID: environment.credentialRecordID
                    )
                )
                #expect(stored.verifierSHA256 == Data(SHA256.hash(data: Data(token.rawValue.utf8))))
                #expect(stored.verifierSHA256 != Data(token.rawValue.utf8))
                #expect(stored.status == .registered)
            }
        )
    }

    @Test("a held continuity write does not block environment and final revoke precedes the issued write")
    func heldContinuityDoesNotBlockEnvironmentAndFinalRevokeDominates() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        try #require(await fixture.prepareDatastoreForIPC(datastore))
        let repository = IPCContinuityRepository(datastore: datastore)
        let port = HeldCredentialContinuityPort(repository: repository)

        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: port,
            releaseHeldWork: { port.releaseRegistration() },
            body: { serverFixture in
                try await datastore.saveWorkspaceSnapshotBundle(
                    WorkspaceSQLiteSaveBundle(
                        workspace: .init(id: serverFixture.workspaceId, name: "IPC held issuance")
                    )
                )
                // A readiness candidate holds the FIFO before issuance. This
                // proof also terminates on the unfixed code, where issuance
                // never submits its own write.
                let seedPaneID = UUIDv7.generate()
                let seedRecordID = UUIDv7.generate()
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: seedPaneID,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: seedRecordID,
                    verifierSHA256: Data(repeating: 0xB4, count: 32)
                )
                try serverFixture.server.start()
                await port.waitUntilRegistrationHeld()

                let owner = makeIdentityOwner(serverFixture: serverFixture)
                let environment = try owner.environment(
                    paneID: serverFixture.boundPaneId, workspaceID: serverFixture.workspaceId
                )
                #expect(!port.observedRelease)
                #expect(!environment.environmentVariables["AGENTSTUDIO_PANE_TOKEN", default: ""].isEmpty)
                #expect(port.registrationCallCount == 1)
                serverFixture.server.finalRevokePrincipals(boundToPaneID: serverFixture.boundPaneId)

                port.releaseRegistration()
                #expect(await serverFixture.server.drainCredentialPersistence().failedOperationCount == 0)
                #expect(port.registrationCallCount == 2)
                #expect(try await repository.paneCredentials(paneID: serverFixture.boundPaneId).isEmpty)
                #expect(
                    try await repository.paneCredential(paneID: seedPaneID, credentialRecordID: seedRecordID)?.status
                        == .registered
                )
            }
        )
    }

    @Test("a failing continuity port leaves the pane environment usable and the verifier eligible")
    func failingContinuityDoesNotBlockEnvironment() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        try #require(await fixture.prepareDatastoreForIPC(datastore))
        let repository = IPCContinuityRepository(datastore: datastore)
        let port = FailingIssuanceContinuityPort()

        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: port,
            body: { serverFixture in
                let seedRecordID = UUIDv7.generate()
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: serverFixture.boundPaneId,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: seedRecordID,
                    verifierSHA256: Data(repeating: 0xB4, count: 32)
                )
                try serverFixture.server.start()
                #expect(await serverFixture.server.drainCredentialPersistence().failedOperationCount == 1)
                let owner = makeIdentityOwner(serverFixture: serverFixture)
                let environment = try owner.environment(
                    paneID: serverFixture.boundPaneId, workspaceID: serverFixture.workspaceId
                )
                #expect(!environment.environmentVariables["AGENTSTUDIO_PANE_TOKEN", default: ""].isEmpty)
                let result = await serverFixture.server.drainCredentialPersistence()
                #expect(port.registrationCallCount == 2)
                #expect(result.failedOperationCount == 1)
                #expect(result.failedOperationCount == port.registrationCallCount - 1)
                #expect(
                    Set(serverFixture.server.principalRegistry.issuedCredentialCandidates().map(\.credentialRecordID))
                        == [seedRecordID, environment.credentialRecordID]
                )
                #expect(try await repository.paneCredentials(paneID: serverFixture.boundPaneId).isEmpty)
                // Prevent the fixture's graceful snapshot from retrying the
                // intentionally failing write during teardown.
                await serverFixture.server.stop()
                await serverFixture.server.joinConnectionHandlers()
            }
        )
    }

    private func makeIdentityOwner(serverFixture: LiveServerFixture) -> PaneIPCIdentityOwner {
        let paneID = serverFixture.boundPaneId
        let workspaceID = serverFixture.workspaceId
        return PaneIPCIdentityOwner(
            principalRegistry: serverFixture.server.principalRegistry,
            socketURL: serverFixture.paths.socketURL,
            cliStoreURL: serverFixture.paths.cliStoreURL,
            cliStoreChannel: .debug,
            cliExecutableURL: serverFixture.rootURL.appending(path: "AgentStudio.app/Contents/Helpers/agentstudio"),
            inheritedEnvironment: [:],
            canonicalPaneMembership: { candidatePaneID, candidateWorkspaceID in
                candidatePaneID == paneID && candidateWorkspaceID == workspaceID
            },
            randomBytes: { Data(repeating: 0xA5, count: 32) }
        )
    }
}

private final class FailingIssuanceContinuityPort: AgentStudioIPCCredentialContinuityPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRegistrationCallCount = 0

    var registrationCallCount: Int { lock.withLock { storedRegistrationCallCount } }

    func registerIssuedPaneCredential(
        _: AgentStudioIPCIssuedPaneCredential,
        if _: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        lock.withLock { storedRegistrationCallCount += 1 }
        throw IssuanceContinuityTestError.injectedWriteFailure
    }

    func revokeAllPaneCredentials(paneID _: UUID) async throws {}
}

private enum IssuanceContinuityTestError: Error {
    case injectedWriteFailure
}
