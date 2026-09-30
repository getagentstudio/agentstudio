import Foundation

/// What a pane-bound agent may do with one method or command, declared once
/// beside its catalog entry. A later layer widens access by changing this
/// value, never by adding a second agent-only surface.
///
/// A method that declares no eligibility keeps its established Agent IPC v2
/// admission (bound-pane baseline privileges) unchanged.
package enum IPCAgentEligibility: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    /// Runs only against targets inside the agent's own pane: its terminal and,
    /// for a main-layout terminal, that pane's drawer children.
    case ownPane
    /// Read-only listing of windows, tabs and panes; no target restriction.
    case anyTarget
    /// Recognized, but refused for pane agents in this layer.
    case notYetAllowed

    /// An agent must reach every eligible method on every channel, so an
    /// eligible entry cannot be debug-only.
    package var requiresAllChannelExposure: Bool {
        switch self {
        case .ownPane, .anyTarget:
            true
        case .notYetAllowed:
            false
        }
    }
}

extension IPCAgentEligibility: IPCSchemaProviding {}
