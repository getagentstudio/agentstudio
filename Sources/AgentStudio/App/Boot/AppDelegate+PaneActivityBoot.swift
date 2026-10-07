import AgentStudioCore
import Foundation

extension AppDelegate {
    func bootRestorePaneActivity() async {
        guard let datastore = workspaceSQLiteDatastore else { return }
        let records = await datastore.loadPaneActivity(workspaceId: store.identityAtom.workspaceId)
        applyRestoredPaneActivity(records, referenceInstant: ContinuousClock.now, wallNow: Date.now)
    }

    func applyRestoredPaneActivity(
        _ records: [PaneActivityRecord],
        referenceInstant: ContinuousClock.Instant,
        wallNow: Date
    ) {
        let activityAtom = atomStore.core.paneActivityTime
        let mutations: [PaneActivityTimeMutation] = records.compactMap { record in
            guard activityAtom.value(for: record.paneId) == nil else { return nil }
            guard let activityTime = record.restoredActivityTime(referenceInstant: referenceInstant, wallNow: wallNow)
            else {
                appLogger.warning("Skipping pane activity with an unrepresentable restore age")
                return nil
            }
            return .set(record.paneId, activityTime)
        }
        activityAtom.apply(mutations)
    }
}
