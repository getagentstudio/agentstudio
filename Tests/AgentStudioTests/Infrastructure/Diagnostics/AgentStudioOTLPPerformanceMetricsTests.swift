import Foundation
import Metrics
import Testing

@testable import AgentStudioInfrastructure

@Suite
struct AgentStudioOTLPPerformanceMetricsTests {
    @Test("filesystem ingress snapshot numeric fields become counters and gauges")
    func filesystemIngressSnapshotFieldsBecomeCountersAndGauges() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 121,
            severityText: .info,
            body: "performance.filesystem.ingress_snapshot",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.filesystem.ingress.local.accepted.batch.count": .int(11),
                "agentstudio.performance.filesystem.ingress.shared_uncertainty.dropped.path.count": .int(13),
                "agentstudio.performance.filesystem.ingress.overflow.coarse_recovery.count": .int(17),
                "agentstudio.performance.filesystem.local_stream.physical.count": .int(1),
                "agentstudio.performance.filesystem.local_stream.logical_registration.count": .int(148),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))
        let samplesByLabel = Dictionary(uniqueKeysWithValues: metricEvent.samples.map { ($0.label, $0.value) })

        #expect(
            samplesByLabel[
                "agentstudio_performance_filesystem_ingress_local_accepted_batch_count"
            ] == 11
        )
        #expect(
            samplesByLabel[
                "agentstudio_performance_filesystem_ingress_shared_uncertainty_dropped_path_count"
            ] == 13
        )
        #expect(
            samplesByLabel[
                "agentstudio_performance_filesystem_ingress_overflow_coarse_recovery_count"
            ] == 17
        )
        #expect(
            samplesByLabel[
                "agentstudio_performance_filesystem_local_stream_physical_count"
            ] == 1
        )
        #expect(
            samplesByLabel[
                "agentstudio_performance_filesystem_local_stream_logical_registration_count"
            ] == 148
        )
        #expect(
            metricEvent.measurements.allSatisfy { measurement in
                switch measurement {
                case .counter(let sample):
                    return sample.label.hasPrefix("agentstudio_performance_filesystem_ingress_")
                case .gauge(let sample):
                    return sample.label.hasPrefix("agentstudio_performance_filesystem_local_stream_")
                case .distribution:
                    return false
                }
            })
    }

    @Test("startup usable projects launch and layout phase distributions")
    func startupUsableProjectsBothDurations() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 120,
            severityText: .info,
            body: "performance.startup.usable",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(125),
                "agentstudio.performance.startup.layout_settle_to_usable_elapsed_ms": .double(8),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.elapsedMilliseconds == 125)
        #expect(
            metricEvent.samples.map(\.label)
                == ["agentstudio_performance_startup_layout_settle_to_usable_elapsed_ms"])
    }

    @Test("Repo Explorer keyed-wake contract becomes bounded metric dimensions")
    func repoExplorerKeyedWakeBecomesBoundedMetricDimensions() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.repo_explorer.keyed_wake",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.repo_explorer.stage": .string("mainactor_apply"),
                "agentstudio.performance.repo_explorer.key_class": .string("relevant"),
                "agentstudio.performance.repo_explorer.outcome": .string("published"),
                "agentstudio.performance.repo_explorer.facet": .string("unread"),
                "agentstudio.performance.repo_explorer.row_relation": .string("owning"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(
            metricEvent.dimensions.map(\.name) == ["event", "stage", "key_class", "outcome", "facet", "row_relation"])
    }

    @Test("interaction kind becomes a metric dimension")
    func interactionKindBecomesMetricDimension() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.interaction.latency",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(7.5),
                "agentstudio.performance.interaction.kind": .string("cmd_r"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(
            metricEvent.dimensions == [
                AgentStudioOTLPPerformanceMetricDimension(
                    name: "event",
                    value: "performance.interaction.latency"
                ),
                AgentStudioOTLPPerformanceMetricDimension(name: "interaction_kind", value: "cmd_r"),
            ])
        #expect(metricEvent.elapsedMilliseconds == 7.5)
    }

    @Test
    func panePresentationMetricsExposeBoundedTransitionOutcome() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.bridge.swift.pane_presentation",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.swift", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.comparison.attempt.status": .string("settled"),
                "agentstudio.bridge.phase": .string("pane_presentation_enqueued"),
                "agentstudio.bridge.plane": .string("control"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.result_reason": .string("none"),
                "agentstudio.bridge.slice": .string("review_metadata"),
                "agentstudio.bridge.transport": .string("swift"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(
            metricEvent.dimensions == [
                .init(name: "event", value: "performance.bridge.swift.pane_presentation"),
                .init(name: "phase", value: "pane_presentation_enqueued"),
                .init(name: "plane", value: "control"),
                .init(name: "priority", value: "hot"),
                .init(name: "slice", value: "review_metadata"),
                .init(name: "comparison_status", value: "settled"),
                .init(name: "result", value: "success"),
                .init(name: "result_reason", value: "none"),
            ]
        )
    }

    @Test
    func renderedPanePresentationMetricsExposeMismatchAndPaneState() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 124,
            severityText: .info,
            body: "performance.bridge.web.pane_presentation",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.bridge.performance.web", version: "0.1.0"),
            attributes: [
                "agentstudio.bridge.comparison.attempt.status": .string("settled"),
                "agentstudio.bridge.comparison.package_match": .string("review_generation_mismatch"),
                "agentstudio.bridge.comparison.pane_state": .string("loading_previous"),
                "agentstudio.bridge.phase": .string("comparison_pane_rendered"),
                "agentstudio.bridge.plane": .string("control"),
                "agentstudio.bridge.priority": .string("hot"),
                "agentstudio.bridge.result": .string("success"),
                "agentstudio.bridge.slice": .string("review_metadata"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.dimensions.contains(.init(name: "package_match", value: "review_generation_mismatch")))
        #expect(metricEvent.dimensions.contains(.init(name: "pane_state", value: "loading_previous")))
    }

    @Test
    func repoCommandPresentationAndTabWorkProjectsOnlyApprovedAggregateCounters() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.repo_explorer.command_presentation",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.apply_governor.batch.count": .int(3),
                "agentstudio.performance.apply_governor.awaited_ms": .double(8),
                "agentstudio.performance.apply_governor.carried_over.count": .int(1),
                "agentstudio.performance.apply_governor.mainactor_held_ms": .double(2),
                "agentstudio.performance.apply_governor.max_single_fact_ms": .double(6),
                "agentstudio.performance.apply_governor.queue_wait_ms": .double(4),
                "agentstudio.performance.apply_governor.superseded.count": .int(9),
                "agentstudio.performance.repo_explorer.command_resolution.count": .int(12),
                "agentstudio.performance.repo_explorer.command_reused.count": .int(18),
                "agentstudio.performance.repo_explorer.visible_set.count": .int(3),
                "agentstudio.performance.repo_explorer.visible_set_delta.count": .int(1),
                "agentstudio.performance.tabbar.affected_item.count": .int(1),
                "agentstudio.performance.repo_explorer.private_title": .string("must-not-project"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(
            metricEvent.samples.map(\.label) == [
                "agentstudio_performance_apply_governor_awaited_ms",
                "agentstudio_performance_apply_governor_batch_count",
                "agentstudio_performance_apply_governor_carried_over_count",
                "agentstudio_performance_apply_governor_mainactor_held_ms",
                "agentstudio_performance_apply_governor_max_single_fact_ms",
                "agentstudio_performance_apply_governor_queue_wait_ms",
                "agentstudio_performance_apply_governor_superseded_count",
                "agentstudio_performance_repo_explorer_command_resolution_count",
                "agentstudio_performance_repo_explorer_command_reused_count",
                "agentstudio_performance_repo_explorer_visible_set_count",
                "agentstudio_performance_repo_explorer_visible_set_delta_count",
                "agentstudio_performance_tabbar_affected_item_count",
            ]
        )
    }

    @Test
    func performanceRecordProjectsBoundedMetricsFromScrubbedAttributes() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.git.status",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(15.5),
                "agentstudio.performance.git.pending.count": .int(64),
                "agentstudio.performance.git.running.count": .int(4),
                "agentstudio.performance.git.status.last_outcome": .string("completed"),
                "agentstudio.performance.git.trigger_source": .string("periodic"),
                "agentstudio.performance.git.has_git_internal_changes": .bool(true),
                "agentstudio.performance.git.root_path": .string("/Users/private/repo"),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.eventName == "performance.git.status")
        #expect(metricEvent.elapsedMilliseconds == 15.5)
        let expectedDimensions = [
            AgentStudioOTLPPerformanceMetricDimension(name: "event", value: "performance.git.status"),
            AgentStudioOTLPPerformanceMetricDimension(name: "trigger_source", value: "periodic"),
            AgentStudioOTLPPerformanceMetricDimension(name: "last_outcome", value: "completed"),
        ]
        #expect(
            metricEvent.samples == [
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.status",
                    label: "agentstudio_performance_git_has_git_internal_changes",
                    dimensions: expectedDimensions,
                    value: 1
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.status",
                    label: "agentstudio_performance_git_pending_count",
                    dimensions: expectedDimensions,
                    value: 64
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.status",
                    label: "agentstudio_performance_git_running_count",
                    dimensions: expectedDimensions,
                    value: 4
                ),
            ])
    }

    @Test
    func gitStatusUnavailableReasonBecomesMetricDimension() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.git.status_unavailable",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(21.5),
                "agentstudio.performance.git.status_unavailable.reason": .string("timeout"),
                "agentstudio.performance.git.status.last_outcome": .string("timeout"),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.eventName == "performance.git.status_unavailable")
        #expect(
            metricEvent.dimensions == [
                AgentStudioOTLPPerformanceMetricDimension(
                    name: "event",
                    value: "performance.git.status_unavailable"
                ),
                AgentStudioOTLPPerformanceMetricDimension(name: "reason", value: "timeout"),
                AgentStudioOTLPPerformanceMetricDimension(name: "last_outcome", value: "timeout"),
            ])
        #expect(metricEvent.elapsedMilliseconds == 21.5)
    }

    @Test
    func gitStatusScopeBecomesMetricDimension() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.git.status",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(12.0),
                "agentstudio.performance.git.status_scope": .string("pathspec"),
                "agentstudio.performance.git.pathspec.count": .int(3),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.eventName == "performance.git.status")
        let expectedDimensions = [
            AgentStudioOTLPPerformanceMetricDimension(name: "event", value: "performance.git.status"),
            AgentStudioOTLPPerformanceMetricDimension(name: "scope", value: "pathspec"),
        ]
        #expect(metricEvent.dimensions == expectedDimensions)
        #expect(
            metricEvent.samples == [
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.status",
                    label: "agentstudio_performance_git_pathspec_count",
                    dimensions: expectedDimensions,
                    value: 3
                )
            ])
        #expect(metricEvent.elapsedMilliseconds == 12.0)
    }

    @Test
    func gitBackoffProjectsBoundedMetricsWithReasonDimension() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.git.backoff",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.git.backoff_open": .bool(true),
                "agentstudio.performance.git.backoff_ms": .double(500),
                "agentstudio.performance.git.backoff_attempt.count": .int(3),
                "agentstudio.performance.git.backoff.reason": .string("timeout"),
                "agentstudio.performance.git.pending.count": .int(2),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.eventName == "performance.git.backoff")
        let expectedDimensions = [
            AgentStudioOTLPPerformanceMetricDimension(name: "event", value: "performance.git.backoff"),
            AgentStudioOTLPPerformanceMetricDimension(name: "reason", value: "timeout"),
        ]
        #expect(metricEvent.dimensions == expectedDimensions)
        #expect(
            metricEvent.samples == [
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.backoff",
                    label: "agentstudio_performance_git_backoff_attempt_count",
                    dimensions: expectedDimensions,
                    value: 3
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.backoff",
                    label: "agentstudio_performance_git_backoff_ms",
                    dimensions: expectedDimensions,
                    value: 500
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.backoff",
                    label: "agentstudio_performance_git_backoff_open",
                    dimensions: expectedDimensions,
                    value: 1
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.git.backoff",
                    label: "agentstudio_performance_git_pending_count",
                    dimensions: expectedDimensions,
                    value: 2
                ),
            ])
    }

    @Test
    func atomPerformanceRecordProjectsAtomCounters() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 456,
            severityText: .info,
            body: "performance.atom.read",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.atom.kind": .string("entity_map"),
                "agentstudio.performance.atom.operation": .string("value"),
                "agentstudio.performance.atom.slot.count": .int(2),
                "agentstudio.performance.atom.cached_key.count": .int(1),
                "agentstudio.performance.atom.cache_hit": .bool(false),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.eventName == "performance.atom.read")
        let expectedDimensions = [
            AgentStudioOTLPPerformanceMetricDimension(name: "event", value: "performance.atom.read")
        ]
        #expect(
            metricEvent.samples == [
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.atom.read",
                    label: "agentstudio_performance_atom_cache_hit",
                    dimensions: expectedDimensions,
                    value: 0
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.atom.read",
                    label: "agentstudio_performance_atom_cached_key_count",
                    dimensions: expectedDimensions,
                    value: 1
                ),
                AgentStudioOTLPPerformanceMetricSample(
                    eventName: "performance.atom.read",
                    label: "agentstudio_performance_atom_slot_count",
                    dimensions: expectedDimensions,
                    value: 2
                ),
            ])
    }

    @Test
    func eagerDerivedFamilyRecordProjectsControlledLaneDimensions() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 457,
            severityText: .info,
            body: "performance.atom.derived",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.atom.kind": .string("eager_derived_family"),
                "agentstudio.performance.atom.label": .string("repo_explorer_projection"),
                "agentstudio.performance.atom.operation": .string("completion"),
                "agentstudio.performance.atom.outcome": .string("published"),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(
            metricEvent.dimensions == [
                AgentStudioOTLPPerformanceMetricDimension(name: "event", value: "performance.atom.derived"),
                AgentStudioOTLPPerformanceMetricDimension(name: "atom_kind", value: "eager_derived_family"),
                AgentStudioOTLPPerformanceMetricDimension(name: "atom_label", value: "repo_explorer_projection"),
                AgentStudioOTLPPerformanceMetricDimension(name: "atom_operation", value: "completion"),
                AgentStudioOTLPPerformanceMetricDimension(name: "outcome", value: "published"),
            ])
    }

    @Test
    func processMallocRecordProjectsPairedMemoryGauges() throws {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 457,
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
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(metricEvent.eventName == "performance.process.malloc_zone")
        #expect(
            metricEvent.samples.map(\.label) == [
                "agentstudio_performance_process_malloc_blocks_in_use",
                "agentstudio_performance_process_malloc_maximum_size_in_use_bytes",
                "agentstudio_performance_process_malloc_size_allocated_bytes",
                "agentstudio_performance_process_malloc_size_in_use_bytes",
            ])
        #expect(
            metricEvent.measurements.allSatisfy { measurement in
                if case .gauge = measurement { return true }
                return false
            })
    }

    @Test
    func runtimePressureAggregateDeltasAreCountersWhileRetainedValuesStayGauges() throws {
        let factory = OTLPRecordingMetricsFactory()
        let metrics = AgentStudioOTLPPerformanceMetrics(factory: factory)
        let changedDimensions = [
            ("outcome", "changed"),
            ("drain_class", "title_deadline"),
            ("event", "performance.terminal.accumulator_drain"),
        ]
        let equalDimensions = [
            ("outcome", "equal"),
            ("drain_class", "title_deadline"),
            ("event", "performance.terminal.accumulator_drain"),
        ]
        let firstRecord = Self.projectedPerformanceRecord(
            body: "performance.terminal.accumulator_drain",
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(3),
                "agentstudio.performance.terminal.accumulator.drain.class": .string("title_deadline"),
                "agentstudio.performance.terminal.accumulator.apply.outcome": .string("changed"),
                "agentstudio.performance.terminal.accumulator.offered.count": .int(10),
                "agentstudio.performance.terminal.accumulator.replaced.count": .int(8),
                "agentstudio.performance.terminal.accumulator.retained_entry.count": .int(4),
                "agentstudio.performance.terminal.accumulator.retained_size_bytes": .int(256),
            ]
        )
        let secondRecord = Self.projectedPerformanceRecord(
            body: "performance.terminal.accumulator_drain",
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(1),
                "agentstudio.performance.terminal.accumulator.drain.class": .string("title_deadline"),
                "agentstudio.performance.terminal.accumulator.apply.outcome": .string("equal"),
                "agentstudio.performance.terminal.accumulator.offered.count": .int(5),
                "agentstudio.performance.terminal.accumulator.replaced.count": .int(3),
                "agentstudio.performance.terminal.accumulator.retained_entry.count": .int(2),
                "agentstudio.performance.terminal.accumulator.retained_size_bytes": .int(128),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: firstRecord))
        metrics.record(firstRecord)
        metrics.record(secondRecord)

        #expect(
            metricEvent.dimensions.contains(
                AgentStudioOTLPPerformanceMetricDimension(name: "drain_class", value: "title_deadline")
            )
        )
        #expect(
            metricEvent.dimensions.contains(
                AgentStudioOTLPPerformanceMetricDimension(name: "outcome", value: "changed")
            )
        )
        #expect(
            metricEvent.measurements.contains { measurement in
                if case .counter(let sample) = measurement {
                    return sample.label == "agentstudio_performance_terminal_accumulator_offered_count"
                }
                return false
            })
        #expect(
            metricEvent.measurements.contains { measurement in
                if case .gauge(let sample) = measurement {
                    return sample.label == "agentstudio_performance_terminal_accumulator_retained_entry_count"
                }
                return false
            })
        #expect(
            factory.counter(
                label: "agentstudio_performance_terminal_accumulator_offered_count",
                dimensions: changedDimensions
            )?.totalValue == 10)
        #expect(
            factory.counter(
                label: "agentstudio_performance_terminal_accumulator_offered_count",
                dimensions: equalDimensions
            )?.totalValue == 5)
        #expect(
            factory.counter(
                label: "agentstudio_performance_terminal_accumulator_replaced_count",
                dimensions: changedDimensions
            )?.totalValue == 8)
        #expect(
            factory.recorder(
                label: "agentstudio_performance_terminal_accumulator_retained_entry_count",
                dimensions: changedDimensions
            )?.values == [4])
        #expect(
            factory.recorder(
                label: "agentstudio_performance_terminal_accumulator_retained_size_bytes",
                dimensions: equalDimensions
            )?.values == [128])
        #expect(
            factory.recorder(
                label: AgentStudioOTLPPerformanceMetrics.elapsedMetricLabel,
                dimensions: changedDimensions
            )?.values == [3])
    }

    @Test
    func terminalEqualSuppressionProjectsAsCounterWithPublicationKind() throws {
        let record = Self.projectedPerformanceRecord(
            body: "performance.terminal.equal_suppressed",
            attributes: [
                "agentstudio.performance.terminal.publication.kind": .string("title"),
                "agentstudio.performance.terminal.equal_suppressed.count": .int(1),
            ]
        )

        let metricEvent = try #require(AgentStudioOTLPPerformanceMetricEvent(record: record))

        #expect(
            metricEvent.dimensions.contains(
                AgentStudioOTLPPerformanceMetricDimension(name: "publication_kind", value: "title")
            )
        )
        #expect(
            metricEvent.measurements.contains { measurement in
                if case .counter(let sample) = measurement {
                    return sample.label == "agentstudio_performance_terminal_equal_suppressed_count"
                        && sample.value == 1
                }
                return false
            }
        )
    }

    @Test
    func commonQuiescenceGaugeRecordsNonzeroThenZero() throws {
        let factory = OTLPRecordingMetricsFactory()
        let metrics = AgentStudioOTLPPerformanceMetrics(factory: factory)
        let dimensions = [("event", "performance.runtime_delivery.snapshot")]

        metrics.record(
            Self.projectedPerformanceRecord(
                body: "performance.runtime_delivery.snapshot",
                attributes: [
                    "agentstudio.performance.runtime_delivery.total_pending.count": .int(6)
                ]
            ))
        metrics.record(
            Self.projectedPerformanceRecord(
                body: "performance.runtime_delivery.snapshot",
                attributes: [
                    "agentstudio.performance.runtime_delivery.total_pending.count": .int(0)
                ]
            ))

        let gauge = try #require(
            factory.recorder(
                label: "agentstudio_performance_runtime_delivery_total_pending_count",
                dimensions: dimensions
            )
        )
        #expect(gauge.values == [6, 0])
    }

    @Test
    func traceQueueBacklogGaugeRecordsNonzeroThenZero() throws {
        let factory = OTLPRecordingMetricsFactory()
        let metrics = AgentStudioOTLPPerformanceMetrics(factory: factory)
        let dimensions = [("event", "performance.trace_queue.completeness")]

        metrics.record(
            Self.projectedPerformanceRecord(
                body: "performance.trace_queue.completeness",
                attributes: [
                    "agentstudio.performance.trace_queue.pending_request.count": .int(3)
                ]
            ))
        metrics.record(
            Self.projectedPerformanceRecord(
                body: "performance.trace_queue.completeness",
                attributes: [
                    "agentstudio.performance.trace_queue.pending_request.count": .int(0)
                ]
            ))

        let gauge = try #require(
            factory.recorder(
                label: "agentstudio_performance_trace_queue_pending_request_count",
                dimensions: dimensions
            )
        )
        #expect(gauge.values == [3, 0])
    }

    @Test
    func recorderEmitsCumulativeElapsedMaximumGaugeByReason() throws {
        let factory = OTLPRecordingMetricsFactory()
        let metrics = AgentStudioOTLPPerformanceMetrics(factory: factory)
        let dimensions = [
            ("event", "performance.git.status_unavailable"),
            ("reason", "timeout"),
        ]

        metrics.record(Self.gitStatusUnavailableRecord(elapsedMilliseconds: 900))
        metrics.record(Self.gitStatusUnavailableRecord(elapsedMilliseconds: 1200))
        metrics.record(Self.gitStatusUnavailableRecord(elapsedMilliseconds: 700))

        let counter = try #require(
            factory.counter(
                label: "agentstudio_performance_events_total",
                dimensions: dimensions
            )
        )
        let elapsedRecorder = try #require(
            factory.recorder(
                label: "agentstudio_performance_event_elapsed_ms",
                dimensions: dimensions
            )
        )
        let elapsedMaxGauge = try #require(
            factory.recorder(
                label: "agentstudio_performance_event_elapsed_ms_max",
                dimensions: dimensions
            )
        )

        #expect(counter.totalValue == 3)
        #expect(elapsedRecorder.values == [900, 1200, 700])
        #expect(elapsedMaxGauge.values == [900, 1200, 1200])
    }

    @Test
    func elapsedHistogramBucketsKeepTimeoutBoundaryReadable() {
        let buckets = AgentStudioOTLPPerformanceMetrics.elapsedHistogramBuckets
        let adjacentBuckets = zip(buckets, buckets.dropFirst())

        #expect(buckets.contains(1050))
        #expect(buckets.contains(1100))
        #expect(adjacentBuckets.allSatisfy { previous, next in previous < next })
    }

    @Test
    func nonPerformanceRecordsDoNotProducePerformanceMetrics() {
        let record = AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "persistence.operation.phase",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.persistence", version: "0.1.0"),
            attributes: [
                "agentstudio.persistence.operation": .string("workspace.load")
            ]
        )

        #expect(AgentStudioOTLPPerformanceMetricEvent(record: record) == nil)
    }

    private static func gitStatusUnavailableRecord(elapsedMilliseconds: Double) -> AgentStudioOTLPProjectedLogRecord {
        AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 123,
            severityText: .info,
            body: "performance.git.status_unavailable",
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: [
                "agentstudio.performance.elapsed_ms": .double(elapsedMilliseconds),
                "agentstudio.performance.git.status_unavailable.reason": .string("timeout"),
                "agentstudio.trace.tag": .string("performance"),
            ]
        )
    }

    private static func projectedPerformanceRecord(
        body: String,
        attributes: [String: AgentStudioTraceValue]
    ) -> AgentStudioOTLPProjectedLogRecord {
        AgentStudioOTLPProjectedLogRecord(
            timeUnixNano: 458,
            severityText: .info,
            body: body,
            traceID: nil,
            spanID: nil,
            parentSpanID: nil,
            resource: ["service.name": "AgentStudio"],
            scope: .init(name: "agentstudio.performance", version: "0.1.0"),
            attributes: attributes
        )
    }

}
