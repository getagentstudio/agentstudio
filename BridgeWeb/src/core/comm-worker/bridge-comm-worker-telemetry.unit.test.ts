import { describe, expect, test } from 'vitest';

import noSourceAttempt from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-comparison-attempt-no-source.json' with { type: 'json' };
import {
	bridgeCommWorkerComparisonTelemetryFacts,
	recordBridgeCommWorkerTaskTelemetry,
} from './bridge-comm-worker-telemetry.js';
import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';

describe('Bridge comm worker telemetry', () => {
	test('projects no-source telemetry without inventing a Review generation', (): void => {
		expect(
			bridgeCommWorkerComparisonTelemetryFacts({
				fileRefreshFailure: null,
				nativeActivity: 'foreground',
				presentationRevision: 1,
				refreshingLanes: [],
				reviewComparison: bridgeProductReviewComparisonPresentationSchema.parse({
					activeTarget: null,
					attempt: noSourceAttempt,
					displayedSnapshot: { status: 'none' },
					repositoryDefaultTarget: null,
				}),
				workAdmissionGeneration: 1,
			}),
		).toEqual({ comparisonAttemptStatus: 'no_source' });
	});
	test('records only the bounded semantic class for message admission', () => {
		const samples: Parameters<
			NonNullable<
				Parameters<typeof recordBridgeCommWorkerTaskTelemetry>[0]['telemetryClient']
			>['record']
		>[0][] = [];
		recordBridgeCommWorkerTaskTelemetry({
			command: 'annotationCommand',
			durationMilliseconds: 1,
			lane: 'selected',
			semanticClass: 'urgent_action',
			taskKind: 'message_handler',
			telemetryClient: {
				record: (sample): void => {
					samples.push(sample);
				},
			},
		});

		expect(samples).toHaveLength(1);
		expect(samples[0]?.stringAttributes).toMatchObject({
			'agentstudio.bridge.worker.command': 'annotationCommand',
			'agentstudio.bridge.worker.semantic_class': 'urgent_action',
		});
		expect(JSON.stringify(samples[0])).not.toContain('exact durable body');
	});
});
