import GRDB

extension WorkspaceCoreRepository {
    func terminalSessionProtocolVersions() throws -> [ZmxSessionID: UInt8] {
        try databaseWriter.read { database in
            var versions: [ZmxSessionID: UInt8] = [:]
            for row in try Row.fetchAll(
                database,
                sql: """
                    SELECT session_id, zmx_protocol_version FROM workspace_terminal_session_ownership
                    WHERE typeof(session_id) = 'text' AND typeof(zmx_protocol_version) = 'integer'
                    """)
            {
                let storedID: String = row["session_id"]
                let storedVersion: Int? = row["zmx_protocol_version"]
                // NULL, invalid identifiers and invalid byte values grant no attach authority.
                guard let sessionID = ZmxSessionID(restoring: storedID),
                    let storedVersion, let version = UInt8(exactly: storedVersion)
                else { continue }
                versions[sessionID] = version
            }
            return versions
        }
    }

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
