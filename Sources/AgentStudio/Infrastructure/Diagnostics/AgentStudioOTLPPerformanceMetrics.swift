import Foundation
import Metrics

final class AgentStudioOTLPPerformanceMetrics: @unchecked Sendable {
    static let elapsedMetricLabel = "agentstudio_performance_event_elapsed_ms"
    static let elapsedMaximumMetricLabel = "agentstudio_performance_event_elapsed_ms_max"
    static let elapsedHistogramBuckets: [Double] = [
        0, 0.25, 0.5, 1, 2, 5, 8, 10, 16, 20, 25, 50, 60, 75, 100, 150, 200, 250, 350, 500, 650, 750,
        900, 1000, 1050, 1100,
        1250, 1500, 2000, 2500, 5000, 7500, 10_000,
    ]

    private let factory: any MetricsFactory
    private let lock = NSLock()
    private var eventCounters: [MetricEventKey: Counter] = [:]
    private var elapsedRecorders: [MetricEventKey: Recorder] = [:]
    private var elapsedMaxGauges: [MetricEventKey: Gauge] = [:]
    private var elapsedMaxValues: [MetricEventKey: Double] = [:]
    private var numericGauges: [MetricGaugeKey: Gauge] = [:]
    private var numericCounters: [MetricGaugeKey: Counter] = [:]
    private var distributionRecorders: [MetricGaugeKey: Recorder] = [:]

    init(factory: any MetricsFactory) {
        self.factory = factory
    }

    func record(_ record: AgentStudioOTLPProjectedLogRecord) {
        guard let metricEvent = AgentStudioOTLPPerformanceMetricEvent(record: record) else { return }

        lock.withLock {
            counter(for: metricEvent).increment()

            for measurement in metricEvent.measurements {
                switch measurement {
                case .counter(let sample):
                    counter(for: sample).increment(by: Self.int64Clamped(sample.value))
                case .distribution(let sample):
                    distributionRecorder(for: sample).record(sample.value)
                    if sample.label == Self.elapsedMetricLabel {
                        recordElapsedMaximum(sample.value, for: metricEvent)
                    }
                case .gauge(let sample):
                    gauge(for: sample).record(sample.value)
                }
            }
        }
    }

    private func counter(for event: AgentStudioOTLPPerformanceMetricEvent) -> Counter {
        let key = MetricEventKey(eventName: event.eventName, dimensions: event.dimensions)
        if let counter = eventCounters[key] {
            return counter
        }

        let counter = Counter(
            label: "agentstudio_performance_events_total",
            dimensions: event.dimensionTuples,
            factory: factory
        )
        eventCounters[key] = counter
        return counter
    }

    private func recorder(for event: AgentStudioOTLPPerformanceMetricEvent) -> Recorder {
        let key = MetricEventKey(eventName: event.eventName, dimensions: event.dimensions)
        if let recorder = elapsedRecorders[key] {
            return recorder
        }

        let recorder = Recorder(
            label: Self.elapsedMetricLabel,
            dimensions: event.dimensionTuples,
            factory: factory
        )
        elapsedRecorders[key] = recorder
        return recorder
    }

    private func recordElapsedMaximum(_ elapsedMilliseconds: Double, for event: AgentStudioOTLPPerformanceMetricEvent) {
        let key = MetricEventKey(eventName: event.eventName, dimensions: event.dimensions)
        let maximumElapsedMilliseconds = max(elapsedMaxValues[key] ?? elapsedMilliseconds, elapsedMilliseconds)
        elapsedMaxValues[key] = maximumElapsedMilliseconds
        elapsedMaximumGauge(for: event).record(maximumElapsedMilliseconds)
    }

    private func elapsedMaximumGauge(for event: AgentStudioOTLPPerformanceMetricEvent) -> Gauge {
        let key = MetricEventKey(eventName: event.eventName, dimensions: event.dimensions)
        if let gauge = elapsedMaxGauges[key] {
            return gauge
        }

        let gauge = Gauge(
            label: Self.elapsedMaximumMetricLabel,
            dimensions: event.dimensionTuples,
            factory: factory
        )
        elapsedMaxGauges[key] = gauge
        return gauge
    }

    private func gauge(for sample: AgentStudioOTLPPerformanceMetricSample) -> Gauge {
        let key = MetricGaugeKey(eventName: sample.eventName, label: sample.label, dimensions: sample.dimensions)
        if let gauge = numericGauges[key] {
            return gauge
        }

        let gauge = Gauge(
            label: sample.label,
            dimensions: sample.dimensionTuples,
            factory: factory
        )
        numericGauges[key] = gauge
        return gauge
    }

    private func counter(for sample: AgentStudioOTLPPerformanceMetricSample) -> Counter {
        let key = MetricGaugeKey(eventName: sample.eventName, label: sample.label, dimensions: sample.dimensions)
        if let counter = numericCounters[key] {
            return counter
        }
        let counter = Counter(label: sample.label, dimensions: sample.dimensionTuples, factory: factory)
        numericCounters[key] = counter
        return counter
    }

    private func distributionRecorder(for sample: AgentStudioOTLPPerformanceMetricSample) -> Recorder {
        if sample.label == Self.elapsedMetricLabel {
            return recorder(
                for: AgentStudioOTLPPerformanceMetricEvent(
                    eventName: sample.eventName,
                    dimensions: sample.dimensions,
                    elapsedMilliseconds: sample.value,
                    samples: [],
                    measurements: []
                ))
        }
        let key = MetricGaugeKey(eventName: sample.eventName, label: sample.label, dimensions: sample.dimensions)
        if let recorder = distributionRecorders[key] {
            return recorder
        }
        let recorder = Recorder(label: sample.label, dimensions: sample.dimensionTuples, factory: factory)
        distributionRecorders[key] = recorder
        return recorder
    }

    private static func int64Clamped(_ value: Double) -> Int64 {
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }
}

package struct AgentStudioOTLPPerformanceMetricEvent: Equatable, Sendable {
    package let eventName: String
    let dimensions: [AgentStudioOTLPPerformanceMetricDimension]
    package let elapsedMilliseconds: Double?
    let samples: [AgentStudioOTLPPerformanceMetricSample]
    let measurements: [AgentStudioOTLPPerformanceMeasurement]

    var dimensionTuples: [(String, String)] {
        dimensions.map(\.tuple)
    }

    package init?(record: AgentStudioOTLPProjectedLogRecord) {
        guard record.body.hasPrefix("performance.") else { return nil }
        if record.body.hasPrefix("performance.bridge.") {
            guard Self.hasCompleteBridgeMetricTaxonomy(record) else { return nil }
        }
        if Self.requiresSidebarMetricTaxonomy(record) {
            guard Self.hasCompleteSidebarMetricTaxonomy(record) else { return nil }
        }

        let dimensions = Self.dimensions(for: record)
        self.eventName = record.body
        self.dimensions = dimensions
        self.elapsedMilliseconds = Self.doubleValue(
            record.attributes["agentstudio.performance.elapsed_ms"]
        )
        let samples: [AgentStudioOTLPPerformanceMetricSample] = record.attributes.compactMap { element in
            let (key, value) = element
            guard key != "agentstudio.performance.elapsed_ms" else { return nil }
            guard let numericValue = Self.doubleValue(value) else { return nil }
            guard let metricLabel = Self.metricLabel(for: key) else { return nil }
            return AgentStudioOTLPPerformanceMetricSample(
                eventName: record.body,
                label: metricLabel,
                dimensions: dimensions,
                value: numericValue
            )
        }
        .sorted { left, right in
            if left.label == right.label {
                return left.eventName < right.eventName
            }
            return left.label < right.label
        }
        self.samples = samples
        var measurements: [AgentStudioOTLPPerformanceMeasurement] = samples.compactMap { sample in
            Self.measurement(for: sample)
        }
        if let elapsedMilliseconds {
            measurements.append(
                .distribution(
                    AgentStudioOTLPPerformanceMetricSample(
                        eventName: record.body,
                        label: AgentStudioOTLPPerformanceMetrics.elapsedMetricLabel,
                        dimensions: dimensions,
                        value: elapsedMilliseconds
                    )))
        }
        self.measurements = measurements.sorted { $0.sortKey < $1.sortKey }
    }

    fileprivate init(
        eventName: String,
        dimensions: [AgentStudioOTLPPerformanceMetricDimension],
        elapsedMilliseconds: Double?,
        samples: [AgentStudioOTLPPerformanceMetricSample],
        measurements: [AgentStudioOTLPPerformanceMeasurement]
    ) {
        self.eventName = eventName
        self.dimensions = dimensions
        self.elapsedMilliseconds = elapsedMilliseconds
        self.samples = samples
        self.measurements = measurements
    }

    private static func dimensions(for record: AgentStudioOTLPProjectedLogRecord)
        -> [AgentStudioOTLPPerformanceMetricDimension]
    {
        var dimensions = [
            AgentStudioOTLPPerformanceMetricDimension(name: "event", value: record.body)
        ]
        if record.body == "performance.interaction.latency",
            case .string(let interactionKind) = record.attributes[
                "agentstudio.performance.interaction.kind"
            ],
            isSafeDimensionValue(interactionKind)
        {
            dimensions.append(
                AgentStudioOTLPPerformanceMetricDimension(
                    name: "interaction_kind",
                    value: interactionKind
                )
            )
        }
        if record.body == "performance.repo_explorer.outline_apply_proxy",
            case .string(let outcome) = record.attributes[
                "agentstudio.performance.repo_explorer.outline_apply_proxy.outcome"
            ],
            ["equal", "changed"].contains(outcome)
        {
            dimensions.append(
                AgentStudioOTLPPerformanceMetricDimension(name: "outcome", value: outcome)
            )
        }
        appendRepoExplorerInstrumentDimensions(record: record, dimensions: &dimensions)
        appendRepoExplorerNativeTablePilotDimensions(record: record, dimensions: &dimensions)
        appendStageOutcomeDimensions(record: record, dimensions: &dimensions)
        appendScrollbackPassDimensions(record: record, dimensions: &dimensions)
        appendGitDimensions(record: record, dimensions: &dimensions)
        if record.body == "performance.terminal.accumulator_drain",
            case .string(let drainClass) = record.attributes[
                "agentstudio.performance.terminal.accumulator.drain.class"
            ],
            isSafeDimensionValue(drainClass)
        {
            dimensions.append(
                AgentStudioOTLPPerformanceMetricDimension(name: "drain_class", value: drainClass)
            )
        }
        appendTerminalAccumulatorApplyOutcomeDimension(record: record, dimensions: &dimensions)
        appendTerminalEqualSuppressedDimension(record: record, dimensions: &dimensions)
        appendRendererLifecycleEventKindDimension(record: record, dimensions: &dimensions)
        appendPaneAssociationOutcomeDimension(record: record, dimensions: &dimensions)
        appendAtomDimensions(record: record, dimensions: &dimensions)
        appendRepoExplorerKeyedWakeDimensions(record: record, dimensions: &dimensions)
        if record.body.hasPrefix("performance.bridge.") {
            appendBridgeDimensions(record: record, dimensions: &dimensions)
        }
        if Self.requiresSidebarMetricTaxonomy(record) {
            appendSafeStringDimension(
                name: "surface",
                attributeKey: "agentstudio.performance.sidebar.surface",
                record: record,
                dimensions: &dimensions
            )
            appendSafeStringDimension(
                name: "phase",
                attributeKey: "agentstudio.performance.sidebar.phase",
                record: record,
                dimensions: &dimensions
            )
            appendSafeStringDimension(
                name: "query_state",
                attributeKey: "agentstudio.performance.sidebar.query_state",
                record: record,
                dimensions: &dimensions
            )
            appendSafeStringDimension(
                name: "group_mode",
                attributeKey: "agentstudio.performance.sidebar.group_mode",
                record: record,
                dimensions: &dimensions
            )
            appendSafeStringDimension(
                name: "trigger",
                attributeKey: "agentstudio.performance.sidebar.trigger",
                record: record,
                dimensions: &dimensions
            )
        }
        return dimensions
    }

    private static func appendGitStatusOutcomeDimension(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard ["performance.git.status", "performance.git.status_unavailable"].contains(record.body),
            case .string(let outcome) = record.attributes["agentstudio.performance.git.status.last_outcome"],
            ["completed", "timeout", "unavailable"].contains(outcome)
        else { return }
        dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: "last_outcome", value: outcome))
    }

    private static func appendGitDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        if record.body == "performance.git.status_unavailable",
            case .string(let reason) = record.attributes["agentstudio.performance.git.status_unavailable.reason"],
            isSafeDimensionValue(reason)
        {
            dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: "reason", value: reason))
        }
        if record.body == "performance.git.status",
            case .string(let scope) = record.attributes["agentstudio.performance.git.status_scope"],
            isSafeDimensionValue(scope)
        {
            dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: "scope", value: scope))
        }
        if record.body == "performance.git.status",
            case .string(let triggerSource) = record.attributes["agentstudio.performance.git.trigger_source"],
            [
                "registration", "filesystem_change", "periodic", "visibility_change",
                "remote_reference_refresh", "retry",
            ].contains(triggerSource)
        {
            dimensions.append(
                AgentStudioOTLPPerformanceMetricDimension(name: "trigger_source", value: triggerSource)
            )
        }
        appendGitStatusOutcomeDimension(record: record, dimensions: &dimensions)
        if record.body == "performance.git.backoff",
            case .string(let reason) = record.attributes["agentstudio.performance.git.backoff.reason"],
            isSafeDimensionValue(reason)
        {
            dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: "reason", value: reason))
        }
    }

    private static func appendRepoExplorerKeyedWakeDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard
            [
                "performance.repo_explorer.keyed_wake",
                "performance.repo_explorer.stage_snapshot",
            ].contains(record.body)
        else { return }
        for (name, attributeKey) in [
            ("stage", "agentstudio.performance.repo_explorer.stage"),
            ("key_class", "agentstudio.performance.repo_explorer.key_class"),
            ("outcome", "agentstudio.performance.repo_explorer.outcome"),
            ("facet", "agentstudio.performance.repo_explorer.facet"),
            ("row_relation", "agentstudio.performance.repo_explorer.row_relation"),
        ] {
            appendSafeStringDimension(
                name: name,
                attributeKey: attributeKey,
                record: record,
                dimensions: &dimensions
            )
        }
    }

    private static func appendRepoExplorerNativeTablePilotDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.repo_explorer.native_table_pilot" else { return }
        for (name, attributeKey) in [
            ("scale", "agentstudio.performance.repo_explorer.native_table_pilot.scale"),
            ("outcome", "agentstudio.performance.repo_explorer.native_table_pilot.outcome"),
        ] {
            appendSafeStringDimension(
                name: name,
                attributeKey: attributeKey,
                record: record,
                dimensions: &dimensions
            )
        }
    }

    private static func appendRepoExplorerInstrumentDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard
            [
                "performance.repo_explorer.row_body_evaluation",
                "performance.repo_explorer.scroll_frame_gap",
            ].contains(record.body)
        else { return }
        for (name, attributeKey) in [
            ("outcome", "agentstudio.performance.repo_explorer.row_body_evaluation.outcome"),
            ("outcome", "agentstudio.performance.repo_explorer.scroll_frame_gap.outcome"),
            ("row_kind", "agentstudio.performance.repo_explorer.row_kind"),
            ("surface", "agentstudio.performance.repo_explorer.surface"),
            ("visible_row_count_bucket", "agentstudio.performance.repo_explorer.visible_row_count_bucket"),
        ] {
            appendSafeStringDimension(
                name: name,
                attributeKey: attributeKey,
                record: record,
                dimensions: &dimensions
            )
        }
    }

    private static func appendStageOutcomeDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        let prefix: String
        switch record.body {
        case "performance.filesystem.stage_outcome": prefix = "filesystem"
        case "performance.forge.refresh": prefix = "forge"
        case "performance.repository_fact_update": prefix = "repository_update"
        default: return
        }
        for name in ["stage", "outcome"] {
            appendSafeStringDimension(
                name: name,
                attributeKey: "agentstudio.performance.\(prefix).\(name)",
                record: record,
                dimensions: &dimensions
            )
        }
    }

    private static func appendAtomDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.atom.derived",
            record.attributes["agentstudio.performance.atom.kind"] == .string("eager_derived_family")
        else { return }
        appendSafeStringDimension(
            name: "atom_kind",
            attributeKey: "agentstudio.performance.atom.kind",
            record: record,
            dimensions: &dimensions
        )
        appendSafeStringDimension(
            name: "atom_label",
            attributeKey: "agentstudio.performance.atom.label",
            record: record,
            dimensions: &dimensions
        )
        appendSafeStringDimension(
            name: "atom_operation",
            attributeKey: "agentstudio.performance.atom.operation",
            record: record,
            dimensions: &dimensions
        )
        guard case .string(let outcome) = record.attributes["agentstudio.performance.atom.outcome"],
            ["published", "equal", "superseded", "cancelled"].contains(outcome)
        else { return }
        dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: "outcome", value: outcome))
    }

    private static func appendTerminalAccumulatorApplyOutcomeDimension(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.terminal.accumulator_drain",
            case .string(let outcome) = record.attributes[
                "agentstudio.performance.terminal.accumulator.apply.outcome"
            ],
            ["equal", "changed"].contains(outcome)
        else {
            return
        }
        dimensions.append(
            AgentStudioOTLPPerformanceMetricDimension(name: "outcome", value: outcome)
        )
    }

    private static func appendPaneAssociationOutcomeDimension(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.pane.association",
            case .string(let outcome) = record.attributes[
                "agentstudio.performance.pane.association_outcome"
            ],
            PaneAssociationOutcome(rawValue: outcome) != nil
        else { return }
        dimensions.append(
            AgentStudioOTLPPerformanceMetricDimension(
                name: "association_outcome",
                value: outcome
            )
        )
    }

    private static func appendTerminalEqualSuppressedDimension(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.terminal.equal_suppressed",
            case .string(let publicationKind) = record.attributes[
                "agentstudio.performance.terminal.publication.kind"
            ],
            ["activity", "cwd", "title"].contains(publicationKind)
        else { return }
        dimensions.append(
            AgentStudioOTLPPerformanceMetricDimension(
                name: "publication_kind",
                value: publicationKind
            )
        )
    }

    private static func appendRendererLifecycleEventKindDimension(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard record.body == "performance.renderer.lifecycle",
            case .string(let eventKind) = record.attributes["agentstudio.performance.renderer.event.kind"],
            RendererLifecycleAction(rawValue: eventKind) != nil
        else { return }
        dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: "event_kind", value: eventKind))
    }

    private static func appendBridgeDimensions(
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        let bridgeDimensionAttributes = [
            ("agent.proof.marker", "agent.proof.marker"),
            ("phase", "agentstudio.bridge.phase"),
            ("plane", "agentstudio.bridge.plane"),
            ("priority", "agentstudio.bridge.priority"),
            ("slice", "agentstudio.bridge.slice"),
            ("lane", "agentstudio.bridge.demand.lane"),
            ("variant", "agentstudio.bridge.viewer.ttfi_variant"),
            ("native_capacity_event", "agentstudio.bridge.native_capacity.event"),
            ("operation_class", "agentstudio.bridge.native_capacity.operation_class"),
            ("activity_rank", "agentstudio.bridge.native_capacity.activity_rank"),
            ("product_kind", "agentstudio.bridge.native_capacity.product_kind"),
            ("semantic_class", "agentstudio.bridge.worker.semantic_class"),
            ("viewer", "agentstudio.bridge.viewer"),
            ("render_disposition_outcome", "agentstudio.bridge.render_disposition.outcome"),
            ("render_publication_outcome", "agentstudio.bridge.render_publication.outcome"),
        ]
        for (name, attributeKey) in bridgeDimensionAttributes {
            appendBridgeDimension(
                name: name,
                attributeKey: attributeKey,
                record: record,
                dimensions: &dimensions
            )
        }
        if record.body.hasSuffix(".pane_presentation") {
            let panePresentationDimensions = [
                ("comparison_status", "agentstudio.bridge.comparison.attempt.status"),
                ("package_match", "agentstudio.bridge.comparison.package_match"),
                ("pane_state", "agentstudio.bridge.comparison.pane_state"),
                ("result", "agentstudio.bridge.result"),
                ("result_reason", "agentstudio.bridge.result_reason"),
            ]
            for (name, attributeKey) in panePresentationDimensions {
                appendBridgeDimension(
                    name: name,
                    attributeKey: attributeKey,
                    record: record,
                    dimensions: &dimensions
                )
            }
        }
    }

    private static func measurement(
        for sample: AgentStudioOTLPPerformanceMetricSample
    ) -> AgentStudioOTLPPerformanceMeasurement? {
        if isCounterMetricLabel(sample.label) {
            guard sample.value >= 0 else { return nil }
            return .counter(sample)
        }
        return .gauge(sample)
    }

    private static let counterMetricLabels: Set<String> = [
        "agentstudio_bridge_render_disposition_accepted_count",
        "agentstudio_bridge_render_disposition_batch_receipt_count",
        "agentstudio_bridge_render_disposition_duplicate_count",
        "agentstudio_bridge_render_disposition_rejected_count",
        "agentstudio_performance_filesystem_affected_key_request_count",
        "agentstudio_performance_filesystem_full_reconciliation_request_count",
        "agentstudio_performance_repo_explorer_interval_count",
        "agentstudio_performance_terminal_accumulator_equal_suppressed_count",
        "agentstudio_performance_terminal_accumulator_follow_up_drain_count",
        "agentstudio_performance_terminal_accumulator_mainactor_task_count",
        "agentstudio_performance_terminal_accumulator_offered_count",
        "agentstudio_performance_terminal_accumulator_replaced_count",
        "agentstudio_performance_terminal_accumulator_scheduled_drain_count",
        "agentstudio_performance_terminal_activity_aggregate_count",
        "agentstudio_performance_terminal_equal_write_suppressed_count",
        "agentstudio_performance_terminal_equal_suppressed_count",
        "agentstudio_performance_trace_identity_coalesced_request_count",
        "agentstudio_performance_trace_identity_equal_snapshot_suppressed_count",
        "agentstudio_performance_trace_identity_fleet_capture_count",
        "agentstudio_performance_trace_identity_refresh_request_count",
    ]

    private static func isCounterMetricLabel(_ label: String) -> Bool {
        counterMetricLabels.contains(label)
            || isScrollbackCounterMetricLabel(label)
            || (label.hasPrefix("agentstudio_performance_renderer_") && label.hasSuffix("_delta"))
            || (label.hasPrefix("agentstudio_performance_filesystem_ingress_")
                && label.hasSuffix("_count"))
            || (label.hasPrefix("agentstudio_performance_forge_") && label.hasSuffix("_count"))
            || (label.hasPrefix("agentstudio_performance_git_aggregate_") && label.hasSuffix("_count"))
            || (label.hasPrefix("agentstudio_performance_repository_fact_demand_")
                && label.hasSuffix("_count"))
            || (label.hasPrefix("agentstudio_performance_remote_reference_")
                && label.hasSuffix("_count"))
    }

    private static func doubleValue(_ value: AgentStudioTraceValue?) -> Double? {
        switch value {
        case .double(let doubleValue):
            guard doubleValue.isFinite else { return nil }
            return doubleValue
        case .int(let intValue):
            return Double(intValue)
        case .bool(let boolValue):
            return boolValue ? 1 : 0
        case .string, .stringArray, .none:
            return nil
        }
    }

    private static func metricLabel(for attributeKey: String) -> String? {
        if attributeKey.hasPrefix("agentstudio.performance.") {
            let suffix = String(attributeKey.dropFirst("agentstudio.performance.".count))
            return metricLabel(prefix: "agentstudio_performance", suffix: suffix)
        }

        guard allowedBridgeMetricAttributeKeys.contains(attributeKey) else { return nil }
        let suffix = String(attributeKey.dropFirst("agentstudio.bridge.".count))
        return metricLabel(prefix: "agentstudio_bridge", suffix: suffix)
    }

    private static func metricLabel(prefix: String, suffix: String) -> String? {
        guard !suffix.isEmpty else { return nil }

        let sanitized = suffix.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        .reduce(into: "") { partialResult, character in
            if character == "_", partialResult.last == "_" {
                return
            }
            partialResult.append(character)
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        guard !sanitized.isEmpty else { return nil }
        return "\(prefix)_\(sanitized)"
    }

    private static let allowedBridgeMetricAttributeKeys: Set<String> = [
        "agentstudio.bridge.batch.sample_count",
        "agentstudio.bridge.content.byte_size_bucket",
        "agentstudio.bridge.content.line_count_bucket",
        "agentstudio.bridge.demand.queue_depth",
        "agentstudio.bridge.demand.scheduler_queue_wait_ms",
        "agentstudio.bridge.demand.stale_drop.count",
        "agentstudio.bridge.metadata_manifest.emitted_total",
        "agentstudio.bridge.metadata_manifest.expected_total",
        "agentstudio.bridge.metadata_manifest.remaining_total",
        "agentstudio.bridge.native_capacity.coalesced_waiter.count",
        "agentstudio.bridge.native_capacity.deadline.count",
        "agentstudio.bridge.native_capacity.draining.count",
        "agentstudio.bridge.native_capacity.entry.count",
        "agentstudio.bridge.native_capacity.fairness_history.count",
        "agentstudio.bridge.native_capacity.in_flight.count",
        "agentstudio.bridge.native_capacity.lease.count",
        "agentstudio.bridge.native_capacity.locator.count",
        "agentstudio.bridge.native_capacity.logical_waiter.count",
        "agentstudio.bridge.native_capacity.occupied_slot.count",
        "agentstudio.bridge.native_capacity.pane_activity.count",
        "agentstudio.bridge.native_capacity.payload.count",
        "agentstudio.bridge.native_capacity.queued.count",
        "agentstudio.bridge.native_capacity.retained_artifact_byte.count",
        "agentstudio.bridge.native_capacity.running.count",
        "agentstudio.bridge.native_capacity.tombstone.count",
        "agentstudio.bridge.native_capacity.waiter.count",
        "agentstudio.bridge.native_capacity.worktree.count",
        "agentstudio.bridge.render_disposition.accepted_count",
        "agentstudio.bridge.render_disposition.batch_receipt_count",
        "agentstudio.bridge.render_disposition.duplicate_count",
        "agentstudio.bridge.render_disposition.in_flight_count",
        "agentstudio.bridge.render_disposition.oldest_pending_age_ms",
        "agentstudio.bridge.render_disposition.pending_count",
        "agentstudio.bridge.render_disposition.pending_high_water_mark",
        "agentstudio.bridge.render_disposition.produced_count",
        "agentstudio.bridge.render_disposition.rejected_count",
        "agentstudio.bridge.render_disposition.retained_count",
        "agentstudio.bridge.render_publication.current_count",
        "agentstudio.bridge.render_publication.high_water_mark",
        "agentstudio.bridge.render_publication.oldest_age_ms",
        "agentstudio.bridge.telemetry.dropped_count",
    ]

    private static func hasCompleteBridgeMetricTaxonomy(_ record: AgentStudioOTLPProjectedLogRecord) -> Bool {
        BridgeTelemetryWireSchema.hasCompleteTaxonomy(
            stringAttributes: [
                "agentstudio.bridge.phase": stringAttribute(record, "agentstudio.bridge.phase"),
                "agentstudio.bridge.plane": stringAttribute(record, "agentstudio.bridge.plane"),
                "agentstudio.bridge.priority": stringAttribute(record, "agentstudio.bridge.priority"),
                "agentstudio.bridge.slice": stringAttribute(record, "agentstudio.bridge.slice"),
            ].compactMapValues { $0 }
        )
    }

    private static func hasCompleteSidebarMetricTaxonomy(_ record: AgentStudioOTLPProjectedLogRecord) -> Bool {
        SidebarMetricSurface(rawValue: stringAttribute(record, "agentstudio.performance.sidebar.surface") ?? "") != nil
            && SidebarMetricPhase(rawValue: stringAttribute(record, "agentstudio.performance.sidebar.phase") ?? "")
                != nil
            && SidebarMetricQueryState(
                rawValue: stringAttribute(record, "agentstudio.performance.sidebar.query_state") ?? "") != nil
            && SidebarMetricGroupMode(
                rawValue: stringAttribute(record, "agentstudio.performance.sidebar.group_mode") ?? "") != nil
            && SidebarMetricTrigger(rawValue: stringAttribute(record, "agentstudio.performance.sidebar.trigger") ?? "")
                != nil
    }

    private static func requiresSidebarMetricTaxonomy(_ record: AgentStudioOTLPProjectedLogRecord) -> Bool {
        record.body == "performance.sidebar.projection" || record.body == "performance.sidebar.row_index"
    }

    private static func stringAttribute(_ record: AgentStudioOTLPProjectedLogRecord, _ key: String) -> String? {
        guard case .string(let value) = record.attributes[key] else { return nil }
        return value
    }

    private static func appendBridgeDimension(
        name: String,
        attributeKey: String,
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        appendSafeStringDimension(name: name, attributeKey: attributeKey, record: record, dimensions: &dimensions)
    }

    private static func appendSafeStringDimension(
        name: String,
        attributeKey: String,
        record: AgentStudioOTLPProjectedLogRecord,
        dimensions: inout [AgentStudioOTLPPerformanceMetricDimension]
    ) {
        guard case .string(let value) = record.attributes[attributeKey] else { return }
        dimensions.append(AgentStudioOTLPPerformanceMetricDimension(name: name, value: value))
    }

    private static func isSafeDimensionValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_"
                || scalar == "-"
                || scalar == "."
        }
    }
}

enum AgentStudioOTLPPerformanceMeasurement: Equatable, Sendable {
    case counter(AgentStudioOTLPPerformanceMetricSample)
    case distribution(AgentStudioOTLPPerformanceMetricSample)
    case gauge(AgentStudioOTLPPerformanceMetricSample)

    fileprivate var sortKey: String {
        switch self {
        case .counter(let sample):
            "counter:\(sample.label)"
        case .distribution(let sample):
            "distribution:\(sample.label)"
        case .gauge(let sample):
            "gauge:\(sample.label)"
        }
    }
}

private enum SidebarMetricSurface: String {
    case inbox
    case repo
}

private enum SidebarMetricPhase: String {
    case pinnedCaptureMainActor = "pinned_capture_mainactor"
    case pinnedProjectionWorker = "pinned_projection_worker"
    case requestBuildMainActor = "request_build_mainactor"
    case projectionWorker = "projection_worker"
    case mainActorApply = "mainactor_apply"
    case rowIndex = "row_index"
    case startupDiagnostic = "startup_diagnostic"
    case surfaceSwitch = "surface_switch"
}

private enum SidebarMetricQueryState: String {
    case empty
    case nonEmpty = "non_empty"
}

private enum SidebarMetricGroupMode: String {
    case repo
    case pane
    case tab
    case noGrouping = "none"
    case notApplicable = "not_applicable"
}

private enum SidebarMetricTrigger: String {
    case pinnedNavigation = "pinned_navigation"
    case groupingSwitch = "grouping_switch"
    case surfaceSwitch = "surface_switch"
    case search
    case sortOrder = "sort_order"
    case collapseToggle = "collapse_toggle"
    case dataRefresh = "data_refresh"
    case startupDiagnostic = "startup_diagnostic"
}

struct AgentStudioOTLPPerformanceMetricSample: Equatable, Sendable {
    let eventName: String
    let label: String
    let dimensions: [AgentStudioOTLPPerformanceMetricDimension]
    let value: Double

    var dimensionTuples: [(String, String)] {
        dimensions.map(\.tuple)
    }
}

struct AgentStudioOTLPPerformanceMetricDimension: Equatable, Hashable, Sendable {
    let name: String
    let value: String

    var tuple: (String, String) {
        (name, value)
    }
}

private struct MetricEventKey: Hashable {
    let eventName: String
    let dimensions: [AgentStudioOTLPPerformanceMetricDimension]
}

private struct MetricGaugeKey: Hashable {
    let eventName: String
    let label: String
    let dimensions: [AgentStudioOTLPPerformanceMetricDimension]
}
