import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioSessions

@Suite("Sessions presentation publication")
struct SessionsPresentationPublicationTests {
    enum EvidenceScenario: CaseIterable, Sendable { case live, ended, unverified, unbound }

    @Test("G10 publication records the actual selected evidence", arguments: EvidenceScenario.allCases)
    func publicationEvidence(scenario: EvidenceScenario) async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            let expectedEvidence: StatusEvidence
            let expectedStatus: AgentSessionStatus
            switch scenario {
            case .live:
                try await Self.submit(.turnStart, pane: pane, to: ingestion)
                expectedEvidence = .verifiedLive
                expectedStatus = .working(.active)
            case .ended:
                try await Self.submit(.turnStart, pane: pane, to: ingestion)
                try await Self.submit(.sessionEnd, pane: pane, to: ingestion)
                expectedEvidence = .verifiedEnded
                expectedStatus = .idle(.ended)
            case .unverified:
                #expect(
                    try await SessionsUnverifiedStatusTests.submit(ingestion, pane: pane, signal: .turnStart)
                        == .hookApplied)
                expectedEvidence = .unverified
                expectedStatus = .working(.active)
            case .unbound:
                await ingestion.recordRefusal(
                    paneId: pane, refusal: .init(reason: .queueFull, event: nil, at: .distantPast))
                expectedEvidence = .none
                expectedStatus = .unknown
            }
            let mailbox = await ingestion.statusPublicationMailbox
            let value = try Self.published(mailbox.takeBatch(), pane: pane)
            #expect(value.evidence == expectedEvidence)
            #expect(value.status == expectedStatus)
            #expect(value.compactPrompt == nil)
            #expect(value.promptListRevision == 0)
        }
    }

    @Test("A second-prompt edit changes the publication while its compact first prompt remains equal")
    func secondPromptInvalidatesPublication() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            try await Self.submit(.turnStart, pane: pane, to: ingestion)
            try await Self.submit(.elicitation(id: "a", summary: "First prompt"), pane: pane, to: ingestion)
            try await Self.submit(.elicitation(id: "b", summary: "Second prompt"), pane: pane, to: ingestion)
            let mailbox = await ingestion.statusPublicationMailbox
            let before = try Self.published(mailbox.takeBatch(), pane: pane)
            #expect(before.evidence == .verifiedLive)
            #expect(before.compactPrompt?.reason == .question)
            #expect(before.compactPrompt?.summary == "First prompt")
            #expect(before.compactPrompt?.observedAt == Date(timeIntervalSince1970: 1_800_000_000))
            #expect(before.compactPrompt?.omittedOrFurtherCount == 1)

            try await Self.submit(.elicitation(id: "b", summary: "Changed second prompt"), pane: pane, to: ingestion)

            let after = try Self.published(mailbox.takeBatch(), pane: pane)
            #expect(after.status == .needsYou(.question))
            #expect(after.compactPrompt == before.compactPrompt)
            #expect(after.promptListRevision == before.promptListRevision + 1)
            let summary = try #require(try await ingestion.sessionSummary(paneId: pane))
            #expect(summary.providerPrompts.map(\.summary) == ["First prompt", "Changed second prompt"])
            let revision = after.promptListRevision
            await ingestion.publishStatus(paneId: pane)
            #expect(mailbox.takeBatch().isEmpty)
            try await Self.submit(.elicitationResult(id: "b"), pane: pane, to: ingestion)
            #expect(try Self.published(mailbox.takeBatch(), pane: pane).promptListRevision == revision + 1)
        }
    }

    @Test("A source omission changes prompt revision even while all listed prompts stay equal")
    func omittedPromptCountInvalidatesPublication() async throws {
        let fixture = try SessionsDatabaseFixture()
        let pane = UUIDv7.generate()
        try await withSessionsIngestion(repository: fixture.makeRepository()) { ingestion in
            try await Self.submit(.turnStart, pane: pane, to: ingestion)
            for index in 0..<16 {
                try await Self.submit(
                    .elicitation(id: "\(index)", summary: "Prompt \(index)"), pane: pane, to: ingestion)
            }
            let mailbox = await ingestion.statusPublicationMailbox
            let before = try Self.published(mailbox.takeBatch(), pane: pane)
            let beforeSummary = try #require(try await ingestion.sessionSummary(paneId: pane))
            #expect(beforeSummary.providerPrompts.count == 16)
            #expect(beforeSummary.omittedPromptCount == 0)
            try await Self.submit(.elicitation(id: "z", summary: "Omitted prompt"), pane: pane, to: ingestion)
            let after = try Self.published(mailbox.takeBatch(), pane: pane)
            let afterSummary = try #require(try await ingestion.sessionSummary(paneId: pane))
            #expect(afterSummary.providerPrompts == beforeSummary.providerPrompts)
            #expect(afterSummary.omittedPromptCount == 1)
            #expect(after.compactPrompt?.summary == "Prompt 0")
            #expect(after.compactPrompt?.omittedOrFurtherCount == 16)
            #expect(after.promptListRevision == before.promptListRevision + 1)
        }
    }

    private static func submit(_ signal: SessionProviderSignal, pane: UUID, to ingestion: SessionsIngestion)
        async throws
    {
        let result = try await ingestion.submitHook(
            makeHookAdmission(paneId: pane, eventName: signal.name, signal: signal, turnId: nil))
        try #require(committedHookCommit(from: result) != nil)
    }

    private static func published(_ batch: [PaneId: SessionStatusPublication], pane: UUID) throws
        -> PaneAgentStatusPresentation
    {
        let publication = try #require(batch[.init(existingUUID: pane)], "The source must publish changed prompt facts")
        guard case .set(let value) = publication else {
            throw PublicationFailure.unexpectedRemoval
        }
        return value
    }

    private enum PublicationFailure: Error { case unexpectedRemoval }
}
