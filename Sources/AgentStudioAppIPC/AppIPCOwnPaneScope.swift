import AgentStudioProgrammaticControl
import Foundation

/// A pane-bound agent's own pane as the pane graph states it at one instant:
/// its bound terminal and, for a main-layout terminal, that pane's drawer
/// children.
package struct AppIPCOwnPaneScope: Equatable, Sendable {
    package let boundPaneId: UUID
    /// A drawer terminal owns only itself: drawers do not nest, and its owning
    /// pane and sibling drawer children are outside its own pane.
    package let isDrawerTerminal: Bool
    package let drawerChildPaneIds: Set<UUID>

    package init(boundPaneId: UUID, isDrawerTerminal: Bool, drawerChildPaneIds: Set<UUID>) {
        self.boundPaneId = boundPaneId
        self.isDrawerTerminal = isDrawerTerminal
        self.drawerChildPaneIds = isDrawerTerminal ? [] : drawerChildPaneIds
    }

    package func membership(of paneId: UUID) -> AppIPCOwnPaneMembership {
        if paneId == boundPaneId { return .boundPane }
        if drawerChildPaneIds.contains(paneId) { return .ownDrawerChild }
        return .outside
    }
}

package enum AppIPCOwnPaneMembership: Equatable, Sendable {
    case boundPane
    case ownDrawerChild
    case outside
}

/// Answers "what is agent pane P's own pane now?" from the App's pane graph.
/// One bounded main-actor lookup per request; no disk or network access.
@MainActor
package protocol AppIPCOwnPaneScopePort: Sendable {
    /// `nil` when the bound pane no longer exists, so a principal that outlived
    /// its pane owns nothing.
    func ownPaneScope(boundPaneId: UUID) -> AppIPCOwnPaneScope?
}

/// An argument whose effect decides agent admission beyond target identity.
/// Registrations name the rule; pane-agent authorization evaluates it after
/// eligibility and own-pane membership.
package enum AppIPCAgentArgumentRule: Equatable, Sendable {
    /// Admission depends on the target identities alone.
    case targetOnly
    /// Closes this pane. An agent never closes its own pane.
    case closesPane(UUID)
    /// Adds a drawer child under this parent. Only an agent in a main-layout
    /// terminal may add, only to its own drawer, and only a terminal or a
    /// browser with an http or https URL.
    case addsDrawerChild(parentPaneId: UUID, content: IPCDrawerChildContent)
}

/// The pane agent an effect was authorized for, handed to the port that
/// applies it so the owner can re-check own-pane membership at effect time.
/// Absent for every other principal, whose admission never depended on it.
public struct AppIPCOwnPaneAssertion: Equatable, Sendable {
    public let boundPaneId: UUID

    public init(boundPaneId: UUID) {
        self.boundPaneId = boundPaneId
    }

    package init?(principal: IPCPrincipal?) {
        guard case .spawnedPaneAgent(let rawBoundPaneId, _)? = principal?.kind,
            let boundPaneId = UUID(uuidString: rawBoundPaneId)
        else { return nil }
        self.init(boundPaneId: boundPaneId)
    }
}
