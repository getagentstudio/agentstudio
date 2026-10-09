import type {
	BridgeMainCodeViewItem,
	BridgeMainRenderSnapshotUpdate,
	BridgeMainSelectionSlice,
	BridgeMainViewportSlice,
} from './bridge-main-render-snapshot-store.js';
import { bridgeMainPanelChromeSliceSchema } from './bridge-main-review-comparison-presentation.js';
import type { MutableBridgeMainRenderSnapshot } from './bridge-main-review-display-state.js';
import type {
	BridgeWorkerContentAvailabilityPatchPayload,
	BridgeWorkerRowPaintPatchPayload,
	BridgeWorkerSlicePatch,
} from './bridge-worker-contracts.js';

export function reduceBridgeMainRenderSnapshotUpdate(
	snapshot: MutableBridgeMainRenderSnapshot,
	update: BridgeMainRenderSnapshotUpdate,
): MutableBridgeMainRenderSnapshot {
	let selectionSlice = snapshot.selectionSlice;
	let viewportSlice = snapshot.viewportSlice;
	let panelChromeSlice = snapshot.panelChromeSlice;
	let codeViewItemsById = snapshot.codeViewItemsById;
	let rowPaintById = snapshot.rowPaintById;
	let contentAvailabilityById = snapshot.contentAvailabilityById;
	let mutableCodeViewItems: Record<string, BridgeMainCodeViewItem> | undefined;
	let mutableRowPaint: Record<string, BridgeWorkerRowPaintPatchPayload> | undefined;
	let mutableContentAvailability:
		| Record<string, BridgeWorkerContentAvailabilityPatchPayload>
		| undefined;
	let didChange = false;

	const ensureMutableCodeViewItems = (): Record<string, BridgeMainCodeViewItem> => {
		if (mutableCodeViewItems !== undefined) return mutableCodeViewItems;
		mutableCodeViewItems = { ...codeViewItemsById };
		codeViewItemsById = mutableCodeViewItems;
		return mutableCodeViewItems;
	};
	const ensureMutableRowPaint = (): Record<string, BridgeWorkerRowPaintPatchPayload> => {
		if (mutableRowPaint !== undefined) return mutableRowPaint;
		mutableRowPaint = { ...rowPaintById };
		rowPaintById = mutableRowPaint;
		return mutableRowPaint;
	};
	const ensureMutableContentAvailability = (): Record<
		string,
		BridgeWorkerContentAvailabilityPatchPayload
	> => {
		if (mutableContentAvailability !== undefined) return mutableContentAvailability;
		mutableContentAvailability = { ...contentAvailabilityById };
		contentAvailabilityById = mutableContentAvailability;
		return mutableContentAvailability;
	};

	if (update.localSelection !== undefined) {
		selectionSlice = update.localSelection;
		didChange = true;
	}
	if (update.localViewport !== undefined) {
		viewportSlice = {
			firstVisibleIndex: update.localViewport.firstVisibleIndex,
			lastVisibleIndex: update.localViewport.lastVisibleIndex,
			visibleItemIds: [...update.localViewport.visibleItemIds],
		};
		didChange = true;
	}
	for (const patch of update.codeViewItemPatches ?? []) {
		didChange = true;
		if (patch.operation === 'reset') {
			mutableCodeViewItems = {};
			codeViewItemsById = mutableCodeViewItems;
			continue;
		}
		const nextCodeViewItems = ensureMutableCodeViewItems();
		if (patch.operation === 'delete') delete nextCodeViewItems[patch.itemId];
		else nextCodeViewItems[patch.itemId] = patch.item;
	}
	for (const patch of update.workerPatches ?? []) {
		didChange = true;
		switch (patch.slice) {
			case 'selection':
				selectionSlice = selectionSliceFromPatch(patch);
				break;
			case 'viewport':
				viewportSlice = viewportSliceFromPatch(patch);
				break;
			case 'rowPaint': {
				if (patch.operation === 'reset') {
					mutableRowPaint = {};
					rowPaintById = mutableRowPaint;
					break;
				}
				const nextRowPaint = ensureMutableRowPaint();
				if (patch.operation === 'delete') {
					delete nextRowPaint[patch.itemId];
					delete ensureMutableCodeViewItems()[patch.itemId];
				} else nextRowPaint[patch.itemId] = patch.payload;
				break;
			}
			case 'contentAvailability': {
				if (patch.operation === 'reset') {
					mutableContentAvailability = {};
					contentAvailabilityById = mutableContentAvailability;
					break;
				}
				const nextAvailability = ensureMutableContentAvailability();
				if (patch.operation === 'delete') delete nextAvailability[patch.itemId];
				else nextAvailability[patch.itemId] = patch.payload;
				break;
			}
			case 'panelChrome':
				panelChromeSlice =
					patch.operation === 'upsert' ? bridgeMainPanelChromeSliceSchema.parse(patch.payload) : {};
				break;
			default:
				assertNeverBridgeWorkerSlicePatch(patch);
		}
	}
	if (!didChange) return snapshot;
	return {
		...snapshot,
		codeViewItemsById,
		contentAvailabilityById,
		panelChromeSlice,
		rowPaintById,
		selectionSlice,
		viewportSlice,
	};
}

function selectionSliceFromPatch(
	patch: Extract<BridgeWorkerSlicePatch, { slice: 'selection' }>,
): BridgeMainSelectionSlice {
	if (patch.operation === 'delete' || patch.operation === 'reset') {
		return { selectedItemId: null, source: null };
	}
	return { selectedItemId: patch.payload.selectedItemId, source: patch.payload.source ?? null };
}

function viewportSliceFromPatch(
	patch: Extract<BridgeWorkerSlicePatch, { slice: 'viewport' }>,
): BridgeMainViewportSlice {
	if (patch.operation === 'delete' || patch.operation === 'reset') {
		return { firstVisibleIndex: 0, lastVisibleIndex: 0, visibleItemIds: [] };
	}
	return {
		firstVisibleIndex: patch.payload.firstVisibleIndex,
		lastVisibleIndex: patch.payload.lastVisibleIndex,
		visibleItemIds: [...patch.payload.visibleItemIds],
	};
}

function assertNeverBridgeWorkerSlicePatch(patch: never): never {
	throw new Error(`Unhandled bridge worker slice patch: ${String(patch)}`);
}
