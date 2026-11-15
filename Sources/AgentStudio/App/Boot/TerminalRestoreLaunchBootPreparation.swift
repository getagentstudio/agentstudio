import AgentStudioCore
import Foundation

/// Called during boot database preparation, before any mount can create zmx.
struct TerminalRestoreLaunchBootPreparation {
    @concurrent nonisolated static func prepare(
        datastore: WorkspaceSQLiteDatastoreActor,
        bootId: @Sendable () async throws -> String = { try await WorkspaceUndoJournalClock.current().bootID }
    ) async throws -> TerminalRestoreLaunchBoot {
        let current = try await bootId()
        return try await datastore.replaceTerminalRestoreLaunchBoot(currentBootId: current, recordedAt: Date())
    }
}
