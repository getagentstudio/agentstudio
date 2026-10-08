import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerRenderDispositionCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	createReviewBatchSinkCapture,
	makeIdleReviewMetadataSubscription,
	makeReviewProductTransport,
	makeReviewTestBatch,
} from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	activateBridgeCommWorkerReviewViewerMode,
	createRecordingBridgeCommWorkerPort,
	makeImmediateReviewContentStream,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeWorkerReviewPierreRenderJobEvent } from './bridge-worker-contracts.js';
import { bridgeWorkerRenderDispositionReceiptSchema } from './bridge-worker-render-fulfillment.js';

describe('Review render recovery Retry composition', () => {
	test.each([
		['visible', 'queued'],
		['selected', 'queued'],
		['visible', 'missing'],
	] as const)(
		'exhaustion then Retry and an identical bank paint surviving %s demand after %s delivery',
		async (demand, delivery) => {
			let nowMilliseconds = 0;
			let failedRenderCount = 0;
			const retriedSubscriptionIds: string[] = [];
			const wakes: Array<{ active: boolean; readonly wake: () => void }> = [];
			const preparationTasks = new Set<Promise<unknown>>();
			let acknowledgeReviewMode = (): void => {};
			const reviewModeAccepted = new Promise<void>((resolve): void => {
				acknowledgeReviewMode = resolve;
			});
			const batches = createReviewBatchSinkCapture();
			const subscription = makeIdleReviewMetadataSubscription('review-render-recovery');
			const transport = makeReviewProductTransport({
				onBatchFrameSinks: batches.onBatchFrameSinks,
				reviewSubscription: subscription,
				subscribedKinds: [],
			});
			const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort({
				beforePostMessage: (message): void => {
					if (
						message.kind === 'health' &&
						message.requestId === 'request-review-mode-render-recovery'
					)
						acknowledgeReviewMode();
				},
			});
			const whenPrepared = async (): Promise<void> => {
				if (preparationTasks.size === 0) return;
				await Promise.all(preparationTasks);
				await whenPrepared();
			};
			registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
				now: (): number => nowMilliseconds,
				openReviewContent: (descriptor) =>
					makeImmediateReviewContentStream(descriptor, 'hello world\n'),
				productTransport: {
					...transport,
					failReviewRender: (): void => {
						failedRenderCount += 1;
					},
					retryView: async (subscriptionId): Promise<void> => {
						retriedSubscriptionIds.push(subscriptionId);
					},
				},
				schedulePreparationDrain: (drain: BridgeCommWorkerPreparationDrain): void => {
					const task = Promise.resolve().then(drain);
					preparationTasks.add(task);
					void task.finally((): void => {
						preparationTasks.delete(task);
					});
				},
				scheduleRenderFulfillmentWake: (_delay, wake): (() => void) => {
					const scheduled = { active: true, wake };
					wakes.push(scheduled);
					return (): void => {
						scheduled.active = false;
					};
				},
			});
			activateBridgeCommWorkerReviewViewerMode(dispatch, 'render-recovery');
			await reviewModeAccepted;
			await batches.install(
				makeReviewTestBatch({
					snapshotCause: 'open',
					subscriptionId: subscription.subscriptionId,
					withContent: true,
				}),
			);
			await whenPrepared();
			dispatch.message(
				encodeBridgeWorkerViewportCommand({
					epoch: 7,
					firstVisibleIndex: 0,
					lastVisibleIndex: 0,
					phase: 'settled',
					requestId: 'visible-render-recovery',
					surface: 'review',
					visibleItemIds: ['item-1'],
				}),
			);
			await whenPrepared();
			const publications = (): BridgeWorkerReviewPierreRenderJobEvent[] =>
				postedMessages.flatMap(({ message }) =>
					message.kind === 'reviewPierreRenderJob' ? [message] : [],
				);
			const disposition = (
				publication: BridgeWorkerReviewPierreRenderJobEvent,
				value: 'queued' | 'applied' | 'painted',
			): void => {
				dispatch.message(
					encodeBridgeWorkerRenderDispositionCommand({
						epoch: 7,
						receipts: [
							bridgeWorkerRenderDispositionReceiptSchema.parse({
								...publication.renderReceiptIdentity,
								disposition: value,
								kind: 'render.disposition',
								receivedAtMilliseconds: nowMilliseconds,
							}),
						],
						requestId: `${publication.renderReceiptIdentity.attemptId}-${value}`,
					}),
				);
			};
			const latestPublication = (): BridgeWorkerReviewPierreRenderJobEvent => {
				const publication = publications().at(-1);
				if (publication === undefined) throw new Error('Expected the demanded Review render.');
				return publication;
			};
			const advanceWake = (atMilliseconds: number): void => {
				nowMilliseconds = atMilliseconds;
				const scheduled = wakes.find((candidate) => candidate.active);
				if (scheduled === undefined) throw new Error('Expected a render lease wake.');
				scheduled.active = false;
				scheduled.wake();
			};
			if (delivery === 'queued') disposition(latestPublication(), 'queued');
			advanceWake(5_000);
			advanceWake(5_025);
			await whenPrepared();
			expect(publications()).toHaveLength(2);
			const exhaustedPublication = latestPublication();
			if (delivery === 'queued') disposition(exhaustedPublication, 'queued');
			advanceWake(10_025);
			await whenPrepared();
			expect(failedRenderCount).toBe(1);
			if (demand === 'selected') {
				dispatch.message(
					encodeBridgeWorkerSelectCommand({
						epoch: 8,
						requestId: 'select-exhausted',
						selectedItemId: 'item-1',
						selectedSource: 'user',
						surface: 'review',
					}),
				);
				dispatch.message(
					encodeBridgeWorkerViewportCommand({
						epoch: 8,
						requestId: 'hide-exhausted',
						firstVisibleIndex: 0,
						lastVisibleIndex: 0,
						phase: 'settled',
						surface: 'review',
						visibleItemIds: [],
					}),
				);
				await whenPrepared();
			}

			dispatch.message({
				wireVersion: 1,
				direction: 'mainToServerWorker',
				transferDescriptors: [],
				kind: 'command',
				command: 'viewRecoveryRetry',
				epoch: 8,
				requestId: 'retry-render-recovery',
				view: { kind: 'review.metadata', subscriptionId: subscription.subscriptionId },
			});
			expect(retriedSubscriptionIds).toEqual([subscription.subscriptionId]);
			await batches.install(
				makeReviewTestBatch({
					snapshotCause: 'open',
					subscriptionId: subscription.subscriptionId,
					revision: 12,
					withContent: true,
				}),
			);
			await whenPrepared();
			expect(publications()).toHaveLength(3);
			const retryPublication = latestPublication();
			expect(retryPublication.renderReceiptIdentity.attemptId).not.toBe(
				exhaustedPublication.renderReceiptIdentity.attemptId,
			);
			for (const value of ['queued', 'applied', 'painted'] as const)
				disposition(retryPublication, value);
			await whenPrepared();
			expect(
				postedMessages
					.filter(
						({ message }) =>
							message.kind === 'health' &&
							message.requestId === `${retryPublication.renderReceiptIdentity.attemptId}-painted`,
					)
					.map(({ message }) => message),
			).toMatchObject([{ status: 'ready' }]);
			expect(wakes.filter((scheduled) => scheduled.active)).toEqual([]);
			expect(failedRenderCount).toBe(1);
			await subscription.cancel();
		},
	);
});
