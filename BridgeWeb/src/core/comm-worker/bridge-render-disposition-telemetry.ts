import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import type { BridgePaneSurface } from './bridge-worker-rpc-client.js';

export type BridgeRenderDispositionAdmissionPhase =
	| 'render_disposition_admission_cleared'
	| 'render_disposition_admission_overloaded'
	| 'render_disposition_batch_dispatched'
	| 'render_disposition_batch_terminal';

export type BridgeRenderDispositionTerminalOutcome = 'acked' | 'cleared' | 'degraded' | 'timed_out';

export type BridgeWorkerOutstandingPublicationPhase =
	| 'render_disposition_response_posted_before_owner_effect'
	| 'render_publication_outstanding_changed';

export type BridgeWorkerOutstandingPublicationOutcome =
	| 'cleared'
	| 'held'
	| 'painted'
	| 'published'
	| 'queued'
	| 'rejected'
	| 'released'
	| 'settled'
	| 'superseded';

export interface BridgeWorkerOutstandingPublicationObservation {
	readonly currentCount: number;
	readonly highWaterMark: number;
	readonly oldestAgeMilliseconds: number;
	readonly outcome: BridgeWorkerOutstandingPublicationOutcome;
	readonly phase: BridgeWorkerOutstandingPublicationPhase;
}

export function recordBridgeWorkerOutstandingPublicationTelemetry(props: {
	readonly observation: BridgeWorkerOutstandingPublicationObservation;
	readonly surface: 'file' | 'review';
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}): void {
	if (props.telemetryClient === undefined) return;
	try {
		props.telemetryClient.record({
			scope: 'web',
			name: 'performance.bridge.worker.render_publication_outstanding',
			durationMilliseconds: null,
			traceContext: null,
			stringAttributes: {
				'agentstudio.bridge.phase': props.observation.phase,
				'agentstudio.bridge.plane': 'data',
				'agentstudio.bridge.priority': 'warm',
				'agentstudio.bridge.render_publication.outcome': props.observation.outcome,
				'agentstudio.bridge.result':
					props.observation.outcome === 'rejected'
						? 'failure'
						: props.observation.outcome === 'superseded'
							? 'stale'
							: 'success',
				'agentstudio.bridge.slice': 'command_acks',
				'agentstudio.bridge.transport': 'worker',
				'agentstudio.bridge.viewer': props.surface,
			},
			numericAttributes: {
				'agentstudio.bridge.render_publication.current_count': props.observation.currentCount,
				'agentstudio.bridge.render_publication.high_water_mark': props.observation.highWaterMark,
				'agentstudio.bridge.render_publication.oldest_age_ms': Math.max(
					0,
					props.observation.oldestAgeMilliseconds,
				),
			},
			booleanAttributes: {},
		});
	} catch {
		// Optional operational evidence must never control publication ownership.
	}
}

export function recordBridgeRenderDispositionAdmissionTelemetry(props: {
	readonly acknowledgementDurationMilliseconds?: number;
	readonly batchReceiptCount?: number;
	readonly duplicateCount: number;
	readonly inFlightReceiptCount: number;
	readonly oldestPendingAgeMilliseconds: number;
	readonly outcome?: BridgeRenderDispositionTerminalOutcome;
	readonly pendingHighWaterMark: number;
	readonly pendingReceiptCount: number;
	readonly phase: BridgeRenderDispositionAdmissionPhase;
	readonly producedCount: number;
	readonly retainedReceiptCount: number;
	readonly surface: BridgePaneSurface;
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}): void {
	props.telemetryClient?.record({
		scope: 'web',
		name: 'performance.bridge.web.render_disposition_admission',
		durationMilliseconds: props.acknowledgementDurationMilliseconds ?? null,
		traceContext: null,
		stringAttributes: {
			'agentstudio.bridge.phase': props.phase,
			'agentstudio.bridge.plane': 'control',
			'agentstudio.bridge.priority': 'warm',
			'agentstudio.bridge.result': bridgeRenderDispositionTelemetryResult(props.outcome),
			'agentstudio.bridge.slice': 'command_acks',
			'agentstudio.bridge.transport': 'worker',
			'agentstudio.bridge.viewer': props.surface === 'fileView' ? 'file' : 'review',
			...(props.outcome === undefined
				? {}
				: { 'agentstudio.bridge.render_disposition.outcome': props.outcome }),
		},
		numericAttributes: {
			'agentstudio.bridge.render_disposition.duplicate_count': props.duplicateCount,
			'agentstudio.bridge.render_disposition.in_flight_count': props.inFlightReceiptCount,
			'agentstudio.bridge.render_disposition.oldest_pending_age_ms': Math.max(
				0,
				props.oldestPendingAgeMilliseconds,
			),
			'agentstudio.bridge.render_disposition.pending_count': props.pendingReceiptCount,
			'agentstudio.bridge.render_disposition.pending_high_water_mark': props.pendingHighWaterMark,
			'agentstudio.bridge.render_disposition.produced_count': props.producedCount,
			'agentstudio.bridge.render_disposition.retained_count': props.retainedReceiptCount,
			...(props.batchReceiptCount === undefined
				? {}
				: {
						'agentstudio.bridge.render_disposition.batch_receipt_count': props.batchReceiptCount,
					}),
		},
		booleanAttributes: {},
	});
}

export function recordBridgeWorkerRenderDispositionBatchTelemetry(props: {
	readonly acceptedCount: number;
	readonly duplicateCount: number;
	readonly receiptCount: number;
	readonly rejectedCount: number;
	readonly surface: 'file' | 'review';
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}): void {
	const degraded = props.rejectedCount > 0;
	props.telemetryClient?.record({
		scope: 'web',
		name: 'performance.bridge.worker.render_disposition_batch',
		durationMilliseconds: null,
		traceContext: null,
		stringAttributes: {
			'agentstudio.bridge.phase': 'render_disposition_batch_applied',
			'agentstudio.bridge.plane': 'data',
			'agentstudio.bridge.priority': 'warm',
			'agentstudio.bridge.render_disposition.outcome': degraded ? 'degraded' : 'acked',
			'agentstudio.bridge.result': degraded ? 'failed' : 'success',
			'agentstudio.bridge.slice': 'command_acks',
			'agentstudio.bridge.transport': 'worker',
			'agentstudio.bridge.viewer': props.surface,
		},
		numericAttributes: {
			'agentstudio.bridge.render_disposition.accepted_count': props.acceptedCount,
			'agentstudio.bridge.render_disposition.batch_receipt_count': props.receiptCount,
			'agentstudio.bridge.render_disposition.duplicate_count': props.duplicateCount,
			'agentstudio.bridge.render_disposition.rejected_count': props.rejectedCount,
		},
		booleanAttributes: {},
	});
}

function bridgeRenderDispositionTelemetryResult(
	outcome: BridgeRenderDispositionTerminalOutcome | undefined,
): 'failed' | 'success' {
	return outcome === 'degraded' || outcome === 'timed_out' ? 'failed' : 'success';
}
