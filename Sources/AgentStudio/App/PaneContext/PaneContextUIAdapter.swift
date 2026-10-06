import AgentStudioCore

/// The App-owned seam preserves typed service results without a UI hop.
struct PaneContextUIAdapter: PaneContextDetailReading, PaneContextPersonActing {
    private let service: PaneContextService

    init(service: PaneContextService) { self.service = service }

    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        await service.readDetail(request)
    }
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        await service.answer(request)
    }
    func dismiss(messageId: AgentMessageId, paneId: PaneId) async -> DismissResult {
        await service.dismiss(messageId: messageId, paneId: paneId)
    }
    func dismissAllNotices(paneId: PaneId, includingDrawers: Bool) async -> DismissAllNoticesResult {
        await service.dismissAllNotices(paneId: paneId, includingDrawers: includingDrawers)
    }
    func markRead(messageId: AgentMessageId, paneId: PaneId) async -> MarkReadResult {
        await service.markRead(messageId: messageId, paneId: paneId)
    }
    func runAction(_ request: MessageActionRequest) async -> MessageActionResult {
        await service.runAction(request)
    }
}
