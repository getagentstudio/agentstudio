import type {
	BridgeMainCodeViewItem,
	BridgeMainReviewCatalogChange,
	BridgeMainReviewCatalogChangeRead,
	BridgeMainReviewCatalogOrderMutation,
	BridgeMainReviewCatalogSnapshot,
	BridgeMainReviewDisplayState,
	BridgeMainReviewDisplayFreshness,
	BridgeMainReviewSourceDisplaySlice,
	BridgeMainReviewTreeDisplayRow,
	BridgeMainRenderSnapshot,
} from './bridge-main-render-snapshot-store.js';
import { bridgeMainReviewComparisonPresentationSchema } from './bridge-main-review-comparison-presentation.js';

export interface MutableBridgeMainReviewDisplayState {
	reviewDisplayFreshness: BridgeMainReviewDisplayFreshness | null;
	reviewItemById: Record<string, BridgeWorkerReviewDisplayItem>;
	reviewItemIdsByIndex: Array<string | null>;
	reviewSourceSlice: BridgeMainReviewSourceDisplaySlice | null;
	reviewTreeRowsByIndex: Array<BridgeMainReviewTreeDisplayRow | null>;
}

export type MutableBridgeMainRenderSnapshot = Omit<
	BridgeMainRenderSnapshot,
	keyof BridgeMainReviewDisplayState | 'panelChromeSlice'
> &
	MutableBridgeMainReviewDisplayState & {
		panelChromeSlice: BridgeMainRenderSnapshot['panelChromeSlice'];
	};
import type {
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerReviewDisplayPatchEvent,
} from './bridge-worker-contracts.js';

export function emptyBridgeMainReviewCatalogSnapshot(): BridgeMainReviewCatalogSnapshot {
	return {
		changeCursor: 0,
		epoch: null,
		itemOrderLength: 0,
		revision: 0,
		treeRowOrderLength: 0,
	};
}

export interface BridgeMainReviewDisplayPatchEffect {
	readonly comparisonChanged: boolean;
	readonly itemIds: ReadonlySet<string>;
	readonly itemOrderMutations: readonly BridgeMainReviewCatalogOrderMutation[];
	readonly previousItemsById: ReadonlyMap<string, BridgeWorkerReviewDisplayItem>;
	readonly reset: boolean;
	readonly sourceChanged: boolean;
	readonly treeRowIds: ReadonlySet<string>;
	readonly treeRowOrderMutations: readonly BridgeMainReviewCatalogOrderMutation[];
}

export function applyReviewDisplayPatchEventInPlace(props: {
	readonly event: BridgeWorkerReviewDisplayPatchEvent;
	readonly reviewItemIndexById: Map<string, number>;
	readonly reviewTreeRowById: Map<string, BridgeMainReviewTreeDisplayRow>;
	readonly snapshot: MutableBridgeMainRenderSnapshot;
}): BridgeMainReviewDisplayPatchEffect | null {
	if (!reviewDisplayEventIsFresh(props.snapshot.reviewDisplayFreshness, props.event)) return null;
	const mutableState = props.snapshot;
	const itemIds = new Set<string>();
	const itemOrderMutations: BridgeMainReviewCatalogOrderMutation[] = [];
	const previousItemsById = new Map<string, BridgeWorkerReviewDisplayItem>();
	const treeRowIds = new Set<string>();
	const treeRowOrderMutations: BridgeMainReviewCatalogOrderMutation[] = [];
	let reset = false;
	let comparisonChanged = false;
	let sourceChanged = false;
	if (
		mutableState.reviewDisplayFreshness !== null &&
		props.event.epoch > mutableState.reviewDisplayFreshness.epoch
	) {
		reset = true;
		for (const itemId of Object.keys(mutableState.reviewItemById)) {
			capturePreviousBridgeMainReviewDisplayItem({
				itemId,
				mutableState,
				previousItemsById,
			});
			itemIds.add(itemId);
		}
		for (const rowId of props.reviewTreeRowById.keys()) treeRowIds.add(rowId);
		mutableState.reviewItemById = {};
		mutableState.reviewItemIdsByIndex = [];
		mutableState.reviewSourceSlice = null;
		mutableState.reviewTreeRowsByIndex = [];
		props.reviewTreeRowById.clear();
		props.reviewItemIndexById.clear();
		sourceChanged = true;
	}
	for (const patch of props.event.patches) {
		switch (patch.slice) {
			case 'reviewComparison':
				mutableState.panelChromeSlice = {
					...mutableState.panelChromeSlice,
					reviewComparison:
						patch.payload === null
							? null
							: bridgeMainReviewComparisonPresentationSchema.parse(patch.payload),
				};
				comparisonChanged = true;
				break;
			case 'reviewSource':
				mutableState.reviewSourceSlice = patch.payload;
				sourceChanged = true;
				break;
			case 'reviewItem':
				applyReviewItemDisplayPatchInPlace({
					itemIds,
					itemOrderMutations,
					mutableState,
					patch,
					previousItemsById,
					resetPresentation: (): void => {
						reset = true;
					},
					reviewItemIndexById: props.reviewItemIndexById,
					reviewTreeRowById: props.reviewTreeRowById,
					treeRowIds,
					treeRowOrderMutations,
				});
				break;
			case 'reviewTree':
				applyReviewTreeDisplayPatchInPlace({
					mutableState,
					patch,
					resetPresentation: (): void => {
						reset = true;
					},
					reviewTreeRowById: props.reviewTreeRowById,
					treeRowIds,
					treeRowOrderMutations,
				});
				break;
			default:
				assertNeverReviewDisplayPatch(patch);
		}
	}
	mutableState.reviewDisplayFreshness = {
		epoch: props.event.epoch,
		projectionRevision: props.event.projectionRevision,
		sequence: props.event.sequence,
	};
	return {
		comparisonChanged,
		itemIds,
		itemOrderMutations,
		previousItemsById,
		reset,
		sourceChanged,
		treeRowIds,
		treeRowOrderMutations,
	};
}

function applyReviewItemDisplayPatchInPlace(props: {
	readonly itemIds: Set<string>;
	readonly itemOrderMutations: BridgeMainReviewCatalogOrderMutation[];
	readonly mutableState: MutableBridgeMainReviewDisplayState;
	readonly patch: Extract<BridgeWorkerReviewDisplayPatch, { readonly slice: 'reviewItem' }>;
	readonly previousItemsById: Map<string, BridgeWorkerReviewDisplayItem>;
	readonly resetPresentation: () => void;
	readonly reviewItemIndexById: Map<string, number>;
	readonly reviewTreeRowById: Map<string, BridgeMainReviewTreeDisplayRow>;
	readonly treeRowIds: Set<string>;
	readonly treeRowOrderMutations: BridgeMainReviewCatalogOrderMutation[];
}): void {
	if (props.patch.operation === 'reset') {
		props.resetPresentation();
		for (const itemId of Object.keys(props.mutableState.reviewItemById)) {
			capturePreviousBridgeMainReviewDisplayItem({
				itemId,
				mutableState: props.mutableState,
				previousItemsById: props.previousItemsById,
			});
			props.itemIds.add(itemId);
		}
		props.mutableState.reviewItemById = {};
		props.mutableState.reviewItemIdsByIndex = [];
		props.reviewItemIndexById.clear();
		return;
	}
	if (props.patch.payload.reset) {
		props.resetPresentation();
		for (const itemId of Object.keys(props.mutableState.reviewItemById)) {
			capturePreviousBridgeMainReviewDisplayItem({
				itemId,
				mutableState: props.mutableState,
				previousItemsById: props.previousItemsById,
			});
			props.itemIds.add(itemId);
		}
		props.mutableState.reviewItemById = {};
		props.mutableState.reviewItemIdsByIndex = [];
		props.reviewItemIndexById.clear();
	}
	if (props.patch.payload.startIndex !== null) {
		props.itemOrderMutations.push({
			kind: 'setRange',
			length: props.patch.payload.items.length,
			startIndex: props.patch.payload.startIndex,
		});
	}
	for (const [offset, item] of props.patch.payload.items.entries()) {
		capturePreviousBridgeMainReviewDisplayItem({
			itemId: item.metadata.itemId,
			mutableState: props.mutableState,
			previousItemsById: props.previousItemsById,
		});
		props.mutableState.reviewItemById[item.metadata.itemId] = item;
		props.itemIds.add(item.metadata.itemId);
		if (props.patch.payload.startIndex !== null) {
			const itemIndex = props.patch.payload.startIndex + offset;
			const previousItemId = props.mutableState.reviewItemIdsByIndex[itemIndex];
			if (previousItemId !== null && previousItemId !== undefined) {
				capturePreviousBridgeMainReviewDisplayItem({
					itemId: previousItemId,
					mutableState: props.mutableState,
					previousItemsById: props.previousItemsById,
				});
				props.reviewItemIndexById.delete(previousItemId);
				if (previousItemId !== item.metadata.itemId) {
					delete props.mutableState.reviewItemById[previousItemId];
					props.itemIds.add(previousItemId);
				}
			}
			props.mutableState.reviewItemIdsByIndex[itemIndex] = item.metadata.itemId;
			props.reviewItemIndexById.set(item.metadata.itemId, itemIndex);
		}
	}
	applyReviewDisplayMutationOperationsInPlace({
		itemIds: props.itemIds,
		itemOrderMutations: props.itemOrderMutations,
		mutableState: props.mutableState,
		operations: props.patch.payload.operations ?? [],
		previousItemsById: props.previousItemsById,
		reviewItemIndexById: props.reviewItemIndexById,
		reviewTreeRowById: props.reviewTreeRowById,
		treeRowIds: props.treeRowIds,
		treeRowOrderMutations: props.treeRowOrderMutations,
	});
}

function applyReviewTreeDisplayPatchInPlace(props: {
	readonly mutableState: MutableBridgeMainReviewDisplayState;
	readonly patch: Extract<BridgeWorkerReviewDisplayPatch, { readonly slice: 'reviewTree' }>;
	readonly resetPresentation: () => void;
	readonly reviewTreeRowById: Map<string, BridgeMainReviewTreeDisplayRow>;
	readonly treeRowIds: Set<string>;
	readonly treeRowOrderMutations: BridgeMainReviewCatalogOrderMutation[];
}): void {
	if (props.patch.operation === 'reset') {
		props.resetPresentation();
		for (const rowId of props.reviewTreeRowById.keys()) props.treeRowIds.add(rowId);
		props.mutableState.reviewTreeRowsByIndex = [];
		props.reviewTreeRowById.clear();
		return;
	}
	if (props.patch.payload.reset) {
		props.resetPresentation();
		for (const rowId of props.reviewTreeRowById.keys()) props.treeRowIds.add(rowId);
		props.mutableState.reviewTreeRowsByIndex = [];
		props.reviewTreeRowById.clear();
	}
	for (const window of props.patch.payload.windows) {
		props.treeRowOrderMutations.push({
			kind: 'setRange',
			length: window.rows.length,
			startIndex: window.startIndex,
		});
		for (const [offset, row] of window.rows.entries()) {
			const rowIndex = window.startIndex + offset;
			const previousRow = props.mutableState.reviewTreeRowsByIndex[rowIndex];
			if (previousRow !== null && previousRow !== undefined) {
				props.reviewTreeRowById.delete(previousRow.rowId);
				props.treeRowIds.add(previousRow.rowId);
			}
			props.mutableState.reviewTreeRowsByIndex[rowIndex] = row;
			props.reviewTreeRowById.set(row.rowId, row);
			props.treeRowIds.add(row.rowId);
		}
	}
}

function applyReviewDisplayMutationOperationsInPlace(props: {
	readonly itemIds: Set<string>;
	readonly itemOrderMutations: BridgeMainReviewCatalogOrderMutation[];
	readonly mutableState: MutableBridgeMainReviewDisplayState;
	readonly operations: Extract<
		BridgeWorkerReviewDisplayPatch,
		{ readonly operation: 'batch'; readonly slice: 'reviewItem' }
	>['payload']['operations'];
	readonly previousItemsById: Map<string, BridgeWorkerReviewDisplayItem>;
	readonly reviewItemIndexById: Map<string, number>;
	readonly reviewTreeRowById: Map<string, BridgeMainReviewTreeDisplayRow>;
	readonly treeRowIds: Set<string>;
	readonly treeRowOrderMutations: BridgeMainReviewCatalogOrderMutation[];
}): void {
	for (const operation of props.operations) {
		switch (operation.operationKind) {
			case 'upsertItems':
				for (const item of operation.items) {
					capturePreviousBridgeMainReviewDisplayItem({
						itemId: item.metadata.itemId,
						mutableState: props.mutableState,
						previousItemsById: props.previousItemsById,
					});
					props.mutableState.reviewItemById[item.metadata.itemId] = item;
					props.itemIds.add(item.metadata.itemId);
				}
				break;
			case 'removeItems':
				for (const itemId of operation.itemIds) {
					capturePreviousBridgeMainReviewDisplayItem({
						itemId,
						mutableState: props.mutableState,
						previousItemsById: props.previousItemsById,
					});
					delete props.mutableState.reviewItemById[itemId];
					props.itemIds.add(itemId);
					const itemIndex = props.reviewItemIndexById.get(itemId);
					if (itemIndex !== undefined) {
						props.itemOrderMutations.push({
							kind: 'setRange',
							length: 1,
							startIndex: itemIndex,
						});
						props.mutableState.reviewItemIdsByIndex[itemIndex] = null;
						props.reviewItemIndexById.delete(itemId);
					}
				}
				break;
			case 'replaceItemOrder':
				for (const itemId of Object.keys(props.mutableState.reviewItemById)) {
					if (operation.itemIds.includes(itemId)) continue;
					capturePreviousBridgeMainReviewDisplayItem({
						itemId,
						mutableState: props.mutableState,
						previousItemsById: props.previousItemsById,
					});
					delete props.mutableState.reviewItemById[itemId];
					props.itemIds.add(itemId);
				}
				props.mutableState.reviewItemIdsByIndex = [...operation.itemIds];
				props.itemOrderMutations.push({ kind: 'replace', length: operation.itemIds.length });
				props.reviewItemIndexById.clear();
				for (const [itemIndex, itemId] of operation.itemIds.entries()) {
					props.reviewItemIndexById.set(itemId, itemIndex);
				}
				break;
			case 'spliceTreeRows': {
				props.treeRowOrderMutations.push({
					deleteCount: operation.deleteCount,
					insertCount: operation.rows.length,
					kind: 'splice',
					startIndex: operation.startIndex,
				});
				const removedRows = props.mutableState.reviewTreeRowsByIndex.slice(
					operation.startIndex,
					operation.startIndex + operation.deleteCount,
				);
				props.mutableState.reviewTreeRowsByIndex.splice(
					operation.startIndex,
					operation.deleteCount,
					...operation.rows,
				);
				for (const row of removedRows) {
					if (row === null || row === undefined) continue;
					props.reviewTreeRowById.delete(row.rowId);
					props.treeRowIds.add(row.rowId);
				}
				for (const row of operation.rows) {
					props.reviewTreeRowById.set(row.rowId, row);
					props.treeRowIds.add(row.rowId);
				}
				break;
			}
			default:
				assertNeverReviewDisplayMutationOperation(operation);
		}
	}
}

function reviewDisplayEventIsFresh(
	current: BridgeMainReviewDisplayFreshness | null,
	event: BridgeWorkerReviewDisplayPatchEvent,
): boolean {
	if (current === null || event.epoch > current.epoch) return true;
	return (
		event.epoch === current.epoch &&
		event.sequence > current.sequence &&
		event.projectionRevision > current.projectionRevision
	);
}

export const BRIDGE_MAIN_REVIEW_CATALOG_CHANGE_LIMIT = 256;

export function bridgeMainReviewRetainedRenderCopyItemIds(
	snapshot: BridgeMainRenderSnapshot,
): readonly string[] {
	return [
		...new Set([
			...Object.keys(snapshot.codeViewItemsById),
			...Object.keys(snapshot.contentAvailabilityById),
			...Object.keys(snapshot.rowPaintById),
		]),
	];
}

function capturePreviousBridgeMainReviewDisplayItem(props: {
	readonly itemId: string;
	readonly mutableState: MutableBridgeMainReviewDisplayState;
	readonly previousItemsById: Map<string, BridgeWorkerReviewDisplayItem>;
}): void {
	if (props.previousItemsById.has(props.itemId)) return;
	const previousItem = props.mutableState.reviewItemById[props.itemId];
	if (previousItem !== undefined) props.previousItemsById.set(props.itemId, previousItem);
}

export function bridgeMainReviewRenderCopyInvalidationItemIds(props: {
	readonly currentItemsById: Readonly<Record<string, BridgeWorkerReviewDisplayItem>>;
	readonly previousItemsById: ReadonlyMap<string, BridgeWorkerReviewDisplayItem>;
	readonly preserveProjectionHiddenCopies: boolean;
	readonly retainedRenderCopyItemIds: readonly string[];
	readonly replacesWorkerDerivationEpoch: boolean;
}): readonly string[] {
	if (props.replacesWorkerDerivationEpoch) {
		return [...new Set([...props.previousItemsById.keys(), ...props.retainedRenderCopyItemIds])];
	}
	const invalidatedItemIds = [...props.previousItemsById].flatMap(([itemId, previousItem]) => {
		const currentItem = props.currentItemsById[itemId];
		if (currentItem === undefined && props.preserveProjectionHiddenCopies) return [];
		return currentItem !== undefined &&
			bridgeMainReviewDisplayItemsShareRenderIdentity(previousItem, currentItem)
			? []
			: [itemId];
	});
	if (props.preserveProjectionHiddenCopies) return invalidatedItemIds;
	return [
		...new Set([
			...invalidatedItemIds,
			...props.retainedRenderCopyItemIds.filter(
				(itemId): boolean => props.currentItemsById[itemId] === undefined,
			),
		]),
	];
}

function bridgeMainReviewDisplayItemsShareRenderIdentity(
	previousItem: BridgeWorkerReviewDisplayItem,
	currentItem: BridgeWorkerReviewDisplayItem,
): boolean {
	if (
		previousItem.metadata.itemId !== currentItem.metadata.itemId ||
		previousItem.metadata.changeKind !== currentItem.metadata.changeKind ||
		previousItem.metadata.fileClass !== currentItem.metadata.fileClass ||
		previousItem.metadata.language !== currentItem.metadata.language ||
		previousItem.contentFacts.length === 0 ||
		previousItem.contentFacts.length !== currentItem.contentFacts.length ||
		!stringArraysEqual(previousItem.metadata.contentRoles, currentItem.metadata.contentRoles)
	) {
		return false;
	}
	return previousItem.contentFacts.every((previousFact, factIndex): boolean => {
		const currentFact = currentItem.contentFacts[factIndex];
		return (
			currentFact !== undefined &&
			previousFact.role === currentFact.role &&
			previousFact.semanticDocumentRevision === currentFact.semanticDocumentRevision &&
			previousFact.contentDigest.algorithm === currentFact.contentDigest.algorithm &&
			previousFact.contentDigest.authority === currentFact.contentDigest.authority &&
			previousFact.contentDigest.value === currentFact.contentDigest.value
		);
	});
}

export interface BridgeMainReviewRenderCopyMetadataReconciliation {
	readonly changed: boolean;
	readonly codeViewItemIds: readonly string[];
	readonly snapshot: MutableBridgeMainRenderSnapshot;
}

export function reconcileBridgeMainReviewRenderCopyMetadata(props: {
	readonly currentItemsById: Readonly<Record<string, BridgeWorkerReviewDisplayItem>>;
	readonly previousItemsById: ReadonlyMap<string, BridgeWorkerReviewDisplayItem>;
	readonly snapshot: MutableBridgeMainRenderSnapshot;
}): BridgeMainReviewRenderCopyMetadataReconciliation {
	let codeViewItemsById: Record<string, BridgeMainCodeViewItem> | null = null;
	const codeViewItemIds: string[] = [];
	for (const [itemId, previousDisplayItem] of props.previousItemsById) {
		const currentDisplayItem = props.currentItemsById[itemId];
		const currentCodeViewItem = props.snapshot.codeViewItemsById[itemId];
		if (
			currentDisplayItem === undefined ||
			currentCodeViewItem === undefined ||
			!bridgeMainReviewDisplayItemsShareRenderIdentity(previousDisplayItem, currentDisplayItem) ||
			bridgeMainReviewDisplayItemsShareReconciledMetadata(previousDisplayItem, currentDisplayItem)
		) {
			continue;
		}
		const reconciledCodeViewItem = bridgeMainReviewCodeViewItemForDisplayMetadata({
			codeViewItem: currentCodeViewItem,
			displayItem: currentDisplayItem,
		});
		if (reconciledCodeViewItem === currentCodeViewItem) continue;
		codeViewItemsById ??= { ...props.snapshot.codeViewItemsById };
		codeViewItemsById[itemId] = reconciledCodeViewItem;
		codeViewItemIds.push(itemId);
	}
	if (codeViewItemsById === null) {
		return { changed: false, codeViewItemIds, snapshot: props.snapshot };
	}
	return {
		changed: true,
		codeViewItemIds,
		snapshot: { ...props.snapshot, codeViewItemsById },
	};
}

function bridgeMainReviewCodeViewItemForDisplayMetadata(props: {
	readonly codeViewItem: BridgeMainCodeViewItem;
	readonly displayItem: BridgeWorkerReviewDisplayItem;
}): BridgeMainCodeViewItem {
	const metadata = props.displayItem.metadata;
	const displayPath = metadata.headPath ?? metadata.basePath ?? metadata.itemId;
	const sourceDescriptorIdsByRole = {
		base: metadata.contentDescriptorIdsByRole.base ?? null,
		diff: metadata.contentDescriptorIdsByRole.diff ?? null,
		file: metadata.contentDescriptorIdsByRole.file ?? null,
		head: metadata.contentDescriptorIdsByRole.head ?? null,
	};
	const nextVersion = (props.codeViewItem.version ?? 0) + 1;
	if (!Number.isSafeInteger(nextVersion)) {
		throw new Error('Bridge main Review CodeView item version exhausted its safe integer range.');
	}
	const bridgeMetadata = {
		...props.codeViewItem.bridgeMetadata,
		displayPath,
		sourceDescriptorIdsByRole,
	};
	if (props.codeViewItem.type === 'file') {
		if (
			props.codeViewItem.bridgeMetadata.displayPath === displayPath &&
			bridgeMainReviewSourceDescriptorIdsMatch(
				props.codeViewItem.bridgeMetadata.sourceDescriptorIdsByRole,
				sourceDescriptorIdsByRole,
			) &&
			props.codeViewItem.file.name === displayPath
		) {
			return props.codeViewItem;
		}
		return {
			...props.codeViewItem,
			bridgeMetadata,
			file: { ...props.codeViewItem.file, name: displayPath },
			version: nextVersion,
		};
	}
	const previousPath =
		metadata.changeKind === 'renamed' || metadata.changeKind === 'copied'
			? (metadata.basePath ?? props.codeViewItem.fileDiff.prevName)
			: undefined;
	if (
		props.codeViewItem.bridgeMetadata.displayPath === displayPath &&
		bridgeMainReviewSourceDescriptorIdsMatch(
			props.codeViewItem.bridgeMetadata.sourceDescriptorIdsByRole,
			sourceDescriptorIdsByRole,
		) &&
		props.codeViewItem.fileDiff.name === displayPath &&
		(previousPath === undefined || props.codeViewItem.fileDiff.prevName === previousPath)
	) {
		return props.codeViewItem;
	}
	return {
		...props.codeViewItem,
		bridgeMetadata,
		fileDiff: {
			...props.codeViewItem.fileDiff,
			name: displayPath,
			...(previousPath === undefined ? {} : { prevName: previousPath }),
		},
		version: nextVersion,
	};
}

function bridgeMainReviewDisplayItemsShareReconciledMetadata(
	previousItem: BridgeWorkerReviewDisplayItem,
	currentItem: BridgeWorkerReviewDisplayItem,
): boolean {
	const previousDescriptors = previousItem.metadata.contentDescriptorIdsByRole;
	const currentDescriptors = currentItem.metadata.contentDescriptorIdsByRole;
	return (
		previousItem.metadata.basePath === currentItem.metadata.basePath &&
		previousItem.metadata.headPath === currentItem.metadata.headPath &&
		(previousDescriptors.base ?? null) === (currentDescriptors.base ?? null) &&
		(previousDescriptors.diff ?? null) === (currentDescriptors.diff ?? null) &&
		(previousDescriptors.file ?? null) === (currentDescriptors.file ?? null) &&
		(previousDescriptors.head ?? null) === (currentDescriptors.head ?? null)
	);
}

function bridgeMainReviewSourceDescriptorIdsMatch(
	current: BridgeMainCodeViewItem['bridgeMetadata']['sourceDescriptorIdsByRole'] | undefined,
	next: NonNullable<BridgeMainCodeViewItem['bridgeMetadata']['sourceDescriptorIdsByRole']>,
): boolean {
	return (
		(current?.base ?? null) === next.base &&
		(current?.diff ?? null) === next.diff &&
		(current?.file ?? null) === next.file &&
		(current?.head ?? null) === next.head
	);
}

function stringArraysEqual(first: readonly string[], second: readonly string[]): boolean {
	return (
		first.length === second.length &&
		first.every((value, valueIndex): boolean => value === second[valueIndex])
	);
}

export interface BridgeMainReviewRenderCopyInvalidation {
	readonly availabilityItemIds: readonly string[];
	readonly changed: boolean;
	readonly codeViewItemIds: readonly string[];
	readonly selectionChanged: boolean;
	readonly snapshot: MutableBridgeMainRenderSnapshot;
}

export function invalidateBridgeMainReviewRenderCopies(props: {
	readonly itemIds: readonly string[];
	readonly selectionItemIds: readonly string[];
	readonly snapshot: MutableBridgeMainRenderSnapshot;
}): BridgeMainReviewRenderCopyInvalidation {
	if (props.itemIds.length === 0 && props.selectionItemIds.length === 0) {
		return {
			availabilityItemIds: [],
			changed: false,
			codeViewItemIds: [],
			selectionChanged: false,
			snapshot: props.snapshot,
		};
	}
	const selectionItemIds = new Set(props.selectionItemIds);
	const availabilityItemIds = props.itemIds.filter(
		(itemId): boolean => props.snapshot.contentAvailabilityById[itemId] !== undefined,
	);
	const codeViewItemIds = props.itemIds.filter(
		(itemId): boolean => props.snapshot.codeViewItemsById[itemId] !== undefined,
	);
	const rowPaintItemIds = props.itemIds.filter(
		(itemId): boolean => props.snapshot.rowPaintById[itemId] !== undefined,
	);
	const selectedItemId = props.snapshot.selectionSlice.selectedItemId;
	const selectionChanged =
		selectedItemId !== null &&
		selectionItemIds.has(selectedItemId) &&
		props.snapshot.reviewItemById[selectedItemId] === undefined;
	const changed =
		selectionChanged ||
		availabilityItemIds.length > 0 ||
		codeViewItemIds.length > 0 ||
		rowPaintItemIds.length > 0;
	if (!changed) {
		return {
			availabilityItemIds,
			changed,
			codeViewItemIds,
			selectionChanged,
			snapshot: props.snapshot,
		};
	}
	const contentAvailabilityById = { ...props.snapshot.contentAvailabilityById };
	const codeViewItemsById = { ...props.snapshot.codeViewItemsById };
	const rowPaintById = { ...props.snapshot.rowPaintById };
	for (const itemId of props.itemIds) {
		delete contentAvailabilityById[itemId];
		delete codeViewItemsById[itemId];
		delete rowPaintById[itemId];
	}
	return {
		availabilityItemIds,
		changed,
		codeViewItemIds,
		selectionChanged,
		snapshot: {
			...props.snapshot,
			codeViewItemsById,
			contentAvailabilityById,
			rowPaintById,
			selectionSlice: selectionChanged
				? { selectedItemId: null, source: null }
				: props.snapshot.selectionSlice,
		},
	};
}

export function readBridgeMainReviewCatalogChangesAfter(props: {
	readonly changes: readonly BridgeMainReviewCatalogChange[];
	readonly currentCursor: number;
	readonly cursor: number;
}): BridgeMainReviewCatalogChangeRead {
	if (props.cursor === props.currentCursor) {
		return { changes: [], resetRequired: false };
	}
	const firstRetainedCursor = props.changes[0]?.cursor ?? props.currentCursor + 1;
	if (props.cursor < firstRetainedCursor - 1 || props.cursor > props.currentCursor) {
		return { changes: [], resetRequired: true };
	}
	return {
		changes: props.changes.filter((change): boolean => change.cursor > props.cursor),
		resetRequired: false,
	};
}

export function emptyBridgeMainReviewDisplayState(): MutableBridgeMainReviewDisplayState {
	return {
		reviewDisplayFreshness: null,
		reviewItemById: {},
		reviewItemIdsByIndex: [],
		reviewSourceSlice: null,
		reviewTreeRowsByIndex: [],
	};
}

function assertNeverReviewDisplayPatch(patch: never): never {
	throw new Error(`Unhandled Review display patch: ${JSON.stringify(patch)}`);
}

function assertNeverReviewDisplayMutationOperation(operation: never): never {
	throw new Error(`Unhandled Review display mutation: ${JSON.stringify(operation)}`);
}
