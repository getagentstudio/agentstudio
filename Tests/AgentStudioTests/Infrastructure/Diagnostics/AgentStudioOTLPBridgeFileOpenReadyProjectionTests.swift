import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPBridgeFileOpenReadyProjectionTests {
    @Test
    func bridgeProjectionPreservesFileOpenReadyDemandDiagnostics() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 514,
            severityText: .info,
            body: "performance.bridge.web.file_open_ready",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.content.body_registry_commit_ms": .double(1.25),
                "agentstudio.bridge.content.estimated_bytes": .int(512),
                "agentstudio.bridge.content.first_chunk_wait_ms": .double(2.5),
                "agentstudio.bridge.content.response_wait_ms": .double(3.75),
                "agentstudio.bridge.content.role": .string("file"),
                "agentstudio.bridge.content.stream_read_ms": .double(4.5),
                "agentstudio.bridge.demand.disposition": .string("cold-loaded"),
                "agentstudio.bridge.demand.executor_in_flight_ms": .double(5.25),
                "agentstudio.bridge.demand.executor_pending_wait_ms": .double(6.5),
                "agentstudio.bridge.demand.lane": .string("foreground"),
                "agentstudio.bridge.demand.request.sequence": .int(7),
                "agentstudio.bridge.demand.scheduler_queue_wait_ms": .double(8.75),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                "agentstudio.bridge.phase": .string("file_open_ready"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.result_reason": .string("none"),
                "agentstudio.bridge.slice": .string("content_fetch"),
                "agentstudio.bridge.transport": .string("content"),
                "agentstudio.bridge.viewer": .string("file"),
                "agentstudio.performance.elapsed_ms": .double(42.5),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
                "agentstudio.trace.raw_error": .string("private error"),
                "agentstudio.trace.raw_path": .string("/Users/private/repo/src/file.swift"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.demand.disposition"] == .string("cold-loaded"))
        #expect(projection.attributes["agentstudio.bridge.demand.scheduler_queue_wait_ms"] == .double(8.75))
        #expect(projection.attributes["agentstudio.bridge.content.body_registry_commit_ms"] == .double(1.25))
        #expect(projection.attributes["agentstudio.bridge.item_id"] != nil)
        #expect(projection.attributes["agentstudio.trace.raw_error"] != nil)
        #expect(projection.attributes["agentstudio.trace.raw_path"] != nil)
    }

}
