import Foundation

/// Persisted pane/session identities, including panes retained for undo.
package protocol ScrollbackPaneBindingReading: Sendable {
    func scrollbackPaneBindings(workspaceID: UUID) async throws -> [ScrollbackPaneBinding]
}
