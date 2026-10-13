import { describe, expect, test } from 'vitest';

import { expectedEmptyReviewProjectionResetPatches } from './bridge-comm-worker-entry.test-support.js';
import { encodeBridgeWorkerSelectCommand } from './bridge-comm-worker-protocol.js';
import { registerBridgeCommWorkerRuntimePortProtocol } from './bridge-comm-worker-runtime-protocol.js';
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
	createBridgeCommWorkerReviewProductTestSource,
	makeWorkerReviewContentMetadata,
	makeContentRequestDescriptor,
	makeRenderSemantics,
	openReviewContentFromDescriptorMap,
} from './bridge-comm-worker-runtime-protocol.test-support.js';
import { createWorkerContentPreparationPump } from './bridge-worker-content-preparation-pump.js';
import {
	createReviewPreparationObservations,
	driveReviewPreparationUntil,
} from './comm-runtime-protocol.review-preparation.test-support.js';

describe('Bridge comm worker Review product source failure policy', () => {
	test('does not restart selected Review demand after metadata retirement', async () => {
		let nowMilliseconds = 0;
		const wakes: Array<{
			active: boolean;
			readonly atMilliseconds: number;
			readonly fire: () => void;
		}> = [];
		const observations = createReviewPreparationObservations();
		const { dispatch, postedMessages, waitForMessage } = createRecordingBridgeCommWorkerPort({
			beforePostMessage: observations.beforePostMessage,
		});
		const source = createBridgeCommWorkerReviewProductTestSource();
		try {
			registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
				bridgeDemandRank: { lane: 'selected', priority: 0 },
				budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 50 },
				now: (): number => nowMilliseconds,
				pump: createWorkerContentPreparationPump({
					maxSliceMs: 8,
					now: (): number => nowMilliseconds,
				}),
				openReviewContent: openReviewContentFromDescriptorMap,
				productTransport: source.productTransport,
				schedulePreparationDrain: observations.schedule,
				scheduleRenderFulfillmentWake: (delayMilliseconds, fire): (() => void) => {
					const wake = { active: true, atMilliseconds: nowMilliseconds + delayMilliseconds, fire };
					wakes.push(wake);
					return (): void => {
						wake.active = false;
					};
				},
			});
			activateBridgeCommWorkerReviewViewerMode(dispatch, 'closed-render-wake');
			source.publishSource({
				contentItems: [makeWorkerReviewContentMetadata({ itemId: 'item-1' })],
				contentRequestDescriptors: [
					makeContentRequestDescriptor({ itemId: 'item-1', role: 'base', text: 'base\n' }),
					makeContentRequestDescriptor({ itemId: 'item-1', role: 'head', text: 'head\n' }),
				],
				renderSemantics: [makeRenderSemantics({ itemId: 'item-1' })],
				rows: [{ id: 'item-1', index: 0, parentId: null }],
			});
			await source.waitForSourceInstallation();
			dispatch.message(
				encodeBridgeWorkerSelectCommand({
					epoch: 2,
					requestId: 'selected-before-close',
					surface: 'review',
					selectedItemId: 'item-1',
					selectedSource: 'user',
				}),
			);
			await driveReviewPreparationUntil({
				observations,
				startIndex: 0,
				label: 'selected render publication before metadata close',
				hasExpectedEvent: (): boolean =>
					postedMessages.some(({ message }) => message.kind === 'reviewPierreRenderJob'),
			});
			expect(wakes.some((wake) => wake.active)).toBe(true);

			const receiptWake = wakes.find((wake) => wake.active);
			if (receiptWake === undefined) throw new Error('Expected the captured receipt-lease wake.');
			source.close();
			await waitForMessage(
				(message): boolean =>
					message.kind === 'reviewDisplayPatch' &&
					message.patches.some(
						(patch) =>
							patch.slice === 'reviewSource' &&
							patch.operation === 'upsert' &&
							patch.payload.status === 'stale',
					),
			);
			expect((): void => {
				if (!receiptWake.active) return;
				nowMilliseconds = receiptWake.atMilliseconds;
				receiptWake.active = false;
				receiptWake.fire();
				const retryWake = wakes.find((wake) => wake.active);
				if (retryWake !== undefined) {
					nowMilliseconds = retryWake.atMilliseconds;
					retryWake.active = false;
					retryWake.fire();
				}
			}).not.toThrow();
			expect(wakes.filter((wake) => wake.active)).toEqual([]);
		} finally {
			source.close();
			const installation = source.pendingSourceInstallation();
			if (installation !== null) await installation;
			for (const wake of wakes) wake.active = false;
			observations.close();
		}
	});

	test('publishes a bounded Review display failure from a certified failed publication', async () => {
		const reviewBatches = createReviewBatchSinkCapture();
		const reviewSubscription: ReviewMetadataSubscription = makeIdleReviewMetadataSubscription(
			'review-subscription-failure',
		);
		const { dispatch, postedMessages } = createRecordingBridgeCommWorkerPort();
		const calledMethods: string[] = [];
		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: makeReviewProductTransport({
				onBatchFrameSinks: reviewBatches.onBatchFrameSinks,
				calledMethods,
				reviewSubscription,
				subscribedKinds: [],
			}),
		});
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'terminal-failure');
		await flushBridgeWorkerRuntimeContinuations();

		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				itemCount: 0,
				desiredStatus: 'failedRetryable',
				withoutDisplayed: true,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();

		const reviewDisplayEvents = postedMessages
			.map(({ message }) => message as unknown as Readonly<Record<string, unknown>>)
			.filter((message) => message['kind'] === 'reviewDisplayPatch');
		expect(reviewDisplayEvents.at(-1)).toMatchObject({
			kind: 'reviewDisplayPatch',
			reviewPublicationIdentity: null,
			patches: [
				{
					operation: 'failed',
					payload: { error: 'metadataUnavailable', status: 'failed' },
					slice: 'reviewSource',
				},
				{ operation: 'replace', payload: null, slice: 'reviewComparison' },
				...expectedEmptyReviewProjectionResetPatches(),
			],
			surface: 'review',
		});
		expect(calledMethods).toContain('file.source.current');
	});
});
