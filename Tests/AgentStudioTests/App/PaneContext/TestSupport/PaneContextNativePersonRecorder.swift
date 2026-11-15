import AgentStudioCore

actor PaneContextNativePersonRecorder: PaneContextPersonActing {
    let person: any PaneContextPersonActing
    private(set) var answers: [AnswerAskRequest] = []
    init(_ person: any PaneContextPersonActing) { self.person = person }
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        answers.append(request)
        return await person.answer(request)
    }
    func dismiss(messageId: AgentMessageId, paneId: PaneId) async -> DismissResult {
        await person.dismiss(messageId: messageId, paneId: paneId)
    }
    func dismissAllNotices(paneId: PaneId, includingDrawers: Bool) async -> DismissAllNoticesResult {
        await person.dismissAllNotices(paneId: paneId, includingDrawers: includingDrawers)
    }
    func markRead(messageId: AgentMessageId, paneId: PaneId) async -> MarkReadResult {
        await person.markRead(messageId: messageId, paneId: paneId)
    }
    func runAction(_ request: MessageActionRequest) async -> MessageActionResult { await person.runAction(request) }
}
