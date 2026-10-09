import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge
@testable import AgentStudioInfrastructure

/// Observes the real factory's trace port without replacing its controller or providers.
actor BridgeNativeCatchUpTraceSink: AgentStudioTraceSink {
    let expectation: BridgeProductWebKitCatchUpTerminalExpectation
    private var reservedOperations: Set<BridgeProductWebKitCatchUpOperation> = []

    init(expectation: BridgeProductWebKitCatchUpTerminalExpectation) {
        self.expectation = expectation
    }

    nonisolated func makeRuntime() -> AgentStudioTraceRuntime {
        AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl",
                "AGENTSTUDIO_TRACE_DIR": FileManager.default.temporaryDirectory.path,
                "AGENTSTUDIO_TRACE_NAME": "native-catch-up-facts",
                "AGENTSTUDIO_TRACE_TAGS": "bridge.performance.swift",
            ]),
            sinkFactory: AgentStudioTraceSinkFactory(makeJSONLSink: { _ in self }, makeOTLPSink: { _ in self }),
            timeUnixNano: { 121 })
    }

    func record(_ record: AgentStudioTraceRecord) {
        guard record.body == "performance.bridge.swift.operation_lifecycle",
            case .string(let laneValue) = record.attributes["agentstudio.bridge.viewer"],
            let lane = BridgePaneRefreshLane(rawValue: laneValue), expectation.lanes.contains(lane),
            case .string(let operationId) = record.attributes["agentstudio.bridge.operation.id"],
            case .string(let phase) = record.attributes["agentstudio.bridge.phase"]
        else { return }
        let operation = BridgeProductWebKitCatchUpOperation(lane: lane, operationId: operationId)
        if phase == "refresh_reserved" {
            reservedOperations.insert(operation)
            expectation.recorder.append(scope: operation, fact: .reserved)
        } else if phase == "refresh_operation_terminal", reservedOperations.contains(operation),
            case .string(let result) = record.attributes["agentstudio.bridge.result"]
        {
            expectation.recorder.append(scope: operation, fact: .terminal(result: result))
        }
    }

    func finish() async throws {
        expectation.recorder.receive(.ended)
        try await expectation.recorder.finish()
    }

    func flush() {}
    func shutdown() {}
    func diagnostics() -> AgentStudioTraceWriterDiagnostics { .empty }
}
