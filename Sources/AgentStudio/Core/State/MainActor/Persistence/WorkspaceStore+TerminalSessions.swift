import Foundation

extension WorkspaceStore {
    /// The persistence owner's synchronous mirror; nil remains unknown and grants no plain attach.
    package func cachedTerminalSessionProtocolVersion(_ sessionID: ZmxSessionID) -> UInt8? {
        terminalSessionProtocolVersionsByID[sessionID]
    }

    package func terminalSessionProtocolVersion(_ sessionID: ZmxSessionID) async throws -> UInt8? {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        return try await sqliteDatastore.terminalSessionProtocolVersion(sessionID)
    }

    package func recordTerminalSessionProtocolVersion(_ sessionID: ZmxSessionID, version: UInt8) async throws {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        try await sqliteDatastore.recordTerminalSessionProtocolVersion(sessionID, version: version)
        terminalSessionProtocolVersionsByID[sessionID] = version
    }

    package func stopPendingIncompatibleTerminalSession(
        sessionID: ZmxSessionID, identity: Data?, operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let sqliteDatastore else { throw WorkspaceStoreLoadFailure.missingSQLiteDatastore }
        try await sqliteDatastore.stopPendingIncompatibleTerminalSession(
            sessionID: sessionID, identity: identity, operation: operation)
    }
}
