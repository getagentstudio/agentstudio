import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioAppIPC

@Suite("AgentStudio IPC authentication")
struct AgentStudioIPCAuthenticationTests {
    @Test("the same active credential authenticates repeatedly with one durable lease identity")
    func sameActiveCredentialAuthenticatesRepeatedly() async throws {
        let runtimeID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let credentialRecordID = UUIDv7.generate()
        let token = AgentStudioIPCSubjectToken(rawValue: "active-pane-token")
        let registry = makeRegistry(
            runtimeID: runtimeID,
            outcomes: [
                token.rawValue: .resolved(
                    paneResolution(
                        paneID: paneID,
                        workspaceID: workspaceID,
                        credentialRecordID: credentialRecordID,
                        status: .registered
                    )
                )
            ]
        )

        let first = try await registry.authenticate(subjectToken: token)
        let second = try await registry.authenticate(subjectToken: token)

        #expect(first.credentialIdentity == .pane(recordID: credentialRecordID))
        #expect(second.credentialIdentity == .pane(recordID: credentialRecordID))
        #expect(first.principal.principalId != second.principal.principalId)
        #expect(
            first.principal.kind
                == .spawnedPaneAgent(boundPaneId: paneID.uuidString, boundWorkspaceId: workspaceID)
        )
    }

    @Test("disconnect release revokes only the exact ephemeral principal lease")
    func disconnectReleaseKeepsSiblingLeaseGrant() async throws {
        let runtimeID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let token = AgentStudioIPCSubjectToken(rawValue: "reconnect-token")
        let ledger = GrantLedger()
        let registry = makeRegistry(
            runtimeID: runtimeID,
            outcomes: [
                token.rawValue: .resolved(
                    paneResolution(
                        paneID: paneID,
                        workspaceID: workspaceID,
                        credentialRecordID: UUIDv7.generate(),
                        status: .registered
                    )
                )
            ],
            grantLedger: ledger
        )
        let first = try await registry.authenticate(subjectToken: token)
        let second = try await registry.authenticate(subjectToken: token)
        let firstScope = IPCPermissionScope(
            privilege: .terminalInputWrite,
            target: .pane(paneID.uuidString),
            dataScope: .terminalInput
        )
        let secondScope = IPCPermissionScope(
            privilege: .terminalInputWrite,
            target: .pane(paneID.uuidString),
            dataScope: .terminalInput
        )
        ledger.grant(firstScope, to: first.principal.principalId)
        ledger.grant(secondScope, to: second.principal.principalId)

        registry.releaseLease(first)

        #expect(!ledger.contains(firstScope, for: first.principal.principalId))
        #expect(ledger.contains(secondScope, for: second.principal.principalId))
    }

    @Test("login ignores caller hints and returns the full authenticated context")
    func loginReturnsContextWithoutCallerHints() async throws {
        let runtimeID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let credentialRecordID = UUIDv7.generate()
        let token = AgentStudioIPCSubjectToken(rawValue: "login-token")
        let registry = makeRegistry(
            runtimeID: runtimeID,
            outcomes: [
                token.rawValue: .resolved(
                    paneResolution(
                        paneID: paneID,
                        workspaceID: workspaceID,
                        credentialRecordID: credentialRecordID,
                        status: .registered
                    )
                )
            ]
        )

        let login = try await AgentStudioIPCAuthenticator(registry: registry).login(subjectToken: token)

        #expect(login.authenticatedContext.credentialIdentity == .pane(recordID: credentialRecordID))
        #expect(
            login.principal.kind
                == .spawnedPaneAgent(
                    boundPaneId: paneID.uuidString,
                    boundWorkspaceId: workspaceID
                ))
    }

    @Test("forged and missing credentials are rejected without a registry fallback")
    func forgedAndMissingCredentialsAreRejected() async {
        let registry = makeRegistry(runtimeID: UUIDv7.generate(), outcomes: [:])

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(
                subjectToken: AgentStudioIPCSubjectToken(rawValue: "missing-token")
            )
        }
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(
                subjectToken: AgentStudioIPCSubjectToken(rawValue: "forged-token")
            )
        }
    }

    @Test("revoked credential resolutions cannot authenticate")
    func revokedCredentialsCannotAuthenticate() async {
        let runtimeID = UUIDv7.generate()
        let revokedToken = AgentStudioIPCSubjectToken(rawValue: "revoked-token")
        let registry = makeRegistry(
            runtimeID: runtimeID,
            outcomes: [
                revokedToken.rawValue: .resolved(
                    paneResolution(
                        paneID: UUIDv7.generate(),
                        workspaceID: UUIDv7.generate(),
                        credentialRecordID: UUIDv7.generate(),
                        status: .revoked
                    )
                )
            ]
        )

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(subjectToken: revokedToken)
        }
    }

    @Test("the installed debug credential authenticates from memory without a stored row")
    func installedDebugCredentialAuthenticatesFromMemory() async throws {
        let token = AgentStudioIPCSubjectToken(rawValue: "installed-debug-token")
        let registry = makeRegistry(runtimeID: UUIDv7.generate(), outcomes: [:])

        let generationID = registry.installDiagnosticCredential(verifierSHA256: verifier(for: token))
        let context = try await registry.authenticate(subjectToken: token)

        #expect(context.principal.accessMode == .automationSameUser)
        #expect(context.principal.kind == .automationClient)
        #expect(context.credentialIdentity == .diagnostic(generationID: generationID))
        #expect(context.persistenceCandidate == nil)
    }

    @Test("an unknown debug token never reaches an installed credential's authority")
    func unknownDebugTokenIsRefused() async {
        let installedToken = AgentStudioIPCSubjectToken(rawValue: "installed-debug-token")
        let unknownToken = AgentStudioIPCSubjectToken(rawValue: "unknown-debug-token")
        let registry = makeRegistry(runtimeID: UUIDv7.generate(), outcomes: [:])
        _ = registry.installDiagnosticCredential(verifierSHA256: verifier(for: installedToken))

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(subjectToken: unknownToken)
        }
    }

    @Test("revoking the debug credential refuses the token it admitted")
    func revokedDebugCredentialIsRefused() async throws {
        let token = AgentStudioIPCSubjectToken(rawValue: "revoked-debug-token")
        let registry = makeRegistry(runtimeID: UUIDv7.generate(), outcomes: [:])
        _ = registry.installDiagnosticCredential(verifierSHA256: verifier(for: token))
        _ = try await registry.authenticate(subjectToken: token)

        registry.revokeDiagnosticCredential()

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(subjectToken: token)
        }
    }

    @Test("a replacement debug generation refuses the credential it replaced")
    func replacedDebugGenerationRefusesTheEarlierCredential() async throws {
        let firstToken = AgentStudioIPCSubjectToken(rawValue: "first-debug-token")
        let secondToken = AgentStudioIPCSubjectToken(rawValue: "second-debug-token")
        let registry = makeRegistry(runtimeID: UUIDv7.generate(), outcomes: [:])
        let firstGenerationID = registry.installDiagnosticCredential(verifierSHA256: verifier(for: firstToken))

        let secondGenerationID = registry.installDiagnosticCredential(verifierSHA256: verifier(for: secondToken))
        let context = try await registry.authenticate(subjectToken: secondToken)

        #expect(secondGenerationID != firstGenerationID)
        #expect(context.credentialIdentity == .diagnostic(generationID: secondGenerationID))
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(subjectToken: firstToken)
        }
    }

    @Test("current RAM and older durable pane verifiers coexist across repeated authentication")
    func currentRAMAndOlderDurablePaneVerifiersCoexist() async throws {
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let currentToken = AgentStudioIPCSubjectToken(rawValue: "current-memory-pane-token")
        let durableToken = AgentStudioIPCSubjectToken(rawValue: "older-durable-pane-token")
        let currentRecordID = UUIDv7.generate()
        let durableRecordID = UUIDv7.generate()
        let durableResolver = StaticCredentialResolver(
            outcomes: [
                durableToken.rawValue: .resolved(
                    paneResolution(
                        paneID: paneID,
                        workspaceID: workspaceID,
                        credentialRecordID: durableRecordID,
                        status: .registered
                    )
                )
            ]
        )
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: durableResolver,
            canonicalPaneMembership: { candidatePaneID, candidateWorkspaceID in
                candidatePaneID == paneID && candidateWorkspaceID == workspaceID
            }
        )
        try registry.registerIssuedPaneCredential(
            paneID: paneID,
            workspaceID: workspaceID,
            credentialRecordID: currentRecordID,
            verifierSHA256: Data(SHA256.hash(data: Data(currentToken.rawValue.utf8)))
        )

        let firstCurrent = try await registry.authenticate(subjectToken: currentToken)
        let secondCurrent = try await registry.authenticate(subjectToken: currentToken)
        let firstDurable = try await registry.authenticate(subjectToken: durableToken)
        let secondDurable = try await registry.authenticate(subjectToken: durableToken)

        #expect(firstCurrent.credentialIdentity == .pane(recordID: currentRecordID))
        #expect(secondCurrent.credentialIdentity == .pane(recordID: currentRecordID))
        #expect(firstDurable.credentialIdentity == .pane(recordID: durableRecordID))
        #expect(secondDurable.credentialIdentity == .pane(recordID: durableRecordID))
        #expect(await durableResolver.lookupCount == 2)
        #expect(
            firstCurrent.principal.kind
                == .spawnedPaneAgent(
                    boundPaneId: paneID.uuidString,
                    boundWorkspaceId: workspaceID
                ))
        #expect(firstDurable.principal.kind == firstCurrent.principal.kind)
    }

    @Test("issued pane record identity is immutable across verifier conflicts")
    func issuedPaneRecordIdentityRejectsConflictingVerifier() async throws {
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let credentialRecordID = UUIDv7.generate()
        let originalToken = AgentStudioIPCSubjectToken(rawValue: "original-record-token")
        let conflictingToken = AgentStudioIPCSubjectToken(rawValue: "conflicting-record-token")
        let registry = makeRegistry(runtimeID: UUIDv7.generate(), outcomes: [:])
        try registry.registerIssuedPaneCredential(
            paneID: paneID,
            workspaceID: workspaceID,
            credentialRecordID: credentialRecordID,
            verifierSHA256: Data(SHA256.hash(data: Data(originalToken.rawValue.utf8)))
        )

        #expect(throws: AgentStudioIPCIssuedCredentialRegistrationError.conflictingRecordIdentity) {
            try registry.registerIssuedPaneCredential(
                paneID: paneID,
                workspaceID: workspaceID,
                credentialRecordID: credentialRecordID,
                verifierSHA256: Data(SHA256.hash(data: Data(conflictingToken.rawValue.utf8)))
            )
        }

        let original = try await registry.authenticate(subjectToken: originalToken)
        #expect(original.credentialIdentity == .pane(recordID: credentialRecordID))
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(subjectToken: conflictingToken)
        }
    }

    @Test("rotation during credential lookup rejects the suspended authentication")
    func rotationDuringLookupRejectsAuthentication() async {
        let runtimeID = UUIDv7.generate()
        let token = AgentStudioIPCSubjectToken(rawValue: "rotating-token")
        let resolver = SuspendedCredentialResolver()
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: runtimeID,
            credentialResolver: resolver,
            canonicalPaneMembership: { _, _ in true }
        )
        let authenticationTask = Task {
            try await registry.authenticate(subjectToken: token)
        }
        await resolver.waitUntilLookupStarted()

        registry.rotateTokens()
        await resolver.resume(
            with: paneResolution(
                paneID: UUIDv7.generate(),
                workspaceID: UUIDv7.generate(),
                credentialRecordID: UUIDv7.generate(),
                status: .registered
            )
        )

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await authenticationTask.value
        }
    }

    @Test("pane invalidation during credential lookup rejects the suspended authentication")
    func paneInvalidationDuringLookupRejectsAuthentication() async {
        let paneID = UUIDv7.generate()
        let runtimeID = UUIDv7.generate()
        let resolver = SuspendedCredentialResolver()
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: runtimeID,
            credentialResolver: resolver,
            canonicalPaneMembership: { _, _ in true }
        )
        let authenticationTask = Task {
            try await registry.authenticate(
                subjectToken: AgentStudioIPCSubjectToken(rawValue: "invalidated-pane-token")
            )
        }
        await resolver.waitUntilLookupStarted()

        registry.invalidatePrincipals(boundToPaneId: paneID.uuidString)
        await resolver.resume(
            with: paneResolution(
                paneID: paneID,
                workspaceID: UUIDv7.generate(),
                credentialRecordID: UUIDv7.generate(),
                status: .registered
            ))

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await authenticationTask.value
        }
    }

    @Test("final fence rejects cached RAM and suspended durable pane authentication")
    func finalFenceRejectsCachedRAMAndSuspendedDurableAuthentication() async throws {
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let currentToken = AgentStudioIPCSubjectToken(rawValue: "final-fenced-current-token")
        let durableToken = AgentStudioIPCSubjectToken(rawValue: "final-fenced-durable-token")
        let resolver = SuspendedCredentialResolver()
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: resolver,
            canonicalPaneMembership: { _, _ in true }
        )
        try registry.registerIssuedPaneCredential(
            paneID: paneID,
            workspaceID: workspaceID,
            credentialRecordID: UUIDv7.generate(),
            verifierSHA256: Data(SHA256.hash(data: Data(currentToken.rawValue.utf8)))
        )
        let durableAuthenticationTask = Task {
            try await registry.authenticate(subjectToken: durableToken)
        }
        await resolver.waitUntilLookupStarted()

        registry.finalRevokePane(paneID)
        #expect(registry.finalRevokedPaneIDsSnapshot() == [paneID])
        await resolver.resume(
            with: paneResolution(
                paneID: paneID,
                workspaceID: workspaceID,
                credentialRecordID: UUIDv7.generate(),
                status: .registered
            ))

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await registry.authenticate(subjectToken: currentToken)
        }
        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await durableAuthenticationTask.value
        }
    }

    @Test("shutdown during credential lookup rejects the suspended authentication")
    func shutdownDuringLookupRejectsAuthentication() async {
        let runtimeID = UUIDv7.generate()
        let resolver = SuspendedCredentialResolver()
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: runtimeID,
            credentialResolver: resolver,
            canonicalPaneMembership: { _, _ in true }
        )
        let authenticationTask = Task {
            try await registry.authenticate(
                subjectToken: AgentStudioIPCSubjectToken(rawValue: "shutdown-token")
            )
        }
        await resolver.waitUntilLookupStarted()

        registry.shutdown()
        await resolver.resume(
            with: paneResolution(
                paneID: UUIDv7.generate(),
                workspaceID: UUIDv7.generate(),
                credentialRecordID: UUIDv7.generate(),
                status: .registered
            )
        )

        await #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try await authenticationTask.value
        }
    }

    @Test("pre-auth allowlist admits ping status and login only")
    func preAuthAllowlistAdmitsPingStatusAndLoginOnly() {
        #expect(AgentStudioIPCPreAuthMethods.isAllowed("system.ping"))
        #expect(AgentStudioIPCPreAuthMethods.isAllowed("auth.login"))
        #expect(AgentStudioIPCPreAuthMethods.isAllowed("auth.status"))
        #expect(!AgentStudioIPCPreAuthMethods.isAllowed("terminal.send"))
    }

    @Test("peer gate rejects different local users")
    func peerGateRejectsDifferentLocalUsers() throws {
        let gate = AgentStudioIPCPeerCredentialGate(currentUserIdentifier: 501)

        try gate.validate(PeerCredentials(userIdentifier: 501, groupIdentifier: 20, peerProcess: nil))
        #expect(throws: AgentStudioIPCAuthenticationError.self) {
            try gate.validate(PeerCredentials(userIdentifier: 502, groupIdentifier: 20, peerProcess: nil))
        }
    }

    @Test("spawn environment carries routing metadata without bearer tokens")
    func spawnEnvironmentCarriesRoutingMetadataWithoutBearerTokens() {
        let runtimeID = UUIDv7.generate()
        let environment = AgentStudioIPCSpawnEnvironment(
            socketPath: "/tmp/asipc.sock",
            runtimeId: runtimeID
        )

        #expect(environment.variables["AGENTSTUDIO_IPC_SOCKET"] == "/tmp/asipc.sock")
        #expect(environment.variables["AGENTSTUDIO_IPC_RUNTIME_ID"] == runtimeID.uuidString)
        #expect(!environment.variables.keys.contains("AGENTSTUDIO_IPC_TOKEN"))
        #expect(!environment.variables.values.contains("secret-token"))
    }

    @Test("redacts subject tokens from public strings")
    func redactsSubjectTokensFromPublicStrings() {
        let redactor = AgentStudioIPCRedactor(
            subjectTokens: [AgentStudioIPCSubjectToken(rawValue: "secret-token")]
        )

        #expect(redactor.redact("token=secret-token") == "token=<redacted>")
    }
}

private enum CredentialResolutionOutcome: Sendable {
    case resolved(AgentStudioIPCCredentialResolution)
    case rejected(AgentStudioIPCAuthenticationError)
}

private actor StaticCredentialResolver: AgentStudioIPCCredentialResolving {
    private let outcomes: [String: CredentialResolutionOutcome]
    private(set) var lookupCount = 0

    init(outcomes: [String: CredentialResolutionOutcome]) {
        self.outcomes = outcomes
    }

    func resolveCredential(
        _ credential: AgentStudioIPCSubjectToken,
        serverRuntimeID _: UUID
    ) async throws -> AgentStudioIPCCredentialResolution {
        lookupCount += 1
        switch outcomes[credential.rawValue] {
        case .resolved(let resolution):
            return resolution
        case .rejected(let error):
            throw error
        case nil:
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }
    }
}

private actor SuspendedCredentialResolver: AgentStudioIPCCredentialResolving {
    private var lookupStarted = false
    private var lookupStartedContinuation: CheckedContinuation<Void, Never>?
    private var resolutionContinuation:
        CheckedContinuation<
            AgentStudioIPCCredentialResolution,
            Error
        >?

    func resolveCredential(
        _: AgentStudioIPCSubjectToken,
        serverRuntimeID _: UUID
    ) async throws -> AgentStudioIPCCredentialResolution {
        try await withCheckedThrowingContinuation { continuation in
            resolutionContinuation = continuation
            lookupStarted = true
            lookupStartedContinuation?.resume()
            lookupStartedContinuation = nil
        }
    }

    func waitUntilLookupStarted() async {
        guard !lookupStarted else { return }
        await withCheckedContinuation { continuation in
            lookupStartedContinuation = continuation
        }
    }

    func resume(with resolution: AgentStudioIPCCredentialResolution) {
        resolutionContinuation?.resume(returning: resolution)
        resolutionContinuation = nil
    }
}

private func makeRegistry(
    runtimeID: UUID,
    outcomes: [String: CredentialResolutionOutcome],
    grantLedger: GrantLedger? = nil
) -> AgentStudioIPCPrincipalRegistry {
    AgentStudioIPCPrincipalRegistry(
        runtimeId: runtimeID,
        credentialResolver: StaticCredentialResolver(outcomes: outcomes),
        canonicalPaneMembership: { _, _ in true },
        grantLedger: grantLedger ?? GrantLedger()
    )
}

private func paneResolution(
    paneID: UUID,
    workspaceID: UUID,
    credentialRecordID: UUID,
    status: AgentStudioIPCPaneCredentialStatus
) -> AgentStudioIPCCredentialResolution {
    .pane(
        paneID: paneID,
        workspaceID: workspaceID,
        credentialRecordID: credentialRecordID,
        status: status
    )
}

private func verifier(for token: AgentStudioIPCSubjectToken) -> Data {
    Data(SHA256.hash(data: Data(token.rawValue.utf8)))
}
