import { describe, expect, test, vi } from 'vitest';

import { applyBridgeCommWorkerPostResponseOwnerEffects } from './bridge-comm-worker-post-response-owner-effects.js';
import type { BridgeWorkerRenderDispositionApplicationReceiptResult } from './bridge-comm-worker-render-disposition-application.js';
import type { BridgeWorkerRenderDispositionReceipt } from './bridge-worker-render-fulfillment.js';
import { makeBridgeWorkerRenderReceiptIdentity } from './bridge-worker-render-fulfillment.test-support.js';

describe('Bridge comm worker post-response owner effects', () => {
	test('routes an accepted paint release to Review readmission without a disposition release', () => {
		const identity = makeBridgeWorkerRenderReceiptIdentity({
			itemId: 'review-item-1',
			publicationSequence: 2,
			surface: 'review',
			workerDerivationEpoch: 7,
		});
		const release = { ...identity, kind: 'paint.released', receivedAtMilliseconds: 10 } as const;
		const readmitReviewPaintRelease = vi.fn();
		const releaseReviewPosition = vi.fn();
		applyBridgeCommWorkerPostResponseOwnerEffects({
			advanceRenderFulfillmentLifecycle: vi.fn(),
			currentFileOperationCorrelationId: (): null => null,
			onFileOperationSettled: (): void => {},
			publish: (): void => {},
			readmitReviewPaintRelease,
			receiptResults: [{ receipt: release, status: 'accepted' }],
			recordFileDisposition: (): void => {},
			releaseReviewPosition,
			settleFileDisposition: () => ({ settled: false, terminalPatch: null }),
		});
		expect(readmitReviewPaintRelease).toHaveBeenCalledWith(release);
		expect(releaseReviewPosition).not.toHaveBeenCalled();
	});
	test('applies owner effects only for accepted or idempotent receipt results', () => {
		// Arrange
		const acceptedReceipt = makeQueuedReceipt('accepted-item', 1);
		const duplicateReceipt = makeQueuedReceipt('duplicate-item', 2);
		const rejectedReceipt = makeQueuedReceipt('rejected-item', 3);
		const releaseReviewPosition = vi.fn(
			(_receipt: BridgeWorkerRenderDispositionReceipt): boolean => true,
		);
		const advanceRenderFulfillmentLifecycle = vi.fn();
		const receiptResults = [
			{ receipt: acceptedReceipt, status: 'accepted' },
			{ receipt: duplicateReceipt, status: 'duplicate' },
			{ receipt: rejectedReceipt, status: 'rejected' },
		] satisfies readonly BridgeWorkerRenderDispositionApplicationReceiptResult[];

		// Act
		applyBridgeCommWorkerPostResponseOwnerEffects({
			advanceRenderFulfillmentLifecycle,
			currentFileOperationCorrelationId: (): null => null,
			onFileOperationSettled: (): void => {},
			publish: (): void => {},
			readmitReviewPaintRelease: (): void => {},
			receiptResults,
			recordFileDisposition: (): void => {},
			releaseReviewPosition,
			settleFileDisposition: () => ({ settled: false, terminalPatch: null }),
		});

		// Assert
		expect(releaseReviewPosition.mock.calls.map(([receipt]) => receipt.itemId)).toEqual([
			'accepted-item',
			'duplicate-item',
		]);
		expect(advanceRenderFulfillmentLifecycle).toHaveBeenCalledOnce();
		expect(advanceRenderFulfillmentLifecycle).toHaveBeenCalledWith('review');
	});
});

function makeQueuedReceipt(
	itemId: string,
	publicationSequence: number,
): BridgeWorkerRenderDispositionReceipt {
	return {
		...makeBridgeWorkerRenderReceiptIdentity({
			itemId,
			publicationSequence,
			surface: 'review',
			workerDerivationEpoch: 1,
		}),
		disposition: 'queued',
		kind: 'render.disposition',
		receivedAtMilliseconds: 1,
	};
}
