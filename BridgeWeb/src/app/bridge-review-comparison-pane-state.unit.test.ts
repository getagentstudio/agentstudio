import { describe, expect, test } from 'vitest';

import {
	bridgeMainReviewComparisonPresentationSchema,
	type BridgeMainReviewComparisonPresentation,
} from '../core/comm-worker/bridge-main-review-comparison-presentation.js';
import type { BridgeWorkerPanelChromePatchPayload } from '../core/comm-worker/bridge-worker-contracts.js';
import { makeBridgeReviewPackage } from '../foundation/review-package/bridge-review-package-test-support.js';
import type { BridgeReviewPackage } from '../foundation/review-package/bridge-review-package.js';
import noSourceAttempt from '../test-fixtures/bridge-contract-fixtures/valid/bridge-product-review-comparison-attempt-no-source.json' with { type: 'json' };
import {
	bridgeReviewComparisonPackageMatch,
	bridgeReviewComparisonPaneState,
} from './bridge-review-comparison-pane-state.js';

describe('bridgeReviewComparisonPaneState', () => {
	test('no-source has no pending target or comparison work', (): void => {
		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: bridgeMainReviewComparisonPresentationSchema.parse({
					activeTarget: null,
					attempt: noSourceAttempt,
					displayedSnapshot: { status: 'none' },
					repositoryDefaultTarget: null,
				}),
				displayedReviewPackage: null,
			}),
		).toEqual({ kind: 'settled' });
	});
	test('distinguishes a pending replacement from an initial comparison load', () => {
		const previousPackage = comparisonPackage('package-previous', 'origin/main');

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					attempt: { reviewGeneration: 2, status: 'pending' },
					displayedSnapshot: snapshotForPackage(previousPackage, 'stale'),
				}),
				displayedReviewPackage: previousPackage,
			}),
		).toEqual({
			displayedTargetLabel: 'origin/main',
			kind: 'loadingPrevious',
			requestedTargetLabel: 'feature/new-target',
		});

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					attempt: { reviewGeneration: 2, status: 'pending' },
					displayedSnapshot: { status: 'none' },
				}),
				displayedReviewPackage: null,
			}),
		).toEqual({ kind: 'loadingInitial', requestedTargetLabel: 'feature/new-target' });
	});

	test('keeps a retained Review settled while its exact comparison target refreshes', () => {
		const retainedPackage = comparisonPackage('package-retained', 'feature/new-target');

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					attempt: { reviewGeneration: 2, status: 'pending' },
					displayedSnapshot: snapshotForPackage(retainedPackage, 'stale'),
				}),
				displayedReviewPackage: retainedPackage,
			}),
		).toEqual({ kind: 'settled' });

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					activeTarget: { basis: 'branchTip', kind: 'ref', name: 'feature/new-target' },
					attempt: { reviewGeneration: 2, status: 'pending' },
					displayedSnapshot: snapshotForPackage(retainedPackage, 'stale'),
				}),
				displayedReviewPackage: retainedPackage,
			}),
		).toMatchObject({ kind: 'loadingPrevious' });
	});

	test('carries retry authority and previous-target identity through failures', () => {
		const previousPackage = comparisonPackage('package-previous', 'origin/main');
		const activeTarget = comparisonTarget();

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					activeTarget,
					attempt: { failureKind: 'git', retryable: true, status: 'unavailable' },
					displayedSnapshot: snapshotForPackage(previousPackage, 'stale'),
				}),
				displayedReviewPackage: previousPackage,
			}),
		).toEqual({
			displayedTargetLabel: 'origin/main',
			kind: 'failedPrevious',
			failureKind: 'refreshUnavailable',
			requestedTargetLabel: 'feature/new-target',
			retryTarget: activeTarget,
		});

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					activeTarget,
					attempt: { failureKind: 'git', retryable: false, status: 'unavailable' },
					displayedSnapshot: { status: 'none' },
				}),
				displayedReviewPackage: null,
			}),
		).toEqual({
			kind: 'failedInitial',
			failureKind: 'refreshUnavailable',
			requestedTargetLabel: 'feature/new-target',
			retryTarget: null,
		});
	});

	test('keeps a settled predecessor loading until the matching package is displayed', () => {
		const previousPackage = comparisonPackage('package-previous', 'origin/main');
		const settledPresentation = comparisonPresentation({
			attempt: { reviewGeneration: 2, status: 'settled' },
			displayedSnapshot: {
				packageId: 'package-next',
				reviewGeneration: 2,
				revision: 1,
				status: 'current',
			},
		});

		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: settledPresentation,
				displayedReviewPackage: previousPackage,
			}),
		).toEqual({
			displayedTargetLabel: 'origin/main',
			kind: 'loadingPrevious',
			requestedTargetLabel: 'feature/new-target',
		});

		const currentPackage = comparisonPackage('package-next', 'feature/new-target', 2);
		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: settledPresentation,
				displayedReviewPackage: currentPackage,
			}),
		).toEqual({ kind: 'settled' });
	});

	test('keeps an initial settled snapshot loading until its package is displayed', () => {
		expect(
			bridgeReviewComparisonPaneState({
				comparisonPresentation: comparisonPresentation({
					attempt: { reviewGeneration: 2, status: 'settled' },
					displayedSnapshot: {
						packageId: 'package-next',
						reviewGeneration: 2,
						revision: 1,
						status: 'current',
					},
				}),
				displayedReviewPackage: null,
			}),
		).toEqual({ kind: 'loadingInitial', requestedTargetLabel: 'feature/new-target' });
	});

	test('classifies the exact displayed-package mismatch without exporting package identity', () => {
		const currentPackage = comparisonPackage('package-next', 'feature/new-target', 1);
		const displayedSnapshot = {
			packageId: 'package-next',
			reviewGeneration: 1,
			revision: 2,
			status: 'current' as const,
		};

		expect(
			bridgeReviewComparisonPackageMatch({
				displayedReviewPackage: currentPackage,
				displayedSnapshot,
			}),
		).toBe('revision_mismatch');
		expect(
			bridgeReviewComparisonPackageMatch({
				displayedReviewPackage: null,
				displayedSnapshot,
			}),
		).toBe('package_absent');
	});
});

function comparisonPresentation(props: {
	readonly activeTarget?: NonNullable<
		BridgeWorkerPanelChromePatchPayload['reviewComparison']
	>['activeTarget'];
	readonly attempt: NonNullable<BridgeWorkerPanelChromePatchPayload['reviewComparison']>['attempt'];
	readonly displayedSnapshot: NonNullable<
		BridgeWorkerPanelChromePatchPayload['reviewComparison']
	>['displayedSnapshot'];
}): BridgeMainReviewComparisonPresentation {
	return bridgeMainReviewComparisonPresentationSchema.parse({
		activeTarget: props.activeTarget ?? comparisonTarget(),
		attempt: props.attempt,
		displayedSnapshot: props.displayedSnapshot,
		repositoryDefaultTarget: { branchName: 'main', remoteName: 'origin' },
	});
}

function comparisonTarget(): NonNullable<
	NonNullable<BridgeWorkerPanelChromePatchPayload['reviewComparison']>['activeTarget']
> {
	return { basis: 'commonCommit', kind: 'ref', name: 'feature/new-target' };
}

function comparisonPackage(
	packageId: string,
	targetName: string,
	reviewGeneration = 1,
): BridgeReviewPackage {
	return {
		...makeBridgeReviewPackage(),
		comparisonOrigin: {
			baseOID: 'a'.repeat(40),
			baseRole: 'commonCommit',
			comparedRole: 'capturedWorkingTree',
			kind: 'contribution',
			resolvedTargetOID: 'b'.repeat(40),
			reviewedHeadOID: 'c'.repeat(40),
			symbolicTarget: { basis: 'commonCommit', kind: 'ref', name: targetName },
		},
		packageId,
		reviewGeneration,
		revision: 1,
	};
}

function snapshotForPackage(
	reviewPackage: BridgeReviewPackage,
	status: 'current' | 'stale',
): Extract<
	NonNullable<BridgeWorkerPanelChromePatchPayload['reviewComparison']>['displayedSnapshot'],
	{ readonly status: 'current' | 'stale' }
> {
	return {
		packageId: reviewPackage.packageId,
		reviewGeneration: reviewPackage.reviewGeneration,
		revision: reviewPackage.revision,
		status,
	};
}
