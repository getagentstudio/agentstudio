import { describe, expect, test, vi } from 'vitest';

import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainCodeViewItem,
	type BridgeMainReviewPublicationIdentity,
} from './bridge-main-render-snapshot-store.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	type BridgeWorkerReviewCandidateStartDisposition,
	type BridgeWorkerReviewDisplayItem,
	type BridgeWorkerReviewDisplayPatchEvent,
} from './bridge-worker-contracts.js';
import { bridgeWorkerReviewSourceContext } from './bridge-worker-review-display.test-support.js';

const ACTIVE_IDENTITY = reviewIdentity(1, 1, '11');
const CANDIDATE_IDENTITY = reviewIdentity(2, 1, '12');
const SUCCESSOR_IDENTITY = reviewIdentity(3, 1, '13');
const LATEST_IDENTITY = reviewIdentity(4, 1, '14');
const FINAL_IDENTITY = reviewIdentity(5, 1, '15');

describe('Bridge main render snapshot store Review candidate bank', () => {
	test('clears candidate Review comparison when a nullable display patch carries null', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		const activeComparison = {
			activeTarget: { basis: 'commonCommit', kind: 'branch', name: 'origin/main' },
			attempt: { reviewGeneration: 1, status: 'settled' },
			displayedSnapshot: {
				packageId: 'package-1',
				reviewGeneration: 1,
				revision: 11,
				status: 'current',
			},
			repositoryDefaultTarget: null,
		} as const;
		const activeEvent = reviewDisplayEvent(1, 'item-a', 1);
		installReview(store, ACTIVE_IDENTITY, {
			...activeEvent,
			patches: [
				{ operation: 'replace', payload: activeComparison, slice: 'reviewComparison' },
				...activeEvent.patches,
			],
		});
		expect(store.getSnapshot().panelChromeSlice.reviewComparison).toEqual(activeComparison);
		startCandidate(store, CANDIDATE_IDENTITY);
		const candidateEvent = reviewDisplayEvent(2, 'item-b', 1);

		// Act
		const staged = store.stageReviewCandidateDisplayEvent({
			event: {
				...candidateEvent,
				patches: [
					{ operation: 'replace', payload: null, slice: 'reviewComparison' },
					...candidateEvent.patches,
				],
			},
			identity: CANDIDATE_IDENTITY,
		});

		// Assert
		expect(staged).toBe(true);
		expect(
			store.markReviewCandidateReady({ identity: CANDIDATE_IDENTITY, role: 'provisional' }),
		).toBe(true);
		expect(store.promoteReviewCandidate(CANDIDATE_IDENTITY)).toBe(true);
		expect(store.getSnapshot().panelChromeSlice.reviewComparison).toBeNull();
	});

	test('keeps A visible while a complete B and its render copies remain private', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		store.setWorkerCodeViewItem({ item: reviewCodeViewItem('item-a', 'A'), itemId: 'item-a' });
		const activeSnapshot = store.getSnapshot();
		startCandidate(store, CANDIDATE_IDENTITY, ['stable-b']);

		// Act
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(2, 'item-b', 1),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(true);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(2, 'item-b-2', 2, false),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(true);
		expect(
			store.setReviewCandidateCodeViewItem({
				identity: CANDIDATE_IDENTITY,
				item: reviewCodeViewItem('item-b', 'B'),
				itemId: 'item-b',
			}),
		).toBe(true);
		expect(
			store.markReviewCandidateReady({
				identity: CANDIDATE_IDENTITY,
				role: 'updateReady',
			}),
		).toBe(true);

		// Assert
		expect(store.getSnapshot()).toBe(activeSnapshot);
		expect(store.getReviewItemSnapshot('item-a')).toBeDefined();
		expect(store.getReviewItemSnapshot('item-b')).toBeUndefined();
		expect(store.getReviewItemSnapshot('item-b-2')).toBeUndefined();
		expect(store.getReviewCodeViewItemSnapshot('item-b')).toBeUndefined();
		expect(store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: ACTIVE_IDENTITY,
			candidate: {
				affectedStableFileIdentities: ['stable-b'],
				effectivePresentationClass: { kind: 'ordinary' },
				identity: CANDIDATE_IDENTITY,
				role: 'updateReady',
				startDisposition: sameSourceDisposition(['stable-b']),
			},
			failure: null,
		});
	});

	test('suppresses presentation notifications for same-candidate snapshot patches', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		const presentationListener = vi.fn();
		store.subscribeReviewRefreshPresentation(presentationListener);
		startCandidate(store, CANDIDATE_IDENTITY, ['stable-b']);

		// Act
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(2, 'item-b', 1),
			identity: CANDIDATE_IDENTITY,
		});
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(2, 'item-b-2', 2, false),
			identity: CANDIDATE_IDENTITY,
		});
		store.markReviewCandidateReady({
			identity: CANDIDATE_IDENTITY,
			role: 'updateReady',
		});

		// Assert
		expect(presentationListener).toHaveBeenCalledTimes(2);
	});

	test('replaces B with C and rejects stale or ambiguous candidate traffic', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		startCandidate(store, CANDIDATE_IDENTITY);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(2, 'item-b', 1),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(true);

		// Act
		startCandidate(store, SUCCESSOR_IDENTITY);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(3, 'item-c', 1),
				identity: SUCCESSOR_IDENTITY,
			}),
		).toBe(true);

		// Assert
		expect(
			store.markReviewCandidateReady({
				identity: CANDIDATE_IDENTITY,
				role: 'provisional',
			}),
		).toBe(false);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(2, 'item-b-delayed', 2),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(false);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(3, 'item-ambiguous', 2),
				identity: { ...SUCCESSOR_IDENTITY, publicationId: publicationId('99') },
			}),
		).toBe(false);
		expect(store.getReviewRefreshPresentation().candidate?.identity).toEqual(SUCCESSOR_IDENTITY);
	});

	test('carries a held same-lineage candidate into its direct successor', () => {
		// Arrange
		const activeIdentity = sameLineageIdentity(1, '31');
		const heldIdentity = sameLineageIdentity(2, '32');
		const successorIdentity = sameLineageIdentity(3, '33');
		const store = createBridgeMainRenderSnapshotStore();
		installReview(
			store,
			activeIdentity,
			sameLineageDisplayEvent(activeIdentity, 'item-a', 0, true),
		);
		const catalogCursorBeforeSuccessors = store.getReviewCatalogSnapshot().changeCursor;
		startCandidate(store, heldIdentity, ['item-b']);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: sameLineageDisplayEvent(heldIdentity, 'item-b', 1, false),
				identity: heldIdentity,
			}),
		).toBe(true);
		expect(store.markReviewCandidateReady({ identity: heldIdentity, role: 'updateReady' })).toBe(
			true,
		);

		// Act
		startCandidate(store, successorIdentity, ['item-c']);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: sameLineageDisplayEvent(successorIdentity, 'item-c', 2, false),
				identity: successorIdentity,
			}),
		).toBe(true);
		expect(
			store.markReviewCandidateReady({ identity: successorIdentity, role: 'provisional' }),
		).toBe(true);

		// Assert
		expect(store.getReviewRefreshPresentation().candidate).toMatchObject({
			affectedStableFileIdentities: ['item-b', 'item-c'],
			identity: successorIdentity,
		});
		expect(store.promoteReviewCandidate(successorIdentity)).toBe(true);
		expect(store.getReviewItemSnapshot('item-a')).toBeDefined();
		expect(store.getReviewItemSnapshot('item-b')).toBeDefined();
		expect(store.getReviewItemSnapshot('item-c')).toBeDefined();
		expect(store.readReviewCatalogChangesAfter(catalogCursorBeforeSuccessors)).toEqual({
			changes: [
				{
					cursor: catalogCursorBeforeSuccessors + 1,
					itemIds: ['item-b', 'item-c'],
					itemOrderMutations: [
						{ kind: 'setRange', length: 1, startIndex: 1 },
						{ kind: 'setRange', length: 1, startIndex: 2 },
					],
					reset: false,
					treeRowIds: ['row-item-b', 'row-item-c'],
					treeRowOrderMutations: [
						{ kind: 'setRange', length: 1, startIndex: 1 },
						{ kind: 'setRange', length: 1, startIndex: 2 },
					],
				},
			],
			resetRequired: false,
		});
	});

	test('pins an installing B against successor replacement until promotion', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		startCandidate(store, CANDIDATE_IDENTITY, ['stable-b']);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(2, 'item-b', 1),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(true);
		expect(
			store.markReviewCandidateReady({
				identity: CANDIDATE_IDENTITY,
				role: 'installing',
			}),
		).toBe(true);

		// Act
		expect(
			store.startReviewCandidate({
				disposition: sameSourceDisposition([]),
				identity: SUCCESSOR_IDENTITY,
			}),
		).toBe(false);
		const stagedSuccessor = store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(3, 'item-c', 1),
			identity: SUCCESSOR_IDENTITY,
		});

		// Assert
		expect(stagedSuccessor).toBe(false);
		expect(store.getReviewRefreshPresentation().candidate).toEqual({
			affectedStableFileIdentities: ['stable-b'],
			effectivePresentationClass: { kind: 'ordinary' },
			identity: CANDIDATE_IDENTITY,
			role: 'installing',
			startDisposition: sameSourceDisposition(['stable-b']),
		});
		expect(store.promoteReviewCandidate(CANDIDATE_IDENTITY)).toBe(true);
	});

	test('escalates only the Main-local effective class and preserves it in failure', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		startCandidate(store, CANDIDATE_IDENTITY, ['stable-b']);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: reviewDisplayEvent(2, 'item-b', 1),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(true);

		// Act
		expect(
			store.escalateReviewCandidatePresentation({
				identity: CANDIDATE_IDENTITY,
				presentationClass: { kind: 'promoted', reason: 'activeAnchor' },
			}),
		).toBe(true);
		expect(
			store.markReviewCandidateReady({ identity: CANDIDATE_IDENTITY, role: 'updateReady' }),
		).toBe(true);

		// Assert
		expect(store.getReviewRefreshPresentation().candidate).toMatchObject({
			effectivePresentationClass: { kind: 'promoted', reason: 'activeAnchor' },
			startDisposition: {
				kind: 'sameSource',
				presentationClass: { kind: 'ordinary' },
			},
		});

		// Act
		expect(store.failReviewCandidate({ identity: CANDIDATE_IDENTITY, retryable: true })).toBe(true);

		// Assert
		expect(store.getReviewRefreshPresentation().failure).toMatchObject({
			identity: CANDIDATE_IDENTITY,
			presentationClass: { kind: 'promoted', reason: 'activeAnchor' },
			retryable: true,
		});
	});

	test('promotes the exact newest candidate as one coherent active publication', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		store.setWorkerCodeViewItem({ item: reviewCodeViewItem('item-a', 'A'), itemId: 'item-a' });
		store.applyWorkerPatch({
			itemId: 'item-a',
			operation: 'upsert',
			payload: { state: 'ready' },
			slice: 'contentAvailability',
		});
		startCandidate(store, CANDIDATE_IDENTITY, ['stable-b']);
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(2, 'item-b', 1),
			identity: CANDIDATE_IDENTITY,
		});
		store.setReviewCandidateCodeViewItem({
			identity: CANDIDATE_IDENTITY,
			item: reviewCodeViewItem('item-b', 'B'),
			itemId: 'item-b',
		});
		store.applyReviewCandidateSnapshotUpdate({
			identity: CANDIDATE_IDENTITY,
			workerPatches: [
				{
					itemId: 'item-b',
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
				{
					itemId: 'not-in-candidate',
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
				{
					itemId: 'not-in-candidate',
					operation: 'upsert',
					payload: { status: 'ready' },
					slice: 'rowPaint',
				},
			],
		});
		expect(
			store.setReviewCandidateCodeViewItem({
				identity: CANDIDATE_IDENTITY,
				item: reviewCodeViewItem('not-in-candidate', 'invalid'),
				itemId: 'not-in-candidate',
			}),
		).toBe(false);
		store.markReviewCandidateReady({
			identity: CANDIDATE_IDENTITY,
			role: 'updateReady',
		});
		const catalogCursorBeforePromotion = store.getReviewCatalogSnapshot().changeCursor;
		const rootListener = vi.fn();
		const catalogListener = vi.fn();
		const oldItemListener = vi.fn();
		const newItemListener = vi.fn();
		store.subscribe(rootListener);
		store.subscribeReviewCatalog(catalogListener);
		store.subscribeReviewItem('item-a', oldItemListener);
		store.subscribeReviewItem('item-b', newItemListener);

		// Act
		expect(store.promoteReviewCandidate(SUCCESSOR_IDENTITY)).toBe(false);
		expect(store.promoteReviewCandidate(CANDIDATE_IDENTITY)).toBe(true);

		// Assert
		expect(store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: CANDIDATE_IDENTITY,
			candidate: null,
			failure: null,
		});
		expect(store.getReviewItemSnapshot('item-a')).toBeUndefined();
		expect(store.getReviewItemSnapshot('item-b')).toBeDefined();
		expect(store.getReviewCodeViewItemSnapshot('item-a')).toBeUndefined();
		expect(store.getReviewCodeViewItemSnapshot('item-b')?.bridgeMetadata.displayPath).toBe('B');
		expect(store.getReviewAvailabilitySnapshot('item-a')).toBeUndefined();
		expect(store.getReviewAvailabilitySnapshot('item-b')).toEqual({ state: 'ready' });
		expect(store.getReviewAvailabilitySnapshot('not-in-candidate')).toBeUndefined();
		expect(store.getReviewCodeViewItemSnapshot('not-in-candidate')).toBeUndefined();
		expect(store.getSnapshot().rowPaintById['not-in-candidate']).toBeUndefined();
		expect(rootListener).toHaveBeenCalledTimes(1);
		expect(catalogListener).toHaveBeenCalledTimes(1);
		expect(oldItemListener).toHaveBeenCalledTimes(1);
		expect(newItemListener).toHaveBeenCalledTimes(1);
		expect(store.readReviewCatalogChangesAfter(catalogCursorBeforePromotion)).toMatchObject({
			changes: [{ reset: true }],
			resetRequired: false,
		});
	});

	test('discards candidate state on explicit discard, worker replacement, close, and dispose', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		const stage = (): void => {
			startCandidate(store, CANDIDATE_IDENTITY);
			expect(
				store.stageReviewCandidateDisplayEvent({
					event: reviewDisplayEvent(2, 'item-b', 1),
					identity: CANDIDATE_IDENTITY,
				}),
			).toBe(true);
		};

		// Act / Assert
		stage();
		expect(store.discardReviewCandidate(CANDIDATE_IDENTITY)).toBe(true);
		expect(store.getReviewRefreshPresentation().candidate).toBeNull();
		stage();
		store.prepareForWorkerReplacement();
		expect(store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: ACTIVE_IDENTITY,
			candidate: null,
			failure: null,
		});
		stage();
		store.dispose();
		expect(store.getReviewRefreshPresentation()).toEqual({
			activeIdentity: null,
			candidate: null,
			failure: null,
		});
		expect(store.promoteReviewCandidate(CANDIDATE_IDENTITY)).toBe(false);
	});

	test('retains only exact promoted failure facts and clears them on lifecycle boundaries', () => {
		const store = createBridgeMainRenderSnapshotStore();
		installReview(store, ACTIVE_IDENTITY, reviewDisplayEvent(1, 'item-a', 1));
		startCandidate(store, CANDIDATE_IDENTITY, []);
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(2, 'item-b', 1),
			identity: CANDIDATE_IDENTITY,
		});
		startCandidate(store, SUCCESSOR_IDENTITY, []);
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(3, 'item-c', 1),
			identity: SUCCESSOR_IDENTITY,
		});

		expect(store.failReviewCandidate({ identity: CANDIDATE_IDENTITY, retryable: true })).toBe(
			false,
		);
		expect(store.getReviewRefreshPresentation().candidate?.identity).toEqual(SUCCESSOR_IDENTITY);
		expect(store.failReviewCandidate({ identity: SUCCESSOR_IDENTITY, retryable: true })).toBe(true);
		expect(store.getReviewRefreshPresentation().failure).toBeNull();

		expect(
			store.startReviewCandidate({
				disposition: {
					affectedStableFileIdentities: [],
					kind: 'sameSource',
					presentationClass: { kind: 'promoted', reason: 'unknown' },
				},
				identity: SUCCESSOR_IDENTITY,
			}),
		).toBe(true);
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(3, 'item-c', 1),
			identity: SUCCESSOR_IDENTITY,
		});
		expect(store.failReviewCandidate({ identity: SUCCESSOR_IDENTITY, retryable: true })).toBe(true);
		expect(store.getReviewRefreshPresentation()).toMatchObject({
			activeIdentity: ACTIVE_IDENTITY,
			candidate: null,
			failure: {
				affectedStableFileIdentities: [],
				identity: SUCCESSOR_IDENTITY,
				presentationClass: { kind: 'promoted', reason: 'unknown' },
				retryable: true,
			},
		});
		expect(
			store.startReviewCandidate({
				disposition: sameSourceDisposition([]),
				identity: CANDIDATE_IDENTITY,
			}),
		).toBe(false);
		expect(store.getReviewRefreshPresentation().failure?.identity).toEqual(SUCCESSOR_IDENTITY);
		startCandidate(store, LATEST_IDENTITY);
		expect(store.getReviewRefreshPresentation().failure).toBeNull();
		expect(store.discardReviewCandidate(LATEST_IDENTITY)).toBe(true);
		expect(
			store.startReviewCandidate({
				disposition: {
					affectedStableFileIdentities: [],
					kind: 'sameSource',
					presentationClass: { kind: 'promoted', reason: 'unknown' },
				},
				identity: FINAL_IDENTITY,
			}),
		).toBe(true);
		store.stageReviewCandidateDisplayEvent({
			event: reviewDisplayEvent(5, 'item-e', 1),
			identity: FINAL_IDENTITY,
		});
		expect(store.failReviewCandidate({ identity: FINAL_IDENTITY, retryable: false })).toBe(true);

		store.prepareForWorkerReplacement();
		expect(store.getReviewRefreshPresentation().failure).toBeNull();
	});
});

function installReview(
	store: ReturnType<typeof createBridgeMainRenderSnapshotStore>,
	identity: BridgeMainReviewPublicationIdentity,
	event: BridgeWorkerReviewDisplayPatchEvent,
): void {
	expect(store.startReviewCandidate({ disposition: { kind: 'replacement' }, identity })).toBe(true);
	expect(store.stageReviewCandidateDisplayEvent({ event, identity })).toBe(true);
	expect(
		store.markReviewCandidateReady({
			identity,
			role: 'provisional',
		}),
	).toBe(true);
	expect(store.promoteReviewCandidate(identity)).toBe(true);
}

function startCandidate(
	store: ReturnType<typeof createBridgeMainRenderSnapshotStore>,
	identity: BridgeMainReviewPublicationIdentity,
	affectedStableFileIdentities: readonly string[] = [],
): void {
	expect(
		store.startReviewCandidate({
			disposition: sameSourceDisposition(affectedStableFileIdentities),
			identity,
		}),
	).toBe(true);
}

function sameSourceDisposition(
	affectedStableFileIdentities: readonly string[],
): BridgeWorkerReviewCandidateStartDisposition {
	return {
		affectedStableFileIdentities,
		kind: 'sameSource' as const,
		presentationClass: { kind: 'ordinary' as const },
	};
}

function reviewIdentity(
	generation: number,
	revision: number,
	publicationSuffix: string,
): BridgeMainReviewPublicationIdentity {
	return {
		generation,
		packageId: `package-${generation}`,
		publicationId: publicationId(publicationSuffix),
		revision,
		sourceIdentity: 'same-source',
	};
}

function sameLineageIdentity(
	revision: number,
	publicationSuffix: string,
): BridgeMainReviewPublicationIdentity {
	return {
		generation: 7,
		packageId: 'package-same-lineage',
		publicationId: publicationId(publicationSuffix),
		revision,
		sourceIdentity: 'source-same-lineage',
	};
}

function publicationId(suffix: string): string {
	return `00000000-0000-7000-8000-${suffix.padStart(12, '0')}`;
}

function reviewDisplayEvent(
	epoch: number,
	itemId: string,
	projectionRevision: number,
	reset = true,
): BridgeWorkerReviewDisplayPatchEvent {
	const identity =
		epoch === 1 ? ACTIVE_IDENTITY : epoch === 2 ? CANDIDATE_IDENTITY : SUCCESSOR_IDENTITY;
	return {
		direction: 'serverWorkerToMain',
		epoch,
		kind: 'reviewDisplayPatch',
		reviewPublicationIdentity: null,
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext(identity.packageId),
					metadataSourceId: identity.sourceIdentity,
					metadataWindowIdentity: `window-${identity.publicationId}`,
					packageId: identity.packageId,
					reviewGeneration: identity.generation,
					revision: identity.revision,
					status: 'ready',
					summary: {
						additions: 1,
						deletions: 1,
						filesChanged: 1,
						hiddenFileCount: 0,
						visibleFileCount: 1,
					},
					totalItemCount: reset ? 1 : 2,
					totalTreeRowCount: reset ? 1 : 2,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: [reviewDisplayItem(itemId)],
					operations: [],
					reset,
					startIndex: reset ? 0 : 1,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset,
					windows: [
						{
							rows: [
								{
									depth: 0,
									isDirectory: false,
									itemId,
									path: `${itemId}.ts`,
									rowId: `row-${itemId}`,
								},
							],
							startIndex: reset ? 0 : 1,
						},
					],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision,
		sequence: projectionRevision,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

function sameLineageDisplayEvent(
	identity: BridgeMainReviewPublicationIdentity,
	itemId: string,
	startIndex: number,
	reset: boolean,
): BridgeWorkerReviewDisplayPatchEvent {
	return {
		direction: 'serverWorkerToMain',
		epoch: identity.generation,
		kind: 'reviewDisplayPatch',
		patches: [
			{
				operation: 'upsert',
				payload: {
					...bridgeWorkerReviewSourceContext(identity.packageId),
					metadataSourceId: identity.sourceIdentity,
					metadataWindowIdentity: `window-${identity.publicationId}`,
					packageId: identity.packageId,
					reviewGeneration: identity.generation,
					revision: identity.revision,
					status: 'ready',
					summary: {
						additions: startIndex + 1,
						deletions: 0,
						filesChanged: startIndex + 1,
						hiddenFileCount: 0,
						visibleFileCount: startIndex + 1,
					},
					totalItemCount: startIndex + 1,
					totalTreeRowCount: startIndex + 1,
				},
				slice: 'reviewSource',
			},
			{
				operation: 'batch',
				payload: {
					items: [reviewDisplayItem(itemId)],
					operations: [],
					reset,
					startIndex,
				},
				slice: 'reviewItem',
			},
			{
				operation: 'batch',
				payload: {
					reset,
					windows: [
						{
							rows: [
								{
									depth: 0,
									isDirectory: false,
									itemId,
									path: `${itemId}.ts`,
									rowId: `row-${itemId}`,
								},
							],
							startIndex,
						},
					],
				},
				slice: 'reviewTree',
			},
		],
		projectionRevision: identity.revision,
		reviewPublicationIdentity: null,
		sequence: identity.revision,
		surface: 'review',
		transferDescriptors: [],
		wireVersion: BRIDGE_WORKER_WIRE_VERSION,
	};
}

function reviewDisplayItem(itemId: string): BridgeWorkerReviewDisplayItem {
	return {
		contentFacts: [],
		extentFacts: [],
		metadata: {
			additions: 1,
			deletions: 1,
			basePath: `${itemId}.ts`,
			changeKind: 'modified' as const,
			contentDescriptorIdsByRole: {},
			contentHashesByRole: {},
			contentRoles: [],
			extension: 'ts',
			fileClass: 'source' as const,
			headPath: `${itemId}.ts`,
			isHiddenByDefault: false,
			itemId,
			language: 'typescript',
			mimeTypes: ['text/typescript'],
			provenance: { agentSessionIds: [], operationIds: [], promptIds: [] },
			reviewPriority: 'normal' as const,
			reviewState: 'unreviewed' as const,
		},
		metadataWindowIdentity: `window-${itemId}`,
	};
}

function reviewCodeViewItem(itemId: string, displayPath: string): BridgeMainCodeViewItem {
	return {
		bridgeMetadata: {
			cacheKey: `cache-${itemId}`,
			contentRoles: ['head' as const],
			contentState: 'hydrated' as const,
			displayPath,
			itemId,
			lineCount: 1,
		},
		file: { cacheKey: `cache-${itemId}`, contents: 'export {};', name: displayPath },
		id: itemId,
		type: 'file' as const,
	};
}
