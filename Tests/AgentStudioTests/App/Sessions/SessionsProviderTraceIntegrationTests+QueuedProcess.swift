import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionsProviderTraceIntegrationTests {
    @Test("a peer that exits while queued cannot reuse admission-time ancestry", arguments: [false, true])
    func queuedPeerRequiresCurrentEvidence(unverified: Bool) async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = CountingElectionProcessReader()
        let pane = UUIDv7.generate()
        let endScope = UUIDv7.generate()
        let candidateScope = UUIDv7.generate()
        let held = HeldStep<Void>("SessionEnd callback before the next election")
        let facts = LocalFactSource<UUID, QueuedProcessFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .ended }))
        let recorder = try facts.attach()
        let onSessionEnded: @Sendable (UUID) async -> Void = { _ in
            facts.sink(endScope, .held)
            _ = try? await held.arrive(())
        }
        let observeQueue: SessionsIngestionProbe = { statistic in
            if statistic.event == .depthChanged, statistic.pendingGlobal == 2 {
                facts.sink(candidateScope, .queued)
            }
        }
        do {
            try await fixture.withIngestion(
                sessionEnded: onSessionEnded, processChainReader: reader, probe: observeQueue,
                operation: { ingestion, adapter in
                    try await sendElectionHook(adapter, pane: pane, name: .turnStart, peerPID: 100, unverified: false)
                    let ending = Task {
                        defer { facts.sink(endScope, .ended) }
                        try await sendElectionHook(
                            adapter, pane: pane, name: .sessionEnd, peerPID: 101, unverified: false)
                    }
                    var candidate: Task<Void, any Error>?
                    do {
                        try await recorder.expectNext(in: endScope, .held)
                        candidate = Task {
                            defer { facts.sink(candidateScope, .ended) }
                            try await sendElectionHook(
                                adapter, pane: pane, name: .turnStart, peerPID: 102, unverified: unverified,
                                conversation: "next")
                        }
                        try await recorder.expectNext(in: candidateScope, .queued)
                        #expect(reader.peers == [100])
                        reader.setObservation(.unknown(.peerUnbound))
                        held.release()
                        try await ending.value
                        try await candidate?.value
                        #expect(reader.peers == [100, 102])
                        let beforeRetry = try await ingestion.repository.statusContext(paneId: pane)
                        #expect(beforeRetry.currentBinding?.status == .ended)
                        #expect(beforeRetry.evidence.count == 2)
                        #expect(await ingestion.unverifiedStatusRuntime.panes[pane]?.main == nil)
                        reader.setObservation(
                            .agentShell(
                                shell: .init(pid: 999, startSeconds: 200, startMicroseconds: 0),
                                shellParent: .multiplexerServer(.herdr)))
                        try await sendElectionHook(
                            adapter, pane: pane, name: .turnStart, peerPID: 103, unverified: unverified,
                            conversation: "next")
                        #expect(reader.peers == [100, 102, 103])
                        if unverified {
                            #expect(await ingestion.unverifiedStatusRuntime.panes[pane]?.main?.sessionId == "next")
                        } else {
                            #expect(
                                try await ingestion.repository.statusContext(paneId: pane).currentBinding?
                                    .providerConversationId == "next")
                        }
                    } catch {
                        held.retire()
                        _ = try? await ending.value
                        _ = try? await candidate?.value
                        throw error
                    }
                })
            facts.end()
            try await recorder.finish()
        } catch {
            held.retire()
            facts.end()
            try? await recorder.finish()
            throw error
        }
    }
}

private enum QueuedProcessFact: Sendable, Equatable { case held, queued, ended }
