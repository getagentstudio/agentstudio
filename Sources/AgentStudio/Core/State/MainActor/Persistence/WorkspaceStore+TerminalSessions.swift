extension WorkspaceStore {
    /// The persistence owner's synchronous mirror; nil remains unknown and grants no plain attach.
    package func cachedTerminalSessionProtocolVersion(_ sessionID: ZmxSessionID) -> UInt8? {
        terminalSessionProtocolVersionsByID[sessionID]
    }
}
