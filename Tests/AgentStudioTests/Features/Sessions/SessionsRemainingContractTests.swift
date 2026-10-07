import AgentStudioInfrastructure
import Foundation
import GRDB
import Testing

@testable import AgentStudioSessions

@Suite("Sessions remaining contracts")
struct SessionsRemainingContractTests {
    @Test("ended sessions stay readable and only their SessionStart can revive them after reload")
    func endedRecordsStayOutOfRestore() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let pane = UUIDv7.generate()
        let endedBindingId = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let startOutcome = try await ingestion.submitHook(makeHookAdmission(paneId: pane))
            let start = try #require(committedHookCommit(from: startOutcome))
            let endOutcome = try await ingestion.submitHook(
                makeHookAdmission(paneId: pane, eventName: .sessionEnd, signal: .sessionEnd))
            _ = try #require(committedHookCommit(from: endOutcome))
            let delayedOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: pane, eventName: .permission,
                    signal: .permission(toolName: "Read", questions: nil)))
            let delayed = try #require(committedHookCommit(from: delayedOutcome))
            #expect(delayed.disposition == .recordedOnly)
            #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .idle(.ended))
            return start.binding.bindingGenerationId
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restored in
            #expect(try await restored.sessionSummary(paneId: pane)?.status == .idle(.ended))
            let reboundOutcome = try await restored.submitHook(makeHookAdmission(paneId: pane))
            let rebound = try #require(committedHookCommit(from: reboundOutcome))
            #expect(rebound.disposition == .bound)
            #expect(rebound.binding.bindingGenerationId == endedBindingId)
            #expect(try await restored.sessionSummary(paneId: pane)?.status == .unknown)
        }
    }

    @Test("the same conversation has independent live bindings in two panes after reload")
    func sameConversationRemainsIndependentAcrossPanes() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let firstPane = UUIDv7.generate()
        let secondPane = UUIDv7.generate()
        let firstInstant = ContinuousClock.now
        let secondInstant = firstInstant + .milliseconds(1)
        let firstBindingId = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let firstOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: firstPane, sessionId: "shared", admissionInstant: firstInstant))
            let first = try #require(committedHookCommit(from: firstOutcome))
            let secondOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: secondPane, sessionId: "shared", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read"), admissionInstant: secondInstant))
            let second = try #require(committedHookCommit(from: secondOutcome))
            #expect(second.disposition == .bound)
            #expect(second.binding.bindingGenerationId != first.binding.bindingGenerationId)
            #expect(try await ingestion.sessionSummary(paneId: firstPane)?.status == .unknown)
            #expect(try await ingestion.sessionSummary(paneId: secondPane)?.status == .working(.active))
            return first.binding.bindingGenerationId
        }
        try await withSessionsIngestion(repository: fixture.makeRepository()) { restored in
            let firstSummary = try await restored.sessionSummary(paneId: firstPane)
            let secondSummary = try await restored.sessionSummary(paneId: secondPane)
            #expect(firstSummary?.bindingGeneration == firstBindingId)
            #expect(secondSummary?.bindingGeneration != firstBindingId)
            #expect(firstSummary?.status == .unknown)
            #expect(secondSummary?.status == .working(.active))
        }
    }

    @Test("a second pane's first SessionStart reuses the known provider conversation")
    func sameConversationSessionStartReusesConversationIdentity() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let firstPane = UUIDv7.generate()
        let secondPane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let firstOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: firstPane, sessionId: "shared", eventName: .sessionStart,
                    signal: .sessionStart, turnId: nil))
            let first = try #require(committedHookCommit(from: firstOutcome))
            let secondOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: secondPane, sessionId: "shared", eventName: .sessionStart,
                    signal: .sessionStart, turnId: nil))
            let second = try #require(committedHookCommit(from: secondOutcome))
            #expect(second.binding.conversationId == first.binding.conversationId)
            #expect(second.binding.bindingGenerationId != first.binding.bindingGenerationId)
        }
        let queue = try DatabaseQueue(path: fixture.databaseURL.path)
        let conversationCount = try await queue.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM sessions_conversation
                    WHERE provider_identifier = 'codex' AND provider_conversation_id = 'shared'
                    """)
        }
        #expect(conversationCount == 1)
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let first = try #require(try await ingestion.sessionSummary(paneId: firstPane))
            let second = try #require(try await ingestion.sessionSummary(paneId: secondPane))
            #expect(first.bindingGeneration != second.bindingGeneration)
            #expect(first.sessionRef.value == "shared")
            #expect(second.sessionRef.value == "shared")
        }
    }

    @Test("an unconfirmed takeover reuses a provider conversation known on another pane")
    func unconfirmedTakeoverReusesConversationIdentity() async throws {
        let fixture = try SessionsFileDatabaseFixture()
        defer { fixture.removeFiles() }
        let knownPane = UUIDv7.generate()
        let takeoverPane = UUIDv7.generate()
        let knownConversationId = try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let knownOutcome = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: knownPane, sessionId: "shared", eventName: .sessionStart,
                    signal: .sessionStart, turnId: nil))
            let known = try #require(committedHookCommit(from: knownOutcome))
            _ = try await ingestion.submitHook(
                makeHookAdmission(
                    paneId: takeoverPane, sessionId: "old", eventName: .toolActivity,
                    signal: .toolActivity(toolName: "Read")))
            return known.binding.conversationId
        }
        let takeoverConversationId = try await withSessionsIngestion(
            repository: fixture.makeRepository(),
            operation: { ingestion in
                _ = try await ingestion.sessionSummary(paneId: takeoverPane)
                let outcome = try await ingestion.submitHook(
                    makeHookAdmission(
                        paneId: takeoverPane, sessionId: "shared", eventName: .sessionStart,
                        signal: .sessionStart, turnId: nil))
                let takeover = try #require(committedHookCommit(from: outcome))
                let context = try await ingestion.repository.statusContext(paneId: takeoverPane)
                #expect(takeover.binding.conversationId == knownConversationId)
                #expect(context.bindings.contains { $0.providerConversationId == "old" && $0.status == .ended })
                return takeover.binding.conversationId
            })
        #expect(takeoverConversationId == knownConversationId)
        let queue = try DatabaseQueue(path: fixture.databaseURL.path)
        let conversationCount = try await queue.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM sessions_conversation
                    WHERE provider_identifier = 'codex' AND provider_conversation_id = 'shared'
                    """)
        }
        #expect(conversationCount == 1)
    }
}
