import { describe, expect, test } from 'vitest';

import { recordBridgeWorkerOutstandingPublicationTelemetry } from '../../src/core/comm-worker/bridge-render-disposition-telemetry.js';
import { recordBridgeReviewRefreshLifecycleTelemetry } from '../../src/core/comm-worker/bridge-review-refresh-lifecycle-telemetry.js';
import type { BridgeTelemetryWorkerBatchRequest } from '../../src/core/telemetry-worker/bridge-telemetry-worker-contracts.js';
import type { BridgeTelemetrySample } from '../../src/foundation/telemetry/bridge-telemetry-event.js';
import { createBridgeTelemetryRecorderFromClient } from '../../src/foundation/telemetry/bridge-telemetry-recorder.js';
import { bridgeDevTelemetryObservationIsSafe } from './bridge-dev-telemetry-otlp.js';
import { createBridgeDevTelemetrySink } from './bridge-dev-telemetry.js';

describe('Bridge dev Review refresh lifecycle telemetry', () => {
	test('retains held render and held promotion samples from the same worker batch', async (): Promise<void> => {
		// Arrange — the real emitters share a batch at the dev collector boundary.
		const samples: BridgeTelemetrySample[] = [];
		const recordSample = (sample: BridgeTelemetrySample): void => {
			samples.push(sample);
		};
		recordBridgeWorkerOutstandingPublicationTelemetry({
			observation: {
				currentCount: 1,
				highWaterMark: 1,
				oldestAgeMilliseconds: 5,
				outcome: 'held',
				phase: 'render_publication_outstanding_changed',
			},
			surface: 'review',
			telemetryClient: { record: recordSample },
		});
		recordBridgeReviewRefreshLifecycleTelemetry({
			event: {
				affectedStableFileCount: 2,
				generation: 1,
				phase: 'candidateHeld',
				presentationClass: { kind: 'promoted', reason: 'commits' },
			},
			recorder: createBridgeTelemetryRecorderFromClient(
				{ enabledScopes: new Set(['web']), scenario: 'review-refresh-proof' },
				{ record: recordSample, flush: (): boolean => true },
			),
		});
		const sink = createBridgeDevTelemetrySink({
			fetchImpl: async (): Promise<Response> => new Response('', { status: 200 }),
		});
		const batch = {
			batchSequence: 1,
			lossSummaries: [],
			schemaVersion: 2,
			telemetrySessionId: 'held-review-proof',
			type: 'telemetry.batch',
			samples: samples.map(
				(
					sample: BridgeTelemetrySample,
					sampleIndex: number,
				): BridgeTelemetryWorkerBatchRequest['samples'][number] => ({
					producerId: sampleIndex === 0 ? 'comm' : 'main',
					producerSequence: 1,
					sample: { sample, timestampMilliseconds: 1, type: 'event.required' },
				}),
			),
		} satisfies BridgeTelemetryWorkerBatchRequest;

		// Act — the network collector is outside the ingestion behavior under proof.
		const result = await sink.ingestWorkerBatch(batch);

		// Assert — one legitimate held outcome must not discard either observation.
		expect.soft(result).toMatchObject({ type: 'accepted', acceptedSampleCount: 2 });
		expect(sink.snapshot()).toMatchObject({
			acceptedBatchCount: 1,
			failedBatchCount: 0,
			lastError: null,
			recentSamples: samples,
		});
	});

	test('admits controlled lifecycle aggregates and rejects raw paths', () => {
		const sample = reviewRefreshLifecycleSample();
		expect(
			bridgeDevTelemetryObservationIsSafe({
				scenario: 'review-refresh-proof',
				samples: [sample],
			}),
		).toBe(true);
		expect(
			bridgeDevTelemetryObservationIsSafe({
				scenario: 'review-refresh-proof',
				samples: [
					{
						...sample,
						stringAttributes: {
							...sample.stringAttributes,
							'agentstudio.bridge.result_reason': '/Users/private/review.ts',
						},
					},
				],
			}),
		).toBe(false);
	});
});

function reviewRefreshLifecycleSample(): BridgeTelemetrySample {
	return {
		booleanAttributes: {},
		durationMilliseconds: null,
		name: 'performance.bridge.web.review_refresh_lifecycle',
		numericAttributes: {
			'agentstudio.bridge.review.generation': 7,
			'agentstudio.bridge.review.refresh.affected_stable_file.count': 3,
		},
		scope: 'web',
		stringAttributes: {
			'agentstudio.bridge.phase': 'review_refresh_install_terminal',
			'agentstudio.bridge.plane': 'control',
			'agentstudio.bridge.priority': 'hot',
			'agentstudio.bridge.result': 'success',
			'agentstudio.bridge.result_reason': 'none',
			'agentstudio.bridge.review.refresh.install_trigger': 'apply_now',
			'agentstudio.bridge.review.refresh.presentation_class': 'promoted',
			'agentstudio.bridge.review.refresh.promotion_reason': 'files',
			'agentstudio.bridge.slice': 'review_metadata',
			'agentstudio.bridge.transport': 'worker',
		},
		traceContext: null,
	};
}
