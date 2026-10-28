import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// The App-owned seam preserves typed service results without a UI hop.
struct PaneContextUIAdapter: PaneContextDetailReading, PaneContextPersonActing {
    private let reader: any PaneContextDetailReading
    private let person: any PaneContextPersonActing
    private let invalidations: any PaneContextInvalidationReading
    private let epoch: UUID
    private let readLiveSession: @Sendable (PaneId) async -> SessionSummary?

    init(
        service: PaneContextService,
        readLiveSession: @escaping @Sendable (PaneId) async -> SessionSummary? = { _ in nil }
    ) {
        reader = service
        person = service
        invalidations = service
        epoch = UUIDv7.generate()
        self.readLiveSession = readLiveSession
    }
    init(
        reader: any PaneContextDetailReading, person: any PaneContextPersonActing,
        invalidations: any PaneContextInvalidationReading,
        readLiveSession: @escaping @Sendable (PaneId) async -> SessionSummary? = { _ in nil }
    ) {
        self.reader = reader
        self.person = person
        self.invalidations = invalidations
        self.readLiveSession = readLiveSession
        epoch = UUIDv7.generate()
    }

    init(
        reader: any PaneContextDetailReading & PaneContextInvalidationReading, person: any PaneContextPersonActing,
        readLiveSession: @escaping @Sendable (PaneId) async -> SessionSummary? = { _ in nil }
    ) {
        self.init(reader: reader, person: person, invalidations: reader, readLiveSession: readLiveSession)
    }

    var popoverPorts: PaneContextPopoverServicePorts {
        .init(
            epoch: epoch, reader: reader, invalidations: invalidations, person: person, readLiveSession: readLiveSession
        )
    }

    func readDetail(_ request: PaneContextReadRequest) async -> PaneContextReadResult {
        await reader.readDetail(request)
    }
    func readMessage(source: PaneId, message: AgentMessageId) async -> MessageReadResult {
        await reader.readMessage(source: source, message: message)
    }
    func answer(_ request: AnswerAskRequest) async -> AnswerAskResult {
        await person.answer(request)
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
    func runAction(_ request: MessageActionRequest) async -> MessageActionResult {
        await person.runAction(request)
    }
}
