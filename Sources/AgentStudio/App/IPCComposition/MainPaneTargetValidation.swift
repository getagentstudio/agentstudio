import AgentStudioAppIPC
import AgentStudioCore
import Foundation

enum MainPaneTargetValidation {
    static func validate(_ paneId: UUID, in snapshot: ProgrammaticControlWorkspaceSnapshot) throws {
        guard let pane = snapshot.panes.first(where: { $0.id == paneId }) else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        guard !pane.isDrawerChild else {
            throw AppIPCLayoutError(reason: .notMainPane)
        }
    }
}
