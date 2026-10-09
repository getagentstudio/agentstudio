import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct BridgeRenderDispositionOTLPMetricsTests {
    @Test
    func admissionProjectsBoundedDimensionsAndMeasurements() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.bridge.web.render_disposition_admission",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(4.5),
                "agentstudio.bridge.phase": .string("render_disposition_batch_terminal"),
                "agentstudio.bridge.plane": .string("control"),
                "agentstudio.bridge.priority": .string("warm"),
                "agentstudio.bridge.render_disposition.batch_receipt_count": .int(64),
                "agentstudio.bridge.render_disposition.duplicate_count": .int(1),
                "agentstudio.bridge.render_disposition.in_flight_count": .int(64),
                "agentstudio.bridge.render_disposition.oldest_pending_age_ms": .double(2),
                "agentstudio.bridge.render_disposition.outcome": .string("acked"),
                "agentstudio.bridge.render_disposition.pending_count": .int(3),
                "agentstudio.bridge.render_disposition.pending_high_water_mark": .int(65),
                "agentstudio.bridge.render_disposition.produced_count": .int(66),
                "agentstudio.bridge.render_disposition.retained_count": .int(67),
                "agentstudio.bridge.slice": .string("command_acks"),
                "agentstudio.bridge.viewer": .string("review"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.elapsedMilliseconds == 4.5)
        #expect(metricEvent.dimensions.contains(.init(name: "viewer", value: "review")))
        #expect(metricEvent.dimensions.contains(.init(name: "render_disposition_outcome", value: "acked")))
        #expect(
            metricEvent.samples.map(\.label) == [
                "agentstudio_bridge_render_disposition_batch_receipt_count",
                "agentstudio_bridge_render_disposition_duplicate_count",
                "agentstudio_bridge_render_disposition_in_flight_count",
                "agentstudio_bridge_render_disposition_oldest_pending_age_ms",
                "agentstudio_bridge_render_disposition_pending_count",
                "agentstudio_bridge_render_disposition_pending_high_water_mark",
                "agentstudio_bridge_render_disposition_produced_count",
                "agentstudio_bridge_render_disposition_retained_count",
            ]
        )
    }

    @Test(arguments: ["published", "held"])
    func workerOutstandingPublicationProjectsBoundedGauges(outcome: String) throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.bridge.worker.render_publication_outstanding",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("render_publication_outstanding_changed"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("warm"),
                "agentstudio.bridge.render_publication.current_count": .int(12),
                "agentstudio.bridge.render_publication.high_water_mark": .int(12),
                "agentstudio.bridge.render_publication.oldest_age_ms": .double(25),
                "agentstudio.bridge.render_publication.outcome": .string(outcome),
                "agentstudio.bridge.slice": .string("command_acks"),
                "agentstudio.bridge.viewer": .string("review"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.dimensions.contains(.init(name: "viewer", value: "review")))
        #expect(metricEvent.dimensions.contains(.init(name: "render_publication_outcome", value: outcome)))
        #expect(
            metricEvent.samples.map(\.label) == [
                "agentstudio_bridge_render_publication_current_count",
                "agentstudio_bridge_render_publication_high_water_mark",
                "agentstudio_bridge_render_publication_oldest_age_ms",
            ]
        )
    }
}
