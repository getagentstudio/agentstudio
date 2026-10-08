import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	drainBridgeCommWorkerPreparationUntilIdle,
	drainUntilReviewAttemptCount,
	expectOriginalReviewContentAttemptsRemainActive,
	makePendingReviewContentStream,
	startBridgeCommWorkerPreparationDrains,
	type PendingReviewContentAttempt,
} from './bridge-comm-worker-runtime-protocol.review-product-preparation.test-support.js';
import {
	createReviewBatchSinkCapture,
	makeIdleReviewMetadataSubscription,
	makeReviewTestBatch,
	makeReviewProductTransport,
	type ReviewMetadataSubscription,
} from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import {
	createDeferredReviewContentStream,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';

describe('Bridge comm worker Review product active viewer mode lifecycle', () => {
	test('does not publish content that completes after File mode suspends Review', async () => {
		const reviewBatches = createReviewBatchSinkCapture();
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const deferredStreams = new Map<string, ReturnType<typeof createDeferredReviewContentStream>>();
		const reviewSubscription: ReviewMetadataSubscription = makeIdleReviewMetadataSubscription(
			'review-subscription-file-mode-late-content',
		);
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			openReviewContent: (descriptor) => {
				const deferredStream = createDeferredReviewContentStream(descriptor);
				deferredStreams.set(descriptor.descriptorId, deferredStream);
				return deferredStream.stream;
			},
			productTransport: makeReviewProductTransport({
				reviewSubscription,
				subscribedKinds: [],
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 1,
				requestId: 'request-review-active-before-file',
				update: {
					activeSource: null,
					mode: 'review',
					nativeSelectionRequestId: null,
					sequence: 1,
					sessionId: 'late-content-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				withContent: true,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 2,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-late-content-viewport',
				surface: 'review',
				visibleItemIds: ['item-1'],
			}),
		);
		await startBridgeCommWorkerPreparationDrains(
			scheduledDrains,
			flushBridgeWorkerRuntimeContinuations,
		);
		expect(deferredStreams.size).toBe(2);

		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 3,
				requestId: 'request-file-before-late-content',
				update: {
					activeSource: null,
					mode: 'file',
					nativeSelectionRequestId: null,
					sequence: 2,
					sessionId: 'late-content-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		postedMessages.length = 0;
		for (const deferredStream of deferredStreams.values()) {
			deferredStream.resolve('late Review content\n');
		}
		await flushBridgeWorkerRuntimeContinuations();
		await drainBridgeCommWorkerPreparationUntilIdle(
			scheduledDrains,
			flushBridgeWorkerRuntimeContinuations,
		);

		expect(
			postedMessages.filter(
				({ message }) =>
					message.kind === 'reviewPierreRenderJob' || message.kind === 'reviewRenderPatch',
			),
		).toEqual([]);
	});

	test('preserves pending Review content across accepted, stale, and repeated viewer mode updates', async () => {
		const reviewBatches = createReviewBatchSinkCapture();
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const attempts: PendingReviewContentAttempt[] = [];
		const reviewSubscription: ReviewMetadataSubscription = makeIdleReviewMetadataSubscription(
			'review-subscription-active-surface-lifecycle',
		);
		const { dispatch } = createRecordingBridgeCommWorkerPort();
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			openReviewContent: (descriptor, abortSignal) =>
				makePendingReviewContentStream({
					abortSignal,
					attempts,
					descriptorId: descriptor.descriptorId,
				}),
			productTransport: makeReviewProductTransport({
				reviewSubscription,
				subscribedKinds: [],
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 1,
				requestId: 'request-review-active-surface',
				update: {
					activeSource: null,
					mode: 'review',
					nativeSelectionRequestId: null,
					sequence: 1,
					sessionId: 'active-surface-lifecycle-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				withContent: true,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		await startBridgeCommWorkerPreparationDrains(
			scheduledDrains,
			flushBridgeWorkerRuntimeContinuations,
		);
		dispatch.message(
			encodeBridgeWorkerSelectCommand({
				epoch: 2,
				requestId: 'request-review-active-surface-selection',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 3,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-review-active-surface-viewport',
				surface: 'review',
				visibleItemIds: ['item-1'],
			}),
		);
		await drainUntilReviewAttemptCount({
			attempts,
			expectedCount: 2,
			scheduledDrains,
			flushContinuations: flushBridgeWorkerRuntimeContinuations,
		});
		expectOriginalReviewContentAttemptsRemainActive(attempts);

		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 4,
				requestId: 'request-file-active-surface',
				update: {
					activeSource: null,
					mode: 'file',
					nativeSelectionRequestId: null,
					sequence: 2,
					sessionId: 'active-surface-lifecycle-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expectOriginalReviewContentAttemptsRemainActive(attempts);

		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 5,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-inactive-review-viewport',
				surface: 'review',
				visibleItemIds: ['item-1'],
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expectOriginalReviewContentAttemptsRemainActive(attempts);

		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 6,
				requestId: 'request-review-active-surface-resume',
				update: {
					activeSource: null,
					mode: 'review',
					nativeSelectionRequestId: null,
					sequence: 3,
					sessionId: 'active-surface-lifecycle-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expectOriginalReviewContentAttemptsRemainActive(attempts);

		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 5,
				requestId: 'request-stale-file-active-surface',
				update: {
					activeSource: null,
					mode: 'file',
					nativeSelectionRequestId: null,
					sequence: 4,
					sessionId: 'active-surface-lifecycle-session',
				},
			}),
		);
		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 7,
				requestId: 'request-repeated-review-active-surface',
				update: {
					activeSource: null,
					mode: 'review',
					nativeSelectionRequestId: null,
					sequence: 5,
					sessionId: 'active-surface-lifecycle-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expectOriginalReviewContentAttemptsRemainActive(attempts);
	});
});
