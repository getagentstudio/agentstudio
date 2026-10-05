import AgentStudioProgrammaticControl

/// App owns the readonly CLI file and application-local cursor query.
package protocol AppIPCCLIStoreReadThroughPort: Sendable {
    func readThrough() async -> IPCCLIStoreReadThrough?
}
