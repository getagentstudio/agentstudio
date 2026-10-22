import Foundation
import Testing

@testable import AgentStudioInfrastructure

extension AgentStudioOTLPPerformanceMetricsTests {
    @Test
    func unpickedDimensionValuesDoNotWidenSamplesOrEventCounters() throws {
        for fixture in Self.metricDimensionValueCases {
            for invalidValue in ["private_kind", "/Users/private/value", ""] {
                let record = Self.metricDimensionRecord(
                    eventName: fixture.eventName,
                    attributes: [fixture.attributeKey: .string(invalidValue)]
                )
                let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
                let expectedDimensions = [
                    AgentStudioOTLPPerformanceMetricDimension(name: "event", value: fixture.eventName)
                ]
                #expect(metricEvent.dimensions == expectedDimensions, "\(fixture.attributeKey): \(invalidValue)")
                let factory = OTLPRecordingMetricsFactory()
                AgentStudioOTLPPerformanceMetrics(factory: factory).record(record)
                #expect(
                    factory.counter(
                        label: "agentstudio_performance_events_total", dimensions: [("event", fixture.eventName)]
                    )?.totalValue == 1
                )
                #expect(
                    metricEvent.measurements.allSatisfy { measurement in
                        switch measurement {
                        case .counter(let sample), .distribution(let sample), .gauge(let sample):
                            return sample.dimensions == expectedDimensions
                        }
                    })
            }
        }
    }

    @Test
    func atomLabelsKeepTheExistingProjectionStringBoundary() throws {
        // The pre-cutover projection admits event-name syntax up to 128 characters.
        for (value, isAdmitted) in [
            ("atom:derived", true), (String(repeating: "a", count: 128), true),
            ("/Users/private", false), ("", false), (String(repeating: "a", count: 129), false),
        ] {
            let record = Self.metricDimensionRecord(
                eventName: "performance.atom.derived",
                attributes: [
                    "agentstudio.performance.atom.kind": .string("eager_derived_family"),
                    "agentstudio.performance.atom.label": .string(value),
                ]
            )
            let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
            #expect(metricEvent.dimensions.contains(.init(name: "atom_label", value: value)) == isAdmitted)
        }
    }

    @Test
    func resourceProofMarkersKeepTheExistingResourceStringBoundary() throws {
        for (value, isAdmitted) in [
            ("proof marker: value", true), (String(repeating: "a", count: 160), true),
            ("/Users/private", false), ("", false), (String(repeating: "a", count: 161), false),
        ] {
            let record = Self.metricDimensionRecord(
                eventName: "performance.bridge.webkit.push_envelope",
                attributes: [
                    "agent.proof.marker": .string(value),
                    "agentstudio.bridge.phase": .string("transport"),
                    "agentstudio.bridge.plane": .string("data"),
                    "agentstudio.bridge.priority": .string("cold"),
                    "agentstudio.bridge.slice": .string("review_metadata"),
                ],
                resource: ["agent.proof.marker": value]
            )
            let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
            #expect(metricEvent.dimensions.contains(.init(name: "agent.proof.marker", value: value)) == isAdmitted)
        }
    }

    @Test
    func pickedMetricDimensionValuesRemainAdmitted() throws {
        // R5 protects these existing value sets; literals pin the pre-cutover contract.
        for fixture in Self.metricDimensionValueCases {
            for value in fixture.allowedValues {
                let record = Self.metricDimensionRecord(
                    eventName: fixture.eventName,
                    attributes: [fixture.attributeKey: .string(value)]
                )
                let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
                #expect(metricEvent.dimensions.contains(.init(name: fixture.dimensionName, value: value)))
            }
        }
    }

    @Test
    func panesSidebarWithActivityGroupingProducesMetrics() throws {
        let record = Self.metricDimensionRecord(
            eventName: "performance.sidebar.projection",
            attributes: [
                "agentstudio.performance.sidebar.surface": .string("panes"),
                "agentstudio.performance.sidebar.phase": .string("projection_worker"),
                "agentstudio.performance.sidebar.query_state": .string("empty"),
                "agentstudio.performance.sidebar.group_mode": .string("activity"),
                "agentstudio.performance.sidebar.trigger": .string("grouping_switch"),
            ]
        )
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
        #expect(metricEvent.dimensions.contains(.init(name: "surface", value: "panes")))
        #expect(metricEvent.dimensions.contains(.init(name: "group_mode", value: "activity")))
        #expect(metricEvent.elapsedMilliseconds == 7.5)
        #expect(!metricEvent.measurements.isEmpty)
    }

    static func metricDimensionRecord(
        eventName: String,
        attributes: [String: AgentStudioTraceValue],
        resource: [String: String] = ["service.name": "AgentStudio"]
    ) -> AgentStudioOTLPProjectedLogRecord {
        var metricAttributes = attributes
        metricAttributes["agentstudio.performance.elapsed_ms"] = .double(7.5)
        return AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 459, severityText: .info, body: eventName,
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: resource,
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: metricAttributes
        )
    }

    struct MetricDimensionValueCase: Sendable {
        let eventName: String
        let attributeKey: String
        let dimensionName: String
        let allowedValues: [String]
    }

    static let metricDimensionValueCases: [MetricDimensionValueCase] = [
        .init(
            eventName: "performance.interaction.latency", attributeKey: "agentstudio.performance.interaction.kind",
            dimensionName: "interaction_kind",
            allowedValues: ["command_bar_open", "command_bar_close", "tab_move", "divider_frame", "cmd_r"]),
        .init(
            eventName: "performance.repo_explorer.keyed_wake",
            attributeKey: "agentstudio.performance.repo_explorer.stage", dimensionName: "stage",
            allowedValues: [
                "observe_project", "distinct", "coalesce", "admission", "execute", "validate", "publish", "materialize",
                "deadline", "eager_admission", "projection_worker", "command_affected_row", "command_whole_surface",
                "capture_rebuild", "affected_row", "membership_path", "whole_surface", "mainactor_apply",
                "final_projection", "atom_slot", "other",
            ]),
        .init(
            eventName: "performance.repo_explorer.keyed_wake",
            attributeKey: "agentstudio.performance.repo_explorer.key_class", dimensionName: "key_class",
            allowedValues: [
                "ordinary_run", "rendered_repo_favorite", "rendered_worktree_fact", "relevant",
                "unrelated_tab_arrangement_pane", "observed_tab_title", "unrendered_attendance", "missing_declared_key",
                "diagnostic_settle",
            ]),
        .init(
            eventName: "performance.repo_explorer.keyed_wake",
            attributeKey: "agentstudio.performance.repo_explorer.outcome", dimensionName: "outcome",
            allowedValues: [
                "observed", "suppressed", "coalesced", "admitted", "executed", "published", "materialized", "equal",
                "changed", "unknown", "retained", "replaced", "deferred", "rejected", "capacity_limited", "started",
                "completed", "current", "cancelled", "superseded", "stale", "stale_generation", "stale_origin",
                "stale_scope", "failed", "invalidated", "revoked", "scheduled", "rescheduled", "fired", "relevant_key",
                "reference_equal", "reference_different", "other",
            ]),
        .init(
            eventName: "performance.repo_explorer.keyed_wake",
            attributeKey: "agentstudio.performance.repo_explorer.facet", dimensionName: "facet",
            allowedValues: ["attendance", "unread"]),
        .init(
            eventName: "performance.repo_explorer.keyed_wake",
            attributeKey: "agentstudio.performance.repo_explorer.row_relation", dimensionName: "row_relation",
            allowedValues: ["owning", "unrendered", "affected_row"]),
        .init(
            eventName: "performance.repo_explorer.native_table_pilot",
            attributeKey: "agentstudio.performance.repo_explorer.native_table_pilot.scale", dimensionName: "scale",
            allowedValues: ["baseline", "doubled", "summary"]),
        .init(
            eventName: "performance.repo_explorer.native_table_pilot",
            attributeKey: "agentstudio.performance.repo_explorer.native_table_pilot.outcome", dimensionName: "outcome",
            allowedValues: ["completed", "passed", "failed"]),
        .init(
            eventName: "performance.repo_explorer.row_body_evaluation",
            attributeKey: "agentstudio.performance.repo_explorer.row_body_evaluation.outcome", dimensionName: "outcome",
            allowedValues: ["success", "failed", "incomplete"]),
        .init(
            eventName: "performance.repo_explorer.row_body_evaluation",
            attributeKey: "agentstudio.performance.repo_explorer.row_kind", dimensionName: "row_kind",
            allowedValues: [
                "section_header", "loading_section_header", "loading_repo", "resolved_group_header",
                "resolved_worktree", "resolved_pane", "topology_fault",
            ]),
        .init(
            eventName: "performance.repo_explorer.row_body_evaluation",
            attributeKey: "agentstudio.performance.repo_explorer.surface", dimensionName: "surface",
            allowedValues: ["repo"]),
        .init(
            eventName: "performance.repo_explorer.row_body_evaluation",
            attributeKey: "agentstudio.performance.repo_explorer.visible_row_count_bucket",
            dimensionName: "visible_row_count_bucket", allowedValues: ["zero", "1_8", "9_16", "17_32", "33_plus"]),
        .init(
            eventName: "performance.repo_explorer.scroll_frame_gap",
            attributeKey: "agentstudio.performance.repo_explorer.scroll_frame_gap.outcome", dimensionName: "outcome",
            allowedValues: ["sampled", "incomplete"]),
        .init(
            eventName: "performance.filesystem.stage_outcome", attributeKey: "agentstudio.performance.filesystem.stage",
            dimensionName: "stage", allowedValues: ["affected_key_apply", "overflow_recovery"]),
        .init(
            eventName: "performance.filesystem.stage_outcome",
            attributeKey: "agentstudio.performance.filesystem.outcome", dimensionName: "outcome",
            allowedValues: ["applied", "rejected", "overflow_coarse", "overflow_scoped"]),
        .init(
            eventName: "performance.forge.refresh", attributeKey: "agentstudio.performance.forge.stage",
            dimensionName: "stage", allowedValues: ["follow_up", "facts_publication"]),
        .init(
            eventName: "performance.forge.refresh", attributeKey: "agentstudio.performance.forge.outcome",
            dimensionName: "outcome", allowedValues: ["admitted", "deferred", "equal"]),
        .init(
            eventName: "performance.repository_fact_update",
            attributeKey: "agentstudio.performance.repository_update.stage", dimensionName: "stage",
            allowedValues: ["captured", "admitted", "settled"]),
        .init(
            eventName: "performance.repository_fact_update",
            attributeKey: "agentstudio.performance.repository_update.outcome", dimensionName: "outcome",
            allowedValues: [
                "captured", "loading", "no_applicable", "complete", "partial_failure", "failed", "cancelled",
                "obsolete", "mixed_terminal", "incomplete",
            ]),
    ]
}
