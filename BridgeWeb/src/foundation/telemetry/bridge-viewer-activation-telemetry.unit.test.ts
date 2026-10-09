import { describe, expect, test } from 'vitest';

import type { BridgeTelemetrySample } from './bridge-telemetry-event.js';
import type { BridgeTelemetryRecorder } from './bridge-telemetry-recorder.js';
import {
	recordBridgeCommWorkerSessionTelemetrySample,
	recordBridgeFileSelectionCommitTelemetrySample,
	recordBridgeViewerActivationRequestedTelemetrySample,
} from './bridge-viewer-activation-telemetry.js';

function makeCapturingRecorder(samples: BridgeTelemetrySample[]): BridgeTelemetryRecorder {
	return {
		flush: (): boolean => true,
		isEnabled: (): boolean => true,
		measure: (props) => props.operation(),
		record: (sample): void => void samples.push(sample),
	};
}

describe('Bridge viewer activation telemetry', () => {
	test('records one scrubbed Review file-corner activation request', () => {
		const samples: BridgeTelemetrySample[] = [];

		recordBridgeViewerActivationRequestedTelemetrySample({
			activationSequence: 7,
			cause: 'review_file_corner',
			fromViewer: 'review',
			sourceAvailable: false,
			telemetryRecorder: makeCapturingRecorder(samples),
			traceContext: null,
			viewer: 'file',
		});

		expect(samples).toEqual([
			expect.objectContaining({
				name: 'performance.bridge.web.viewer_activation',
				stringAttributes: {
					'agentstudio.bridge.activation.cause': 'review_file_corner',
					'agentstudio.bridge.activation.from_viewer': 'review',
					'agentstudio.bridge.phase': 'viewer_activation_requested',
					'agentstudio.bridge.plane': 'control',
					'agentstudio.bridge.priority': 'warm',
					'agentstudio.bridge.result': 'started',
					'agentstudio.bridge.slice': 'review_rpc',
					'agentstudio.bridge.transport': 'local',
					'agentstudio.bridge.viewer': 'file',
				},
				numericAttributes: {
					'agentstudio.bridge.activation.sequence': 7,
				},
				booleanAttributes: {
					'agentstudio.bridge.activation.source_available': false,
				},
			}),
		]);
		expect(JSON.stringify(samples)).not.toContain('path');
	});

	test('records a scrubbed File selection commit without forcing path identity into OTEL', () => {
		const samples: BridgeTelemetrySample[] = [];

		recordBridgeFileSelectionCommitTelemetrySample({
			activationSequence: 9,
			selectionOrigin: 'review_file_corner',
			sourceGeneration: 12,
			telemetryRecorder: makeCapturingRecorder(samples),
			traceContext: null,
		});

		expect(samples).toEqual([
			expect.objectContaining({
				name: 'performance.bridge.web.selection_commit',
				stringAttributes: expect.objectContaining({
					'agentstudio.bridge.phase': 'selection_commit',
					'agentstudio.bridge.result': 'success',
					'agentstudio.bridge.selection.origin': 'review_file_corner',
					'agentstudio.bridge.viewer': 'file',
				}),
				numericAttributes: {
					'agentstudio.bridge.activation.sequence': 9,
					'agentstudio.bridge.source.generation': 12,
				},
			}),
		]);
		expect(JSON.stringify(samples)).not.toContain('path');
	});

	test('records context-switcher File selection using the same bounded vocabulary', () => {
		const samples: BridgeTelemetrySample[] = [];

		recordBridgeFileSelectionCommitTelemetrySample({
			activationSequence: 10,
			selectionOrigin: 'context_switcher',
			sourceGeneration: 13,
			telemetryRecorder: makeCapturingRecorder(samples),
			traceContext: null,
		});

		expect(samples[0]?.stringAttributes['agentstudio.bridge.selection.origin']).toBe(
			'context_switcher',
		);
	});

	test('records scrubbed main-thread comm-worker replacement state', () => {
		const samples: BridgeTelemetrySample[] = [];

		recordBridgeCommWorkerSessionTelemetrySample({
			snapshot: {
				failureReason: null,
				latestFileModeDispatchDisposition: 'posted',
				latestFileSelectDispatchDisposition: 'queued_not_ready',
				latestReviewSelectDispatchDisposition: null,
				lastReplacementReason: {
					kind: 'runtimeRecovery',
					source: 'reviewInstalledReceiptFailed',
				},
				nativeBootstrapInstallCount: 1,
				queuedCommandCount: 2,
				replacementRequestCount: 1,
				state: 'replacement_requested',
			},
			telemetryRecorder: makeCapturingRecorder(samples),
		});

		expect(samples).toEqual([
			expect.objectContaining({
				name: 'performance.bridge.web.comm_worker_session',
				stringAttributes: expect.objectContaining({
					'agentstudio.bridge.phase': 'comm_worker_session_snapshot',
					'agentstudio.bridge.worker.file_select_dispatch': 'queued_not_ready',
					'agentstudio.bridge.worker.session_state': 'replacement_requested',
					'agentstudio.bridge.worker.replacement_reason': 'runtime_recovery',
					'agentstudio.bridge.worker.replacement_source': 'review_installed_receipt_failed',
				}),
				numericAttributes: {
					'agentstudio.bridge.worker.native_bootstrap_install.count': 1,
					'agentstudio.bridge.worker.queued_command.count': 2,
					'agentstudio.bridge.worker.replacement_request.count': 1,
				},
			}),
		]);
		expect(JSON.stringify(samples)).not.toContain('path');
	});
});
