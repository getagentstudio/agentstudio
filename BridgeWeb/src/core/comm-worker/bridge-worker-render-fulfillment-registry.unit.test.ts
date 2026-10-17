import { describe, expect, test } from 'vitest';

import { readBridgeCommWorkerAbsoluteNowMilliseconds } from './bridge-comm-worker-clock.js';
import { buildBridgeWorkerPierreRenderJob } from './bridge-worker-pierre-render-job.js';
import type {
	BridgeWorkerDemandRank,
	BridgeWorkerPierreRenderJob,
} from './bridge-worker-pierre-render-job.js';
import {
	BridgeWorkerRenderFulfillmentRegistry,
	type BridgeWorkerRenderFulfillmentRegistryContext,
} from './bridge-worker-render-fulfillment-registry.js';
import { bridgeWorkerRenderReceiptTransitionSchema } from './bridge-worker-render-fulfillment.js';
import type {
	BridgeWorkerRenderDisposition,
	BridgeWorkerRenderDispositionReceipt,
	BridgeWorkerRenderReceiptIdentity,
} from './bridge-worker-render-fulfillment.js';

const reviewContext: BridgeWorkerRenderFulfillmentRegistryContext = {
	paneSessionId: 'pane-session-1',
	surface: 'review',
	workerInstanceId: 'worker-instance-1',
};

describe('Bridge worker render fulfillment registry', () => {
	test('File rejects held receipts before any File operation can settle from them', () => {
		const registry = createRegistry({ ...reviewContext, surface: 'file' });
		const publication = registry.beginPublication({
			job: makeRenderJob('file-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'held', 1)).status,
		).toBe('rejected');
		expect(registry.getItemState('file-item')?.stage).toBe('published');
	});
	test('held receipts are identity fenced, duplicate inert, and cannot regress queued or terminal work', () => {
		const registry = createRegistry(reviewContext);
		const publication = registry.beginPublication({
			job: makeRenderJob('held-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const held = disposition(publication.receiptIdentity, 'held', 1);
		expect(registry.applyDisposition(held).status).toBe('accepted');
		expect(registry.applyDisposition(held).status).toBe('duplicate');
		expect(registry.applyDisposition({ ...held, workerDerivationEpoch: 2 }).status).toBe(
			'rejected',
		);
		expect(registry.applyDisposition({ ...held, attemptId: 'foreign-attempt' }).status).toBe(
			'rejected',
		);
		registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 2));
		expect(registry.applyDisposition(held).status).toBe('duplicate');
		expect(registry.getItemState('held-item')?.stage).toBe('queued');
		registry.applyDisposition(disposition(publication.receiptIdentity, 'applied', 3));
		registry.applyDisposition(disposition(publication.receiptIdentity, 'painted', 4));
		expect(registry.applyDisposition(held).status).toBe('rejected');
		registry.resetPublications();
		registry.beginPublication({
			job: makeRenderJob('held-item'),
			publicationSequence: 9,
			workerDerivationEpoch: 4,
		});
		expect(registry.applyDisposition(held).status).toBe('rejected');
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 5)).status,
		).toBe('rejected');
	});

	test('source churn preserves an exact held attempt and removal fences its late receipts', () => {
		const registry = createRegistry(reviewContext);
		const job = makeRenderJob('held-item');
		const publication = registry.beginPublication({
			job,
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		registry.applyDisposition(disposition(publication.receiptIdentity, 'held', 1));
		expect(registry.requeuePublicationsForSourceChurn(2)).toEqual([]);
		expect(
			registry.beginPublication({ job, publicationSequence: 9, workerDerivationEpoch: 3 })
				.shouldPublish,
		).toBe(false);
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
		registry.retireRemovedItemsForSourceChurn(['held-item']);
		expect(registry.getItemState('held-item')).toBeNull();
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 3)).status,
		).toBe('rejected');
	});

	test('held and queued receipts and unchanged source churn do not renew a missing-delivery probe', () => {
		let nowMilliseconds = 0;
		const registry = createRegistry(reviewContext, (): number => nowMilliseconds);
		const job = makeRenderJob('held-item');
		registry.beginPublication({ job, publicationSequence: 8, workerDerivationEpoch: 3 });
		nowMilliseconds = 100;
		registry.expireReceiptLeases();
		nowMilliseconds = 105;
		registry.releaseReadyRetries();
		const retry = registry.beginPublication({
			job,
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});
		registry.applyDisposition(disposition(retry.receiptIdentity, 'held', 106));
		registry.requeuePublicationsForSourceChurn(107);
		registry.updateVisibleItemIds(['held-item']);
		registry.applyDisposition(disposition(retry.receiptIdentity, 'queued', 108));
		nowMilliseconds = 205;
		expect(registry.expireVisibleQueuedLeases()).toEqual({
			exhaustedItemIds: ['held-item'],
			retryableItemIds: [],
		});
		expect(registry.getItemState('held-item')?.stage).toBe('failed');
		expect(registry.releaseReadyRetries()).toEqual([]);
	});
	test('releases only the current painted receipt back to desired', () => {
		const registry = createRegistry(reviewContext);
		const publication = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		for (const [index, stage] of (['queued', 'applied', 'painted'] as const).entries()) {
			registry.applyDisposition(disposition(publication.receiptIdentity, stage, index + 1));
		}
		const release = {
			...publication.receiptIdentity,
			kind: 'paint.released',
			receivedAtMilliseconds: 4,
		} as const;
		expect(bridgeWorkerRenderReceiptTransitionSchema.safeParse(release).success).toBe(true);
		expect(registry.applyPaintRelease(release)).toMatchObject({ status: 'accepted' });
		expect(registry.getItemState('review-item-1')).toMatchObject({
			stage: 'desired',
			paintedResidency: null,
		});
		expect(registry.applyPaintRelease(release)).toMatchObject({
			status: 'rejected',
			reason: 'already_terminal',
		});
		const replacement = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});
		expect(replacement.shouldPublish).toBe(true);
		expect(registry.applyPaintRelease(release)).toMatchObject({
			status: 'rejected',
			reason: 'stale_submission',
		});
	});
	test('requires a strictly positive receipt lease before publication can become reachable', () => {
		expect(
			() =>
				new BridgeWorkerRenderFulfillmentRegistry({
					context: reviewContext,
					receiptLeaseDurationMilliseconds: 0,
					retryBackoffMilliseconds: 5,
				}),
		).toThrow('Bridge render receipt lease duration must be finite and positive.');
	});

	test('compares receipt leases and retries across different realm time origins', () => {
		// Arrange
		let workerNowMilliseconds = readBridgeCommWorkerAbsoluteNowMilliseconds({
			now: (): number => 100,
			timeOrigin: 1_000,
		});
		const registry = createRegistry(reviewContext, (): number => workerNowMilliseconds);
		const publication = registry.beginPublication({
			job: makeRenderJob('replacement-worker-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const mainReceivedAtMilliseconds = readBridgeCommWorkerAbsoluteNowMilliseconds({
			now: (): number => 220,
			timeOrigin: 900,
		});

		// Act
		const result = registry.applyDisposition(
			disposition(publication.receiptIdentity, 'rejected', mainReceivedAtMilliseconds),
		);
		workerNowMilliseconds = mainReceivedAtMilliseconds + 4;
		const beforeRetry = registry.releaseReadyRetries();
		workerNowMilliseconds = mainReceivedAtMilliseconds + 5;
		const atRetry = registry.releaseReadyRetries();

		// Assert
		expect(result).toMatchObject({ status: 'accepted' });
		expect(beforeRetry).toEqual([]);
		expect(atRetry).toEqual(['replacement-worker-item']);
	});

	test('mints one full publication identity and fulfills only after painted', () => {
		const identifiers = createIdentifierSequence();
		const registry = new BridgeWorkerRenderFulfillmentRegistry({
			context: reviewContext,
			createIdentifier: identifiers.create,
			now: (): number => 10,
			receiptLeaseDurationMilliseconds: 100,
			retryBackoffMilliseconds: 5,
		});

		const publication = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});

		expect(publication.status).toBe('published');
		expect(publication.shouldPublish).toBe(true);
		expect(publication.receiptIdentity).toEqual({
			attemptId: 'attempt-1',
			itemId: 'review-item-1',
			operationCorrelationId: null,
			paneSessionId: 'pane-session-1',
			publicationId: 'publication-1',
			publicationSequence: 8,
			submissionId: 'submission-1',
			surface: 'review',
			windowKey: expect.stringContaining('bridge-render-window-v1'),
			workerDerivationEpoch: 3,
			workerInstanceId: 'worker-instance-1',
		});
		expect(registry.getItemState('review-item-1')?.isDesired).toBe(true);

		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 11)),
		).toEqual(expect.objectContaining({ status: 'accepted' }));
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'applied', 12)),
		).toEqual(expect.objectContaining({ status: 'accepted' }));
		expect(registry.getItemState('review-item-1')?.isDesired).toBe(true);
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'painted', 13)),
		).toEqual(expect.objectContaining({ status: 'accepted' }));
		expect(registry.getItemState('review-item-1')?.isDesired).toBe(false);
		expect(registry.getItemState('review-item-1')?.stage).toBe('painted');
	});

	test('coalesces one semantic publication and treats matching receipts idempotently', () => {
		const registry = createRegistry(reviewContext);
		const first = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const duplicate = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});

		expect(duplicate).toMatchObject({
			receiptIdentity: first.receiptIdentity,
			shouldPublish: false,
			status: 'duplicate',
		});
		const queuedReceipt = disposition(first.receiptIdentity, 'queued', 1);
		const accepted = registry.applyDisposition(queuedReceipt);
		const repeated = registry.applyDisposition(queuedReceipt);
		expect(accepted.status).toBe('accepted');
		expect(repeated.status).toBe('duplicate');
		expect(repeated.state).toBe(accepted.state);
	});

	test('ends the delivery lease after queued while preserving later paint settlement', () => {
		// Arrange
		let nowMilliseconds = 0;
		const registry = createRegistry(reviewContext, (): number => nowMilliseconds);
		const publication = registry.beginPublication({
			job: makeRenderJob('offscreen-review-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});

		// Act
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 1)),
		).toMatchObject({ status: 'accepted' });
		nowMilliseconds = 100;

		// Assert
		expect(registry.expireReceiptLeases()).toEqual([]);
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
		expect(registry.getItemState('offscreen-review-item')).toMatchObject({
			isDesired: true,
			stage: 'queued',
		});
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'applied', 101)),
		).toMatchObject({ status: 'accepted' });
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'painted', 102)),
		).toMatchObject({ status: 'accepted' });
		expect(registry.getItemState('offscreen-review-item')).toMatchObject({
			isDesired: false,
			stage: 'painted',
		});
	});

	test('leases an in-window queued Review publication, retries once, then reports exhaustion', () => {
		let nowMilliseconds = 0;
		const registry = createRegistry(reviewContext, (): number => nowMilliseconds);
		const first = registry.beginPublication({
			job: makeRenderJob('visible-review-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		registry.applyDisposition(disposition(first.receiptIdentity, 'queued', 1));
		registry.updateVisibleItemIds(['visible-review-item']);
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBe(100);
		nowMilliseconds = 100;
		expect(registry.expireVisibleQueuedLeases()).toEqual({
			exhaustedItemIds: [],
			retryableItemIds: ['visible-review-item'],
		});
		expect(registry.getItemState('visible-review-item')?.stage).toBe('retry_wait');
		nowMilliseconds = 105;
		expect(registry.releaseReadyRetries()).toEqual(['visible-review-item']);
		const retry = registry.beginPublication({
			job: makeRenderJob('visible-review-item'),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});
		expect(retry.shouldPublish).toBe(true);
		registry.applyDisposition(disposition(retry.receiptIdentity, 'queued', 106));
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBe(205);
		nowMilliseconds = 205;
		expect(registry.expireVisibleQueuedLeases()).toEqual({
			exhaustedItemIds: ['visible-review-item'],
			retryableItemIds: [],
		});
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
		const retained = registry.beginPublication({
			job: makeRenderJob('unrelated-review-item'),
			publicationSequence: 10,
			workerDerivationEpoch: 3,
		});
		expect(registry.retryExhaustedPublications()).toEqual(['visible-review-item']);
		expect(registry.getItemState('unrelated-review-item')).toBe(retained.state);
		expect(registry.getItemState('visible-review-item')).toBeNull();
		expect(registry.retryExhaustedPublications()).toEqual([]);
		expect(
			registry.applyDisposition(disposition(retry.receiptIdentity, 'queued', 206)),
		).toMatchObject({
			status: 'rejected',
		});
	});

	test('keeps an out-of-window queued Review publication dormant and clears a lease on exit', () => {
		let nowMilliseconds = 0;
		const registry = createRegistry(reviewContext, (): number => nowMilliseconds);
		const publication = registry.beginPublication({
			job: makeRenderJob('virtualized-review-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 1));
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
		registry.updateVisibleItemIds(['virtualized-review-item']);
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBe(100);
		registry.updateVisibleItemIds([]);
		nowMilliseconds = 200;
		expect(registry.nextLifecycleWakeAtMilliseconds()).toBeNull();
		expect(registry.expireVisibleQueuedLeases()).toEqual({
			exhaustedItemIds: [],
			retryableItemIds: [],
		});
		expect(registry.getItemState('virtualized-review-item')?.stage).toBe('queued');
	});

	test('retires publication residency before the same semantic window is republished', () => {
		// Arrange
		const registry = createRegistry(reviewContext);
		const first = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		expect(first.shouldPublish).toBe(true);

		// Act
		registry.resetPublications();
		const replacement = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});

		// Assert
		expect(replacement).toMatchObject({ shouldPublish: true, status: 'published' });
		expect(replacement.receiptIdentity.publicationId).not.toBe(first.receiptIdentity.publicationId);
		expect(
			registry.applyDisposition(disposition(first.receiptIdentity, 'queued', 1)),
		).toMatchObject({ status: 'rejected' });
	});

	test('retains an active source-churn attempt until its first disposition or existing lease expiry', () => {
		// Arrange
		const registry = createRegistry(reviewContext);
		const first = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});

		// Act
		const requeuedItemIds = registry.requeuePublicationsForSourceChurn(1);
		const expiredItemIds = registry.expireReceiptLeases(99);
		const nextWakeAtMilliseconds = registry.nextLifecycleWakeAtMilliseconds();
		const queuedResult = registry.applyDisposition(
			disposition(first.receiptIdentity, 'queued', 99),
		);
		const replacement = registry.beginPublication({
			job: makeRenderJob('review-item-1', { lane: 'visible', priority: 1 }, 'b'.repeat(64)),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});

		// Assert
		expect(requeuedItemIds).toEqual([]);
		expect(expiredItemIds).toEqual([]);
		expect(nextWakeAtMilliseconds).toBe(100);
		expect(queuedResult).toMatchObject({ status: 'accepted' });
		expect(replacement).toMatchObject({ shouldPublish: true, status: 'published' });
		expect(replacement.receiptIdentity.publicationId).not.toBe(first.receiptIdentity.publicationId);
	});

	test('a changed selected item can publish its new content after the old first disposition is lost', () => {
		let nowMilliseconds = 0;
		const registry = createRegistry(reviewContext, (): number => nowMilliseconds);
		const oldPublication = registry.beginPublication({
			job: makeRenderJob('selected-item', { lane: 'selected', priority: 0 }, 'a'.repeat(64)),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		expect(oldPublication.shouldPublish).toBe(true);
		registry.requeuePublicationsForSourceChurn();

		// The old main-thread reply is lost. The existing render lease is the progress boundary.
		nowMilliseconds = 100;
		expect(registry.expireReceiptLeases()).toEqual(['selected-item']);
		nowMilliseconds = 105;
		expect(registry.releaseReadyRetries()).toEqual(['selected-item']);
		const replacement = registry.beginPublication({
			job: makeRenderJob('selected-item', { lane: 'selected', priority: 0 }, 'b'.repeat(64)),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});
		expect(replacement).toMatchObject({ shouldPublish: true, status: 'published' });
		expect(replacement.receiptIdentity.attemptId).not.toBe(
			oldPublication.receiptIdentity.attemptId,
		);
		expect(
			registry.applyDisposition(disposition(oldPublication.receiptIdentity, 'queued', 105)),
		).toMatchObject({ status: 'rejected' });
		expect(
			registry.applyDisposition(disposition(replacement.receiptIdentity, 'queued', 106)),
		).toMatchObject({ status: 'accepted' });
		expect(
			registry.applyDisposition(disposition(replacement.receiptIdentity, 'applied', 107)),
		).toMatchObject({ status: 'accepted' });
		expect(
			registry.applyDisposition(disposition(replacement.receiptIdentity, 'painted', 108)),
		).toMatchObject({ status: 'accepted' });
		expect(registry.getItemState('selected-item')?.stage).toBe('painted');
	});

	test('retires a removed item immediately after its outstanding first disposition', () => {
		const registry = createRegistry(reviewContext);
		const publication = registry.beginPublication({
			job: makeRenderJob('removed-review-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});

		registry.retireRemovedItemsForSourceChurn(['removed-review-item']);
		expect(registry.getItemState('removed-review-item')).not.toBeNull();
		expect(
			registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 1)),
		).toMatchObject({ status: 'accepted' });

		expect(registry.getItemState('removed-review-item')).toBeNull();
	});

	test('revalidates exact painted content across source churn without republication', () => {
		// Arrange
		const registry = createRegistry(reviewContext);
		const first = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		registry.applyDisposition(disposition(first.receiptIdentity, 'queued', 1));
		registry.applyDisposition(disposition(first.receiptIdentity, 'applied', 2));
		registry.applyDisposition(disposition(first.receiptIdentity, 'painted', 3));

		// Act
		const requeuedItemIds = registry.requeuePublicationsForSourceChurn(4);
		const revalidationState = registry.getItemState('review-item-1');
		const replacement = registry.beginPublication({
			job: makeRenderJob('review-item-1', { lane: 'background', priority: 1 }),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});

		// Assert
		expect(requeuedItemIds).toEqual(['review-item-1']);
		expect(revalidationState).toMatchObject({
			isDesired: true,
			paintedResidency: first.receiptIdentity,
			stage: 'desired',
		});
		expect(replacement).toMatchObject({
			receiptIdentity: first.receiptIdentity,
			shouldPublish: false,
			status: 'duplicate',
		});
		expect(registry.getItemState('review-item-1')).toMatchObject({
			isDesired: false,
			stage: 'painted',
		});
	});

	test('publishes changed semantic content after source revalidation', () => {
		// Arrange
		const registry = createRegistry(reviewContext);
		const first = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		registry.applyDisposition(disposition(first.receiptIdentity, 'queued', 1));
		registry.applyDisposition(disposition(first.receiptIdentity, 'applied', 2));
		registry.applyDisposition(disposition(first.receiptIdentity, 'painted', 3));

		// Act
		registry.requeuePublicationsForSourceChurn(4);
		const replacement = registry.beginPublication({
			job: makeRenderJob('review-item-1', { lane: 'visible', priority: 1 }, 'b'.repeat(64)),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});

		// Assert
		expect(replacement).toMatchObject({ shouldPublish: true, status: 'published' });
		expect(replacement.receiptIdentity.publicationId).not.toBe(first.receiptIdentity.publicationId);
	});

	test('replaces same-window publication authority when the surface derivation epoch advances', () => {
		const registry = createRegistry(reviewContext);
		const first = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const replacement = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 9,
			workerDerivationEpoch: 4,
		});

		expect(replacement).toMatchObject({ shouldPublish: true, status: 'published' });
		expect(replacement.receiptIdentity).toMatchObject({
			publicationSequence: 9,
			workerDerivationEpoch: 4,
		});
		expect(replacement.receiptIdentity.publicationId).not.toBe(first.receiptIdentity.publicationId);
		expect(
			registry.applyDisposition(disposition(first.receiptIdentity, 'queued', 1)),
		).toMatchObject({ status: 'rejected' });
		expect(registry.getItemState('review-item-1')?.stage).toBe('published');
	});

	test('rejects stale, foreign, out-of-order and conflicting receipts without mutation', () => {
		const registry = createRegistry(reviewContext);
		const publication = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const initial = registry.getItemState('review-item-1');

		for (const receipt of [
			disposition(publication.receiptIdentity, 'applied', 1),
			disposition({ ...publication.receiptIdentity, attemptId: 'attempt-foreign' }, 'queued', 1),
			disposition({ ...publication.receiptIdentity, paneSessionId: 'pane-foreign' }, 'queued', 1),
			disposition({ ...publication.receiptIdentity, windowKey: 'window-foreign' }, 'queued', 1),
		]) {
			expect(registry.applyDisposition(receipt)).toMatchObject({ status: 'rejected' });
			expect(registry.getItemState('review-item-1')).toBe(initial);
		}

		registry.applyDisposition(disposition(publication.receiptIdentity, 'queued', 2));
		registry.applyDisposition(disposition(publication.receiptIdentity, 'applied', 3));
		registry.applyDisposition(disposition(publication.receiptIdentity, 'painted', 4));
		const painted = registry.getItemState('review-item-1');
		expect(
			registry.applyDisposition(
				terminalDisposition(publication.receiptIdentity, 'rejected', 4, 'already_terminal'),
			),
		).toMatchObject({ status: 'rejected' });
		expect(registry.getItemState('review-item-1')).toBe(painted);
	});

	test('does not convert an internal receipt-parser failure into a recoverable rejection', () => {
		const registry = createRegistry(reviewContext);
		const publication = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const invalidReceipt = {
			...disposition(publication.receiptIdentity, 'queued', 1),
			receivedAtMilliseconds: Number.NaN,
		} satisfies BridgeWorkerRenderDispositionReceipt;

		expect(() => registry.applyDisposition(invalidReceipt)).toThrow();
		expect(registry.getItemState('review-item-1')?.stage).toBe('published');
	});

	test.each(['rejected', 'superseded'] as const)(
		'keeps desired demand through %s and republishes with a new attempt only',
		(dispositionKind) => {
			let now = 0;
			const registry = createRegistry(reviewContext, (): number => now);
			const first = registry.beginPublication({
				job: makeRenderJob('review-item-1'),
				publicationSequence: 8,
				workerDerivationEpoch: 3,
			});
			registry.applyDisposition(
				terminalDisposition(first.receiptIdentity, dispositionKind, now, 'stale_attempt'),
			);

			expect(registry.getItemState('review-item-1')).toMatchObject({
				isDesired: true,
				stage: 'retry_wait',
			});
			now = 5;
			expect(registry.releaseReadyRetries()).toEqual(['review-item-1']);
			const retry = registry.beginPublication({
				job: makeRenderJob('review-item-1'),
				publicationSequence: 99,
				workerDerivationEpoch: 3,
			});
			expect(retry).toMatchObject({ shouldPublish: true, status: 'published' });
			expect(retry.receiptIdentity.attemptId).not.toBe(first.receiptIdentity.attemptId);
			expect(retry.receiptIdentity.publicationId).toBe(first.receiptIdentity.publicationId);
			expect(retry.receiptIdentity.submissionId).toBe(first.receiptIdentity.submissionId);
			expect(retry.receiptIdentity.publicationSequence).toBe(
				first.receiptIdentity.publicationSequence,
			);
		},
	);

	test('keeps desired demand through lease expiry and bounded retry release', () => {
		let now = 0;
		const registry = createRegistry(reviewContext, (): number => now);
		const publication = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});

		now = 100;
		expect(registry.expireReceiptLeases()).toEqual(['review-item-1']);
		expect(registry.getItemState('review-item-1')).toMatchObject({
			isDesired: true,
			retryAtMilliseconds: 105,
			stage: 'retry_wait',
		});
		now = 104;
		expect(registry.releaseReadyRetries()).toEqual([]);
		now = 105;
		expect(registry.releaseReadyRetries()).toEqual(['review-item-1']);
		const retry = registry.beginPublication({
			job: makeRenderJob('review-item-1'),
			publicationSequence: 9,
			workerDerivationEpoch: 3,
		});
		expect(retry.receiptIdentity.attemptId).not.toBe(publication.receiptIdentity.attemptId);
	});

	test('isolates identical File and Review item ids in separate surface registries', () => {
		const reviewRegistry = createRegistry(reviewContext);
		const fileRegistry = createRegistry({ ...reviewContext, surface: 'file' });
		const reviewPublication = reviewRegistry.beginPublication({
			job: makeRenderJob('shared-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});
		const filePublication = fileRegistry.beginPublication({
			job: makeRenderJob('shared-item'),
			publicationSequence: 8,
			workerDerivationEpoch: 3,
		});

		expect(
			fileRegistry.applyDisposition(disposition(reviewPublication.receiptIdentity, 'queued', 1)),
		).toMatchObject({ status: 'rejected' });
		expect(reviewRegistry.getItemState('shared-item')?.stage).toBe('published');
		expect(fileRegistry.getItemState('shared-item')?.stage).toBe('published');
		expect(filePublication.receiptIdentity.surface).toBe('file');
	});
});

function createRegistry(
	context: BridgeWorkerRenderFulfillmentRegistryContext,
	now: () => number = (): number => 0,
): BridgeWorkerRenderFulfillmentRegistry {
	return new BridgeWorkerRenderFulfillmentRegistry({
		context,
		createIdentifier: createIdentifierSequence().create,
		now,
		receiptLeaseDurationMilliseconds: 100,
		retryBackoffMilliseconds: 5,
	});
}

function createIdentifierSequence(): {
	readonly create: (purpose: 'attempt' | 'publication' | 'submission') => string;
} {
	const nextByPurpose = { attempt: 0, publication: 0, submission: 0 };
	return {
		create: (purpose): string => {
			nextByPurpose[purpose] += 1;
			return `${purpose}-${nextByPurpose[purpose]}`;
		},
	};
}

function makeRenderJob(
	itemId: string,
	bridgeDemandRank: BridgeWorkerDemandRank = { lane: 'visible', priority: 1 },
	contentHash: string = 'a'.repeat(64),
): BridgeWorkerPierreRenderJob {
	return buildBridgeWorkerPierreRenderJob({
		bridgeDemandRank,
		budget: {
			className: bridgeDemandRank.lane === 'visible' ? 'visible' : 'background',
			maxBytes: 1024,
			maxWindowLines: 4,
		},
		contentCacheKey: `cache-${itemId}`,
		contentHash,
		itemId,
		language: 'text',
		payload: {
			kind: 'codeViewFileItem',
			item: {
				bridgeMetadata: {
					cacheKey: `cache-${itemId}`,
					contentRoles: ['file'],
					contentState: 'hydrated',
					displayPath: `${itemId}.txt`,
					itemId,
					lineCount: 1,
				},
				file: { cacheKey: `cache-${itemId}`, contents: 'content', name: `${itemId}.txt` },
				id: itemId,
				type: 'file',
			},
		},
		renderKind: 'fileText',
		window: { endLine: 1, startLine: 1, totalLineCount: 1 },
	});
}

function disposition(
	identity: BridgeWorkerRenderReceiptIdentity,
	dispositionValue: BridgeWorkerRenderDisposition,
	receivedAtMilliseconds: number,
): BridgeWorkerRenderDispositionReceipt {
	if (dispositionValue === 'rejected' || dispositionValue === 'superseded') {
		return {
			...identity,
			disposition: dispositionValue,
			kind: 'render.disposition',
			reason: 'stale_attempt',
			receivedAtMilliseconds,
			retryAtMilliseconds: receivedAtMilliseconds + 5,
		};
	}
	return {
		...identity,
		disposition: dispositionValue,
		kind: 'render.disposition',
		receivedAtMilliseconds,
	};
}

function terminalDisposition(
	identity: BridgeWorkerRenderReceiptIdentity,
	dispositionValue: 'rejected' | 'superseded',
	receivedAtMilliseconds: number,
	reason: 'already_terminal' | 'stale_attempt',
): BridgeWorkerRenderDispositionReceipt {
	return {
		...identity,
		disposition: dispositionValue,
		kind: 'render.disposition',
		reason,
		receivedAtMilliseconds,
		retryAtMilliseconds: receivedAtMilliseconds + 5,
	};
}
