import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { type BridgeProductSubscriptionOptions } from './bridge-product-subscription-contracts.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import {
	bridgeProductMaximumViewScopeItemCount,
	type BridgeProductViewScopeRequest,
} from './bridge-product-view-control-wire-contracts.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

type ProductViewScope = BridgeProductViewScopeRequest['scope'];

type FileMetadataProtocol = typeof bridgeProductFileMetadataApplicationProtocol;
type FileMetadataSubscription = BridgeProductMetadataApplicationSubscription<FileMetadataProtocol>;
type ReviewMetadataProtocol = typeof bridgeProductReviewMetadataApplicationProtocol;
type ReviewMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewMetadataProtocol>;

const source = {
	repoId: '00000000-0000-4000-8000-000000000001',
	rootRevisionToken: 'root-revision-1',
	sourceCursor: 'source-cursor-1',
	sourceId: 'file-source-1',
	subscriptionGeneration: 3,
	worktreeId: '00000000-0000-4000-8000-000000000002',
} as const;

describe('Bridge comm worker product controller', () => {
	test('opens one Review metadata subscription and reconciles lane interests in the comm worker', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const updates: Array<{
			readonly interests: readonly { readonly lane: string; readonly itemIds: readonly string[] }[];
		}> = [];
		let reviewEpoch = 0;
		let subscriptionOptions: unknown = null;
		const reviewSubscription: ReviewMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'review-subscription-1',
			subscriptionKind: 'review.metadata',
		};
		const controller = new BridgeCommWorkerProductController({
			productTransport: {
				...unusedProductTransport((scope): void => {
					if (scope.kind === 'review') updates.push({ interests: scope.interests });
				}),
				...createTestMetadataReopenPort(),
				advanceWorkerDerivationEpoch: (surface): number => {
					if (surface === 'review') reviewEpoch += 1;
					return surface === 'review' ? reviewEpoch : 0;
				},
				workerDerivationEpoch: (surface): number => (surface === 'review' ? reviewEpoch : 0),
			},
			subscribeReview: (options) => {
				subscriptionOptions = options;
				return reviewSubscription;
			},
		});

		// Act
		controller.ensureReviewMetadata();
		await controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [{ itemId: 'item-selected', role: 'selected' }],
			workerDerivationEpoch: 1,
		});
		await controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [
				{ itemId: 'item-selected', role: 'selected' },
				{ itemId: 'item-visible', role: 'visible' },
			],
			workerDerivationEpoch: 1,
		});
		await controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [{ itemId: 'item-visible', role: 'visible' }],
			workerDerivationEpoch: 1,
		});
		await controller.replaceReviewMetadataInterestsFromActiveDemand({
			activeDemand: [],
			workerDerivationEpoch: 1,
		});
		// Assert
		expect(reviewEpoch).toBe(1);
		expect(subscriptionOptions).toEqual({});
		expect(updates).toEqual([
			{ interests: [{ itemIds: ['item-selected'], lane: 'foreground' }] },
			{
				interests: [
					{ itemIds: ['item-selected'], lane: 'foreground' },
					{ itemIds: ['item-visible'], lane: 'visible' },
				],
			},
			{ interests: [{ itemIds: ['item-visible'], lane: 'visible' }] },
			{ interests: [] },
		]);
	});

	test('opens one canonical Review subscription for empty interests and keeps it open', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(1);
		let derivationEpochBumpCount = 0;
		let subscribeReviewCallCount = 0;
		let subscriptionOptions: BridgeProductSubscriptionOptions<'review.metadata'> | null = null;
		const controller = new BridgeCommWorkerProductController({
			productTransport: {
				...unusedProductTransport(),
				...createTestMetadataReopenPort(),
				advanceWorkerDerivationEpoch: (): number => {
					derivationEpochBumpCount += 1;
					return derivationEpochBumpCount;
				},
			},
			subscribeReview: (options) => {
				subscribeReviewCallCount += 1;
				subscriptionOptions = options;
				return {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'review-empty-interest-subscription',
					subscriptionKind: 'review.metadata',
				};
			},
		});

		// Act
		controller.ensureReviewMetadata();

		// Assert
		expect(subscribeReviewCallCount).toBe(1);
		expect(derivationEpochBumpCount).toBe(1);
		expect(subscriptionOptions).toEqual({});
	});

	test('retains early File demand and reconciles it after one discovered source opens', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const sourceDiscovery = createDeferredFileSourceDiscovery();
		const updates: unknown[] = [];
		let discoveryCallCount = 0;
		let derivationEpochBumpCount = 0;
		let subscriptionCount = 0;
		let resolveDemandReapplication = (): void => {};
		const demandReapplied = new Promise<void>((resolve): void => {
			resolveDemandReapplication = resolve;
		});
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => {
				discoveryCallCount += 1;
				return await sourceDiscovery.promise;
			},
			productTransport: productTransportWithFileEpochBump(
				(): void => {
					derivationEpochBumpCount += 1;
				},
				(scope): void => {
					if (scope.kind !== 'file') return;
					updates.push({ interests: scope.interests, pathScope: scope.pathScope });
					resolveDemandReapplication();
				},
			),
			subscribeFile: (options) => {
				subscriptionCount += 1;
				expect(options).toEqual({ source: currentFileSourceConfiguration });
				return {
					cancel: async (): Promise<void> => {},
					events,
					subscriptionId: 'discovered-file-subscription',
					subscriptionKind: 'file.metadata',
				};
			},
		});

		const firstEnsure = controller.ensureFileSource();
		const secondEnsure = controller.ensureFileSource();
		await controller.updateFileMetadataDemand({
			epoch: 1,
			nearbyPaths: ['Sources/Nearby-Old.swift'],
			selectedPath: 'Sources/Selected-Old.swift',
			visiblePaths: ['Sources/Visible-Old.swift'],
		});
		await controller.updateFileMetadataDemand({
			epoch: 2,
			nearbyPaths: ['Sources/Nearby.swift'],
			selectedPath: 'Sources/Selected.swift',
			visiblePaths: ['Sources/Visible.swift'],
		});
		expect(subscriptionCount).toBe(0);

		sourceDiscovery.resolve({ source: currentFileSourceConfiguration, status: 'available' });
		await Promise.all([firstEnsure, secondEnsure]);
		controller.acceptInstalledFileBatch({
			certified: true,
			source,
			subscriptionId: 'discovered-file-subscription',
			workerDerivationEpoch: 1,
		});
		await demandReapplied;

		expect(discoveryCallCount).toBe(1);
		expect(derivationEpochBumpCount).toBe(1);
		expect(subscriptionCount).toBe(1);
		expect(updates).toEqual([
			{
				interests: [
					{ lane: 'foreground', paths: ['Sources/Selected.swift'] },
					{ lane: 'visible', paths: ['Sources/Visible.swift'] },
					{ lane: 'nearby', paths: ['Sources/Nearby.swift'] },
				],
				pathScope: [],
			},
		]);
	});

	test('settles unavailable File discovery once without subscribing or retrying', async () => {
		let discoveryCallCount = 0;
		let derivationEpochBumpCount = 0;
		let subscriptionCount = 0;
		let unavailableCount = 0;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => {
				discoveryCallCount += 1;
				return { reason: 'no-file-source-authority', status: 'unavailable' };
			},
			onFileSourceUnavailable: (): void => {
				unavailableCount += 1;
			},
			productTransport: productTransportWithFileEpochBump((): void => {
				derivationEpochBumpCount += 1;
			}),
			subscribeFile: (): never => {
				subscriptionCount += 1;
				throw new Error('Unavailable discovery must not subscribe.');
			},
		});

		await Promise.all([controller.ensureFileSource(), controller.ensureFileSource()]);
		await controller.updateFileMetadataDemand({
			epoch: 4,
			nearbyPaths: ['Sources/Nearby.swift'],
			selectedPath: 'Sources/Selected.swift',
			visiblePaths: ['Sources/Visible.swift'],
		});
		await controller.ensureFileSource();

		expect(discoveryCallCount).toBe(1);
		expect(derivationEpochBumpCount).toBe(0);
		expect(subscriptionCount).toBe(0);
		expect(unavailableCount).toBe(1);
	});

	test('opens File metadata and replaces worker-owned selected demand without another native RPC path', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const updates: unknown[] = [];
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
		};
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: discoverCurrentFileSource,
			productTransport: unusedProductTransport((scope): void => {
				if (scope.kind === 'file')
					updates.push({ interests: scope.interests, pathScope: scope.pathScope });
			}),
			subscribeFile: () => subscription,
		});

		// Act
		await controller.ensureFileSource();
		controller.acceptInstalledFileBatch({
			certified: true,
			source,
			subscriptionId: 'file-subscription-1',
			workerDerivationEpoch: 1,
		});
		await controller.updateFileMetadataDemand({
			epoch: 1,
			nearbyPaths: [],
			selectedPath: 'Sources/File.swift',
			visiblePaths: [],
		});
		await controller.updateFileMetadataDemand({
			epoch: 2,
			nearbyPaths: [],
			selectedPath: 'Sources/Other.swift',
			visiblePaths: [],
		});
		await controller.updateFileMetadataDemand({
			epoch: 1,
			nearbyPaths: [],
			selectedPath: 'Sources/Stale.swift',
			visiblePaths: [],
		});

		// Assert
		expect(updates).toEqual([
			{
				interests: [{ lane: 'foreground', paths: ['Sources/File.swift'] }],
				pathScope: [],
			},
			{
				interests: [{ lane: 'foreground', paths: ['Sources/Other.swift'] }],
				pathScope: [],
			},
		]);
	});

	test('deduplicates selected, visible, and nearby paths by demand priority', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const updates: unknown[] = [];
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-priority',
			subscriptionKind: 'file.metadata',
		};
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: discoverCurrentFileSource,
			productTransport: unusedProductTransport((scope): void => {
				if (scope.kind === 'file')
					updates.push({ interests: scope.interests, pathScope: scope.pathScope });
			}),
			subscribeFile: () => subscription,
		});
		await controller.ensureFileSource();
		controller.acceptInstalledFileBatch({
			certified: true,
			source,
			subscriptionId: 'file-subscription-priority',
			workerDerivationEpoch: 1,
		});

		await controller.updateFileMetadataDemand({
			epoch: 1,
			selectedPath: 'Sources/Selected.swift',
			visiblePaths: ['Sources/Selected.swift', 'Sources/Visible.swift'],
			nearbyPaths: ['Sources/Visible.swift', 'Sources/Nearby.swift'],
		});

		expect(updates).toEqual([
			{
				interests: [
					{ lane: 'foreground', paths: ['Sources/Selected.swift'] },
					{ lane: 'visible', paths: ['Sources/Visible.swift'] },
					{ lane: 'nearby', paths: ['Sources/Nearby.swift'] },
				],
				pathScope: [],
			},
		]);
	});

	test('bounds aggregate File interests while retaining selected priority', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const updates: Array<{
			readonly interests: readonly { readonly lane: string; readonly paths: readonly string[] }[];
			readonly pathScope: readonly string[];
		}> = [];
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-bounded',
			subscriptionKind: 'file.metadata',
		};
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: discoverCurrentFileSource,
			productTransport: unusedProductTransport((scope): void => {
				if (scope.kind === 'file')
					updates.push({ interests: scope.interests, pathScope: scope.pathScope });
			}),
			subscribeFile: () => subscription,
		});
		await controller.ensureFileSource();
		controller.acceptInstalledFileBatch({
			certified: true,
			source,
			subscriptionId: 'file-subscription-bounded',
			workerDerivationEpoch: 1,
		});

		await controller.updateFileMetadataDemand({
			epoch: 1,
			selectedPath: 'Sources/Selected.swift',
			visiblePaths: Array.from(
				{ length: bridgeProductMaximumViewScopeItemCount },
				(_unused, index) => `Sources/Visible-${index}.swift`,
			),
			nearbyPaths: ['Sources/Nearby.swift'],
		});

		const interests = updates[0]?.interests ?? [];
		expect(interests[0]).toEqual({
			lane: 'foreground',
			paths: ['Sources/Selected.swift'],
		});
		expect(interests.reduce((count, interest) => count + interest.paths.length, 0)).toBe(
			bridgeProductMaximumViewScopeItemCount,
		);
		expect(interests.some((interest) => interest.paths.includes('Sources/Nearby.swift'))).toBe(
			false,
		);
	});

	test('reports File interest update failures and permits a same-demand retry', async () => {
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const failures: Array<{ readonly error: unknown; readonly epoch: number }> = [];
		const updates: unknown[] = [];
		let shouldRejectUpdate = true;
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-update-failure',
			subscriptionKind: 'file.metadata',
		};
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: discoverCurrentFileSource,
			onFileMetadataDemandFailure: (error, epoch): void => {
				failures.push({ epoch, error });
			},
			productTransport: unusedProductTransport((scope): void => {
				if (scope.kind !== 'file') return;
				if (shouldRejectUpdate) {
					shouldRejectUpdate = false;
					throw new Error('interest update failed');
				}
				updates.push({ interests: scope.interests, pathScope: scope.pathScope });
			}),
			subscribeFile: () => subscription,
		});
		await controller.ensureFileSource();
		controller.acceptInstalledFileBatch({
			certified: true,
			source,
			subscriptionId: 'file-subscription-update-failure',
			workerDerivationEpoch: 1,
		});
		const demand = {
			epoch: 1,
			nearbyPaths: [],
			selectedPath: 'Sources/File.swift',
			visiblePaths: [],
		} as const;

		await expect(controller.updateFileMetadataDemand(demand)).rejects.toThrow(
			/interest update failed/i,
		);
		await controller.updateFileMetadataDemand(demand);

		expect(failures).toEqual([{ epoch: 1, error: expect.any(Error) }]);
		expect(updates).toEqual([
			{
				interests: [{ lane: 'foreground', paths: ['Sources/File.swift'] }],
				pathScope: [],
			},
		]);
	});

	test('reports an active File metadata subscription that ends unexpectedly', async () => {
		// Arrange
		const events = new BridgeProductBoundedAsyncQueue<never>(64);
		const subscription: FileMetadataSubscription = {
			cancel: async (): Promise<void> => {},
			events,
			subscriptionId: 'file-subscription-ended',
			subscriptionKind: 'file.metadata',
		};
		let resolveFailure = (_error: unknown): void => {};
		const failure = new Promise<unknown>((resolve): void => {
			resolveFailure = resolve;
		});
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: discoverCurrentFileSource,
			onFileMetadataFailure: (error): void => {
				resolveFailure(error);
			},
			productTransport: unusedProductTransport(),
			subscribeFile: () => subscription,
		});

		// Act
		await controller.ensureFileSource();
		events.close(true);

		// Assert
		await expect(failure).resolves.toEqual(expect.any(Error));
		expect(((await failure) as Error).message).toMatch(/ended unexpectedly/i);
	});
});

function unusedProductTransport(
	onScope?: (scope: ProductViewScope) => void | Promise<void>,
): BridgeProductTransportSession {
	let fileEpoch = 0;
	let scopeRevision = 0;
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') fileEpoch += 1;
			return surface === 'file' ? fileEpoch : 0;
		},
		call: async (): Promise<never> => {
			throw new Error('Unexpected product call.');
		},
		openContent: (): never => {
			throw new Error('Unexpected content open.');
		},
		setViewScopeForSubscription: async ({ scope }) => {
			await onScope?.(scope);
			return { kind: 'accepted', scopeRevision: ++scopeRevision };
		},
		subscribe: (): never => {
			throw new Error('Unexpected direct subscription.');
		},
		workerDerivationEpoch: (surface): number => (surface === 'file' ? fileEpoch : 0),
	};
}

const currentFileSourceConfiguration = {
	cwdScope: null,
	freshness: 'live',
	includeStatuses: true,
	repoId: source.repoId,
	rootPathToken: 'root-token-1',
	worktreeId: source.worktreeId,
} as const;

function createDeferredFileSourceDiscovery(): {
	readonly promise: Promise<
		| { readonly source: typeof currentFileSourceConfiguration; readonly status: 'available' }
		| { readonly reason: 'no-file-source-authority'; readonly status: 'unavailable' }
	>;
	readonly resolve: (
		result:
			| { readonly source: typeof currentFileSourceConfiguration; readonly status: 'available' }
			| { readonly reason: 'no-file-source-authority'; readonly status: 'unavailable' },
	) => void;
} {
	let resolveDiscovery: (
		result:
			| { readonly source: typeof currentFileSourceConfiguration; readonly status: 'available' }
			| { readonly reason: 'no-file-source-authority'; readonly status: 'unavailable' },
	) => void = (): void => {};
	const promise = new Promise<
		| { readonly source: typeof currentFileSourceConfiguration; readonly status: 'available' }
		| { readonly reason: 'no-file-source-authority'; readonly status: 'unavailable' }
	>((resolve): void => {
		resolveDiscovery = resolve;
	});
	return { promise, resolve: resolveDiscovery };
}

function productTransportWithFileEpochBump(
	onBump: () => void,
	onScope?: (scope: ProductViewScope) => void | Promise<void>,
): BridgeProductTransportSession {
	let fileEpoch = 0;
	return {
		...unusedProductTransport(onScope),
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') {
				fileEpoch += 1;
				onBump();
			}
			return surface === 'file' ? fileEpoch : 0;
		},
		workerDerivationEpoch: (surface): number => (surface === 'file' ? fileEpoch : 0),
	};
}
function discoverCurrentFileSource(): Promise<{
	readonly source: typeof currentFileSourceConfiguration;
	readonly status: 'available';
}> {
	return Promise.resolve({ source: currentFileSourceConfiguration, status: 'available' });
}
