import AgentStudioAppIPC
import AgentStudioInfrastructure
import Foundation
import Testing

@Suite("IPC pane credential issuance sink")
struct AgentStudioIPCIssuanceSinkTests {
    @Test("new admission calls the sink outside the registry lock and duplicate records do not call it")
    func newAdmissionCallsSinkOutsideLockOnlyOnce() throws {
        let registry = makeRegistry()
        defer { registry.shutdown() }
        let recorder = IssuedCredentialRecorder()
        let credential = makeCredential()
        registry.installIssuedPaneCredentialSink { issuedCredential in
            // Reading the registry here requires the same lock as admission.
            #expect(registry.issuedCredentialCandidates() == [issuedCredential])
            recorder.record(issuedCredential)
        }

        try register(credential, in: registry)
        try register(credential, in: registry)

        #expect(recorder.credentials == [credential])
    }

    @Test("installing the sink leaves earlier records for the readiness snapshot and emits later records")
    func earlierAdmissionsRemainSnapshotCandidates() throws {
        let registry = makeRegistry()
        defer { registry.shutdown() }
        let recorder = IssuedCredentialRecorder()
        let earlierCredential = makeCredential(byte: 0xB4)
        try register(earlierCredential, in: registry)

        registry.installIssuedPaneCredentialSink { recorder.record($0) }
        #expect(recorder.credentials.isEmpty)
        #expect(registry.issuedCredentialCandidates() == [earlierCredential])
        let laterCredential = makeCredential()
        try register(laterCredential, in: registry)

        #expect(recorder.credentials == [laterCredential])
        #expect(
            Set(registry.issuedCredentialCandidates().map(\.credentialRecordID))
                == [earlierCredential.credentialRecordID, laterCredential.credentialRecordID])
    }

    @Test("conflicting, final-revoked and shutdown admissions never reach the issuance sink")
    func refusedAdmissionsDoNotCallSink() throws {
        let registry = makeRegistry()
        defer { registry.shutdown() }
        let recorder = IssuedCredentialRecorder()
        registry.installIssuedPaneCredentialSink { recorder.record($0) }
        let credential = makeCredential()
        try register(credential, in: registry)

        let recordConflict = AgentStudioIPCIssuedPaneCredential(
            paneID: credential.paneID, workspaceID: credential.workspaceID,
            credentialRecordID: credential.credentialRecordID, verifierSHA256: Data(repeating: 0xB4, count: 32)
        )
        #expect(throws: AgentStudioIPCIssuedCredentialRegistrationError.conflictingRecordIdentity) {
            try register(recordConflict, in: registry)
        }
        #expect(throws: AgentStudioIPCIssuedCredentialRegistrationError.conflictingVerifier) {
            try register(makeCredential(), in: registry)
        }
        registry.finalRevokePane(credential.paneID)
        #expect(throws: AgentStudioIPCIssuedCredentialRegistrationError.paneFinalRevoked) {
            try register(credential, in: registry)
        }
        registry.shutdown()
        #expect(throws: AgentStudioIPCIssuedCredentialRegistrationError.registryShutdown) {
            try register(makeCredential(byte: 0xC3), in: registry)
        }

        #expect(recorder.credentials == [credential])
    }

    private func makeRegistry() -> AgentStudioIPCPrincipalRegistry {
        AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: IssuanceSinkUnusedCredentialResolver(),
            canonicalPaneMembership: { _, _ in true }
        )
    }

    private func makeCredential(byte: UInt8 = 0xA5) -> AgentStudioIPCIssuedPaneCredential {
        .init(
            paneID: UUIDv7.generate(), workspaceID: UUIDv7.generate(), credentialRecordID: UUIDv7.generate(),
            verifierSHA256: Data(repeating: byte, count: 32)
        )
    }

    private func register(
        _ credential: AgentStudioIPCIssuedPaneCredential, in registry: AgentStudioIPCPrincipalRegistry
    ) throws {
        try registry.registerIssuedPaneCredential(
            paneID: credential.paneID, workspaceID: credential.workspaceID,
            credentialRecordID: credential.credentialRecordID, verifierSHA256: credential.verifierSHA256
        )
    }
}

private final class IssuedCredentialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCredentials: [AgentStudioIPCIssuedPaneCredential] = []

    var credentials: [AgentStudioIPCIssuedPaneCredential] { lock.withLock { recordedCredentials } }

    func record(_ credential: AgentStudioIPCIssuedPaneCredential) {
        lock.withLock { recordedCredentials.append(credential) }
    }
}

private actor IssuanceSinkUnusedCredentialResolver: AgentStudioIPCCredentialResolving {
    func resolveCredential(
        _: AgentStudioIPCSubjectToken, serverRuntimeID _: UUID
    ) async throws -> AgentStudioIPCCredentialResolution {
        throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
    }
}
