import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import Synchronization
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

extension SessionsProviderTraceIntegrationTests {
    @Test(
        "the real status adapter publishes hook activity only for the unverified main and keeps identity reads unbound")
    func unverifiedAdapterActivityAndRefusal() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        let workspace = UUIDv7.generate()
        let activity = Mutex<[PaneActivityOccurrence]>([])
        let clock = PaneActivityClock(
            submissionObserver: { fact in activity.withLock { $0.append(fact) } }, sink: { _ in })
        do {
            try await fixture.withIngestion(activityClock: clock) { ingestion, adapter in
                func report(_ session: String, _ name: IPCSessionEventName) -> IPCSessionStatusParams {
                    .init(
                        paneClaim: .init(paneId: pane, workspaceId: workspace), tokenOutcome: .rejected,
                        report: .hook(
                            event: .init(
                                name: name, conversationId: session, turnId: nil,
                                requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                            provider: .init(identifier: "codex", version: "0.160.0", mode: "cli"),
                            providerSessionId: session),
                        correlationId: UUIDv7.generate())
                }
                _ = try await adapter.recordUnverifiedStatus(
                    paneId: pane, params: report("main", .turnStart), revalidateClaim: {})
                _ = try await adapter.recordUnverifiedStatus(
                    paneId: pane, params: report("child", .turnDone), revalidateClaim: {})
                #expect(activity.withLock { $0.count } == 1)
                #expect(activity.withLock { $0.first?.paneId } == pane)
                #expect(activity.withLock { $0.first?.source } == .hook)
                _ = try await adapter.recordUnverifiedStatus(
                    paneId: pane, params: report("main", .permission), revalidateClaim: {})
                #expect(activity.withLock { $0.count } == 2)
                let read = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
                #expect(read.sourceHealth == .unbound)
                #expect(read.session == nil)
                #expect(read.lastRefusal?.reason == .credentialNotRecognized)
                #expect(read.lastRefusal?.intent == .status)
                #expect(
                    ingestion.statusPublicationMailbox.takeBatch()[.init(existingUUID: pane)]
                        == .set(.init(status: .needsYou(.approval), connectionIssue: .credentialNotRecognized)))
                let context = try await ingestion.repository.statusContext(paneId: pane)
                #expect(context.bindings.isEmpty)
                #expect(context.evidence.isEmpty)
                for reason in [IPCAgentConnectionRefusalReason.noSessionId, .undecodablePayload] {
                    _ = try await adapter.recordUnverifiedStatus(
                        paneId: pane,
                        params: .init(
                            paneClaim: .init(paneId: pane, workspaceId: workspace), tokenOutcome: .rejected,
                            report: .refusal(reason: reason), correlationId: UUIDv7.generate()), revalidateClaim: {})
                    let state = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
                    #expect(state.lastRefusal?.reason == reason)
                    #expect(
                        ingestion.statusPublicationMailbox.takeBatch()[.init(existingUUID: pane)]
                            == .set(
                                .init(
                                    status: .needsYou(.approval),
                                    connectionIssue: AgentStudioIPCSessionsAdapter.domainRefusal(reason))))
                }
                #expect(activity.withLock { $0.count } == 2)
            }
            await clock.shutdown()
        } catch {
            await clock.shutdown()
            throw error
        }
    }
}
