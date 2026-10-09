import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { makeReviewProductTransport } from './bridge-comm-worker-runtime-protocol.review-product-transport.test-support.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductControlCommand } from './bridge-product-control-contracts.js';
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import { BridgeProductSubscriptionResetError } from './bridge-product-subscription-state.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';

type ReviewMetadataProtocol = typeof bridgeProductReviewMetadataApplicationProtocol;
type ReviewMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewMetadataProtocol>;

const reviewRecoveryControls: readonly BridgeProductControlCommand[] = [
	{ method: 'review.comparisonTargets.query', params: {} },
	{
		method: 'review.comparison.update',
		params: { target: { basis: 'commonCommit', kind: 'branch', name: 'origin/main' } },
	},
];

describe('Bridge comm worker Review metadata recovery', () => {
	test('automatic ensures and target queries cannot escape a failed E3 reopen budget', async () => {
		const exhaustedKinds: string[] = [];
		const events = [
			new BridgeProductBoundedAsyncQueue<never>(1),
			new BridgeProductBoundedAsyncQueue<never>(1),
			new BridgeProductBoundedAsyncQueue<never>(1),
		];
		const failures = [makeDeferred<void>(), makeDeferred<void>()];
		let subscriptionCount = 0;
		let failureCount = 0;
		const subscriptions = events.map((queue, index) =>
			reviewSubscription(`review-budget-${index}`, queue),
		);
		const firstSubscription = subscriptions[0];
		if (firstSubscription === undefined) throw new Error('First Review fixture missing.');
		const controller = new BridgeCommWorkerProductController({
			onReviewMetadataFailure: (): void => {
				failureCount += 1;
				failures[failureCount - 1]?.resolve();
			},
			productTransport: {
				...makeReviewProductTransport({
					calledMethods: [],
					onCall: (): null => null,
					reviewSubscription: firstSubscription,
					subscribedKinds: [],
				}),
				reportMetadataReopenExhausted: (kind): void => {
					exhaustedKinds.push(kind);
				},
			},
			subscribeReview: () => {
				const subscription = subscriptions[subscriptionCount++];
				if (subscription === undefined) throw new Error('Unexpected Review reopen.');
				return subscription;
			},
		});
		try {
			controller.ensureReviewMetadata();
			events[0]?.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
			await failures[0]?.promise;
			expect(subscriptionCount).toBe(2);
			events[1]?.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
			await failures[1]?.promise;
			try {
				controller.ensureReviewMetadata();
			} catch {
				/* Budget refusal is allowed. */
			}
			await controller.sendProductControl({ method: 'review.comparisonTargets.query', params: {} });
			expect(subscriptionCount).toBe(2);
			expect(exhaustedKinds).toContain('review.metadata');
			await controller.retryMetadataView('review');
			expect(subscriptionCount).toBe(3);
		} finally {
			for (const queue of events) queue.close(true);
		}
	});

	test('a current Review subscription reset reopens once without another UI action', async () => {
		// Arrange
		const firstEvents = new BridgeProductBoundedAsyncQueue<never>(8);
		const replacementEvents = new BridgeProductBoundedAsyncQueue<never>(8);
		const subscriptions = [
			reviewSubscription('review-before-reset', firstEvents),
			reviewSubscription('review-after-reset', replacementEvents),
		] as const;
		const firstFailure = makeDeferred<void>();
		const secondFailure = makeDeferred<void>();
		let subscriptionCount = 0;
		let failureCount = 0;
		const controller = new BridgeCommWorkerProductController({
			onReviewMetadataFailure: (): void => {
				failureCount += 1;
				if (failureCount === 1) firstFailure.resolve();
				if (failureCount === 2) secondFailure.resolve();
			},
			productTransport: makeReviewProductTransport({
				calledMethods: [],
				onCall: (): null => null,
				reviewSubscription: subscriptions[0],
				subscribedKinds: [],
			}),
			subscribeReview: () => {
				const subscription = subscriptions[subscriptionCount];
				if (subscription === undefined) throw new Error('Unbounded Review reset recovery.');
				subscriptionCount += 1;
				return subscription;
			},
		});
		controller.ensureReviewMetadata();
		try {
			// Act / Assert — retry a terminal reset, but stop if the new subscription makes no progress.
			firstEvents.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
			await firstFailure.promise;
			expect(subscriptionCount).toBe(2);
			replacementEvents.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
			await secondFailure.promise;
			expect(failureCount).toBe(2);
			expect(subscriptionCount).toBe(2);
		} finally {
			firstEvents.close(true);
			replacementEvents.close(true);
		}
	});

	test('a certified Review batch permits a later automatic reset recovery', async () => {
		const firstEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const secondEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const thirdEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const secondOpened = makeDeferred<void>();
		const thirdOpened = makeDeferred<void>();
		const subscriptions = [
			reviewSubscription('review-reset-1', firstEvents),
			reviewSubscription('review-reset-2', secondEvents),
			reviewSubscription('review-reset-3', thirdEvents),
		] as const;
		let subscriptionCount = 0;
		let reviewEpoch = 0;
		const productTransport = {
			...makeReviewProductTransport({
				calledMethods: [],
				onCall: (): null => null,
				reviewSubscription: subscriptions[0],
				subscribedKinds: [],
			}),
			advanceWorkerDerivationEpoch: (): number => ++reviewEpoch,
			workerDerivationEpoch: (): number => reviewEpoch,
		};
		const controller = new BridgeCommWorkerProductController({
			productTransport,
			subscribeReview: () => {
				const subscription = subscriptions[subscriptionCount];
				if (subscription === undefined) throw new Error('Unexpected fourth Review subscription.');
				subscriptionCount += 1;
				if (subscriptionCount === 2) secondOpened.resolve();
				if (subscriptionCount === 3) thirdOpened.resolve();
				return subscription;
			},
		});
		controller.ensureReviewMetadata();
		try {
			firstEvents.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
			await secondOpened.promise;
			controller.acceptInstalledReviewBatch({
				subscriptionId: 'review-reset-2',
				workerDerivationEpoch: 2,
			});
			secondEvents.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
			await thirdOpened.promise;
			expect(subscriptionCount).toBe(3);
		} finally {
			firstEvents.close(true);
			secondEvents.close(true);
			thirdEvents.close(true);
		}
	});

	test.each(reviewRecoveryControls)(
		'reopens failed Review metadata before $method control',
		async (command) => {
			// Arrange
			const firstEvents = new BridgeProductBoundedAsyncQueue<never>(8);
			const replacementEvents = new BridgeProductBoundedAsyncQueue<never>(8);
			const observedFailure = makeDeferred<void>();
			const subscriptions = [
				reviewSubscription('review-subscription-before-failure', firstEvents),
				reviewSubscription('review-subscription-after-failure', replacementEvents),
			] as const;
			let subscriptionCount = 0;
			const calledMethods: string[] = [];
			const controller = new BridgeCommWorkerProductController({
				onReviewMetadataFailure: (): void => observedFailure.resolve(),
				productTransport: makeReviewProductTransport({
					calledMethods,
					onCall: (): null => null,
					reviewSubscription: subscriptions[0],
					subscribedKinds: [],
				}),
				subscribeReview: () => {
					const subscription = subscriptions[subscriptionCount];
					if (subscription === undefined) throw new Error('Unexpected third Review subscription.');
					subscriptionCount += 1;
					return subscription;
				},
			});
			controller.ensureReviewMetadata();
			firstEvents.fail(
				Object.assign(new Error('metadata acknowledgement timed out'), {
					failureCode: 'request_timeout',
				}),
				true,
			);
			await observedFailure.promise;
			expect(subscriptionCount).toBe(1);

			// Act
			await controller.sendProductControl(command);

			// Assert
			expect(subscriptionCount).toBe(2);
			expect(calledMethods).toEqual([command.method]);
		},
	);
});

function reviewSubscription(
	subscriptionId: string,
	events: BridgeProductBoundedAsyncQueue<never>,
): ReviewMetadataSubscription {
	return {
		cancel: async (): Promise<void> => {},
		events,
		subscriptionId,
		subscriptionKind: 'review.metadata',
	};
}

function makeDeferred<TValue>(): {
	readonly promise: Promise<TValue>;
	readonly resolve: (value: TValue) => void;
} {
	let resolvePromise: ((value: TValue) => void) | undefined;
	const promise = new Promise<TValue>((resolve): void => {
		resolvePromise = resolve;
	});
	return {
		promise,
		resolve: (value): void => resolvePromise?.(value),
	};
}
