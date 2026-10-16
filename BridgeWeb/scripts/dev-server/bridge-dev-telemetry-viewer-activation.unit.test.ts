import { describe, expect, test, vi } from 'vitest';

import type { BridgeTelemetryWorkerBatchRequest } from '../../src/core/telemetry-worker/bridge-telemetry-worker-contracts.js';
import type { BridgeTelemetrySample } from '../../src/foundation/telemetry/bridge-telemetry-event.js';
import type { BridgeTelemetryRecorder } from '../../src/foundation/telemetry/bridge-telemetry-recorder.js';
import {
	recordBridgeCommWorkerSessionTelemetrySample,
	recordBridgeFileSelectionCommitTelemetrySample,
	recordBridgeViewerActivationRequestedTelemetrySample,
} from '../../src/foundation/telemetry/bridge-viewer-activation-telemetry.js';
import { createBridgeDevTelemetrySink } from './bridge-dev-telemetry.js';

describe('Bridge dev viewer activation telemetry', () => {
	test('accepts bounded File activation and comm-worker session telemetry', async () => {
		const fetchImpl = vi.fn(async (): Promise<Response> => new Response('', { status: 200 }));
		const samples: BridgeTelemetrySample[] = [];
		const telemetryRecorder = recordingTelemetryRecorder(samples);
		recordBridgeViewerActivationRequestedTelemetrySample({
			activationSequence: 1,
			cause: 'context_switcher',
			fromViewer: 'review',
			sourceAvailable: false,
			telemetryRecorder,
			traceContext: null,
			viewer: 'file',
		});
		recordBridgeFileSelectionCommitTelemetrySample({
			activationSequence: 1,
			selectionOrigin: 'context_switcher',
			sourceGeneration: 2,
			telemetryRecorder,
			traceContext: null,
		});
		recordBridgeCommWorkerSessionTelemetrySample({
			snapshot: {
				failureReason: null,
				latestFileModeDispatchDisposition: 'posted',
				latestFileSelectDispatchDisposition: 'queued_not_ready',
				latestReviewSelectDispatchDisposition: 'dropped_detached',
				lastReplacementReason: null,
				nativeBootstrapInstallCount: 1,
				queuedCommandCount: 2,
				replacementRequestCount: 0,
				state: 'replacement_requested',
			},
			telemetryRecorder,
		});
		const sink = createBridgeDevTelemetrySink({ fetchImpl });

		await expect(sink.ingestWorkerBatch(telemetryBatch(samples))).resolves.toMatchObject({
			type: 'accepted',
			acceptedSampleCount: 3,
		});
	});
});

function recordingTelemetryRecorder(samples: BridgeTelemetrySample[]): BridgeTelemetryRecorder {
	return {
		flush: (): boolean => true,
		isEnabled: (): boolean => true,
		measure: <TResult>(props: { readonly operation: () => TResult }): TResult => props.operation(),
		record: (sample): void => {
			samples.push(sample);
		},
	};
}

function telemetryBatch(
	samples: readonly BridgeTelemetrySample[],
): BridgeTelemetryWorkerBatchRequest {
	return {
		type: 'telemetry.batch',
		schemaVersion: 2,
		telemetrySessionId: 'vite-dev-viewer-activation-session-1',
		batchSequence: 1,
		samples: samples.map((sample, index) => ({
			producerId: 'main',
			producerSequence: index + 1,
			sample: {
				type: 'event.required',
				timestampMilliseconds: index + 1,
				sample,
			},
		})),
		lossSummaries: [],
	};
}
