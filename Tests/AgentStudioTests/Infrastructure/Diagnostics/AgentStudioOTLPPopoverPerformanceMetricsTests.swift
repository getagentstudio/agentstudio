import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite("Popover performance metric projection")
struct AgentStudioOTLPPopoverPerformanceMetricsTests {
    @Test("S6 popover counts and synchronous held spans export bounded stage, surface and kind dimensions")
    func popoverEventsRetainTheirMetricDimensions() throws {
        let stages = [
            "observed", "coalesced", "deferred", "admission", "execution", "storage_read", "projection",
            "publication", "validation_publication", "input_publication", "wake", "empty_wake",
            "capture", "materialize", "admit", "classify", "complete", "equal", "superseded", "cancelled", "retired",
            "family_admission", "apply", "text_layout", "text_layout_reuse",
        ]
        let surfaces = [
            "sidebar_messages", "pane_messages", "card_messages", "agent_line", "management_card", "toolbar", "shared",
        ]
        let kinds = ["none", "opening", "background", "age", "action", "page"]
        for body in ["performance.pane_context.popover", "performance.pane_context.popover.main_actor_held"] {
            for (index, stage) in stages.enumerated() {
                let surface = surfaces[index % surfaces.count]
                let kind = kinds[index % kinds.count]
                let raw = record(body: body, stage: stage, surface: surface, kind: kind)
                let projected = AgentStudioOTLPTraceProjection.project(raw)
                let metric = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projected))
                #expect(metric.eventName == body)
                #expect(metric.dimensionTuples.map { $0.0 } == ["event", "stage", "surface", "kind"])
                #expect(metric.dimensionTuples.map { $0.1 } == [body, stage, surface, kind])
                #expect(metric.elapsedMilliseconds == 2.5)
                #expect(
                    metric.measurements.contains {
                        if case .distribution(let sample) = $0 {
                            sample.label == "agentstudio_performance_event_elapsed_ms" && sample.value == 2.5
                        } else {
                            false
                        }
                    })
            }
        }
    }

    @Test("S6 arbitrary synthetic strings are retained as log attributes but never admitted as metric dimensions")
    func unknownPopoverDimensionsCannotCreateSeries() throws {
        // Synthetic strings bypass the App emitter's enum-only vocabulary; projection preserves raw logs.
        let raw = record(
            body: "performance.pane_context.popover", stage: "PRIVATE-BODY", surface: "PRIVATE-PANE",
            kind: "PRIVATE-PROMPT")
        let projected = AgentStudioOTLPTraceProjection.project(raw)
        #expect(projected.attributes["agentstudio.performance.pane_context.popover.stage"] == .string("PRIVATE-BODY"))
        let metric = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projected))
        #expect(metric.dimensionTuples.map { $0.0 } == ["event"])
        #expect(metric.dimensionTuples.map { $0.1 } == ["performance.pane_context.popover"])
    }

    @Test(
        "Named apply/worker elapsed gauges retain histograms and TextKit counts export as counters",
        arguments: ["apply", "projection", "text_layout"])
    func popoverWorkBecomesNumericMeasurements(stage: String) throws {
        let name: String
        switch stage {
        case "apply": name = "agentstudio.performance.pane_context.popover.apply_commit_elapsed_ms"
        case "projection": name = "agentstudio.performance.pane_context.popover.projection_elapsed_ms"
        default: name = "agentstudio.performance.pane_context.popover.text_layout.count"
        }
        let body =
            stage == "apply" ? "performance.pane_context.popover.main_actor_held" : "performance.pane_context.popover"
        var attributes: [String: AgentStudioTraceValue] = [
            "agentstudio.performance.pane_context.popover.stage": .string(stage),
            "agentstudio.performance.pane_context.popover.surface": .string("sidebar_messages"),
            "agentstudio.performance.pane_context.popover.kind": .string("none"), name: .double(7),
        ]
        if stage != "text_layout" { attributes["agentstudio.performance.elapsed_ms"] = .double(7) }
        let raw = AgentStudioTraceRecord(
            timeUnixNano: 117, severityText: .info, body: body, traceID: nil, spanID: nil, parentSpanID: nil,
            resource: [:], scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: attributes)
        let metric = try #require(
            AgentStudioOTLPPerformanceMetricEvent(record: AgentStudioOTLPTraceProjection.project(raw)))
        #expect(metric.dimensionTuples.map { $0.1 } == [body, stage, "sidebar_messages", "none"])
        let label = name.replacingOccurrences(of: ".", with: "_")
        #expect(metric.samples.map(\.label) == [label])
        #expect(metric.samples.map(\.value) == [7])
        let measurement = try #require(
            metric.measurements.first {
                switch $0 {
                case .counter(let sample), .distribution(let sample), .gauge(let sample): sample.label == label
                }
            })
        switch measurement {
        case .counter: #expect(stage == "text_layout")
        case .gauge: #expect(stage != "text_layout")
        case .distribution: Issue.record("Named measurements follow the catalog's counter/gauge classification")
        }
        if stage != "text_layout" {
            #expect(
                metric.measurements.contains {
                    if case .distribution(let sample) = $0 {
                        sample.label == "agentstudio_performance_event_elapsed_ms" && sample.value == 7
                    } else {
                        false
                    }
                }, "The duration recorder must also retain the elapsed histogram")
        }
    }

    private func record(body: String, stage: String, surface: String, kind: String) -> AgentStudioTraceRecord {
        .init(
            timeUnixNano: 117, severityText: .info, body: body, traceID: nil, spanID: nil, parentSpanID: nil,
            resource: [:], scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.pane_context.popover.stage": .string(stage),
                "agentstudio.performance.pane_context.popover.surface": .string(surface),
                "agentstudio.performance.pane_context.popover.kind": .string(kind),
                "agentstudio.performance.elapsed_ms": .double(2.5),
            ])
    }
}
