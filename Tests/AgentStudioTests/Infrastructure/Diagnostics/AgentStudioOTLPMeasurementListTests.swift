import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPMeasurementListTests {
    @Test
    func everyListedMeasurementHasAnEmitterAnchorAndProducesNumericSamples() async throws {
        let entries = try await valueFromDedicatedThread { try Self.readMeasurementAnchors() }
        #expect(entries.count == 520)
        #expect(Set(entries.map(\.name)) == AgentStudioOTLPMeasurementList.names)
        #expect(Set(entries.map(\.name)).count == entries.count)
        let numericValues: [(AgentStudioTraceValue, Double)] = [(.int(7), 7), (.double(2.5), 2.5)]
        for entry in entries {
            #expect(entry.hasValidSource, "Missing emitter anchor: \(entry.name)")
            for (inputValue, expectedValue) in numericValues {
                let metricEvent = try #require(
                    AgentStudioOTLPPerformanceMetricEvent(record: Self.measurementRecord(entry.name, value: inputValue))
                )
                let expectedLabel =
                    entry.name == "agentstudio.performance.elapsed_ms"
                    ? "agentstudio_performance_event_elapsed_ms"
                    : entry.name.replacingOccurrences(of: ".", with: "_")
                #expect(metricEvent.measurements.count == 1, "\(entry.name)")
                let measurement = try #require(metricEvent.measurements.first)
                let sample: AgentStudioOTLPPerformanceMetricSample
                switch measurement {
                case .counter(let value), .distribution(let value), .gauge(let value): sample = value
                }
                #expect(sample.label == expectedLabel, "\(entry.name)")
                #expect(sample.value == expectedValue, "\(entry.name)")
            }
        }
    }

    @Test
    func classifiedExcludedNamesNeverProduceNumericSamples() throws {
        for name in Self.excludedNames {
            for value: AgentStudioTraceValue in [.int(0), .int(1), .double(2.5)] {
                let metricEvent = try #require(
                    AgentStudioOTLPPerformanceMetricEvent(record: Self.measurementRecord(name, value: value))
                )
                #expect(metricEvent.measurements.isEmpty, "\(name)")
            }
        }
    }

    @Test
    func booleansNeverProduceSamplesEvenForListedMeasurementNames() throws {
        for name in AgentStudioOTLPMeasurementList.names.union(Self.excludedNames) {
            for value in [true, false] {
                let metricEvent = try #require(
                    AgentStudioOTLPPerformanceMetricEvent(record: Self.measurementRecord(name, value: .bool(value)))
                )
                #expect(metricEvent.measurements.isEmpty, "\(name)")
                #expect(metricEvent.elapsedMilliseconds == nil, "\(name)")
            }
        }
    }

    @Test
    func eventCounterAndDurationDerivedInstrumentsSurviveTheListGate() throws {
        let factory = OTLPRecordingMetricsFactory()
        let metrics = AgentStudioOTLPPerformanceMetrics(factory: factory)
        for value in [12.0, 4.0] {
            metrics.record(Self.measurementRecord("agentstudio.performance.elapsed_ms", value: .double(value)))
        }
        metrics.record(Self.measurementRecord("agentstudio.performance.unlisted_measurement", value: .int(9)))
        let dimensions = [("event", "performance.git.status")]
        #expect(factory.counter(label: "agentstudio_performance_events_total", dimensions: dimensions)?.totalValue == 3)
        #expect(
            factory.recorder(label: "agentstudio_performance_event_elapsed_ms", dimensions: dimensions)?.values == [
                12, 4,
            ]
        )
        #expect(
            factory.recorder(label: "agentstudio_performance_event_elapsed_ms_max", dimensions: dimensions)?.values
                == [12, 12]
        )
    }

    @Test
    func rareMeasurementsAndClassifiedTalliesRemainListed() {
        for name in [
            "agentstudio.performance.ipc.pane_context_read.detail_elapsed_ms",
            "agentstudio.performance.ipc.pane_context_read.reply_bytes",
            "agentstudio.bridge.native_capacity.entry.count",
            "agentstudio.performance.atom.input_revision.count",
            "agentstudio.performance.filesystem.ingress.shared_ancestor.stale_generation.count",
            "agentstudio.performance.topology.index.count",
            "agentstudio.bridge.render_disposition.pending_high_water_mark",
            "agentstudio.performance.repository_fact_demand.activity.hydration_unclassified.current",
        ] {
            #expect(AgentStudioOTLPMeasurementList.names.contains(name), "\(name)")
        }
    }

    @Test
    func flagsSequencesUnlistedNumbersAndBooleanDurationsProduceNoMeasurements() throws {
        let record = AgentStudioOTLPPerformanceMetricsTests.metricDimensionRecord(
            eventName: "performance.git.status",
            attributes: [
                "agentstudio.performance.sidebar.is_filtering": .int(1),
                "agentstudio.performance.renderer.sample.sequence": .int(8),
                "agentstudio.performance.repo_explorer.native_table_pilot.exactness": .int(1),
                "agentstudio.performance.unlisted_measurement": .double(2),
            ]
        )
        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
        #expect(metricEvent.samples.isEmpty)

        let booleanDuration = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 460, severityText: .info, body: "performance.git.status",
            traceID: nil, spanID: nil, parentSpanID: nil, resource: [:],
            scope: .init(name: "agentstudio.performance", version: "test"),
            attributes: ["agentstudio.performance.elapsed_ms": .bool(true)]
        )
        let booleanEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: booleanDuration))
        #expect(booleanEvent.elapsedMilliseconds == nil)
        #expect(booleanEvent.measurements.isEmpty)
    }

    static func measurementRecord(_ name: String, value: AgentStudioTraceValue) -> AgentStudioOTLPProjectedLogRecord {
        var attributes = [name: value]
        let isBridge = name.hasPrefix("agentstudio.bridge.")
        if isBridge {
            attributes.merge([
                "agentstudio.bridge.phase": .string("transport"),
                "agentstudio.bridge.plane": .string("data"),
                "agentstudio.bridge.priority": .string("cold"),
                "agentstudio.bridge.slice": .string("review_metadata"),
            ]) { current, _ in current }
        }
        return AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 460, severityText: .info,
            body: isBridge ? "performance.bridge.webkit.push_envelope" : "performance.git.status",
            traceID: nil, spanID: nil, parentSpanID: nil, resource: [:],
            scope: .init(name: "agentstudio.performance", version: "test"), attributes: attributes
        )
    }

    private struct MeasurementSourceEntry: Sendable {
        let name: String
        let hasValidSource: Bool
    }

    private enum MeasurementAnchorError: Error {
        case malformedEntry(String)
    }

    private static func readMeasurementAnchors() throws -> [MeasurementSourceEntry] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let filenames = ["AgentStudioOTLPMeasurementList.swift", "AgentStudioOTLPMeasurementList+Bridge.swift"]
        let source = try filenames.map { filename in
            try String(
                contentsOf: root.appendingPathComponent("Sources/AgentStudio/Infrastructure/Diagnostics/" + filename),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        var entries: [MeasurementSourceEntry] = []
        var sourcesByPath: [String: String] = [:]
        var precedingComment = ""
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") {
                precedingComment = String(trimmed.dropFirst(2))
                continue
            }
            guard trimmed.hasPrefix("\"agentstudio.") else { continue }
            guard let name = trimmed.split(separator: "\"").first,
                let anchor = precedingComment.split(separator: ";").first
            else { throw MeasurementAnchorError.malformedEntry(line) }
            let location = anchor.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard location.count == 2, let lineNumber = Int(location[1]) else {
                throw MeasurementAnchorError.malformedEntry(line)
            }
            let path = String(location[0])
            let contents: String
            if let cached = sourcesByPath[path] {
                contents = cached
            } else {
                contents = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                sourcesByPath[path] = contents
            }
            let lines = contents.components(separatedBy: .newlines)
            let valid =
                (1...lines.count).contains(lineNumber)
                && sourceLineContainsMeasurement(String(name), line: lines[lineNumber - 1], contents: contents)
            entries.append(MeasurementSourceEntry(name: String(name), hasValidSource: valid))
        }
        return entries
    }

    private static func sourceLineContainsMeasurement(_ name: String, line: String, contents: String) -> Bool {
        if line.contains("\"\(name)\"") { return true }
        let ingressPrefix = "agentstudio.performance.filesystem.ingress."
        if name.hasPrefix(ingressPrefix), line.contains("\\(prefix)") {
            let suffix = String(name.dropFirst(ingressPrefix.count))
            let components = suffix.split(separator: ".", maxSplits: 1)
            guard components.count == 2 else { return false }
            return line.contains("\"\\(prefix).\(components[1])\"")
                && contents.contains("source: \"\(components[0])\"")
        }
        for suffix in ["initial_readback.", "attendance_lost."] {
            let prefix = "agentstudio.performance.sidebar.proof." + suffix
            if name.hasPrefix(prefix) {
                return line.contains("prefix + \"\(name.dropFirst(prefix.count))\"")
                    && contents.contains("\"\(prefix)\"")
            }
        }
        return false
    }

    private static let excludedNames: Set<String> = [
        "agentstudio.performance.trace_queue.dropped_record.count",
        "agentstudio.performance.trace_queue.pending_request.count",
        "agentstudio.performance.trace_queue.high_watermark",
        "agentstudio.bridge.activation.sequence",  // sequence
        "agentstudio.bridge.activation.source_available",  // flag
        "agentstudio.bridge.active_viewer.sequence",  // sequence
        "agentstudio.bridge.already_selected",  // flag
        "agentstudio.bridge.annotation.catalog.revision",  // sequence
        "agentstudio.bridge.annotation.catalog.window.ordinal",  // sequence
        "agentstudio.bridge.cache_hit",  // flag
        "agentstudio.bridge.content.binary",  // flag
        "agentstudio.bridge.content.stale",  // flag
        "agentstudio.bridge.demand.request.sequence",  // sequence
        "agentstudio.bridge.focus",  // flag
        "agentstudio.bridge.generation",  // sequence
        "agentstudio.bridge.header_missing",  // flag
        "agentstudio.bridge.header_supported",  // flag
        "agentstudio.bridge.intake.generation",  // sequence
        "agentstudio.bridge.intake.sequence",  // sequence
        "agentstudio.bridge.interaction.sequence",  // sequence
        "agentstudio.bridge.presentation.has_active_stream",  // flag
        "agentstudio.bridge.presentation.publication_sequence",  // sequence
        "agentstudio.bridge.presentation.revision",  // sequence
        "agentstudio.bridge.presentation.revision.after",  // sequence
        "agentstudio.bridge.presentation.revision.before",  // sequence
        "agentstudio.bridge.refreshing.review",  // flag
        "agentstudio.bridge.reopen_signaled",  // flag
        "agentstudio.bridge.review.comparison_targets.is_truncated",  // flag
        "agentstudio.bridge.review.comparison_targets.query_request.sequence",  // sequence
        "agentstudio.bridge.review.generation",  // sequence
        "agentstudio.bridge.row_mounted",  // flag
        "agentstudio.bridge.scroll.active",  // flag
        "agentstudio.bridge.selected",  // flag
        "agentstudio.bridge.source.generation",  // sequence
        "agentstudio.bridge.source.monotonic_ms",  // bookkeeping
        "agentstudio.bridge.stage.attempt",  // sequence
        "agentstudio.bridge.stream_id_matches",  // flag
        "agentstudio.bridge.telemetry.accepted_batch.sequence",  // sequence
        "agentstudio.bridge.telemetry.comm_producer.high_watermark",  // sequence
        "agentstudio.bridge.telemetry.lossy",  // flag
        "agentstudio.bridge.telemetry.main_producer.high_watermark",  // sequence
        "agentstudio.bridge.telemetry.proof_eligible",  // flag
        "agentstudio.bridge.telemetry.settlement_acknowledged",  // flag
        "agentstudio.bridge.telemetry.value",  // bookkeeping
        "agentstudio.bridge.viewer.active",  // flag
        "agentstudio.bridge.worker.derivation_epoch",  // sequence
        "agentstudio.bridge.worker.file_metadata_selected_path_resolved",  // flag
        "agentstudio.bridge.worker.source_epoch",  // sequence
        "agentstudio.bridge.worktree_file.receiver.generation",  // sequence
        "agentstudio.bridge.worktree_file.tree.window.is_final",  // flag
        "agentstudio.performance.atom.cache_hit",  // flag
        "agentstudio.performance.commandbar.search.generation",  // sequence
        "agentstudio.performance.commandbar.search.sequence",  // sequence
        "agentstudio.performance.coordinator.source_sync.batch_index",  // sequence
        "agentstudio.performance.filesystem.ingress.shared_ancestor.latest_pending_epoch",  // sequence
        "agentstudio.performance.git.backoff_attempt.count",  // sequence
        "agentstudio.performance.git.backoff_open",  // flag
        "agentstudio.performance.git.has_git_internal_changes",  // flag
        "agentstudio.performance.git.path_quarantined",  // flag
        "agentstudio.performance.git.request.sequence",  // sequence
        "agentstudio.performance.management_layer.did_exit",  // flag
        "agentstudio.performance.management_layer.is_active",  // flag
        "agentstudio.performance.pane_view_restore.force_when_bounds_exist",  // flag
        "agentstudio.performance.pane_view_restore.had_placeholder",  // flag
        "agentstudio.performance.renderer.lifecycle.valid",  // flag
        "agentstudio.performance.renderer.sample.sequence",  // sequence
        "agentstudio.performance.renderer.window.miniaturized",  // flag
        "agentstudio.performance.renderer.window.occluded",  // flag
        "agentstudio.performance.renderer.window.visible",  // flag
        "agentstudio.performance.repo_explorer.native_table_pilot.completed",  // flag
        "agentstudio.performance.repo_explorer.native_table_pilot.exactness",  // flag
        "agentstudio.performance.repo_explorer.native_table_pilot.growth_percent",  // bookkeeping
        "agentstudio.performance.repo_explorer.native_table_pilot.measured.count",  // bookkeeping
        "agentstudio.performance.repo_explorer.native_table_pilot.passed",  // flag
        "agentstudio.performance.repo_explorer.native_table_pilot.policy_version",  // bookkeeping
        "agentstudio.performance.repo_explorer.native_table_pilot.result_version",  // bookkeeping
        "agentstudio.performance.repo_explorer.native_table_pilot.warmup.count",  // bookkeeping
        "agentstudio.performance.sidebar.is_collapsed",  // flag
        "agentstudio.performance.sidebar.is_filtering",  // flag
        "agentstudio.performance.sidebar.proof.action.sequence",  // sequence
        "agentstudio.performance.sidebar.proof.attendance_lost.app_active",  // flag
        "agentstudio.performance.sidebar.proof.attendance_lost.app_hidden",  // flag
        "agentstudio.performance.sidebar.proof.attendance_lost.window_key",  // flag
        "agentstudio.performance.sidebar.proof.attendance_lost.window_miniaturized",  // flag
        "agentstudio.performance.sidebar.proof.attendance_lost.window_occlusion_visible",  // flag
        "agentstudio.performance.sidebar.proof.attendance_lost.window_on_active_space",  // flag
        "agentstudio.performance.sidebar.proof.attendance_lost.window_visible",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.app_active",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.app_hidden",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.native_accessibility_ready",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.native_collapsed",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.native_geometry_visible",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.present",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.repo_demanded",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.repo_presentation_ready",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.semantic_collapsed",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.window_key",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.window_miniaturized",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.window_occlusion_visible",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.window_on_active_space",  // flag
        "agentstudio.performance.sidebar.proof.initial_readback.window_visible",  // flag
        "agentstudio.performance.sidebar.proof.monotonic_ns",  // bookkeeping
        "agentstudio.performance.sidebar.proof.readback.acknowledged_revision",  // sequence
        "agentstudio.performance.sidebar.proof.readback.materialization_fingerprint",  // bookkeeping
        "agentstudio.performance.sidebar.proof.readback.native_materialization_fingerprint",  // bookkeeping
        "agentstudio.performance.sidebar.proof.readback.native_materialization_generation",  // sequence
        "agentstudio.performance.sidebar.proof.readback.native_projection_matches",  // flag
        "agentstudio.performance.sidebar.proof.readback.native_projection_required",  // flag
        "agentstudio.performance.sidebar.proof.readback.semantic_generation",  // sequence
        "agentstudio.performance.sidebar.proof.readback.visible_generation",  // sequence
        "agentstudio.performance.sidebar.readback.acknowledged_revision",  // sequence
        "agentstudio.performance.sidebar.readback.materialization_fingerprint",  // bookkeeping
        "agentstudio.performance.sidebar.readback.semantic_generation",  // sequence
        "agentstudio.performance.sidebar.readback.visible_generation",  // sequence
        "agentstudio.performance.sidebar.was_collapsed",  // flag
        "agentstudio.performance.tabbar.active_tab.present",  // flag
        "agentstudio.performance.tabbar.context_menu.host_hit",  // flag
        "agentstudio.performance.tabbar.context_menu.static_menu_available",  // flag
        "agentstudio.performance.tabbar.context_menu.tab_hit",  // flag
        "agentstudio.performance.tabbar.pane_drop.target_resolved",  // flag
        "agentstudio.performance.tabbar.sequence",  // sequence
        "agentstudio.performance.terminal.activity_projection.submitted",  // flag
        "agentstudio.performance.terminal.surface.dedup_likely",  // flag
        "agentstudio.performance.terminal.surface.has_superview",  // flag
        "agentstudio.performance.terminal.surface.has_window",  // flag
        "agentstudio.performance.terminal.surface.hidden",  // flag
        "agentstudio.performance.topology.has_match",  // flag
        "agentstudio.bridge.demand.queue_depth",  // no emitter / ingress
        "agentstudio.bridge.demand.stale_drop.count",  // no emitter / ingress
        "agentstudio.bridge.metadata_manifest.emitted_total",  // no emitter / ingress
        "agentstudio.bridge.metadata_manifest.expected_total",  // no emitter / ingress
        "agentstudio.bridge.metadata_manifest.remaining_total",  // no emitter / ingress
    ]
}
