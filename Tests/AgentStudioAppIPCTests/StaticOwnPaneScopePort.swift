import AgentStudioAppIPC
import Foundation

/// Answers own-pane questions from a fixed table, standing in for the App's
/// pane graph where a test proves admission rather than App wiring. A bound
/// pane missing from the table is a main-layout terminal with an empty drawer,
/// unless the port models vanished panes.
struct StaticOwnPaneScopePort: AppIPCOwnPaneScopePort {
    let scopesByBoundPaneId: [UUID: AppIPCOwnPaneScope]
    let unlistedPanesExist: Bool

    nonisolated init(scopes: [AppIPCOwnPaneScope] = [], unlistedPanesExist: Bool = true) {
        scopesByBoundPaneId = Dictionary(uniqueKeysWithValues: scopes.map { ($0.boundPaneId, $0) })
        self.unlistedPanesExist = unlistedPanesExist
    }

    func ownPaneScope(boundPaneId: UUID) -> AppIPCOwnPaneScope? {
        if let scope = scopesByBoundPaneId[boundPaneId] { return scope }
        guard unlistedPanesExist else { return nil }
        return AppIPCOwnPaneScope(boundPaneId: boundPaneId, isDrawerTerminal: false, drawerChildPaneIds: [])
    }
}
