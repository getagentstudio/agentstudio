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

extension SessionsProviderTraceIntegrationTests {
    @Test("an active matching hook applies without another process walk", arguments: [false, true])
    func activeBindingSkipsProcessWalk(unverified: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = CountingElectionProcessReader()
        let pane = UUIDv7.generate()
        try await fixture.withIngestion(processChainReader: reader) { ingestion, adapter in
            try await sendElectionHook(adapter, pane: pane, name: .turnStart, peerPID: 100, unverified: unverified)
            #expect(reader.peers == [100])
            try await sendElectionHook(adapter, pane: pane, name: .permission, peerPID: 101, unverified: unverified)
            #expect(reader.peers == [100])
            if unverified {
                #expect(await ingestion.unverifiedStatusRuntime.status(paneId: pane) == .needsYou(.approval))
            } else {
                let context = try await ingestion.repository.statusContext(paneId: pane)
                #expect(context.evidence.count == 2)
                #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .needsYou(.approval))
            }
        }
    }

    @Test("invalid provenance and payloads spend no process reads", arguments: [false, true])
    func invalidHooksDoNotReadProcesses(unverified: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = CountingElectionProcessReader()
        try await fixture.withIngestion(processChainReader: reader) { _, adapter in
            let pane = UUIDv7.generate()
            for (name, conversation) in [
                (IPCSessionEventName.turnStart, ""), (.question, "main"), (.turnFailed, "main"),
            ] {
                await #expect(throws: AppIPCSessionsError.self) {
                    try await sendElectionHook(
                        adapter, pane: pane, name: name, peerPID: 100,
                        unverified: unverified, conversation: conversation)
                }
            }
            let event = IPCSessionEventIdentity(
                name: .turnStart, conversationId: "main", turnId: nil, requestId: nil,
                toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate())
            let provider = IPCSessionProviderIdentity(identifier: "codex", version: "1", mode: "cli")
            if unverified {
                await #expect(throws: AppIPCSessionsError.self) {
                    try await adapter.recordUnverifiedStatus(
                        paneId: pane,
                        params: .init(
                            paneClaim: .init(paneId: pane, workspaceId: UUIDv7.generate()), tokenOutcome: .rejected,
                            report: .hook(event: event, provider: provider, providerSessionId: "other"),
                            correlationId: UUIDv7.generate()), revalidateClaim: {})
                }
                await #expect(throws: AppIPCSessionsError.self) {
                    try await adapter.recordUnverifiedStatus(
                        paneId: pane,
                        params: .init(
                            paneClaim: .init(paneId: pane, workspaceId: UUIDv7.generate()), tokenOutcome: .rejected,
                            report: .hook(event: event, provider: provider, providerSessionId: "main"),
                            correlationId: UUIDv7.generate()),
                        revalidateClaim: { throw AppIPCSessionsError(reason: .validationRejected) })
                }
            } else {
                await #expect(throws: AppIPCSessionsError.self) {
                    try await adapter.recordProviderEvent(
                        paneId: pane,
                        params: .init(
                            handle: "self", provider: provider, event: event,
                            correlationId: UUIDv7.generate()), provenance: .other)
                }
            }
            #expect(reader.peers.isEmpty)
        }
    }

    @Test("ending and reopening the same conversation observes its new process", arguments: [false, true])
    func resumedConversationReadsFreshEvidence(unverified: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = CountingElectionProcessReader()
        let pane = UUIDv7.generate()
        try await fixture.withIngestion(processChainReader: reader) { ingestion, adapter in
            try await sendElectionHook(adapter, pane: pane, name: .sessionStart, peerPID: 100, unverified: unverified)
            let generation = try await ingestion.repository.statusContext(paneId: pane).currentBinding?
                .bindingGenerationId
            try await sendElectionHook(adapter, pane: pane, name: .sessionEnd, peerPID: 101, unverified: unverified)
            reader.setObservation(
                .agentShell(
                    shell: .init(pid: 999, startSeconds: 200, startMicroseconds: 0),
                    shellParent: .other))
            try await sendElectionHook(adapter, pane: pane, name: .sessionStart, peerPID: 102, unverified: unverified)
            #expect(reader.peers == [100, 102])
            if unverified {
                #expect(await ingestion.unverifiedStatusRuntime.panes[pane]?.main == nil)
            } else {
                #expect(try await ingestion.repository.statusContext(paneId: pane).currentBinding?.status == .ended)
            }
            reader.setObservation(
                .agentShell(
                    shell: .init(pid: 999, startSeconds: 200, startMicroseconds: 0),
                    shellParent: .multiplexerServer(.tmux)))
            try await sendElectionHook(adapter, pane: pane, name: .sessionStart, peerPID: 103, unverified: unverified)
            #expect(reader.peers == [100, 102, 103])
            if unverified {
                #expect(await ingestion.unverifiedStatusRuntime.panes[pane]?.main?.sessionId == "same-conversation")
            } else {
                let resumed = try await ingestion.repository.statusContext(paneId: pane).currentBinding
                #expect(resumed?.status == .active)
                #expect(resumed?.bindingGenerationId == generation)
            }
        }
    }

    @Test("unknown ancestry is retried by the next non-start hook after restart", arguments: [false, true])
    func unknownProcessIsRetryable(unverified: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = CountingElectionProcessReader()
        reader.setObservation(.unknown(.peerUnbound))
        let pane = UUIDv7.generate()
        try await fixture.withIngestion(processChainReader: reader) { ingestion, adapter in
            try await sendElectionHook(adapter, pane: pane, name: .toolActivity, peerPID: 100, unverified: unverified)
            #expect(try await ingestion.repository.statusContext(paneId: pane).currentBinding == nil)
        }
        // Reopen the real database with a new ingestion runtime; no SessionStart is required.
        try await fixture.withIngestion(processChainReader: reader) { ingestion, adapter in
            reader.setObservation(
                .agentShell(
                    shell: .init(pid: 500, startSeconds: 1, startMicroseconds: 0),
                    shellParent: .multiplexerServer(.herdr)))
            try await sendElectionHook(adapter, pane: pane, name: .turnStart, peerPID: 101, unverified: unverified)
            #expect(reader.peers == [100, 101])
            if unverified {
                #expect(await ingestion.unverifiedStatusRuntime.status(paneId: pane) == .working(.active))
            } else {
                #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .working(.active))
            }
        }
    }
}

func sendElectionHook(
    _ adapter: AgentStudioIPCSessionsAdapter, pane: UUID, name: IPCSessionEventName,
    peerPID: Int32, unverified: Bool, conversation: String = "same-conversation"
) async throws {
    let event = IPCSessionEventIdentity(
        name: name, conversationId: conversation, turnId: nil, requestId: nil,
        toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate())
    let provider = IPCSessionProviderIdentity(identifier: "claude-code", version: "2.1.310", mode: "cli")
    let peer = AppIPCPeerProcess(pid: peerPID, pidVersion: 17)
    if unverified {
        _ = try await adapter.recordUnverifiedStatus(
            paneId: pane,
            params: .init(
                paneClaim: .init(paneId: pane, workspaceId: UUIDv7.generate()), tokenOutcome: .rejected,
                report: .hook(event: event, provider: provider, providerSessionId: conversation),
                correlationId: UUIDv7.generate()), peerProcess: peer, revalidateClaim: {})
    } else {
        _ = try await adapter.recordProviderEvent(
            paneId: pane,
            params: .init(
                handle: "self", provider: provider, event: event,
                correlationId: UUIDv7.generate()),
            provenance: .matchingPane, peerProcess: peer)
    }
}

final class CountingElectionProcessReader: ProcessChainReading {
    private struct State {
        var peers: [Int32?] = []
        var observation = ProcessChainObservation.agentShell(
            shell: .init(pid: 500, startSeconds: 1, startMicroseconds: 0), shellParent: .multiplexerServer(.tmux))
    }
    private let state = Mutex(State())
    var peers: [Int32?] { state.withLock { $0.peers } }
    func setObservation(_ observation: ProcessChainObservation) { state.withLock { $0.observation = observation } }
    func observe(peer: ProcessChainPeer?, provider: String) -> ProcessChainObservation {
        state.withLock {
            $0.peers.append(peer?.pid)
            return $0.observation
        }
    }
}
