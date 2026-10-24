import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPBridgeTreeTelemetryProjectionTests {
    @Test
    func projectionPreservesBridgeTreeInstrumentationAttributes() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 771,
            severityText: .info,
            body: "performance.bridge.trees.scroll_to_path",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.anchor_restore.phase": .string("direct_restore"),
                "agentstudio.bridge.focus": .bool(true),
                "agentstudio.bridge.input.source": .string("mouse"),
                "agentstudio.bridge.phase": .string("scroll_to_path"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.scroll.active": .bool(false),
                "agentstudio.bridge.scroll.frame_gap.max_ms": .double(41),
                "agentstudio.bridge.scroll.frame_gap.over_16ms.count": .int(3),
                "agentstudio.bridge.scroll.frame_gap.over_33ms.count": .int(1),
                "agentstudio.bridge.scroll.frame_gap.over_50ms.count": .int(0),
                "agentstudio.bridge.scroll.frame_gap.p95_ms": .double(33),
                "agentstudio.bridge.scroll.offset": .string("nearest"),
                "agentstudio.bridge.scroll.reason": .string("selected_path_effect"),
                "agentstudio.bridge.slice": .string("tree_prepare_input"),
                "agentstudio.bridge.transport": .string("worker"),
                "agentstudio.bridge.visible_descriptor.count": .int(4),
                "agentstudio.bridge.visible_publisher.skipped.count": .int(2),
                "agentstudio.bridge.visible_row.count": .int(9),
                "agentstudio.bridge.viewer": .string("file"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.input.source"] == .string("mouse"))
        #expect(projection.attributes["agentstudio.bridge.scroll.reason"] == .string("selected_path_effect"))
        #expect(projection.attributes["agentstudio.bridge.scroll.offset"] == .string("nearest"))
        #expect(projection.attributes["agentstudio.bridge.anchor_restore.phase"] == .string("direct_restore"))
        #expect(projection.attributes["agentstudio.bridge.focus"] == .bool(true))
        #expect(projection.attributes["agentstudio.bridge.scroll.active"] == .bool(false))
        #expect(projection.attributes["agentstudio.bridge.scroll.frame_gap.max_ms"] == .double(41))
        #expect(projection.attributes["agentstudio.bridge.visible_descriptor.count"] == .int(4))
        #expect(projection.attributes["agentstudio.bridge.visible_publisher.skipped.count"] == .int(2))
        #expect(projection.attributes["agentstudio.bridge.visible_row.count"] == .int(9))
    }
}
