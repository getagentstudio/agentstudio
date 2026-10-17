import { describe, expect, test } from 'vitest';

import type { BridgeWorkerAnnotationProjectionSnapshot } from '../core/comm-worker/bridge-comm-worker-annotation-projection-decoder.js';
import { createBridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainReviewCatalogChange,
} from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductReviewAnnotationPublicationIdentity } from '../core/comm-worker/bridge-product-call-contracts.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import { createBridgeWorkerRpcLifecycleStore } from '../core/comm-worker/bridge-worker-rpc-lifecycle-store.js';
import {
	createWorktreeAnnotationSurfaceClient,
	type WorktreeAnnotationProjectionSnapshot,
} from './worktree-annotation-surface-client.js';

const sessionId = '00000000-0000-7000-8000-000000000011';
const threadId = '00000000-0000-7000-8000-000000000012';
const messageId = '00000000-0000-7000-8000-000000000013';
const firstIdentity = reviewIdentity(1, '41');

describe('Review annotation application checkpoint', () => {
	test('does not install a held candidate before its publication becomes active', () => {
		const harness = createReviewApplicationHarness();
		harness.stageCatalog();
		const initialSnapshot = harness.client.getSnapshot();

		harness.publishReady(reviewIdentity(2, '42'), 1);

		expect(harness.client.getSnapshot()).toBe(initialSnapshot);
		expect(harness.client.getSnapshot().reviewAnnotationApplication).toBeNull();
		harness.dispose();
	});

	test('retires an unacknowledged application when its Review publication is replaced', () => {
		const harness = createReviewApplicationHarness();
		harness.publishReady(firstIdentity, 1);
		expect(harness.client.getSnapshot().reviewAnnotationApplication).not.toBeNull();

		harness.setActiveIdentity(reviewIdentity(2, '42'));

		expect(harness.client.getSnapshot().reviewAnnotationApplication).toBeNull();
		harness.dispose();
	});

	test('discards a late same-generation ready result before projection mutation', () => {
		const harness = createReviewApplicationHarness();
		harness.publishReady(firstIdentity, 1);
		const firstApplication = requireApplication(harness.client.getSnapshot());
		expect(firstApplication.affectedItemIds).toBeNull();
		expect(
			harness.client.acknowledgeReviewAnnotationApplication(firstApplication.applicationId),
		).toBe(true);
		const acceptedSnapshot = harness.client.getSnapshot();
		const secondIdentity = reviewIdentity(2, '42');
		harness.setActiveIdentity(secondIdentity);

		harness.publishReady(firstIdentity, 2);

		expect(harness.client.getSnapshot()).toBe(acceptedSnapshot);
		harness.dispose();
	});

	test('coalesces two ready scopes until the latest Pierre acknowledgement', () => {
		const harness = createReviewApplicationHarness();
		harness.publishReady(firstIdentity, 1);
		const initialApplication = requireApplication(harness.client.getSnapshot());
		harness.client.acknowledgeReviewAnnotationApplication(initialApplication.applicationId);

		harness.appendCatalogChange(['item-first']);
		harness.publishReady(firstIdentity, 2);
		const firstPendingApplication = requireApplication(harness.client.getSnapshot());
		expect(firstPendingApplication.affectedItemIds).toEqual(['item-first']);

		harness.appendCatalogChange(['item-second']);
		harness.publishReady(firstIdentity, 3);
		const coalescedApplication = requireApplication(harness.client.getSnapshot());
		expect(coalescedApplication.affectedItemIds).toEqual(['item-first', 'item-second']);
		expect(
			harness.client.acknowledgeReviewAnnotationApplication(firstPendingApplication.applicationId),
		).toBe(false);
		expect(
			harness.client.acknowledgeReviewAnnotationApplication(coalescedApplication.applicationId),
		).toBe(true);

		harness.publishReady(firstIdentity, 4);
		expect(requireApplication(harness.client.getSnapshot()).affectedItemIds).toEqual([]);
		harness.dispose();
	});

	test('unions skipped installed promotions from the completed checkpoint', () => {
		const harness = createReviewApplicationHarness();
		harness.publishReady(firstIdentity, 1);
		const initialApplication = requireApplication(harness.client.getSnapshot());
		harness.client.acknowledgeReviewAnnotationApplication(initialApplication.applicationId);

		harness.appendCatalogChange(['item-first']);
		harness.appendCatalogChange(['item-second']);
		const thirdIdentity = reviewIdentity(3, '43');
		harness.setActiveIdentity(thirdIdentity);
		harness.publishReady(thirdIdentity, 2);

		expect(requireApplication(harness.client.getSnapshot()).affectedItemIds).toEqual([
			'item-first',
			'item-second',
		]);
		harness.dispose();
	});

	test('uses full application for ledger eviction or reset', () => {
		const harness = createReviewApplicationHarness();
		harness.publishReady(firstIdentity, 1);
		const initialApplication = requireApplication(harness.client.getSnapshot());
		harness.client.acknowledgeReviewAnnotationApplication(initialApplication.applicationId);

		harness.appendCatalogChange(['item-reset'], true);
		harness.publishReady(firstIdentity, 2);
		expect(requireApplication(harness.client.getSnapshot()).affectedItemIds).toBeNull();
		const resetApplication = requireApplication(harness.client.getSnapshot());
		harness.client.acknowledgeReviewAnnotationApplication(resetApplication.applicationId);

		harness.setResetRequired(true);
		harness.publishReady(firstIdentity, 3);
		expect(requireApplication(harness.client.getSnapshot()).affectedItemIds).toBeNull();
		harness.dispose();
	});

	test('does not consume the checkpoint for control-only ready while content is demanded', () => {
		const harness = createReviewApplicationHarness();
		harness.publishReady(firstIdentity, 1);
		const initialApplication = requireApplication(harness.client.getSnapshot());
		harness.client.acknowledgeReviewAnnotationApplication(initialApplication.applicationId);
		harness.appendCatalogChange(['item-content']);

		harness.publishReady(firstIdentity, 2, []);
		expect(harness.client.getSnapshot()).toMatchObject({
			readStatus: { kind: 'refreshing' },
			reviewAnnotationApplication: null,
		});

		harness.publishReady(firstIdentity, 3);
		expect(requireApplication(harness.client.getSnapshot()).affectedItemIds).toEqual([
			'item-content',
		]);
		harness.dispose();
	});
});

interface ReviewApplicationHarness {
	readonly appendCatalogChange: (itemIds: readonly string[], reset?: boolean) => void;
	readonly client: ReturnType<typeof createWorktreeAnnotationSurfaceClient>;
	readonly dispose: () => void;
	readonly publishReady: (
		identity: BridgeProductReviewAnnotationPublicationIdentity,
		projectionRevision: number,
		contentSessionIds?: readonly string[],
	) => void;
	readonly setActiveIdentity: (identity: BridgeProductReviewAnnotationPublicationIdentity) => void;
	readonly setResetRequired: (resetRequired: boolean) => void;
	readonly stageCatalog: () => void;
}

function createReviewApplicationHarness(): ReviewApplicationHarness {
	let activeIdentity = firstIdentity;
	let catalogCursor = 0;
	let messageListener: ((message: BridgeWorkerServerToMainMessage) => void) | null = null;
	let renderListener: (() => void) | null = null;
	let reviewPresentationListener: (() => void) | null = null;
	let resetRequired = false;
	let catalogStaged = false;
	const catalogChanges: BridgeMainReviewCatalogChange[] = [];
	const renderStore = createBridgeMainRenderSnapshotStore();
	Object.defineProperties(renderStore, {
		getReviewCatalogSnapshot: {
			value: () => ({
				changeCursor: catalogCursor,
				epoch: 0,
				itemOrderLength: 2,
				revision: activeIdentity.revision,
				treeRowOrderLength: 2,
			}),
		},
		getReviewRefreshPresentation: {
			value: () => ({
				activeIdentity: {
					generation: activeIdentity.reviewGeneration,
					packageId: activeIdentity.packageId,
					publicationId: activeIdentity.publicationId,
					revision: activeIdentity.revision,
					sourceIdentity: activeIdentity.sourceIdentity,
				},
				candidate: null,
				failure: null,
			}),
		},
		readReviewCatalogChangesAfter: {
			value: (cursor: number) => ({
				changes: catalogChanges.filter((change): boolean => change.cursor > cursor),
				resetRequired,
			}),
		},
		subscribe: {
			value: (listener: () => void): (() => void) => {
				renderListener = listener;
				return (): void => {
					if (renderListener === listener) renderListener = null;
				};
			},
		},
		subscribeReviewRefreshPresentation: {
			value: (listener: () => void): (() => void) => {
				reviewPresentationListener = listener;
				return (): void => {
					if (reviewPresentationListener === listener) reviewPresentationListener = null;
				};
			},
		},
	});
	const fulfillmentCoordinator = createBridgeMainRenderFulfillmentCoordinator({
		cancelAnimationFrame: (): void => {},
		requestAnimationFrame: (): number => 1,
		sendDisposition: (): void => {},
	});
	const surfaceClient = {
		requestWorkerReplacement: (): void => {},
		lifecycle: createBridgeWorkerRpcLifecycleStore(),
		renderFulfillmentCoordinator: fulfillmentCoordinator,
		renderStore,
		send: (): string => 'worker-request',
		subscribeMessages: (
			listener: (message: BridgeWorkerServerToMainMessage) => void,
		): (() => void) => {
			messageListener = listener;
			return (): void => {
				if (messageListener === listener) messageListener = null;
			};
		},
		surface: 'review',
	} satisfies BridgePaneSurfaceClient;
	const client = createWorktreeAnnotationSurfaceClient(surfaceClient);
	const releaseSession = client.acquireSession(sessionId);
	const stageCatalog = (): void => {
		if (!catalogStaged) {
			catalogStaged = true;
			for (const catalogMessage of annotationCatalogStagingMessages()) {
				messageListener?.(catalogMessage);
			}
		}
	};
	const publish = (message: BridgeWorkerServerToMainMessage): void => {
		if (message.kind === 'annotationProjectionConvergence') stageCatalog();
		messageListener?.(message);
	};
	return {
		appendCatalogChange: (itemIds, reset = false): void => {
			catalogCursor += 1;
			catalogChanges.push({
				cursor: catalogCursor,
				itemIds,
				itemOrderMutations: [],
				reset,
				treeRowIds: [],
				treeRowOrderMutations: [],
			});
		},
		client,
		dispose: (): void => {
			releaseSession();
			client.dispose();
			fulfillmentCoordinator.dispose();
			renderStore.dispose();
		},
		publishReady: (identity, projectionRevision, contentSessionIds = [sessionId]): void => {
			const completeSnapshot = projectionSnapshot(projectionRevision);
			const snapshot =
				contentSessionIds.length === 0
					? {
							...completeSnapshot,
							expectedMessageCount: 0,
							expectedThreadCount: 0,
							threads: [],
						}
					: completeSnapshot;
			publish({
				direction: 'serverWorkerToMain',
				kind: 'annotationProjectionConvergence',
				operationCorrelationId: 'a'.repeat(64),
				state: {
					contentSessionIds,
					kind: 'ready',
					stageAttempt: 0,
					reviewPublicationIdentity: identity,
					snapshot,
				},
				surface: 'review',
				transferDescriptors: [],
				wireVersion: BRIDGE_WORKER_WIRE_VERSION,
			});
		},
		setActiveIdentity: (identity): void => {
			activeIdentity = identity;
			reviewPresentationListener?.();
		},
		setResetRequired: (value): void => {
			resetRequired = value;
		},
		stageCatalog,
	};
}

function reviewIdentity(
	revision: number,
	publicationSuffix: string,
): BridgeProductReviewAnnotationPublicationIdentity {
	return {
		packageId: 'package-installed',
		publicationId: `00000000-0000-7000-8000-0000000000${publicationSuffix}`,
		reviewGeneration: 7,
		revision,
		sourceIdentity: 'source-installed',
	};
}

function requireApplication(
	snapshot: ReturnType<ReviewApplicationHarness['client']['getSnapshot']>,
): NonNullable<WorktreeAnnotationProjectionSnapshot['reviewAnnotationApplication']> {
	const application = snapshot.reviewAnnotationApplication;
	if (application === null) throw new Error('Expected pending Review annotation application.');
	return application;
}

function projectionSnapshot(projectionRevision: number): BridgeWorkerAnnotationProjectionSnapshot {
	return {
		expectedMessageCount: 1,
		expectedSessionCount: 1,
		expectedThreadCount: 1,
		projectionRevision,
		recoveryStatus: 'available',
		sessions: [
			{
				completedAt: null,
				createdAt: 1,
				eligibleMessageCount: 1,
				eligibleWithoutInlinePlacementCount: 0,
				lifecycle: 'living',
				semanticRevision: projectionRevision,
				sessionId,
				sourceRelationship: 'applicable',
				updatedAt: 2,
			},
		],
		sourceGeneration: 7,
		threads: [
			{
				context: {
					diffSide: 'additions',
					endLine: 4,
					path: 'Sources/App.swift',
					placement: 'exact',
					resolution: 'open',
					scope: 'located',
					sourceIdentity: 'source-1',
					sourceRole: 'review_head',
					startLine: 3,
					threadId,
				},
				messages: [
					{
						attentionState: 'not_applicable',
						authorKind: 'human',
						createdAt: 2,
						draft: null,
						handled: false,
						messageId,
						messageRevision: projectionRevision,
						ordinal: 0,
						savedBody: 'Comment',
						savedRevision: projectionRevision,
						sessionId,
						sessionRevision: projectionRevision,
						status: 'locked',
						threadId,
						threadRevision: projectionRevision,
					},
				],
			},
		],
		worktreeId: 'worktree-1',
	};
}

function annotationCatalogStagingMessages(): readonly Extract<
	BridgeWorkerServerToMainMessage,
	{ readonly kind: 'annotationCatalogStaging' }
>[] {
	const authority = {
		subscriptionId: 'review-annotation-subscription-1',
		workerDerivationEpoch: 1,
		worktreeId: 'worktree-1',
	} as const;
	const transferId = 'review-annotation-catalog-1';
	const entries = [
		{ kind: 'session' as const, semanticRevision: 1, sessionId },
		{
			createdOrdinal: 0,
			kind: 'thread' as const,
			scope: 'located' as const,
			sessionId,
			threadId,
		},
		{ kind: 'message' as const, messageId, ordinal: 0, threadId },
	];
	const common = {
		authority,
		direction: 'serverWorkerToMain' as const,
		kind: 'annotationCatalogStaging' as const,
		operationCorrelationId: 'a'.repeat(64),
		surface: 'review' as const,
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
	return [
		{
			...common,
			transfer: {
				catalogRevision: 1,
				expectedEntryCount: entries.length,
				kind: 'catalog.begin',
				transferId,
			},
		},
		{
			...common,
			transfer: {
				catalogRevision: 1,
				entries,
				kind: 'catalog.window',
				transferId,
				windowOrdinal: 0,
			},
		},
		{
			...common,
			transfer: {
				catalogRevision: 1,
				entryCount: entries.length,
				kind: 'catalog.commit',
				transferId,
				windowCount: 1,
			},
		},
	];
}
