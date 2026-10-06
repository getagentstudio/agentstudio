import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension AgentStudioIPCSessionsVerticalTests {
    @Test("the real commandFinished bus fact forwards into Sessions FIFO and late SessionEnd stays recorded-only")
    func terminalCommandFinishedEndsMainSession() async throws {
        let harness = try await SessionsVerticalHarness.make()
        let database = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: database.root) }
        let paneId = harness.boundPaneId
        let boundAt = ContinuousClock.now
        let bus = harness.commandHarness.coordinator.paneEventBus
        let ended = FactRecorder<UUID, UUID>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { "ended binding \($0)" }, isClosing: { _, _ in false })
        )
        do {
            let expected = try await database.withIngestion(
                continuousNow: { boundAt },
                sessionEnded: { generation in ended.append(scope: paneId, fact: generation) },
                operation: { ingestion, adapter in
                    let pane = paneId
                    await MainActor.run { harness.commandHarness.coordinator.sessionsIngestion = ingestion }
                    let parameters = IPCSessionEventParams(
                        handle: pane.uuidString, provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
                        event: .init(
                            name: .toolActivity, conversationId: "main", turnId: "turn", requestId: nil,
                            toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                        correlationId: UUIDv7.generate())
                    _ = try await adapter.recordProviderEvent(
                        paneId: pane, params: parameters, provenance: .matchingPane)
                    let before = try #require(try await ingestion.sessionSummary(paneId: pane))
                    _ = await bus.post(
                        commandFinishedEnvelope(paneId: pane, timestamp: boundAt.advanced(by: .seconds(1))))
                    try await ended.expectNext(in: pane, before.bindingGeneration)
                    let finished = try #require(try await ingestion.sessionSummary(paneId: pane))
                    #expect(finished.status == .idle(.ended))
                    let late = IPCSessionEventParams(
                        handle: pane.uuidString, provider: parameters.provider,
                        event: .init(
                            name: .sessionEnd, conversationId: "main", turnId: nil, requestId: nil,
                            toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                        correlationId: UUIDv7.generate())
                    _ = try await adapter.recordProviderEvent(paneId: pane, params: late, provenance: .matchingPane)
                    let context = try await ingestion.repository.statusContext(paneId: pane)
                    #expect(context.evidence.last?.statusEffect == .recordedOnly)
                    #expect(try await ingestion.sessionSummary(paneId: pane) == finished)
                    await MainActor.run { harness.commandHarness.coordinator.sessionsIngestion = nil }
                    return finished
                })
            try await database.withIngestion { ingestion, _ in
                let summary = try await ingestion.sessionSummary(paneId: paneId)
                #expect(summary == expected)
            }
            await harness.tearDown()
            try await ended.finish()
        } catch {
            harness.commandHarness.coordinator.sessionsIngestion = nil
            await harness.tearDown()
            try? await ended.finish()
            throw error
        }
    }
    @Test("a held commandFinished delivery through the coordinator cannot end a newer pane main")
    func heldCoordinatorExitKeepsNewMain() async throws {
        let harness = try await SessionsVerticalHarness.make()
        let database = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: database.root) }
        let pane = harness.boundPaneId
        let bus = harness.commandHarness.coordinator.paneEventBus
        let origin = ContinuousClock.now
        let time = Mutex(origin)
        let held = HeldStep<Void>("old commandFinished before coordinator bus delivery")
        do {
            let expected = try await database.withIngestion(
                continuousNow: { time.withLock { $0 } },
                operation: { ingestion, adapter in
                    await MainActor.run { harness.commandHarness.coordinator.sessionsIngestion = ingestion }
                    try await coordinatorExitHook(adapter, pane: pane, session: "A", event: .toolActivity)
                    let delivery = Task {
                        try await held.arrive(())
                        _ = await bus.post(
                            commandFinishedEnvelope(
                                paneId: pane, timestamp: origin.advanced(by: .milliseconds(100))))
                    }
                    do {
                        try await held.firstArrival()
                        time.withLock { $0 = origin.advanced(by: .milliseconds(200)) }
                        try await coordinatorExitHook(adapter, pane: pane, session: "A", event: .sessionEnd)
                        time.withLock { $0 = origin.advanced(by: .milliseconds(300)) }
                        try await coordinatorExitHook(adapter, pane: pane, session: "B", event: .toolActivity)
                        let before = try await ingestion.sessionSummary(paneId: pane)
                        held.release()
                        try await delivery.value
                        await coordinatorExitBarrier(bus: bus, pane: pane)
                        #expect(try await ingestion.sessionSummary(paneId: pane) == before)
                        try await coordinatorExitHook(adapter, pane: pane, session: "A", event: .sessionEnd)
                        #expect(try await ingestion.sessionSummary(paneId: pane) == before)
                        #expect(
                            try await ingestion.repository.statusContext(paneId: pane).evidence.last?.statusEffect
                                == .recordedOnly)
                        await MainActor.run { harness.commandHarness.coordinator.sessionsIngestion = nil }
                        return before
                    } catch {
                        held.retire()
                        _ = try? await delivery.value
                        throw error
                    }
                })
            try await database.withIngestion { ingestion, _ in
                let summary = try await ingestion.sessionSummary(paneId: pane)
                #expect(summary == expected)
            }
            await harness.tearDown()
        } catch {
            harness.commandHarness.coordinator.sessionsIngestion = nil
            await harness.tearDown()
            throw error
        }
    }

}

private func commandFinishedEnvelope(paneId: UUID, timestamp: ContinuousClock.Instant) -> RuntimeEnvelope {
    let envelope = RuntimeEnvelopeHarness.paneEnvelope(
        event: .terminal(.commandFinished(exitCode: 0, duration: 42)),
        paneId: .init(existingUUID: paneId), eventId: UUIDv7.generate())
    guard case .pane(let pane) = envelope else { return envelope }
    return .pane(
        .init(
            eventId: pane.eventId, source: pane.source, seq: pane.seq, timestamp: timestamp,
            paneId: pane.paneId, paneKind: pane.paneKind, event: pane.event))
}

@MainActor
private func coordinatorExitBarrier(bus: EventBus<RuntimeEnvelope>, pane: UUID) async {
    let stream = await AppEventBus.shared.subscribe(
        policy: .criticalUnbounded, subscriberName: "CommandFinished.coordinatorBarrier")
    let waiter = Task { @MainActor in
        for await event in stream {
            if case .worktreeBellRang(let observed) = event, observed == pane { return true }
        }
        return false
    }
    _ = await bus.post(
        .pane(
            .init(
                source: .pane(.init(existingUUID: pane)), seq: 2, timestamp: ContinuousClock.now,
                paneId: .init(existingUUID: pane), paneKind: .terminal, event: .terminal(.bellRang))))
    #expect(await waiter.value)
}

private func coordinatorExitHook(
    _ adapter: AgentStudioIPCSessionsAdapter, pane: UUID, session: String, event: IPCSessionEventName
) async throws {
    _ = try await adapter.recordProviderEvent(
        paneId: pane,
        params: .init(
            handle: pane.uuidString, provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
            event: .init(
                name: event, conversationId: session, turnId: "turn", requestId: nil, toolId: nil,
                subagentId: nil, occurrenceId: UUIDv7.generate()), correlationId: UUIDv7.generate()),
        provenance: .matchingPane)
}
