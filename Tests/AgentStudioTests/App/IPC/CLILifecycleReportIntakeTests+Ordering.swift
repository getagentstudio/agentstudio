import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore
@testable import AgentStudioSessions

extension CLILifecycleReportIntakeTests {
    @Test("whole-read times prevail over commit order", arguments: [false, true])
    func sameReadStartCancelsOlderEnd(reverseCommit: Bool) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.seedUnconfirmedLifecycleMain(pane: pane, session: session)
            let original = try await harness.lifecycleContext(pane: pane).currentBinding?.bindingGenerationId
            if reverseCommit {
                try await harness.appendLifecycle(pane: pane, session: session, event: .sessionStart, at: 3.0006)
                try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
            } else {
                try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
                try await harness.appendLifecycle(pane: pane, session: session, event: .sessionStart, at: 3.0006)
            }
            _ = await harness.drain()
            #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .active)
            #expect(try await harness.restartedDrain().readOutcome != .unreadable(.localDatabase))
            #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .active)
            try await assertReloadedLifecycleQuery(harness, pane: pane, health: .live)
            #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.bindingGenerationId == original)
            let liveSession = UUIDv7.generate().uuidString
            _ = try await harness.ingestion.submitHook(
                .init(
                    paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: liveSession,
                    eventName: .turnStart, turnId: "new-live-turn", signal: .turnStart,
                    recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 4),
                    chain: TestMainAgentChain.observation))
            #expect(
                try await harness.lifecycleContext(pane: pane).currentBinding?.providerConversationId == liveSession)
            try await assertReloadedLifecycleQuery(harness, pane: pane, health: .live)

        }
    }

    @Test(
        "a handled start's fact survives cursor advance, restart and purge", arguments: [false, true], [false, true])
    func previousReadStartVetoesDelayedEnd(purge: Bool, holdNotice: Bool) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            let start = try await harness.appendLifecycle(
                pane: pane, session: session, event: .sessionStart, at: 3.0006)
            _ = await harness.drain()
            #expect(try await harness.cursor() == start.id)
            if purge {
                let writer = harness.writer
                try await valueFromDedicatedThread {
                    _ = try writer.purgeHandledOutbox(
                        expectedStoreID: writer.identity.storeID, through: start.id,
                        now: Date(timeIntervalSince1970: 200_000)
                    ).get()
                }
            }
            if holdNotice {
                _ = try await harness.append(paneID: pane, line: harness.messageLine(text: "held notice"))
                await harness.sqliteAccess.setRejectsWrites(true)
                guard case .incomplete = await harness.drain().readOutcome else {
                    Issue.record("Retryable notice did not hold the prefix")
                    await harness.sqliteAccess.setRejectsWrites(false)
                    return
                }
                #expect(try await harness.cursor() == start.id)
            }
            let end = try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
            await harness.sqliteAccess.setRejectsWrites(false)
            _ = try await harness.restartedDrain()
            #expect(try await harness.cursor() == end.id)
            let context = try await harness.lifecycleContext(pane: pane)
            #expect(context.currentBinding?.status == .active)
            guard case .sessionLifecycle(let startRow) = start else {
                Issue.record("Missing start row")
                return
            }
            let fact = try #require(context.evidence.first { $0.recordId == startRow.messageID })
            #expect(fact.kind == .activityStarted)
            #expect(fact.providerSignal == .sessionStart)
            #expect(fact.statusEffect == .recordedOnly)
            #expect(fact.occurredAt == Date(timeIntervalSince1970: 3))
            try await assertReloadedLifecycleQuery(harness, pane: pane, health: .live)
        }
    }

    @Test("distinct sub-millisecond reports tie only after both real codecs floor")
    func liveStartAndDelayedEndInSameMillisecond() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            try await harness.bindLifecycleMain(pane: pane, session: session, at: 2.0008)
            let row = try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
            guard case .sessionLifecycle(let end) = row else {
                Issue.record("Missing end")
                return
            }
            #expect(end.reportedAt == Date(timeIntervalSince1970: 2))
            _ = await harness.drain()
            let context = try await harness.lifecycleContext(pane: pane)
            #expect(context.currentBinding?.status == .active)
            #expect(context.evidence.contains { $0.occurredAt == Date(timeIntervalSince1970: 2.0008) })
        }
    }

    @Test("SR13a: a later stored start cannot reopen the main; a live start does")
    func acceptedWarmStatusRace() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            let original = try await harness.lifecycleContext(pane: pane).currentBinding?.bindingGenerationId
            try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
            _ = await harness.drain()
            await harness.publishLifecycleStatus()
            #expect(harness.statusAtom.value(for: PaneId(existingUUID: pane))?.status == .idle(.ended))
            try await harness.appendLifecycle(pane: pane, session: session, event: .sessionStart, at: 3.0006)
            _ = try await harness.restartedDrain()
            #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .ended)
            try await assertReloadedLifecycleQuery(harness, pane: pane, health: .ended)
            try await harness.bindLifecycleMain(pane: pane, session: session, at: 4)
            let context = try await harness.lifecycleContext(pane: pane)
            #expect(context.bindings.count == 1)
            #expect(context.currentBinding?.bindingGenerationId == original)
            #expect(context.currentBinding?.status == .active)
        }
    }
}

@MainActor
func assertReloadedLifecycleQuery(
    _ harness: PaneCLIOutboxDrainHarness, pane: UUID, health: IPCSessionSourceHealth
) async throws {
    let ingestion = SessionsIngestion(
        repository: harness.repository, limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128),
        probe: { _ in }, terminalLeaderReader: MatchingTestPaneTerminalLeaderReader())
    do {
        let adapter = AgentStudioIPCSessionsAdapter(
            ingestion: ingestion, processChainReader: EligibleTestProcessChainReader())
        let query = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
        #expect(query.sourceHealth == health)
        await ingestion.finish()
    } catch {
        await ingestion.finish()
        throw error
    }
}
