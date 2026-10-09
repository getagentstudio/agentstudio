import type {
	BridgeMainReviewCatalogChange,
	BridgeMainReviewCatalogOrderMutation,
	BridgeMainReviewCatalogSnapshot,
	BridgeMainReviewSourceDisplaySlice,
	BridgeMainReviewTreeDisplayRow,
} from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeWorkerReviewDisplayItem } from '../core/comm-worker/bridge-worker-contracts.js';
import type { ReviewTreeRowMetadata } from '../features/review/models/review-protocol-models.js';
import {
	createBridgeReviewItemRegistry,
	type BridgeReviewItemRegistry,
} from '../foundation/review-package/bridge-review-item-registry.js';
import type {
	BridgeReviewItemDescriptor,
	BridgeReviewPackage,
} from '../foundation/review-package/bridge-review-package.js';
import type {
	BridgeReviewFacetCounts,
	BridgeReviewProjectionResult,
} from '../review-viewer/models/review-projection-models.js';
import type { BridgeReviewDirectDisplayStore } from './bridge-app-review-render-snapshot-controller.js';

export interface BridgeReviewPresentationSnapshot {
	readonly presentationKey: string;
	readonly presentationRegistry: BridgeReviewItemRegistry;
	readonly projection: BridgeReviewProjectionResult;
	readonly reviewPackage: BridgeReviewPackage;
	readonly reviewTreeRows: readonly ReviewTreeRowMetadata[];
}

type BridgeReviewSourceUpsertDisplaySlice = Exclude<
	BridgeMainReviewSourceDisplaySlice,
	{ readonly status: 'failed' | 'readyEmpty' }
>;

type BridgePresentableReviewSourceDisplaySlice = Omit<
	BridgeReviewSourceUpsertDisplaySlice,
	| 'baseEndpoint'
	| 'headEndpoint'
	| 'query'
	| 'status'
	| 'summary'
	| 'totalItemCount'
	| 'totalTreeRowCount'
> & {
	readonly baseEndpoint: NonNullable<BridgeReviewSourceUpsertDisplaySlice['baseEndpoint']>;
	readonly headEndpoint: NonNullable<BridgeReviewSourceUpsertDisplaySlice['headEndpoint']>;
	readonly query: NonNullable<BridgeReviewSourceUpsertDisplaySlice['query']>;
	readonly status: 'ready' | 'stale';
	readonly summary: NonNullable<BridgeReviewSourceUpsertDisplaySlice['summary']>;
	readonly totalItemCount: number;
	readonly totalTreeRowCount: number;
};

interface BridgeReviewPresentationLedger {
	catalogCursor: number;
	epoch: number | null;
	readonly itemIdsByIndex: Array<string | null>;
	readonly rawItemsById: Map<string, BridgeWorkerReviewDisplayItem>;
	reviewGeneration: number;
	snapshot: BridgeReviewPresentationSnapshot;
	readonly treeRowsByIndex: Array<ReviewTreeRowMetadata | null>;
}

interface BridgeReviewItemProjectionUpdates {
	readonly availableContentRolesByItemId: Map<
		string,
		BridgeReviewProjectionResult['availableContentRolesByItemId'][string] | undefined
	>;
	readonly candidatePathsByItemId: Map<string, readonly string[] | undefined>;
	readonly itemIdsByDisplayPath: Map<string, readonly string[] | undefined>;
	readonly itemsById: Map<string, BridgeReviewItemDescriptor | undefined>;
	readonly primaryDisplayPathByItemId: Map<string, string | undefined>;
	readonly secondaryItemIdsByTreePath: Map<string, readonly string[] | undefined>;
}

interface BridgeReviewTreeProjectionUpdates {
	readonly primaryItemIdByTreePath: Map<string, string | undefined>;
}

const presentationLedgerByDisplayStore = new WeakMap<
	BridgeReviewDirectDisplayStore,
	BridgeReviewPresentationLedger
>();

export function bridgeReviewPresentationSnapshotForDisplay(props: {
	readonly catalogSnapshot: BridgeMainReviewCatalogSnapshot;
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly reviewSourceSlice: BridgeMainReviewSourceDisplaySlice | null;
}): BridgeReviewPresentationSnapshot | null {
	const reviewSourceSlice = props.reviewSourceSlice;
	if (!isPresentableReviewSourceDisplaySlice(reviewSourceSlice)) return null;
	const previousLedger = presentationLedgerByDisplayStore.get(props.displayStore);
	if (
		previousLedger === undefined ||
		previousLedger.epoch !== props.catalogSnapshot.epoch ||
		previousLedger.reviewGeneration !== reviewSourceSlice.reviewGeneration
	) {
		return rebuildBridgeReviewPresentationLedger({
			catalogSnapshot: props.catalogSnapshot,
			displayStore: props.displayStore,
			reviewSourceSlice,
		});
	}
	const catalogChanges = props.displayStore.readReviewCatalogChangesAfter(
		previousLedger.catalogCursor,
	);
	if (
		catalogChanges.resetRequired ||
		catalogChanges.changes.some((change): boolean => change.reset)
	) {
		return rebuildBridgeReviewPresentationLedger({
			catalogSnapshot: props.catalogSnapshot,
			displayStore: props.displayStore,
			reviewSourceSlice,
		});
	}
	if (catalogChanges.changes.length === 0) {
		return previousLedger.snapshot;
	}
	const snapshot = applyBridgeReviewPresentationChanges({
		catalogSnapshot: props.catalogSnapshot,
		changes: catalogChanges.changes,
		displayStore: props.displayStore,
		ledger: previousLedger,
		reviewSourceSlice,
	});
	previousLedger.catalogCursor = props.catalogSnapshot.changeCursor;
	previousLedger.snapshot = snapshot;
	return snapshot;
}

function rebuildBridgeReviewPresentationLedger(props: {
	readonly catalogSnapshot: BridgeMainReviewCatalogSnapshot;
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly reviewSourceSlice: BridgePresentableReviewSourceDisplaySlice;
}): BridgeReviewPresentationSnapshot | null {
	const orderedDisplayItems = orderedReviewDisplayItems(props);
	const reviewTreeRows = orderedReviewTreeRows(props);
	if (
		orderedDisplayItems.length !== props.catalogSnapshot.itemOrderLength ||
		reviewTreeRows.length !== props.catalogSnapshot.treeRowOrderLength
	) {
		return null;
	}
	const orderedItemIds = orderedDisplayItems.map((item) => item.metadata.itemId);
	const itemsById = Object.fromEntries(
		orderedDisplayItems.map((item) => [
			item.metadata.itemId,
			presentationItemForDisplay(item, props.catalogSnapshot.revision),
		]),
	);
	const presentationKey = JSON.stringify([
		'bridge-review-presentation-v4',
		props.catalogSnapshot.epoch ?? 0,
		props.reviewSourceSlice.reviewGeneration,
	]);
	const reviewPackage = presentationPackageForDisplay({
		itemsById,
		orderedItemIds,
		presentationKey,
		reviewGeneration: props.reviewSourceSlice.reviewGeneration,
		reviewSourceSlice: props.reviewSourceSlice,
		revision: props.reviewSourceSlice.revision,
	});
	const projection = presentationProjectionForDisplay({
		orderedDisplayItems,
		presentationKey,
		reviewTreeRows,
	});
	const snapshot: BridgeReviewPresentationSnapshot = {
		presentationKey,
		presentationRegistry: createBridgeReviewItemRegistry({ reviewPackage }),
		projection,
		reviewPackage,
		reviewTreeRows,
	};
	presentationLedgerByDisplayStore.set(props.displayStore, {
		catalogCursor: props.catalogSnapshot.changeCursor,
		epoch: props.catalogSnapshot.epoch,
		itemIdsByIndex: orderedItemIds.map((itemId) => itemId),
		rawItemsById: new Map(orderedDisplayItems.map((item) => [item.metadata.itemId, item])),
		reviewGeneration: props.reviewSourceSlice.reviewGeneration,
		snapshot,
		treeRowsByIndex: reviewTreeRows.map((row) => row),
	});
	return snapshot;
}

function applyBridgeReviewPresentationChanges(props: {
	readonly catalogSnapshot: BridgeMainReviewCatalogSnapshot;
	readonly changes: readonly BridgeMainReviewCatalogChange[];
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly ledger: BridgeReviewPresentationLedger;
	readonly reviewSourceSlice: BridgePresentableReviewSourceDisplaySlice;
}): BridgeReviewPresentationSnapshot {
	const previousSnapshot = props.ledger.snapshot;
	const itemProjectionUpdates = emptyBridgeReviewItemProjectionUpdates();
	const treeProjectionUpdates = emptyBridgeReviewTreeProjectionUpdates();
	const affectedItemIds = new Set<string>();
	const affectedTreeRowPaths = new Set<string>();
	for (const change of props.changes) {
		for (const itemId of change.itemIds) affectedItemIds.add(itemId);
		applyItemOrderMutations({
			affectedItemIds,
			displayStore: props.displayStore,
			itemIdsByIndex: props.ledger.itemIdsByIndex,
			mutations: change.itemOrderMutations,
		});
		applyTreeRowOrderMutations({
			affectedTreeRowPaths,
			displayStore: props.displayStore,
			mutations: change.treeRowOrderMutations,
			treeRowsByIndex: props.ledger.treeRowsByIndex,
		});
	}
	const nextFacetCounts = cloneFacetCounts(previousSnapshot.projection.facetCounts);
	for (const itemId of affectedItemIds) {
		const previousRawItem = props.ledger.rawItemsById.get(itemId);
		if (previousRawItem !== undefined) {
			removeItemProjectionFacts({
				facetCounts: nextFacetCounts,
				item: previousRawItem,
				previousProjection: previousSnapshot.projection,
				updates: itemProjectionUpdates,
			});
		}
		if (!props.displayStore.reviewCatalogContainsItem(itemId)) {
			props.ledger.rawItemsById.delete(itemId);
			itemProjectionUpdates.itemsById.set(itemId, undefined);
			continue;
		}
		const nextRawItem = props.displayStore.getReviewItemSnapshot(itemId);
		if (nextRawItem === undefined) continue;
		props.ledger.rawItemsById.set(itemId, nextRawItem);
		itemProjectionUpdates.itemsById.set(
			itemId,
			presentationItemForDisplay(nextRawItem, props.catalogSnapshot.revision),
		);
		addItemProjectionFacts({
			facetCounts: nextFacetCounts,
			item: nextRawItem,
			previousProjection: previousSnapshot.projection,
			updates: itemProjectionUpdates,
		});
	}
	const orderedItemIds = props.ledger.itemIdsByIndex.filter(
		(itemId): itemId is string => itemId !== null,
	);
	const reviewTreeRows = props.ledger.treeRowsByIndex.filter(
		(row): row is ReviewTreeRowMetadata => row !== null,
	);
	const orderedItemRankByItemId = incrementalOrderedItemRanks({
		changes: props.changes,
		orderedItemIds,
		previousRanks: previousSnapshot.projection.orderedItemRankByItemId ?? {},
	});
	const treeProjection = incrementalTreeProjection({
		affectedTreeRowPaths,
		previousProjection: previousSnapshot.projection,
		reviewTreeRows,
		updates: treeProjectionUpdates,
	});
	const reviewPackage: BridgeReviewPackage = {
		...previousSnapshot.reviewPackage,
		itemsById: patchReadonlyRecord(
			previousSnapshot.reviewPackage.itemsById,
			itemProjectionUpdates.itemsById,
		),
		orderedItemIds,
		revision: props.reviewSourceSlice.revision,
		summary: props.reviewSourceSlice.summary,
	};
	const projection: BridgeReviewProjectionResult = {
		...previousSnapshot.projection,
		availableContentRolesByItemId: patchReadonlyRecord(
			previousSnapshot.projection.availableContentRolesByItemId,
			itemProjectionUpdates.availableContentRolesByItemId,
		),
		candidatePathsByItemId: patchReadonlyRecord(
			previousSnapshot.projection.candidatePathsByItemId,
			itemProjectionUpdates.candidatePathsByItemId,
		),
		facetCounts: nextFacetCounts,
		itemIdsByDisplayPath: patchReadonlyRecord(
			previousSnapshot.projection.itemIdsByDisplayPath,
			itemProjectionUpdates.itemIdsByDisplayPath,
		),
		orderedItemIds,
		orderedItemRankByItemId,
		orderedPaths: treeProjection.orderedPaths,
		primaryDisplayPathByItemId: patchReadonlyRecord(
			previousSnapshot.projection.primaryDisplayPathByItemId,
			itemProjectionUpdates.primaryDisplayPathByItemId,
		),
		primaryItemIdByTreePath: patchReadonlyRecord(
			previousSnapshot.projection.primaryItemIdByTreePath,
			treeProjectionUpdates.primaryItemIdByTreePath,
		),
		secondaryItemIdsByTreePath: patchReadonlyRecord(
			previousSnapshot.projection.secondaryItemIdsByTreePath,
			itemProjectionUpdates.secondaryItemIdsByTreePath,
		),
	};
	return {
		presentationKey: previousSnapshot.presentationKey,
		presentationRegistry: incrementalPresentationRegistry({
			affectedItemIds,
			previousRegistry: previousSnapshot.presentationRegistry,
			reviewPackage,
		}),
		projection,
		reviewPackage,
		reviewTreeRows,
	};
}

function applyItemOrderMutations(props: {
	readonly affectedItemIds: Set<string>;
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly itemIdsByIndex: Array<string | null>;
	readonly mutations: readonly BridgeMainReviewCatalogOrderMutation[];
}): void {
	for (const mutation of props.mutations) {
		switch (mutation.kind) {
			case 'replace':
				for (const itemId of props.itemIdsByIndex) {
					if (itemId !== null) props.affectedItemIds.add(itemId);
				}
				props.itemIdsByIndex.length = mutation.length;
				for (let itemIndex = 0; itemIndex < mutation.length; itemIndex += 1) {
					const itemId = props.displayStore.getReviewItemIdAtIndex(itemIndex) ?? null;
					props.itemIdsByIndex[itemIndex] = itemId;
					if (itemId !== null) props.affectedItemIds.add(itemId);
				}
				break;
			case 'setRange':
				for (let offset = 0; offset < mutation.length; offset += 1) {
					const itemIndex = mutation.startIndex + offset;
					const previousItemId = props.itemIdsByIndex[itemIndex] ?? null;
					if (previousItemId !== null) props.affectedItemIds.add(previousItemId);
					const itemId = props.displayStore.getReviewItemIdAtIndex(itemIndex) ?? null;
					props.itemIdsByIndex[itemIndex] = itemId;
					if (itemId !== null) props.affectedItemIds.add(itemId);
				}
				break;
			case 'splice':
				throw new Error('Review item order does not support splice catalog mutations.');
			default:
				assertNeverCatalogOrderMutation(mutation);
		}
	}
}

function applyTreeRowOrderMutations(props: {
	readonly affectedTreeRowPaths: Set<string>;
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly mutations: readonly BridgeMainReviewCatalogOrderMutation[];
	readonly treeRowsByIndex: Array<ReviewTreeRowMetadata | null>;
}): void {
	for (const mutation of props.mutations) {
		switch (mutation.kind) {
			case 'replace': {
				for (const row of props.treeRowsByIndex) {
					if (row !== null) props.affectedTreeRowPaths.add(row.path);
				}
				props.treeRowsByIndex.length = mutation.length;
				for (let rowIndex = 0; rowIndex < mutation.length; rowIndex += 1) {
					const row = reviewTreeRowForDisplay(props.displayStore.getReviewTreeRowAtIndex(rowIndex));
					props.treeRowsByIndex[rowIndex] = row;
					if (row !== null) props.affectedTreeRowPaths.add(row.path);
				}
				break;
			}
			case 'setRange':
				for (let offset = 0; offset < mutation.length; offset += 1) {
					const rowIndex = mutation.startIndex + offset;
					const previousRow = props.treeRowsByIndex[rowIndex] ?? null;
					if (previousRow !== null) props.affectedTreeRowPaths.add(previousRow.path);
					const row = reviewTreeRowForDisplay(props.displayStore.getReviewTreeRowAtIndex(rowIndex));
					props.treeRowsByIndex[rowIndex] = row;
					if (row !== null) props.affectedTreeRowPaths.add(row.path);
				}
				break;
			case 'splice': {
				const removedRows = props.treeRowsByIndex.slice(
					mutation.startIndex,
					mutation.startIndex + mutation.deleteCount,
				);
				for (const row of removedRows) {
					if (row !== null) props.affectedTreeRowPaths.add(row.path);
				}
				const insertedRows = Array.from({ length: mutation.insertCount }, (_, offset) =>
					reviewTreeRowForDisplay(
						props.displayStore.getReviewTreeRowAtIndex(mutation.startIndex + offset),
					),
				);
				props.treeRowsByIndex.splice(mutation.startIndex, mutation.deleteCount, ...insertedRows);
				for (const row of insertedRows) {
					if (row !== null) props.affectedTreeRowPaths.add(row.path);
				}
				break;
			}
			default:
				assertNeverCatalogOrderMutation(mutation);
		}
	}
}

function emptyBridgeReviewItemProjectionUpdates(): BridgeReviewItemProjectionUpdates {
	return {
		availableContentRolesByItemId: new Map(),
		candidatePathsByItemId: new Map(),
		itemIdsByDisplayPath: new Map(),
		itemsById: new Map(),
		primaryDisplayPathByItemId: new Map(),
		secondaryItemIdsByTreePath: new Map(),
	};
}

function emptyBridgeReviewTreeProjectionUpdates(): BridgeReviewTreeProjectionUpdates {
	return { primaryItemIdByTreePath: new Map() };
}

function removeItemProjectionFacts(props: {
	readonly facetCounts: BridgeReviewFacetCounts;
	readonly item: BridgeWorkerReviewDisplayItem;
	readonly previousProjection: BridgeReviewProjectionResult;
	readonly updates: BridgeReviewItemProjectionUpdates;
}): void {
	const itemId = props.item.metadata.itemId;
	const displayPath = displayPathForItem(props.item);
	props.updates.availableContentRolesByItemId.set(itemId, undefined);
	props.updates.candidatePathsByItemId.set(itemId, undefined);
	props.updates.primaryDisplayPathByItemId.set(itemId, undefined);
	const previousPathItemIds =
		props.updates.itemIdsByDisplayPath.get(displayPath) ??
		props.previousProjection.itemIdsByDisplayPath[displayPath] ??
		[];
	const remainingPathItemIds = previousPathItemIds.filter((candidateId) => candidateId !== itemId);
	props.updates.itemIdsByDisplayPath.set(
		displayPath,
		remainingPathItemIds.length === 0 ? undefined : remainingPathItemIds,
	);
	props.updates.secondaryItemIdsByTreePath.set(
		displayPath,
		remainingPathItemIds.length <= 1 ? undefined : remainingPathItemIds.slice(1),
	);
	adjustPresentationFacetCounts(props.facetCounts, props.item, -1);
}

function addItemProjectionFacts(props: {
	readonly facetCounts: BridgeReviewFacetCounts;
	readonly item: BridgeWorkerReviewDisplayItem;
	readonly previousProjection: BridgeReviewProjectionResult;
	readonly updates: BridgeReviewItemProjectionUpdates;
}): void {
	const itemId = props.item.metadata.itemId;
	const candidatePaths = candidatePathsForItem(props.item);
	const displayPath = candidatePaths[0] ?? itemId;
	props.updates.availableContentRolesByItemId.set(itemId, props.item.metadata.contentRoles);
	props.updates.candidatePathsByItemId.set(itemId, candidatePaths);
	props.updates.primaryDisplayPathByItemId.set(itemId, displayPath);
	const currentPathItemIds =
		props.updates.itemIdsByDisplayPath.get(displayPath) ??
		props.previousProjection.itemIdsByDisplayPath[displayPath] ??
		[];
	const nextPathItemIds = currentPathItemIds.includes(itemId)
		? currentPathItemIds
		: [...currentPathItemIds, itemId];
	props.updates.itemIdsByDisplayPath.set(displayPath, nextPathItemIds);
	props.updates.secondaryItemIdsByTreePath.set(displayPath, nextPathItemIds.slice(1));
	adjustPresentationFacetCounts(props.facetCounts, props.item, 1);
}

function incrementalOrderedItemRanks(props: {
	readonly changes: readonly BridgeMainReviewCatalogChange[];
	readonly orderedItemIds: readonly string[];
	readonly previousRanks: Readonly<Record<string, number>>;
}): Readonly<Record<string, number>> {
	const updates = new Map<string, number | undefined>();
	for (const change of props.changes) {
		for (const itemId of change.itemIds) updates.set(itemId, undefined);
		for (const mutation of change.itemOrderMutations) {
			if (mutation.kind === 'replace') {
				for (const itemId of Object.keys(props.previousRanks)) updates.set(itemId, undefined);
				for (const [itemIndex, itemId] of props.orderedItemIds.entries()) {
					updates.set(itemId, itemIndex);
				}
				continue;
			}
			if (mutation.kind === 'setRange') {
				for (
					let itemIndex = mutation.startIndex;
					itemIndex < props.orderedItemIds.length;
					itemIndex += 1
				) {
					const itemId = props.orderedItemIds[itemIndex];
					if (itemId !== undefined) updates.set(itemId, itemIndex);
					if (itemIndex >= mutation.startIndex + mutation.length - 1) break;
				}
			}
		}
	}
	return patchReadonlyRecord(props.previousRanks, updates);
}

function incrementalTreeProjection(props: {
	readonly affectedTreeRowPaths: ReadonlySet<string>;
	readonly previousProjection: BridgeReviewProjectionResult;
	readonly reviewTreeRows: readonly ReviewTreeRowMetadata[];
	readonly updates: BridgeReviewTreeProjectionUpdates;
}): { readonly orderedPaths: readonly string[] } {
	for (const path of props.affectedTreeRowPaths) {
		const matchingRow = props.reviewTreeRows.find(
			(row) => row.path === path && row.itemId !== undefined,
		);
		props.updates.primaryItemIdByTreePath.set(path, matchingRow?.itemId);
	}
	const previousOrderedPaths = props.previousProjection.orderedPaths;
	const previousPathSet = new Set(previousOrderedPaths);
	const appendedPaths = props.reviewTreeRows
		.slice(previousOrderedPaths.length)
		.map((row) => row.path)
		.filter((path) => !previousPathSet.has(path));
	const existingPathsStillMatch = previousOrderedPaths.every(
		(path, pathIndex) => props.reviewTreeRows[pathIndex]?.path === path,
	);
	return {
		orderedPaths: existingPathsStillMatch
			? [...previousOrderedPaths, ...appendedPaths]
			: [...new Set(props.reviewTreeRows.map((row) => row.path))],
	};
}

function incrementalPresentationRegistry(props: {
	readonly affectedItemIds: ReadonlySet<string>;
	readonly previousRegistry: BridgeReviewItemRegistry;
	readonly reviewPackage: BridgeReviewPackage;
}): BridgeReviewItemRegistry {
	const previousOrderedItemIds = props.previousRegistry.reviewPackage.orderedItemIds;
	const appendedItemIds = props.reviewPackage.orderedItemIds.slice(previousOrderedItemIds.length);
	const isAppendOrUpdate = previousOrderedItemIds.every(
		(itemId, itemIndex) => props.reviewPackage.orderedItemIds[itemIndex] === itemId,
	);
	if (!isAppendOrUpdate)
		return createBridgeReviewItemRegistry({ reviewPackage: props.reviewPackage });
	const orderedItems = [...props.previousRegistry.orderedItems];
	const visibleItems = [...props.previousRegistry.visibleItems];
	const visiblePriorityFacts = [...props.previousRegistry.visiblePriorityFacts];
	for (const itemId of props.affectedItemIds) {
		const itemIndex = props.reviewPackage.orderedItemIds.indexOf(itemId);
		if (itemIndex < 0 || itemIndex >= previousOrderedItemIds.length) continue;
		const item = props.reviewPackage.itemsById[itemId];
		if (item === undefined) continue;
		orderedItems[itemIndex] = item;
		visibleItems[itemIndex] = item;
		visiblePriorityFacts[itemIndex] = presentationVisiblePriorityFact(item);
	}
	for (const itemId of appendedItemIds) {
		const item = props.reviewPackage.itemsById[itemId];
		if (item === undefined) continue;
		orderedItems.push(item);
		visibleItems.push(item);
		visiblePriorityFacts.push(presentationVisiblePriorityFact(item));
	}
	return { orderedItems, reviewPackage: props.reviewPackage, visibleItems, visiblePriorityFacts };
}

function presentationVisiblePriorityFact(
	item: BridgeReviewItemDescriptor,
): BridgeReviewItemRegistry['visiblePriorityFacts'][number] {
	return {
		itemId: item.itemId,
		pathLabel: item.headPath ?? item.basePath ?? item.itemId,
		reviewPriority: item.reviewPriority,
	};
}

function patchReadonlyRecord<TValue>(
	base: Readonly<Record<string, TValue>>,
	updates: ReadonlyMap<string, TValue | undefined>,
): Readonly<Record<string, TValue>> {
	if (updates.size === 0) return base;
	const patch = new Map(updates);
	const target: Record<string, TValue> = {};
	return new Proxy(target, {
		deleteProperty: (): boolean => false,
		get: (_target, property): TValue | undefined => {
			if (typeof property !== 'string') return undefined;
			return patch.has(property) ? patch.get(property) : base[property];
		},
		getOwnPropertyDescriptor: (_target, property): PropertyDescriptor | undefined => {
			if (typeof property !== 'string') return undefined;
			const value = patch.has(property) ? patch.get(property) : base[property];
			return value === undefined
				? undefined
				: { configurable: true, enumerable: true, value, writable: false };
		},
		has: (_target, property): boolean => {
			if (typeof property !== 'string') return false;
			return patch.has(property) ? patch.get(property) !== undefined : property in base;
		},
		ownKeys: (): readonly string[] => {
			const keys = new Set(Object.keys(base));
			for (const [key, value] of patch) {
				if (value === undefined) keys.delete(key);
				else keys.add(key);
			}
			return [...keys];
		},
		set: (): boolean => false,
	});
}

function orderedReviewDisplayItems(props: {
	readonly catalogSnapshot: BridgeMainReviewCatalogSnapshot;
	readonly displayStore: BridgeReviewDirectDisplayStore;
}): readonly BridgeWorkerReviewDisplayItem[] {
	const orderedItems: BridgeWorkerReviewDisplayItem[] = [];
	for (let itemIndex = 0; itemIndex < props.catalogSnapshot.itemOrderLength; itemIndex += 1) {
		const itemId = props.displayStore.getReviewItemIdAtIndex(itemIndex);
		if (itemId === null || itemId === undefined) continue;
		const displayItem = props.displayStore.getReviewItemSnapshot(itemId);
		if (displayItem !== undefined) orderedItems.push(displayItem);
	}
	return orderedItems;
}

function orderedReviewTreeRows(props: {
	readonly catalogSnapshot: BridgeMainReviewCatalogSnapshot;
	readonly displayStore: BridgeReviewDirectDisplayStore;
}): readonly ReviewTreeRowMetadata[] {
	const rows: ReviewTreeRowMetadata[] = [];
	for (let rowIndex = 0; rowIndex < props.catalogSnapshot.treeRowOrderLength; rowIndex += 1) {
		const row = reviewTreeRowForDisplay(props.displayStore.getReviewTreeRowAtIndex(rowIndex));
		if (row !== null) rows.push(row);
	}
	return rows;
}

function reviewTreeRowForDisplay(
	row: BridgeMainReviewTreeDisplayRow | null | undefined,
): ReviewTreeRowMetadata | null {
	if (row === null || row === undefined) return null;
	return {
		depth: row.depth,
		isDirectory: row.isDirectory,
		path: row.path,
		rowId: row.rowId,
		...(row.itemId === null ? {} : { itemId: row.itemId }),
		...(row.lane === undefined ? {} : { lane: row.lane }),
		...(row.loadedBy === undefined ? {} : { loaded_by: row.loadedBy }),
	};
}

function presentationItemForDisplay(
	displayItem: BridgeWorkerReviewDisplayItem,
	itemVersion: number,
): BridgeReviewItemDescriptor {
	const metadata = displayItem.metadata;
	const contentLineCountsByRole = Object.fromEntries(
		displayItem.extentFacts.map((fact) => [fact.contentRole, fact.lineCount]),
	);
	return {
		additions: metadata.additions,
		annotationSummary: { commentCount: 0, threadCount: 0, unresolvedThreadCount: 0 },
		baseContentHash: metadata.contentHashesByRole.base ?? null,
		basePath: metadata.basePath,
		cacheKey: metadataWindowCacheKey(displayItem),
		changeKind: metadata.changeKind,
		collapsed: false,
		contentHashAlgorithm: displayItem.contentFacts[0]?.contentDigest.algorithm ?? 'unknown',
		contentLineCountsByRole,
		contentRoles: {},
		deletions: metadata.deletions,
		extension: metadata.extension,
		fileClass: metadata.fileClass,
		headContentHash: metadata.contentHashesByRole.head ?? null,
		headPath: metadata.headPath,
		isHiddenByDefault: metadata.isHiddenByDefault,
		itemId: metadata.itemId,
		itemKind: presentationItemKind(displayItem),
		itemVersion,
		language: metadata.language,
		provenance: {
			agentSessionIds: [...metadata.provenance.agentSessionIds],
			operationIds: [...metadata.provenance.operationIds],
			paneIds: [],
			promptIds: [...metadata.provenance.promptIds],
			sourceKinds: [],
		},
		reviewPriority: metadata.reviewPriority,
		reviewState: metadata.reviewState,
		sizeBytes: 0,
	};
}

function metadataWindowCacheKey(displayItem: BridgeWorkerReviewDisplayItem): string {
	return JSON.stringify([
		'bridge-review-presentation-item-v1',
		displayItem.metadataWindowIdentity,
		displayItem.contentFacts.map((fact) => [
			fact.role,
			fact.contentDigest.algorithm,
			fact.contentDigest.value,
		]),
	]);
}

function presentationItemKind(displayItem: BridgeWorkerReviewDisplayItem): 'diff' | 'file' {
	const roles = displayItem.metadata.contentRoles;
	return roles.includes('file') &&
		!roles.some((role) => role === 'base' || role === 'head' || role === 'diff')
		? 'file'
		: 'diff';
}

function presentationPackageForDisplay(props: {
	readonly itemsById: Readonly<Record<string, BridgeReviewItemDescriptor>>;
	readonly orderedItemIds: readonly string[];
	readonly presentationKey: string;
	readonly reviewGeneration: number;
	readonly reviewSourceSlice: BridgePresentableReviewSourceDisplaySlice;
	readonly revision: number;
}): BridgeReviewPackage {
	const query = presentationQueryForDisplay(props.reviewSourceSlice.query);
	return {
		baseEndpoint: props.reviewSourceSlice.baseEndpoint,
		comparisonOrigin: props.reviewSourceSlice.comparisonOrigin,
		filterState: query.viewFilter,
		generatedAtUnixMilliseconds: 0,
		groups: [],
		headEndpoint: props.reviewSourceSlice.headEndpoint,
		itemsById: props.itemsById,
		orderedItemIds: [...props.orderedItemIds],
		packageId: props.reviewSourceSlice.packageId,
		query,
		reviewGeneration: props.reviewGeneration,
		reviewedSubjectLabel: props.reviewSourceSlice.reviewedSubjectLabel,
		revision: props.revision,
		schemaVersion: 1,
		summary: props.reviewSourceSlice.summary,
	};
}

function presentationQueryForDisplay(
	query: BridgePresentableReviewSourceDisplaySlice['query'],
): BridgeReviewPackage['query'] {
	const viewFilter: BridgeReviewPackage['filterState'] = {
		changeKinds: [...query.viewFilter.changeKinds],
		excludedExtensions: [...query.viewFilter.excludedExtensions],
		excludedFileClasses: [...query.viewFilter.excludedFileClasses],
		excludedPathGlobs: [...query.viewFilter.excludedPathGlobs],
		includedExtensions: [...query.viewFilter.includedExtensions],
		includedFileClasses: [...query.viewFilter.includedFileClasses],
		includedPathGlobs: [...query.viewFilter.includedPathGlobs],
		reviewStates: [...query.viewFilter.reviewStates],
		showBinaryFiles: query.viewFilter.showBinaryFiles,
		showHiddenFiles: query.viewFilter.showHiddenFiles,
		showLargeFiles: query.viewFilter.showLargeFiles,
	};
	return {
		...query,
		pathScope: [...query.pathScope],
		provenanceFilter: {
			...query.provenanceFilter,
			agentSessionIds: [...query.provenanceFilter.agentSessionIds],
			operationIds: [...query.provenanceFilter.operationIds],
			paneIds: [...query.provenanceFilter.paneIds],
			promptIds: [...query.provenanceFilter.promptIds],
			sourceKinds: [...query.provenanceFilter.sourceKinds],
		},
		viewFilter,
	};
}

function isPresentableReviewSourceDisplaySlice(
	sourceSlice: BridgeMainReviewSourceDisplaySlice | null,
): sourceSlice is BridgePresentableReviewSourceDisplaySlice {
	return (
		sourceSlice !== null &&
		(sourceSlice.status === 'ready' || sourceSlice.status === 'stale') &&
		sourceSlice.baseEndpoint !== null &&
		sourceSlice.headEndpoint !== null &&
		sourceSlice.query !== null &&
		sourceSlice.summary !== null &&
		sourceSlice.totalItemCount !== null &&
		sourceSlice.totalTreeRowCount !== null
	);
}

function presentationProjectionForDisplay(props: {
	readonly orderedDisplayItems: readonly BridgeWorkerReviewDisplayItem[];
	readonly presentationKey: string;
	readonly reviewTreeRows: readonly ReviewTreeRowMetadata[];
}): BridgeReviewProjectionResult {
	const orderedItemIds = props.orderedDisplayItems.map((item) => item.metadata.itemId);
	const primaryDisplayPathByItemId: Record<string, string> = {};
	const candidatePathsByItemId: Record<string, readonly string[]> = {};
	const itemIdsByDisplayPath: Record<string, readonly string[]> = {};
	const availableContentRolesByItemId: Record<
		string,
		BridgeWorkerReviewDisplayItem['metadata']['contentRoles']
	> = {};
	for (const item of props.orderedDisplayItems) {
		const candidatePaths = candidatePathsForItem(item);
		const displayPath = candidatePaths[0] ?? item.metadata.itemId;
		primaryDisplayPathByItemId[item.metadata.itemId] = displayPath;
		candidatePathsByItemId[item.metadata.itemId] = candidatePaths;
		itemIdsByDisplayPath[displayPath] = [
			...(itemIdsByDisplayPath[displayPath] ?? []),
			item.metadata.itemId,
		];
		availableContentRolesByItemId[item.metadata.itemId] = item.metadata.contentRoles;
	}
	const primaryItemIdByTreePath: Record<string, string> = {};
	for (const row of props.reviewTreeRows) {
		if (row.itemId !== undefined && primaryItemIdByTreePath[row.path] === undefined) {
			primaryItemIdByTreePath[row.path] = row.itemId;
		}
	}
	return {
		availableContentRolesByItemId,
		candidatePathsByItemId,
		facetCounts: presentationFacetCounts(props.orderedDisplayItems),
		itemIdsByDisplayPath,
		label: 'Worker display presentation',
		orderedItemIds,
		orderedItemRankByItemId: Object.fromEntries(
			orderedItemIds.map((itemId, index) => [itemId, index]),
		),
		orderedPaths: [...new Set(props.reviewTreeRows.map((row) => row.path))],
		primaryDisplayPathByItemId,
		primaryItemIdByTreePath,
		projectionId: props.presentationKey,
		secondaryItemIdsByTreePath: Object.fromEntries(
			Object.entries(itemIdsByDisplayPath).map(([path, itemIds]) => [path, itemIds.slice(1)]),
		),
	};
}

function candidatePathsForItem(item: BridgeWorkerReviewDisplayItem): readonly string[] {
	return [...new Set([item.metadata.headPath, item.metadata.basePath].filter(isString))];
}

function displayPathForItem(item: BridgeWorkerReviewDisplayItem): string {
	return candidatePathsForItem(item)[0] ?? item.metadata.itemId;
}

function isString(value: string | null): value is string {
	return value !== null;
}

function presentationFacetCounts(
	items: readonly BridgeWorkerReviewDisplayItem[],
): BridgeReviewFacetCounts {
	const facetCounts = emptyPresentationFacetCounts();
	for (const item of items) adjustPresentationFacetCounts(facetCounts, item, 1);
	return facetCounts;
}

function emptyPresentationFacetCounts(): BridgeReviewFacetCounts {
	return {
		binary: 0,
		changeKinds: {},
		extensions: {},
		fileClasses: {},
		hidden: 0,
		large: 0,
		reviewStates: {},
	};
}

function cloneFacetCounts(facetCounts: BridgeReviewFacetCounts): BridgeReviewFacetCounts {
	return {
		binary: facetCounts.binary,
		changeKinds: { ...facetCounts.changeKinds },
		extensions: { ...facetCounts.extensions },
		fileClasses: { ...facetCounts.fileClasses },
		hidden: facetCounts.hidden,
		large: facetCounts.large,
		reviewStates: { ...facetCounts.reviewStates },
	};
}

function adjustPresentationFacetCounts(
	counts: BridgeReviewFacetCounts,
	item: BridgeWorkerReviewDisplayItem,
	delta: 1 | -1,
): void {
	adjustCount(counts.fileClasses, item.metadata.fileClass, delta);
	adjustCount(counts.changeKinds, item.metadata.changeKind, delta);
	adjustCount(counts.reviewStates, item.metadata.reviewState, delta);
	if (item.metadata.extension !== null)
		adjustCount(counts.extensions, item.metadata.extension, delta);
	if (item.metadata.isHiddenByDefault) counts.hidden += delta;
	if (item.metadata.fileClass === 'binary') counts.binary += delta;
	if (item.metadata.fileClass === 'large') counts.large += delta;
}

function adjustCount(counts: Record<string, number>, key: string, delta: 1 | -1): void {
	const nextCount = (counts[key] ?? 0) + delta;
	if (nextCount <= 0) delete counts[key];
	else counts[key] = nextCount;
}

function assertNeverCatalogOrderMutation(mutation: never): never {
	throw new Error(`Unhandled Review catalog order mutation: ${JSON.stringify(mutation)}`);
}
