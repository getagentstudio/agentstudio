import { describe, expect, test } from 'vitest';

import { expectedEmptyReviewProjectionResetPatches } from './bridge-comm-worker-entry.test-support.js';
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
} from './bridge-comm-worker-runtime-protocol.test-support.js';

describe('Bridge comm worker Review product source failure policy', () => {
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
