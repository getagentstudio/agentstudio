import AgentStudioCore

/// The App-owned seam preserves typed service results without a UI hop.
struct PaneContextUIAdapter: PaneContextDetailReading, PaneContextPersonActing {
    private let reader: any PaneContextDetailReading
    private let person: any PaneContextPersonActing

    init(service: PaneContextService) {
        reader = service
        person = service
    }
    init(reader: any PaneContextDetailReading, person: any PaneContextPersonActing) {
        self.reader = reader
        self.person = person
    }

    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        await reader.readDetail(request)
    }
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        await person.answer(request)
    }
    func dismiss(messageId: AgentMessageId, paneId: PaneId) async -> DismissResult {
        await person.dismiss(messageId: messageId, paneId: paneId)
    }
    func dismissAllNotices(paneId: PaneId, includingDrawers: Bool) async -> DismissAllNoticesResult {
        await service.dismissAllNotices(paneId: paneId, includingDrawers: includingDrawers)
    }
    func markRead(messageId: AgentMessageId, paneId: PaneId) async -> MarkReadResult {
        await person.markRead(messageId: messageId, paneId: paneId)
    }
    func runAction(_ request: MessageActionRequest) async -> MessageActionResult {
        await person.runAction(request)
    }
}
