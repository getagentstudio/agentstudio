import { describe, expect, test } from 'vitest';

import {
	encodeBridgeWorkerActiveViewerModeUpdateCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
import type { BridgeCommWorkerPreparationDrain } from './bridge-comm-worker-runtime-protocol.js';
import {
	makeReviewPanePresentationFrame,
	requirePanePresentationSink,
} from './bridge-comm-worker-runtime-protocol.review-product-pane-presentation.test-support.js';
import {
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
	activateBridgeCommWorkerReviewViewerMode,
	createRecordingBridgeCommWorkerPort,
	flushBridgeWorkerRuntimeContinuations,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeProductPanePresentationFrame } from './bridge-product-transport.js';

describe('Bridge comm worker Review product pane activity lifecycle', () => {
	test('preserves selected Review preparation while the pane is hidden and foregrounded', async () => {
		const reviewBatches = createReviewBatchSinkCapture();
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const attempts: PendingReviewContentAttempt[] = [];
		let panePresentationSink: ((frame: BridgeProductPanePresentationFrame) => void) | null = null;
		const reviewSubscription: ReviewMetadataSubscription = makeIdleReviewMetadataSubscription(
			'review-subscription-pane-suppression',
		);
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
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
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				onPanePresentationSink: (sink): void => {
					panePresentationSink = sink;
				},
				reviewSubscription,
				subscribedKinds: [],
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'pane-suppression');
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
				epoch: 1,
				requestId: 'request-review-pane-suppression-selection',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 2,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-review-pane-suppression-viewport',
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
		const messageCountBeforeSuppression = postedMessages.length;

		requirePanePresentationSink(panePresentationSink)(
			makeReviewPanePresentationFrame(12, 'loadedHidden'),
		);
		await flushBridgeWorkerRuntimeContinuations();
		dispatch.message(
			encodeBridgeWorkerActiveViewerModeUpdateCommand({
				epoch: 3,
				requestId: 'request-hidden-review-active-viewer-mode',
				update: {
					activeSource: null,
					mode: 'review',
					nativeSelectionRequestId: null,
					sequence: 3,
					sessionId: 'hidden-review-session',
				},
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expectOriginalReviewContentAttemptsRemainActive(attempts);
		expect(
			postedMessages
				.slice(messageCountBeforeSuppression)
				.map(({ message }) => message)
				.filter(
					(message) =>
						message.kind === 'reviewPierreRenderJob' ||
						(message.kind === 'reviewRenderPatch' &&
							message.patches.some((patch) => patch.slice !== 'panelChrome')),
				),
		).toEqual([]);

		requirePanePresentationSink(panePresentationSink)(
			makeReviewPanePresentationFrame(13, 'foreground'),
		);
		await flushBridgeWorkerRuntimeContinuations();
		requirePanePresentationSink(panePresentationSink)(
			makeReviewPanePresentationFrame(13, 'foreground'),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expectOriginalReviewContentAttemptsRemainActive(attempts);
	});

	test('preserves held Review preparation across back-to-back hidden and foreground frames', async () => {
		const reviewBatches = createReviewBatchSinkCapture();
		const scheduledDrains: BridgeCommWorkerPreparationDrain[] = [];
		const attempts: PendingReviewContentAttempt[] = [];
		let panePresentationSink: ((frame: BridgeProductPanePresentationFrame) => void) | null = null;
		const reviewSubscription: ReviewMetadataSubscription = makeIdleReviewMetadataSubscription(
			'review-subscription-rapid-pane-resume',
		);
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
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
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				onPanePresentationSink: (sink): void => {
					panePresentationSink = sink;
				},
				reviewSubscription,
				subscribedKinds: [],
			}),
			schedulePreparationDrain: (drain): void => {
				scheduledDrains.push(drain);
			},
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'rapid-pane-resume');
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
				epoch: 1,
				requestId: 'request-review-rapid-pane-resume-selection',
				selectedItemId: 'item-1',
				selectedSource: 'user',
				surface: 'review',
			}),
		);
		dispatch.message(
			encodeBridgeWorkerViewportCommand({
				epoch: 2,
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				phase: 'settled',
				requestId: 'request-review-rapid-pane-resume-viewport',
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
		const messageCountBeforeNativeCycle = postedMessages.length;

		requirePanePresentationSink(panePresentationSink)(
			makeReviewPanePresentationFrame(12, 'loadedHidden'),
		);
		requirePanePresentationSink(panePresentationSink)(
			makeReviewPanePresentationFrame(13, 'foreground'),
		);
		await flushBridgeWorkerRuntimeContinuations();

		expectOriginalReviewContentAttemptsRemainActive(attempts);
		expect(
			postedMessages
				.slice(messageCountBeforeNativeCycle)
				.map(({ message }) => message)
				.filter(
					(message) =>
						message.kind === 'reviewRenderPatch' &&
						message.patches.some(
							(patch) =>
								patch.slice === 'contentAvailability' &&
								patch.operation === 'upsert' &&
								patch.payload.reason === 'load_failed',
						),
				),
		).toEqual([]);
	});
});
