import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

@MainActor
package struct TerminalRestoreRuntime {
    package struct ZmxAttachDiagnostics: Sendable {
        package let paneId: UUID
        package let sessionId: String
        let zmxDir: String
        let socketPath: String
        package let socketPathLength: Int
        package let maxSocketPathLength: Int
        let zmxPath: String

        package var socketPathHeadroom: Int {
            maxSocketPathLength - socketPathLength
        }
    }

    let sessionConfiguration: SessionConfiguration

    package init(sessionConfiguration: SessionConfiguration) {
        self.sessionConfiguration = sessionConfiguration
    }

    /// Return the exact durable identity stored with the terminal pane.
    /// Restoration never derives, validates against pane shape, or rewrites it.
    func zmxSessionID(for pane: Pane) -> ZmxSessionID? {
        guard pane.provider == .zmx else { return nil }
        return pane.terminalState?.zmxSessionID
    }

    /// The actual startup command for an already-decided restore kind (SR1-
    /// SR3, SR6a; Program Design item 2, choice 1's "`TerminalRestoreRuntime
    /// .startupCommand(for:kind:)` stays pure and synchronous"). Amended
    /// 2026-09-30 ("option A"; Spec SR2a; S4b): every cohort-computed kind —
    /// `.cold`, `.warm`, and `.unverified` alike — sends its plan's
    /// cold-restore script; zmx itself ignores that script when the session
    /// it finds is actually alive, so a correct warm/unverified check
    /// changes nothing observable, and a session that died between the
    /// check and the reconnect is recreated by the script instead of
    /// silently attaching to a blank shell. Only `nil` (no cohort-computed
    /// kind — every call site outside the launch-restore cohort, such as a
    /// steady-state new pane or a mid-session repair) keeps today's plain
    /// attach.
    package func startupCommand(for pane: Pane, kind: TerminalRestoreKind?) -> String? {
        switch kind {
        case .cold(let plan), .warm(_, let plan), .unverified(_, let plan):
            return ZmxBackend.buildColdRestoreCommand(plan)
        case nil:
            return zmxAttachCommand(for: pane)
        }
    }

    package func zmxAttachCommand(for pane: Pane) -> String? {
        guard sessionConfiguration.isOperational else { return nil }
        guard let sessionID = zmxSessionID(for: pane) else { return nil }
        guard let zmxPath = sessionConfiguration.zmxPath else { return nil }
        return ZmxBackend.buildAttachCommand(
            zmxPath: zmxPath,
            sessionID: sessionID,
            shell: SessionConfiguration.defaultShell()
        )
    }

    package func zmxAttachDiagnostics(for pane: Pane) -> ZmxAttachDiagnostics? {
        guard sessionConfiguration.isOperational else { return nil }
        guard let sessionID = zmxSessionID(for: pane) else { return nil }
        guard let zmxPath = sessionConfiguration.zmxPath else { return nil }

        let socketPath = "\(sessionConfiguration.zmxDir)/\(sessionID.rawValue)"
        return ZmxAttachDiagnostics(
            paneId: pane.id,
            sessionId: sessionID.rawValue,
            zmxDir: sessionConfiguration.zmxDir,
            socketPath: socketPath,
            socketPathLength: socketPath.count,
            maxSocketPathLength: 103,
            zmxPath: zmxPath
        )
    }
}
