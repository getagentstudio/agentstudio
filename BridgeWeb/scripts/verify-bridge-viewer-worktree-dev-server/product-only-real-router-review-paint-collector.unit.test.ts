import type { Page } from 'playwright';
import { expect, test, vi } from 'vitest';

import { paintSnapshotForTest } from './product-only-real-router-contract.test-support.ts';
import { createOwnedProductJourneyDeadline } from './product-only-real-router-journey-deadline.ts';
import { captureBridgeViewerProductOnlyJourneyFailure } from './product-only-real-router-review-failure.ts';
import { observeReviewPaintReceipt } from './product-only-real-router-review-paint-observation.ts';
import {
	bridgeViewerReviewPaintFailureEvidenceFromError,
	collectReviewPaintLedger,
} from './product-only-real-router-review-paint.ts';
import { makeDeferred } from './utils.ts';

test.each(['targeting', 'viewport', 'restore'] as const)(
	'collector preserves completed evidence on owner expiry during %s',
	async (heldStage) => {
		const owner = new AbortController();
		const arrived = makeDeferred<void>();
		const held = makeDeferred<void>();
		let closed = false;
		const page = {
			evaluate: vi.fn(async (callback: unknown, argument: unknown): Promise<unknown> => {
				if (closed) throw new Error('Target page has been closed');
				if (callback === observeReviewPaintReceipt) return { publicationId: 'publication-a' };
				if (typeof argument === 'string') return undefined; // observer cancellation
				return paintSnapshotForTest({ actualScrollTop: 0, requestedScrollTop: 0 });
			}),
			close: async (): Promise<void> => {
				closed = true;
			},
		} as unknown as Page;
		const deadline = createOwnedProductJourneyDeadline({
			signal: owner.signal,
			page,
			browser: { close: async (): Promise<void> => {} },
		});
		let readCount = 0;
		const collection = collectReviewPaintLedger({
			expectedItemIds: heldStage === 'restore' ? ['item-a'] : ['item-a', 'item-b'],
			selectedItemId: null,
			page,
			observeWait: deadline.waitFor,
			readViewportState: async () => {
				owner.signal.throwIfAborted();
				readCount += 1;
				if (heldStage === 'viewport' && readCount === 2) {
					arrived.resolve();
					await held.promise;
				}
				owner.signal.throwIfAborted();
				return {
					codeScroll: { clientHeight: 100, scrollHeight: 200, scrollTop: 0 },
					visibleItems: [{ itemId: 'item-a', displayPath: 'file-a.ts' }],
				};
			},
			scroll: async () => {
				if (heldStage !== 'viewport') {
					arrived.resolve();
					await held.promise;
				}
				owner.signal.throwIfAborted();
				return { requestedScrollTop: 80 };
			},
		}).then(
			(): unknown => new Error('Collector unexpectedly succeeded'),
			(error: unknown): unknown => error,
		);
		try {
			await arrived.promise;
			owner.abort(new Error('controlled journey owner expiry'));
			held.resolve();
			const error = await collection;
			const evidence = bridgeViewerReviewPaintFailureEvidenceFromError(error);
			expect(evidence?.paintLedger[0]?.status).toBe('painted');
			expect(evidence?.paintLedger[0]?.publicationId).toBe('publication-a');
			expect(evidence?.paintLedger[0]?.targetSnapshot.itemInDom).toBe(true);
			expect(evidence?.pendingPaintItemId).toBe(heldStage === 'restore' ? null : 'item-b');
			if (heldStage !== 'restore') {
				expect(evidence?.paintLedger[1]?.status).toBe('targeted');
				expect(evidence?.paintLedger[1]?.targetSnapshot.captureError).toBe('snapshot-unavailable');
			}
			const checkpoint = await captureBridgeViewerProductOnlyJourneyFailure({
				browserDiagnostics: [],
				documentGeneration: 1,
				error,
				failedResponses: [],
				page,
				routeObserver: {
					flushResponseParsers: async (): Promise<void> => {},
					failureTransportSnapshot: () => ({
						entries: [],
						unfinishedRequestOrdinals: [],
						unresolvedWaiters: [],
					}),
				},
			});
			expect(closed).toBe(true);
			expect(checkpoint.captureStatus).toBe('captured');
			expect(checkpoint.review?.paintLedger).toEqual(evidence?.paintLedger);
			expect(checkpoint.review?.pendingPaintItemId).toBe(evidence?.pendingPaintItemId);
		} finally {
			held.resolve();
			await collection;
			await deadline.dispose();
		}
	},
);
