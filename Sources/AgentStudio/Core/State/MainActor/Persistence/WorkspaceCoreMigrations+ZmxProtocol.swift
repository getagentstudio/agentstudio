extension WorkspaceCoreMigrations {
    static let trackZmxProtocolVersionStatements = [
        "ALTER TABLE workspace_terminal_session_ownership ADD COLUMN zmx_protocol_version INTEGER"
    ]
}
