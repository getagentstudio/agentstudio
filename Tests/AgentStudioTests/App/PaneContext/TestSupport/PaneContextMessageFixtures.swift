import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Literal message fixtures shared by the real owner, projection and native product tests.
enum PaneContextMessageFixtures {
    static func askDetail(pane: PaneId, id: AgentMessageId, state: AskState, revision: UInt64) throws
        -> PaneContextDetail
    {
        let message = AgentMessageDetail(
            id: id, sourcePaneId: pane,
            sender: .session(
                provider: try .init("codex"), sessionRef: try .init("session"), bindingGeneration: UUIDv7.generate()),
            sentAt: .distantPast, sourceOccurredAt: nil, importance: .info, body: "Question", why: nil,
            actions: [], shape: .ask(.question, .freeText(placeholder: "Reply"), .nonBlocking, state))
        return .init(
            paneId: pane, revision: .init(revision), agentTitle: nil, agentLine: nil,
            scopedSessions: [.init(sourcePaneId: pane, session: nil)], hasDismissibleNotices: false,
            messages: [message], drawerMessages: [], links: .unknown, pullRequests: .notApplicable, truncation: nil)
    }
}
