import { expect, test } from 'vitest';

import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainReviewTreeDisplayRow,
} from './bridge-main-render-snapshot-store.js';
import { makeReviewDisplayPatchEvent } from './bridge-main-render-snapshot-store.test-support.js';
import {
	applyReviewDisplayPatchEventInPlace,
	type MutableBridgeMainRenderSnapshot,
} from './bridge-main-review-display-state.js';
import type { BridgeProductReviewComparisonPresentation } from './bridge-product-review-comparison-presentation-contracts.js';

test('accepts no comparison and classifies the following non-null comparison patch', () => {
	// Arrange
	const comparison = {
		activeTarget: null,
		attempt: { status: 'selectionRequired' },
		displayedSnapshot: { status: 'none' },
		repositoryDefaultTarget: null,
	} satisfies BridgeProductReviewComparisonPresentation;
	const snapshot: MutableBridgeMainRenderSnapshot = {
		...createBridgeMainRenderSnapshotStore().getSnapshot(),
		panelChromeSlice: { reviewComparison: comparison },
		reviewItemById: {},
		reviewItemIdsByIndex: [],
		reviewTreeRowsByIndex: [],
	};
	const reviewItemIndexById = new Map<string, number>();
	const reviewTreeRowById = new Map<string, BridgeMainReviewTreeDisplayRow>();
	const event = makeReviewDisplayPatchEvent();

	// Act / Assert — null is an admitted absence, not a failed comparison object.
	expect(() =>
		applyReviewDisplayPatchEventInPlace({
			event: {
				...event,
				patches: [{ operation: 'replace', payload: null, slice: 'reviewComparison' }],
			},
			reviewItemIndexById,
			reviewTreeRowById,
			snapshot,
		}),
	).not.toThrow();
	expect(snapshot.panelChromeSlice.reviewComparison).toBeNull();

	const failedComparison = {
		...comparison,
		attempt: {
			failureKind: 'loadFailed:package:cancelled',
			retryable: true,
			status: 'unavailable',
		},
	} satisfies BridgeProductReviewComparisonPresentation;
	const effect = applyReviewDisplayPatchEventInPlace({
		event: {
			...event,
			patches: [{ operation: 'replace', payload: failedComparison, slice: 'reviewComparison' }],
			projectionRevision: event.projectionRevision + 1,
			sequence: event.sequence + 1,
		},
		reviewItemIndexById,
		reviewTreeRowById,
		snapshot,
	});
	expect(effect?.comparisonChanged).toBe(true);
	expect(snapshot.panelChromeSlice.reviewComparison).toEqual({
		...failedComparison,
		attempt: { ...failedComparison.attempt, failureKind: 'refreshUnavailable' },
	});
});
