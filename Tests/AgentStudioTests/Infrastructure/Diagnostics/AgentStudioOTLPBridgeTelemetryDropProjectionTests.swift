import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPBridgeTelemetryDropProjectionTests {
    @Test
    func bridgeProjectionPreservesTelemetryDropRequiredDroppedCount() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 514,
            severityText: .info,
            body: "performance.bridge.web.telemetry_drop",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("dropped"),
                "agentstudio.bridge.plane": .string("observability"),
                "agentstudio.bridge.priority": .string("best_effort"),
                "agentstudio.bridge.result": .string("dropped"),
                "agentstudio.bridge.slice": .string("telemetry_drop"),
                "agentstudio.bridge.telemetry.drop_reason": .string("required_event_shed"),
                "agentstudio.bridge.telemetry.dropped_count": .int(7),
                "agentstudio.bridge.telemetry.required_dropped_count": .int(7),
                "agentstudio.bridge.transport": .string("rpc"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(
            projection.attributes["agentstudio.bridge.telemetry.required_dropped_count"]
                == .int(7)
        )
    }
}
