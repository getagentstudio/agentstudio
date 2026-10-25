import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

@MainActor
@Suite("One real election walk and no foreground following", .serialized)
struct OneProcessWalkTests {
    @Test("server ancestry is rejected on every predicting hook on both ingress routes", arguments: [false, true])
    func rejectedServerHooksRepeatRealWalk(unverified: Bool) async throws {
        let fixture = try MainEligibilityDatabaseFixture()
        let ingestion = fixture.makeIngestion(reader: MatchingTestPaneTerminalLeaderReader())
        let facts = ElectionProcessFacts(relation: .server)
        let adapter = AgentStudioIPCSessionsAdapter(
            ingestion: ingestion,
            processChainReader: DarwinProcessChainReader(
                facts: facts, readLimit: AppPolicies.Sessions.mainEligibilityReadLimit))
        let pane = UUIDv7.generate()
        let session = UUIDv7.generate().uuidString
        do {
            for _ in 0..<3 {
                try await sendCodexElectionHook(
                    adapter, pane: pane, session: session, name: .toolActivity, unverified: unverified)
                #expect(try await fixture.repository.statusContext(paneId: pane).currentBinding == nil)
            }
            #expect(facts.walks == 3)
            #expect(facts.versionReads == 6)
            #expect(await ingestion.unverifiedStatusRuntime.panes[pane]?.main == nil)
            let ended = try await ingestion.endLiveMainForColdRestore(paneId: pane)
            #expect(ended == nil)
            let verdict = await SessionsResumeResolver().resumeEvidence(
                for: .init(
                    paneId: pane, zmxSessionId: .generateUUIDv7(), coldEndedMain: ended, evidence: nil,
                    isSameBoot: false, inventory: .unavailable(.timedOut)))
            #expect(verdict == .knownExited)
            await ingestion.finish()
        } catch {
            await ingestion.finish()
            throw error
        }
    }

    @Test(
        "pane and unrelated tmux relations bind once; later hooks, messages and output read no processes",
        arguments: [ElectionProcessRelation.pane, .multiplexer])
    func boundAgentStopsProcessReads(relation: ElectionProcessRelation) async throws {
        try await withCompositionFactory { fixture in
            let facts = ElectionProcessFacts(relation: relation)
            let adapter = AgentStudioIPCSessionsAdapter(
                ingestion: fixture.composition.ingestion,
                processChainReader: DarwinProcessChainReader(
                    facts: facts,
                    readLimit: AppPolicies.Sessions.mainEligibilityReadLimit))
            let pane = fixture.ownerId.uuid
            let session = UUIDv7.generate().uuidString
            try await sendCodexElectionHook(adapter, pane: pane, session: session, name: .sessionStart)
            #expect(facts.walks == 1)
            #expect(
                try await fixture.composition.ingestion.repository.statusContext(paneId: pane).currentBinding?
                    .providerConversationId == session)
            for name in [IPCSessionEventName.turnStart, .toolActivity, .turnStart] {
                try await sendCodexElectionHook(adapter, pane: pane, session: session, name: name)
            }
            let message = UUIDv7.generate()
            _ = try await fixture.composition.paneContextIPCAdapter.sendMessage(
                paneId: pane,
                params: .init(
                    handle: pane.uuidString, messageId: message,
                    writer: .init(provider: "codex", conversationId: session),
                    importance: .info, body: "No process lookup for a message", actions: [], shape: .notice,
                    correlationId: UUIDv7.generate()))
            let detail = await fixture.composition.paneContextService.readDetail(
                .init(paneId: fixture.ownerId, page: .first))
            guard case .detail(let value) = detail else {
                Issue.record("real committed message detail unavailable")
                return
            }
            #expect(value.messages.contains { $0.id.uuid == message })
            let updates = Mutex(0)
            let projector = TerminalActivityProjector()
            await projector.configure { outcomes in
                for case .compactStateChanged in outcomes { updates.withLock { $0 += 1 } }
            }
            let state = ScrollbarState(top: 0, bottom: 40, total: 40)
            await projector.ingest(
                surfaceID: UUIDv7.generate(), paneID: pane,
                aggregate: .init(state: state, observedAtMilliseconds: 1), latestState: state,
                context: .init(isAttended: true, isAgentClassified: false, outputBurstThreshold: 30))
            await projector.reset()
            #expect(updates.withLock { $0 } == 1)
            #expect(facts.walks == 1)
            #expect(facts.versionReads == 2)
            let ended = try await fixture.composition.ingestion.endLiveMainForColdRestore(paneId: pane)
            #expect(ended != nil)
            let result = await SessionsResumeResolver().resumeEvidence(
                for: .init(
                    paneId: pane, zmxSessionId: .generateUUIDv7(), coldEndedMain: ended, evidence: nil,
                    isSameBoot: false, inventory: .unavailable(.timedOut)))
            #expect(
                result
                    == .interruptedCandidate(
                        .init(
                            provider: .codex,
                            sessionId: try ProviderSessionId(rawValue: session))))
        }
    }
}

enum ElectionProcessRelation: Equatable, Sendable { case server, pane, multiplexer }

final class ElectionProcessFacts: ProcessChainFactsReading {
    private struct Counts {
        var walks = 0
        var versions = 0
    }
    private let counts = Mutex(Counts())
    private let relation: ElectionProcessRelation
    init(relation: ElectionProcessRelation) { self.relation = relation }
    var walks: Int { counts.withLock { $0.walks } }
    var versionReads: Int { counts.withLock { $0.versions } }
    func pidVersion(of pid: Int32) -> UInt32? {
        counts.withLock { $0.versions += 1 }
        return pid == 90 ? 17 : nil
    }
    func executableName(of process: ProcessChainProcessFacts) -> String? {
        counts.withLock { $0.walks += 1 }
        return process.executableName
    }
    func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts? {
        let shell: Int32 = relation == .pane ? 58 : 500
        let parent: Int32 = relation == .multiplexer ? 2 : 1
        let data: (Int32, UInt64, String)
        switch pid {
        case 90: data = (80, 4, "agentstudio")
        case 80: data = (shell, 3, "codex")
        case shell: data = (parent, 1, "zsh")
        case 1: data = (0, 0, "launchd")
        case 2: data = (1, 0, "tmux")
        default: return nil
        }
        return .init(
            incarnation: .init(pid: pid, startSeconds: data.1, startMicroseconds: 0),
            parentPID: data.0, executableName: data.2)
    }
}

private func sendCodexElectionHook(
    _ adapter: AgentStudioIPCSessionsAdapter, pane: UUID, session: String,
    name: IPCSessionEventName, unverified: Bool = false
) async throws {
    let event = IPCSessionEventIdentity(
        name: name, conversationId: session, turnId: nil,
        requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate())
    let provider = IPCSessionProviderIdentity(identifier: "codex", version: "1", mode: "cli")
    let peer = AppIPCPeerProcess(pid: 90, pidVersion: 17)
    if unverified {
        _ = try await adapter.recordUnverifiedStatus(
            paneId: pane,
            params: .init(
                paneClaim: .init(paneId: pane, workspaceId: UUIDv7.generate()), tokenOutcome: .rejected,
                report: .hook(event: event, provider: provider, providerSessionId: session),
                correlationId: UUIDv7.generate()), peerProcess: peer, revalidateClaim: {})
    } else {
        _ = try await adapter.recordProviderEvent(
            paneId: pane,
            params: .init(
                handle: "self", provider: provider, event: event, correlationId: UUIDv7.generate()),
            provenance: .matchingPane, peerProcess: peer)
    }
}
