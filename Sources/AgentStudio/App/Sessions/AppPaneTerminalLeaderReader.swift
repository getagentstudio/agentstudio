import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import Foundation

struct AppPaneTerminalLeaderReader: PaneTerminalLeaderReading {
    let datastore: WorkspaceSQLiteDatastoreActor
    private let zmxDirectory: String

    init(datastore: WorkspaceSQLiteDatastoreActor, zmxDirectory: String = AppDataPaths.zmxDirectory().path) {
        self.datastore = datastore
        self.zmxDirectory = zmxDirectory
    }

    func terminalSessionID(for paneId: UUID) async -> ZmxSessionID? {
        try? await datastore.terminalSessionID(for: paneId)
    }

    @concurrent nonisolated func terminalLeader(for sessionID: ZmxSessionID) async -> ZmxProcessIncarnation? {
        guard let time = try? await WorkspaceUndoJournalClock.current() else { return nil }
        return (try? ZmxSessionControl.observe(path: "\(zmxDirectory)/\(sessionID.rawValue)", bootID: time.bootID))?
            .terminalLeader
    }
}
