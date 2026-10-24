import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPNativeTablePilotMetricsTests {
    @Test("native table pilot metrics retain bounded scale outcome and distribution")
    func nativeTablePilotMetricsAreBounded() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 124,
            severityText: .info,
            body: "performance.repo_explorer.native_table_pilot",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repo_explorer.native_table_pilot.scale": .string("baseline"),
                "agentstudio.performance.repo_explorer.native_table_pilot.outcome": .string("passed"),
                "agentstudio.performance.repo_explorer.native_table_pilot.measured.count": .int(200),
                "agentstudio.performance.repo_explorer.native_table_pilot.liveness_projection.count": .int(1),
                "agentstudio.performance.repo_explorer.native_table_pilot.drain_completed.count": .int(1),
                "agentstudio.performance.repo_explorer.native_table_pilot.template_pair.count": .int(1),
                "agentstudio.performance.repo_explorer.native_table_pilot.membership_p95_ms": .double(1.5),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.dimensions.map(\.name) == ["event", "scale", "outcome"])
        #expect(
            metricEvent.samples.map(\.label) == [
                "agentstudio_performance_repo_explorer_native_table_pilot_drain_completed_count",
                "agentstudio_performance_repo_explorer_native_table_pilot_liveness_projection_count",
                "agentstudio_performance_repo_explorer_native_table_pilot_membership_p95_ms",
                "agentstudio_performance_repo_explorer_native_table_pilot_template_pair_count",
            ]
        )
    }
}
