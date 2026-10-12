import { describe, expect, test } from 'vitest';

import {
	makePassingProductOnlyProof,
	paintSnapshotForTest,
} from './product-only-real-router-contract.test-support.ts';
import { collectBridgeViewerProductOnlyContractViolations } from './product-only-real-router-contract.ts';
import { reviewFailureSnapshotFromPaintFailureEvidence } from './product-only-real-router-review-failure.ts';
import {
	BridgeViewerReviewPaintWaitFailure,
	type BridgeViewerReviewPaintFailureSnapshot,
	bridgeViewerReviewPaintFailureEvidenceFromError,
	bridgeViewerReviewPaintViewportRelation,
} from './product-only-real-router-review-paint.ts';

describe('Bridge Viewer Review paint diagnostics', () => {
	test('keeps a failed ledger entry snapshot shape', () => {
		const snapshot = {
			actualScrollTop: 400,
			captureError: null,
			codeScroll: { clientHeight: 900, scrollHeight: 1_800, scrollTop: 400 },
			header: {
				contentState: 'placeholder',
				paintedPublicationId: null,
				paintedSourceCorrelations: null,
				renderDispositionSettledOutcome: null,
				renderDispositionSettledPublicationId: null,
			},
			headerRendered: true,
			itemElement: null,
			itemInDom: true,
			itemRect: {
				bottom: 1_000,
				height: 100,
				left: 0,
				right: 1_000,
				top: 900,
				width: 1_000,
			},
			requestedScrollTop: 450,
			viewportRelation: 'partly-in-view',
			workerLastPublishedVisibleItemIds: null,
		} satisfies BridgeViewerReviewPaintFailureSnapshot;
		const proof = makePassingProductOnlyProof();
		const failedEntry = {
			...proof.reviewFreshRoute.paintLedger[1],
			failureSnapshot: snapshot,
			publicationId: null,
			reason: 'receipt missing',
			status: 'failed' as const,
		};

		expect(failedEntry.failureSnapshot).toEqual(snapshot);
		expect(failedEntry.requestedScrollTop).toBe(900);
		expect(failedEntry.actualScrollTop).toBe(900);
	});

	test('carries the partial ledger and pending target snapshot through an owner abort', () => {
		const passingProof = makePassingProductOnlyProof();
		const paintedEntry = passingProof.reviewFreshRoute.paintLedger[0];
		const existingEntry = passingProof.reviewFreshRoute.paintLedger[1];
		if (paintedEntry === undefined || existingEntry === undefined)
			throw new Error('expected two paint ledger entries');
		const pendingEntry = {
			...existingEntry,
			status: 'targeted' as const,
			targetSnapshot: paintSnapshotForTest({ viewportRelation: 'partly-in-view' }),
		};
		const cause = new Error('BRIDGE_PRODUCT_JOURNEY_DEADLINE_EXCEEDED: awaiting Review item paint');
		const failure = new BridgeViewerReviewPaintWaitFailure(
			cause,
			paintSnapshotForTest({ viewportRelation: 'partly-in-view' }),
			[paintedEntry, pendingEntry],
			pendingEntry.itemId,
		);
		const evidence = bridgeViewerReviewPaintFailureEvidenceFromError(failure);
		if (evidence === null) throw new Error('expected paint failure evidence');

		const record = reviewFailureSnapshotFromPaintFailureEvidence(evidence);
		expect(record.paintLedger).toEqual([paintedEntry, pendingEntry]);
		expect(record.pendingPaintItemId).toBe(pendingEntry.itemId);
		expect(record.paintLedger[1]?.targetSnapshot.viewportRelation).toBe('partly-in-view');
	});

	test('uses the real container rectangle when scroll metrics are zero', () => {
		expect(
			bridgeViewerReviewPaintViewportRelation({
				clientHeight: 0,
				itemRect: { bottom: 688, top: 440 },
				scrollHeight: 0,
				viewportRect: { bottom: 980, top: 0 },
			}),
		).toBe('in-view');
	});

	test('fails targeted paint coverage when a receipt is missing', () => {
		const passingProof = makePassingProductOnlyProof();
		const proof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				paintLedger: passingProof.reviewFreshRoute.paintLedger.map((entry) =>
					entry.itemId === 'review-item-3'
						? {
								...entry,
								publicationId: null,
								reason: 'receipt missing',
								status: 'failed' as const,
							}
						: entry,
				),
			},
		};
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);
		expect(violationCodes).toContain('REVIEW_FRESH_ROUTE_VISIBLE_PAINT_COVERAGE_MISSING');
	});

	test('does not fail paint coverage for a passive painted-set deficit', () => {
		const passingProof = makePassingProductOnlyProof();
		const proof = {
			...passingProof,
			reviewFreshRoute: {
				...passingProof.reviewFreshRoute,
				hydrationCoverage: {
					...passingProof.reviewFreshRoute.hydrationCoverage,
					observedHydratedNonSelectedItemIds: ['review-item-2'],
				},
			},
		};
		const violationCodes = collectBridgeViewerProductOnlyContractViolations(proof).map(
			(violation) => violation.code,
		);
		expect(violationCodes).not.toContain('REVIEW_FRESH_ROUTE_VISIBLE_PAINT_COVERAGE_MISSING');
	});
});
