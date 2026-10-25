import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

@Suite("Restore Sessions producers")
struct RestoreSessionsProducerTests {
    @Test("a newly committed pane message remains visible through the App adapter")
    func committedPaneMessageRemainsVisible() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let conversationId = UUIDv7.generate().uuidString
            _ = try await fixture.bindConversation(conversationId)
            let adapter = AgentStudioIPCPaneContextAdapter(service: fixture.service, ingestion: fixture.ingestion)
            let params = IPCPaneMessageSendParams(
                handle: fixture.paneId.uuid.uuidString, messageId: UUIDv7.generate(),
                writer: .init(provider: fixture.provider.identifier, conversationId: conversationId),
                importance: .info, body: "Turn complete", actions: [], shape: .notice,
                correlationId: UUIDv7.generate())
            _ = try await adapter.sendMessage(paneId: fixture.paneId.uuid, params: params)
            #expect(try await fixture.detail().messages.map(\.body) == ["Turn complete"])
        }
    }

    @Test("a lifecycle reply follows its real SQLite commit")
    func bindingReplyFollowsCommit() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture)
        let hold = HeldStep<Void>("provider start before Sessions transaction")
        defer { hold.retire() }
        fixture.access.holdNextWrite(hold)
        let params = try fixture.event(.sessionStart)
        let start = Task {
            // If admission ends before reaching the transaction, firstArrival must also end.
            defer { hold.retire() }
            return try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: params, provenance: .matchingPane)
        }
        do {
            _ = try await hold.firstArrival()
            #expect(try await fixture.context().currentBinding == nil)
            hold.release()
            #expect(try await start.value.disposition == .admitted)
            let committed = try #require(try await fixture.context().currentBinding)
            #expect(committed.providerConversationId == fixture.sessionId)
            #expect(committed.status == .active)
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.sessionEnd), provenance: .matchingPane)
            #expect(try await fixture.context().currentBinding?.status == .ended)
            await ingestion.finish()
        } catch {
            hold.retire()
            _ = try? await start.value
            await ingestion.finish()
            throw error
        }
    }

    @Test("a committed stop hook preserves the binding")
    func activityHookPreservesBinding() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture)
        do {
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.sessionStart), provenance: .matchingPane)
            let before = try await fixture.context()
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.stop), provenance: .matchingPane)
            let after = try await fixture.context()
            #expect(after.currentBinding?.bindingGenerationId == before.currentBinding?.bindingGenerationId)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }

    @Test("current main accepts arbitrary provider versions")
    func providerVersionStillBinds() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture)
        do {
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.sessionStart, version: "future-version"),
                provenance: .matchingPane)
            #expect(try await fixture.context().currentBinding?.providerConversationId == fixture.sessionId)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }

    @Test("a malformed hook cannot bind")
    func refusedMalformedHookCannotBind() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture)
        let valid = try fixture.event(.sessionStart)
        let malformed = IPCSessionEventParams(
            handle: valid.handle, provider: valid.provider,
            event: .init(
                name: .question, conversationId: fixture.sessionId, turnId: nil, requestId: nil,
                toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
            correlationId: UUIDv7.generate())
        do {
            await #expect(throws: (any Error).self) {
                try await adapter.recordProviderEvent(
                    paneId: fixture.paneId, params: malformed, provenance: .matchingPane)
            }
            #expect(try await fixture.context().currentBinding == nil)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }
}
