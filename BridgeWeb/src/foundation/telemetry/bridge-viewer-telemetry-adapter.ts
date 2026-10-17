import type { BridgeTelemetryRecorder } from './bridge-telemetry-recorder.js';
import type { BridgeTraceContext } from './bridge-trace-context.js';

export {
	recordBridgeTreeAnchorRestoreTelemetrySample,
	recordBridgeTreeClickToRowHighlightTelemetrySample,
	recordBridgeTreeHoverToRenderTelemetrySample,
	recordBridgeTreeScrollFrameGapTelemetrySample,
	recordBridgeTreeScrollToPathTelemetrySample,
	recordBridgeTreeVisibleIdsCaptureTelemetrySample,
} from './bridge-tree-telemetry-adapter.js';

export interface BridgeProjectionBuildTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly durationMilliseconds: number | null;
	readonly executionLane: 'sync' | 'worker';
	readonly fixtureClass: 'smoke' | 'medium' | 'large' | 'huge';
	readonly itemCountBucket: 'empty' | 'small' | 'medium' | 'large' | 'huge';
	readonly projectionKind: string;
	readonly treePathCountBucket: 'empty' | 'small' | 'medium' | 'large' | 'huge';
}

export interface BridgeProjectionCoordinatorTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly durationMilliseconds: number;
	readonly executionLane: 'sync' | 'worker';
	readonly itemCount: number;
	readonly phase: 'projection_input_build' | 'projection_store_apply' | 'projection_total';
	readonly result: 'failed' | 'success';
}

export interface BridgeViewerContentQueueTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly contentRole: 'base' | 'head' | 'diff' | 'file' | 'unknown';
	readonly interest: 'selected' | 'visible' | 'nearby' | 'speculative' | 'background';
}

export interface BridgeViewerContentFetchTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly contentRole: 'base' | 'head' | 'diff' | 'file' | 'unknown';
	readonly durationMilliseconds: number;
	readonly interest: 'selected' | 'visible' | 'nearby' | 'speculative' | 'background';
	readonly result: 'success' | 'deferred' | 'failed';
	readonly resultReason: string | null;
}

export interface BridgeViewerWorktreeFileContentFetchTelemetrySampleProps {
	readonly byteLength: number;
	readonly estimatedBytes: number | null;
	readonly firstChunkWaitMilliseconds: number | null;
	readonly lane: string;
	readonly responseWaitMilliseconds: number | null;
	readonly result: 'failed' | 'success';
	readonly resultReason: string | null;
	readonly streamReadMilliseconds: number | null;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly totalDurationMilliseconds: number;
	readonly traceContext: BridgeTraceContext | null;
}

export interface BridgeViewerWorktreeFileTreeTelemetrySampleProps {
	readonly descriptorCount: number;
	readonly durationMilliseconds: number | null;
	readonly frameCount: number;
	readonly phase: 'worktree_file_frame_apply' | 'worktree_file_projection';
	readonly result: 'success';
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly treeRowCount: number;
	readonly treeWindowRowCount: number;
}

export interface BridgeViewerFileOpenReadyTelemetrySampleProps {
	readonly disposition: string;
	readonly durationMilliseconds: number;
	readonly estimatedBytes: number | null;
	readonly executorInFlightMilliseconds: number | null;
	readonly executorPendingWaitMilliseconds: number | null;
	readonly lane: string;
	readonly requestId: number;
	readonly resourceBodyRegistryCommitMilliseconds: number | null;
	readonly resourceFetchResponseWaitMilliseconds: number | null;
	readonly resourceFirstChunkWaitMilliseconds: number | null;
	readonly resourceStreamReadMilliseconds: number | null;
	readonly result: 'failed' | 'success';
	readonly resultReason: string | null;
	readonly demandQueueWaitMilliseconds: number | null;
	readonly sourceGeneration: number | null;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
}

export interface BridgeTreeScrollVisibleDemandTelemetrySampleProps {
	readonly durationMilliseconds: number;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly viewer: 'file' | 'review';
	readonly visibleItemCount: number;
}

export interface BridgeFrameJankTelemetrySampleProps {
	readonly droppedFrameCount: number;
	readonly droppedFrameWorstGapMilliseconds: number;
	readonly durationMilliseconds: number;
	readonly kind: 'dropped_frame' | 'long_task';
	readonly longTaskCount: number;
	readonly longTaskMaxMilliseconds: number;
	readonly longTaskTotalMilliseconds: number;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly viewer: 'file' | 'review';
	readonly viewerIsActive: boolean;
}

export interface BridgeViewerFirstInteractionReadyTelemetrySampleProps {
	readonly activationSequence?: number;
	readonly durationMilliseconds: number;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly variant: 'cold' | 'warm';
	readonly viewer: 'file' | 'review';
	readonly visibleItemCount: number;
}

export interface BridgeWorktreeFileVisibleDemandSettledTelemetrySampleProps {
	readonly durationMilliseconds: number;
	readonly enqueueAcceptedCount: number;
	readonly enqueueRejectedCount: number;
	readonly executorInFlightMilliseconds: number | null;
	readonly executorPendingWaitMilliseconds: number | null;
	readonly failedCount: number;
	readonly firstChunkWaitMilliseconds: number | null;
	readonly intentCount: number;
	readonly lane: string | null;
	readonly loadedCount: number;
	readonly requestId: number;
	readonly responseWaitMilliseconds: number | null;
	readonly result: 'failed' | 'success';
	readonly resultReason: string | null;
	readonly demandQueueWaitMilliseconds: number | null;
	readonly streamReadMilliseconds: number | null;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly visibleItemCount: number;
}

export interface BridgeCodeViewHydrationTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly contentBytesBucket: 'empty' | 'small' | 'medium' | 'large' | 'huge';
	readonly itemCountBucket: 'empty' | 'small' | 'medium' | 'large' | 'huge';
	readonly languageClass: 'config' | 'markdown' | 'other' | 'swift' | 'text' | 'typescript';
	readonly workerLane: 'none' | 'pierre';
}

export interface BridgeCodeViewItemMaterializeTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly contentBytesBucket: 'empty' | 'small' | 'medium' | 'large' | 'huge';
	readonly durationMilliseconds: number;
	readonly itemCountBucket: 'empty' | 'small' | 'medium' | 'large' | 'huge';
	readonly languageClass: 'config' | 'markdown' | 'other' | 'swift' | 'text' | 'typescript';
	readonly result: 'added' | 'unchanged' | 'updated';
	readonly selected: boolean;
	readonly transport: 'swift' | 'worker';
	readonly viewer: 'review';
}

export interface BridgeSelectedContentPaintedTelemetrySampleProps {
	readonly activationSequence?: number;
	readonly clickToPaintMilliseconds: number;
	readonly frameWaitMilliseconds: number;
	readonly materializeMilliseconds: number;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly transport: 'swift' | 'worker';
	readonly viewer: 'review';
}

export interface BridgeSelectedContentDroppedTelemetrySampleProps {
	readonly dropReason: string;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly viewer: 'review';
}

export interface BridgeReviewSelectionCommitTelemetrySampleProps {
	readonly telemetryRecorder: BridgeTelemetryRecorder;
}

export interface BridgeReviewComparisonPaneTelemetrySampleProps {
	readonly attemptStatus:
		| 'absent'
		| 'no_source'
		| 'pending'
		| 'selection_required'
		| 'settled'
		| 'unavailable';
	readonly packageMatch:
		| 'matched'
		| 'snapshot_not_current'
		| 'package_absent'
		| 'package_id_mismatch'
		| 'review_generation_mismatch'
		| 'revision_mismatch';
	readonly paneState:
		| 'failed_initial'
		| 'failed_previous'
		| 'loading_initial'
		| 'loading_previous'
		| 'settled';
	readonly telemetryRecorder: BridgeTelemetryRecorder;
}

export interface BridgeReviewContentDemandTelemetrySampleProps {
	readonly activeIntentCount: number;
	readonly deferredCount: number;
	readonly durationMilliseconds: number;
	readonly failedCount: number;
	readonly foregroundIntentCount: number;
	readonly idleIntentCount: number;
	readonly interest: 'selected' | 'visible' | 'nearby' | 'speculative' | 'background';
	readonly intentCount: number;
	readonly loadedCount: number;
	readonly nearbyIntentCount: number;
	readonly result: 'deferred' | 'failed' | 'success';
	readonly resultReason: string | null;
	readonly speculativeIntentCount: number;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly traceContext: BridgeTraceContext | null;
	readonly viewer: 'review';
	readonly visibleIntentCount: number;
}

export function recordBridgeProjectionBuildTelemetrySample(
	props: BridgeProjectionBuildTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.trees.projection_build',
			durationMilliseconds: props.durationMilliseconds,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.fixture_class': props.fixtureClass,
				'agentstudio.bridge.item_count_bucket': props.itemCountBucket,
				'agentstudio.bridge.phase': 'projection_build',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'warm',
				'agentstudio.bridge.projection.kind': props.projectionKind,
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'review_projection',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.tree_path_count_bucket': props.treePathCountBucket,
				'agentstudio.bridge.worker.lane': props.executionLane === 'worker' ? 'projection' : 'none',
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
	});
}

export function recordBridgeProjectionCoordinatorTelemetrySample(
	props: BridgeProjectionCoordinatorTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: `performance.bridge.web.${props.phase}`,
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.phase': props.phase,
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'warm',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.slice': 'review_projection',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.worker.lane': props.executionLane === 'worker' ? 'projection' : 'none',
			},
			numericAttributes: {
				'agentstudio.bridge.review.item_count': props.itemCount,
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeViewerContentQueueTelemetrySample(
	props: BridgeViewerContentQueueTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.viewer.content_queue',
			durationMilliseconds: null,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content.interest': props.interest,
				'agentstudio.bridge.content.priority': props.interest,
				'agentstudio.bridge.content.role': props.contentRole,
				'agentstudio.bridge.phase': 'content_queue',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.queue.depth_bucket': 'small',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
	});
}

export function recordBridgeViewerContentFetchTelemetrySample(
	props: BridgeViewerContentFetchTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.content_fetch',
			durationMilliseconds: props.durationMilliseconds,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content.correlation_mode': 'summary',
				'agentstudio.bridge.content.interest': props.interest,
				'agentstudio.bridge.content.role': props.contentRole,
				'agentstudio.bridge.phase': 'fetch',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.result_reason': props.resultReason ?? 'none',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
			},
			numericAttributes: {},
			booleanAttributes: {
				'agentstudio.bridge.header_missing': true,
				'agentstudio.bridge.header_supported': false,
			},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeViewerWorktreeFileContentFetchTelemetrySample(
	props: BridgeViewerWorktreeFileContentFetchTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.content_fetch',
			durationMilliseconds: Math.max(0, props.totalDurationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content.correlation_mode': 'summary',
				'agentstudio.bridge.content.role': 'file',
				'agentstudio.bridge.demand.lane': props.lane,
				'agentstudio.bridge.file_size_bucket': bridgeContentSizeBucketForBytes(
					props.estimatedBytes ?? props.byteLength,
				),
				'agentstudio.bridge.generation_relation': 'current',
				'agentstudio.bridge.phase': 'fetch',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.protocol': 'worktree-file',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.result_reason': props.resultReason ?? 'none',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': 'file',
			},
			numericAttributes: {
				'agentstudio.bridge.content.byte_length': props.byteLength,
				...(props.estimatedBytes === null
					? {}
					: { 'agentstudio.bridge.content.estimated_bytes': props.estimatedBytes }),
				...(props.firstChunkWaitMilliseconds === null
					? {}
					: {
							'agentstudio.bridge.content.first_chunk_wait_ms': props.firstChunkWaitMilliseconds,
						}),
				...(props.responseWaitMilliseconds === null
					? {}
					: {
							'agentstudio.bridge.content.response_wait_ms': props.responseWaitMilliseconds,
						}),
				...(props.streamReadMilliseconds === null
					? {}
					: { 'agentstudio.bridge.content.stream_read_ms': props.streamReadMilliseconds }),
			},
			booleanAttributes: {
				'agentstudio.bridge.header_missing': true,
				'agentstudio.bridge.header_supported': false,
			},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeViewerWorktreeFileTreeTelemetrySample(
	props: BridgeViewerWorktreeFileTreeTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.trees.prepare_input',
			durationMilliseconds:
				props.durationMilliseconds === null ? null : Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.fixture_class': bridgeWorktreeFileTreeFixtureBucket(props.treeRowCount),
				'agentstudio.bridge.phase': props.phase,
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'warm',
				'agentstudio.bridge.projection.kind': 'source',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.slice': 'tree_prepare_input',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.tree_path_count_bucket': bridgeWorktreeFileTreeFixtureBucket(
					props.treeRowCount,
				),
			},
			numericAttributes: {
				'agentstudio.bridge.worktree_file.tree.current_row.count': props.treeRowCount,
				'agentstudio.bridge.worktree_file.tree.descriptor.count': props.descriptorCount,
				'agentstudio.bridge.worktree_file.tree.incoming_frame.count': props.frameCount,
				'agentstudio.bridge.worktree_file.tree.window.row.count': props.treeWindowRowCount,
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeViewerFileOpenReadyTelemetrySample(
	props: BridgeViewerFileOpenReadyTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.file_open_ready',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content.role': 'file',
				'agentstudio.bridge.demand.disposition': props.disposition,
				'agentstudio.bridge.demand.lane': props.lane,
				'agentstudio.bridge.phase': 'file_open_ready',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.result_reason': props.resultReason ?? 'none',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': 'file',
			},
			numericAttributes: {
				'agentstudio.bridge.demand.request.sequence': props.requestId,
				...(props.sourceGeneration === null
					? {}
					: { 'agentstudio.bridge.source.generation': props.sourceGeneration }),
				...(props.estimatedBytes === null
					? {}
					: { 'agentstudio.bridge.content.estimated_bytes': props.estimatedBytes }),
				...optionalNumericAttribute(
					'agentstudio.bridge.content.body_registry_commit_ms',
					props.resourceBodyRegistryCommitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.content.first_chunk_wait_ms',
					props.resourceFirstChunkWaitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.content.response_wait_ms',
					props.resourceFetchResponseWaitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.content.stream_read_ms',
					props.resourceStreamReadMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.demand.executor_in_flight_ms',
					props.executorInFlightMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.demand.executor_pending_wait_ms',
					props.executorPendingWaitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.demand.scheduler_queue_wait_ms',
					props.demandQueueWaitMilliseconds,
				),
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeTreeScrollVisibleDemandTelemetrySample(
	props: BridgeTreeScrollVisibleDemandTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.trees.scroll_visible_demand',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.demand.disposition': 'published',
				'agentstudio.bridge.demand.lane': 'visible',
				'agentstudio.bridge.phase': 'scroll_visible_demand',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.result_reason': 'none',
				'agentstudio.bridge.slice': 'tree_prepare_input',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.viewer': props.viewer,
			},
			numericAttributes: {
				'agentstudio.bridge.visible_item.count': props.visibleItemCount,
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeFrameJankTelemetrySample(
	props: BridgeFrameJankTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.frame_jank',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.frame_jank.kind': props.kind,
				'agentstudio.bridge.phase': 'frame_jank',
				'agentstudio.bridge.plane': 'control',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'frame_jank',
				'agentstudio.bridge.transport': 'local',
				'agentstudio.bridge.viewer': props.viewer,
			},
			numericAttributes: {
				'agentstudio.bridge.frame_jank.dropped_frame.count': props.droppedFrameCount,
				'agentstudio.bridge.frame_jank.dropped_frame.worst_gap_ms':
					props.droppedFrameWorstGapMilliseconds,
				'agentstudio.bridge.frame_jank.long_task.count': props.longTaskCount,
				'agentstudio.bridge.frame_jank.long_task.max_ms': props.longTaskMaxMilliseconds,
				'agentstudio.bridge.frame_jank.long_task.total_ms': props.longTaskTotalMilliseconds,
			},
			booleanAttributes: {
				'agentstudio.bridge.viewer.active': props.viewerIsActive,
			},
		});
	});
}

export function recordBridgeViewerFirstInteractionReadyTelemetrySample(
	props: BridgeViewerFirstInteractionReadyTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.viewer.time_to_first_interaction',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.phase': 'time_to_first_interaction',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': props.viewer,
				'agentstudio.bridge.viewer.ttfi_variant': props.variant,
			},
			numericAttributes: {
				...(props.activationSequence === undefined
					? {}
					: { 'agentstudio.bridge.activation.sequence': props.activationSequence }),
				'agentstudio.bridge.visible_item.count': props.visibleItemCount,
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeWorktreeFileVisibleDemandSettledTelemetrySample(
	props: BridgeWorktreeFileVisibleDemandSettledTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.visible_demand_settled',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content.role': 'file',
				'agentstudio.bridge.demand.lane': props.lane ?? 'visible',
				'agentstudio.bridge.phase': 'visible_demand_settled',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.result_reason': props.resultReason ?? 'none',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': 'file',
			},
			numericAttributes: {
				'agentstudio.bridge.demand.enqueue_accepted.count': props.enqueueAcceptedCount,
				'agentstudio.bridge.demand.enqueue_rejected.count': props.enqueueRejectedCount,
				'agentstudio.bridge.demand.failed.count': props.failedCount,
				'agentstudio.bridge.demand.intent.count': props.intentCount,
				'agentstudio.bridge.demand.loaded.count': props.loadedCount,
				'agentstudio.bridge.demand.request.sequence': props.requestId,
				'agentstudio.bridge.visible_item.count': props.visibleItemCount,
				...optionalNumericAttribute(
					'agentstudio.bridge.content.first_chunk_wait_ms',
					props.firstChunkWaitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.content.response_wait_ms',
					props.responseWaitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.content.stream_read_ms',
					props.streamReadMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.demand.executor_in_flight_ms',
					props.executorInFlightMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.demand.executor_pending_wait_ms',
					props.executorPendingWaitMilliseconds,
				),
				...optionalNumericAttribute(
					'agentstudio.bridge.demand.scheduler_queue_wait_ms',
					props.demandQueueWaitMilliseconds,
				),
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeCodeViewHydrationTelemetrySamples(
	props: BridgeCodeViewHydrationTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.pierre.item_update',
			durationMilliseconds: null,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.item_count_bucket': props.itemCountBucket,
				'agentstudio.bridge.item_update.kind': 'hydrate',
				'agentstudio.bridge.phase': 'item_update',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'code_view_item',
				'agentstudio.bridge.transport': 'swift',
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.shiki.highlight',
			durationMilliseconds: null,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content_bytes_bucket': props.contentBytesBucket,
				'agentstudio.bridge.language_class': props.languageClass,
				'agentstudio.bridge.phase': 'highlight',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'shiki_highlight',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.worker.lane': props.workerLane,
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.worker.task',
			durationMilliseconds: null,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.item_count_bucket': props.itemCountBucket,
				'agentstudio.bridge.phase': 'worker_task',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'warm',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'worker_task',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.worker.lane': props.workerLane,
				'agentstudio.bridge.worker.task_kind': 'highlight',
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeCodeViewItemMaterializeTelemetrySample(
	props: BridgeCodeViewItemMaterializeTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.code_view_item_materialize',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content_bytes_bucket': props.contentBytesBucket,
				'agentstudio.bridge.item_count_bucket': props.itemCountBucket,
				'agentstudio.bridge.language_class': props.languageClass,
				'agentstudio.bridge.phase': 'code_view_item_materialize',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.slice': 'code_view_item',
				'agentstudio.bridge.transport': props.transport,
				'agentstudio.bridge.viewer': props.viewer,
			},
			numericAttributes: {},
			booleanAttributes: {
				'agentstudio.bridge.selected': props.selected,
			},
		});
	});
}

export function recordBridgeSelectedContentPaintedTelemetrySample(
	props: BridgeSelectedContentPaintedTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		const clickToPaintMilliseconds = Math.max(0, props.clickToPaintMilliseconds);
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.selected_content_painted',
			durationMilliseconds: clickToPaintMilliseconds,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.phase': 'selected_content_painted',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.slice': 'code_view_item',
				'agentstudio.bridge.transport': props.transport,
				'agentstudio.bridge.viewer': props.viewer,
			},
			numericAttributes: {
				...(props.activationSequence === undefined
					? {}
					: { 'agentstudio.bridge.activation.sequence': props.activationSequence }),
				'agentstudio.bridge.selected_content.click_to_paint_ms': clickToPaintMilliseconds,
				'agentstudio.bridge.selected_content.frame_wait_ms': Math.max(
					0,
					props.frameWaitMilliseconds,
				),
				'agentstudio.bridge.selected_content.materialize_ms': Math.max(
					0,
					props.materializeMilliseconds,
				),
			},
			booleanAttributes: {},
		});
	});
}

export function recordBridgeSelectedContentDroppedTelemetrySample(
	props: BridgeSelectedContentDroppedTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.selected_content_dropped',
			durationMilliseconds: null,
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.drop_reason': props.dropReason,
				'agentstudio.bridge.phase': 'selected_content_dropped',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'dropped',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': props.viewer,
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeReviewSelectionCommitTelemetrySample(
	props: BridgeReviewSelectionCommitTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.selection_commit',
			durationMilliseconds: null,
			traceContext: null,
			stringAttributes: {
				'agentstudio.bridge.phase': 'selection_commit',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'warm',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.result_reason': 'none',
				'agentstudio.bridge.slice': 'review_projection',
				'agentstudio.bridge.transport': 'local',
				'agentstudio.bridge.viewer': 'review',
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

export function recordBridgeReviewComparisonPaneTelemetrySample(
	props: BridgeReviewComparisonPaneTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.pane_presentation',
			durationMilliseconds: null,
			traceContext: null,
			stringAttributes: {
				'agentstudio.bridge.comparison.attempt.status': props.attemptStatus,
				'agentstudio.bridge.comparison.package_match': props.packageMatch,
				'agentstudio.bridge.comparison.pane_state': props.paneState,
				'agentstudio.bridge.phase': 'comparison_pane_rendered',
				'agentstudio.bridge.plane': 'control',
				'agentstudio.bridge.presentation.disposition': 'rendered',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': 'success',
				'agentstudio.bridge.slice': 'review_metadata',
				'agentstudio.bridge.transport': 'local',
				'agentstudio.bridge.viewer': 'review',
			},
			numericAttributes: {},
			booleanAttributes: {},
		});
	});
}

export function recordBridgeReviewContentDemandTelemetrySample(
	props: BridgeReviewContentDemandTelemetrySampleProps,
): void {
	recordWhenEnabled(props.telemetryRecorder, () => {
		props.telemetryRecorder.record({
			scope: 'web',
			name: 'performance.bridge.web.review_content_demand',
			durationMilliseconds: Math.max(0, props.durationMilliseconds),
			traceContext: props.traceContext,
			stringAttributes: {
				'agentstudio.bridge.content.interest': props.interest,
				'agentstudio.bridge.phase': 'review_content_demand',
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'hot',
				'agentstudio.bridge.result': props.result,
				'agentstudio.bridge.result_reason': props.resultReason ?? 'none',
				'agentstudio.bridge.slice': 'content_fetch',
				'agentstudio.bridge.transport': 'content',
				'agentstudio.bridge.viewer': props.viewer,
			},
			numericAttributes: {
				'agentstudio.bridge.demand.active.count': props.activeIntentCount,
				'agentstudio.bridge.demand.deferred.count': props.deferredCount,
				'agentstudio.bridge.demand.duration_ms': Math.max(0, props.durationMilliseconds),
				'agentstudio.bridge.demand.failed.count': props.failedCount,
				'agentstudio.bridge.demand.foreground.count': props.foregroundIntentCount,
				'agentstudio.bridge.demand.idle.count': props.idleIntentCount,
				'agentstudio.bridge.demand.intent.count': props.intentCount,
				'agentstudio.bridge.demand.loaded.count': props.loadedCount,
				'agentstudio.bridge.demand.nearby.count': props.nearbyIntentCount,
				'agentstudio.bridge.demand.speculative.count': props.speculativeIntentCount,
				'agentstudio.bridge.demand.visible.count': props.visibleIntentCount,
			},
			booleanAttributes: {},
		});
		props.telemetryRecorder.flush();
	});
}

function recordWhenEnabled(telemetryRecorder: BridgeTelemetryRecorder, record: () => void): void {
	if (!telemetryRecorder.isEnabled('web')) {
		return;
	}
	record();
}

function optionalNumericAttribute(
	key: string,
	value: number | null,
): Readonly<Record<string, number>> {
	return value === null ? {} : { [key]: value };
}

function bridgeWorktreeFileTreeFixtureBucket(
	rowCount: number,
): 'empty' | 'huge' | 'large' | 'medium' | 'small' {
	if (rowCount <= 0) {
		return 'empty';
	}
	if (rowCount < 100) {
		return 'small';
	}
	if (rowCount < 1_000) {
		return 'medium';
	}
	if (rowCount < 10_000) {
		return 'large';
	}
	return 'huge';
}

function bridgeContentSizeBucketForBytes(
	byteLength: number,
): 'empty' | 'huge' | 'large' | 'medium' | 'small' | 'unknown' {
	if (!Number.isFinite(byteLength) || byteLength < 0) {
		return 'unknown';
	}
	if (byteLength === 0) {
		return 'empty';
	}
	if (byteLength < 16 * 1024) {
		return 'small';
	}
	if (byteLength < 256 * 1024) {
		return 'medium';
	}
	if (byteLength < 1024 * 1024) {
		return 'large';
	}
	return 'huge';
}
