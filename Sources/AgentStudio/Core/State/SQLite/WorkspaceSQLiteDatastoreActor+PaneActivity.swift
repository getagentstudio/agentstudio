import Foundation
import OSLog

private let paneActivityDatastoreLogger = Logger(subsystem: "com.agentstudio", category: "PaneActivityDatastore")

extension WorkspaceSQLiteDatastoreActor {
    package func loadPaneActivity(workspaceId: UUID) -> [PaneActivityRecord] {
        do {
            let repository = try preparedApplicationLocalRepository()
            let coreRepository = try journalRepository()
            // A failed membership read must never turn into an empty retain set.
            do {
                let retainedIDs = try coreRepository.fetchRetainedPaneActivityPaneIDs()
                try repository.prunePaneActivity(retaining: retainedIDs)
            } catch {
                paneActivityDatastoreLogger.warning(
                    "Pane activity prune skipped: \(String(describing: error), privacy: .private)")
            }
            let workspacePaneIDs = try coreRepository.fetchRetainedPaneActivityPaneIDs(workspaceID: workspaceId)
            return try repository.fetchPaneActivity().filter { workspacePaneIDs.contains($0.paneId) }
        } catch {
            paneActivityDatastoreLogger.warning(
                "Pane activity load failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    package func commitPaneActivity(_ commit: PaneActivityCommit) throws {
        try preparedApplicationLocalRepository().commitPaneActivity(commit)
    }
}
