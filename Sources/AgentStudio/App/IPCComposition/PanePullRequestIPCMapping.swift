import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

enum PanePullRequestIPCMapping {
    static func presentation(_ value: PanePullRequestList) -> IPCPanePullRequestPresentationList {
        .init(
            rows: value.rows.map { row in
                .init(
                    identity: identity(row.identity), isWorktree: row.isWorktree,
                    authors: row.authors.map(author), createdAt: row.createdAt, details: details(row.details))
            }, worstChecks: value.worstChecks.map(PaneContextIPCMapping.checkStatus))
    }

    static func identity(_ value: ForgePullRequestIdentity) -> IPCPanePullRequestIdentity {
        .init(host: value.host, owner: value.owner, repository: value.repository, number: value.number)
    }

    static func author(_ value: PanePullRequestAuthor) -> IPCPanePullRequestAuthor {
        switch value {
        case .person: .person
        case .client: .client
        case .paneAgent(let pane, let conversation):
            .paneAgent(
                sourcePaneId: pane.uuid,
                conversation: conversation.map {
                    .init(provider: $0.provider.value, conversationId: $0.sessionRef.value)
                })
        }
    }

    static func state(_ value: ForgePullRequestState) -> IPCPanePullRequestState {
        switch value {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        }
    }

    private static func failure(_ value: ForgePullRequestDetailsFailureReason) -> IPCPanePullRequestFailureReason {
        switch value {
        case .noAccess: .noAccess
        case .notFound: .notFound
        case .rateLimited: .rateLimited
        case .offline: .offline
        case .failed: .failed
        }
    }

    private static func details(_ value: PanePullRequestDetails) -> IPCPanePullRequestDetailsValue {
        switch value {
        case .loading: return .loading
        case .unavailable(let reason): return .unavailable(failure(reason))
        case .loaded(let read, let refreshFailure):
            let detail = read.details
            return .loaded(
                .init(
                    title: detail.title, state: state(detail.state),
                    checks: PaneContextIPCMapping.checkStatus(detail.readiness.checkStatus),
                    review: PaneContextIPCMapping.reviewStatus(detail.readiness.reviewStatus),
                    mergeability: mergeability(detail.readiness.mergeability),
                    mergeState: mergeState(detail.readiness.mergeState), updatedAt: detail.updatedAt,
                    lastGoodReadAt: read.readAt, url: detail.url.absoluteString,
                    refreshFailure: refreshFailure.map(failure)))
        }
    }

    private static func mergeability(_ value: PullRequestMergeability) -> IPCPanePullRequestMergeability {
        switch value {
        case .mergeable: .mergeable
        case .conflicting: .conflicting
        case .unknown: .unknown
        }
    }
    private static func mergeState(_ value: PullRequestMergeState) -> IPCPanePullRequestMergeState {
        switch value {
        case .clean: .clean
        case .blocked: .blocked
        case .behind: .behind
        case .dirty: .dirty
        case .draft: .draft
        case .hasHooks: .hasHooks
        case .unstable: .unstable
        case .unknown: .unknown
        }
    }
}
