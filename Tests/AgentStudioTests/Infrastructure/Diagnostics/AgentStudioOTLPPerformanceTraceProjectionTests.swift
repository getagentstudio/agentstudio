import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPPerformanceTraceProjectionTests {
    @Test("focus responder change keeps controlled reason and rejects arbitrary values")
    func focusResponderChangeKeepsOnlyControlledReason() {
        let controlled = focusResponderChangeRecord(reason: "parked_cleared")
        let arbitrary = focusResponderChangeRecord(reason: "pane-123-private")

        #expect(
            AgentStudioOTLPTraceProjection.project(controlled).attributes[
                "agentstudio.performance.focus.responder_change.reason"
            ] == .string("parked_cleared"))
        #expect(
            AgentStudioOTLPTraceProjection.project(arbitrary).attributes[
                "agentstudio.performance.focus.responder_change.reason"
            ] == nil)
    }

    private func focusResponderChangeRecord(reason: String) -> AgentStudioTraceRecord {
        AgentStudioTraceRecord(
            timeUnixNano: 118,
            severityText: .info,
            body: "performance.focus.responder_change",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [:],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.focus.responder_change.reason": .string(reason)
            ]
        )
    }

    @Test("startup deferral keeps only bounded gate and outcome values")
    func startupDeferralKeepsBoundedValues() {
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 119,
                severityText: .info,
                body: "performance.startup.deferral",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.performance.startup.deferral.gate": .string("terminal_activation_release"),
                    "agentstudio.performance.startup.deferral.outcome": .string("cancelled"),
                    "agentstudio.performance.startup.deferral.detail": .string("private"),
                ]
            ))

        #expect(
            projection.attributes["agentstudio.performance.startup.deferral.gate"]
                == .string("terminal_activation_release"))
        #expect(
            projection.attributes["agentstudio.performance.startup.deferral.outcome"]
                == .string("cancelled"))
        #expect(projection.attributes["agentstudio.performance.startup.deferral.detail"] == nil)
    }

    @Test("startup usable keeps only bounded duration fields")
    func startupUsableKeepsSafeDurations() {
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 120,
                severityText: .info,
                body: "performance.startup.usable",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.performance.elapsed_ms": .double(125),
                    "agentstudio.performance.startup.layout_settle_to_usable_elapsed_ms": .double(8),
                    "agentstudio.performance.startup.source": .string("presented"),
                    "agentstudio.performance.startup.pane_id": .string("private"),
                ]
            ))

        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(125))
        #expect(
            projection.attributes["agentstudio.performance.startup.layout_settle_to_usable_elapsed_ms"]
                == .double(8))
        #expect(projection.attributes["agentstudio.performance.startup.pane_id"] == nil)
        #expect(projection.attributes["agentstudio.performance.startup.source"] == .string("presented"))
    }

    @Test("interaction latency keeps controlled kind and scrubs correlation id")
    func interactionLatencyKeepsKindAndScrubsCorrelationId() {
        let projection = AgentStudioOTLPTraceProjection.project(
            AgentStudioTraceRecord(
                timeUnixNano: 123,
                severityText: .info,
                body: "performance.interaction.latency",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: [:],
                scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                attributes: [
                    "agentstudio.performance.elapsed_ms": .double(4.5),
                    "agentstudio.performance.interaction.kind": .string("tab_move"),
                    "agentstudio.performance.interaction.correlation_id": .string(UUIDv7.generate().uuidString),
                ]
            ))

        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(4.5))
        #expect(projection.attributes["agentstudio.performance.interaction.kind"] == .string("tab_move"))
        #expect(projection.attributes["agentstudio.performance.interaction.correlation_id"] == nil)
    }

    @Test("pane-agent authorization time keeps its controlled outcome and drops anything else")
    func agentAuthorizationKeepsControlledOutcome() {
        func project(outcome: String) -> AgentStudioOTLPProjectedLogRecord {
            AgentStudioOTLPTraceProjection.project(
                AgentStudioTraceRecord(
                    timeUnixNano: 123,
                    severityText: .info,
                    body: "performance.ipc.agent_authorization",
                    traceID: nil,
                    spanID: nil,
                    parentSpanID: nil,
                    resource: [:],
                    scope: .init(name: "agentstudio.performance", version: "0.1.0"),
                    attributes: [
                        "agentstudio.performance.elapsed_ms": .double(0.2),
                        "agentstudio.performance.ipc.agent_authorization.outcome": .string(outcome),
                    ]
                ))
        }

        let refused = project(outcome: "refused_for_agent")
        let unexpected = project(outcome: UUIDv7.generate().uuidString)

        #expect(refused.attributes["agentstudio.performance.elapsed_ms"] == .double(0.2))
        #expect(
            refused.attributes["agentstudio.performance.ipc.agent_authorization.outcome"]
                == .string("refused_for_agent"))
        #expect(unexpected.attributes["agentstudio.performance.ipc.agent_authorization.outcome"] == nil)
    }

    @Test("app IPC start keeps its controlled unavailability reason and drops anything else")
    func appIPCStartKeepsControlledReason() {
        func project(reason: String) -> AgentStudioOTLPProjectedLogRecord {
            AgentStudioOTLPTraceProjection.project(
                AgentStudioTraceRecord(
                    timeUnixNano: 123,
                    severityText: .info,
                    body: "app.ipc.start",
                    traceID: nil,
                    spanID: nil,
                    parentSpanID: nil,
                    resource: [:],
                    scope: .init(name: "agentstudio.startup", version: "0.1.0"),
                    attributes: [
                        "agentstudio.app.startup.outcome": .string("unavailable"),
                        "agentstudio.app.ipc.start.reason": .string(reason),
                    ]
                ))
        }

        let sessions = project(reason: "sessions_ingestion_failed")
        let initializationCancelled = project(reason: "initialization_cancelled")
        let unexpected = project(reason: "/Users/example/.agentstudio/ipc")

        #expect(sessions.attributes["agentstudio.app.ipc.start.reason"] == .string("sessions_ingestion_failed"))
        #expect(sessions.attributes["agentstudio.app.startup.outcome"] == .string("unavailable"))
        #expect(
            initializationCancelled.attributes["agentstudio.app.ipc.start.reason"]
                == .string("initialization_cancelled"))
        #expect(unexpected.attributes["agentstudio.app.ipc.start.reason"] == nil)
    }

    @Test
    func performanceProjectionKeepsSafeNumericFieldsAndDropsUnsafeContext() {
        let worktreeID = UUID(uuidString: "6DE2BC87-AD1F-4271-96DD-7922D58612D5")!
        let record = performanceProjectionRecord(worktreeID: worktreeID)

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let renderedProjection = projection.renderedForCanaryAssertions()

        #expect(projection.body == "performance.git.status")
        #expect(projection.attributes["agent.proof.marker"] == .string("perf-proof"))
        #expect(projection.attributes["agentstudio.trace.tag"] == .string("performance"))
        #expect(projection.attributes["agentstudio.performance.git.running.count"] == .int(4))
        #expect(projection.attributes["agentstudio.performance.git.status.last_outcome"] == .string("timeout"))
        #expect(projection.attributes["agentstudio.performance.git.status.consecutive_failure.count"] == .int(2))
        #expect(projection.attributes["agentstudio.performance.git.status.duration_ms"] == .double(2.5))
        #expect(projection.attributes["agentstudio.performance.git.status.elapsed_ms"] == .double(2.7))
        #expect(projection.attributes["agentstudio.performance.git.status_unavailable.reason"] == .string("timeout"))
        #expect(projection.attributes["agentstudio.performance.git.root_path"] == nil)
        #expect(projection.attributes["agentstudio.performance.repo.dynamic_key.count"] == nil)
        #expect(projection.attributes["agentstudio.performance.future.elapsed_ms"] == nil)
        #expect(projection.attributes["agentstudio.performance.future.has_value"] == nil)
        #expect(projection.attributes["agentstudio.performance.atom.kind"] == .string("entity_map"))
        #expect(projection.attributes["agentstudio.performance.atom.label"] == .string("pane_graph_canonical"))
        #expect(projection.attributes["agentstudio.performance.atom.operation"] == .string("value"))
        #expect(projection.attributes["agentstudio.performance.atom.slot.count"] == .int(2))
        #expect(projection.attributes["agentstudio.performance.atom.cached_key.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.atom.cache_hit"] == .bool(false))
        #expect(projection.attributes["agentstudio.performance.coordinator.activity_write.count"] == .int(3))
        #expect(
            projection.attributes["agentstudio.performance.coordinator.filesystem_source_elapsed_ms"]
                == .double(4.5))
        #expect(projection.attributes["agentstudio.performance.coordinator.index_elapsed_ms"] == .double(5.5))
        #expect(projection.attributes["agentstudio.performance.coordinator.derived_input.count"] == .int(1))
        #expect(projection.attributes["agentstudio.performance.coordinator.input_revision.count"] == .int(7))
        #expect(
            projection.attributes["agentstudio.performance.coordinator.mainactor_apply_elapsed_ms"]
                == .double(0.5))
        #expect(projection.attributes["agentstudio.performance.coordinator.phase"] == .string("source_sync"))
        #expect(
            projection.attributes["agentstudio.performance.coordinator.skipped_unchanged_input.count"] == .int(1)
        )
        #expect(projection.attributes["agentstudio.performance.coordinator.total_elapsed_ms"] == .double(10.5))
        #expect(
            projection.attributes["agentstudio.performance.management_layer.command"]
                == .string("toggleManagementLayer"))
        #expect(projection.attributes["agentstudio.performance.note_text"] == nil)
        #expect(projection.attributes["agentstudio.performance.pane_action.name"] == .string("minimizePane"))
        #expect(projection.attributes["agentstudio.performance.sidebar.is_collapsed"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.sidebar.split_width"] == .double(1200))
        #expect(projection.attributes["agentstudio.performance.sidebar.toggle.intent"] == .string("collapse"))
        #expect(projection.attributes["agentstudio.performance.sidebar.was_collapsed"] == .bool(false))
        #expect(projection.attributes["agentstudio.performance.sidebar.width"] == .double(320))
        #expect(
            projection.attributes["agentstudio.performance.terminal.geometry.reason"]
                == .string("splitViewDidResizeSubviews"))
        #expect(projection.attributes["agentstudio.performance.terminal.geometry.visible_terminal.count"] == .double(7))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.cell_height_px"] == .double(28))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.cell_width_px"] == .double(14))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.column.count"] == .double(80))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.current_height_px"] == .double(780))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.current_width_px"] == .double(1200))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.dedup_likely"] == .bool(false))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.has_superview"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.has_window"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.hidden"] == .bool(false))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.requested_height_px"] == .double(800))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.requested_width_px"] == .double(1280))
        #expect(projection.attributes["agentstudio.performance.terminal.surface.row.count"] == .double(24))
        #expect(
            projection.attributes["agentstudio.performance.terminal.surface.source"]
                == .string("forceGeometrySync"))
        #expect(projection.attributes["agentstudio.worktree.id"] == nil)
        #expect(projection.attributes["agentstudio.performance.atom.key"] == nil)
        #expect(projection.attributes["agentstudio.performance.atom.value"] == nil)
        #expect(projection.resource["process.pid"] == nil)
        #expect(!renderedProjection.contains("/Users/shravan"))
        #expect(!renderedProjection.contains(worktreeID.uuidString))
    }

    @Test
    func runtimePressureProjectionKeepsMemoryGauges() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 601,
            severityText: .info,
            body: "performance.process.malloc_zone",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.process.malloc.blocks_in_use": .int(7),
                "agentstudio.performance.process.malloc.size_in_use_bytes": .int(11),
                "agentstudio.performance.process.malloc.maximum_size_in_use_bytes": .int(13),
                "agentstudio.performance.process.malloc.size_allocated_bytes": .int(17),
                "agentstudio.performance.private_payload": .string("do not export"),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)

        #expect(projection.attributes["agentstudio.performance.process.malloc.blocks_in_use"] == .int(7))
        #expect(projection.attributes["agentstudio.performance.process.malloc.size_in_use_bytes"] == .int(11))
        #expect(
            projection.attributes["agentstudio.performance.process.malloc.maximum_size_in_use_bytes"] == .int(13))
        #expect(projection.attributes["agentstudio.performance.process.malloc.size_allocated_bytes"] == .int(17))
        #expect(projection.attributes["agentstudio.performance.private_payload"] == nil)
    }

    @Test
    func tabBarProjectionKeepsAggregateFactsAndDropsIdentityAndPayloadContext() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 602,
            severityText: .info,
            body: "performance.tabbar.terminal",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.tabbar.sequence": .int(17),
                "agentstudio.performance.tabbar.tab.count": .int(3),
                "agentstudio.performance.tabbar.pane.count": .int(8),
                "agentstudio.performance.tabbar.terminal.outcome": .string("published"),
                "agentstudio.performance.tabbar.active_tab.present": .bool(true),
                "agentstudio.performance.tabbar.queue_wait_ms": .double(12.5),
                "agentstudio.performance.tabbar.mainactor_held_ms": .double(0.75),
                "agentstudio.performance.trace_queue.dropped_record.count": .int(0),
                "agentstudio.performance.trace_queue.high_watermark": .int(7),
                "agentstudio.performance.trace_queue.pending_request.count": .int(3),
                "agentstudio.performance.tabbar.tab.id": .string("01987654-3210-7abc-8def-0123456789ab"),
                "agentstudio.performance.tabbar.title": .string("private title"),
                "agentstudio.performance.tabbar.path": .string("/Users/private/repository"),
                "agentstudio.performance.tabbar.request": .string("private request"),
                "agentstudio.performance.tabbar.notification.body": .string("private body"),
            ]
        )
        let invalidOutcomeRecord = AgentStudioTraceRecord(
            timeUnixNano: 603,
            severityText: .info,
            body: "performance.tabbar.terminal",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.tabbar.terminal.outcome": .string("private-dynamic-value")
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let invalidOutcomeProjection = AgentStudioOTLPTraceProjection.project(invalidOutcomeRecord)

        #expect(projection.attributes["agentstudio.performance.tabbar.sequence"] == .int(17))
        #expect(projection.attributes["agentstudio.performance.tabbar.tab.count"] == .int(3))
        #expect(projection.attributes["agentstudio.performance.tabbar.pane.count"] == .int(8))
        #expect(
            projection.attributes["agentstudio.performance.tabbar.terminal.outcome"]
                == .string("published")
        )
        #expect(projection.attributes["agentstudio.performance.tabbar.active_tab.present"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.tabbar.queue_wait_ms"] == .double(12.5))
        #expect(projection.attributes["agentstudio.performance.tabbar.mainactor_held_ms"] == .double(0.75))
        #expect(
            projection.attributes["agentstudio.performance.trace_queue.dropped_record.count"] == .int(0)
        )
        #expect(projection.attributes["agentstudio.performance.trace_queue.high_watermark"] == .int(7))
        #expect(
            projection.attributes["agentstudio.performance.trace_queue.pending_request.count"] == .int(3)
        )
        #expect(projection.attributes["agentstudio.performance.tabbar.tab.id"] == nil)
        #expect(projection.attributes["agentstudio.performance.tabbar.title"] == nil)
        #expect(projection.attributes["agentstudio.performance.tabbar.path"] == nil)
        #expect(projection.attributes["agentstudio.performance.tabbar.request"] == nil)
        #expect(projection.attributes["agentstudio.performance.tabbar.notification.body"] == nil)
        #expect(
            invalidOutcomeProjection.attributes["agentstudio.performance.tabbar.terminal.outcome"] == nil
        )
    }

    @Test
    func tabBarContextMenuProjectionKeepsOnlyLowCardinalityInputFacts() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 604,
            severityText: .info,
            body: "performance.tabbar.context_menu",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.tabbar.context_menu.phase": .string("input"),
                "agentstudio.performance.tabbar.context_menu.host_hit": .bool(true),
                "agentstudio.performance.tabbar.context_menu.tab_hit": .bool(true),
                "agentstudio.performance.tabbar.context_menu.hit_view_class": .string("swiftui"),
                "agentstudio.performance.tabbar.context_menu.static_menu_available": .bool(false),
                "agentstudio.performance.tabbar.context_menu.tab_id": .string(
                    "01987654-3210-7abc-8def-0123456789ab"
                ),
            ]
        )
        let rawClassRecord = AgentStudioTraceRecord(
            timeUnixNano: 605,
            severityText: .info,
            body: "performance.tabbar.context_menu",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.tabbar.context_menu.hit_view_class": .string(
                    "SwiftUI._NSHostingView"
                )
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)
        let rawClassProjection = AgentStudioOTLPTraceProjection.project(rawClassRecord)

        #expect(
            projection.attributes["agentstudio.performance.tabbar.context_menu.phase"]
                == .string("input")
        )
        #expect(projection.attributes["agentstudio.performance.tabbar.context_menu.host_hit"] == .bool(true))
        #expect(projection.attributes["agentstudio.performance.tabbar.context_menu.tab_hit"] == .bool(true))
        #expect(
            projection.attributes["agentstudio.performance.tabbar.context_menu.hit_view_class"]
                == .string("swiftui")
        )
        #expect(
            projection.attributes["agentstudio.performance.tabbar.context_menu.static_menu_available"]
                == .bool(false)
        )
        #expect(projection.attributes["agentstudio.performance.tabbar.context_menu.tab_id"] == nil)
        #expect(
            rawClassProjection.attributes["agentstudio.performance.tabbar.context_menu.hit_view_class"] == nil
        )
    }

    @Test
    func tabBarPaneDropProjectionKeepsBoundedIngressFacts() {
        let record = AgentStudioTraceRecord(
            timeUnixNano: 606,
            severityText: .info,
            body: "performance.tabbar.pane_drop",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.tabbar.pane_drop.phase": .string("commit"),
                "agentstudio.performance.tabbar.pane_drop.outcome": .string("rejected"),
                "agentstudio.performance.tabbar.pane_drop.reason": .string("target_unresolved"),
                "agentstudio.performance.management_layer.is_active": .bool(true),
                "agentstudio.performance.tabbar.pane_drop.target_resolved": .bool(false),
                "agentstudio.performance.tabbar.pane_drop.frame.count": .int(2),
                "agentstudio.performance.tabbar.tab.count": .int(3),
                "agentstudio.performance.tabbar.pane_drop.pane_id": .string(
                    "01987654-3210-7abc-8def-0123456789ab"
                ),
                "agentstudio.performance.tabbar.pane_drop.pointer_x": .double(42),
                "agentstudio.performance.tabbar.pane_drop.path": .string("/private/example"),
            ]
        )

        let projection = AgentStudioOTLPTraceProjection.project(record)

        #expect(
            projection.attributes["agentstudio.performance.tabbar.pane_drop.phase"]
                == .string("commit")
        )
        #expect(
            projection.attributes["agentstudio.performance.tabbar.pane_drop.outcome"]
                == .string("rejected")
        )
        #expect(
            projection.attributes["agentstudio.performance.tabbar.pane_drop.reason"]
                == .string("target_unresolved")
        )
        #expect(
            projection.attributes["agentstudio.performance.management_layer.is_active"]
                == .bool(true)
        )
        #expect(
            projection.attributes["agentstudio.performance.tabbar.pane_drop.target_resolved"]
                == .bool(false)
        )
        #expect(
            projection.attributes["agentstudio.performance.tabbar.pane_drop.frame.count"] == .int(2)
        )
        #expect(projection.attributes["agentstudio.performance.tabbar.tab.count"] == .int(3))
        #expect(projection.attributes["agentstudio.performance.tabbar.pane_drop.pane_id"] == nil)
        #expect(projection.attributes["agentstudio.performance.tabbar.pane_drop.pointer_x"] == nil)
        #expect(projection.attributes["agentstudio.performance.tabbar.pane_drop.path"] == nil)
    }

    private func performanceProjectionRecord(worktreeID: UUID) -> AgentStudioTraceRecord {
        AgentStudioTraceRecord(
            timeUnixNano: 600,
            severityText: .info,
            body: "performance.git.status",
            traceID: "trace-should-not-export",
            spanID: "span-should-not-export",
            parentSpanID: nil,
            resource: [
                "agent.proof.marker": "perf-proof",
                "process.pid": "12345",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.running.count": .int(4),
                "agentstudio.performance.git.status.last_outcome": .string("timeout"),
                "agentstudio.performance.git.status.consecutive_failure.count": .int(2),
                "agentstudio.performance.git.status.duration_ms": .double(2.5),
                "agentstudio.performance.git.status.elapsed_ms": .double(2.7),
                "agentstudio.performance.git.status_unavailable.reason": .string("timeout"),
                "agentstudio.performance.git.root_path": .string("/Users/shravan/private/repo"),
                "agentstudio.performance.repo.dynamic_key.count": .int(999),
                "agentstudio.performance.future.elapsed_ms": .double(999),
                "agentstudio.performance.future.has_value": .bool(true),
                "agentstudio.performance.atom.kind": .string("entity_map"),
                "agentstudio.performance.atom.label": .string("pane_graph_canonical"),
                "agentstudio.performance.atom.key": .string("private-pane-key"),
                "agentstudio.performance.atom.value": .string("private-pane-value"),
                "agentstudio.performance.atom.operation": .string("value"),
                "agentstudio.performance.atom.slot.count": .int(2),
                "agentstudio.performance.atom.cached_key.count": .int(1),
                "agentstudio.performance.atom.cache_hit": .bool(false),
                "agentstudio.performance.coordinator.activity_write.count": .int(3),
                "agentstudio.performance.coordinator.filesystem_source_elapsed_ms": .double(4.5),
                "agentstudio.performance.coordinator.index_elapsed_ms": .double(5.5),
                "agentstudio.performance.coordinator.derived_input.count": .int(1),
                "agentstudio.performance.coordinator.input_revision.count": .int(7),
                "agentstudio.performance.coordinator.mainactor_apply_elapsed_ms": .double(0.5),
                "agentstudio.performance.coordinator.phase": .string("source_sync"),
                "agentstudio.performance.coordinator.skipped_unchanged_input.count": .int(1),
                "agentstudio.performance.coordinator.total_elapsed_ms": .double(10.5),
                "agentstudio.performance.management_layer.command": .string("toggleManagementLayer"),
                "agentstudio.performance.note_text": .string("raw payload should stay local"),
                "agentstudio.performance.pane_action.name": .string("minimizePane"),
                "agentstudio.performance.sidebar.is_collapsed": .bool(true),
                "agentstudio.performance.sidebar.split_width": .double(1200),
                "agentstudio.performance.sidebar.toggle.intent": .string("collapse"),
                "agentstudio.performance.sidebar.was_collapsed": .bool(false),
                "agentstudio.performance.sidebar.width": .double(320),
                "agentstudio.performance.terminal.geometry.reason": .string("splitViewDidResizeSubviews"),
                "agentstudio.performance.terminal.geometry.visible_terminal.count": .double(7),
                "agentstudio.performance.terminal.surface.cell_height_px": .double(28),
                "agentstudio.performance.terminal.surface.cell_width_px": .double(14),
                "agentstudio.performance.terminal.surface.column.count": .double(80),
                "agentstudio.performance.terminal.surface.current_height_px": .double(780),
                "agentstudio.performance.terminal.surface.current_width_px": .double(1200),
                "agentstudio.performance.terminal.surface.dedup_likely": .bool(false),
                "agentstudio.performance.terminal.surface.has_superview": .bool(true),
                "agentstudio.performance.terminal.surface.has_window": .bool(true),
                "agentstudio.performance.terminal.surface.hidden": .bool(false),
                "agentstudio.performance.terminal.surface.requested_height_px": .double(800),
                "agentstudio.performance.terminal.surface.requested_width_px": .double(1280),
                "agentstudio.performance.terminal.surface.row.count": .double(24),
                "agentstudio.performance.terminal.surface.source": .string("forceGeometrySync"),
                "agentstudio.trace.tag": .string("performance"),
                "agentstudio.worktree.id": .string(worktreeID.uuidString),
            ]
        )
    }

}
