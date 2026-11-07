import GRDB

extension WorkspaceCoreRepository {
    func terminalSessionProtocolVersion(_ sessionID: ZmxSessionID) throws -> UInt8? {
        try databaseWriter.read { database in
            guard
                let value = try Int.fetchOne(
                    database,
                    sql: "SELECT zmx_protocol_version FROM workspace_terminal_session_ownership WHERE session_id = ?",
                    arguments: [sessionID.rawValue]
                )
            else { return nil }
            guard let version = UInt8(exactly: value) else { throw ZmxSessionControlFailure.invalidIdentity }
            return version
        }
    }

    func recordTerminalSessionProtocolVersion(_ sessionID: ZmxSessionID, version: UInt8) throws {
        try databaseWriter.write { database in
            try database.execute(
                sql: """
                    UPDATE workspace_terminal_session_ownership SET zmx_protocol_version = ?
                    WHERE session_id = ? AND cleanup_state IN ('owned', 'pending')
                    """, arguments: [version, sessionID.rawValue])
            guard try Int.fetchOne(database, sql: "SELECT changes()") == 1 else {
                throw ZmxSessionControlFailure.invalidIdentity
            }
        }
    }
}
