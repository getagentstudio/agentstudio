import AgentStudioCore

@MainActor
final class PaneContextPopoverAutoOpenState {
    private var lastPresentedAskByPane: [PaneId: AgentMessageId] = [:]

    func lastPresentedAskId(for paneId: PaneId) -> AgentMessageId? {
        lastPresentedAskByPane[paneId]
    }

    func rememberPresentedAsk(_ askId: AgentMessageId, for paneId: PaneId) {
        lastPresentedAskByPane[paneId] = askId
    }
}
