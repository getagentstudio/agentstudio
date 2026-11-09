import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation

@MainActor
struct AgentStudioIPCPanePullRequestAdapter: AppIPCPanePullRequestPort {
    let service: PaneContextService
    let ingestion: SessionsIngestion
    let workspaceStore: WorkspaceStore
    let windowLifecycleReader: any WorkspaceWindowLifecycleReading

    func addPullRequest(_ params: IPCPanePullRequestMutationParams, caller: AppIPCPanePullRequestCaller) async throws
        -> IPCPanePullRequestAddResult
    {
        let pane = try target(params.targetPaneHandle)
        let identity = try Self.identity(params.pullRequest)
        let author = try await Self.author(caller: caller, writer: params.writer, ingestion: ingestion)
        do {
            switch try await service.addPullRequest(paneId: pane, identity: identity, author: author) {
            case .added: return .added
            case .alreadyPresent: return .alreadyPresent
            case .paneFull: return .paneFull
            }
        } catch { throw Self.serviceFailure(error) }
    }

    func removePullRequest(_ params: IPCPanePullRequestMutationParams, caller: AppIPCPanePullRequestCaller) async throws
        -> IPCPanePullRequestRemoveResult
    {
        let pane = try target(params.targetPaneHandle)
        let identity = try Self.identity(params.pullRequest)
        let author = try await Self.author(caller: caller, writer: params.writer, ingestion: ingestion)
        do {
            switch try await service.removePullRequest(paneId: pane, identity: identity, author: author) {
            case .removed: return .removed
            case .notOnPane: return .notOnPane
            case .addedBySomeoneElse: return .addedBySomeoneElse
            }
        } catch { throw Self.serviceFailure(error) }
    }

    func listPullRequests(_ params: IPCPanePullRequestListParams) async throws -> IPCPanePullRequestListResult {
        let pane = try target(params.targetPaneHandle)
        do {
            let records = try await service.listPullRequests(paneId: pane)
            return await Self.listResult(records)
        } catch { throw Self.serviceFailure(error) }
    }

    private func target(_ rawHandle: String) throws -> PaneId {
        let lifecycle = windowLifecycleReader.snapshot()
        guard let window = lifecycle.preferredWorkspaceWindowId, lifecycle.registeredWindowIds.contains(window) else {
            throw AppIPCLayoutError(reason: .noActiveWindow)
        }
        return PaneId(
            existingUUID: try MainPaneTargetValidation.resolve(
                rawHandle, in: workspaceStore.programmaticControlSnapshot()))
    }

    nonisolated private static func identity(_ value: IPCPanePullRequestIdentity) throws -> ForgePullRequestIdentity {
        guard value.host.lowercased() == "github.com" else { throw AppIPCPaneContextError(reason: .notGitHub) }
        do {
            return try ForgePullRequestIdentity(
                host: "github.com", owner: value.owner.lowercased(), repository: value.repository.lowercased(),
                number: value.number)
        } catch { throw AppIPCPaneContextError(reason: .invalidField, field: "pullRequest") }
    }

    @concurrent nonisolated static func author(
        caller: AppIPCPanePullRequestCaller, writer: IPCPaneWriterClaim?, ingestion: SessionsIngestion
    ) async throws -> PanePullRequestAuthor {
        let source: PaneId
        switch caller.principal.kind {
        case .spawnedPaneAgent(let rawPane, _):
            guard let pane = UUID(uuidString: rawPane) else { throw AuthorizationError(reason: .unauthorized) }
            source = PaneId(existingUUID: pane)
        case .paneClaim(let pane, _): source = PaneId(existingUUID: pane)
        case .unsafeDebugClient: return .client(credentialKey: "unsafe-debug")
        case .automationClient, .futureMCPClient:
            guard case .diagnostic(let generation)? = caller.credentialIdentity else {
                throw AuthorizationError(reason: .unauthorized)
            }
            return .client(credentialKey: "diagnostic:\(generation.uuidString)")
        }
        guard let writer else { return .paneAgent(sourcePaneId: source, conversation: nil) }
        let binding: SessionsBindingRecord?
        do {
            binding = try await ingestion.bindingForProviderConversation(
                paneId: source.uuid, providerIdentifier: writer.provider, providerConversationId: writer.conversationId)
        } catch { throw AppIPCPaneContextError(reason: .unavailable) }
        guard let binding, binding.paneId == source.uuid else {
            return .paneAgent(sourcePaneId: source, conversation: nil)
        }
        return .paneAgent(
            sourcePaneId: source,
            conversation: try BridgeAgentContributorIdentity(
                provider: BridgeAgentProviderName(binding.providerIdentifier),
                sessionRef: BridgeAgentSessionRef(binding.providerConversationId)))
    }

    @concurrent nonisolated private static func listResult(_ records: [PanePullRequestRow]) async
        -> IPCPanePullRequestListResult
    {
        .init(
            rows: records.map { record in
                .init(
                    identity: .init(
                        host: record.identity.host, owner: record.identity.owner,
                        repository: record.identity.repository, number: record.identity.number),
                    isWorktree: record.isWorktree,
                    authors: record.contributions.map { contribution in
                        switch contribution.author {
                        case .paneAgent(let pane, let conversation):
                            .paneAgent(
                                sourcePaneId: pane.uuid,
                                conversation: conversation.map {
                                    .init(provider: $0.provider.value, conversationId: $0.sessionRef.value)
                                })
                        case .client: .client
                        case .person: .person
                        }
                    },
                    state: record.details.lastGood.map { read in
                        switch read.details.state {
                        case .open: .open
                        case .draft: .draft
                        case .merged: .merged
                        case .closed: .closed
                        }
                    })
            })
    }

    nonisolated private static func serviceFailure(_ error: any Error) -> any Error {
        guard let failure = error as? PanePullRequestServiceError else {
            return AppIPCPaneContextError(reason: .unavailable)
        }
        switch failure {
        case .paneGone: return AppIPCLayoutError(reason: .targetNotFound)
        case .unavailable: return AppIPCPaneContextError(reason: .unavailable)
        }
    }
}
