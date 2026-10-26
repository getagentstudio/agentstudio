import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

struct PaneContextScenarioFacts: Sendable {
    let owner: PaneId
    let drawer: PaneId
    let now: Date
    let line: AgentLineDetail?
    let messages: [PaneContextStoredMessage]
    let own: PaneMessageCounts
    let scoped: PaneMessageCounts
    let presentation: PaneAgentStatusPresentation
    let session: SessionSummary?
    let activityDate: Date

    static func make(_ scenario: PaneContextScenario) async throws -> Self {
        let owner = PaneId.generateUUIDv7()
        let drawer = PaneId.generateUUIDv7()
        let now = PaneContextScenario.writtenAt.addingTimeInterval(scenario.line?.ageSeconds ?? 0)
        let line = scenario.line.map {
            AgentLineDetail(summary: $0.text, refs: [], writer: .pane(owner), updatedAt: PaneContextScenario.writtenAt)
        }
        let messages = try scenario.messages.enumerated().map { index, input in
            try storedMessage(
                input, owner: owner, drawer: drawer, position: UInt64(index + 1),
                at: now.addingTimeInterval(Double(index - scenario.messages.count + 1)))
        }
        let own = PaneMessageCountFold.summarize(messages: messages, sourceOrder: [owner])
        let scoped = PaneMessageCountFold.summarize(messages: messages, sourceOrder: [owner, drawer])
        let status = try await publishedStatus(scenario, pane: owner)
        return Self(
            owner: owner, drawer: drawer, now: now, line: line, messages: messages, own: own, scoped: scoped,
            presentation: status.presentation, session: status.session,
            activityDate: now.addingTimeInterval(-scenario.activityAgeSeconds))
    }

    private static func storedMessage(
        _ input: PaneContextScenario.MessageInput, owner: PaneId, drawer: PaneId, position: UInt64, at: Date
    ) throws -> PaneContextStoredMessage {
        let source: PaneId
        let body: String
        let importance: MessageImportance
        let shape: AgentMessageShape
        switch input {
        case .notice(let level, let text, let state, let isDrawer):
            source = isDrawer ? drawer : owner
            body = text
            importance = level
            shape = .notice(state)
        case .ask(let formInput, let text, let answer):
            source = owner
            body = text
            importance = .attention
            let form: AskForm
            switch formInput {
            case .singleChoice:
                form = .choice(
                    options: [
                        .init(id: try .init("red"), label: "red"), .init(id: try .init("blue"), label: "blue"),
                    ], allowsMultiple: false)
            case .multipleChoice:
                form = .choice(
                    options: [
                        .init(id: try .init("swift"), label: "Swift"),
                        .init(id: try .init("bridgeweb"), label: "BridgeWeb"),
                        .init(id: try .init("e2e"), label: "E2E"),
                    ], allowsMultiple: true)
            case .approval: throw ScenarioFactsFailure.approvalBelongsToP6
            }
            let state: AskState =
                switch answer {
                case .open: .open
                case .pending:
                    .answered(by: .localUser, value: .choices([try .init("blue")]), receipt: .notYetConfirmed)
                case .confirmed:
                    .answered(by: .localUser, value: .choices([try .init("blue")]), receipt: .confirmed(at: at))
                case .unconfirmed:
                    .answered(by: .localUser, value: .choices([try .init("blue")]), receipt: .unconfirmed)
                case .dismissed: .dismissed
                }
            let waiting: AskWaiting =
                answer == .dismissed ? .nonBlocking : .blocking(deadline: at.addingTimeInterval(60))
            shape = .ask(.question, form, waiting, state)
        }
        let sender: AgentMessageSender =
            switch shape {
            case .notice: .pane(source)
            case .ask:
                .session(
                    provider: try .init("codex"), sessionRef: try .init("scenario-session"),
                    bindingGeneration: UUIDv7.generate())
            }
        let actions: [MessageAction] = scenarioFileAction(body)
        return .init(
            rowId: UUIDv7.generate(), position: position,
            detail: .init(
                id: .generateUUIDv7(), sourcePaneId: source, sender: sender, sentAt: at,
                sourceOccurredAt: nil, importance: importance, body: body, why: nil, actions: actions, shape: shape),
            settledAt: nil, displayHidden: false)
    }

    private static func scenarioFileAction(_ body: String) -> [MessageAction] {
        body == "Build failed: 3 errors in SessionsIngestion.swift"
            ? [.openFile(path: "Sources/AgentStudio/Features/Sessions/Runtime/SessionsIngestion.swift", line: 142)] : []
    }

    private static func publishedStatus(_ scenario: PaneContextScenario, pane: PaneId) async throws
        -> (presentation: PaneAgentStatusPresentation, session: SessionSummary?)
    {
        let fixture = try await CompositionFactoryFixture.make(ownerId: pane)
        let ingestion = fixture.composition.ingestion
        do {
            func admission(_ signal: SessionProviderSignal) -> SessionsHookAdmission {
                .init(
                    paneId: pane.uuid, providerIdentifier: "codex", providerVersion: "9.9.9",
                    sessionId: "scenario-session", eventName: signal.name, turnId: "scenario-turn",
                    signal: signal, recordId: UUIDv7.generate(), admittedAt: PaneContextScenario.writtenAt,
                    chain: TestMainAgentChain.observation)
            }
            func submit(_ signal: SessionProviderSignal) async throws {
                let result = try await ingestion.submitHook(admission(signal))
                guard case .committed = result else { throw ScenarioFactsFailure.missingPublication(scenario.id) }
            }
            if scenario.session == .unverifiedWorking {
                let hook = admission(.turnStart)
                try #require(
                    try await ingestion.recordUnverifiedStatus(
                        paneId: pane.uuid, hook: hook,
                        refusal: .init(
                            reason: .credentialNotRecognized, event: "turnStart", at: hook.admittedAt, intent: .status),
                        remainsPresent: { true }) == .hookApplied)
            } else if scenario.session != .unbound {
                try await submit(.turnStart)
                let binding = try #require(
                    try await ingestion.repository.statusContext(paneId: pane.uuid).currentBinding)
                switch scenario.session {
                case .ready:
                    try await submit(.turnDone)
                    ingestion.paneViewedMailbox.noteViewed(
                        pane.uuid, viewedAt: ContinuousClock.now.advanced(by: .seconds(1)))
                    await ingestion.consumePaneViewedBatch()
                case .question:
                    await ingestion.receiveOpenAskSummary(
                        .init(
                            bindingGenerationId: binding.bindingGenerationId,
                            summary: .init(sequence: 1, approval: 0, question: 1, blocked: 0)))
                case .approval:
                    switch scenario.prompts {
                    case .absent:
                        await ingestion.receiveOpenAskSummary(
                            .init(
                                bindingGenerationId: binding.bindingGenerationId,
                                summary: .init(sequence: 1, approval: 1, question: 0, blocked: 0)))
                    case .approvalWithoutSummary, .syntheticApprovalSummary, .syntheticTwoListedOneOmitted:
                        try await submit(.permission(toolName: "Bash", questions: nil))
                    }
                case .ended: try await submit(.sessionEnd)
                case .working, .unverifiedWorking, .unbound: break
                }
            }
            await ingestion.publishStatus(paneId: pane.uuid)
            let mailbox = await ingestion.statusPublicationMailbox
            guard case .set(let published)? = mailbox.takeBatch()[pane] else {
                throw ScenarioFactsFailure.missingPublication(scenario.id)
            }
            // G07/G08: the producer cannot emit these exact inputs. Keep the override explicit;
            // do not change provider mapping or limits, or claim this is a real-ingress proof.
            let prepared: PaneAgentStatusPresentation
            if scenario.isSyntheticPromptInput {
                prepared = .init(
                    status: published.status, evidence: published.evidence,
                    compactPrompt: .init(
                        reason: .approval, summary: "Allow write to ~/.zshrc?",
                        observedAt: PaneContextScenario.writtenAt,
                        omittedOrFurtherCount: scenario.id == "S18-synthetic-input" ? 2 : 0),
                    promptListRevision: published.promptListRevision)
            } else {
                prepared = published
            }
            let session = try await ingestion.sessionSummary(paneId: pane.uuid)
            try await fixture.close()
            return (prepared, session)
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    private enum ScenarioFactsFailure: Error {
        case approvalBelongsToP6
        case missingPublication(String)
    }
}
