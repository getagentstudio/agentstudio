import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Renderer lifecycle OTLP")
struct RendererLifecycleOTLPTests {
    @Test("projection exports bounded aggregates and retains exact identity")
    func projectionExportsBoundedAggregatesAndRetainsIdentity() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:14: renderer emits lifecycle populations, never message text.
        // Arrange
        let surfaceID = UUIDv7.generate().uuidString
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.renderer.event.kind": .string("released"),
            "agentstudio.performance.renderer.created.total": .int(1),
            "agentstudio.performance.renderer.released.total": .int(1),
            "agentstudio.performance.renderer.freed.total": .int(0),
            "agentstudio.performance.renderer.active.current": .int(0),
            "agentstudio.performance.renderer.hidden.current": .int(0),
            "agentstudio.performance.renderer.close_undo.current": .int(0),
            "agentstudio.performance.renderer.live.current": .int(1),
            "agentstudio.performance.renderer.manager_owned.current": .int(0),
            "agentstudio.performance.renderer.orphan_candidate.current": .int(1),
            "agentstudio.performance.renderer.sample.sequence": .int(2),
            "agentstudio.performance.renderer.created.delta": .int(0),
            "agentstudio.performance.renderer.released.delta": .int(1),
            "agentstudio.performance.renderer.freed.delta": .int(0),
            "agentstudio.performance.renderer.lifecycle.valid": .bool(true),
        ]
        attributes["agentstudio.performance.renderer.surface_id"] = .string(surfaceID)
        attributes["agentstudio.performance.renderer.raw_path"] = .string("/private/renderer-path")
        attributes["agentstudio.performance.renderer.title"] = .string("secret-title")
        let record = AgentStudioTraceRecord(
            timeUnixNano: 89,
            severityText: .info,
            body: "performance.renderer.lifecycle",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: attributes
        )

        // Act
        let projection = OTLPProjectionAssertions.project(record)

        // Assert
        #expect(
            projection.attributes["agentstudio.performance.renderer.event.kind"] == .string("released")
        )
        #expect(projection.attributes["agentstudio.performance.renderer.released.delta"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.renderer.orphan_candidate.current"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.renderer.lifecycle.valid"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.renderer.surface_id"] != nil)
        #expect(projection.attributes["agentstudio.performance.renderer.raw_path"] != nil)
        #expect(projection.attributes["agentstudio.performance.renderer.title"] != nil)
    }

    @Test("metric mapping uses counters for deltas and gauges for current values")
    func metricMappingUsesCountersForDeltasAndGaugesForCurrent() throws {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder+RendererLifecycle.swift:14: renderer emits lifecycle populations, never message text.
        // Arrange
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 119,
            severityText: .info,
            body: "performance.renderer.lifecycle",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.renderer.event.kind": .string("released"),
                "agentstudio.performance.renderer.created.delta": .int(0),
                "agentstudio.performance.renderer.released.delta": .int(1),
                "agentstudio.performance.renderer.freed.delta": .int(0),
                "agentstudio.performance.renderer.created.total": .int(1),
                "agentstudio.performance.renderer.released.total": .int(1),
                "agentstudio.performance.renderer.active.current": .int(0),
            ]
        )

        // Act
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
        let counterLabels = metricEvent.measurements.compactMap { measurement -> String? in
            guard case .counter(let sample) = measurement else { return nil }
            return sample.label
        }
        let gaugeLabels = metricEvent.measurements.compactMap { measurement -> String? in
            guard case .gauge(let sample) = measurement else { return nil }
            return sample.label
        }

        // Assert
        #expect(
            metricEvent.dimensions == [
                .init(name: "event", value: "performance.renderer.lifecycle"),
                .init(name: "event_kind", value: "released"),
            ]
        )
        #expect(counterLabels.contains("agentstudio_performance_renderer_released_delta"))
        #expect(!counterLabels.contains("agentstudio_performance_renderer_created_total"))
        #expect(gaugeLabels.contains("agentstudio_performance_renderer_created_total"))
        #expect(gaugeLabels.contains("agentstudio_performance_renderer_active_current"))
    }
}
