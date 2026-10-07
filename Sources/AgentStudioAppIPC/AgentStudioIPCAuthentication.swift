import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import CryptoKit
import Foundation

public struct AgentStudioIPCSubjectToken: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AgentStudioIPCAuthenticationError: Error, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case unauthenticated
        case peerUserMismatch
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }
}

package enum AgentStudioIPCIssuedCredentialRegistrationError: Error, Equatable, Sendable {
    case conflictingRecordIdentity
    case conflictingVerifier
    case paneFinalRevoked
    case registryShutdown
}

package protocol AgentStudioIPCCredentialResolving: Sendable {
    func resolveCredential(
        _ credential: AgentStudioIPCSubjectToken,
        serverRuntimeID: UUID
    ) async throws -> AgentStudioIPCCredentialResolution
}

package enum AgentStudioIPCCredentialNamespace: Equatable, Hashable, Sendable {
    case pane(paneID: UUID, workspaceID: UUID)
    case diagnostic(runtimeID: UUID)
}

package enum AgentStudioIPCPaneCredentialStatus: Equatable, Sendable {
    case registered
    case revoked
}

/// Durable credential storage holds pane verifiers only. The reusable debug
/// credential lives in the principal registry's memory for the runtime's
/// lifetime and never reaches this resolver.
package enum AgentStudioIPCCredentialResolution: Equatable, Sendable {
    case pane(
        paneID: UUID,
        workspaceID: UUID,
        credentialRecordID: UUID,
        status: AgentStudioIPCPaneCredentialStatus
    )
}

package enum AgentStudioIPCAuthenticatedCredentialIdentity: Equatable, Hashable, Sendable {
    case pane(recordID: UUID)
    case diagnostic(generationID: UUID)
}

package struct AgentStudioIPCIssuedPaneCredential: Equatable, Sendable {
    package let paneID: UUID
    package let workspaceID: UUID
    package let credentialRecordID: UUID
    package let verifierSHA256: Data

    package init(paneID: UUID, workspaceID: UUID, credentialRecordID: UUID, verifierSHA256: Data) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.credentialRecordID = credentialRecordID
        self.verifierSHA256 = verifierSHA256
    }
}

package struct AgentStudioIPCAuthenticatedContext: Equatable, Sendable {
    package let principal: IPCPrincipal
    package let credentialIdentity: AgentStudioIPCAuthenticatedCredentialIdentity
    package let persistenceCandidate: AgentStudioIPCIssuedPaneCredential?

    package init(
        principal: IPCPrincipal,
        credentialIdentity: AgentStudioIPCAuthenticatedCredentialIdentity,
        persistenceCandidate: AgentStudioIPCIssuedPaneCredential? = nil
    ) {
        self.principal = principal
        self.credentialIdentity = credentialIdentity
        self.persistenceCandidate = persistenceCandidate
    }
}

public final class AgentStudioIPCPrincipalRegistry: @unchecked Sendable {
    public let runtimeId: UUID

    private struct LeaseKey: Hashable, Sendable {
        let namespace: AgentStudioIPCCredentialNamespace
        let credentialIdentity: AgentStudioIPCAuthenticatedCredentialIdentity
    }

    private let lock = NSLock()
    private let credentialResolver: any AgentStudioIPCCredentialResolving
    private let canonicalPaneMembership: @Sendable (UUID, UUID) -> Bool
    package let grantLedger: GrantLedger
    private var lifetimeEpoch: UInt64 = 0
    private var invalidationSequence: UInt64 = 0
    private var paneInvalidationSequences: [UUID: UInt64] = [:]
    private var retiredLeaseSequences: [LeaseKey: UInt64] = [:]
    private var activeLeases: [LeaseKey: Set<UUID>] = [:]
    private var issuedPaneCredentialsByRecordID: [UUID: AgentStudioIPCIssuedPaneCredential] = [:]
    private var issuedPaneCredentialRecordIDByVerifier: [Data: UUID] = [:]
    private var durableIssuedPaneCredentialIDs: Set<UUID> = []
    private var finalRevokedPaneIDs: Set<UUID> = []
    private var installedDebugCredential: InstalledDebugCredential?
    private var isShutdown = false

    package init(
        runtimeId: UUID,
        credentialResolver: any AgentStudioIPCCredentialResolving,
        canonicalPaneMembership: @escaping @Sendable (UUID, UUID) -> Bool,
        grantLedger: GrantLedger = GrantLedger()
    ) {
        self.runtimeId = runtimeId
        self.credentialResolver = credentialResolver
        self.canonicalPaneMembership = canonicalPaneMembership
        self.grantLedger = grantLedger
    }

    package func registerIssuedPaneCredential(
        paneID: UUID,
        workspaceID: UUID,
        credentialRecordID: UUID,
        verifierSHA256: Data
    ) throws {
        precondition(verifierSHA256.count == 32, "pane credential verifier must be SHA-256")
        let credential = AgentStudioIPCIssuedPaneCredential(
            paneID: paneID,
            workspaceID: workspaceID,
            credentialRecordID: credentialRecordID,
            verifierSHA256: verifierSHA256
        )
        try lock.withLock {
            guard !isShutdown else {
                throw AgentStudioIPCIssuedCredentialRegistrationError.registryShutdown
            }
            guard !finalRevokedPaneIDs.contains(paneID) else {
                throw AgentStudioIPCIssuedCredentialRegistrationError.paneFinalRevoked
            }
            if let existing = issuedPaneCredentialsByRecordID[credentialRecordID] {
                guard existing == credential else {
                    throw AgentStudioIPCIssuedCredentialRegistrationError.conflictingRecordIdentity
                }
                return
            }
            if let existingRecordID = issuedPaneCredentialRecordIDByVerifier[verifierSHA256],
                existingRecordID != credentialRecordID
            {
                throw AgentStudioIPCIssuedCredentialRegistrationError.conflictingVerifier
            }
            issuedPaneCredentialsByRecordID[credentialRecordID] = credential
            issuedPaneCredentialRecordIDByVerifier[verifierSHA256] = credentialRecordID
        }
    }

    /// The reusable debug credential exists for this runtime only. Installing a
    /// replacement drops the previous verifier, so the token it replaced stops
    /// authenticating immediately.
    package func installDiagnosticCredential(verifierSHA256: Data) -> UUID {
        precondition(verifierSHA256.count == 32, "debug credential verifier must be SHA-256")
        let generationID = UUIDv7.generate()
        lock.withLock {
            installedDebugCredential = InstalledDebugCredential(
                verifierSHA256: verifierSHA256,
                generationID: generationID
            )
        }
        return generationID
    }

    package func revokeDiagnosticCredential() {
        lock.withLock { installedDebugCredential = nil }
    }

    package func issuedCredentialCandidates() -> [AgentStudioIPCIssuedPaneCredential] {
        lock.withLock {
            issuedPaneCredentialsByRecordID.values
                .filter {
                    !durableIssuedPaneCredentialIDs.contains($0.credentialRecordID)
                        && !finalRevokedPaneIDs.contains($0.paneID)
                }
                .sorted { $0.credentialRecordID.uuidString < $1.credentialRecordID.uuidString }
        }
    }

    package func markIssuedCredentialDurable(recordID: UUID) {
        _ = lock.withLock { durableIssuedPaneCredentialIDs.insert(recordID) }
    }

    package func finalRevokePane(_ paneID: UUID) {
        let principalIDs = lock.withLock {
            finalRevokedPaneIDs.insert(paneID)
            invalidationSequence &+= 1
            paneInvalidationSequences[paneID] = invalidationSequence
            let matchingKeys = activeLeases.keys.filter { key in
                guard case .pane(let boundPaneID, _) = key.namespace else { return false }
                return boundPaneID == paneID
            }
            let principalIDs = Set(matchingKeys.flatMap { activeLeases[$0] ?? [] })
            for key in matchingKeys {
                activeLeases.removeValue(forKey: key)
            }
            return principalIDs
        }
        revokeGrants(for: principalIDs)
    }

    package func finalRevokedPaneIDsSnapshot() -> Set<UUID> {
        lock.withLock { finalRevokedPaneIDs }
    }

    package func beginGracefulShutdownAndSnapshotUnsavedCredentials()
        -> [AgentStudioIPCIssuedPaneCredential]
    {
        let shutdown = lock.withLock {
            () -> (
                [AgentStudioIPCIssuedPaneCredential], Set<UUID>
            ) in
            guard !isShutdown else { return ([], []) }
            isShutdown = true
            lifetimeEpoch &+= 1
            let principalIDs = Set(activeLeases.values.joined())
            activeLeases.removeAll(keepingCapacity: false)
            let snapshot = issuedPaneCredentialsByRecordID.values
                .filter {
                    !durableIssuedPaneCredentialIDs.contains($0.credentialRecordID)
                        && !finalRevokedPaneIDs.contains($0.paneID)
                }
            return (snapshot, principalIDs)
        }
        revokeGrants(for: shutdown.1)
        return shutdown.0
    }

    package func authenticate(
        subjectToken: AgentStudioIPCSubjectToken
    ) async throws -> AgentStudioIPCAuthenticatedContext {
        let observation = lock.withLock {
            AuthObservation(
                lifetimeEpoch: lifetimeEpoch,
                invalidationSequence: invalidationSequence,
                isShutdown: isShutdown
            )
        }
        guard !observation.isShutdown else {
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }

        let verifier = Data(SHA256.hash(data: Data(subjectToken.rawValue.utf8)))
        let memoryMatch = lock.withLock {
            (
                debugGenerationID: installedDebugCredential?.generationID(matching: verifier),
                issuedPaneCredential: issuedPaneCredentialRecordIDByVerifier[verifier]
                    .flatMap { issuedPaneCredentialsByRecordID[$0] }
            )
        }
        let context: AgentStudioIPCAuthenticatedContext
        if let debugGenerationID = memoryMatch.debugGenerationID {
            context = makeDebugAuthenticatedContext(generationID: debugGenerationID)
        } else {
            let issuedCredential = memoryMatch.issuedPaneCredential
            let resolution: AgentStudioIPCCredentialResolution
            if let issuedCredential {
                resolution = .pane(
                    paneID: issuedCredential.paneID,
                    workspaceID: issuedCredential.workspaceID,
                    credentialRecordID: issuedCredential.credentialRecordID,
                    status: .registered
                )
            } else {
                resolution = try await credentialResolver.resolveCredential(
                    subjectToken,
                    serverRuntimeID: runtimeId
                )
            }
            context = try await makeAuthenticatedContext(
                from: resolution,
                persistenceCandidate: issuedCredential
            )
        }
        let namespace = namespace(for: context.principal)
        guard let namespace else { throw AgentStudioIPCAuthenticationError(reason: .unauthenticated) }
        let leaseKey = LeaseKey(namespace: namespace, credentialIdentity: context.credentialIdentity)

        let accepted = lock.withLock {
            guard !isShutdown, lifetimeEpoch == observation.lifetimeEpoch else { return false }
            if case .spawnedPaneAgent(let paneID, _) = context.principal.kind,
                let paneUUID = UUID(uuidString: paneID)
            {
                guard !finalRevokedPaneIDs.contains(paneUUID) else { return false }
                guard paneInvalidationSequences[paneUUID, default: 0] <= observation.invalidationSequence else {
                    return false
                }
            }
            guard retiredLeaseSequences[leaseKey] == nil else {
                return false
            }
            activeLeases[leaseKey, default: []].insert(context.principal.principalId)
            return true
        }
        guard accepted else {
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }
        return context
    }

    package func rotateTokens() {
        invalidateAllLeases()
    }

    package func shutdown() {
        let principalIDs = lock.withLock {
            isShutdown = true
            lifetimeEpoch &+= 1
            let principalIDs = Set(activeLeases.values.joined())
            activeLeases.removeAll(keepingCapacity: false)
            return principalIDs
        }
        revokeGrants(for: principalIDs)
    }

    package func revokeAllGrants() {
        grantLedger.revokeAll()
    }

    package func invalidatePrincipals(boundToPaneId paneId: String) {
        guard let paneUUID = UUID(uuidString: paneId) else { return }
        let principalIDs = lock.withLock {
            invalidationSequence &+= 1
            paneInvalidationSequences[paneUUID] = invalidationSequence
            let matchingKeys = activeLeases.keys.filter { key in
                guard case .pane(let boundPaneID, _) = key.namespace else { return false }
                return boundPaneID == paneUUID
            }
            let principalIDs = Set(matchingKeys.flatMap { activeLeases[$0] ?? [] })
            for key in matchingKeys {
                activeLeases.removeValue(forKey: key)
            }
            return principalIDs
        }
        revokeGrants(for: principalIDs)
    }

    package func releaseLease(_ context: AgentStudioIPCAuthenticatedContext) {
        guard let namespace = namespace(for: context.principal) else { return }
        let leaseKey = LeaseKey(namespace: namespace, credentialIdentity: context.credentialIdentity)
        let released = lock.withLock {
            guard var principalIDs = activeLeases[leaseKey],
                principalIDs.remove(context.principal.principalId) != nil
            else {
                return false
            }
            if principalIDs.isEmpty {
                activeLeases.removeValue(forKey: leaseKey)
            } else {
                activeLeases[leaseKey] = principalIDs
            }
            return true
        }
        if released {
            grantLedger.revokeAll(for: context.principal.principalId)
        }
    }

    package func contextRemainsAuthorized(_ context: AgentStudioIPCAuthenticatedContext) async -> Bool {
        if case .spawnedPaneAgent(let paneID, let workspaceID) = context.principal.kind {
            guard
                let paneUUID = UUID(uuidString: paneID),
                let workspaceID,
                canonicalPaneMembership(paneUUID, workspaceID)
            else { return false }
        }
        guard let namespace = namespace(for: context.principal) else { return false }
        let leaseKey = LeaseKey(namespace: namespace, credentialIdentity: context.credentialIdentity)
        return lock.withLock {
            guard !isShutdown, retiredLeaseSequences[leaseKey] == nil else { return false }
            return activeLeases[leaseKey]?.contains(context.principal.principalId) == true
        }
    }

    package func retireLease(_ context: AgentStudioIPCAuthenticatedContext) {
        guard let namespace = namespace(for: context.principal) else { return }
        let leaseKey = LeaseKey(namespace: namespace, credentialIdentity: context.credentialIdentity)
        let principalIDs = lock.withLock {
            invalidationSequence &+= 1
            retiredLeaseSequences[leaseKey] = invalidationSequence
            let principalIDs = activeLeases.removeValue(forKey: leaseKey) ?? []
            return principalIDs
        }
        revokeGrants(for: principalIDs)
    }

    private func invalidateAllLeases() {
        let principalIDs = lock.withLock {
            lifetimeEpoch &+= 1
            let principalIDs = Set(activeLeases.values.joined())
            activeLeases.removeAll(keepingCapacity: false)
            return principalIDs
        }
        revokeGrants(for: principalIDs)
    }

    private func revokeGrants(for principalIDs: Set<UUID>) {
        for principalID in principalIDs {
            grantLedger.revokeAll(for: principalID)
        }
    }

    package func registrationRemainsEligible(_ credential: AgentStudioIPCIssuedPaneCredential) -> Bool {
        lock.withLock {
            guard !finalRevokedPaneIDs.contains(credential.paneID) else { return false }
            return issuedPaneCredentialsByRecordID[credential.credentialRecordID] == credential
        }
    }

    private func namespace(for principal: IPCPrincipal) -> AgentStudioIPCCredentialNamespace? {
        switch principal.kind {
        case .spawnedPaneAgent(let paneID, let workspaceID):
            guard let paneUUID = UUID(uuidString: paneID), let workspaceID else {
                return nil
            }
            return .pane(paneID: paneUUID, workspaceID: workspaceID)
        case .automationClient, .futureMCPClient, .unsafeDebugClient:
            return .diagnostic(runtimeID: runtimeId)
        }
    }

    private func makeAuthenticatedContext(
        from resolution: AgentStudioIPCCredentialResolution,
        persistenceCandidate: AgentStudioIPCIssuedPaneCredential?
    ) async throws -> AgentStudioIPCAuthenticatedContext {
        switch resolution {
        case .pane(let paneID, let workspaceID, let credentialRecordID, .registered):
            guard canonicalPaneMembership(paneID, workspaceID) else {
                throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
            }
            return AgentStudioIPCAuthenticatedContext(
                principal: IPCPrincipal(
                    principalId: UUIDv7.generate(),
                    runtimeId: runtimeId,
                    accessMode: .agentStudioOnly,
                    kind: .spawnedPaneAgent(
                        boundPaneId: paneID.uuidString,
                        boundWorkspaceId: workspaceID
                    ),
                    approvalAuthority: .noApprovalAuthority
                ),
                credentialIdentity: .pane(recordID: credentialRecordID),
                persistenceCandidate: persistenceCandidate
            )
        case .pane(_, _, _, .revoked):
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }
    }

    /// The debug credential is admitted from memory, so there is no stored
    /// runtime to compare and no persistence candidate to carry.
    private func makeDebugAuthenticatedContext(generationID: UUID) -> AgentStudioIPCAuthenticatedContext {
        AgentStudioIPCAuthenticatedContext(
            principal: IPCPrincipal(
                principalId: UUIDv7.generate(),
                runtimeId: runtimeId,
                accessMode: .automationSameUser,
                kind: .automationClient,
                approvalAuthority: .noApprovalAuthority
            ),
            credentialIdentity: .diagnostic(generationID: generationID)
        )
    }

    private struct InstalledDebugCredential: Sendable {
        let verifierSHA256: Data
        let generationID: UUID

        func generationID(matching verifier: Data) -> UUID? {
            verifierSHA256 == verifier ? generationID : nil
        }
    }

    private struct AuthObservation: Sendable {
        let lifetimeEpoch: UInt64
        let invalidationSequence: UInt64
        let isShutdown: Bool
    }
}

package struct AgentStudioIPCLoginResult: Equatable, Sendable {
    package let authenticatedContext: AgentStudioIPCAuthenticatedContext
    package var principal: IPCPrincipal { authenticatedContext.principal }

    package init(authenticatedContext: AgentStudioIPCAuthenticatedContext) {
        self.authenticatedContext = authenticatedContext
    }
}

public struct AgentStudioIPCAuthenticator: Sendable {
    private let registry: AgentStudioIPCPrincipalRegistry

    public init(registry: AgentStudioIPCPrincipalRegistry) {
        self.registry = registry
    }

    package func login(
        subjectToken: AgentStudioIPCSubjectToken
    ) async throws -> AgentStudioIPCLoginResult {
        let authenticatedContext = try await registry.authenticate(subjectToken: subjectToken)
        return AgentStudioIPCLoginResult(authenticatedContext: authenticatedContext)
    }
}

public enum AgentStudioIPCPreAuthMethods {
    private static let allowedMethods: Set<String> = [
        "auth.login",
        "auth.status",
        "system.ping",
    ]

    public static func isAllowed(_ method: String) -> Bool {
        allowedMethods.contains(method)
    }
}

public struct AgentStudioIPCPeerCredentialGate: Sendable {
    public let currentUserIdentifier: uid_t

    public init(currentUserIdentifier: uid_t) {
        self.currentUserIdentifier = currentUserIdentifier
    }

    public func validate(_ peerCredentials: PeerCredentials) throws {
        guard peerCredentials.userIdentifier == currentUserIdentifier else {
            throw AgentStudioIPCAuthenticationError(reason: .peerUserMismatch)
        }
    }
}

public struct AgentStudioIPCSpawnEnvironment: Equatable, Sendable {
    public let variables: [String: String]

    public init(socketPath: String, runtimeId: UUID) {
        self.variables = [
            "AGENTSTUDIO_IPC_SOCKET": socketPath,
            "AGENTSTUDIO_IPC_RUNTIME_ID": runtimeId.uuidString,
        ]
    }
}

public struct AgentStudioIPCRedactor: Sendable {
    private let subjectTokens: Set<AgentStudioIPCSubjectToken>

    public init(subjectTokens: Set<AgentStudioIPCSubjectToken>) {
        self.subjectTokens = subjectTokens
    }

    public func redact(_ value: String) -> String {
        subjectTokens.reduce(value) { redacted, token in
            redacted.replacingOccurrences(of: token.rawValue, with: "<redacted>")
        }
    }
}
