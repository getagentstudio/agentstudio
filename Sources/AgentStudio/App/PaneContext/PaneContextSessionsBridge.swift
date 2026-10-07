import AgentStudioCore
import AgentStudioSessions
import Foundation
import GRDB
import Synchronization

/// App owns the Core/Sessions join. The owners hold this adapter through their
/// callbacks; weak endpoints keep those callbacks from forming a retain cycle.
final class PaneContextSessionsBridge: SessionOpenAskReading, Sendable {
    private enum AskSourceFailure: Error { case serviceUnavailable }
    private struct Endpoints {
        weak var service: PaneContextService?
        weak var ingestion: SessionsIngestion?
    }
    private let endpoints = Mutex(Endpoints())

    func connect(service: PaneContextService, ingestion: SessionsIngestion) {
        endpoints.withLock {
            $0.service = service
            $0.ingestion = ingestion
        }
    }

    func openAskSummaries() async throws -> [SessionsOpenAskUpdate] {
        guard let service = endpoints.withLock({ $0.service }) else { throw AskSourceFailure.serviceUnavailable }
        let updates = try await service.openAskSummaries()
        return updates.map(Self.sessionsOpenAskUpdate)
    }

    func receiveOpenAskSummary(_ update: PaneContextOpenAskUpdate) async {
        guard let ingestion = endpoints.withLock({ $0.ingestion }) else { return }
        await ingestion.receiveOpenAskSummary(Self.sessionsOpenAskUpdate(update))
    }

    func receiveAgentLine(work: AgentStudioCore.AgentLineWork?, bindingGenerationId: UUID) async {
        guard let ingestion = endpoints.withLock({ $0.ingestion }) else { return }
        await ingestion.receiveAgentLine(
            work: work.flatMap(Self.sessionsLineWork), bindingGenerationId: bindingGenerationId)
    }

    func sessionEnded(bindingGenerationId: UUID) async {
        guard let service = endpoints.withLock({ $0.service }) else { return }
        await service.sessionEnded(bindingGenerationId: bindingGenerationId)
    }

    func sessionSummary(paneId: PaneId) async throws -> SessionSummary? {
        guard let ingestion = endpoints.withLock({ $0.ingestion }) else { return nil }
        return try await ingestion.sessionSummary(paneId: paneId.uuid)
    }

    /// This existing repository read is the transaction seam, not a stand-in.
    static func currentBindingGeneration(paneId: PaneId, in database: Database) throws -> UUID? {
        try SessionsRepositoryStorage.currentBindingGeneration(paneId: paneId.uuid, in: database)
    }

    private static func sessionsOpenAskUpdate(_ update: PaneContextOpenAskUpdate) -> SessionsOpenAskUpdate {
        .init(
            bindingGenerationId: update.bindingGenerationId,
            summary: .init(
                sequence: update.sequence, approval: update.approval, question: update.question,
                blocked: update.blocked))
    }

    // Sessions owns the turn outcome; only monitoring refines an already-working turn.
    private static func sessionsLineWork(_ work: AgentStudioCore.AgentLineWork) -> AgentStudioSessions.AgentLineWork? {
        switch work {
        case .monitoring: return .monitoring
        case .working, .blockedOnYou, .done, .failed: return nil
        }
    }
}
