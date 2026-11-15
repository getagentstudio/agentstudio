import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPRecordedAttributeTests {

    @Test("persistence reasons retain recorded values and retain recorded sentinels")
    func persistenceReasonProjectionRetainsRecordedReasons() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteTraceRecorder.swift:210: SQLite recorder owns diagnostic fields, not agent message recording.
        let allowedReasons = [
            "topology_restore_main_role_repaired",
            "topology_restore_missing_main_degraded",
            "topology_scan_main_repaired",
            "topology_boot_normalization_flush_failed",
            "topology_normalization_rejected",
            "pane_location_restore_repaired",
            "pane_location_restore_degraded",
            "workspace_save_composition_rejected",
            "workspace_save_bridge_failed",
            "workspace_save_database_failed",
            "pane_topology_association_ambiguous",
        ]
        let rejectedReasons = [
            "/Users/private/repository",
            "019be3be-7c00-7000-8000-000000000099",
            "SQLite error: database locked",
            "arbitrary_payload",
        ]

        for reason in allowedReasons + rejectedReasons {
            let record = AgentStudioTraceRecord(
                timeUnixNano: 199,
                severityText: .info,
                body: "persistence.reason",
                traceID: nil,
                spanID: nil,
                parentSpanID: nil,
                resource: ["service.name": "AgentStudio"],
                scope: .init(name: "agentstudio.persistence.operation", version: "0.1.0"),
                attributes: [
                    "agentstudio.persistence.reason": .string(reason),
                    "agentstudio.trace.tag": .string("persistence.operation"),
                ]
            )

            let projection = OTLPProjectionAssertions.project(record)

            if allowedReasons.contains(reason) {
                #expect(projection.attributes["agentstudio.persistence.reason"] == .string(reason))
            } else {
                #expect(projection.attributes["agentstudio.persistence.reason"] != nil)
            }
        }
    }

    @Test
    func persistenceProjectionRetainsPathsWorkspaceIDsAndRawErrors() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Core/State/SQLite/WorkspaceSQLiteTraceRecorder.swift:210: SQLite recorder owns diagnostic fields, not agent message recording.
        let workspaceID = UUID(uuidString: "F6ADCB1B-E191-4890-963E-37F4A694B065")!
        let record = AgentStudioTraceRecord(
            timeUnixNano: 200,
            severityText: .error,
            body: "persistence.recovery",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.persistence.recovery", version: "0.1.0"),
            attributes: [
                "agentstudio.persistence.backend": .string("sqlite"),
                "agentstudio.persistence.classification": .string("corrupt_database"),
                "agentstudio.persistence.disposition": .string("local_available"),
                "agentstudio.persistence.error.description": .string(
                    "SQLite failed at /Users/shravan/private/core.sqlite"
                ),
                "agentstudio.persistence.lane": .string("local"),
                "agentstudio.persistence.operation": .string("workspace.load"),
                "agentstudio.persistence.outcome": .string("quarantined"),
                "agentstudio.persistence.phase": .string("quarantine_sidecars"),
                "agentstudio.persistence.recovery.attempt": .string("quarantine_and_replace"),
                "agentstudio.persistence.recovery.kind": .string("local_quarantine"),
                "agentstudio.sqlite.database": .string("local"),
                "agentstudio.sqlite.database_path": .string("~/Library/Application Support/AgentStudio/core.sqlite"),
                "agentstudio.sqlite.result_code": .int(26),
                "agentstudio.trace.tag": .string("persistence.recovery"),
                "agentstudio.workspace.id": .string(workspaceID.uuidString),
                "agentstudio.workspace.snapshot.has_tab_membership_mismatch": .bool(true),
                "agentstudio.workspace.snapshot.pane_count": .int(2),
                "agentstudio.workspace.snapshot.tab_membership_mismatches": .stringArray([workspaceID.uuidString]),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.persistence.backend"] == .string("sqlite"))
        #expect(projection.attributes["agentstudio.persistence.classification"] == .string("corrupt_database"))
        #expect(projection.attributes["agentstudio.persistence.disposition"] == .string("local_available"))
        #expect(
            projection.attributes["agentstudio.persistence.recovery.attempt"]
                == .string("quarantine_and_replace")
        )
        #expect(projection.attributes["agentstudio.persistence.recovery.kind"] == .string("local_quarantine"))
        #expect(projection.attributes["agentstudio.sqlite.result_code"] == .int(26))
        #expect(projection.attributes["agentstudio.workspace.snapshot.has_tab_membership_mismatch"] == .bool(true))
        #expect(projection.attributes["agentstudio.workspace.snapshot.pane_count"] == .int(2))
        #expect(projection.attributes["agentstudio.workspace.id"] != nil)
        #expect(projection.attributes["agentstudio.sqlite.database_path"] != nil)
        #expect(projection.attributes["agentstudio.persistence.error.description"] != nil)
        #expect(projection.attributes["agentstudio.workspace.snapshot.tab_membership_mismatches"] != nil)
    }

    @Test
    func terminalProjectionRetainsPaneSurfaceZmxAndRawFailureDetails() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioPerformanceTraceRecorder.swift:660: terminal performance emits counts/durations, never terminal output text.
        let paneID = UUID(uuidString: "E568C446-9E0F-445B-95C9-382AE44915D5")!
        let surfaceID = UUID(uuidString: "D2C553E9-31C1-4A9C-9DD4-2D5255B8EEC3")!
        let record = AgentStudioTraceRecord(
            timeUnixNano: 300,
            severityText: .warn,
            body: "terminal.startup.surface_create_failed",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.terminal.startup", version: "0.1.0"),
            attributes: [
                "agentstudio.app.is_active": .bool(false),
                "agentstudio.display.count": .int(2),
                "agentstudio.ghostty.surface.environment_variable_count": .int(4),
                "agentstudio.ghostty.surface.initial_frame_height": .double(700),
                "agentstudio.ghostty.surface.initial_frame_width": .double(1100),
                "agentstudio.ghostty.surface.startup_command_present": .bool(true),
                "agentstudio.pane.id": .string(paneID.uuidString),
                "agentstudio.surface.id": .string(surfaceID.uuidString),
                "agentstudio.terminal.startup.error": .string("Failed after command output: secret prompt"),
                "agentstudio.terminal.startup.failure.creation_retry.count": .int(2),
                "agentstudio.terminal.startup.failure.kind": .string("creation_failed"),
                "agentstudio.terminal.startup.operation_id": .string(UUID().uuidString),
                "agentstudio.terminal.startup.outcome": .string("failed"),
                "agentstudio.terminal.startup.phase": .string("surface_create_failed"),
                "agentstudio.trace.tag": .string("terminal.startup"),
                "agentstudio.zmx.session_id": .string("zmx-private-session"),
                "agentstudio.zmx.socket_path_headroom": .int(-2),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.terminal.startup.phase"] == .string("surface_create_failed"))
        #expect(projection.attributes["agentstudio.terminal.startup.outcome"] == .string("failed"))
        #expect(projection.attributes["agentstudio.terminal.startup.failure.kind"] == .string("creation_failed"))
        #expect(projection.attributes["agentstudio.terminal.startup.failure.creation_retry.count"] == .int(2))
        #expect(projection.attributes["agentstudio.app.is_active"] == .bool(false))
        #expect(projection.attributes["agentstudio.display.count"] == .int(2))
        #expect(projection.attributes["agentstudio.ghostty.surface.environment_variable_count"] == .int(4))
        #expect(projection.attributes["agentstudio.ghostty.surface.initial_frame_height"] == .double(700))
        #expect(projection.attributes["agentstudio.ghostty.surface.initial_frame_width"] == .double(1100))
        #expect(projection.attributes["agentstudio.ghostty.surface.startup_command_present"] == .bool(true))
        #expect(projection.attributes["agentstudio.zmx.socket_path_headroom"] == .int(-2))
        #expect(projection.attributes["agentstudio.pane.id"] != nil)
        #expect(projection.attributes["agentstudio.surface.id"] != nil)
        #expect(projection.attributes["agentstudio.terminal.startup.error"] != nil)
        #expect(projection.attributes["agentstudio.terminal.startup.operation_id"] != nil)
        #expect(projection.attributes["agentstudio.zmx.session_id"] != nil)
    }

    @Test
    func terminalActivityProjectionKeepsAgentHeuristicEvidenceAndRetainsPaneIdentity() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Terminal/Routing/TerminalActivityRouter.swift:518; activity tracing records event identity, never terminal output text.
        let paneID = UUID(uuidString: "B25FE4D0-67D6-495B-A93F-8E9E6FF311DD")!
        let record = AgentStudioTraceRecord(
            timeUnixNano: 325,
            severityText: .info,
            body: "terminal.activity.unseenWindowClosed",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "agent.proof.marker": "terminal-agent-settled-proof",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.terminal.activity", version: "0.1.0"),
            attributes: [
                "agentstudio.pane.id": .string(paneID.uuidString),
                "agentstudio.trace.tag": .string("terminal.activity"),
                "terminal.activity.baseline_rows": .int(100),
                "terminal.activity.close_reason": .string("quiet"),
                "terminal.activity.debounce_ms": .int(180_000),
                "terminal.activity.duration_ms": .int(61_000),
                "terminal.activity.event_count": .int(2),
                "terminal.activity.is_agent_candidate": .bool(true),
                "terminal.activity.is_agent_settled_candidate": .bool(true),
                "terminal.activity.is_inferred": .bool(true),
                "terminal.activity.is_pinned_to_bottom": .bool(false),
                "terminal.activity.latest_rows": .int(700),
                "terminal.activity.rows_added": .int(600),
                "terminal.activity.source": .string("scrollbar"),
                "terminal.activity.threshold_rows": .int(30),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.trace.tag"] == .string("terminal.activity"))
        #expect(projection.attributes["terminal.activity.close_reason"] == .string("quiet"))
        #expect(projection.attributes["terminal.activity.is_agent_candidate"] == .bool(true))
        #expect(projection.attributes["terminal.activity.is_agent_settled_candidate"] == .bool(true))
        #expect(projection.attributes["terminal.activity.rows_added"] == .int(600))
        #expect(projection.attributes["agentstudio.pane.id"] != nil)
    }

    @Test
    func terminalSignalProjectionKeepsControlledSignalFieldsAndRetainsRawPayloadAndIDs() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionRouter+Tracing.swift:107: signal tracing strips payload associated values, never notification text.
        let paneID = UUID(uuidString: "1A84D2E8-4177-4D6B-8360-2BAA4C08654A")!
        let surfaceID = UUID(uuidString: "7F609C1D-B01C-4D9B-B8D7-BC566B42716F")!
        let record = AgentStudioTraceRecord(
            timeUnixNano: 350,
            severityText: .info,
            body: "ghostty.action.translated",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "agent.proof.marker": "terminal-signal-proof",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.terminal.signal", version: "0.1.0"),
            attributes: [
                "agentstudio.ghostty.action.name": .string("desktopNotification"),
                "agentstudio.ghostty.action.payload": .string("desktopNotification"),
                "agentstudio.ghostty.action.tag": .int(25),
                "agentstudio.ghostty.route.reason": .string("runtime_event_delivered"),
                "agentstudio.ghostty.route.result": .bool(true),
                "agentstudio.ghostty.signal.class": .string("semantic"),
                "agentstudio.pane.id": .string(paneID.uuidString),
                "agentstudio.runtime.event": .string("terminal.desktopNotificationRequested"),
                "agentstudio.surface.id": .string(surfaceID.uuidString),
                "agentstudio.trace.tag": .string("terminal.signal"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.trace.tag"] == .string("terminal.signal"))
        #expect(projection.attributes["agentstudio.ghostty.action.name"] == .string("desktopNotification"))
        #expect(projection.attributes["agentstudio.ghostty.action.tag"] == .int(25))
        #expect(projection.attributes["agentstudio.ghostty.route.reason"] == .string("runtime_event_delivered"))
        #expect(projection.attributes["agentstudio.ghostty.route.result"] == .bool(true))
        #expect(projection.attributes["agentstudio.ghostty.signal.class"] == .string("semantic"))
        #expect(projection.attributes["agentstudio.runtime.event"] == .string("terminal.desktopNotificationRequested"))
        #expect(projection.attributes["agentstudio.ghostty.action.payload"] != nil)
        #expect(projection.attributes["agentstudio.pane.id"] != nil)
        #expect(projection.attributes["agentstudio.surface.id"] != nil)
    }

    @Test
    func notificationProjectionKeepsRoutingEvidenceAndRetainsNotificationIdentity() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/InboxNotification/Routing/InboxNotificationRouter.swift:455: notification tracing emits identity/routing facts, never notification text.
        let notificationID = UUID(uuidString: "55461083-7987-4CA6-982E-1D0BB15AF2E1")!
        let sessionID = UUID(uuidString: "13955374-46E1-43B8-AD8E-D60F1F59631A")!
        let record = AgentStudioTraceRecord(
            timeUnixNano: 375,
            severityText: .info,
            body: "inbox.notification.appended",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "agent.proof.marker": "inbox-proof",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.inbox", version: "0.1.0"),
            attributes: [
                "agentstudio.inbox.claim.lane": .string("pane"),
                "agentstudio.inbox.claim.semantic": .string("activity"),
                "agentstudio.inbox.claim.session_id": .string(sessionID.uuidString),
                "agentstudio.inbox.decision": .string("promote"),
                "agentstudio.inbox.global_unread_after": .int(3),
                "agentstudio.inbox.global_unread_before": .int(2),
                "agentstudio.inbox.global_unread_count": .int(3),
                "agentstudio.inbox.kind": .string("unseenActivity"),
                "agentstudio.inbox.notification.coalesced": .bool(true),
                "agentstudio.inbox.notification.id": .string(notificationID.uuidString),
                "agentstudio.inbox.notification.revoked": .bool(true),
                "agentstudio.inbox.reason": .string("unattended_pane"),
                "agentstudio.pane.attended": .bool(false),
                "agentstudio.pane.observed": .bool(false),
                "agentstudio.pane.pinned_to_bottom": .bool(true),
                "agentstudio.pane_inbox.cleared_count": .int(1),
                "agentstudio.pane_inbox.dismissed": .bool(true),
                "agentstudio.pane_inbox.keep_count": .int(2),
                "agentstudio.trace.tag": .string("inbox"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.inbox.claim.lane"] == .string("pane"))
        #expect(projection.attributes["agentstudio.inbox.claim.semantic"] == .string("activity"))
        #expect(projection.attributes["agentstudio.inbox.decision"] == .string("promote"))
        #expect(projection.attributes["agentstudio.inbox.global_unread_after"] == .int(3))
        #expect(projection.attributes["agentstudio.inbox.global_unread_before"] == .int(2))
        #expect(projection.attributes["agentstudio.inbox.global_unread_count"] == .int(3))
        #expect(projection.attributes["agentstudio.inbox.kind"] == .string("unseenActivity"))
        #expect(projection.attributes["agentstudio.inbox.notification.coalesced"] == .bool(true))
        #expect(projection.attributes["agentstudio.inbox.notification.revoked"] == .bool(true))
        #expect(projection.attributes["agentstudio.inbox.reason"] == .string("unattended_pane"))
        #expect(projection.attributes["agentstudio.pane.attended"] == .bool(false))
        #expect(projection.attributes["agentstudio.pane.observed"] == .bool(false))
        #expect(projection.attributes["agentstudio.pane.pinned_to_bottom"] == .bool(true))
        #expect(projection.attributes["agentstudio.pane_inbox.cleared_count"] == .int(1))
        #expect(projection.attributes["agentstudio.pane_inbox.dismissed"] == .bool(true))
        #expect(projection.attributes["agentstudio.pane_inbox.keep_count"] == .int(2))
        #expect(projection.attributes["agentstudio.inbox.claim.session_id"] != nil)
        #expect(projection.attributes["agentstudio.inbox.notification.id"] != nil)
    }

    @Test
    func unsafeBodyFallsBackAndSafeIdentityKeysRemainAllowed() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Terminal/Routing/TerminalActivityRouter.swift:518; runtime tracing records event identity, never terminal output text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 400,
            severityText: .info,
            body: "raw output from /Users/shravan/private/project",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "dev.repo.hash": "repo-hash",
                "dev.repo.name": "agent-studio",
                "dev.worktree.hash": "worktree-hash",
                "dev.branch.name": "feature/otel",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.runtime", version: "0.1.0"),
            attributes: [
                "agentstudio.runtime.event": .string("session_state_changed"),
                "agentstudio.runtime.output": .string("raw output from /Users/shravan/private/project"),
                "agentstudio.trace.tag": .string("runtime"),
                "dev.runtime.flavor": .string("debug"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "agentstudio.trace.record")
        #expect(projection.resource["dev.repo.hash"] == "repo-hash")
        #expect(projection.resource["dev.repo.name"] == nil)
        #expect(projection.resource["dev.worktree.hash"] == "worktree-hash")
        #expect(projection.resource["dev.branch.name"] == "feature/otel")
        #expect(projection.attributes["dev.repo.hash"] == .string("repo-hash"))
        #expect(projection.attributes["dev.worktree.hash"] == .string("worktree-hash"))
        #expect(projection.attributes["dev.branch.name"] == .string("feature/otel"))
        #expect(projection.attributes["agentstudio.runtime.event"] == .string("session_state_changed"))
        #expect(projection.attributes["dev.runtime.flavor"] == .string("debug"))
        #expect(projection.attributes["agentstudio.runtime.output"] != nil)
    }

    @Test
    func safeResourceIdentityIsCopiedToPerRecordAttributesForLogStreaming() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/Terminal/Routing/TerminalActivityRouter.swift:518; runtime tracing records event identity, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 500,
            severityText: .info,
            body: "runtime.worktree",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "agentstudio.release_channel": "beta",
                "agentstudio.runtime_flavor": "beta",
                "agent.proof.launch": "launch-token-456",
                "agent.proof.marker": "beta-observability-456",
                "dev.release.channel": "beta",
                "dev.repo.hash": "repo-hash",
                "dev.repo.name": "agent-studio",
                "dev.runtime.flavor": "beta",
                "dev.worktree.hash": "worktree-hash",
                "dev.branch.name": "feature/otel",
                "service.name": "AgentStudio",
                "service.version": "0.0.54-beta.15",
            ],
            scope: .init(name: "agentstudio.runtime", version: "0.1.0"),
            attributes: [
                "agentstudio.runtime.event": .string("worktree_recorded")
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.resource["agent.proof.marker"] == "beta-observability-456")
        #expect(projection.resource["agent.proof.launch"] == "launch-token-456")
        #expect(projection.resource["dev.repo.hash"] == "repo-hash")
        #expect(projection.resource["dev.worktree.hash"] == "worktree-hash")
        #expect(projection.resource["dev.branch.name"] == "feature/otel")
        #expect(projection.attributes["agentstudio.event.time_unix_nano"] == .int(500))
        #expect(projection.attributes["agentstudio.release_channel"] == .string("beta"))
        #expect(projection.attributes["agentstudio.runtime_flavor"] == .string("beta"))
        #expect(projection.attributes["agent.proof.marker"] == .string("beta-observability-456"))
        #expect(projection.attributes["agent.proof.launch"] == .string("launch-token-456"))
        #expect(projection.attributes["dev.release.channel"] == .string("beta"))
        #expect(projection.attributes["dev.repo.hash"] == .string("repo-hash"))
        #expect(projection.attributes["dev.repo.name"] == nil)
        #expect(projection.attributes["dev.runtime.flavor"] == .string("beta"))
        #expect(projection.attributes["dev.worktree.hash"] == .string("worktree-hash"))
        #expect(projection.attributes["dev.branch.name"] == .string("feature/otel"))
        #expect(projection.attributes["service.version"] == .string("0.0.54-beta.15"))
        #expect(projection.attributes["service.name"] == nil)
    }

}
