import AgentStudioCore
import Foundation

/// Sessions reads the persisted association around one off-main leader observation.
package protocol PaneTerminalLeaderReading: Sendable {
    func terminalSessionID(for paneId: UUID) async -> ZmxSessionID?
    func terminalLeader(for sessionID: ZmxSessionID) async -> ZmxProcessIncarnation?
}
