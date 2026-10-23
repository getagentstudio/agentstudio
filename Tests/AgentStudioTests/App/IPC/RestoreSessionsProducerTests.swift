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
    @Test("a newly committed pane message requests a look through the current App adapter")
    func committedPaneMessageRequestsForegroundLook() async throws {
        try await withPaneContextSessionsBridge { fixture in
            let conversationId = UUIDv7.generate().uuidString
            _ = try await fixture.bindConversation(conversationId)
            let committedBodies = Mutex<[String]>([])
            let adapter = AgentStudioIPCPaneContextAdapter(
                service: fixture.service, ingestion: fixture.ingestion,
                foregroundLookSink: { trigger, paneId in
                    guard case .agentMessage = trigger, paneId == fixture.paneId.uuid else {
                        Issue.record("Expected the committed pane's agent-message trigger")
                        return
                    }
                    do {
                        let detail = try await fixture.detail()
                        committedBodies.withLock { $0 = detail.messages.map(\.body) }
                    } catch { Issue.record("Could not read the committed message: \(error)") }
                })
            let params = IPCPaneMessageSendParams(
                handle: fixture.paneId.uuid.uuidString, messageId: UUIDv7.generate(),
                writer: .init(provider: fixture.provider.identifier, conversationId: conversationId),
                importance: .info, body: "Turn complete", actions: [], shape: .notice,
                correlationId: UUIDv7.generate())
            _ = try await adapter.sendMessage(paneId: fixture.paneId.uuid, params: params)
            #expect(committedBodies.withLock { $0 } == ["Turn complete"])
        }
    }

    @Test("a lifecycle trigger follows its real SQLite commit, never the pending hook")
    func bindingTriggerFollowsCommit() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let ledger = RestoreSessionsTriggerLedger()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture, ledger: ledger)
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
            #expect(ledger.snapshot().isEmpty)
            hold.release()
            #expect(try await start.value.disposition == .admitted)
            let committed = try #require(ledger.snapshot().first)
            #expect(committed.kind == .bindingChanged)
            #expect(committed.sessionId == fixture.sessionId)
            #expect(committed.bindingId != nil)
            #expect(!committed.ended)
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.sessionEnd), provenance: .matchingPane)
            #expect(ledger.snapshot().map(\.kind) == [.bindingChanged, .bindingChanged])
            #expect(ledger.snapshot().last?.ended == true)
            await ingestion.finish()
        } catch {
            hold.retire()
            _ = try? await start.value
            await ingestion.finish()
            throw error
        }
    }

    @Test("a committed stop hook requests foreground refresh without rebinding")
    func activityHookRefreshesWithoutRebinding() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let ledger = RestoreSessionsTriggerLedger()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture, ledger: ledger)
        do {
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.sessionStart), provenance: .matchingPane)
            let before = try await fixture.context()
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.stop), provenance: .matchingPane)
            let after = try await fixture.context()
            #expect(after.currentBinding?.bindingGenerationId == before.currentBinding?.bindingGenerationId)
            #expect(ledger.snapshot().map(\.kind) == [.bindingChanged, .agentMessage])
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }

    @Test("current main accepts arbitrary provider versions and still emits the committed trigger")
    func providerVersionDoesNotSuppressRestoreTrigger() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let ledger = RestoreSessionsTriggerLedger()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture, ledger: ledger)
        do {
            _ = try await adapter.recordProviderEvent(
                paneId: fixture.paneId, params: fixture.event(.sessionStart, version: "future-version"),
                provenance: .matchingPane)
            #expect(ledger.snapshot().map(\.kind) == [.bindingChanged])
            #expect(try await fixture.context().currentBinding?.providerConversationId == fixture.sessionId)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }

    @Test("a malformed hook has no binding trigger or foreground side effect")
    func refusedMalformedHookCannotTriggerLook() async throws {
        let fixture = try AppResumeSessionsFixture()
        let ingestion = fixture.makeIngestion()
        let ledger = RestoreSessionsTriggerLedger()
        let adapter = resumeProducerAdapter(ingestion: ingestion, fixture: fixture, ledger: ledger)
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
            #expect(ledger.snapshot().isEmpty)
            #expect(try await fixture.context().currentBinding == nil)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }
}
