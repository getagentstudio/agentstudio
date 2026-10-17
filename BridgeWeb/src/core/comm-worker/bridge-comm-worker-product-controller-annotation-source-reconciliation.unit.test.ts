import { describe, expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import { installBridgeProductCommentBatch } from './bridge-product-comment-batch-installer.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { BridgeProductSubscriptionResetError } from './bridge-product-subscription-state.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';
import {
	deferred,
	makeCommentCatalogInstallation,
	sessionId,
	worktreeId,
} from './test-fixtures/bridge-comm-worker-annotation-projection.test-support.js';

type FileMetadataProtocol = typeof bridgeProductFileMetadataApplicationProtocol;
type FileMetadataSubscription = BridgeProductMetadataApplicationSubscription<FileMetadataProtocol>;
type ReviewMetadataProtocol = typeof bridgeProductReviewMetadataApplicationProtocol;
type ReviewMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<ReviewMetadataProtocol>;

const currentFileSourceConfiguration = {
	cwdScope: null,
	freshness: 'live',
	includeStatuses: true,
	repoId: '00000000-0000-4000-8000-000000000001',
	rootPathToken: 'root-token-1',
	worktreeId: '00000000-0000-4000-8000-000000000002',
} as const;

describe('Bridge comm worker annotation source reconciliation', () => {
	test('a held stale File projection cannot cancel a File E3 that reopened for its own reset', async () => {
		const firstQuery = deferred<unknown>();
		const secondQuery = deferred<unknown>();
		const firstQueryStarted = deferred<void>();
		const secondQueryStarted = deferred<void>();
		const replacementOpened = deferred<void>();
		const firstFileEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const replacementFileEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const annotationEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		const reviewAnnotationEvents = new BridgeProductBoundedAsyncQueue<never>(1);
		let fileSubscriptionCount = 0;
		let fileCancellationCount = 0;
		const queryGenerations: number[] = [];
		const transport: BridgeProductTransportSession = {
			...unusedProductTransport(),
			call: (async (method: string, request: { sourceGeneration?: number }): Promise<unknown> => {
				if (method !== 'file.annotations.projection.query') {
					throw new Error(`Unexpected product call: ${method}.`);
				}
				queryGenerations.push(request.sourceGeneration ?? -1);
				if (queryGenerations.length === 1) {
					firstQueryStarted.resolve();
					return firstQuery.promise;
				}
				secondQueryStarted.resolve();
				return secondQuery.promise;
			}) as BridgeProductTransportSession['call'],
			subscribe: ((protocol: { kind: string }): unknown => {
				if (protocol.kind === 'file.annotations') {
					return {
						cancel: async (): Promise<void> => annotationEvents.close(true),
						events: annotationEvents,
						subscriptionId: 'file-annotations',
						subscriptionKind: 'file.annotations',
					};
				}
				if (protocol.kind === 'review.annotations') {
					return {
						cancel: async (): Promise<void> => reviewAnnotationEvents.close(true),
						events: reviewAnnotationEvents,
						subscriptionId: 'review-annotations',
						subscriptionKind: 'review.annotations',
					};
				}
				throw new Error(`Unexpected subscription: ${protocol.kind}.`);
			}) as BridgeProductTransportSession['subscribe'],
		};
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => ({
				source: currentFileSourceConfiguration,
				status: 'available',
			}),
			productTransport: transport,
			subscribeFile: () => {
				fileSubscriptionCount += 1;
				if (fileSubscriptionCount === 2) replacementOpened.resolve();
				return fileMetadataSubscription({
					cancel: async (): Promise<void> => {
						fileCancellationCount += 1;
					},
					subscriptionId: `file-metadata-${fileSubscriptionCount}`,
					...(fileSubscriptionCount === 1
						? { events: firstFileEvents }
						: { events: replacementFileEvents }),
				});
			},
		});
		await controller.ensureFileSource();
		controller.acceptInstalledFileBatch({
			certified: true,
			source: fileSourceIdentity(10),
			subscriptionId: 'file-metadata-1',
			workerDerivationEpoch: 1,
		});
		controller.setAnnotationProjectionSurfaceActive('file', true, 10);
		controller.ensureAnnotationSubscriptions();
		controller.acceptInstalledCommentCatalog(
			// This is a real W4 catalog installation; the query is held at the E4 boundary.
			installBridgeProductCommentBatch(
				makeCommentCatalogInstallation({
					snapshotCause: 'open',
					entries: [{ kind: 'session', semanticRevision: 1, sessionId }],
					revision: 1,
					subscriptionId: 'file-annotations',
					subscriptionKind: 'file.annotations',
					worktreeId,
				}),
				{
					subscriptionId: 'file-annotations',
					workerDerivationEpoch: 1,
					worktreeId,
				},
			),
			'file',
		);
		await firstQueryStarted.promise;

		firstFileEvents.fail(new BridgeProductSubscriptionResetError('stale_source'), true);
		await replacementOpened.promise;
		firstQuery.resolve({ currentSourceGeneration: 11, kind: 'source_stale' });
		await controller.waitForAnnotationProjectionIdle('file');
		expect(fileCancellationCount).toBe(0);
		expect(fileSubscriptionCount).toBe(2);

		controller.acceptInstalledFileBatch({
			certified: true,
			source: fileSourceIdentity(11),
			subscriptionId: 'file-metadata-2',
			workerDerivationEpoch: 2,
		});
		await secondQueryStarted.promise;
		secondQuery.resolve({ currentSourceGeneration: 12, kind: 'source_stale' });
		await controller.waitForAnnotationProjectionIdle('file');
		expect(fileCancellationCount).toBe(0);
		expect(fileSubscriptionCount).toBe(2);
		controller.setAnnotationProjectionSurfaceActive('file', true, 10);
		await controller.waitForAnnotationProjectionIdle('file');
		expect(queryGenerations).toEqual([10, 11]);

		firstFileEvents.close(true);
		replacementFileEvents.close(true);
		annotationEvents.close(true);
		reviewAnnotationEvents.close(true);
	});
	test('leaves File metadata open while a newer source generation is pending', async () => {
		let cancellationCount = 0;
		let discoveryCount = 0;
		let subscriptionCount = 0;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => {
				discoveryCount += 1;
				return { source: currentFileSourceConfiguration, status: 'available' };
			},
			productTransport: unusedProductTransport(),
			subscribeFile: () => {
				subscriptionCount += 1;
				return fileMetadataSubscription({
					cancel: async (): Promise<void> => {
						cancellationCount += 1;
					},
					subscriptionId: `file-metadata-${subscriptionCount}`,
				});
			},
		});
		await controller.ensureFileSource();

		await controller.reconcileAnnotationProjectionSourceAuthority({
			currentSourceGeneration: 12,
			requestedSourceGeneration: 10,
			surface: 'file',
		});

		expect(cancellationCount).toBe(0);
		expect(discoveryCount).toBe(1);
		expect(subscriptionCount).toBe(1);
	});

	test('leaves Review metadata open while a newer source generation is pending', async () => {
		let cancellationCount = 0;
		let subscriptionCount = 0;
		const controller = new BridgeCommWorkerProductController({
			productTransport: unusedProductTransport(),
			subscribeReview: () => {
				subscriptionCount += 1;
				return reviewMetadataSubscription({
					cancel: async (): Promise<void> => {
						cancellationCount += 1;
					},
					subscriptionId: `review-metadata-${subscriptionCount}`,
				});
			},
		});
		controller.ensureReviewMetadata();

		await controller.reconcileAnnotationProjectionSourceAuthority({
			currentSourceGeneration: 12,
			requestedSourceGeneration: 10,
			surface: 'review',
		});

		expect(cancellationCount).toBe(0);
		expect(subscriptionCount).toBe(1);
	});

	test('does not reopen metadata when source authority did not advance', async () => {
		const convergenceStates: string[] = [];
		let discoveryCount = 0;
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => {
				discoveryCount += 1;
				return { source: currentFileSourceConfiguration, status: 'available' };
			},
			onAnnotationProjectionConvergence: ({ state }): void => {
				convergenceStates.push(state.kind);
			},
			productTransport: unusedProductTransport(),
		});
		controller.setAnnotationProjectionSurfaceActive('file', false, 10);

		await controller.reconcileAnnotationProjectionSourceAuthority({
			currentSourceGeneration: 10,
			requestedSourceGeneration: 10,
			surface: 'file',
		});

		expect(convergenceStates).toEqual([]);
		expect(discoveryCount).toBe(0);
	});
});

function fileSourceIdentity(subscriptionGeneration: number): {
	readonly repoId: string;
	readonly rootRevisionToken: string;
	readonly sourceCursor: string;
	readonly sourceId: string;
	readonly subscriptionGeneration: number;
	readonly worktreeId: string;
} {
	return {
		repoId: currentFileSourceConfiguration.repoId,
		rootRevisionToken: `root-revision-${subscriptionGeneration}`,
		sourceCursor: `source-cursor-${subscriptionGeneration}`,
		sourceId: `file-source-${subscriptionGeneration}`,
		subscriptionGeneration,
		worktreeId: currentFileSourceConfiguration.worktreeId,
	};
}

function fileMetadataSubscription(props: {
	readonly cancel: () => Promise<void>;
	readonly events?: AsyncIterable<never>;
	readonly subscriptionId: string;
}): FileMetadataSubscription {
	return {
		cancel: props.cancel,
		events: props.events ?? new BridgeProductBoundedAsyncQueue<never>(1),
		subscriptionId: props.subscriptionId,
		subscriptionKind: 'file.metadata',
	};
}

function reviewMetadataSubscription(props: {
	readonly cancel: () => Promise<void>;
	readonly subscriptionId: string;
}): ReviewMetadataSubscription {
	return {
		cancel: props.cancel,
		events: new BridgeProductBoundedAsyncQueue<never>(1),
		subscriptionId: props.subscriptionId,
		subscriptionKind: 'review.metadata',
	};
}

function unusedProductTransport(): BridgeProductTransportSession {
	let fileEpoch = 0;
	let reviewEpoch = 0;
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (surface): number => {
			if (surface === 'file') fileEpoch += 1;
			else reviewEpoch += 1;
			return surface === 'file' ? fileEpoch : reviewEpoch;
		},
		call: async (): Promise<never> => {
			throw new Error('Unexpected product call.');
		},
		openContent: (): never => {
			throw new Error('Unexpected content open.');
		},
		subscribe: (): never => {
			throw new Error('Unexpected direct subscription.');
		},
		workerDerivationEpoch: (surface): number => (surface === 'file' ? fileEpoch : reviewEpoch),
	};
}
