import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import Testing

@testable import AgentStudio

@Suite("PR adapter author stamping")
struct PanePullRequestAuthorStampingTests {
    private func caller(_ kind: IPCPrincipalKind, credential: AgentStudioIPCAuthenticatedCredentialIdentity? = nil)
        -> AppIPCPanePullRequestCaller
    {
        .init(
            principal: .init(
                principalId: UUIDv7.generate(), runtimeId: UUIDv7.generate(), accessMode: .agentStudioOnly,
                kind: kind, approvalAuthority: .noApprovalAuthority), credentialIdentity: credential)
    }

    @Test("Active and ended claims use the real source-pane binding")
    func activeAndEndedBindings() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("pr-bound")
            let source = caller(.spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: nil))
            let claim = IPCPaneWriterClaim(
                provider: fixture.provider.identifier, conversationId: binding.providerConversationId)
            let expected = PanePullRequestAuthor.paneAgent(
                sourcePaneId: fixture.paneId,
                conversation: .init(
                    provider: try BridgeAgentProviderName(fixture.provider.identifier),
                    sessionRef: try BridgeAgentSessionRef("pr-bound")))
            #expect(
                try await AgentStudioIPCPanePullRequestAdapter.author(
                    caller: source, writer: claim, ingestion: fixture.ingestion) == expected)
            try await fixture.applyHook(binding, eventName: .sessionEnd, signal: .sessionEnd)
            #expect(
                try await AgentStudioIPCPanePullRequestAdapter.author(
                    caller: source, writer: claim, ingestion: fixture.ingestion) == expected)
        }
    }

    @Test("An absent claim or a claim bound only in another pane falls back to the source pane")
    func unboundAndOtherPaneClaims() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let binding = try await fixture.bindConversation("elsewhere")
            let boundSource = caller(.spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: nil))
            for claim in [
                Optional<IPCPaneWriterClaim>.none,
                .init(provider: fixture.provider.identifier, conversationId: "not-bound"),
            ] {
                #expect(
                    try await AgentStudioIPCPanePullRequestAdapter.author(
                        caller: boundSource, writer: claim, ingestion: fixture.ingestion)
                        == .paneAgent(sourcePaneId: fixture.paneId, conversation: nil))
            }
            let sourcePane = PaneId.generateUUIDv7()
            let source = caller(.paneClaim(paneId: sourcePane.uuid, workspaceId: UUIDv7.generate()))
            let expected = PanePullRequestAuthor.paneAgent(sourcePaneId: sourcePane, conversation: nil)
            for claim in [
                Optional<IPCPaneWriterClaim>.none,
                .init(provider: fixture.provider.identifier, conversationId: "not-bound"),
                .init(provider: fixture.provider.identifier, conversationId: binding.providerConversationId),
            ] {
                #expect(
                    try await AgentStudioIPCPanePullRequestAdapter.author(
                        caller: source, writer: claim, ingestion: fixture.ingestion) == expected)
            }
        }
    }

    @Test("Rebinding the same conversation retains ownership; a different conversation cannot remove it")
    func rebindAndDifferentConversation() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let identity = try ForgePullRequestIdentity(
                host: "github.com", owner: "owner", repository: "repo", number: 7)
            let source = caller(.spawnedPaneAgent(boundPaneId: fixture.paneId.uuidString, boundWorkspaceId: nil))
            let first = try await fixture.bindConversation("same")
            let sameClaim = IPCPaneWriterClaim(provider: fixture.provider.identifier, conversationId: "same")
            let firstAuthor = try await AgentStudioIPCPanePullRequestAdapter.author(
                caller: source, writer: sameClaim, ingestion: fixture.ingestion)
            _ = try await fixture.service.addPullRequest(
                paneId: fixture.paneId, identity: identity, author: firstAuthor)
            try await fixture.applyHook(first, eventName: .sessionEnd, signal: .sessionEnd)
            let intervening = try await fixture.bindConversation("intervening")
            try #require(intervening.bindingGenerationId != first.bindingGenerationId)
            try await fixture.applyHook(intervening, eventName: .sessionEnd, signal: .sessionEnd)
            let rebound = try await fixture.bindConversation("same")
            try #require(rebound.status == .active)
            #expect(rebound.providerConversationId == first.providerConversationId)
            let reboundAuthor = try await AgentStudioIPCPanePullRequestAdapter.author(
                caller: source, writer: sameClaim, ingestion: fixture.ingestion)
            #expect(reboundAuthor == firstAuthor)
            #expect(
                try await fixture.service.removePullRequest(
                    paneId: fixture.paneId, identity: identity, author: reboundAuthor) == .removed)
            _ = try await fixture.service.addPullRequest(
                paneId: fixture.paneId, identity: identity, author: reboundAuthor)
            try await fixture.applyHook(rebound, eventName: .sessionEnd, signal: .sessionEnd)
            _ = try await fixture.bindConversation("different")
            let different = try await AgentStudioIPCPanePullRequestAdapter.author(
                caller: source, writer: .init(provider: fixture.provider.identifier, conversationId: "different"),
                ingestion: fixture.ingestion)
            #expect(
                try await fixture.service.removePullRequest(
                    paneId: fixture.paneId, identity: identity, author: different) == .addedBySomeoneElse)
        }
    }

    @Test(
        "Client ownership uses credential generation, refuses missing identity, and keeps explicit unsafe-debug stable")
    func clientCredentialIdentity() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let generation = UUIDv7.generate()
            let first = caller(.automationClient, credential: .diagnostic(generationID: generation))
            let second = caller(.futureMCPClient, credential: .diagnostic(generationID: generation))
            #expect(first.principal.principalId != second.principal.principalId)
            let author = try await AgentStudioIPCPanePullRequestAdapter.author(
                caller: first, writer: nil, ingestion: fixture.ingestion)
            #expect(author == .client(credentialKey: "diagnostic:\(generation.uuidString)"))
            #expect(
                try await AgentStudioIPCPanePullRequestAdapter.author(
                    caller: second, writer: nil, ingestion: fixture.ingestion) == author)
            await #expect(throws: AuthorizationError.self) {
                try await AgentStudioIPCPanePullRequestAdapter.author(
                    caller: caller(.automationClient), writer: nil, ingestion: fixture.ingestion)
            }
            for _ in 0..<2 {
                let unsafe = caller(.unsafeDebugClient, credential: .diagnostic(generationID: UUIDv7.generate()))
                #expect(
                    try await AgentStudioIPCPanePullRequestAdapter.author(
                        caller: unsafe, writer: nil, ingestion: fixture.ingestion)
                        == .client(credentialKey: "unsafe-debug"))
            }
        }
    }
}
