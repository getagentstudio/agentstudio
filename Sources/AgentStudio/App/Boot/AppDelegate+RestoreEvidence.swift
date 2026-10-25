import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTerminal
import Foundation

extension AppDelegate {
    /// Replay waits for optional report schema preparation, independent of process observation.
    func replayBootRestoreRetirements() {
        workspaceSurfaceCoordinator.markRestoreEvidenceRetirementReady()
    }

    func installRestoreEvidenceOwners(datastore: WorkspaceSQLiteDatastoreActor) async {
        let repository =
            restoreReportEvidenceRepository
            ?? SQLitePaneForegroundEvidenceRepository(
                access: WorkspaceForegroundEvidenceSQLiteAccess(datastore: datastore),
                observerLaunchId: UUIDv7.generate())
        restoreReportEvidenceRepository = repository
        workspaceSurfaceCoordinator.restorePaneRetirementSink = { [weak self] paneId in
            try? await repository.retire(paneId: paneId)
            await self?.retireColdResumePane(paneId)
        }
    }

    func shutdownRestoreEvidenceOwners() async {
        await restoreResumeReadiness.shutdown()
        restoreReportEvidenceRepository = nil
    }
}
