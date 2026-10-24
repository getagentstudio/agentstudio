import AgentStudioInfrastructure
import Foundation

struct RestoreCostTraceTestFixture: Sendable {
    let directory: URL
    let runtime: AgentStudioTraceRuntime
    let recorder: AgentStudioPerformanceTraceRecorder

    init() {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "restore-cost-\(UUIDv7.generate().uuidString)")
        runtime = AgentStudioTraceRuntime(
            configuration: .from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": directory.path,
                "AGENTSTUDIO_TRACE_NAME": "restore-owner-cost", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]), processIdentifier: 909)
        recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
    }

    @concurrent nonisolated func finish() async throws -> [RestoreCostTraceRow] {
        try await recorder.drain()
        guard let output = runtime.outputFileURL else { return [] }
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").compactMap { line in
            let row = try JSONDecoder().decode(RestoreCostTraceRow.self, from: Data(line.utf8))
            return row.body.hasPrefix("performance.restore.") ? row : nil
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

struct RestoreCostTraceRow: Decodable, Sendable {
    let body: String
    let attributes: RestoreCostTraceScalars
}

struct RestoreCostTraceScalars: Decodable, Sendable {
    let elapsedMilliseconds: Double?
    let executions: Int?
    let mainThreadExecutions: Int?
    let mainThreadMilliseconds: Double?

    enum CodingKeys: String, CodingKey {
        case elapsedMilliseconds = "agentstudio.performance.elapsed_ms"
        case executions = "agentstudio.performance.restore.execution.count"
        case mainThreadExecutions = "agentstudio.performance.restore.main_thread.execution.count"
        case mainThreadMilliseconds = "agentstudio.performance.restore.main_thread.elapsed_ms"
    }
}
