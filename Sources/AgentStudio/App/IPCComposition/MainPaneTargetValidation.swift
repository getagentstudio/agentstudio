import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioProgrammaticControl
import Foundation

enum MainPaneTargetValidation {
    static func resolve(_ rawHandle: String, in snapshot: ProgrammaticControlWorkspaceSnapshot) throws -> UUID {
        let handle = try IPCHandle.parse(rawHandle)
        guard handle.kind == .pane else { throw AppIPCLayoutError(reason: .validationRejected) }
        let paneId: UUID
        switch handle.reference {
        case .canonicalUUID(let identifier): paneId = identifier
        case .friendlyOrdinal(let ordinal):
            guard snapshot.panes.indices.contains(ordinal - 1) else { throw AppIPCLayoutError(reason: .targetNotFound) }
            paneId = snapshot.panes[ordinal - 1].id
        }
        try validate(paneId, in: snapshot)
        return paneId
    }

    static func validate(_ paneId: UUID, in snapshot: ProgrammaticControlWorkspaceSnapshot) throws {
        guard let pane = snapshot.panes.first(where: { $0.id == paneId }) else {
            throw AppIPCLayoutError(reason: .targetNotFound)
        }
        guard !pane.isDrawerChild else {
            throw AppIPCLayoutError(reason: .notMainPane)
        }
    }
}
