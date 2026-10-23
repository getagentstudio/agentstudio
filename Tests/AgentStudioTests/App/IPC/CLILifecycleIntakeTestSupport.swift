import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore
@testable import AgentStudioSessions

@MainActor
extension PaneCLIOutboxDrainHarness {
    func drainForLaunch(
        readiness: RestoreResumeReadiness<TestPushClock>, clock: TestPushClock,
        reportSink: (@Sendable (PaneCLIOutboxDrain.DrainReport) -> Void)? = nil
    ) async {
        await drainOwner.drainForLaunch(storeURL: storeURL, readiness: readiness, clock: clock, reportSink: reportSink)
    }

    func seedUnconfirmedLifecycleMain(pane: UUID, session: String, at: TimeInterval = 1) async throws {
        membership.addPane(PaneId(existingUUID: pane))
        _ = try await repository.applyHook(
            .init(
                paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: session,
                eventName: .sessionStart, turnId: nil, signal: .sessionStart, recordId: UUIDv7.generate(),
                admittedAt: Date(timeIntervalSince1970: at)))
    }

    func bindLifecycleMain(pane: UUID, session: String, at: TimeInterval = 1) async throws {
        membership.addPane(PaneId(existingUUID: pane))
        _ = try await ingestion.submitHook(
            .init(
                paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: session,
                eventName: .sessionStart, turnId: nil, signal: .sessionStart,
                recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: at)))
    }

    @discardableResult
    func appendLifecycle(
        pane: UUID, session: String, event: IPCSessionEventName, at: TimeInterval, provider: String = "codex"
    ) async throws -> CLIOutboxEntry {
        let params = lifecycleIntakeParams(pane: pane, session: session, event: event, provider: provider)
        let payload = try #require(String(data: JSONEncoder().encode(params), encoding: .utf8))
        let writer = writer
        return try await valueFromDedicatedThread {
            try writer.appendSessionLifecycle(
                paneID: pane, messageID: UUIDv7.generate(), payloadJSON: payload,
                reportedAt: Date(timeIntervalSince1970: at)
            ).get()
        }
    }

    func publishLifecycleStatus() async {
        await ingestion.statusPublicationLane?.publishPending()
    }

    func lifecycleContext(pane: UUID) async throws -> SessionsRepositoryContext {
        try await repository.statusContext(paneId: pane)
    }

    func drainWithRestoreFailure(afterEvidence: Bool) async throws -> PaneCLIOutboxDrain.DrainReport {
        let membership = membership
        let drain = try PaneCLIOutboxDrain(
            admission: admission, sqliteAccess: sqliteAccess, expectedChannel: .debug,
            ingestion: ingestion,
            restoreEvidence: FailingLifecycleRestoreParticipant(base: restoreEvidence, afterEvidence: afterEvidence),
            paneExists: { membership.sources(for: PaneId(existingUUID: $0)) != nil })
        return await drain.drain(storeURL: storeURL, legacySpoolDirectory: legacyDirectory)
    }
}

struct FailingLifecycleRestoreParticipant: AgentStudioSessions.ClosedAppRestoreEvidenceParticipant {
    let base: AgentStudio.ClosedAppRestoreEvidenceParticipant
    let afterEvidence: Bool

    func commit(in database: Database, item: ClosedAppOutboxItem, latestBindings: SessionsLatestBindings) throws {
        if afterEvidence { try base.commit(in: database, item: item, latestBindings: latestBindings) }
        throw OutboxStorageFailure()
    }
}
