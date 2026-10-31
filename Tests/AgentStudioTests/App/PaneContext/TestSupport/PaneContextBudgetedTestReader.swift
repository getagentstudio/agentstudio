import AgentStudioCore

/// Uses the service's real bounded-page operation; the exact read is unchanged.
struct PaneContextBudgetedTestReader: PaneContextDetailReading {
    let service: PaneContextService
    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        await service.readDetail(request, maximumDetailBytes: 0)
    }
    func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult {
        await service.readMessage(source: source, message: message)
    }
}
