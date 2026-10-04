import { describe, expect, test } from 'vitest';

import noSourceAttempt from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-comparison-attempt-no-source.json' with { type: 'json' };
import { bridgeProductReviewComparisonPresentationSchema } from './bridge-product-review-comparison-presentation-contracts.js';
import { bridgeProductMetadataFrameSchema } from './bridge-product-session-contracts.js';

describe('Bridge product session Review comparison contract', () => {
	test('decodes the shared payload-free no-source attempt and refuses extra payload', (): void => {
		const presentation = {
			activeTarget: null,
			attempt: noSourceAttempt,
			displayedSnapshot: { status: 'none' },
			repositoryDefaultTarget: null,
		};
		expect(noSourceAttempt).toEqual({ status: 'noSource' });
		expect(bridgeProductReviewComparisonPresentationSchema.safeParse(presentation).success).toBe(
			true,
		);
		expect(bridgeProductReviewComparisonPresentationSchema.parse(presentation)).toEqual(
			presentation,
		);
		for (const payload of [
			{ reviewGeneration: 1 },
			{ failureKind: 'missingRoot' },
			{ retryable: true },
		]) {
			expect(
				bridgeProductReviewComparisonPresentationSchema.safeParse({
					...presentation,
					attempt: { ...noSourceAttempt, ...payload },
				}).success,
			).toBe(false);
		}
	});

	test('accepts the exact comparison-aware pane presentation and rejects the activity-only shape', () => {
		const frame = {
			fileRefreshFailure: null,
			kind: 'pane.presentation',

			operationCorrelationId: null,
			metadataStreamId: 'metadata-stream-comparison-presentation',
			nativeActivity: 'foreground',
			paneSessionId: 'pane-session-1',
			presentationRevision: 5,
			refreshingLanes: ['review'],
			reviewComparison: {
				activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'feature/review' },
				attempt: { reviewGeneration: 8, status: 'pending' },
				displayedSnapshot: {
					packageId: 'package-predecessor',
					reviewGeneration: 7,
					revision: 3,
					status: 'stale',
				},
				repositoryDefaultTarget: {
					branchName: 'main',
					remoteName: 'origin',
				},
			},
			streamSequence: 5,
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		} as const;

		expect(bridgeProductMetadataFrameSchema.parse(frame)).toEqual(frame);
		expect(
			bridgeProductMetadataFrameSchema.safeParse({
				...frame,
				presentationRevision: undefined,
			}).success,
		).toBe(false);
		expect(
			bridgeProductMetadataFrameSchema.safeParse({ ...frame, reviewComparison: undefined }).success,
		).toBe(false);
		expect(
			bridgeProductMetadataFrameSchema.safeParse({ ...frame, fileRefreshFailure: undefined })
				.success,
		).toBe(false);
		expect(
			bridgeProductMetadataFrameSchema.safeParse({
				...frame,
				fileRefreshFailure: {
					failureKind: 'fileSourceUnavailable',
					retryable: false,
				},
			}).success,
		).toBe(false);
		expect(
			bridgeProductMetadataFrameSchema.safeParse({
				...frame,
				fileRefreshFailure: {
					failureKind: 'unknownFailure',
					retryable: false,
				},
			}).success,
		).toBe(false);
	});

	test('rejects retired target catalog metadata', () => {
		const comparisonPresentation = {
			activeTarget: null,
			attempt: { status: 'selectionRequired' },
			displayedSnapshot: { status: 'none' },
			repositoryDefaultTarget: null,
			targetCatalog: {
				branches: [{ branchName: 'main', kind: 'remoteTracking', oid: 'a'.repeat(40) }],
				defaultTarget: null,
			},
		};
		const frame = {
			fileRefreshFailure: null,
			kind: 'pane.presentation',

			operationCorrelationId: null,
			metadataStreamId: 'metadata-stream-invalid-target-catalog',
			nativeActivity: 'foreground',
			paneSessionId: 'pane-session-1',
			presentationRevision: 5,
			refreshingLanes: ['review'],
			reviewComparison: comparisonPresentation,
			streamSequence: 5,
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		} as const;

		expect(bridgeProductMetadataFrameSchema.safeParse(frame).success).toBe(false);
	});
});
