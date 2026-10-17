import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import {
	BridgeProductBoundedAsyncQueue,
	createBridgeProductDeferred,
} from './bridge-product-async-queue.js';
import { bridgeProductReviewMetadataApplicationProtocol } from './bridge-product-metadata-application-registry.js';
import type { BridgeProductSubscriptionOptions } from './bridge-product-subscription-contracts.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

type ReviewMetadataProtocol = typeof bridgeProductReviewMetadataApplicationProtocol;
type ReviewMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewMetadataProtocol>;
type ReviewViewScopeRequest = Parameters<
	NonNullable<BridgeProductTransportSession['setViewScopeForSubscription']>
>[0];
type ReviewViewScopeSettlement = Awaited<
	ReturnType<NonNullable<BridgeProductTransportSession['setViewScopeForSubscription']>>
>;

describe('Bridge comm worker product controller Review interests', () => {
	test('atomically replaces all worker-owned Review view scopes and suppresses an equal snapshot', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(1);
		const viewScopes: ReviewViewScopeRequest[] = [];
		let reviewEpoch = 0;
		const controller = new BridgeCommWorkerProductController({
			productTransport: reviewEpochTransport({
				currentEpoch: (): number => reviewEpoch,
				incrementEpoch: (): number => (reviewEpoch += 1),
				setViewScopeForSubscription: async (request): Promise<ReviewViewScopeSettlement> => {
					viewScopes.push(request);
					return { kind: 'accepted', scopeRevision: viewScopes.length };
				},
			}),
			subscribeReview: () => ({
				cancel: async (): Promise<void> => {},
				events,
				subscriptionId: 'review-worker-demand-subscription',
				subscriptionKind: 'review.metadata',
			}),
		});
		controller.ensureReviewMetadata();
		const snapshot = {
			activeDemand: [
				{ itemId: 'selected', role: 'selected' },
				{ itemId: 'visible', role: 'visible' },
				{ itemId: 'nearby', role: 'nearby' },
				{ itemId: 'speculative', role: 'speculative' },
				{ itemId: 'background', role: 'background' },
			] as const,
			workerDerivationEpoch: 1,
		};

		// Act
		await controller.replaceReviewMetadataInterestsFromActiveDemand(snapshot);
		await controller.replaceReviewMetadataInterestsFromActiveDemand(snapshot);

		// Assert
		expect(viewScopes).toEqual([
			{
				scope: {
					kind: 'review',
					interests: [
						{ itemIds: ['selected'], lane: 'foreground' },
						{ itemIds: ['visible'], lane: 'visible' },
						{ itemIds: ['nearby'], lane: 'nearby' },
						{ itemIds: ['speculative'], lane: 'speculative' },
						{ itemIds: ['background'], lane: 'idle' },
					],
				},
				subscriptionId: 'review-worker-demand-subscription',
			},
		]);
	});

	test('retries a failed Review scope on the same E3 subscription', async () => {
		// Arrange
		const firstEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const subscriptionOptions: BridgeProductSubscriptionOptions<'review.metadata'>[] = [];
		const viewScopes: ReviewViewScopeRequest[] = [];
		let cancelCount = 0;
		let failureCount = 0;
		let reviewEpoch = 0;
		const authorityChanges: Array<number | null> = [];
		const subscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {
				cancelCount += 1;
			},
			events: firstEvents,
			subscriptionId: 'review-interest-failure-1',
			subscriptionKind: 'review.metadata',
		};
		const controller = new BridgeCommWorkerProductController({
			onReviewWorkerDerivationEpochChanged: (workerDerivationEpoch): void => {
				authorityChanges.push(workerDerivationEpoch);
			},
			onReviewMetadataFailure: (): void => {
				failureCount += 1;
			},
			productTransport: reviewEpochTransport({
				currentEpoch: (): number => reviewEpoch,
				incrementEpoch: (): number => (reviewEpoch += 1),
				setViewScopeForSubscription: async (request): Promise<ReviewViewScopeSettlement> => {
					viewScopes.push(request);
					if (viewScopes.length === 1) throw new Error('injected Review interest failure');
					return { kind: 'accepted', scopeRevision: viewScopes.length };
				},
			}),
			subscribeReview: (options) => {
				subscriptionOptions.push(options);
				return subscription;
			},
		});
		controller.ensureReviewMetadata();

		// Act / Assert
		await expect(
			controller.replaceReviewMetadataInterestsFromActiveDemand({
				activeDemand: [{ itemId: 'selected-before-failure', role: 'selected' }],
				workerDerivationEpoch: 1,
			}),
		).rejects.toThrow('injected Review interest failure');
		expect(cancelCount).toBe(0);
		expect(failureCount).toBe(1);
		expect(reviewEpoch).toBe(1);
		expect(authorityChanges).toEqual([1]);
		expect(subscriptionOptions).toEqual([{}]);

		await controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [{ itemId: 'selected-before-failure', role: 'selected' }],
			workerDerivationEpoch: 1,
		});
		expect(viewScopes.map(({ scope, subscriptionId }) => ({ scope, subscriptionId }))).toEqual([
			{
				scope: {
					kind: 'review',
					interests: [{ itemIds: ['selected-before-failure'], lane: 'foreground' }],
				},
				subscriptionId: 'review-interest-failure-1',
			},
			{
				scope: {
					kind: 'review',
					interests: [{ itemIds: ['selected-before-failure'], lane: 'foreground' }],
				},
				subscriptionId: 'review-interest-failure-1',
			},
		]);
		firstEvents.close(true);
	});

	test('keeps the newest Review scope when an older in-flight admission fails', async () => {
		// Arrange
		const firstEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const secondEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const firstUpdate = createBridgeProductDeferred<void>();
		const firstUpdateStarted = createBridgeProductDeferred<void>();
		const viewScopes: ReviewViewScopeRequest[] = [];
		let reviewEpoch = 0;
		let subscriptionIndex = 0;
		const subscriptions: readonly ReviewMetadataSubscription[] = [
			{
				cancel: async (): Promise<void> => {},
				events: firstEvents,
				subscriptionId: 'review-queued-interest-failure-1',
				subscriptionKind: 'review.metadata',
			},
			{
				cancel: async (): Promise<void> => {},
				events: secondEvents,
				subscriptionId: 'review-queued-interest-failure-2',
				subscriptionKind: 'review.metadata',
			},
		];
		const controller = new BridgeCommWorkerProductController({
			productTransport: reviewEpochTransport({
				currentEpoch: (): number => reviewEpoch,
				incrementEpoch: (): number => (reviewEpoch += 1),
				setViewScopeForSubscription: async (request): Promise<ReviewViewScopeSettlement> => {
					viewScopes.push(request);
					if (viewScopes.length === 1) {
						firstUpdateStarted.resolve();
						await firstUpdate.promise;
					}
					return { kind: 'accepted', scopeRevision: viewScopes.length };
				},
			}),
			subscribeReview: () => {
				const subscription = subscriptions[subscriptionIndex];
				if (subscription === undefined) throw new Error('Unexpected Review subscription.');
				subscriptionIndex += 1;
				return subscription;
			},
		});
		controller.ensureReviewMetadata();

		// Act
		const firstCommit = controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [{ itemId: 'selected-before-failure', role: 'selected' }],
			workerDerivationEpoch: 1,
		});
		await firstUpdateStarted.promise;
		const queuedCommit = controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [{ itemId: 'visible-before-failure', role: 'visible' }],
			workerDerivationEpoch: 1,
		});
		firstUpdate.reject(new Error('retire first Review interest authority'));

		// Assert
		await expect(firstCommit).resolves.toBeUndefined();
		await expect(queuedCommit).resolves.toBeUndefined();
		expect(reviewEpoch).toBe(1);
		expect(viewScopes).toEqual([
			{
				scope: {
					kind: 'review',
					interests: [{ itemIds: ['selected-before-failure'], lane: 'foreground' }],
				},
				subscriptionId: 'review-queued-interest-failure-1',
			},
			{
				scope: {
					kind: 'review',
					interests: [{ itemIds: ['visible-before-failure'], lane: 'visible' }],
				},
				subscriptionId: 'review-queued-interest-failure-1',
			},
		]);
		firstEvents.close(true);
		secondEvents.close(true);
	});
});

function reviewEpochTransport(props: {
	readonly currentEpoch: () => number;
	readonly incrementEpoch: () => number;
	readonly setViewScopeForSubscription?: NonNullable<
		BridgeProductTransportSession['setViewScopeForSubscription']
	>;
}): BridgeProductTransportSession {
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number =>
			surface === 'review' ? props.incrementEpoch() : 0,
		call: async (): Promise<never> => {
			throw new Error('Unexpected product call.');
		},
		openContent: (): never => {
			throw new Error('Unexpected content open.');
		},
		...(props.setViewScopeForSubscription === undefined
			? {}
			: { setViewScopeForSubscription: props.setViewScopeForSubscription }),
		subscribe: (): never => {
			throw new Error('Unexpected direct subscription.');
		},
		workerDerivationEpoch: (surface): number => (surface === 'review' ? props.currentEpoch() : 0),
	};
}
