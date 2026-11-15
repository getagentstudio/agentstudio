import Foundation

protocol AgentStudioTraceSink: Sendable {
    func record(_ record: AgentStudioTraceRecord) async throws
    func flush() async throws
    func shutdown() async throws
    func diagnostics() async -> AgentStudioTraceWriterDiagnostics
}

struct AgentStudioJSONLTraceSinkContext: Sendable {
    let fileURL: URL
    let retainedLineLimit: Int
    let timeUnixNano: @Sendable () -> UInt64
}

struct AgentStudioOTLPTraceSinkContext: Sendable {
    let endpoint: URL
    let otlpProtocol: AgentStudioOTLPProtocol
    let queueStatistics: AgentStudioTraceQueueStatistics
}

struct AgentStudioTraceSinkFactory: Sendable {
    let makeJSONLSink: @Sendable (AgentStudioJSONLTraceSinkContext) -> any AgentStudioTraceSink
    let makeOTLPSink: @Sendable (AgentStudioOTLPTraceSinkContext) -> any AgentStudioTraceSink

    static let live = Self(
        makeJSONLSink: { context in
            AgentStudioJSONLTraceSink(context: context)
        },
        makeOTLPSink: { context in
            AgentStudioOTLPTraceSink(context: context)
        }
    )
}
