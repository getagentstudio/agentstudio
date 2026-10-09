import { expect, test } from 'vitest';

import {
	bridgeReviewFallbackRegionPresentation,
	bridgeReviewReadyRegionPresentation,
	bridgeReviewSelectedContentReadFailure,
	bridgeReviewRegionSurfaceStatus,
} from './bridge-review-region-presentation.js';

const readyInput = {
	identity: 'package-1:1:1',
	hasChangedFiles: true,
	hasSelectedItem: true,
	selectedContentLoading: false,
	selectedContentFailure: null,
	surface: { kind: 'current' },
} as const;

test('no-source is Empty without a read, while pane failures still take precedence', (): void => {
	expect(
		bridgeReviewFallbackRegionPresentation({
			status: 'noSource',
			comparisonPaneState: { kind: 'settled' },
		}),
	).toEqual({ kind: 'empty', reason: 'noSource' });
	expect(
		bridgeReviewFallbackRegionPresentation({
			status: 'noSource',
			comparisonPaneState: { kind: 'settled' },
			surface: {
				kind: 'failed',
				failure: { kind: 'retryable', scope: 'pane', message: "Bridge couldn't start." },
			},
		}),
	).toMatchObject({ kind: 'failed', retainsContent: false, failure: { scope: 'pane' } });
});

test('selected-content Loading leaves its settled tree sibling current', (): void => {
	expect(
		bridgeReviewReadyRegionPresentation({
			...readyInput,
			region: 'content',
			selectedContentLoading: true,
		}),
	).toEqual({ kind: 'loading' });
	expect(
		bridgeReviewReadyRegionPresentation({
			...readyInput,
			region: 'tree',
			selectedContentLoading: true,
		}),
	).toEqual({ kind: 'content' });
});

test('no selection is Empty while a nonempty inventory stays content', (): void => {
	expect(
		bridgeReviewReadyRegionPresentation({
			...readyInput,
			region: 'content',
			hasSelectedItem: false,
		}),
	).toEqual({ kind: 'empty', reason: 'noSelection' });
	expect(
		bridgeReviewReadyRegionPresentation({ ...readyInput, region: 'tree', hasSelectedItem: false }),
	).toEqual({ kind: 'content' });
});

test('a permanent unavailable selected read offers correction, not surface Retry', (): void => {
	expect(
		bridgeReviewReadyRegionPresentation({
			...readyInput,
			region: 'content',
			selectedContentFailure: bridgeReviewSelectedContentReadFailure('unavailable'),
		}),
	).toMatchObject({ kind: 'failed', failure: { kind: 'permanent', scope: 'read' } });
});

test('a permanent target failure overrides a completed empty read', (): void => {
	const surface = bridgeReviewRegionSurfaceStatus({
		comparisonPaneState: {
			kind: 'failedPrevious',
			failureKind: 'targetNotFound',
			displayedTargetLabel: 'main',
			requestedTargetLabel: 'gone',
			retryTarget: null,
		},
	});
	expect(
		bridgeReviewReadyRegionPresentation({
			...readyInput,
			region: 'tree',
			hasChangedFiles: false,
			surface,
		}),
	).toMatchObject({
		kind: 'failed',
		retainsContent: true,
		failure: { kind: 'permanent', message: 'Comparison unavailable' },
	});
});

test('a metadata failure preserves the last complete Review and uses refresh vocabulary', (): void => {
	const surface = bridgeReviewRegionSurfaceStatus({
		comparisonPaneState: { kind: 'settled' },
		recoveryStatus: {
			status: 'failedRetryable',
			view: { kind: 'review.metadata', subscriptionId: 'ready-review-e3' },
		},
	});
	expect(
		bridgeReviewReadyRegionPresentation({ ...readyInput, region: 'tree', surface }),
	).toMatchObject({
		kind: 'failed',
		retainsContent: true,
		failure: { kind: 'retryable', message: 'Update unavailable' },
	});
});

test('recovering rests hidden or held and stays Loading without a good bank', (): void => {
	const recoveryStatus = {
		status: 'recovering',
		view: { kind: 'review.metadata', subscriptionId: 'review-e3' },
	} as const;
	const comparisonPaneState = { kind: 'settled' } as const;
	expect(
		bridgeReviewRegionSurfaceStatus({ comparisonPaneState, recoveryStatus, isActive: false }),
	).toEqual({ kind: 'updating', rest: 'hidden' });
	expect(
		bridgeReviewRegionSurfaceStatus({
			comparisonPaneState,
			recoveryStatus,
			refreshPresentation: {
				activeIdentity: null,
				failure: null,
				candidate: {
					affectedStableFileIdentities: [],
					effectivePresentationClass: { kind: 'promoted', reason: 'unknown' },
					identity: {
						packageId: 'package',
						publicationId: 'publication',
						generation: 1,
						revision: 2,
						sourceIdentity: 'source',
					},
					role: 'updateReady',
					startDisposition: { kind: 'replacement' },
				},
			},
		}),
	).toEqual({ kind: 'updating', rest: 'held' });
	expect(
		bridgeReviewFallbackRegionPresentation({
			status: 'loading',
			comparisonPaneState,
			recoveryStatus,
		}),
	).toEqual({ kind: 'loading' });
});

test.each([null, { kind: 'ref', name: 'main', basis: 'commonCommit' }] as const)(
	'comparison failure takes precedence over recovering (Retry target %j)',
	(retryTarget): void => {
		const surface = bridgeReviewRegionSurfaceStatus({
			comparisonPaneState: {
				kind: 'failedPrevious',
				displayedTargetLabel: 'main',
				requestedTargetLabel: 'gone',
				failureKind: 'targetNotFound',
				retryTarget,
			},
			recoveryStatus: {
				status: 'recovering',
				view: { kind: 'review.metadata', subscriptionId: 'review-e3' },
			},
		});
		expect(surface).toMatchObject({
			kind: 'failed',
			failure: { kind: retryTarget === null ? 'permanent' : 'retryable' },
		});
	},
);
