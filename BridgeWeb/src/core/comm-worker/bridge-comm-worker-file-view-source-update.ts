import type { StoreApi } from 'zustand/vanilla';

import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	isBridgeCommWorkerDemandEligibleContentMetadata,
	reconcileBridgeCommWorkerDemandMembership,
	serializeBridgeCommWorkerDemandMembership,
} from './bridge-comm-worker-reconciler.js';
import type {
	BridgeCommWorkerRow,
	BridgeCommWorkerStoreState,
	BridgeCommWorkerTouchedResult,
} from './bridge-comm-worker-store.js';
import {
	isBridgeWorkerFileViewContentMetadata,
	type BridgeWorkerContentAvailabilityPatchPayload,
	type BridgeWorkerContentMetadata,
	type BridgeWorkerFileViewContentMetadata,
	type BridgeWorkerSlicePatch,
} from './bridge-worker-contracts.js';

type BridgeCommWorkerContentAvailabilityReason = NonNullable<
	BridgeWorkerContentAvailabilityPatchPayload['reason']
>;

export interface ApplyBridgeCommWorkerFileViewSourceUpdateFactProps {
	readonly contentItems: readonly BridgeWorkerFileViewContentMetadata[];
	readonly epoch: number;
	readonly pendingSlicePatches: BridgeWorkerSlicePatch[];
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly selectedContentRequestChanged: boolean;
	readonly store: StoreApi<BridgeCommWorkerStoreState>;
}

export interface ApplyBridgeCommWorkerFileViewSourceMutationFactProps {
	readonly epoch: number;
	readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	readonly pendingSlicePatches: BridgeWorkerSlicePatch[];
	readonly selectedContentRequestChanged: boolean;
	readonly store: StoreApi<BridgeCommWorkerStoreState>;
}

export function applyBridgeCommWorkerFileViewSourceUpdateFact(
	props: ApplyBridgeCommWorkerFileViewSourceUpdateFactProps,
): BridgeCommWorkerTouchedResult {
	const previousState = props.store.getState();
	const sourceIndexes = buildBridgeCommWorkerFileViewSourceIndexes(props);
	const nextByteCache = new Map(previousState.byteCache);
	const nextPaintReadyByItemId = new Map(previousState.paintReadyByItemId);
	const nextAvailabilityByItemId = new Map(previousState.availabilityByItemId);
	const touchedKeys = new Set<string>([
		'sourceRows',
		'sourceContentMetadata',
		...Array.from(sourceIndexes.contentMetadataByItemId.keys()).map(
			(itemId): string => `contentMetadata:${itemId}`,
		),
	]);
	const selectedFileViewContentMetadataChanged = didSelectedFileViewContentMetadataChange({
		nextContentMetadataByItemId: sourceIndexes.contentMetadataByItemId,
		previousState,
	});
	const nextSlicePatches: BridgeWorkerSlicePatch[] = [];
	const selectedDemandEpoch = selectedDemandEpochForSourceUpdate({
		contentMetadataByItemId: sourceIndexes.contentMetadataByItemId,
		epoch: props.epoch,
		selectedContentChanged:
			selectedFileViewContentMetadataChanged || props.selectedContentRequestChanged,
		state: previousState,
	});
	const selectedDemandEnabled = selectedDemandEpoch !== null;
	const demandByKey = buildDemandByKey({
		contentMetadataByItemId: sourceIndexes.contentMetadataByItemId,
		selectedId: previousState.selectedId,
		selectedDemandEpoch,
		visibleIds: previousState.visibleIds,
	});
	let resultReason: BridgeCommWorkerContentAvailabilityReason | null = null;

	for (const itemId of sourceRepairCandidateIds(previousState)) {
		const metadata = sourceIndexes.contentMetadataByItemId.get(itemId) ?? null;
		const isDemandEligible = isBridgeCommWorkerDemandEligibleContentMetadata(metadata);
		const isSelectedItem = previousState.selectedId === itemId;
		const isDemandTarget = isSelectedItem || previousState.visibleIds.includes(itemId);
		const previousContentCacheKey = previousState.paintReadyByItemId.get(itemId);
		const keepsReadyPaint =
			previousContentCacheKey !== undefined &&
			isDemandEligible &&
			metadata?.cacheKey === previousContentCacheKey;
		const keepsStaleSelectedPaint =
			previousContentCacheKey !== undefined && metadata === null && isSelectedItem;
		if (previousContentCacheKey !== undefined && !keepsReadyPaint && !keepsStaleSelectedPaint) {
			nextPaintReadyByItemId.delete(itemId);
			nextByteCache.delete(previousContentCacheKey);
			touchedKeys.add(`paintReady:${itemId}`);
			touchedKeys.add(`byteCache:${previousContentCacheKey}`);
			nextSlicePatches.push({
				slice: 'rowPaint',
				operation: 'delete',
				itemId,
			});
		}

		const nextAvailability = nextAvailabilityForFileViewSourceUpdate({
			hasReadyPaint: keepsReadyPaint,
			hasStaleSelectedPaint: keepsStaleSelectedPaint,
			isDemandEligible,
			isDemandTarget,
			previousContentCacheKey,
		});
		if (
			nextAvailability !== null &&
			previousState.availabilityByItemId.get(itemId) !== nextAvailability
		) {
			const payload =
				nextAvailability === 'unavailable'
					? ({ reason: 'source_reset', state: nextAvailability } as const)
					: ({ state: nextAvailability } as const);
			nextAvailabilityByItemId.set(itemId, nextAvailability);
			touchedKeys.add(`availability:${itemId}`);
			nextSlicePatches.push({
				slice: 'contentAvailability',
				operation: 'upsert',
				itemId,
				payload,
			});
			if (nextAvailability === 'unavailable') {
				resultReason = 'source_reset';
			}
		}
		if (demandByKey.get(itemId) !== previousState.demandByKey.get(itemId)) {
			touchedKeys.add(`demand:${itemId}`);
		}
	}

	props.store.setState({
		...previousState,
		...sourceIndexes,
		selectedDemandEnabled,
		byteCache: nextByteCache,
		paintReadyByItemId: nextPaintReadyByItemId,
		availabilityByItemId: nextAvailabilityByItemId,
		demandByKey,
	});
	props.pendingSlicePatches.push(...nextSlicePatches);

	return {
		...(resultReason === null
			? {}
			: {
					resultReason,
					sourceEpoch: props.epoch,
				}),
		selectedFileViewContentMetadataChanged,
		touchedKeys: [...touchedKeys],
	};
}

export function applyBridgeCommWorkerFileViewSourceMutationFact(
	props: ApplyBridgeCommWorkerFileViewSourceMutationFactProps,
): BridgeCommWorkerTouchedResult {
	const state = props.store.getState();
	const selectedId = state.selectedId;
	const previousSelectedMetadata =
		selectedId === null ? null : (state.contentMetadataByItemId.get(selectedId) ?? null);
	const affectedContentIds = new Set<string>();
	applyFileRuntimeMutationToSourceIndexes({
		affectedContentIds,
		mutation: props.mutation,
		state,
	});
	const nextSelectedMetadata =
		selectedId === null ? null : (state.contentMetadataByItemId.get(selectedId) ?? null);
	const selectedFileViewContentMetadataChanged = !areFileViewContentMetadataEquivalent(
		previousSelectedMetadata,
		nextSelectedMetadata,
	);
	const repairCandidateIds = fileRuntimeMutationRepairCandidateIds({
		affectedContentIds,
		mutation: props.mutation,
		state,
	});
	const touchedKeys = new Set<string>();
	let resultReason: BridgeCommWorkerContentAvailabilityReason | null = null;
	for (const itemId of affectedContentIds) touchedKeys.add(`contentMetadata:${itemId}`);
	for (const itemId of repairCandidateIds) {
		const repair = repairFileRuntimeContentCandidate({
			epoch: props.epoch,
			itemId,
			pendingSlicePatches: props.pendingSlicePatches,
			state,
			touchedKeys,
		});
		if (repair === 'source_reset') resultReason = repair;
	}
	const previousDemandByKey = state.demandByKey;
	const selectedDemandEpoch = selectedDemandEpochForSourceUpdate({
		contentMetadataByItemId: state.contentMetadataByItemId,
		epoch: props.epoch,
		selectedContentChanged:
			selectedFileViewContentMetadataChanged || props.selectedContentRequestChanged,
		state,
	});
	const selectedDemandEnabled = selectedDemandEpoch !== null;
	const demandByKey = buildDemandByKey({
		contentMetadataByItemId: state.contentMetadataByItemId,
		selectedId,
		selectedDemandEpoch,
		visibleIds: state.visibleIds,
	});
	for (const itemId of new Set([
		...(selectedId === null ? [] : [selectedId]),
		...state.visibleIds,
	])) {
		if (previousDemandByKey.get(itemId) !== demandByKey.get(itemId)) {
			touchedKeys.add(`demand:${itemId}`);
		}
	}
	props.store.setState({ ...state, demandByKey, selectedDemandEnabled });
	return {
		...(resultReason === null ? {} : { resultReason, sourceEpoch: props.epoch }),
		selectedFileViewContentMetadataChanged,
		touchedKeys: [...touchedKeys],
	};
}

function applyFileRuntimeMutationToSourceIndexes(props: {
	readonly affectedContentIds: Set<string>;
	readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	readonly state: BridgeCommWorkerStoreState;
}): void {
	if (props.mutation.kind === 'reset') {
		props.state.rowById.clear();
		props.state.orderedIds.length = 0;
		props.state.indexById.clear();
		props.state.childrenByParentId.clear();
		props.state.contentMetadataByItemId.clear();
	} else {
		if (props.mutation.resetContent === true) {
			props.state.contentMetadataByItemId.clear();
		}
		for (const itemId of props.mutation.rowRemovals) removeFileRuntimeRow(props.state, itemId);
		for (const itemId of props.mutation.contentRemovals) {
			props.state.contentMetadataByItemId.delete(itemId);
			props.affectedContentIds.add(itemId);
		}
	}
	for (const row of props.mutation.rowUpserts) upsertFileRuntimeRow(props.state, row);
	for (const metadata of props.mutation.contentUpserts) {
		props.state.contentMetadataByItemId.set(metadata.itemId, metadata);
		props.affectedContentIds.add(metadata.itemId);
	}
}

function removeFileRuntimeRow(state: BridgeCommWorkerStoreState, itemId: string): void {
	const row = state.rowById.get(itemId);
	if (row === undefined) return;
	state.rowById.delete(itemId);
	state.indexById.delete(itemId);
	if (state.orderedIds[row.index] === itemId) state.orderedIds[row.index] = undefined;
	if (row.parentId !== null) {
		const childIds = state.childrenByParentId.get(row.parentId);
		childIds?.delete(itemId);
		if (childIds?.size === 0) state.childrenByParentId.delete(row.parentId);
	}
}

function upsertFileRuntimeRow(state: BridgeCommWorkerStoreState, row: BridgeCommWorkerRow): void {
	const previousRow = state.rowById.get(row.id);
	if (previousRow !== undefined && previousRow.parentId !== row.parentId) {
		const previousChildIds =
			previousRow.parentId === null
				? undefined
				: state.childrenByParentId.get(previousRow.parentId);
		previousChildIds?.delete(row.id);
		if (previousChildIds?.size === 0 && previousRow.parentId !== null) {
			state.childrenByParentId.delete(previousRow.parentId);
		}
	}
	if (previousRow !== undefined && previousRow.index !== row.index) {
		if (state.orderedIds[previousRow.index] === row.id) {
			state.orderedIds[previousRow.index] = undefined;
		}
	}
	const displacedId = state.orderedIds[row.index];
	if (displacedId !== undefined && displacedId !== row.id) removeFileRuntimeRow(state, displacedId);
	state.rowById.set(row.id, row);
	state.indexById.set(row.id, row.index);
	state.orderedIds[row.index] = row.id;
	if (row.parentId !== null) {
		const childIds = state.childrenByParentId.get(row.parentId) ?? new Set<string>();
		childIds.add(row.id);
		state.childrenByParentId.set(row.parentId, childIds);
	}
}

function fileRuntimeMutationRepairCandidateIds(props: {
	readonly affectedContentIds: ReadonlySet<string>;
	readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	readonly state: BridgeCommWorkerStoreState;
}): readonly string[] {
	if (props.mutation.kind === 'delta' && props.mutation.resetContent !== true) {
		const visibleIds = new Set(props.state.visibleIds);
		const candidates: string[] = [];
		for (const itemId of props.affectedContentIds) {
			if (
				props.state.selectedId === itemId ||
				visibleIds.has(itemId) ||
				props.state.paintReadyByItemId.has(itemId) ||
				props.state.availabilityByItemId.has(itemId)
			) {
				candidates.push(itemId);
			}
		}
		return candidates;
	}
	const candidates = new Set<string>([
		...props.state.visibleIds,
		...props.state.paintReadyByItemId.keys(),
	]);
	if (props.state.selectedId !== null) candidates.add(props.state.selectedId);
	return [...candidates];
}

function repairFileRuntimeContentCandidate(props: {
	readonly epoch: number;
	readonly itemId: string;
	readonly pendingSlicePatches: BridgeWorkerSlicePatch[];
	readonly state: BridgeCommWorkerStoreState;
	readonly touchedKeys: Set<string>;
}): BridgeCommWorkerContentAvailabilityReason | null {
	const metadata = props.state.contentMetadataByItemId.get(props.itemId) ?? null;
	const isDemandEligible = isBridgeCommWorkerDemandEligibleContentMetadata(metadata);
	const isSelectedItem = props.state.selectedId === props.itemId;
	const isDemandTarget = isSelectedItem || props.state.visibleIds.includes(props.itemId);
	const previousContentCacheKey = props.state.paintReadyByItemId.get(props.itemId);
	const keepsReadyPaint =
		previousContentCacheKey !== undefined &&
		isDemandEligible &&
		metadata?.cacheKey === previousContentCacheKey;
	const keepsStaleSelectedPaint =
		previousContentCacheKey !== undefined && metadata === null && isSelectedItem;
	if (previousContentCacheKey !== undefined && !keepsReadyPaint && !keepsStaleSelectedPaint) {
		props.state.paintReadyByItemId.delete(props.itemId);
		props.state.byteCache.delete(previousContentCacheKey);
		props.touchedKeys.add(`paintReady:${props.itemId}`);
		props.touchedKeys.add(`byteCache:${previousContentCacheKey}`);
		props.pendingSlicePatches.push({
			slice: 'rowPaint',
			operation: 'delete',
			itemId: props.itemId,
		});
	}
	const nextAvailability = nextAvailabilityForFileViewSourceUpdate({
		hasReadyPaint: keepsReadyPaint,
		hasStaleSelectedPaint: keepsStaleSelectedPaint,
		isDemandEligible,
		isDemandTarget,
		previousContentCacheKey,
	});
	if (nextAvailability === null) {
		if (props.state.availabilityByItemId.delete(props.itemId)) {
			props.touchedKeys.add(`availability:${props.itemId}`);
			props.pendingSlicePatches.push({
				itemId: props.itemId,
				operation: 'delete',
				slice: 'contentAvailability',
			});
		}
		return null;
	}
	if (props.state.availabilityByItemId.get(props.itemId) === nextAvailability) return null;
	props.state.availabilityByItemId.set(props.itemId, nextAvailability);
	props.touchedKeys.add(`availability:${props.itemId}`);
	const payload =
		nextAvailability === 'unavailable'
			? ({ reason: 'source_reset', state: nextAvailability } as const)
			: ({ state: nextAvailability } as const);
	props.pendingSlicePatches.push({
		itemId: props.itemId,
		operation: 'upsert',
		payload,
		slice: 'contentAvailability',
	});
	return nextAvailability === 'unavailable' ? 'source_reset' : null;
}

function buildBridgeCommWorkerFileViewSourceIndexes(props: {
	readonly contentItems: readonly BridgeWorkerFileViewContentMetadata[];
	readonly rows: readonly BridgeCommWorkerRow[];
}): Pick<
	BridgeCommWorkerStoreState,
	'rowById' | 'orderedIds' | 'indexById' | 'childrenByParentId' | 'contentMetadataByItemId'
> {
	const rowById = new Map<string, BridgeCommWorkerRow>();
	const indexById = new Map<string, number>();
	const childrenByParentId = new Map<string, Set<string>>();
	const contentMetadataByItemId = new Map<string, BridgeWorkerContentMetadata>();
	for (const row of props.rows) {
		rowById.set(row.id, row);
		indexById.set(row.id, row.index);
		if (row.parentId !== null) {
			const childIds = childrenByParentId.get(row.parentId) ?? new Set<string>();
			childIds.add(row.id);
			childrenByParentId.set(row.parentId, childIds);
		}
	}
	for (const contentItem of props.contentItems) {
		contentMetadataByItemId.set(contentItem.itemId, contentItem);
	}
	return {
		rowById,
		orderedIds: props.rows.map((row) => row.id),
		indexById,
		childrenByParentId,
		contentMetadataByItemId,
	};
}

function selectedDemandEpochForSourceUpdate(props: {
	readonly contentMetadataByItemId: ReadonlyMap<string, BridgeWorkerContentMetadata>;
	readonly epoch: number;
	readonly selectedContentChanged: boolean;
	readonly state: BridgeCommWorkerStoreState;
}): number | null {
	if (
		props.state.selectedId === null ||
		!isBridgeCommWorkerDemandEligibleContentMetadata(
			props.contentMetadataByItemId.get(props.state.selectedId) ?? null,
		)
	) {
		return null;
	}
	if (props.selectedContentChanged) {
		return props.epoch;
	}
	return selectedDemandEpochFromState(props.state) ?? props.epoch;
}

function selectedDemandEpochFromState(state: BridgeCommWorkerStoreState): number | null {
	if (state.selectedId === null) {
		return null;
	}
	const existingDemand = state.demandByKey.get(state.selectedId);
	const selectedEpochMatch = /^selected:(\d+)$/u.exec(existingDemand ?? '');
	return selectedEpochMatch === null ? null : Number(selectedEpochMatch[1]);
}

function sourceRepairCandidateIds(state: BridgeCommWorkerStoreState): readonly string[] {
	const itemIds = new Set<string>([
		...state.visibleIds,
		...state.paintReadyByItemId.keys(),
		...state.availabilityByItemId.keys(),
	]);
	if (state.selectedId !== null) {
		itemIds.add(state.selectedId);
	}
	return [...itemIds];
}

function nextAvailabilityForFileViewSourceUpdate(props: {
	readonly hasReadyPaint: boolean;
	readonly hasStaleSelectedPaint: boolean;
	readonly isDemandEligible: boolean;
	readonly isDemandTarget: boolean;
	readonly previousContentCacheKey: string | undefined;
}): BridgeWorkerContentAvailabilityPatchPayload['state'] | null {
	if (props.hasReadyPaint) {
		return 'ready';
	}
	if (props.hasStaleSelectedPaint) {
		return 'stale';
	}
	if (
		!props.isDemandEligible &&
		(props.isDemandTarget || props.previousContentCacheKey !== undefined)
	) {
		return 'unavailable';
	}
	if (props.isDemandEligible && props.isDemandTarget) {
		return 'loading';
	}
	return null;
}

function buildDemandByKey(props: {
	readonly contentMetadataByItemId: ReadonlyMap<string, BridgeWorkerContentMetadata>;
	readonly selectedId: string | null;
	readonly selectedDemandEpoch: number | null;
	readonly visibleIds: readonly string[];
}): Map<string, string> {
	return serializeBridgeCommWorkerDemandMembership(
		reconcileBridgeCommWorkerDemandMembership(props),
	);
}

function didSelectedFileViewContentMetadataChange(props: {
	readonly nextContentMetadataByItemId: ReadonlyMap<string, BridgeWorkerContentMetadata>;
	readonly previousState: BridgeCommWorkerStoreState;
}): boolean {
	const selectedId = props.previousState.selectedId;
	if (selectedId === null) {
		return false;
	}
	return !areFileViewContentMetadataEquivalent(
		props.previousState.contentMetadataByItemId.get(selectedId) ?? null,
		props.nextContentMetadataByItemId.get(selectedId) ?? null,
	);
}

function areFileViewContentMetadataEquivalent(
	left: BridgeWorkerContentMetadata | null,
	right: BridgeWorkerContentMetadata | null,
): boolean {
	if (left === null || right === null) {
		return left === right;
	}
	if (
		!isBridgeWorkerFileViewContentMetadata(left) ||
		!isBridgeWorkerFileViewContentMetadata(right)
	) {
		return false;
	}
	return (
		left.itemId === right.itemId &&
		left.path === right.path &&
		left.language === right.language &&
		left.cacheKey === right.cacheKey &&
		left.sizeBytes === right.sizeBytes &&
		left.descriptorId === right.descriptorId &&
		(left.contentHash ?? null) === (right.contentHash ?? null) &&
		left.encoding === right.encoding &&
		left.virtualizedExtentKind === right.virtualizedExtentKind &&
		left.payloadByteCount === right.payloadByteCount &&
		left.payloadLineCount === right.payloadLineCount &&
		left.totalLineCount === right.totalLineCount &&
		left.truncationKind === right.truncationKind &&
		left.endsMidLine === right.endsMidLine &&
		left.endsWithNewline === right.endsWithNewline &&
		left.isBinary === right.isBinary &&
		left.canFetchContent === right.canFetchContent
	);
}
