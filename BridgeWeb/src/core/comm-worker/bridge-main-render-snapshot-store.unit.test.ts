import { describe, expect, test } from 'vitest';

import {
	createBridgeMainRenderSnapshotStore,
	type BridgeMainCodeViewItem,
} from './bridge-main-render-snapshot-store.js';
import {
	makeBridgeMainCodeViewItem,
	makeReviewDisplayPatchEvent,
} from './bridge-main-render-snapshot-store.test-support.js';
import type { BridgeWorkerReviewDisplayItem } from './bridge-worker-contracts.js';

describe('Bridge main render snapshot store', () => {
	test('keeps selected Review content loading while worker replacement retires its old copy', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const item = makeBridgeMainCodeViewItem('item-selected');
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ item, itemId: item.id, operation: 'upsert' }],
			workerPatches: [
				{
					itemId: item.id,
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
			],
		});
		store.setLocalSelection({ selectedItemId: item.id, source: 'user' });

		// A replacement retires the render coordinator before the old copy is removed.
		store.prepareForWorkerReplacement();
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ itemId: item.id, operation: 'delete' }],
		});

		expect(store.getReviewAvailabilitySnapshot(item.id)).toEqual({ state: 'ready' });
		expect(store.hasPendingReviewPaintRelease(item.id)).toBe(true);
	});

	test('clears a replacement marker when the successor publication proves the old item is gone', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const item = makeBridgeMainCodeViewItem('item-removed');
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ item, itemId: item.id, operation: 'upsert' }],
		});
		store.prepareForWorkerReplacement();
		expect(store.hasPendingReviewPaintRelease(item.id)).toBe(true);

		store.applySnapshotUpdate({ codeViewItemPatches: [{ operation: 'reset' }] });

		expect(store.getReviewCodeViewItemSnapshot(item.id)).toBeUndefined();
		expect(store.hasPendingReviewPaintRelease(item.id)).toBe(false);
	});

	test('uses useSyncExternalStore and accepts only local intent plus worker patch writes', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const initialSnapshot = store.getSnapshot();
		let publishCount = 0;
		const unsubscribe = store.subscribe(() => {
			publishCount += 1;
		});

		expect(store.getSnapshot()).toBe(initialSnapshot);
		expect(store.getServerSnapshot()).toBe(initialSnapshot);

		store.setLocalSelection({ selectedItemId: 'item-1', source: 'user' });
		store.setLocalViewport({
			firstVisibleIndex: 0,
			lastVisibleIndex: 2,
			visibleItemIds: ['item-1', 'item-2', 'item-3'],
		});
		store.applyWorkerPatch({
			slice: 'selection',
			operation: 'upsert',
			payload: {
				selectedItemId: 'item-from-worker',
				source: 'keyboard',
			},
		});
		store.applyWorkerPatch({
			slice: 'viewport',
			operation: 'upsert',
			payload: {
				firstVisibleIndex: 1,
				lastVisibleIndex: 2,
				visibleItemIds: ['item-from-worker', 'item:2/path'],
			},
		});
		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'upsert',
			itemId: 'item:2/path',
			payload: {
				label: 'README.md',
				status: 'modified',
			},
		});
		store.applyWorkerPatch({
			slice: 'contentAvailability',
			operation: 'upsert',
			itemId: 'item:2/path',
			payload: {
				state: 'ready',
			},
		});

		const snapshot = store.getSnapshot();

		expect(snapshot.selectionSlice).toEqual({
			selectedItemId: 'item-from-worker',
			source: 'keyboard',
		});
		expect(snapshot.viewportSlice.visibleItemIds).toEqual(['item-from-worker', 'item:2/path']);
		expect(snapshot.rowPaintById['item:2/path']).toEqual({
			label: 'README.md',
			status: 'modified',
		});
		expect(snapshot.contentAvailabilityById['item:2/path']).toEqual({
			state: 'ready',
		});
		expect(JSON.stringify(snapshot)).not.toMatch(
			/workerDerivationEpoch|streamId|byteCache|demandMembership|retryAfterVersion|contentDescriptor|descriptorId|expectedSha256|leaseId|sourceCursor/i,
		);
		expect(publishCount).toBe(6);

		unsubscribe();
	});

	test('applies reset and delete worker patches without app-side payload parsing', () => {
		const store = createBridgeMainRenderSnapshotStore();

		store.applyWorkerPatch({
			slice: 'selection',
			operation: 'upsert',
			payload: {
				selectedItemId: 'item-1',
				source: 'user',
			},
		});
		store.applyWorkerPatch({
			slice: 'viewport',
			operation: 'upsert',
			payload: {
				firstVisibleIndex: 0,
				lastVisibleIndex: 1,
				visibleItemIds: ['item-1', 'item-2'],
			},
		});
		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'upsert',
			itemId: 'item-1',
			payload: {
				contentCacheKey: 'pierre-content:item-1',
			},
		});
		store.applyWorkerPatch({
			slice: 'contentAvailability',
			operation: 'upsert',
			itemId: 'item-1',
			payload: {
				state: 'ready',
			},
		});

		store.applyWorkerPatch({ slice: 'selection', operation: 'delete' });
		store.applyWorkerPatch({ slice: 'viewport', operation: 'reset' });
		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'delete',
			itemId: 'item-1',
		});
		store.applyWorkerPatch({ slice: 'contentAvailability', operation: 'reset' });

		expect(store.getSnapshot()).toMatchObject({
			selectionSlice: {
				selectedItemId: null,
				source: null,
			},
			viewportSlice: {
				firstVisibleIndex: 0,
				lastVisibleIndex: 0,
				visibleItemIds: [],
			},
			rowPaintById: {},
			contentAvailabilityById: {},
		});
	});

	test('drops deleted CodeView items while keeping them across row-paint resets', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const item = makeBridgeMainCodeViewItem('item-1');

		store.setWorkerCodeViewItem({ itemId: 'item-1', item });
		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'upsert',
			itemId: 'item-1',
			payload: {
				contentCacheKey: 'pierre-content:item-1',
			},
		});

		expect(store.getSnapshot().codeViewItemsById['item-1']).toBe(item);

		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'delete',
			itemId: 'item-1',
		});

		expect(store.getSnapshot().codeViewItemsById['item-1']).toBeUndefined();

		store.setWorkerCodeViewItem({ itemId: 'item-1', item });
		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'reset',
		});

		expect(store.getSnapshot().codeViewItemsById).toEqual({ 'item-1': item });
	});

	test('keeps CodeView display cache identity stable for row paint upserts', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const item = makeBridgeMainCodeViewItem('item-1');

		store.setWorkerCodeViewItem({ itemId: 'item-1', item });
		const beforeRowPaint = store.getSnapshot().codeViewItemsById;

		store.applyWorkerPatch({
			slice: 'rowPaint',
			operation: 'upsert',
			itemId: 'item-1',
			payload: {
				contentCacheKey: 'pierre-content:item-1',
				status: 'ready',
			},
		});

		const afterRowPaint = store.getSnapshot();
		expect(afterRowPaint.codeViewItemsById).toBe(beforeRowPaint);
		expect(afterRowPaint.codeViewItemsById['item-1']).toBe(item);
		expect(afterRowPaint.rowPaintById['item-1']).toEqual({
			contentCacheKey: 'pierre-content:item-1',
			status: 'ready',
		});
	});

	test('does not mutate previous snapshots for single CodeView item patches', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const item = makeBridgeMainCodeViewItem('item-1');
		const emptySnapshot = store.getSnapshot();

		store.setWorkerCodeViewItem({ itemId: 'item-1', item });
		const populatedSnapshot = store.getSnapshot();

		store.applySnapshotUpdate({
			codeViewItemPatches: [
				{
					operation: 'delete',
					itemId: 'item-1',
				},
			],
		});

		expect(emptySnapshot.codeViewItemsById['item-1']).toBeUndefined();
		expect(populatedSnapshot.codeViewItemsById['item-1']).toBe(item);
		expect(store.getSnapshot().codeViewItemsById['item-1']).toBeUndefined();
	});

	test('applies batched record patches without mutating previous snapshots', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const firstItem = makeBridgeMainCodeViewItem('item-1');
		const secondItem = makeBridgeMainCodeViewItem('item-2');
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ operation: 'upsert', itemId: 'item-1', item: firstItem }],
			workerPatches: [
				{
					slice: 'rowPaint',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { contentCacheKey: 'paint:item-1', status: 'ready' },
				},
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'ready' },
				},
			],
		});
		const previousSnapshot = store.getSnapshot();

		store.applySnapshotUpdate({
			codeViewItemPatches: [
				{ operation: 'upsert', itemId: 'item-2', item: secondItem },
				{ operation: 'delete', itemId: 'item-1' },
			],
			workerPatches: [
				{
					slice: 'rowPaint',
					operation: 'upsert',
					itemId: 'item-2',
					payload: { contentCacheKey: 'paint:item-2', status: 'ready' },
				},
				{ slice: 'rowPaint', operation: 'delete', itemId: 'item-1' },
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-2',
					payload: { state: 'ready' },
				},
				{ slice: 'contentAvailability', operation: 'delete', itemId: 'item-1' },
			],
		});

		expect(previousSnapshot.codeViewItemsById).toEqual({ 'item-1': firstItem });
		expect(previousSnapshot.rowPaintById).toEqual({
			'item-1': { contentCacheKey: 'paint:item-1', status: 'ready' },
		});
		expect(previousSnapshot.contentAvailabilityById).toEqual({
			'item-1': { state: 'ready' },
		});
		const nextSnapshot = store.getSnapshot();
		expect(nextSnapshot.codeViewItemsById).toEqual({ 'item-2': secondItem });
		expect(nextSnapshot.rowPaintById).toEqual({
			'item-2': { contentCacheKey: 'paint:item-2', status: 'ready' },
		});
		expect(nextSnapshot.contentAvailabilityById).toEqual({
			'item-2': { state: 'ready' },
		});
	});

	test('batches local selection, CodeView item, and worker patches into one publish', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const item = makeBridgeMainCodeViewItem('item-1');
		let publishCount = 0;
		const unsubscribe = store.subscribe(() => {
			publishCount += 1;
		});

		store.applySnapshotUpdate({
			localSelection: {
				selectedItemId: 'item-1',
				source: 'programmatic',
			},
			codeViewItemPatches: [
				{
					operation: 'upsert',
					itemId: 'item-1',
					item,
				},
			],
			workerPatches: [
				{
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: 'item-1',
					payload: { state: 'ready' },
				},
			],
		});

		expect(publishCount).toBe(1);
		expect(store.getSnapshot().selectionSlice).toEqual({
			selectedItemId: 'item-1',
			source: 'programmatic',
		});
		expect(store.getSnapshot().codeViewItemsById['item-1']).toBe(item);
		expect(store.getSnapshot().contentAvailabilityById['item-1']).toEqual({
			state: 'ready',
		});

		unsubscribe();
	});

	test('atomically applies bounded Review display state and rejects stale publications', () => {
		const store = createBridgeMainRenderSnapshotStore();
		const event = makeReviewDisplayPatchEvent();
		let publishCount = 0;
		const unsubscribe = store.subscribe(() => {
			publishCount += 1;
		});

		store.applyReviewDisplayPatchEvent(event);

		const acceptedSnapshot = store.getSnapshot();
		expect(publishCount).toBe(1);
		expect(acceptedSnapshot.reviewDisplayFreshness).toEqual({
			epoch: 2,
			projectionRevision: 3,
			sequence: 5,
		});
		expect(acceptedSnapshot.reviewSourceSlice).toMatchObject({
			baseEndpoint: { endpointId: 'package-1-base' },
			headEndpoint: { endpointId: 'package-1-head' },
			metadataWindowIdentity: 'metadata-window-package-1-r11',
			query: { queryId: 'package-1-query' },
			status: 'loading',
		});
		expect(acceptedSnapshot.reviewItemIdsByIndex).toEqual(['item-1']);
		expect(acceptedSnapshot.reviewItemById['item-1']?.metadata.headPath).toBe('Sources/App.swift');
		expect(acceptedSnapshot.reviewTreeRowsByIndex).toMatchObject([
			{ itemId: 'item-1', path: 'Sources/App.swift', rowId: 'row-item-1' },
		]);

		for (const staleEvent of [
			{ ...event, epoch: 1, projectionRevision: 99, sequence: 99 },
			{ ...event, projectionRevision: event.projectionRevision, sequence: 6 },
			{ ...event, projectionRevision: 4, sequence: event.sequence },
		]) {
			store.applyReviewDisplayPatchEvent(staleEvent);
			expect(store.getSnapshot()).toBe(acceptedSnapshot);
		}

		store.applyReviewDisplayPatchEvent({
			...event,
			epoch: 3,
			patches: [
				{
					operation: 'failed',
					payload: { error: 'metadataUnavailable', status: 'failed' },
					slice: 'reviewSource',
				},
			],
			projectionRevision: 1,
			sequence: 6,
		});
		expect(store.getSnapshot()).toMatchObject({
			reviewDisplayFreshness: { epoch: 3, projectionRevision: 1, sequence: 6 },
			reviewItemById: {},
			reviewItemIdsByIndex: [],
			reviewSourceSlice: { error: 'metadataUnavailable', status: 'failed' },
			reviewTreeRowsByIndex: [],
		});

		unsubscribe();
	});

	test('preserves local Review selection when a catalog reset reintroduces the selected item', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		const initialEvent = makeReviewDisplayPatchEvent();
		store.applyReviewDisplayPatchEvent(initialEvent);
		store.setLocalSelection({ selectedItemId: 'item-1', source: 'user' });

		// Act
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			projectionRevision: initialEvent.projectionRevision + 1,
			sequence: initialEvent.sequence + 1,
		});

		// Assert
		expect(store.getSnapshot().selectionSlice).toEqual({
			selectedItemId: 'item-1',
			source: 'user',
		});
	});

	test('retains hydrated Review render copies while a query projection hides and restores an item', () => {
		// Arrange
		const releasedPaintItemIds: string[] = [];
		const store = createBridgeMainRenderSnapshotStore({
			onReviewPaintedCopyReleased: (itemId): boolean => {
				releasedPaintItemIds.push(itemId);
				return true;
			},
		});
		const initialEvent = makeReviewDisplayPatchEvent();
		const initialSourcePatch = initialEvent.patches[0];
		const initialItemPatch = initialEvent.patches[1];
		const initialTreePatch = initialEvent.patches[2];
		if (initialItemPatch?.slice !== 'reviewItem' || initialItemPatch.operation !== 'batch') {
			throw new Error('expected Review fixture item batch');
		}
		if (
			initialSourcePatch?.slice !== 'reviewSource' ||
			initialSourcePatch.operation !== 'upsert' ||
			initialTreePatch?.slice !== 'reviewTree'
		) {
			throw new Error('expected Review fixture source and tree patches');
		}
		const initialCatalogItem = initialItemPatch.payload.items[0];
		const initialPublicationIdentity = initialEvent.reviewPublicationIdentity;
		if (initialCatalogItem === undefined) {
			throw new Error('expected Review fixture item');
		}
		if (initialPublicationIdentity === null) {
			throw new Error('expected Review fixture publication identity');
		}
		const activeIdentity = {
			generation: initialPublicationIdentity.reviewGeneration,
			packageId: initialPublicationIdentity.packageId,
			publicationId: initialPublicationIdentity.publicationId,
			revision: initialPublicationIdentity.revision,
			sourceIdentity: initialPublicationIdentity.sourceIdentity,
		};
		const hydratedCatalogItem: BridgeWorkerReviewDisplayItem = {
			...initialCatalogItem,
			contentFacts: [
				{
					contentDigest: {
						algorithm: 'sha256',
						authority: 'authoritative',
						value: 'a'.repeat(64),
					},
					role: 'file',
					semanticDocumentRevision: 'semantic-item-1',
				},
			],
			metadata: {
				...initialCatalogItem.metadata,
				contentDescriptorIdsByRole: { file: 'descriptor-item-1' },
				contentRoles: ['file'],
			},
		};
		const populatedItemPatch = {
			...initialItemPatch,
			payload: { ...initialItemPatch.payload, items: [hydratedCatalogItem] },
		} as const;
		expect(
			store.startReviewCandidate({
				disposition: { kind: 'replacement' },
				identity: activeIdentity,
			}),
		).toBe(true);
		expect(
			store.stageReviewCandidateDisplayEvent({
				event: {
					...initialEvent,
					patches: [
						{ ...initialSourcePatch, payload: { ...initialSourcePatch.payload, status: 'ready' } },
						populatedItemPatch,
						initialTreePatch,
					],
				},
				identity: activeIdentity,
			}),
		).toBe(true);
		expect(store.markReviewCandidateReady({ identity: activeIdentity, role: 'provisional' })).toBe(
			true,
		);
		expect(store.promoteReviewCandidate(activeIdentity)).toBe(true);
		const codeViewItem = makeBridgeMainCodeViewItem('item-1');
		const rowPaint = { contentCacheKey: 'pierre-content:item-1', status: 'ready' } as const;
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ operation: 'upsert', itemId: 'item-1', item: codeViewItem }],
			workerPatches: [
				{
					itemId: 'item-1',
					operation: 'upsert',
					payload: rowPaint,
					slice: 'rowPaint',
				},
				{
					itemId: 'item-1',
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
			],
		});
		store.setLocalSelection({ selectedItemId: 'item-1', source: 'user' });

		// Act: query-only display publications carry no source publication identity.
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				initialSourcePatch,
				{
					...populatedItemPatch,
					payload: { ...populatedItemPatch.payload, items: [] },
				},
				initialTreePatch,
			],
			projectionRevision: initialEvent.projectionRevision + 1,
			reviewPublicationIdentity: null,
			sequence: initialEvent.sequence + 1,
		});

		// Assert
		const hiddenSnapshot = store.getSnapshot();
		expect(hiddenSnapshot.reviewItemById['item-1']).toBeUndefined();
		expect(hiddenSnapshot.selectionSlice).toEqual({ selectedItemId: null, source: null });
		expect(hiddenSnapshot.codeViewItemsById['item-1']).toBe(codeViewItem);
		expect(hiddenSnapshot.contentAvailabilityById['item-1']).toEqual({ state: 'ready' });
		expect(hiddenSnapshot.rowPaintById['item-1']).toEqual(rowPaint);

		// Act
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [initialSourcePatch, populatedItemPatch, initialTreePatch],
			projectionRevision: initialEvent.projectionRevision + 2,
			reviewPublicationIdentity: null,
			sequence: initialEvent.sequence + 2,
		});

		// Assert
		const restoredSnapshot = store.getSnapshot();
		expect(restoredSnapshot.reviewItemById['item-1']).toEqual(hydratedCatalogItem);
		expect(restoredSnapshot.codeViewItemsById['item-1']).toBe(codeViewItem);
		expect(restoredSnapshot.contentAvailabilityById['item-1']).toEqual({ state: 'ready' });
		expect(restoredSnapshot.rowPaintById['item-1']).toEqual(rowPaint);

		// A sealed filter projection names the same immutable publication instead of null.
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				initialSourcePatch,
				{
					...populatedItemPatch,
					payload: { ...populatedItemPatch.payload, items: [] },
				},
				initialTreePatch,
			],
			projectionRevision: initialEvent.projectionRevision + 3,
			reviewPublicationIdentity: initialPublicationIdentity,
			sequence: initialEvent.sequence + 3,
		});
		expect(store.getSnapshot().reviewItemById['item-1']).toBeUndefined();
		expect(store.getSnapshot().codeViewItemsById['item-1']).toBe(codeViewItem);
		expect(store.getSnapshot().contentAvailabilityById['item-1']).toEqual({ state: 'ready' });
		expect(releasedPaintItemIds).toEqual([]);
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [initialSourcePatch, populatedItemPatch, initialTreePatch],
			projectionRevision: initialEvent.projectionRevision + 4,
			reviewPublicationIdentity: initialPublicationIdentity,
			sequence: initialEvent.sequence + 4,
		});
		expect(store.getSnapshot().codeViewItemsById['item-1']).toBe(codeViewItem);
		expect(store.getSnapshot().contentAvailabilityById['item-1']).toEqual({ state: 'ready' });

		// Act: hide the item again, then accept a same-epoch source publication while it is absent.
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				initialSourcePatch,
				{
					...populatedItemPatch,
					payload: { ...populatedItemPatch.payload, items: [] },
				},
				initialTreePatch,
			],
			projectionRevision: initialEvent.projectionRevision + 5,
			reviewPublicationIdentity: null,
			sequence: initialEvent.sequence + 5,
		});
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				initialSourcePatch,
				{
					...populatedItemPatch,
					payload: { ...populatedItemPatch.payload, items: [] },
				},
				initialTreePatch,
			],
			projectionRevision: initialEvent.projectionRevision + 6,
			reviewPublicationIdentity: {
				...initialPublicationIdentity,
				publicationId: '00000000-0000-7000-8000-000000000002',
			},
			sequence: initialEvent.sequence + 6,
		});

		// Assert
		const sameEpochSourceSnapshot = store.getSnapshot();
		expect(sameEpochSourceSnapshot.codeViewItemsById['item-1']).toBeUndefined();
		expect(sameEpochSourceSnapshot.contentAvailabilityById['item-1']).toBeUndefined();
		expect(sameEpochSourceSnapshot.rowPaintById['item-1']).toBeUndefined();
		expect(releasedPaintItemIds).toEqual(['item-1']);
		expect(store.hasPendingReviewPaintRelease('item-1')).toBe(true);

		// Arrange: an off-catalog retained copy must also be purged by an epoch replacement.
		store.applySnapshotUpdate({
			codeViewItemPatches: [{ operation: 'upsert', itemId: 'item-1', item: codeViewItem }],
			workerPatches: [
				{
					itemId: 'item-1',
					operation: 'upsert',
					payload: rowPaint,
					slice: 'rowPaint',
				},
				{
					itemId: 'item-1',
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
			],
		});
		expect(store.hasPendingReviewPaintRelease('item-1')).toBe(false);

		// Act
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			epoch: initialEvent.epoch + 1,
			patches: [
				initialSourcePatch,
				{
					...populatedItemPatch,
					payload: { ...populatedItemPatch.payload, items: [] },
				},
				initialTreePatch,
			],
			projectionRevision: 1,
			reviewPublicationIdentity: {
				...initialPublicationIdentity,
				publicationId: '00000000-0000-7000-8000-000000000003',
			},
			sequence: initialEvent.sequence + 7,
		});

		// Assert
		const replacedSourceSnapshot = store.getSnapshot();
		expect(replacedSourceSnapshot.codeViewItemsById['item-1']).toBeUndefined();
		expect(replacedSourceSnapshot.contentAvailabilityById['item-1']).toBeUndefined();
		expect(replacedSourceSnapshot.rowPaintById['item-1']).toBeUndefined();
	});

	test('preserves unchanged ready Review render copies while invalidating removed or semantically changed copies', () => {
		// Arrange
		const store = createBridgeMainRenderSnapshotStore();
		const initialEvent = makeReviewDisplayPatchEvent();
		const initialItemPatch = initialEvent.patches[1];
		if (initialItemPatch?.slice !== 'reviewItem' || initialItemPatch.operation !== 'batch') {
			throw new Error('expected Review fixture item batch');
		}
		const initialCatalogItem = initialItemPatch.payload.items[0];
		if (initialCatalogItem === undefined) {
			throw new Error('expected retained Review fixture item');
		}
		const retainedCatalogItem: BridgeWorkerReviewDisplayItem = {
			...initialCatalogItem,
			contentFacts: [
				{
					contentDigest: {
						algorithm: 'sha256',
						authority: 'authoritative',
						value: 'a'.repeat(64),
					},
					role: 'file',
					semanticDocumentRevision: 'semantic-item-1',
				},
			],
			metadata: {
				...initialCatalogItem.metadata,
				contentDescriptorIdsByRole: { file: 'descriptor-item-1-a' },
				contentRoles: ['file'],
			},
		};
		const removedCatalogItem: BridgeWorkerReviewDisplayItem = {
			...retainedCatalogItem,
			metadata: {
				...retainedCatalogItem.metadata,
				basePath: 'Sources/Removed.swift',
				headPath: 'Sources/Removed.swift',
				itemId: 'item-removed',
			},
			metadataWindowIdentity: 'metadata-window-item-removed-r11',
		};
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				{
					...initialItemPatch,
					payload: {
						...initialItemPatch.payload,
						items: [retainedCatalogItem, removedCatalogItem],
					},
				},
			],
		});
		const retainedCodeViewItem: BridgeMainCodeViewItem = {
			...makeBridgeMainCodeViewItem('item-1'),
			bridgeMetadata: {
				...makeBridgeMainCodeViewItem('item-1').bridgeMetadata,
				sourceDescriptorIdsByRole: {
					base: null,
					diff: null,
					file: 'descriptor-item-1-a',
					head: null,
				},
			},
		};
		const removedCodeViewItem = makeBridgeMainCodeViewItem('item-removed');
		const retainedRowPaint = {
			contentCacheKey: 'pierre-content:item-1',
			status: 'ready',
		};
		store.applySnapshotUpdate({
			codeViewItemPatches: [
				{ operation: 'upsert', itemId: 'item-1', item: retainedCodeViewItem },
				{ operation: 'upsert', itemId: 'item-removed', item: removedCodeViewItem },
			],
			workerPatches: [
				{
					itemId: 'item-1',
					operation: 'upsert',
					payload: retainedRowPaint,
					slice: 'rowPaint',
				},
				{
					itemId: 'item-1',
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
				{
					itemId: 'item-removed',
					operation: 'upsert',
					payload: { contentCacheKey: 'pierre-content:item-removed', status: 'ready' },
					slice: 'rowPaint',
				},
				{
					itemId: 'item-removed',
					operation: 'upsert',
					payload: { state: 'ready' },
					slice: 'contentAvailability',
				},
			],
		});
		const addedCatalogItem: BridgeWorkerReviewDisplayItem = {
			...retainedCatalogItem,
			metadata: {
				...retainedCatalogItem.metadata,
				basePath: 'Sources/Added.swift',
				headPath: 'Sources/Added.swift',
				itemId: 'item-added',
			},
			metadataWindowIdentity: 'metadata-window-item-added-r12',
		};
		const changedRetainedCatalogItem: BridgeWorkerReviewDisplayItem = {
			...retainedCatalogItem,
			contentFacts: [
				{
					contentDigest: {
						algorithm: 'sha256',
						authority: 'authoritative',
						value: 'b'.repeat(64),
					},
					role: 'file',
					semanticDocumentRevision: 'semantic-item-1-changed',
				},
			],
		};

		// Act
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				{
					...initialItemPatch,
					payload: {
						...initialItemPatch.payload,
						items: [retainedCatalogItem, addedCatalogItem],
					},
				},
			],
			projectionRevision: initialEvent.projectionRevision + 1,
			sequence: initialEvent.sequence + 1,
		});

		// Assert
		const snapshot = store.getSnapshot();
		expect(snapshot.reviewItemIdsByIndex).toEqual(['item-1', 'item-added']);
		expect(snapshot.codeViewItemsById['item-1']).toBe(retainedCodeViewItem);
		expect(snapshot.contentAvailabilityById['item-1']).toEqual({ state: 'ready' });
		expect(snapshot.rowPaintById['item-1']).toEqual(retainedRowPaint);
		expect(snapshot.codeViewItemsById['item-removed']).toBeUndefined();
		expect(snapshot.contentAvailabilityById['item-removed']).toBeUndefined();
		expect(snapshot.rowPaintById['item-removed']).toBeUndefined();

		// Act: identical content retained under a successor descriptor must carry successor
		// source authority before a newly opened annotation composer captures its origin.
		const successorDescriptorCatalogItem: BridgeWorkerReviewDisplayItem = {
			...retainedCatalogItem,
			metadata: {
				...retainedCatalogItem.metadata,
				contentDescriptorIdsByRole: { file: 'descriptor-item-1-b' },
			},
			metadataWindowIdentity: 'metadata-window-item-1-successor-r13',
		};
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				{
					...initialItemPatch,
					payload: {
						...initialItemPatch.payload,
						items: [successorDescriptorCatalogItem, addedCatalogItem],
					},
				},
			],
			projectionRevision: initialEvent.projectionRevision + 2,
			sequence: initialEvent.sequence + 2,
		});

		// Assert
		const successorDescriptorCodeViewItem = store.getSnapshot().codeViewItemsById['item-1'];
		expect(successorDescriptorCodeViewItem).not.toBe(retainedCodeViewItem);
		expect(successorDescriptorCodeViewItem?.bridgeMetadata.sourceDescriptorIdsByRole).toEqual({
			base: null,
			diff: null,
			file: 'descriptor-item-1-b',
			head: null,
		});

		// Act: unchanged complete content is retained while its same-epoch display path changes.
		const renamedRetainedCatalogItem: BridgeWorkerReviewDisplayItem = {
			...retainedCatalogItem,
			metadata: {
				...retainedCatalogItem.metadata,
				basePath: 'Sources/Renamed.swift',
				headPath: 'Sources/Renamed.swift',
			},
			metadataWindowIdentity: 'metadata-window-item-1-renamed-r13',
		};
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				{
					...initialItemPatch,
					payload: {
						...initialItemPatch.payload,
						items: [renamedRetainedCatalogItem, addedCatalogItem],
					},
				},
			],
			projectionRevision: initialEvent.projectionRevision + 3,
			sequence: initialEvent.sequence + 3,
		});

		// Assert
		const renamedSnapshot = store.getSnapshot();
		const renamedCodeViewItem = renamedSnapshot.codeViewItemsById['item-1'];
		expect(renamedCodeViewItem).not.toBe(retainedCodeViewItem);
		expect(renamedCodeViewItem).toMatchObject({
			bridgeMetadata: {
				contentState: 'hydrated',
				displayPath: 'Sources/Renamed.swift',
			},
			file: {
				contents: retainedCodeViewItem.type === 'file' ? retainedCodeViewItem.file.contents : '',
				name: 'Sources/Renamed.swift',
			},
			type: 'file',
		});
		expect(renamedCodeViewItem?.version).toBeGreaterThan(retainedCodeViewItem.version ?? 0);
		expect(renamedSnapshot.contentAvailabilityById['item-1']).toEqual({ state: 'ready' });
		expect(renamedSnapshot.rowPaintById['item-1']).toEqual(retainedRowPaint);

		// Act: the same catalog identity now names different authoritative content.
		store.applyReviewDisplayPatchEvent({
			...initialEvent,
			patches: [
				{
					...initialItemPatch,
					payload: {
						...initialItemPatch.payload,
						items: [
							{
								...changedRetainedCatalogItem,
								metadata: renamedRetainedCatalogItem.metadata,
							},
							addedCatalogItem,
						],
					},
				},
			],
			projectionRevision: initialEvent.projectionRevision + 4,
			sequence: initialEvent.sequence + 4,
		});

		// Assert
		expect(store.getSnapshot().codeViewItemsById['item-1']).toBeUndefined();
		expect(store.getSnapshot().contentAvailabilityById['item-1']).toBeUndefined();
		expect(store.getSnapshot().rowPaintById['item-1']).toBeUndefined();
	});
});
