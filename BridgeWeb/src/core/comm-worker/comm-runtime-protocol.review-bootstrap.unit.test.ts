import { describe, expect, test } from 'vitest';

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
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import type { BridgeProductSubscriptionOptions } from './bridge-product-subscription-contracts.js';
import type { BridgeProductSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

describe('Bridge comm worker Review product bootstrap', () => {
	test('opens Review metadata only after Review becomes the active viewer', async () => {
		// Arrange
		const subscriptions: Array<{
			readonly kind: 'review.metadata';
			readonly options: BridgeProductSubscriptionOptions<'review.metadata'>;
		}> = [];
		const reviewSubscription: BridgeProductSubscription<'review.metadata'> =
			makeIdleReviewMetadataSubscription('review-bootstrap-subscription');
		const { dispatch } = createRecordingBridgeCommWorkerPort();

		registerBridgeCommWorkerRuntimePortProtocol(dispatch.port, {
			bridgeDemandRank: { lane: 'selected', priority: 0 },
			budget: { className: 'interactive', maxBytes: 512 * 1024, maxWindowLines: 400 },
			productTransport: productTransportRecordingReviewBootstrap({
				reviewSubscription,
				subscriptions,
			}),
		});
		await flushBridgeWorkerRuntimeContinuations();
		expect(subscriptions).toEqual([]);

		// Act
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'initial-review');
		await flushBridgeWorkerRuntimeContinuations();

		// Assert
		expect(subscriptions).toEqual([
			{
				kind: 'review.metadata',
				options: {},
			},
		]);
	});

	test('starts File metadata only after the active Review publication commits', async () => {
		// Arrange
		const reviewBatches = createReviewBatchSinkCapture();
		const calledMethods: string[] = [];
		const reviewSubscription: ReviewMetadataSubscription = makeIdleReviewMetadataSubscription(
			'review-active-first-subscription',
		);
		const { dispatch } = createRecordingBridgeCommWorkerPort();
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

		// Act / Assert
		activateBridgeCommWorkerReviewViewerMode(dispatch, 'active-first');
		await flushBridgeWorkerRuntimeContinuations();
		expect(calledMethods).not.toContain('file.source.current');

		await reviewBatches.install(
			makeReviewTestBatch({
				snapshotCause: 'open',
				subscriptionId: reviewSubscription.subscriptionId,
				withContent: true,
			}),
		);
		await flushBridgeWorkerRuntimeContinuations();
		expect(calledMethods.filter((method) => method === 'file.source.current')).toHaveLength(1);
	});
});

function productTransportRecordingReviewBootstrap(props: {
	readonly reviewSubscription: BridgeProductSubscription<'review.metadata'>;
	readonly subscriptions: Array<{
		readonly kind: 'review.metadata';
		readonly options: BridgeProductSubscriptionOptions<'review.metadata'>;
	}>;
}): BridgeProductTransportSession {
	let reviewEpoch = 0;
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'review') reviewEpoch += 1;
			return surface === 'review' ? reviewEpoch : 0;
		},
		call: async (): Promise<never> => ({ reason: 'notConfigured', status: 'unavailable' }) as never,
		openContent: (): never => {
			throw new Error('Review bootstrap must not open content.');
		},
		subscribe: (...arguments_): never => {
			const [protocol, options] = arguments_;
			if (protocol.kind !== bridgeProductReviewMetadataApplicationProtocol.kind) {
				throw new Error(`Unexpected product subscription ${protocol.kind}.`);
			}
			props.subscriptions.push({
				kind: bridgeProductReviewMetadataApplicationProtocol.kind,
				options: bridgeProductReviewMetadataApplicationProtocol.optionsSchema.parse(options),
			});
			return props.reviewSubscription as never;
		},
		workerDerivationEpoch: (surface): number => (surface === 'review' ? reviewEpoch : 0),
	};
}
