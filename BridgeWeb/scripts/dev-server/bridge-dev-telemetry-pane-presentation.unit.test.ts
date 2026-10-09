import { describe, expect, test, vi } from 'vitest';

import type { BridgeTelemetryWorkerBatchRequest } from '../../src/core/telemetry-worker/bridge-telemetry-worker-contracts.js';
import type { BridgeTelemetrySample } from '../../src/foundation/telemetry/bridge-telemetry-event.js';
import { createBridgeDevTelemetrySink } from './bridge-dev-telemetry.js';

describe('Bridge dev pane-presentation telemetry', () => {
	test.each(['pending', 'no_source'])(
		'accepts %s through worker, main, and rendered comparison telemetry',
		async (attemptStatus: string): Promise<void> => {
			// Arrange
			const fetchImpl = vi.fn(async (): Promise<Response> => new Response('', { status: 200 }));
			const sink = createBridgeDevTelemetrySink({
				fetchImpl,
				marker: 'vite-dev-proof-1',
				nowUnixNano: () => '1782218790000000000',
				serviceVersion: 'vite-dev',
				worktreeHash: 'wt-hash',
			});
			const panePresentationSample: BridgeTelemetrySample = {
				booleanAttributes: { 'agentstudio.bridge.refreshing.review': true },
				durationMilliseconds: null,
				name: 'performance.bridge.web.pane_presentation',
				numericAttributes: {
					'agentstudio.bridge.presentation.revision': 3,
					'agentstudio.bridge.review.generation': 2,
				},
				scope: 'web',
				stringAttributes: {
					'agentstudio.bridge.comparison.attempt.status': attemptStatus,
					'agentstudio.bridge.phase': 'pane_presentation_applied',
					'agentstudio.bridge.plane': 'control',
					'agentstudio.bridge.presentation.disposition': 'applied',
					'agentstudio.bridge.priority': 'hot',
					'agentstudio.bridge.result': 'success',
					'agentstudio.bridge.slice': 'review_metadata',
					'agentstudio.bridge.transport': 'worker',
				},
				traceContext: null,
			};
			const batch = telemetryBatch([
				panePresentationSample,
				mainApplicationSample(panePresentationSample),
				workerPublicationSample(panePresentationSample),
				renderedComparisonSample(panePresentationSample),
			]);

			// Act / Assert
			await expect(sink.ingestWorkerBatch(batch)).resolves.toMatchObject({ type: 'accepted' });
			expect(sink.snapshot()).toMatchObject({ acceptedBatchCount: 1, failedBatchCount: 0 });
			expect(sink.snapshot().recentSamples).toHaveLength(4);
		},
	);
});

function mainApplicationSample(sample: BridgeTelemetrySample): BridgeTelemetrySample {
	return {
		...sample,
		booleanAttributes: {},
		numericAttributes: {
			'agentstudio.bridge.presentation.publication_sequence': 5,
			'agentstudio.bridge.worker.derivation_epoch': 1,
		},
		stringAttributes: {
			...sample.stringAttributes,
			'agentstudio.bridge.comparison.attempt.status': 'absent',
			'agentstudio.bridge.panel.operation': 'reset',
			'agentstudio.bridge.phase': 'panel_chrome_applied',
			'agentstudio.bridge.transport': 'local',
			'agentstudio.bridge.viewer': 'review',
		},
	};
}

function workerPublicationSample(sample: BridgeTelemetrySample): BridgeTelemetrySample {
	return {
		...sample,
		numericAttributes: {
			'agentstudio.bridge.presentation.publication_sequence': 2,
			'agentstudio.bridge.presentation.revision': 3,
			'agentstudio.bridge.review.generation': 2,
			'agentstudio.bridge.worker.derivation_epoch': 1,
		},
		stringAttributes: {
			...sample.stringAttributes,
			'agentstudio.bridge.panel.operation': 'reset',
			'agentstudio.bridge.phase': 'panel_chrome_published',
			'agentstudio.bridge.presentation.disposition': 'published',
			'agentstudio.bridge.viewer': 'file',
		},
	};
}

function renderedComparisonSample(sample: BridgeTelemetrySample): BridgeTelemetrySample {
	return {
		...sample,
		booleanAttributes: {},
		numericAttributes: {},
		stringAttributes: {
			...sample.stringAttributes,
			'agentstudio.bridge.comparison.package_match': 'matched',
			'agentstudio.bridge.comparison.pane_state': 'settled',
			'agentstudio.bridge.phase': 'comparison_pane_rendered',
			'agentstudio.bridge.presentation.disposition': 'rendered',
			'agentstudio.bridge.transport': 'local',
			'agentstudio.bridge.viewer': 'review',
		},
	};
}

function telemetryBatch(
	samples: readonly BridgeTelemetrySample[],
): BridgeTelemetryWorkerBatchRequest {
	return {
		batchSequence: 1,
		lossSummaries: [],
		samples: samples.map((sample, index) => ({
			producerId: 'main',
			producerSequence: index + 1,
			sample: { sample, timestampMilliseconds: index + 1, type: 'event.required' },
		})),
		schemaVersion: 2,
		telemetrySessionId: 'vite-dev-session-1',
		type: 'telemetry.batch',
	};
}
