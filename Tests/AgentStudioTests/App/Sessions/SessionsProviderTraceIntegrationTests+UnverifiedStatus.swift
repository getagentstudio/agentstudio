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
                let statusMailbox = await ingestion.statusPublicationMailbox
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
                    statusMailbox.takeBatch()[.init(existingUUID: pane)]
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
                        statusMailbox.takeBatch()[.init(existingUUID: pane)]
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

    @Test("a bound pane's unverified hook records E7 but changes neither status nor activity")
    func boundUnverifiedHookRecordsRefusalWithoutActivity() async throws {
        let fixture = try RecordedStatusDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pane = UUIDv7.generate()
        let activity = Mutex<[PaneActivityOccurrence]>([])
        let clock = PaneActivityClock(
            submissionObserver: { occurrence in activity.withLock { $0.append(occurrence) } }, sink: { _ in })
        do {
            try await fixture.withIngestion(activityClock: clock) { ingestion, adapter in
                let provider = IPCSessionProviderIdentity(identifier: "codex", version: "0.160.0", mode: "cli")
                _ = try await adapter.recordProviderEvent(
                    paneId: pane,
                    params: .init(
                        handle: "self", provider: provider,
                        event: .init(
                            name: .turnStart, conversationId: "verified", turnId: nil,
                            requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                        correlationId: UUIDv7.generate()), provenance: .matchingPane)
                let statusMailbox = await ingestion.statusPublicationMailbox
                #expect(statusMailbox.takeBatch()[.init(existingUUID: pane)] == .set(.init(status: .working(.active))))
                let before = activity.withLock { $0.count }
                let reply = try await adapter.recordUnverifiedStatus(
                    paneId: pane,
                    params: .init(
                        paneClaim: .init(paneId: pane, workspaceId: UUIDv7.generate()), tokenOutcome: .rejected,
                        report: .hook(
                            event: .init(
                                name: .permission, conversationId: "unverified", turnId: nil,
                                requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
                            provider: provider, providerSessionId: "unverified"),
                        correlationId: UUIDv7.generate()), revalidateClaim: {})
                #expect(reply.disposition == .admitted)
                #expect(activity.withLock { $0.count } == before)
                let state = try await adapter.readSessionState(paneId: pane, params: .init(handle: "self"))
                #expect(state.lastRefusal?.reason == .credentialNotRecognized)
                #expect(state.lastRefusal?.count == 1)
                #expect(try await ingestion.sessionSummary(paneId: pane)?.status == .working(.active))
                #expect(statusMailbox.takeBatch().isEmpty)
                #expect(await ingestion.unverifiedStatusRuntime.panes[pane] == nil)
            }
            await clock.shutdown()
        } catch {
            await clock.shutdown()
            throw error
        }
    }

    @Test("Sessions capacity errors map to the documented queueFull wire reason")
    func capacityPortErrorPreservesQueueFull() {
        for error in [SessionsRepositoryError.paneQueueFull(UUIDv7.generate()), .globalQueueFull] {
            let mapped = AgentStudioIPCSessionsAdapter.portError(from: error)
            #expect((mapped as? AppIPCSessionsError)?.reason.rawValue == "queueFull")
            let wire = AgentStudioAppIPCRequestError(mapped)
            #expect(wire.code == -32_005)
            #expect(wire.data == .object(["reason": .string("queueFull")]))
        }
        #expect(
            (AgentStudioIPCSessionsAdapter.portError(from: SessionsRepositoryError.ingestionFinished)
                as? AppIPCSessionsError)?.reason == .ingestionUnavailable)
    }
}
