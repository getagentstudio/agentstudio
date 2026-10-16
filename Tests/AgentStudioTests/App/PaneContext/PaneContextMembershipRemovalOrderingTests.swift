import AgentStudioAppIPC
import AgentStudioInfrastructure
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

@MainActor
@Suite("Pane context membership removal ordering", .serialized)
struct PaneContextMembershipRemovalOrderingTests {
    @Test("The next login and revalidation after canonical graph removal see absence without a MainActor hop")
    func graphRemovalIsTheNextAuthorizationDecision() async throws {
        let owners = try await makeCanonicalIPCWorkspaceOwners()
        let pane = owners.store.createPane(title: "Removed before next login")
        let probe = MembershipAuthorizationReadProbe(
            directory: owners.core.workspacePaneGraph.paneContextMembershipDirectory)
        let registry = AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: MembershipOrderingCredentialResolver(
                paneId: pane.id, workspaceId: owners.core.workspaceIdentity.workspaceId),
            canonicalPaneMembership: { probe.contains(paneID: $0, inWorkspace: $1) })
        defer { registry.shutdown() }
        let token = AgentStudioIPCSubjectToken(rawValue: "membership-ordering")
        let context = try await Self.loginOffMain(registry, token: token)
        try #require(owners.core.workspacePaneGraph.deletePaneAndOwnedDrawerChildren(pane.id))
        let result = await Self.authorizationOffMain(registry, token: token, context: context)
        #expect(!result.remainsAuthorized)
        #expect(result.loginError == AgentStudioIPCAuthenticationError(reason: .unauthenticated))
        #expect(probe.everyReadWasOffMain)
    }

    @concurrent nonisolated private static func loginOffMain(
        _ registry: AgentStudioIPCPrincipalRegistry, token: AgentStudioIPCSubjectToken
    ) async throws -> AgentStudioIPCAuthenticatedContext {
        try await registry.authenticate(subjectToken: token)
    }

    @concurrent nonisolated private static func authorizationOffMain(
        _ registry: AgentStudioIPCPrincipalRegistry, token: AgentStudioIPCSubjectToken,
        context: AgentStudioIPCAuthenticatedContext
    ) async -> MembershipOrderingAuthorizationResult {
        let authorized = await registry.contextRemainsAuthorized(context)
        do {
            _ = try await registry.authenticate(subjectToken: token)
            return .init(remainsAuthorized: authorized, loginError: nil)
        } catch {
            return .init(remainsAuthorized: authorized, loginError: error as? AgentStudioIPCAuthenticationError)
        }
    }
}

private struct MembershipOrderingAuthorizationResult: Sendable {
    let remainsAuthorized: Bool
    let loginError: AgentStudioIPCAuthenticationError?
}

private final class MembershipAuthorizationReadProbe: Sendable {
    private let directory: PaneContextMembershipDirectory
    private let offMain = Mutex(true)

    init(directory: PaneContextMembershipDirectory) { self.directory = directory }

    var everyReadWasOffMain: Bool { offMain.withLock { $0 } }

    func contains(paneID: UUID, inWorkspace workspaceId: UUID) -> Bool {
        offMain.withLock { $0 = $0 && !Thread.isMainThread }
        return directory.contains(paneID: paneID, inWorkspace: workspaceId)
    }
}

private struct MembershipOrderingCredentialResolver: AgentStudioIPCCredentialResolving {
    let paneId: UUID
    let workspaceId: UUID
    private let recordId = UUIDv7.generate()

    init(paneId: UUID, workspaceId: UUID) {
        self.paneId = paneId
        self.workspaceId = workspaceId
    }

    func resolveCredential(_ token: AgentStudioIPCSubjectToken, serverRuntimeID: UUID) async throws
        -> AgentStudioIPCCredentialResolution
    {
        guard token.rawValue == "membership-ordering" else {
            throw AgentStudioIPCAuthenticationError(reason: .unauthenticated)
        }
        return .pane(paneID: paneId, workspaceID: workspaceId, credentialRecordID: recordId, status: .registered)
    }
}
