import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension CLILifecycleReportIntakeTests {
    @Test(
        "an own stored start leaves working, needs-you and ended status unchanged",
        arguments: ["working", "needsYou", "ended"])
    func ownStartDoesNotChangeStatus(state: String) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            let signal: SessionProviderSignal
            let kind: SessionsEvidenceKind
            let expected: AgentSessionStatus
            switch state {
            case "working":
                signal = .turnStart
                kind = .activityStarted
                expected = .working(.active)
            case "needsYou":
                signal = .permission(toolName: "shell", questions: nil)
                kind = .needsYouOpened
                expected = .needsYou(.approval)
            default:
                signal = .sessionEnd
                kind = .completed
                expected = .idle(.ended)
            }
            _ = try await harness.ingestion.submitHook(
                .init(
                    paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: session,
                    eventName: signal.name, turnId: "turn", kind: kind, signal: signal, recordId: UUIDv7.generate(),
                    admittedAt: Date(timeIntervalSince1970: 2)))
            #expect(try await harness.ingestion.sessionSummary(paneId: pane)?.status == expected)
            try await harness.appendLifecycle(pane: pane, session: session, event: .sessionStart, at: 3.0006)
            _ = await harness.drain()
            await harness.publishLifecycleStatus()
            #expect(harness.statusAtom.value(for: PaneId(existingUUID: pane))?.status == expected)
            let reloaded = SessionsIngestion(
                repository: harness.repository,
                limits: .init(maximumPendingPerPane: 32, maximumPendingGlobal: 128), probe: { _ in })
            do {
                #expect(try await reloaded.sessionSummary(paneId: pane)?.status == expected)
                let query = try await AgentStudioIPCSessionsAdapter(ingestion: reloaded).readSessionState(
                    paneId: pane, params: .init(handle: "self"))
                #expect(query.sourceHealth == (state == "ended" ? .ended : .live))
                await reloaded.finish()
            } catch {
                await reloaded.finish()
                throw error
            }
        }
    }
}
