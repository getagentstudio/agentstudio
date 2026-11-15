import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPInstrumentationTaxonomyTests {
    @Test
    func strictSidebarPolicyProjectsItsClosedStructuredValues() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 5,
                severityText: .info,
                body: "app.startup_diagnostic_action.command_exercised",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.startup_diagnostic.sidebar_proof.standard_trace_tags": .string(
                        "performance,app.startup,terminal.startup"
                    ),
                    "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_trace_tags": .string(
                        "performance,atoms,app.startup,terminal.startup"
                    ),
                    "agentstudio.startup_diagnostic.sidebar_proof.idle_populations": .string(
                        "zero_pty_idle"
                    ),
                    "agentstudio.startup_diagnostic.sidebar_proof.action_populations": .string(
                        "search_clear,grouping,hide_show,tab_switch"
                    ),
                ]
            )
        )

        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.standard_trace_tags"
            ] == .string("performance,app.startup,terminal.startup")
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.diagnostic_trace_tags"
            ] == .string("performance,atoms,app.startup,terminal.startup")
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.idle_populations"
            ] == .string("zero_pty_idle")
        )
        #expect(
            projection.attributes[
                "agentstudio.startup_diagnostic.sidebar_proof.action_populations"
            ] == .string("search_clear,grouping,hide_show,tab_switch")
        )
    }

    @Test
    func strictSidebarInitialReadbackProjectsOnlyBoundedFailureFacets() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let prefix = "agentstudio.performance.sidebar.proof.initial_readback."
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 6,
                severityText: .info,
                body: "performance.sidebar.proof_action.failed",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    prefix + "present": .bool(true),
                    prefix + "repo_demanded": .bool(false),
                    prefix + "repo_presentation_ready": .bool(true),
                    prefix + "repo_accessibility": .string("ready"),
                    prefix + "semantic_collapsed": .bool(false),
                    prefix + "native_collapsed": .bool(false),
                    prefix + "native_geometry_visible": .bool(true),
                    prefix + "native_accessibility_ready": .bool(false),
                    prefix + "app_hidden": .bool(false),
                    prefix + "app_active": .bool(true),
                    prefix + "window_visible": .bool(true),
                    prefix + "window_key": .bool(true),
                    prefix + "window_miniaturized": .bool(false),
                    prefix + "window_on_active_space": .bool(true),
                    prefix + "window_occlusion_visible": .bool(false),
                    prefix + "represented_row_count": .int(148),
                    prefix + "native_row_count": .int(148),
                    prefix + "private_title": .string("secret"),
                ]
            )
        )

        #expect(projection.attributes[prefix + "repo_demanded"] == .bool(false))
        #expect(projection.attributes[prefix + "repo_accessibility"] == .string("ready"))
        #expect(projection.attributes[prefix + "semantic_collapsed"] == .bool(false))
        #expect(projection.attributes[prefix + "native_collapsed"] == .bool(false))
        #expect(projection.attributes[prefix + "native_geometry_visible"] == .bool(true))
        #expect(projection.attributes[prefix + "native_accessibility_ready"] == .bool(false))
        #expect(projection.attributes[prefix + "app_hidden"] == .bool(false))
        #expect(projection.attributes[prefix + "app_active"] == .bool(true))
        #expect(projection.attributes[prefix + "window_visible"] == .bool(true))
        #expect(projection.attributes[prefix + "window_key"] == .bool(true))
        #expect(projection.attributes[prefix + "window_miniaturized"] == .bool(false))
        #expect(projection.attributes[prefix + "window_on_active_space"] == .bool(true))
        #expect(projection.attributes[prefix + "window_occlusion_visible"] == .bool(false))
        #expect(projection.attributes[prefix + "represented_row_count"] == .int(148))
        #expect(projection.attributes[prefix + "native_row_count"] == .int(148))
        #expect(projection.attributes[prefix + "private_title"] != nil)

        let rejectedControlledText = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 7,
                severityText: .info,
                body: "performance.sidebar.proof_action.failed",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [prefix + "repo_accessibility": .string("secret")]
            )
        )
        #expect(rejectedControlledText.attributes[prefix + "repo_accessibility"] != nil)
    }

    @Test
    func nativeTablePilotProjectsOnlyBoundedPolicyAndAggregateValues() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 4,
                severityText: .info,
                body: "performance.repo_explorer.native_table_pilot",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.trace.tag": .string("performance"),
                    "agentstudio.performance.repo_explorer.native_table_pilot.policy_id": .string(
                        "sidebar-native-table-pilot"
                    ),
                    "agentstudio.performance.repo_explorer.native_table_pilot.policy_version": .int(1),
                    "agentstudio.performance.repo_explorer.native_table_pilot.scale": .string("baseline"),
                    "agentstudio.performance.repo_explorer.native_table_pilot.outcome": .string("passed"),
                    "agentstudio.performance.repo_explorer.native_table_pilot.measured.count": .int(200),
                    "agentstudio.performance.repo_explorer.native_table_pilot.liveness_projection.count": .int(1),
                    "agentstudio.performance.repo_explorer.native_table_pilot.drain_completed.count": .int(1),
                    "agentstudio.performance.repo_explorer.native_table_pilot.template_pair.count": .int(1),
                    "agentstudio.performance.repo_explorer.native_table_pilot.membership_p95_ms": .double(1.5),
                    "agentstudio.performance.repo_explorer.native_table_pilot.private_row_id": .string("secret"),
                ]
            )
        )

        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.native_table_pilot.policy_id"
            ] == .string("sidebar-native-table-pilot")
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.native_table_pilot.measured.count"
            ] == .int(200)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.native_table_pilot.liveness_projection.count"
            ] == .int(1)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.native_table_pilot.drain_completed.count"
            ] == .int(1)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.native_table_pilot.template_pair.count"
            ] == .int(1)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.native_table_pilot.private_row_id"
            ] != nil
        )
    }

    @Test
    func repoExplorerInstrumentDimensionsAreAllowlistedAndBounded() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 1,
                severityText: .info,
                body: "performance.repo_explorer.row_body_evaluation",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.trace.tag": .string("performance"),
                    "agentstudio.performance.repo_explorer.row_body_evaluation.outcome": .string("success"),
                    "agentstudio.performance.repo_explorer.row_kind": .string("resolved_worktree"),
                    "agentstudio.performance.repo_explorer.surface": .string("repo"),
                    "agentstudio.performance.repo_explorer.scroll_active": .bool(true),
                    "agentstudio.performance.repo_explorer.visible_row_count_bucket": .string("9_16"),
                    "agentstudio.performance.repo_explorer.private_row_id": .string("secret"),
                ]
            )
        )

        #expect(projection.attributes["agentstudio.performance.repo_explorer.row_kind"] == .string("resolved_worktree"))
        #expect(projection.attributes["agentstudio.performance.repo_explorer.scroll_active"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.repo_explorer.private_row_id"] != nil)
    }

    @Test
    func repoExplorerKeyedWakeRejectsUnknownTaxonomyValues() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 2,
                severityText: .info,
                body: "performance.repo_explorer.keyed_wake",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.trace.tag": .string("performance"),
                    "agentstudio.performance.repo_explorer.stage": .string("private_stage"),
                    "agentstudio.performance.repo_explorer.key_class": .string("private_key"),
                    "agentstudio.performance.repo_explorer.outcome": .string("private_outcome"),
                ]
            )
        )

        #expect(projection.attributes["agentstudio.performance.repo_explorer.stage"] != nil)
        #expect(projection.attributes["agentstudio.performance.repo_explorer.key_class"] != nil)
        #expect(projection.attributes["agentstudio.performance.repo_explorer.outcome"] != nil)
    }

    @Test
    func stageOutcomeTaxonomiesRejectUnknownValues() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 3,
                severityText: .info,
                body: "performance.filesystem.stage_outcome",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.trace.tag": .string("performance"),
                    "agentstudio.performance.filesystem.stage": .string("private_stage"),
                    "agentstudio.performance.filesystem.outcome": .string("private_outcome"),
                ]
            )
        )

        #expect(projection.attributes["agentstudio.performance.filesystem.stage"] != nil)
        #expect(projection.attributes["agentstudio.performance.filesystem.outcome"] != nil)
    }

    @Test("filesystem ingress snapshot exports only explicit numeric attribution")
    func filesystemIngressSnapshotExportsOnlyExplicitNumericAttribution() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let projection = OTLPProjectionAssertions.project(
            AgentStudioTraceRecord(
                timeUnixNano: 4,
                severityText: .info,
                body: "performance.filesystem.ingress_snapshot",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.trace.tag": .string("performance"),
                    "agentstudio.performance.filesystem.ingress.local_raw_callback.batch.count": .int(3),
                    "agentstudio.performance.filesystem.ingress.shared_exact.accepted.batch.count": .int(5),
                    "agentstudio.performance.filesystem.ingress.overflow.recovery.count": .int(7),
                    "agentstudio.performance.filesystem.local_stream.physical.count": .int(1),
                    "agentstudio.performance.filesystem.local_stream.logical_registration.count": .int(148),
                    "agentstudio.performance.filesystem.ingress.raw_path": .string("/private/repository"),
                    "agentstudio.performance.filesystem.ingress.worktree_id": .string(
                        UUIDv7.generate().uuidString
                    ),
                ]
            )
        )

        #expect(
            projection.attributes[
                "agentstudio.performance.filesystem.ingress.local_raw_callback.batch.count"
            ] == .int(3)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.filesystem.ingress.shared_exact.accepted.batch.count"
            ] == .int(5)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.filesystem.ingress.overflow.recovery.count"
            ] == .int(7)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.filesystem.local_stream.physical.count"
            ] == .int(1)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.filesystem.local_stream.logical_registration.count"
            ] == .int(148)
        )
        #expect(projection.attributes["agentstudio.performance.filesystem.ingress.raw_path"] != nil)
        #expect(projection.attributes["agentstudio.performance.filesystem.ingress.worktree_id"] != nil)
    }
}
