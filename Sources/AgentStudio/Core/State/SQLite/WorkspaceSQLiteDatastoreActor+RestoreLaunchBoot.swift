import Foundation

extension WorkspaceSQLiteDatastoreActor {
    package func replaceTerminalRestoreLaunchBoot(currentBootId: String, recordedAt: Date) async throws
        -> TerminalRestoreLaunchBoot
    {
        try await preparedApplicationLocalRepository().replaceTerminalRestoreLaunchBoot(
            currentBootId: currentBootId, recordedAt: recordedAt)
    }
}
