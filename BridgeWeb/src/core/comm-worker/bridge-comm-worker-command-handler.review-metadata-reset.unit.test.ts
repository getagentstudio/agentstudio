import { describe, expect, test } from 'vitest';

import { makeBridgeReviewItem } from '../../foundation/review-package/bridge-review-package-test-support.js';
import { reviewMetadataApplication } from './bridge-comm-worker-command-handler-review.test-support.js';
import { createBridgeCommWorkerCommandHandler } from './bridge-comm-worker-command-handler.js';
import {
	ignoreScheduledSelectedFileViewPreparation,
	pushScheduledSelectedReviewPreparation,
	type ScheduledSelectedReviewPreparation,
} from './bridge-comm-worker-command-handler.test-support.js';
import {
	encodeBridgeWorkerReviewInvalidateCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import { makeReviewPublication } from './bridge-main-render-fulfillment-coordinator.test-support.js';
import type { BridgeWorkerReviewContentMetadata } from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';

describe('Bridge comm worker Review metadata reset', () => {
	test('missing first receipts consume one probe across attempts and end at view failure until Retry', () => {
		let nowMilliseconds = 0;
		const exhaustedItemIds: string[][] = [];
		const scheduledPreparations: ScheduledSelectedReviewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [makeWorkerReviewContentMetadata('missing-receipt')],
			rows: [{ id: 'missing-receipt', parentId: null, index: 0 }],
			now: (): number => nowMilliseconds,
			renderReceiptLeaseDurationMilliseconds: 10,
			renderRetryBackoffMilliseconds: 5,
			onReviewVisibleRenderExhausted: (itemIds): void => {
				exhaustedItemIds.push([...itemIds]);
			},
			scheduleSelectedReviewContentReadyPreparation:
				pushScheduledSelectedReviewPreparation(scheduledPreparations),
			scheduleSelectedFileViewContentReadyPreparation: ignoreScheduledSelectedFileViewPreparation,
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 7,
				requestId: 'select-missing-receipt',
				selectedItemId: 'missing-receipt',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		const store = scheduledPreparations[0]?.store;
		if (store === undefined) throw new Error('Expected the demanded Review store.');
		const job = makeReviewPublication({ itemId: 'missing-receipt', publicationSequence: 1 }).job;
		store.renderFulfillmentRegistry.beginPublication({
			job,
			publicationSequence: 1,
			workerDerivationEpoch: 1,
		});
		nowMilliseconds = 10;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		nowMilliseconds = 15;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(
			store.renderFulfillmentRegistry.beginPublication({
				job,
				publicationSequence: 2,
				workerDerivationEpoch: 1,
			}).shouldPublish,
		).toBe(true);
		nowMilliseconds = 25;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(exhaustedItemIds).toEqual([['missing-receipt']]);
		const preparationCount = scheduledPreparations.length;
		for (const nextTime of [100, 1_000, 10_000]) {
			nowMilliseconds = nextTime;
			expect(
				handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds).nextWakeAtMilliseconds,
			).toBeNull();
			expect(
				store.renderFulfillmentRegistry.beginPublication({
					job,
					publicationSequence: 3,
					workerDerivationEpoch: 1,
				}).shouldPublish,
			).toBe(false);
		}
		expect(scheduledPreparations).toHaveLength(preparationCount);
		expect(exhaustedItemIds).toHaveLength(1);
	});
	test('the viewport arms a queued render lease and exhaustion reaches only the Review recovery owner', () => {
		const itemId = 'visible-queued-review-item';
		let nowMilliseconds = 0;
		const exhaustedItemIds: string[][] = [];
		const scheduledPreparations: ScheduledSelectedReviewPreparation[] = [];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [makeWorkerReviewContentMetadata(itemId)],
			now: (): number => nowMilliseconds,
			renderReceiptLeaseDurationMilliseconds: 10,
			renderRetryBackoffMilliseconds: 5,
			onReviewVisibleRenderExhausted: (itemIds): void => {
				exhaustedItemIds.push([...itemIds]);
			},
			rows: [{ id: itemId, parentId: null, index: 0 }],
			scheduleSelectedReviewContentReadyPreparation:
				pushScheduledSelectedReviewPreparation(scheduledPreparations),
			scheduleSelectedFileViewContentReadyPreparation: ignoreScheduledSelectedFileViewPreparation,
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 7,
				requestId: 'select-visible-queued',
				selectedItemId: itemId,
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		const store = scheduledPreparations[0]?.store;
		if (store === undefined) throw new Error('Expected the selected Review store.');
		handler.handleMessage(
			encodeBridgeWorkerViewportCommand({
				epoch: 7,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'viewport-visible-queued',
				surface: 'review',
				visibleItemIds: [itemId],
			}),
		);
		const renderJob = makeReviewPublication({ itemId, publicationSequence: 1 }).job;
		const first = store.renderFulfillmentRegistry.beginPublication({
			job: renderJob,
			publicationSequence: 1,
			workerDerivationEpoch: 1,
		});
		store.renderFulfillmentRegistry.applyDisposition(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...first.receiptIdentity,
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 0,
			}),
		);
		nowMilliseconds = 10;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(exhaustedItemIds).toEqual([]);
		nowMilliseconds = 15;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(scheduledPreparations.length).toBeGreaterThan(1);
		const retry = store.renderFulfillmentRegistry.beginPublication({
			job: renderJob,
			publicationSequence: 2,
			workerDerivationEpoch: 1,
		});
		store.renderFulfillmentRegistry.applyDisposition(
			bridgeWorkerRenderDispositionReceiptSchema.parse({
				...retry.receiptIdentity,
				disposition: 'queued',
				kind: 'render.disposition',
				receivedAtMilliseconds: 15,
			}),
		);
		nowMilliseconds = 25;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(exhaustedItemIds).toEqual([[itemId]]);
	});

	test('releases a selected render retry with the invalidated demand epoch', () => {
		// Arrange
		const itemId = 'item-invalidated-retry';
		const scheduledPreparations: ScheduledSelectedReviewPreparation[] = [];
		let nowMilliseconds = 0;
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems: [makeWorkerReviewContentMetadata(itemId)],
			now: (): number => nowMilliseconds,
			renderReceiptLeaseDurationMilliseconds: 10,
			renderRetryBackoffMilliseconds: 5,
			rows: [{ id: itemId, parentId: null, index: 0 }],
			scheduleSelectedReviewContentReadyPreparation:
				pushScheduledSelectedReviewPreparation(scheduledPreparations),
			scheduleSelectedFileViewContentReadyPreparation: ignoreScheduledSelectedFileViewPreparation,
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 7,
				requestId: 'request-select-before-invalidated-retry',
				selectedItemId: itemId,
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		const reviewStore = scheduledPreparations[0]?.store;
		if (reviewStore === undefined) throw new Error('expected selected Review store');
		reviewStore.renderFulfillmentRegistry.beginPublication({
			job: makeReviewPublication({ itemId, publicationSequence: 1 }).job,
			publicationSequence: 1,
			workerDerivationEpoch: 1,
		});
		nowMilliseconds = 10;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		handler.handleMessage(
			encodeBridgeWorkerReviewInvalidateCommand({
				epoch: 8,
				itemIds: [itemId],
				pathHints: [],
				reason: 'watchEvent',
				requestId: 'request-invalidate-before-retry-release',
				scope: 'items',
			}),
		);
		expect(reviewStore.getState()).toMatchObject({ selectedEpoch: 7 });
		expect(reviewStore.getState().demandByKey.get(itemId)).toBe('selected:8');

		// Act
		nowMilliseconds = 15;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);

		// Assert
		expect(scheduledPreparations).toHaveLength(3);
		expect(scheduledPreparations.at(-1)).toMatchObject({ epoch: 8, itemId });
	});

	test('retains active render attempts through reset commit with a bounded receipt lease', () => {
		// Arrange
		const itemId = 'item-generation-refresh';
		const scheduledPreparations: ScheduledSelectedReviewPreparation[] = [];
		let reviewStore: ScheduledSelectedReviewPreparation['store'] | null = null;
		let resetScheduledWithBoundedLease = false;
		let nowMilliseconds = 0;
		const expiredPublicationItemIds: string[] = [];
		const contentItems = [makeWorkerReviewContentMetadata(itemId)];
		const handler = createBridgeCommWorkerCommandHandler({
			contentItems,
			renderFulfillmentNow: (): number => nowMilliseconds,
			renderReceiptLeaseDurationMilliseconds: 10,
			renderRetryBackoffMilliseconds: 5,
			releaseExpiredReviewPublication: (expiredItemId): void => {
				expiredPublicationItemIds.push(expiredItemId);
			},
			rows: [{ id: itemId, parentId: null, index: 0 }],
			scheduleReviewMetadataReset: (): void => {
				resetScheduledWithBoundedLease =
					reviewStore?.renderFulfillmentRegistry.getItemState(itemId)?.stage === 'published' &&
					reviewStore.renderFulfillmentRegistry.nextLifecycleWakeAtMilliseconds() !== null;
			},
			scheduleSelectedReviewContentReadyPreparation:
				pushScheduledSelectedReviewPreparation(scheduledPreparations),
			scheduleSelectedFileViewContentReadyPreparation: ignoreScheduledSelectedFileViewPreparation,
		});
		handler.handleMessage(
			encodeBridgeWorkerSelectCommand({
				epoch: 7,
				requestId: 'request-select-before-generation-refresh',
				selectedItemId: itemId,
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		reviewStore = scheduledPreparations[0]?.store ?? null;
		if (reviewStore === null) throw new Error('expected selected Review store');
		const renderJob = makeReviewPublication({ itemId, publicationSequence: 1 }).job;
		const firstPublication = reviewStore.renderFulfillmentRegistry.beginPublication({
			job: renderJob,
			publicationSequence: 1,
			workerDerivationEpoch: 1,
		});
		const resetApplication = reviewMetadataApplication({
			contentItems,
			contentRequestDescriptors: [],
			renderSemantics: [],
			reset: true,
			rows: [{ id: itemId, parentId: null, index: 0 }],
			sourceEpoch: 8,
		});

		// Act: rollback preserves the original lease; commit retains the attempt without a local retry.
		const rolledBackTransaction = handler.prepareReviewMetadataApplication(resetApplication);
		rolledBackTransaction.rollback();
		const publicationAfterRollback = reviewStore.renderFulfillmentRegistry.beginPublication({
			job: renderJob,
			publicationSequence: 2,
			workerDerivationEpoch: 1,
		});
		const committedTransaction = handler.prepareReviewMetadataApplication(resetApplication);
		committedTransaction.commit();
		committedTransaction.runPostCommitEffects();
		const publicationAfterCommit = reviewStore.renderFulfillmentRegistry.beginPublication({
			job: renderJob,
			publicationSequence: 3,
			workerDerivationEpoch: 1,
		});

		// Assert
		expect(publicationAfterRollback).toMatchObject({
			receiptIdentity: firstPublication.receiptIdentity,
			shouldPublish: false,
			status: 'duplicate',
		});
		expect(resetScheduledWithBoundedLease).toBe(true);
		expect(publicationAfterCommit).toMatchObject({
			receiptIdentity: firstPublication.receiptIdentity,
			shouldPublish: false,
			status: 'duplicate',
		});
		nowMilliseconds = 9;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(expiredPublicationItemIds).toEqual([]);
		nowMilliseconds = 10;
		handler.advanceReviewRenderFulfillmentLifecycle(nowMilliseconds);
		expect(expiredPublicationItemIds).toEqual([itemId]);
	});
});

function makeWorkerReviewContentMetadata(itemId: string): BridgeWorkerReviewContentMetadata {
	const item = makeBridgeReviewItem({
		itemId,
		path: `Sources/App/${itemId}.swift`,
	});
	return {
		itemId: item.itemId,
		path: item.headPath ?? item.basePath ?? item.itemId,
		language: item.language ?? null,
		cacheKey: item.cacheKey,
		sizeBytes: item.sizeBytes,
		availableContentRoles: ['head'],
		contentLineCountsByRole: item.contentLineCountsByRole ?? {},
	};
}
