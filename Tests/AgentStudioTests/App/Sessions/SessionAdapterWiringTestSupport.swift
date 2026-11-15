import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Synchronization

@testable import AgentStudio
@testable import AgentStudioSessions

final class ScriptedIPCProcessFacts: ProcessChainFactsReading {
    private let peerPID: Int32
    private let peerVersion: UInt32
    private let processes: [Int32: ProcessChainProcessFacts]
    private let versionReads = Mutex(0)
    let shell: ZmxProcessIncarnation

    init(peerPID: Int32, peerVersion: UInt32, nested: Bool) {
        self.peerPID = peerPID
        self.peerVersion = peerVersion
        let identifiers: [Int32] = [20, 30, 40, 50, 58, 60].filter { $0 != peerPID }
        let providerPID = identifiers[0]
        let shellPID = identifiers[1]
        let shellParentPID = identifiers[2]
        let toolShellPID = identifiers[3]
        let ancestorPID = identifiers[4]
        shell = .init(pid: shellPID, startSeconds: 1, startMicroseconds: 0)
        processes = [
            peerPID: Self.process(peerPID, parent: providerPID, start: 100, name: "agentstudio-cli"),
            providerPID: Self.process(providerPID, parent: nested ? toolShellPID : shellPID, start: 90, name: "claude"),
            shellPID: Self.process(shellPID, parent: shellParentPID, start: 1, name: "zsh"),
            shellParentPID: Self.process(shellParentPID, parent: 1, start: 0, name: "zmx"),
            toolShellPID: Self.process(toolShellPID, parent: ancestorPID, start: 80, name: "zsh"),
            ancestorPID: Self.process(ancestorPID, parent: shellPID, start: 70, name: "claude"),
        ]
    }

    var versionReadCount: Int { versionReads.withLock { $0 } }
    func pidVersion(of pid: Int32) -> UInt32? {
        versionReads.withLock { $0 += 1 }
        return pid == peerPID ? peerVersion : nil
    }
    func bsdInfo(of pid: Int32) -> ProcessChainProcessFacts? { processes[pid] }

    private static func process(_ pid: Int32, parent: Int32, start: UInt64, name: String) -> ProcessChainProcessFacts {
        .init(
            incarnation: .init(pid: pid, startSeconds: start, startMicroseconds: 0), parentPID: parent,
            executableName: name)
    }
}

enum AdapterObservationOperation: Equatable, Sendable { case observe, clock, enqueue }

final class AdapterObservationRecorder: Sendable {
    private struct State {
        var operations: [AdapterObservationOperation] = []
        var peers: [ProcessChainPeer?] = []
    }
    private let state = Mutex(State())
    var operations: [AdapterObservationOperation] { state.withLock { $0.operations } }
    var peers: [ProcessChainPeer?] { state.withLock { $0.peers } }
    func record(_ operation: AdapterObservationOperation) { state.withLock { $0.operations.append(operation) } }
    func observed(_ peer: ProcessChainPeer?) {
        state.withLock {
            $0.operations.append(.observe)
            $0.peers.append(peer)
        }
    }
}

private struct RecordingAdapterProcessReader: ProcessChainReading {
    let recorder: AdapterObservationRecorder
    func observe(peer: ProcessChainPeer?, provider: String) -> ProcessChainObservation {
        recorder.observed(peer)
        return TestMainAgentChain.observation
    }
}

struct AdapterObservationResult: Sendable {
    let operations: [AdapterObservationOperation]
    let peers: [ProcessChainPeer?]
    let session: String?
    let refusal: AgentConnectionRefusalReason?
}

@concurrent nonisolated func driveAdapterObservation(route: MainEligibilityRoute, refusalOnly: Bool) async throws
    -> AdapterObservationResult
{
    let fixture = try MainEligibilityDatabaseFixture()
    let recorder = AdapterObservationRecorder()
    let pane = UUIDv7.generate()
    let ingestion = SessionsIngestion(
        repository: fixture.repository, limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
        probe: { statistics in
            if statistics.event == .depthChanged, statistics.pendingGlobal == 1 { recorder.record(.enqueue) }
        }, terminalLeaderReader: MatchingTestPaneTerminalLeaderReader())
    let adapter = AgentStudioIPCSessionsAdapter(
        ingestion: ingestion,
        continuousNow: {
            recorder.record(.clock)
            return ContinuousClock.now
        },
        processChainReader: RecordingAdapterProcessReader(recorder: recorder))
    let provider = IPCSessionProviderIdentity(identifier: "claude-code", version: "1", mode: "interactive")
    let event = adapterWiringEvent()
    let peer = AppIPCPeerProcess(pid: 500, pidVersion: 17)
    do {
        switch route {
        case .verified:
            _ = try await adapter.recordProviderEvent(
                paneId: pane,
                params: .init(
                    handle: pane.uuidString, provider: provider, event: event, correlationId: UUIDv7.generate()),
                provenance: .matchingPane, peerProcess: peer)
        case .claim:
            _ = try await adapter.recordUnverifiedStatus(
                paneId: pane,
                params: .init(
                    paneClaim: .init(paneId: pane, workspaceId: UUIDv7.generate()), tokenOutcome: .absent,
                    report: refusalOnly
                        ? .refusal(reason: .noSessionId)
                        : .hook(event: event, provider: provider, providerSessionId: event.conversationId),
                    correlationId: UUIDv7.generate()),
                peerProcess: peer, revalidateClaim: {})
        }
        let context = try await fixture.repository.statusContext(paneId: pane)
        let claimSession = await ingestion.unverifiedStatusRuntime.panes[pane]?.main?.sessionId
        let session = context.currentBinding?.providerConversationId ?? claimSession
        let refusal = await ingestion.lastRefusal(paneId: pane)?.reason
        let result = AdapterObservationResult(
            operations: recorder.operations, peers: recorder.peers, session: session, refusal: refusal)
        await ingestion.finish()
        return result
    } catch {
        await ingestion.finish()
        throw error
    }
}
