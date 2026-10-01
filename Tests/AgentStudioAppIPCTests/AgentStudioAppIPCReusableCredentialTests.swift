import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import CryptoKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@Suite("App IPC reusable persisted credentials", .serialized)
struct AgentStudioAppIPCReusableCredentialTests {
    @Test("current RAM and older durable pane verifiers authenticate sequential Unix connections")
    func currentRAMAndOlderDurableVerifiersAuthenticateSequentialConnections() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let durableToken = AgentStudioIPCSubjectToken(
            rawValue: Data(repeating: 0xA5, count: 32).base64EncodedString())
        let currentToken = AgentStudioIPCSubjectToken(
            rawValue: Data(repeating: 0xB4, count: 32).base64EncodedString())
        let durableVerifier = Data(SHA256.hash(data: Data(durableToken.rawValue.utf8)))
        let currentVerifier = Data(SHA256.hash(data: Data(currentToken.rawValue.utf8)))
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: repository,
            body: { serverFixture in
                let paneID = serverFixture.boundPaneId
                let durableRecordID = UUIDv7.generate()
                let currentRecordID = UUIDv7.generate()
                try await repository.registerPaneCredential(
                    IPCPaneCredential(
                        paneID: paneID,
                        workspaceID: serverFixture.workspaceId,
                        credentialRecordID: durableRecordID,
                        verifierSHA256: durableVerifier,
                        status: .registered
                    )
                )
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: paneID,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: currentRecordID,
                    verifierSHA256: currentVerifier
                )
                try serverFixture.server.start()

                for (index, token) in [currentToken, durableToken, currentToken, durableToken].enumerated() {
                    let login = try await fixture.loginAndReadSystemVersion(
                        fixture: serverFixture,
                        token: token,
                        requestID: 10 + (index * 10)
                    )
                    #expect(login.runtimeID == serverFixture.runtimeId)
                    #expect(login.accessMode == .agentStudioOnly)
                }

                let forged = AgentStudioIPCSubjectToken(
                    rawValue: Data(repeating: 0x5A, count: 32).base64EncodedString())
                let rejected = try await fixture.loginResponse(fixture: serverFixture, token: forged, requestID: 30)
                #expect(rejected.error?.code == -32_001)
                let stored = try #require(
                    try await repository.paneCredential(paneID: paneID, credentialRecordID: durableRecordID))
                #expect(stored.verifierSHA256 == durableVerifier)
                #expect(stored.verifierSHA256 != Data(durableToken.rawValue.utf8))
                #expect(
                    try await repository.paneCredential(paneID: paneID, credentialRecordID: currentRecordID)?.status
                        == .registered)
            })
    }

    @Test("revoked durable pane credential cannot authenticate")
    func revokedPaneCredentialIsRejectedBeforeMethodAdmission() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let token = AgentStudioIPCSubjectToken(rawValue: Data(repeating: 0xA5, count: 32).base64EncodedString())
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: repository,
            body: { serverFixture in
                try await repository.registerPaneCredential(
                    IPCPaneCredential(
                        paneID: serverFixture.boundPaneId,
                        workspaceID: serverFixture.workspaceId,
                        credentialRecordID: UUIDv7.generate(),
                        verifierSHA256: Data(SHA256.hash(data: Data(token.rawValue.utf8))),
                        status: .revoked
                    )
                )
                try serverFixture.server.start()
                let response = try await fixture.loginResponse(fixture: serverFixture, token: token, requestID: 40)
                #expect(response.error?.code == -32_001)
            })
    }

    @Test("canonical close denial and final revocation refuse existing pane credential without a result")
    func canonicalCloseAndFinalRevocationRefuseCredential() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let membership = ReusableCredentialMembershipGate()
        let durableToken = AgentStudioIPCSubjectToken(
            rawValue: Data(repeating: 0xC3, count: 32).base64EncodedString())
        let currentToken = AgentStudioIPCSubjectToken(
            rawValue: Data(repeating: 0xD4, count: 32).base64EncodedString())
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: repository,
            canonicalPaneMembership: { _, _ in membership.isMember },
            body: { serverFixture in
                try await repository.registerPaneCredential(
                    IPCPaneCredential(
                        paneID: serverFixture.boundPaneId,
                        workspaceID: serverFixture.workspaceId,
                        credentialRecordID: UUIDv7.generate(),
                        verifierSHA256: Data(SHA256.hash(data: Data(durableToken.rawValue.utf8))),
                        status: .registered
                    )
                )
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: serverFixture.boundPaneId,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: UUIDv7.generate(),
                    verifierSHA256: Data(SHA256.hash(data: Data(currentToken.rawValue.utf8)))
                )
                try serverFixture.server.start()
                let connection = try await connectWithoutBlockingCooperativePool(
                    socketPath: serverFixture.paths.socketURL.path)
                defer { connection.close() }
                var reader = TestFrameReader()
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(
                        id: .number(50), method: "auth.login",
                        params: .object(["token": .string(durableToken.rawValue)]))
                )
                let initialLoginResponse = try await reader.receiveResponseWithoutBlockingMainActor(
                    connection: connection)
                let initialLoginStatus = try decodeResponseResult(IPCAuthStatusResult.self, from: initialLoginResponse)
                guard case .authenticated = initialLoginStatus else {
                    Issue.record("Expected initial credential login to authenticate")
                    return
                }

                membership.setMember(false)
                try await sendRequestWithoutBlockingCooperativePool(
                    connection: connection,
                    request: JSONRPCClientRequest(id: .number(51), method: "system.version", params: .object([:]))
                )
                let closedResponse = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
                #expect(closedResponse.result == nil)
                #expect(closedResponse.error?.code == -32_001)

                serverFixture.server.finalRevokePrincipals(boundToPaneID: serverFixture.boundPaneId)
                #expect(await serverFixture.server.drainCredentialPersistence().failedOperationCount == 0)
                membership.setMember(true)
                for (index, token) in [durableToken, currentToken].enumerated() {
                    let finalResponse = try await fixture.loginResponse(
                        fixture: serverFixture,
                        token: token,
                        requestID: 52 + index
                    )
                    #expect(finalResponse.result == nil)
                    #expect(finalResponse.error?.code == -32_001)
                }
            })
    }

    @Test("socket authentication does not await held persistence and duplicate admission coalesces")
    func socketAuthenticationDoesNotAwaitHeldPersistence() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        let barrierPort = HeldCredentialContinuityPort(repository: repository)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: barrierPort, releaseHeldWork: { barrierPort.releaseRegistration() },
            body: { serverFixture in
                try serverFixture.server.start()
                let token = AgentStudioIPCSubjectToken(rawValue: "held-persistence-token")
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: serverFixture.boundPaneId,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: UUIDv7.generate(),
                    verifierSHA256: Data(SHA256.hash(data: Data(token.rawValue.utf8)))
                )

                let first = try await fixture.loginResponse(fixture: serverFixture, token: token, requestID: 60)
                let second = try await fixture.loginResponse(fixture: serverFixture, token: token, requestID: 61)
                #expect(try decodeResponseResult(IPCAuthStatusResult.self, from: first).isAuthenticated)
                #expect(try decodeResponseResult(IPCAuthStatusResult.self, from: second).isAuthenticated)
                await barrierPort.waitUntilRegistrationHeld()
                #expect(barrierPort.registrationCallCount == 1)

                barrierPort.releaseRegistration()
                serverFixture.stopAcceptingConnections()
                #expect(await serverFixture.server.drainCredentialPersistence().failedOperationCount == 0)
                #expect(barrierPort.registrationCallCount == 1)
            })
    }

    /// Joining connection handlers before draining credentials is the fix for
    /// S1/R9: a handler that authenticated enqueues its registration
    /// synchronously, on its own task, before that task returns — so by the
    /// time the handler is joined, the enqueue has already happened. This is
    /// a real-path completion proof: a genuine handler-originated write
    /// reaches and clears the drain, with join running first. It does not
    /// itself force or reproduce the late-enqueue race — that ordering
    /// guarantee is pinned statically in ApplicationEntrypointArchitectureTests
    /// against the production source, not re-derived here by scheduling.
    @Test("a handler's enqueued write reaches the drain after joining, in a real auth.login round trip")
    func aHandlersEnqueuedWriteReachesTheDrainAfterJoiningInARealRoundTrip() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        let barrierPort = HeldCredentialContinuityPort(repository: repository)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: barrierPort, releaseHeldWork: { barrierPort.releaseRegistration() },
            body: { serverFixture in
                try serverFixture.server.start()
                let token = AgentStudioIPCSubjectToken(rawValue: "join-before-drain-token")
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: serverFixture.boundPaneId,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: UUIDv7.generate(),
                    verifierSHA256: Data(SHA256.hash(data: Data(token.rawValue.utf8)))
                )

                // The handler's own task: it enqueues synchronously (inside
                // auth.login's authenticate closure) before returning the
                // response, so the login round trip already proves the enqueue
                // happened.
                let response = try await fixture.loginResponse(fixture: serverFixture, token: token, requestID: 90)
                #expect(try decodeResponseResult(IPCAuthStatusResult.self, from: response).isAuthenticated)
                // Event-driven: the worker has genuinely started the held write,
                // not merely been enqueued and left pending.
                await barrierPort.waitUntilRegistrationHeld()
                #expect(barrierPort.registrationCallCount == 1)

                serverFixture.stopAcceptingConnections()
                // The handler's own task is independent of the credential worker
                // task the held write is parked in, so joining it does not
                // itself wait on the held write — this is the production
                // ordering, not an incidental step.
                await serverFixture.server.joinConnectionHandlers()

                barrierPort.releaseRegistration()
                let result = await serverFixture.server.drainCredentialPersistence()
                #expect(result.failedOperationCount == 0)
                #expect(barrierPort.registrationCallCount == 1)
            })
    }

    /// R10: proves the failure-cleanup path this test's own do/catch relies
    /// on actually reaches completion — a throw staged after the write is
    /// held, deliberately, without production failure injection.
    @Test("a throw after the write is held still releases it, joins, and drains")
    func aThrowAfterTheWriteIsHeldStillReleasesJoinsAndDrains() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        let barrierPort = HeldCredentialContinuityPort(repository: repository)
        var scopedServer: LiveServerFixture?
        do {
            try await fixture.withServer(
                credentialResolver: IPCContinuityCredentialResolver(repository: repository),
                credentialContinuityPort: barrierPort, releaseHeldWork: { barrierPort.releaseRegistration() },
                body: { serverFixture in
                    scopedServer = serverFixture
                    try serverFixture.server.start()
                    let token = AgentStudioIPCSubjectToken(rawValue: "throw-after-hold-token")
                    try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                        paneID: serverFixture.boundPaneId,
                        workspaceID: serverFixture.workspaceId,
                        credentialRecordID: UUIDv7.generate(),
                        verifierSHA256: Data(SHA256.hash(data: Data(token.rawValue.utf8)))
                    )
                    let response = try await fixture.loginResponse(fixture: serverFixture, token: token, requestID: 91)
                    #expect(try decodeResponseResult(IPCAuthStatusResult.self, from: response).isAuthenticated)
                    await barrierPort.waitUntilRegistrationHeld()
                    #expect(barrierPort.registrationCallCount == 1)

                    // Deliberate, test-local failure: stands in for the
                    // transport/decode throw the reviewer identified, staged after
                    // the write is held and before any release.
                    throw ReusableCredentialTestError.deliberateFailureAfterHold
                })
        } catch {
            guard case ReusableCredentialTestError.deliberateFailureAfterHold = error else { throw error }
        }
        let serverFixture = try #require(scopedServer)

        // Asserts on what the cleanup above left behind, not on a second
        // guess: the continuity port observed the release, the one queued
        // write was processed, and no handler is left tracked.
        #expect(barrierPort.observedRelease)
        #expect(barrierPort.registrationCallCount == 1)
        #expect(serverFixture.server.trackedConnectionHandlerCount == 0)
    }

    @Test("graceful shutdown persists an unused issued token that authenticates after reopen")
    func gracefulShutdownPersistsUnusedIssuedToken() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let token = AgentStudioIPCSubjectToken(rawValue: "unused-shutdown-token")
        let persistedIdentity = try await fixture.persistUnusedIssuedTokenBeforeShutdown(token)

        let reopenedDatastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(reopenedDatastore) else {
            Issue.record("Reopened database preparation failed")
            return
        }
        let reopenedRepository = IPCContinuityRepository(datastore: reopenedDatastore)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: reopenedRepository),
            credentialContinuityPort: reopenedRepository,
            canonicalPaneMembership: { paneID, workspaceID in
                paneID == persistedIdentity.paneID && workspaceID == persistedIdentity.workspaceID
            },
            body: { secondServer in
                try secondServer.server.start()
                let response = try await fixture.loginResponse(fixture: secondServer, token: token, requestID: 70)
                #expect(try decodeResponseResult(IPCAuthStatusResult.self, from: response).isAuthenticated)
            })
    }

    @MainActor
    @Test("the App-owned final fence recorded before server publication replays before registration")
    func preServerFinalFenceReplaysBeforeCredentialRegistration() async throws {
        let fixture = try ReusableCredentialFixture()
        defer { fixture.cleanup() }
        let datastore = fixture.makeDatastore()
        guard await fixture.prepareDatastoreForIPC(datastore) else {
            Issue.record("Database preparation failed")
            return
        }
        let repository = IPCContinuityRepository(datastore: datastore)
        try await fixture.withServer(
            credentialResolver: IPCContinuityCredentialResolver(repository: repository),
            credentialContinuityPort: repository,
            body: { serverFixture in
                let durableRecordID = UUIDv7.generate()
                let issuedRecordID = UUIDv7.generate()
                let appDelegate = AppDelegate()
                appDelegate.appIPCPrincipalRegistry = serverFixture.server.principalRegistry
                appDelegate.paneIPCIdentityOwner = PaneIPCIdentityOwner(
                    principalRegistry: serverFixture.server.principalRegistry,
                    socketURL: serverFixture.paths.socketURL,
                    spoolDirectory: serverFixture.paths.spoolDirectory,
                    cliExecutableURL: fixture.rootURL.appending(path: "AgentStudio.app/Contents/Helpers/agentstudio"),
                    inheritedEnvironment: [:],
                    canonicalPaneMembership: { _, _ in true }
                )
                #expect(appDelegate.appIPCPrincipalRegistry === serverFixture.server.principalRegistry)
                try await repository.registerPaneCredential(
                    IPCPaneCredential(
                        paneID: serverFixture.boundPaneId,
                        workspaceID: serverFixture.workspaceId,
                        credentialRecordID: durableRecordID,
                        verifierSHA256: Data(repeating: 0xA5, count: 32),
                        status: .registered
                    )
                )
                try serverFixture.server.principalRegistry.registerIssuedPaneCredential(
                    paneID: serverFixture.boundPaneId,
                    workspaceID: serverFixture.workspaceId,
                    credentialRecordID: issuedRecordID,
                    verifierSHA256: Data(repeating: 0xB4, count: 32)
                )
                appDelegate.appIPCWorkspaceSurfaceLifecycle().finalRevokePaneIDs([serverFixture.boundPaneId])

                try serverFixture.server.start()
                await serverFixture.shutdownThroughApplication(appDelegate)
                #expect(appDelegate.appIPCServer == nil)

                let storedCredentials = try await repository.paneCredentials(paneID: serverFixture.boundPaneId)
                #expect(storedCredentials.map(\.credentialRecordID) == [durableRecordID])
                #expect(storedCredentials.first?.status == .revoked)
                #expect(!storedCredentials.contains { $0.credentialRecordID == issuedRecordID })
            })
    }

}

private struct ReusableCredentialFixture {
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
        canonicalPaneMembership: (@MainActor @Sendable (UUID, UUID) -> Bool)? = nil,
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
                serverFixture.stopAcceptingConnections()
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
        guard case .authenticated(let principalID, let runtimeID, let accessMode) = loginStatus else {
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
    fileprivate var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

private final class HeldCredentialContinuityPort: AgentStudioIPCCredentialContinuityPort,
    @unchecked Sendable
{
    private let repository: IPCContinuityRepository
    private let lock = NSLock()
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didHold = false
    private var didRelease = false
    private var storedRegistrationCallCount = 0

    init(repository: IPCContinuityRepository) {
        self.repository = repository
    }

    var registrationCallCount: Int { lock.withLock { storedRegistrationCallCount } }
    var observedRelease: Bool { lock.withLock { didRelease } }

    func registerIssuedPaneCredential(
        _ credential: AgentStudioIPCIssuedPaneCredential,
        if remainsEligible: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        await holdRegistration()
        return try await repository.registerIssuedPaneCredential(credential, if: remainsEligible)
    }

    func revokeAllPaneCredentials(paneID: UUID) async throws {
        try await repository.revokeAllPaneCredentials(paneID: paneID)
    }

    func waitUntilRegistrationHeld() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard !didHold else { return true }
                heldContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseRegistration() {
        lock.withLock {
            didRelease = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private func holdRegistration() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                storedRegistrationCallCount += 1
                didHold = true
                heldContinuation?.resume()
                heldContinuation = nil
                guard !didRelease else { return true }
                releaseContinuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

private final class ReusableCredentialMembershipGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIsMember = true

    var isMember: Bool { lock.withLock { storedIsMember } }

    func setMember(_ isMember: Bool) {
        lock.withLock { storedIsMember = isMember }
    }
}

private struct ReusableCredentialLoginResult: Equatable {
    let principalID: UUID
    let runtimeID: UUID
    let accessMode: IPCAccessMode
}

private enum ReusableCredentialTestError: Error {
    case unauthenticated
    case databasePreparationFailed
    /// Stands in for a transport/decode failure staged after a credential
    /// write is held, so the failure-cleanup path can be exercised without a
    /// production hook.
    case deliberateFailureAfterHold
}
