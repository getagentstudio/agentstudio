import type { BridgeTelemetrySample } from '../../src/foundation/telemetry/bridge-telemetry-event.js';

export interface BridgeDevTelemetryObservation {
	readonly scenario: string;
	readonly samples: readonly BridgeTelemetrySample[];
}

interface BuildBridgeDevTelemetryLogRecordProps {
	readonly marker: string;
	readonly observation: BridgeDevTelemetryObservation;
	readonly receivedAtUnixNano: string;
	readonly sample: BridgeTelemetrySample;
	readonly serviceVersion: string;
	readonly worktreeHash: string;
}

interface BuildBridgeDevTelemetryOTLPRequestProps {
	readonly marker: string;
	readonly observation: BridgeDevTelemetryObservation;
	readonly receivedAtUnixNano: string;
	readonly serviceVersion: string;
	readonly worktreeHash: string;
}

interface OTelAnyValue {
	readonly stringValue?: string;
	readonly intValue?: string;
	readonly doubleValue?: number;
	readonly boolValue?: boolean;
}

interface OTelKeyValue {
	readonly key: string;
	readonly value: OTelAnyValue;
}

interface OTelLogRecord {
	readonly body: OTelAnyValue;
	readonly attributes: readonly OTelKeyValue[];
	readonly severityNumber: number;
	readonly severityText: 'info';
	readonly timeUnixNano: string;
}

type OTelMetric =
	| {
			readonly name: string;
			readonly sum: {
				readonly aggregationTemporality: 2;
				readonly isMonotonic: boolean;
				readonly dataPoints: readonly OTelMetricDataPoint[];
			};
	  }
	| {
			readonly name: string;
			readonly gauge: {
				readonly dataPoints: readonly OTelMetricDataPoint[];
			};
	  }
	| {
			readonly name: string;
			readonly histogram: {
				readonly aggregationTemporality: 2;
				readonly dataPoints: readonly OTelHistogramDataPoint[];
			};
	  };

interface OTelMetricDataPoint {
	readonly timeUnixNano: string;
	readonly attributes: readonly OTelKeyValue[];
	readonly asInt?: string;
	readonly asDouble?: number;
}

interface OTelHistogramDataPoint {
	readonly timeUnixNano: string;
	readonly attributes: readonly OTelKeyValue[];
	readonly count: string;
	readonly sum: number;
	readonly bucketCounts: readonly string[];
	readonly explicitBounds: readonly number[];
	readonly min: number;
	readonly max: number;
}

const bridgeDevRuntimeFlavor = 'vite-dev';
const bridgeDevReleaseChannel = 'local';
const elapsedHistogramBounds = [
	0, 5, 10, 25, 50, 75, 100, 150, 200, 250, 350, 500, 650, 750, 900, 1000, 1050, 1100, 1250, 1500,
	2000, 2500, 5000, 7500, 10_000,
] as const satisfies readonly number[];

const bridgeDevStringAttributeKeys = new Set<string>([
	'agentstudio.bridge.activation.cause',
	'agentstudio.bridge.activation.from_viewer',
	'agentstudio.bridge.anchor_restore.phase',
	'agentstudio.bridge.comparison.attempt.status',
	'agentstudio.bridge.comparison.package_match',
	'agentstudio.bridge.comparison.pane_state',
	'agentstudio.bridge.content.correlation_mode',
	'agentstudio.bridge.content.interest',
	'agentstudio.bridge.content.priority',
	'agentstudio.bridge.content.role',
	'agentstudio.bridge.content_bytes_bucket',
	'agentstudio.bridge.demand.disposition',
	'agentstudio.bridge.demand.lane',
	'agentstudio.bridge.drop_reason',
	'agentstudio.bridge.file_size_bucket',
	'agentstudio.bridge.fixture_class',
	'agentstudio.bridge.frame_jank.kind',
	'agentstudio.bridge.generation_relation',
	'agentstudio.bridge.header_missing',
	'agentstudio.bridge.header_supported',
	'agentstudio.bridge.item_count_bucket',
	'agentstudio.bridge.item_update.kind',
	'agentstudio.bridge.input.source',
	'agentstudio.bridge.interaction.attempt_id',
	'agentstudio.bridge.language_class',
	'agentstudio.bridge.markdown.fallback_reason',
	'agentstudio.bridge.operation.id',
	'agentstudio.bridge.phase',
	'agentstudio.bridge.panel.operation',
	'agentstudio.bridge.plane',
	'agentstudio.bridge.presentation.disposition',
	'agentstudio.bridge.priority',
	'agentstudio.bridge.protocol',
	'agentstudio.bridge.projection.kind',
	'agentstudio.bridge.queue.depth_bucket',
	'agentstudio.bridge.result',
	'agentstudio.bridge.result_reason',
	'agentstudio.bridge.render_disposition.outcome',
	'agentstudio.bridge.render_publication.outcome',
	'agentstudio.bridge.review.refresh.install_trigger',
	'agentstudio.bridge.review.refresh.presentation_class',
	'agentstudio.bridge.review.refresh.promotion_reason',
	'agentstudio.bridge.rpc.method_class',
	'agentstudio.bridge.selection.origin',
	'agentstudio.bridge.slice',
	'agentstudio.bridge.scroll.offset',
	'agentstudio.bridge.scroll.reason',
	'agentstudio.bridge.surface',
	'agentstudio.bridge.telemetry.drop_reason',
	'agentstudio.bridge.transport',
	'agentstudio.bridge.tree_path_count_bucket',
	'agentstudio.bridge.viewer',
	'agentstudio.bridge.viewer.ttfi_variant',
	'agentstudio.bridge.worker.action',
	'agentstudio.bridge.worker.command',
	'agentstudio.bridge.worker.file_mode_dispatch',
	'agentstudio.bridge.worker.file_select_dispatch',
	'agentstudio.bridge.worker.lane',
	'agentstudio.bridge.worker.payload_class',
	'agentstudio.bridge.worker.review_select_dispatch',
	'agentstudio.bridge.worker.replacement_reason',
	'agentstudio.bridge.worker.replacement_source',
	'agentstudio.bridge.worker.semantic_class',
	'agentstudio.bridge.worker.session_state',
	'agentstudio.bridge.worker.task_kind',
	'agentstudio.bridge.worker.work_kind',
]);

const bridgeDevRestrictedStringAttributeValuesByKey = new Map<string, ReadonlySet<string>>([
	[
		'agentstudio.bridge.anchor_restore.phase',
		new Set([
			'capture',
			'direct_restore',
			'path_order_restore',
			'raf_restore',
			'scroll_to_path_reveal',
		]),
	],
	[
		'agentstudio.bridge.activation.cause',
		new Set(['context_switcher', 'native_request', 'review_file_corner']),
	],
	['agentstudio.bridge.activation.from_viewer', new Set(['file', 'review'])],
	[
		'agentstudio.bridge.comparison.attempt.status',
		new Set(['absent', 'pending', 'selection_required', 'settled', 'unavailable']),
	],
	[
		'agentstudio.bridge.comparison.package_match',
		new Set([
			'matched',
			'snapshot_not_current',
			'package_absent',
			'package_id_mismatch',
			'review_generation_mismatch',
			'revision_mismatch',
		]),
	],
	[
		'agentstudio.bridge.comparison.pane_state',
		new Set([
			'failed_initial',
			'failed_previous',
			'loading_initial',
			'loading_previous',
			'settled',
		]),
	],
	[
		'agentstudio.bridge.demand.disposition',
		new Set([
			'active-preloaded',
			'cache-hit',
			'cold-loaded',
			'idle-preloaded',
			'nearby-preloaded',
			'none',
			'published',
			'refreshed',
			'speculative-preloaded',
			'visible-preloaded',
		]),
	],
	['agentstudio.bridge.frame_jank.kind', new Set(['dropped_frame', 'long_task'])],
	['agentstudio.bridge.input.source', new Set(['keyboard', 'mouse', 'programmatic'])],
	['agentstudio.bridge.panel.operation', new Set(['reset', 'upsert'])],
	[
		'agentstudio.bridge.presentation.disposition',
		new Set(['applied', 'idempotent_replay', 'published', 'rendered']),
	],
	['agentstudio.bridge.viewer.ttfi_variant', new Set(['cold', 'warm'])],
	[
		'agentstudio.bridge.selection.origin',
		new Set(['context_switcher', 'native_request', 'review_file_corner']),
	],
	[
		'agentstudio.bridge.worker.file_mode_dispatch',
		new Set(['dropped_detached', 'none', 'posted', 'queued_not_ready']),
	],
	[
		'agentstudio.bridge.worker.file_select_dispatch',
		new Set(['dropped_detached', 'none', 'posted', 'queued_not_ready']),
	],
	[
		'agentstudio.bridge.worker.review_select_dispatch',
		new Set(['dropped_detached', 'none', 'posted', 'queued_not_ready']),
	],
	[
		'agentstudio.bridge.worker.session_state',
		new Set(['awaiting_bootstrap', 'bootstrapping', 'disposed', 'ready', 'replacement_requested']),
	],
	[
		'agentstudio.bridge.worker.replacement_reason',
		new Set([
			'bootstrap_timeout',
			'explicit_dispose',
			'message_error',
			'none',
			'runtime_recovery',
			'session_in_use',
			'session_suspect',
			'worker_error',
		]),
	],
	[
		'agentstudio.bridge.worker.replacement_source',
		new Set([
			'admission_reply_exhausted',
			'none',
			'render_disposition_overload',
			'render_disposition_probe_exhausted',
			'result_acknowledgement_exhausted',
			'result_deadline_exhausted',
			'review_installed_receipt_failed',
		]),
	],
	[
		'agentstudio.bridge.render_disposition.outcome',
		new Set(['acked', 'cleared', 'degraded', 'timed_out']),
	],
	[
		'agentstudio.bridge.render_publication.outcome',
		new Set([
			'cleared',
			'held',
			'painted',
			'published',
			'queued',
			'rejected',
			'released',
			'settled',
			'superseded',
		]),
	],
	[
		'agentstudio.bridge.worker.semantic_class',
		new Set(['demand', 'lifecycle_control', 'settlement', 'urgent_action']),
	],
	['agentstudio.bridge.scroll.offset', new Set(['nearest', 'none', 'top', 'unknown'])],
	[
		'agentstudio.bridge.scroll.reason',
		new Set([
			'anchor_workaround',
			'append_reveal',
			'clicked_selection',
			'search_match',
			'selected_path_effect',
			'selection_sync',
		]),
	],
	[
		'agentstudio.bridge.tree_path_count_bucket',
		new Set(['empty', 'small', 'medium', 'large', 'huge']),
	],
]);

const bridgeDevNumericAttributeKeys = new Set<string>([
	'agentstudio.bridge.activation.sequence',
	'agentstudio.bridge.annotation.catalog.entry.count',
	'agentstudio.bridge.annotation.catalog.revision',
	'agentstudio.bridge.annotation.catalog.unit.byte_count',
	'agentstudio.bridge.annotation.catalog.window.count',
	'agentstudio.bridge.annotation.catalog.window.ordinal',
	'agentstudio.bridge.anchor_restore.call.count',
	'agentstudio.bridge.anchor_restore.direct_scroll_top_write.count',
	'agentstudio.bridge.anchor_restore.synthetic_scroll.count',
	'agentstudio.bridge.content.byte_length',
	'agentstudio.bridge.content.body_registry_commit_ms',
	'agentstudio.bridge.content.byte_count',
	'agentstudio.bridge.content.chunk_byte_count',
	'agentstudio.bridge.content.chunk_count',
	'agentstudio.bridge.content.estimated_bytes',
	'agentstudio.bridge.content.first_chunk_wait_ms',
	'agentstudio.bridge.content.response_wait_ms',
	'agentstudio.bridge.content.stream_read_ms',
	'agentstudio.bridge.content.resource_count',
	'agentstudio.bridge.content.total_bytes_read',
	'agentstudio.bridge.demand.active.count',
	'agentstudio.bridge.demand.deferred.count',
	'agentstudio.bridge.demand.duration_ms',
	'agentstudio.bridge.demand.enqueue_accepted.count',
	'agentstudio.bridge.demand.enqueue_rejected.count',
	'agentstudio.bridge.demand.executor_in_flight_ms',
	'agentstudio.bridge.demand.executor_pending_wait_ms',
	'agentstudio.bridge.demand.failed.count',
	'agentstudio.bridge.demand.foreground.count',
	'agentstudio.bridge.demand.idle.count',
	'agentstudio.bridge.demand.intent.count',
	'agentstudio.bridge.demand.loaded.count',
	'agentstudio.bridge.demand.nearby.count',
	'agentstudio.bridge.demand.request.sequence',
	'agentstudio.bridge.demand.scheduler_queue_wait_ms',
	'agentstudio.bridge.demand.speculative.count',
	'agentstudio.bridge.demand.visible.count',
	'agentstudio.bridge.dev_server.get_provider_ms',
	'agentstudio.bridge.dev_server.provider_load_ms',
	'agentstudio.bridge.dev_server.response_total_ms',
	'agentstudio.bridge.frame_jank.dropped_frame.count',
	'agentstudio.bridge.frame_jank.dropped_frame.worst_gap_ms',
	'agentstudio.bridge.frame_jank.long_task.count',
	'agentstudio.bridge.frame_jank.long_task.max_ms',
	'agentstudio.bridge.frame_jank.long_task.total_ms',
	'agentstudio.bridge.hover_to_render.max_ms',
	'agentstudio.bridge.hover_to_render.p95_ms',
	'agentstudio.bridge.hover_to_render.sample.count',
	'agentstudio.bridge.markdown.input_bytes',
	'agentstudio.bridge.markdown.output_bytes',
	'agentstudio.bridge.presentation.publication_sequence',
	'agentstudio.bridge.presentation.revision',
	'agentstudio.bridge.presentation.revision.after',
	'agentstudio.bridge.presentation.revision.before',
	'agentstudio.bridge.interaction.sequence',
	'agentstudio.bridge.review.generation',
	'agentstudio.bridge.review.refresh.active_bank.count',
	'agentstudio.bridge.review.refresh.affected_file.count',
	'agentstudio.bridge.review.refresh.affected_stable_file.count',
	'agentstudio.bridge.review.refresh.candidate_bank.count',
	'agentstudio.bridge.review.refresh.changed_line.count',
	'agentstudio.bridge.review.refresh.imported_commit.count',
	'agentstudio.bridge.review.refresh.retained_publication.count',
	'agentstudio.bridge.review.refresh.source_lease.count',
	'agentstudio.bridge.source.generation',
	'agentstudio.bridge.source.monotonic_ms',
	'agentstudio.bridge.stage.attempt',
	'agentstudio.bridge.review.item_count',
	'agentstudio.bridge.render_disposition.accepted_count',
	'agentstudio.bridge.render_disposition.batch_receipt_count',
	'agentstudio.bridge.render_disposition.duplicate_count',
	'agentstudio.bridge.render_disposition.in_flight_count',
	'agentstudio.bridge.render_disposition.oldest_pending_age_ms',
	'agentstudio.bridge.render_disposition.pending_count',
	'agentstudio.bridge.render_disposition.pending_high_water_mark',
	'agentstudio.bridge.render_disposition.produced_count',
	'agentstudio.bridge.render_disposition.rejected_count',
	'agentstudio.bridge.render_disposition.retained_count',
	'agentstudio.bridge.render_publication.current_count',
	'agentstudio.bridge.render_publication.high_water_mark',
	'agentstudio.bridge.render_publication.oldest_age_ms',
	'agentstudio.bridge.scroll.frame_gap.max_ms',
	'agentstudio.bridge.scroll.frame_gap.over_16ms.count',
	'agentstudio.bridge.scroll.frame_gap.over_33ms.count',
	'agentstudio.bridge.scroll.frame_gap.over_50ms.count',
	'agentstudio.bridge.scroll.frame_gap.p95_ms',
	'agentstudio.bridge.selected_content.click_to_paint_ms',
	'agentstudio.bridge.selected_content.frame_wait_ms',
	'agentstudio.bridge.selected_content.materialize_ms',
	'agentstudio.bridge.telemetry.dropped_count',
	'agentstudio.bridge.telemetry.value',
	'agentstudio.bridge.visible_descriptor.count',
	'agentstudio.bridge.visible_item.count',
	'agentstudio.bridge.visible_publisher.skipped.count',
	'agentstudio.bridge.visible_row.count',
	'agentstudio.bridge.worktree_file.tree.current_row.count',
	'agentstudio.bridge.worktree_file.tree.descriptor.count',
	'agentstudio.bridge.worktree_file.tree.incoming_frame.count',
	'agentstudio.bridge.worktree_file.tree.window.row.count',
	'agentstudio.bridge.worker.handler_duration_ms',
	'agentstudio.bridge.worker.native_bootstrap_install.count',
	'agentstudio.bridge.worker.patch_count',
	'agentstudio.bridge.worker.queued_command.count',
	'agentstudio.bridge.worker.queue_wait_ms',
	'agentstudio.bridge.worker.replacement_request.count',
	'agentstudio.bridge.worker.derivation_epoch',
	'agentstudio.bridge.worker.source_epoch',
	'agentstudio.bridge.worker.touched_key_count',
	'agentstudio.bridge.worktree.content_height_delta_px',
	'agentstudio.bridge.worktree.content_total_size_px',
	'agentstudio.bridge.worktree.descriptor_count',
	'agentstudio.bridge.worktree.frame_count',
	'agentstudio.bridge.worktree.tree_height_delta_px',
	'agentstudio.bridge.worktree.tree_total_size_px',
]);

const bridgeDevBooleanAttributeKeys = new Set<string>([
	'agentstudio.bridge.activation.source_available',
	'agentstudio.bridge.already_selected',
	'agentstudio.bridge.header_missing',
	'agentstudio.bridge.header_supported',
	'agentstudio.bridge.focus',
	'agentstudio.bridge.refreshing.review',
	'agentstudio.bridge.row_mounted',
	'agentstudio.bridge.scroll.active',
	'agentstudio.bridge.selected',
	'agentstudio.bridge.viewer.active',
	'agentstudio.bridge.worker.file_metadata_selected_path_resolved',
]);

const bridgeDevTelemetryUnsafeValuePatterns = [
	/(^|[ "'=])\/Users\//,
	/agentstudio:\/\/resource\//i,
	/prompt-canary/i,
	/(^|[._-])prompt([._-]|$)/i,
	/(^|[._-])comment([._-]|$)/i,
	/(^|[._-])comms?([._-]|$)/i,
] as const satisfies readonly RegExp[];

const bridgeDevExplicitSafeTelemetryNames = new Set([
	'performance.bridge.web.annotation_lifecycle',
	'performance.bridge.web.comm_worker_session',
	'performance.bridge.web.operation_lifecycle',
]);
const bridgeDevExplicitSafeStringAttributePairs = new Set([
	'agentstudio.bridge.phase\u0000annotation_catalog_main_begin',
	'agentstudio.bridge.phase\u0000annotation_catalog_main_commit',
	'agentstudio.bridge.phase\u0000annotation_catalog_main_window',
	'agentstudio.bridge.phase\u0000annotation_invalidation_received',
	'agentstudio.bridge.phase\u0000annotation_paint_started',
	'agentstudio.bridge.phase\u0000annotation_paint_terminal',
	'agentstudio.bridge.phase\u0000content_transfer_started',
	'agentstudio.bridge.phase\u0000content_transfer_terminal',
	'agentstudio.bridge.phase\u0000descriptor_claim_started',
	'agentstudio.bridge.phase\u0000descriptor_claim_terminal',
	'agentstudio.bridge.phase\u0000comm_worker_session_snapshot',
	'agentstudio.bridge.phase\u0000main_thread_install_terminal',
	'agentstudio.bridge.phase\u0000main_thread_install_started',
	'agentstudio.bridge.phase\u0000metadata_delivery_started',
	'agentstudio.bridge.phase\u0000metadata_delivery_terminal',
	'agentstudio.bridge.phase\u0000native_annotation_work_started',
	'agentstudio.bridge.phase\u0000native_annotation_work_terminal',
	'agentstudio.bridge.phase\u0000projection_content_transfer_terminal',
	'agentstudio.bridge.phase\u0000projection_convergence_started',
	'agentstudio.bridge.phase\u0000projection_convergence_terminal',
	'agentstudio.bridge.phase\u0000projection_query_started',
	'agentstudio.bridge.phase\u0000projection_query_terminal',
	'agentstudio.bridge.phase\u0000projection_store_started',
	'agentstudio.bridge.phase\u0000projection_store_terminal',
	'agentstudio.bridge.phase\u0000projection_validation_started',
	'agentstudio.bridge.phase\u0000projection_validation_terminal',
	'agentstudio.bridge.phase\u0000worker_application_started',
	'agentstudio.bridge.phase\u0000worker_application_terminal',
	'agentstudio.bridge.phase\u0000panel_chrome_publish_started',
	'agentstudio.bridge.phase\u0000panel_chrome_publish_terminal',
	'agentstudio.bridge.phase\u0000file_content_operation_started',
	'agentstudio.bridge.phase\u0000file_content_operation_terminal',
	'agentstudio.bridge.phase\u0000file_descriptor_wait_started',
	'agentstudio.bridge.phase\u0000file_descriptor_wait_terminal',
	'agentstudio.bridge.phase\u0000content_operation_started',
	'agentstudio.bridge.phase\u0000content_operation_terminal',
	'agentstudio.bridge.phase\u0000render_operation_started',
	'agentstudio.bridge.phase\u0000render_operation_terminal',
	'agentstudio.bridge.phase\u0000paint_fulfillment_started',
	'agentstudio.bridge.phase\u0000paint_fulfillment_terminal',
]);

export function bridgeDevTelemetryObservationIsSafe(
	observation: BridgeDevTelemetryObservation,
): boolean {
	if (!bridgeDevTelemetryStringValueIsSafe(observation.scenario)) {
		return false;
	}
	for (const sample of observation.samples) {
		if (
			!bridgeDevTelemetryStringValueIsSafe(sample.name) &&
			!bridgeDevExplicitSafeTelemetryNames.has(sample.name)
		) {
			return false;
		}
		for (const [key, value] of Object.entries(sample.stringAttributes)) {
			if (!bridgeDevStringAttributeIsSafe(key, value)) {
				return false;
			}
		}
		for (const [key, value] of Object.entries(sample.numericAttributes)) {
			if (
				!bridgeDevNumericAttributeKeys.has(key) ||
				!Number.isFinite(value) ||
				(key === 'agentstudio.bridge.stage.attempt' && (!Number.isSafeInteger(value) || value < 0))
			) {
				return false;
			}
		}
		for (const key of Object.keys(sample.booleanAttributes)) {
			if (!bridgeDevBooleanAttributeKeys.has(key)) {
				return false;
			}
		}
	}
	return true;
}

export function buildBridgeDevTelemetryLogRecord(
	props: BuildBridgeDevTelemetryLogRecordProps,
): OTelLogRecord {
	return {
		body: { stringValue: props.sample.name },
		attributes: [
			stringAttribute('agent.proof.marker', props.marker),
			stringAttribute('agentstudio.bridge.test.scenario', props.observation.scenario),
			stringAttribute('dev.release.channel', bridgeDevReleaseChannel),
			stringAttribute('dev.runtime.flavor', bridgeDevRuntimeFlavor),
			stringAttribute('dev.worktree.hash', props.worktreeHash),
			stringAttribute('service.name', 'AgentStudioBridgeWebDevServer'),
			stringAttribute('service.version', props.serviceVersion),
			...Object.entries(props.sample.stringAttributes)
				.filter(([key, value]): boolean => bridgeDevStringAttributeIsSafe(key, value))
				.map(([key, value]): OTelKeyValue => stringAttribute(key, value)),
			...Object.entries(props.sample.numericAttributes)
				.filter(([key]): boolean => bridgeDevNumericAttributeKeys.has(key))
				.map(([key, value]): OTelKeyValue => numberAttribute(key, value)),
			...Object.entries(props.sample.booleanAttributes)
				.filter(([key]): boolean => bridgeDevBooleanAttributeKeys.has(key))
				.map(([key, value]): OTelKeyValue => booleanAttribute(key, value)),
			...(props.sample.durationMilliseconds === null
				? []
				: [
						numberAttribute(
							'agentstudio.performance.elapsed_ms',
							props.sample.durationMilliseconds,
						),
					]),
		],
		severityNumber: 9,
		severityText: 'info',
		timeUnixNano: props.receivedAtUnixNano,
	};
}

export function buildBridgeDevTelemetryOTLPRequest(
	props: BuildBridgeDevTelemetryOTLPRequestProps,
): {
	readonly resourceLogs: readonly [
		{
			readonly resource: { readonly attributes: readonly OTelKeyValue[] };
			readonly scopeLogs: readonly [
				{
					readonly scope: { readonly name: 'bridge-web-vite-dev'; readonly version: string };
					readonly logRecords: readonly OTelLogRecord[];
				},
			];
		},
	];
} {
	return {
		resourceLogs: [
			{
				resource: {
					attributes: [
						stringAttribute('service.name', 'AgentStudioBridgeWebDevServer'),
						stringAttribute('service.version', props.serviceVersion),
						stringAttribute('dev.release.channel', bridgeDevReleaseChannel),
						stringAttribute('dev.runtime.flavor', bridgeDevRuntimeFlavor),
						stringAttribute('dev.worktree.hash', props.worktreeHash),
					],
				},
				scopeLogs: [
					{
						scope: { name: 'bridge-web-vite-dev', version: props.serviceVersion },
						logRecords: props.observation.samples.map(
							(sample: BridgeTelemetrySample): OTelLogRecord =>
								buildBridgeDevTelemetryLogRecord({ ...props, sample }),
						),
					},
				],
			},
		],
	};
}

export function buildBridgeDevTelemetryOTLPMetricsRequest(
	props: BuildBridgeDevTelemetryOTLPRequestProps,
): {
	readonly resourceMetrics: readonly [
		{
			readonly resource: { readonly attributes: readonly OTelKeyValue[] };
			readonly scopeMetrics: readonly [
				{
					readonly scope: { readonly name: 'bridge-web-vite-dev'; readonly version: string };
					readonly metrics: readonly OTelMetric[];
				},
			];
		},
	];
} {
	return {
		resourceMetrics: [
			{
				resource: {
					attributes: resourceAttributesForBridgeDevTelemetry(props),
				},
				scopeMetrics: [
					{
						scope: { name: 'bridge-web-vite-dev', version: props.serviceVersion },
						metrics: metricsForBridgeTelemetryObservation(props),
					},
				],
			},
		],
	};
}

function metricsForBridgeTelemetryObservation(props: {
	readonly observation: BridgeDevTelemetryObservation;
	readonly receivedAtUnixNano: string;
}): readonly OTelMetric[] {
	const counterPoints: OTelMetricDataPoint[] = [];
	const elapsedHistogramPoints: OTelHistogramDataPoint[] = [];
	const elapsedMaxPoints: OTelMetricDataPoint[] = [];
	const numericGaugePointsByMetricName = new Map<string, OTelMetricDataPoint[]>();

	for (const sample of props.observation.samples) {
		const dimensions = dimensionsForBridgeTelemetrySample(sample);
		if (dimensions === null) {
			continue;
		}
		counterPoints.push({
			timeUnixNano: props.receivedAtUnixNano,
			attributes: dimensions,
			asInt: '1',
		});
		if (sample.durationMilliseconds !== null) {
			elapsedHistogramPoints.push(
				histogramPointForDuration({
					attributes: dimensions,
					durationMilliseconds: sample.durationMilliseconds,
					timeUnixNano: props.receivedAtUnixNano,
				}),
			);
			elapsedMaxPoints.push({
				timeUnixNano: props.receivedAtUnixNano,
				attributes: dimensions,
				asDouble: sample.durationMilliseconds,
			});
		}
		for (const [key, value] of Object.entries(sample.numericAttributes)) {
			const metricName = metricNameForBridgeTelemetryNumericAttribute(key);
			if (metricName === null) {
				continue;
			}
			const points = numericGaugePointsByMetricName.get(metricName) ?? [];
			points.push({
				timeUnixNano: props.receivedAtUnixNano,
				attributes: dimensions,
				asDouble: value,
			});
			numericGaugePointsByMetricName.set(metricName, points);
		}
	}

	const metrics: OTelMetric[] = [
		{
			name: 'agentstudio_performance_events_total',
			sum: {
				aggregationTemporality: 2,
				isMonotonic: true,
				dataPoints: counterPoints,
			},
		},
		{
			name: 'agentstudio_performance_event_elapsed_ms',
			histogram: {
				aggregationTemporality: 2,
				dataPoints: elapsedHistogramPoints,
			},
		},
		{
			name: 'agentstudio_performance_event_elapsed_ms_max',
			gauge: {
				dataPoints: elapsedMaxPoints,
			},
		},
	];
	for (const [metricName, dataPoints] of [...numericGaugePointsByMetricName.entries()].toSorted(
		([leftName], [rightName]): number => leftName.localeCompare(rightName),
	)) {
		metrics.push({
			name: metricName,
			gauge: { dataPoints },
		});
	}
	return metrics;
}

function dimensionsForBridgeTelemetrySample(
	sample: BridgeTelemetrySample,
): readonly OTelKeyValue[] | null {
	if (!sample.name.startsWith('performance.')) {
		return null;
	}
	if (sample.name.startsWith('performance.bridge.')) {
		const phase = sample.stringAttributes['agentstudio.bridge.phase'];
		const plane = sample.stringAttributes['agentstudio.bridge.plane'];
		const priority = sample.stringAttributes['agentstudio.bridge.priority'];
		const slice = sample.stringAttributes['agentstudio.bridge.slice'];
		if (
			phase === undefined ||
			plane === undefined ||
			priority === undefined ||
			slice === undefined
		) {
			return null;
		}
		return [
			stringAttribute('event', sample.name),
			stringAttribute('phase', phase),
			stringAttribute('plane', plane),
			stringAttribute('priority', priority),
			stringAttribute('slice', slice),
			...(sample.stringAttributes['agentstudio.bridge.transport'] === undefined
				? []
				: [stringAttribute('transport', sample.stringAttributes['agentstudio.bridge.transport'])]),
		];
	}
	return [stringAttribute('event', sample.name)];
}

function histogramPointForDuration(props: {
	readonly attributes: readonly OTelKeyValue[];
	readonly durationMilliseconds: number;
	readonly timeUnixNano: string;
}): OTelHistogramDataPoint {
	const bucketCounts = Array.from({ length: elapsedHistogramBounds.length + 1 }, (): string => '0');
	const bucketIndex = elapsedHistogramBounds.findIndex(
		(bound): boolean => props.durationMilliseconds <= bound,
	);
	bucketCounts[bucketIndex === -1 ? elapsedHistogramBounds.length : bucketIndex] = '1';
	return {
		timeUnixNano: props.timeUnixNano,
		attributes: props.attributes,
		count: '1',
		sum: props.durationMilliseconds,
		bucketCounts,
		explicitBounds: [...elapsedHistogramBounds],
		min: props.durationMilliseconds,
		max: props.durationMilliseconds,
	};
}

function metricNameForBridgeTelemetryNumericAttribute(key: string): string | null {
	if (key === 'agentstudio.performance.elapsed_ms') {
		return null;
	}
	if (key.startsWith('agentstudio.performance.')) {
		return metricNameFromAttributeSuffix(
			'agentstudio_performance',
			key.slice('agentstudio.performance.'.length),
		);
	}
	if (!key.startsWith('agentstudio.bridge.')) {
		return null;
	}
	return metricNameFromAttributeSuffix(
		'agentstudio_bridge',
		key.slice('agentstudio.bridge.'.length),
	);
}

function metricNameFromAttributeSuffix(prefix: string, suffix: string): string | null {
	const sanitized = suffix
		.replace(/[^A-Za-z0-9]+/gu, '_')
		.replace(/_+/gu, '_')
		.replace(/^_|_$/gu, '');
	return sanitized.length === 0 ? null : `${prefix}_${sanitized}`;
}

function resourceAttributesForBridgeDevTelemetry(props: {
	readonly marker: string;
	readonly serviceVersion: string;
	readonly worktreeHash: string;
}): readonly OTelKeyValue[] {
	return [
		stringAttribute('service.name', 'AgentStudioBridgeWebDevServer'),
		stringAttribute('service.version', props.serviceVersion),
		stringAttribute('dev.release.channel', bridgeDevReleaseChannel),
		stringAttribute('dev.runtime.flavor', bridgeDevRuntimeFlavor),
		stringAttribute('dev.worktree.hash', props.worktreeHash),
		stringAttribute('agent.proof.marker', props.marker),
	];
}

function bridgeDevStringAttributeIsSafe(key: string, value: string): boolean {
	if (!bridgeDevStringAttributeKeys.has(key)) {
		return false;
	}
	if (key === 'agentstudio.bridge.operation.id') {
		return /^[0-9a-f]{64}$/u.test(value);
	}
	const restrictedValues = bridgeDevRestrictedStringAttributeValuesByKey.get(key);
	if (restrictedValues !== undefined) {
		return restrictedValues.has(value);
	}
	return (
		bridgeDevTelemetryStringValueIsSafe(value) ||
		bridgeDevExplicitSafeStringAttributePairs.has(`${key}\u0000${value}`)
	);
}

function bridgeDevTelemetryStringValueIsSafe(value: string): boolean {
	return !bridgeDevTelemetryUnsafeValuePatterns.some((pattern): boolean => pattern.test(value));
}

function stringAttribute(key: string, value: string): OTelKeyValue {
	return { key, value: { stringValue: value } };
}

function numberAttribute(key: string, value: number): OTelKeyValue {
	return Number.isInteger(value)
		? { key, value: { intValue: String(value) } }
		: { key, value: { doubleValue: value } };
}

function booleanAttribute(key: string, value: boolean): OTelKeyValue {
	return { key, value: { boolValue: value } };
}
