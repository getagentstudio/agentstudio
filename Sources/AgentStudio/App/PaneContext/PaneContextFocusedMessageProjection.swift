import AgentStudioCore

enum PaneContextFocusedMessageProjection {
    /// Native navigation supplements the bounded page with one exact, scoped read.
    @concurrent nonisolated static func including(_ message: AgentMessageDetail, in detail: PaneContextDetail) async
        -> PaneContextDetail
    {
        let own = message.sourcePaneId == detail.paneId
        var messages = detail.messages
        var drawers = detail.drawerMessages
        if own {
            messages.removeAll { $0.id == message.id }
            messages.append(message)
        } else if let index = drawers.firstIndex(where: { $0.sourcePaneId == message.sourcePaneId }) {
            var rows = drawers[index].messages.filter { $0.id != message.id }
            rows.append(message)
            drawers[index] = .init(sourcePaneId: message.sourcePaneId, messages: rows)
        } else {
            drawers.append(.init(sourcePaneId: message.sourcePaneId, messages: [message]))
        }
        return .init(
            paneId: detail.paneId, revision: detail.revision, agentTitle: detail.agentTitle,
            agentLine: detail.agentLine, scopedSessions: detail.scopedSessions,
            hasDismissibleNotices: detail.hasDismissibleNotices, messages: messages, drawerMessages: drawers,
            links: detail.links, pullRequests: detail.pullRequests, truncation: detail.truncation)
    }
}
