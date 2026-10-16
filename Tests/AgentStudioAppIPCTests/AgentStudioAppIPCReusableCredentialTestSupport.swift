import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import CryptoKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

struct ReusableCredentialFixture {
    let rootURL: URL
    let localDatabaseURL: URL
    let coreDatabaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-ipc-reusable-credential-\(UUIDv7.generate())")
        localDatabaseURL = rootURL.appending(path: "local.sqlite")
        coreDatabaseURL = rootURL.appending(path: "core.sqlite")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func makeDatastore() -> WorkspaceSQLiteDatastoreActor {
        WorkspaceSQLiteDatastoreFactory(
            coreDatabaseURL: coreDatabaseURL,
            localDatabaseURL: localDatabaseURL
        ).makeDatastore()
    }

    func prepareDatastoreForIPC(_ datastore: WorkspaceSQLiteDatastoreActor) async -> Bool {
        guard case .prepared = await datastore.prepareDatabasesForBoot() else { return false }
        guard case .ready = await datastore.prepareOptionalApplicationLocalSchema() else { return false }
        return true
    }

    nonisolated(nonsending) func withServer<Result>(
        credentialResolver: any AgentStudioIPCCredentialResolving,
        credentialContinuityPort: any AgentStudioIPCCredentialContinuityPort,
        canonicalPaneMembership: (@Sendable (UUID, UUID) -> Bool)? = nil,
        releaseHeldWork: @Sendable () async -> Void = {},
        body: (LiveServerFixture) async throws -> Result
    ) async throws -> Result {
        try await withLiveServer(
            makeFixture: {
                try LiveServerFixture(
                    credentialResolver: credentialResolver,
                    credentialContinuityPort: credentialContinuityPort,
                    canonicalPaneMembership: canonicalPaneMembership
                )
            }, releaseHeldWork: releaseHeldWork, body: body)
    }

    func persistUnusedIssuedTokenBeforeShutdown(
        _ token: AgentStudioIPCSubjectToken
    ) async throws -> (paneID: UUID, workspaceID: UUID) {
        let datastore = makeDatastore()
        guard await prepareDatastoreForIPC(datastore) else {
            throw ReusableCredentialTestError.databasePreparationFailed
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        return try await withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: repository,
            body: { serverFixture in
                try await datastore.saveWorkspaceSnapshotBundle(
                    WorkspaceSQLiteSaveBundle(
                        workspace: .init(id: serverFixture.workspaceId, name: "IPC graceful shutdown reopen")
                    )
                )
                try serverFixture.server.start()
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: serverFixture.boundPaneId,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: UUIDv7.generate(),
                    verifierSHA256: Data(SHA256.hash(data: Data(token.rawValue.utf8)))
                )
                await serverFixture.stopAcceptingConnections()
                #expect(await serverFixture.server.drainCredentialPersistence().failedOperationCount == 0)
                #expect(throws: AgentStudioIPCIssuedCredentialRegistrationError.registryShutdown) {
                    try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                        paneID: UUIDv7.generate(),
                        workspaceID: serverFixture.workspaceId,
                        credentialRecordID: UUIDv7.generate(),
                        verifierSHA256: Data(repeating: 0xA5, count: 32)
                    )
                }
                return (serverFixture.boundPaneId, serverFixture.workspaceId)
            })
    }

    func loginAndReadSystemVersion(
        fixture: LiveServerFixture,
        token: AgentStudioIPCSubjectToken,
        requestID: Int
    ) async throws -> ReusableCredentialLoginResult {
        let connection = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
        defer { connection.close() }
        var reader = TestFrameReader()
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(requestID), method: "auth.login", params: .object(["token": .string(token.rawValue)])
            )
        )
        let loginResponse = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        let loginStatus = try decodeResponseResult(IPCAuthStatusResult.self, from: loginResponse)
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: JSONRPCClientRequest(id: .number(requestID + 1), method: "system.version", params: .object([:]))
        )
        let response = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
        let version = try decodeResponseResult(IPCSystemVersionResult.self, from: response)
        #expect(!version.appVersion.isEmpty)
        guard case .authenticated(let principalID, let runtimeID, let accessMode, _) = loginStatus else {
            throw ReusableCredentialTestError.unauthenticated
        }
        return .init(principalID: principalID, runtimeID: runtimeID, accessMode: accessMode)
    }

    func loginResponse(
        fixture: LiveServerFixture,
        token: AgentStudioIPCSubjectToken,
        requestID: Int
    ) async throws -> JSONRPCResponseMessage {
        let connection = try await connectWithoutBlockingCooperativePool(socketPath: fixture.paths.socketURL.path)
        defer { connection.close() }
        try await sendRequestWithoutBlockingCooperativePool(
            connection: connection,
            request: JSONRPCClientRequest(
                id: .number(requestID), method: "auth.login", params: .object(["token": .string(token.rawValue)])
            )
        )
        var reader = TestFrameReader()
        return try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

extension IPCAuthStatusResult {
    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

final class HeldCredentialContinuityPort: AgentStudioIPCCredentialContinuityPort,
    @unchecked Sendable
{
    private let repository: IPCContinuityRepository
    private let lock = NSLock()
    private let firstRegistrationStep: HeldStep<AgentStudioIPCIssuedPaneCredential>?
    private let registrationStep = HeldStep<AgentStudioIPCIssuedPaneCredential>(
        "pane verifier registration before repository write"
    )
    private var didRelease = false
    private var storedRegistrationCallCount = 0

    init(
        repository: IPCContinuityRepository,
        firstRegistrationStep: HeldStep<AgentStudioIPCIssuedPaneCredential>? = nil
    ) {
        self.repository = repository
        self.firstRegistrationStep = firstRegistrationStep
    }

    var registrationCallCount: Int { lock.withLock { storedRegistrationCallCount } }
    var observedRelease: Bool { lock.withLock { didRelease } }

    func registerIssuedPaneCredential(
        _ credential: AgentStudioIPCIssuedPaneCredential,
        if remainsEligible: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let step = lock.withLock {
            storedRegistrationCallCount += 1
            return storedRegistrationCallCount == 1 ? firstRegistrationStep ?? registrationStep : registrationStep
        }
        try await step.arrive(credential)
        return try await repository.registerIssuedPaneCredential(credential, if: remainsEligible)
    }

    func revokeAllPaneCredentials(paneID: UUID) async throws {
        try await repository.revokeAllPaneCredentials(paneID: paneID)
    }

    func waitUntilRegistrationHeld() async throws -> AgentStudioIPCIssuedPaneCredential {
        try await registrationStep.firstArrival()
    }

    func releaseRegistration() {
        lock.withLock { didRelease = true }
        firstRegistrationStep?.release()
        registrationStep.release()
    }
}

final class ReusableCredentialMembershipGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsMember = true

    var isMember: Bool { lock.withLock { storedIsMember } }

    func setMember(_ isMember: Bool) {
        lock.withLock { storedIsMember = isMember }
    }
}

struct ReusableCredentialLoginResult: Equatable {
    let principalID: UUID
    let runtimeID: UUID
    let accessMode: IPCAccessMode
}

enum ReusableCredentialTestError: Error {
    case unauthenticated
    case databasePreparationFailed
    case deliberateRegistrationFailure
    /// Stands in for a transport/decode failure staged after a credential
    /// write is held, so the failure-cleanup path can be exercised without a
    /// production hook.
    case deliberateFailureAfterHold
}
