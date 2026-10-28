import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

/// D60: archived F10 population, unchanged text/forms; fresh live binding and identifiers for each test.
enum PaneContextF10Scene {
    static let question = "Which checks should run before I push?"
    static let initialNotice = "Initial Info notice before the survival turn."

    static func install(in fixture: CompositionFactoryFixture) async throws -> AgentMessageId {
        let signal = SessionProviderSignal.sessionStart
        let result = try await fixture.composition.ingestion.submitHook(
            .init(
                paneId: fixture.ownerId.uuid, providerIdentifier: "codex", providerVersion: "9.9.9",
                sessionId: "f10-\(fixture.ownerId.uuid)", eventName: signal.name, turnId: nil, signal: signal,
                recordId: UUIDv7.generate(), admittedAt: fixture.now, chain: TestMainAgentChain.observation))
        guard case .committed = result else { throw SceneFailure.bindingNotCommitted }
        let context = try await fixture.composition.ingestion.repository.statusContext(paneId: fixture.ownerId.uuid)
        let sender = try fixture.sender(#require(context.currentBinding))
        let service = fixture.composition.paneContextService
        let withdrawn = try await send(
            "Review the migration plan before I apply it.", importance: .attention, sender: sender, fixture: fixture)
        try #require(
            await service.withdraw(messageId: withdrawn, paneId: fixture.ownerId, writer: sender) == .withdrawn)
        let compiler =
            (["J9 synthetic compiler output for opening survival."]
            + (1...32).map { "diagnostic \($0): retain the complete compiler output." }).joined(separator: "\n")
        _ = try await send(compiler, importance: .failure, sender: sender, fixture: fixture)
        let initial = try await send(initialNotice, importance: .info, sender: sender, fixture: fixture)
        _ = try await send(
            "NEW NOTICE — real provider turn reached the existing opening.", importance: .info,
            sender: sender, fixture: fixture)
        for index in 1...8 {
            _ = try await send(
                "Info scroll row \(index): the message body must remain behind its opaque sticky Info heading while scrolling through the complete native list.",
                importance: .info, sender: sender, fixture: fixture)
        }
        let choices = try [
            ("typecheck", "Type checking"), ("unit", "Unit tests"),
            ("browser", "Browser checks (slow, needs Chromium; about 6 minutes on this machine)"),
        ].map { try AskChoice(id: AskChoiceId($0.0), label: $0.1) }
        _ = try await send(
            question, importance: .attention, sender: sender, fixture: fixture,
            shape: .ask(reason: .question, form: .choice(options: choices, allowsMultiple: true), waiting: .nonBlocking)
        )
        await fixture.composition.presentationLane.publishPending()
        return initial
    }

    private static func send(
        _ body: String, importance: MessageImportance, sender: AgentMessageSender, fixture: CompositionFactoryFixture,
        shape: PaneMessageSendShape = .notice
    ) async throws -> AgentMessageId {
        let id = AgentMessageId.generateUUIDv7()
        try #require(
            await fixture.composition.paneContextService.send(
                .init(
                    paneId: fixture.ownerId, messageId: id, sender: sender, sourceOccurredAt: nil,
                    importance: importance, body: body, why: nil, actions: [], shape: shape)) == .created(id))
        return id
    }

    private enum SceneFailure: Error { case bindingNotCommitted }
}
