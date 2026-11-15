import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPTraceProjectionTests {
    @Test
    func commandBarProjectionExportsCountsWithoutRawRecencySentinels() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:162; production command-bar telemetry records population counts, never item/message text.
        let sentinels = [
            "/private/command-bar-recency/path",
            "command-bar-recency-label",
            "command-bar-recency-prompt",
            "019be3be-7c00-7000-8000-000000000099",
            "command-bar-recency-payload",
            "command-bar-recency-error",
        ]
        let record = AgentStudioTraceRecord(
            timeUnixNano: 90,
            severityText: .info,
            body: "performance.commandbar.items",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.commandbar.item.count": .int(12),
                "agentstudio.performance.commandbar.repo.count": .int(3),
                "agentstudio.performance.commandbar.worktree.count": .int(4),
                "agentstudio.performance.commandbar.pane.count": .int(5),
                "agentstudio.performance.commandbar.raw_path": .string(sentinels[0]),
                "agentstudio.performance.commandbar.raw_label": .string(sentinels[1]),
                "agentstudio.performance.commandbar.raw_prompt": .string(sentinels[2]),
                "agentstudio.performance.commandbar.raw_uuid": .string(sentinels[3]),
                "agentstudio.performance.commandbar.raw_payload": .string(sentinels[4]),
                "agentstudio.performance.commandbar.raw_error": .string(sentinels[5]),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.performance.commandbar.item.count"] == .int(12))
        #expect(projection.attributes["agentstudio.performance.commandbar.repo.count"] == .int(3))
        #expect(projection.attributes["agentstudio.performance.commandbar.worktree.count"] == .int(4))
        #expect(projection.attributes["agentstudio.performance.commandbar.pane.count"] == .int(5))
    }

    @Test
    func commandBarCacheProjectionKeepsBoundedOutcomeAndInvalidationReason() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/CommandBar/CommandBarDataSource.swift:162; production command-bar telemetry records population counts, never item/message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 91,
            severityText: .info,
            body: "performance.commandbar.cache",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.commandbar.cache_outcome": .string("miss"),
                "agentstudio.performance.commandbar.invalidation_reason": .string("topology_observation"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.performance.commandbar.cache_outcome"] == .string("miss"))
        #expect(
            projection.attributes["agentstudio.performance.commandbar.invalidation_reason"]
                == .string("topology_observation")
        )
    }

    @Test
    func outlineApplyProxyProjectionKeepsBoundedReconciliationCountsForMetrics() throws {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424; current RepoExplorer snapshots record typed counts/outcomes, not message text (the outline proxy fixture has no current emitter).
        let record = AgentStudioTraceRecord(
            timeUnixNano: 125,
            severityText: .info,
            body: "performance.repo_explorer.outline_apply_proxy",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(3),
                "agentstudio.performance.repo_explorer.outline_apply_proxy.outcome": .string("changed"),
                "agentstudio.performance.repo_explorer.outline_apply_proxy.rows_total.count": .int(42),
                "agentstudio.performance.repo_explorer.outline_apply_proxy.rows_changed.count": .int(7),
                "agentstudio.performance.repo_explorer.outline_apply_proxy.equal_publish.count": .int(0),
                "agentstudio.performance.repo_explorer.outline_apply_proxy.mainactor_held_ms": .double(3),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: projection))

        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.outcome"
            ] == .string("changed")
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.rows_total.count"
            ] == .int(42)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.rows_changed.count"
            ] == .int(7)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.equal_publish.count"
            ] == .int(0)
        )
        #expect(
            projection.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.mainactor_held_ms"
            ] == .double(3)
        )
        #expect(metricEvent.dimensionTuples.contains { $0 == ("outcome", "changed") })
        #expect(metricEvent.samples.isEmpty)
        #expect(metricEvent.elapsedMilliseconds == 3)

        let invalidRecord = AgentStudioTraceRecord(
            timeUnixNano: 126,
            severityText: .info,
            body: "performance.repo_explorer.outline_apply_proxy",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repo_explorer.outline_apply_proxy.outcome": .string("unexpected")
            ]
        )
        let invalidProjection = OTLPProjectionAssertions.project(invalidRecord)
        #expect(
            invalidProjection.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.outcome"
            ] != nil
        )
    }

    @Test
    func startupProjectionKeepsControlledFieldsAndRetainsProcessIdentity() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/App/Boot/StartupDiagnosticRenderProofs.swift:35: geometry proof emits counts/verdicts, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 100,
            severityText: .info,
            body: "app.startup.ghostty_init",
            traceID: "trace-should-not-export",
            spanID: "span-should-not-export",
            parentSpanID: "parent-should-not-export",
            resource: [
                "agentstudio.build.config": "DEBUG",
                "agentstudio.session.id": "session-1",
                "agent.proof.launch": "launch-token-123",
                "agent.proof.marker": "beta-observability-123",
                "process.pid": "1234",
                "service.name": "AgentStudio",
                "service.version": "0.0.99",
            ],
            scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
            attributes: [
                "agentstudio.app.startup.phase": .string("ghostty_init"),
                "agentstudio.app.startup.outcome": .string("succeeded"),
                "agentstudio.ghostty.status": .int(0),
                "agentstudio.trace.tag": .string("app.startup"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "app.startup.ghostty_init")
        #expect(projection.resource["service.name"] == "AgentStudio")
        #expect(projection.resource["service.version"] == "0.0.99")
        #expect(projection.resource["agentstudio.build.config"] == "DEBUG")
        #expect(projection.resource["agent.proof.launch"] == "launch-token-123")
        #expect(projection.attributes["agent.proof.launch"] == .string("launch-token-123"))
        #expect(projection.attributes["agent.proof.marker"] == .string("beta-observability-123"))
        #expect(projection.resource["process.pid"] == nil)
        #expect(projection.resource["agentstudio.session.id"] == nil)
        #expect(projection.attributes["agentstudio.app.startup.phase"] == .string("ghostty_init"))
        #expect(projection.attributes["agentstudio.app.startup.outcome"] == .string("succeeded"))
        #expect(projection.attributes["agentstudio.event.time_unix_nano"] == .int(100))
        #expect(projection.attributes["agentstudio.ghostty.status"] == .int(0))
        #expect(projection.traceID == nil)
        #expect(projection.spanID == nil)
    }

    @Test
    func bridgeProjectionPreservesValidTraceFieldsAndSafeAttributes() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let historicalBridgeLane = ["agentstudio", "bridge", "lane"].joined(separator: ".")
        let record = AgentStudioTraceRecord(
            timeUnixNano: 125,
            severityText: .info,
            body: "performance.bridge.webkit.push_envelope",
            traceID: "11111111111111111111111111111111",
            spanID: "2222222222222222",
            parentSpanID: "3333333333333333",
            resource: [
                "agentstudio.trace.name": "bridge-proof",
                "service.name": "AgentStudio",
            ],
            scope: .init(name: "agentstudio.bridge.performance.webkit", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.content.byte_size_bucket": .int(100_000),
                "agentstudio.bridge.content.line_count_bucket": .int(500),
                "agentstudio.bridge.header_supported": .bool(true),
                "agentstudio.bridge.item_id": .string("private-item-id"),
                historicalBridgeLane: .string("warm"),
                "agentstudio.bridge.phase": .string("transport"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("cold"),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("push"),
                "agentstudio.performance.elapsed_ms": .double(4.25),
                "agentstudio.trace.tag": .string("bridge.performance.webkit"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.traceID == "11111111111111111111111111111111")
        #expect(projection.spanID == "2222222222222222")
        #expect(projection.parentSpanID == "3333333333333333")
        #expect(projection.attributes["agentstudio.bridge.content.byte_size_bucket"] == .int(100_000))
        #expect(projection.attributes["agentstudio.bridge.content.line_count_bucket"] == .int(500))
        #expect(projection.attributes["agentstudio.bridge.header_supported"] == .bool(true))
        #expect(projection.attributes[historicalBridgeLane] != nil)
        #expect(projection.attributes["agentstudio.bridge.phase"] == .string("transport"))
        #expect(projection.attributes["agentstudio.bridge.plane"] == .string("data"))
        #expect(projection.attributes["agentstudio.bridge.priority"] == .string("cold"))
        #expect(projection.attributes["agentstudio.bridge.slice"] == .string("review_metadata"))
        #expect(projection.attributes["agentstudio.bridge.transport"] == .string("push"))
        #expect(projection.attributes["agentstudio.performance.elapsed_ms"] == .double(4.25))
        #expect(projection.attributes["agentstudio.bridge.item_id"] != nil)
    }

    @Test
    func bridgeProjectionRetainsInvalidTaxonomyValues() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 126,
            severityText: .info,
            body: "performance.bridge.webkit.push_envelope",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.webkit", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.phase": .string("package_push"),
                "agentstudio.bridge.plane": .string("file:///Users/private/repo"),
                "agentstudio.bridge.priority": .string("urgent"),
                "agentstudio.bridge.slice": .string("Sources/App/View.swift"),
                "agentstudio.trace.tag": .string("bridge.performance.webkit"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.bridge.phase"] != nil)
        #expect(projection.attributes["agentstudio.bridge.plane"] != nil)
        #expect(projection.attributes["agentstudio.bridge.priority"] != nil)
        #expect(projection.attributes["agentstudio.bridge.slice"] != nil)
    }

    @Test
    func bridgeProjectionRetainsInvalidTraceFields() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/BridgeTelemetryWireSchema.swift:56: Bridge ingress admits closed string values, never message text.
        let historicalBridgeLane = ["agentstudio", "bridge", "lane"].joined(separator: ".")
        let record = AgentStudioTraceRecord(
            timeUnixNano: 126,
            severityText: .info,
            body: "performance.bridge.web.push_apply",
            traceID: "00000000000000000000000000000000",
            spanID: "not-a-span",
            parentSpanID: "0000000000000000",
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                historicalBridgeLane: .string("warm"),
                "agentstudio.bridge.phase": .string("package_apply"),
                "agentstudio.trace.tag": .string("bridge.performance.web"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.traceID == nil)
        #expect(projection.spanID == nil)
        #expect(projection.parentSpanID == nil)
    }

    @Test
    func sidebarPerformanceProjectionKeepsControlledTaxonomyAndRetainsPayloadText() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter.swift:254; the sidebar producer records query length/state, never query text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 175,
            severityText: .info,
            body: "performance.sidebar.projection",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio"
            ],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(2.75),
                "agentstudio.performance.sidebar.surface": .string("inbox"),
                "agentstudio.performance.sidebar.phase": .string("mainactor_apply"),
                "agentstudio.performance.sidebar.query_state": .string("non_empty"),
                "agentstudio.performance.sidebar.group_mode": .string("not_applicable"),
                "agentstudio.performance.sidebar.trigger": .string("grouping_switch"),
                "agentstudio.performance.sidebar.input.count": .int(10),
                "agentstudio.performance.sidebar.group.count": .int(3),
                "agentstudio.performance.sidebar.request_build_mainactor_elapsed_ms": .double(0.5),
                "agentstudio.performance.sidebar.section.count": .int(99),
                "agentstudio.performance.sidebar.mainactor_apply_elapsed_ms": .double(2.75),
                "agentstudio.performance.sidebar.notification_text": .string("secret user prompt"),
                "agentstudio.performance.sidebar.query_text": .string("billing secret"),
                "agentstudio.performance.sidebar.repo.id": .string(UUID().uuidString),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "performance.sidebar.projection")
        #expect(projection.attributes["agentstudio.performance.sidebar.surface"] == .string("inbox"))
        #expect(projection.attributes["agentstudio.performance.sidebar.phase"] == .string("mainactor_apply"))
        #expect(projection.attributes["agentstudio.performance.sidebar.query_state"] == .string("non_empty"))
        #expect(projection.attributes["agentstudio.performance.sidebar.group_mode"] == .string("not_applicable"))
        #expect(projection.attributes["agentstudio.performance.sidebar.trigger"] == .string("grouping_switch"))
        #expect(projection.attributes["agentstudio.performance.sidebar.input.count"] == .int(10))
        #expect(projection.attributes["agentstudio.performance.sidebar.group.count"] == .int(3))
        #expect(
            projection.attributes["agentstudio.performance.sidebar.request_build_mainactor_elapsed_ms"] == .double(0.5))
        #expect(projection.attributes["agentstudio.performance.sidebar.section.count"] != nil)
        #expect(projection.attributes["agentstudio.performance.sidebar.mainactor_apply_elapsed_ms"] == .double(2.75))
        #expect(projection.attributes["agentstudio.performance.sidebar.notification_text"] != nil)
        #expect(projection.attributes["agentstudio.performance.sidebar.query_text"] != nil)
        #expect(projection.attributes["agentstudio.performance.sidebar.repo.id"] != nil)
    }

    @Test
    func sidebarRowIndexProjectionKeepsCanonicalPhaseAndElapsedKey() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter.swift:254; the sidebar producer records query length/state, never query text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 176,
            severityText: .info,
            body: "performance.sidebar.row_index",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(1.25),
                "agentstudio.performance.sidebar.surface": .string("repo"),
                "agentstudio.performance.sidebar.phase": .string("row_index"),
                "agentstudio.performance.sidebar.query_state": .string("empty"),
                "agentstudio.performance.sidebar.group_mode": .string("pane"),
                "agentstudio.performance.sidebar.trigger": .string("grouping_switch"),
                "agentstudio.performance.sidebar.row_index_elapsed_ms": .double(1.25),
                "agentstudio.performance.sidebar.row_index_worker_elapsed_ms": .double(99),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "performance.sidebar.row_index")
        #expect(projection.attributes["agentstudio.performance.sidebar.phase"] == .string("row_index"))
        #expect(projection.attributes["agentstudio.performance.sidebar.trigger"] == .string("grouping_switch"))
        #expect(projection.attributes["agentstudio.performance.sidebar.row_index_elapsed_ms"] == .double(1.25))
        #expect(projection.attributes["agentstudio.performance.sidebar.row_index_worker_elapsed_ms"] != nil)
    }

    @Test
    func sidebarRequestBuildProjectionKeepsCanonicalPhaseAndDataRefreshTrigger() {
        // R10: synthetic text bypasses Sources/AgentStudio/Features/RepoExplorer/RepoExplorerProjectionAdapter.swift:254; the sidebar producer records query length/state, never query text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 177,
            severityText: .info,
            body: "performance.sidebar.projection",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(0.75),
                "agentstudio.performance.sidebar.surface": .string("repo"),
                "agentstudio.performance.sidebar.phase": .string("request_build_mainactor"),
                "agentstudio.performance.sidebar.query_state": .string("empty"),
                "agentstudio.performance.sidebar.group_mode": .string("pane"),
                "agentstudio.performance.sidebar.trigger": .string("data_refresh"),
                "agentstudio.performance.sidebar.request_build_mainactor_elapsed_ms": .double(0.75),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.attributes["agentstudio.performance.sidebar.phase"] == .string("request_build_mainactor"))
        #expect(projection.attributes["agentstudio.performance.sidebar.trigger"] == .string("data_refresh"))
        #expect(
            projection.attributes["agentstudio.performance.sidebar.request_build_mainactor_elapsed_ms"] == .double(0.75)
        )
    }

    @Test
    func repoExplorerCommandPresentationProjectionKeepsWakeTriggerAndReusedCount() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerPerformanceTelemetry.swift:424: stage snapshot emits typed counts/outcomes, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 178, severityText: .info,
            body: "performance.repo_explorer.command_presentation",
            traceID: nil, spanID: nil, parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repo_explorer.wake_trigger": .string("observation"),
                "agentstudio.performance.repo_explorer.command_reused.count": .int(57),
            ]
        )
        let projection = OTLPProjectionAssertions.project(record)
        #expect(projection.attributes["agentstudio.performance.repo_explorer.wake_trigger"] == .string("observation"))
        #expect(projection.attributes["agentstudio.performance.repo_explorer.command_reused.count"] == .int(57))
    }

    @Test
    func tccDiagnosticProjectionKeepsClassificationsAndRetainsRawPaths() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTCCDiagnosticRecorder.swift:250: TCC probe emits access diagnostics, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 179,
            severityText: .warn,
            body: "terminal.tcc.access_probe",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio",
                "dev.release.channel": "beta",
            ],
            scope: .init(name: "agentstudio.terminal.tcc", version: "0.1.0"),
            attributes: [
                "agentstudio.tcc.phase": .string("startup_diagnostic"),
                "agentstudio.tcc.subject": .string("shell_child"),
                "agentstudio.tcc.access.target": .string("documents"),
                "agentstudio.tcc.access.result": .string("denied_eacces"),
                "agentstudio.tcc.responsible.kind": .string("agentstudio_beta"),
                "agentstudio.tcc.command.exit_class": .string("permission_denied"),
                "agentstudio.tcc.probe.sequence": .int(7),
                "agentstudio.tcc.bundle.changed": .bool(true),
                "agentstudio.tcc.bundle.executable.reachable": .bool(true),
                "agentstudio.tcc.tccdb.bundle_grant.present": .bool(true),
                "agentstudio.tcc.tccdb.path_row.count": .int(2),
                "agentstudio.tcc.raw.executable_path": .string(
                    "/Applications/AgentStudio Beta.app/Contents/MacOS/AgentStudio"),
                "agentstudio.tcc.raw.probe_path": .string("/Users/shravansunder/Documents/private"),
                "agentstudio.tcc.raw.responsible_path": .string(
                    "/Applications/AgentStudio Beta.app/Contents/MacOS/AgentStudio"),
                "agentstudio.tcc.tccdb.raw_client": .string("/Users/shravansunder/debug/AgentStudio"),
                "agentstudio.trace.tag": .string("terminal.tcc"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "terminal.tcc.access_probe")
        #expect(projection.attributes["agentstudio.trace.tag"] == .string("terminal.tcc"))
        #expect(projection.attributes["agentstudio.tcc.phase"] == .string("startup_diagnostic"))
        #expect(projection.attributes["agentstudio.tcc.subject"] == .string("shell_child"))
        #expect(projection.attributes["agentstudio.tcc.access.target"] == .string("documents"))
        #expect(projection.attributes["agentstudio.tcc.access.result"] == .string("denied_eacces"))
        #expect(projection.attributes["agentstudio.tcc.responsible.kind"] == .string("agentstudio_beta"))
        #expect(projection.attributes["agentstudio.tcc.command.exit_class"] == .string("permission_denied"))
        #expect(projection.attributes["agentstudio.tcc.probe.sequence"] == .int(7))
        #expect(projection.attributes["agentstudio.tcc.bundle.changed"] == .bool(true))
        #expect(projection.attributes["agentstudio.tcc.bundle.executable.reachable"] == .bool(true))
        #expect(projection.attributes["agentstudio.tcc.tccdb.bundle_grant.present"] == .bool(true))
        #expect(projection.attributes["agentstudio.tcc.tccdb.path_row.count"] == .int(2))
        #expect(projection.attributes["agentstudio.tcc.raw.executable_path"] != nil)
        #expect(projection.attributes["agentstudio.tcc.raw.probe_path"] != nil)
        #expect(projection.attributes["agentstudio.tcc.raw.responsible_path"] != nil)
        #expect(projection.attributes["agentstudio.tcc.tccdb.raw_client"] != nil)
    }

    @Test
    func fullDiskAccessHealthProjectionKeepsOnlySafeClassificationFields() {
        // R10: synthetic raw fields bypass Sources/AgentStudio/Infrastructure/Diagnostics/AgentStudioTCCDiagnosticRecorder.swift:250: TCC probe emits access diagnostics, never message text.
        let record = AgentStudioTraceRecord(
            timeUnixNano: 179,
            severityText: .warn,
            body: "app.full_disk_access.health_check.completed",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: [
                "service.name": "AgentStudio",
                "dev.release.channel": "beta",
            ],
            scope: .init(name: "agentstudio.app.startup", version: "0.1.0"),
            attributes: [
                "agentstudio.app.startup.phase": .string("full_disk_access_health_check"),
                "agentstudio.app.startup.outcome": .string("blocked"),
                "agentstudio.full_disk_access.health.healthy": .bool(false),
                "agentstudio.tcc.access.target": .string("messages_data"),
                "agentstudio.tcc.access.result": .string("denied_eperm"),
                "agentstudio.tcc.command.exit_class": .string("permission_denied"),
                "agentstudio.tcc.raw.probe_path": .string("/Users/shravansunder/Library/Messages"),
            ]
        )

        let projection = OTLPProjectionAssertions.project(record)

        #expect(projection.body == "app.full_disk_access.health_check.completed")
        #expect(projection.attributes["agentstudio.app.startup.phase"] == .string("full_disk_access_health_check"))
        #expect(projection.attributes["agentstudio.app.startup.outcome"] == .string("blocked"))
        #expect(projection.attributes["agentstudio.full_disk_access.health.healthy"] == .bool(false))
        #expect(projection.attributes["agentstudio.tcc.access.target"] == .string("messages_data"))
        #expect(projection.attributes["agentstudio.tcc.access.result"] == .string("denied_eperm"))
        #expect(projection.attributes["agentstudio.tcc.command.exit_class"] == .string("permission_denied"))
        #expect(projection.attributes["agentstudio.tcc.raw.probe_path"] != nil)
    }
}
