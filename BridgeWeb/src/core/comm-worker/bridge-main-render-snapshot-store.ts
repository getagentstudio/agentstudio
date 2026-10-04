import type {
	BridgeMainReviewCatalogSnapshot,
	BridgeMainReviewCatalogChange,
	BridgeMainReviewCatalogChangeRead,
} from './bridge-main-review-catalog-contracts.js';
import type { BridgeMainPanelChromeSlice } from './bridge-main-review-comparison-presentation.js';
export type {
	BridgeMainReviewCatalogSnapshot,
	BridgeMainReviewCatalogOrderMutation,
	BridgeMainReviewCatalogChange,
	BridgeMainReviewCatalogChangeRead,
} from './bridge-main-review-catalog-contracts.js';
import {
	BridgeMainFileDisplayPatchApplier,
	type BridgeMainFileDisplayPatchApplierProps,
	type BridgeMainFileDisplayState,
	type BridgeMainFileTreePatchStream,
} from './bridge-main-file-display-patch-applier.js';
import { BridgeMainKeyedListenerRegistry } from './bridge-main-keyed-listener-registry.js';
import { reduceBridgeMainRenderSnapshotUpdate as buildSnapshotFromUpdate } from './bridge-main-render-snapshot-update-reducer.js';
import {
	BridgeMainReviewCandidateBankOwner,
	mergeBridgeMainReviewCandidateSnapshot,
	type BridgeMainReviewCandidateStore,
	type MutableBridgeMainReviewCandidateBank,
	type BridgeMainReviewPublicationIdentity,
	type BridgeMainReviewRefreshPresentation,
} from './bridge-main-review-candidate-bank.js';
import {
	applyReviewDisplayPatchEventInPlace,
	bridgeMainReviewRenderCopyInvalidationItemIds,
	bridgeMainReviewRetainedRenderCopyItemIds,
	BRIDGE_MAIN_REVIEW_CATALOG_CHANGE_LIMIT,
	emptyBridgeMainReviewCatalogSnapshot,
	emptyBridgeMainReviewDisplayState,
	invalidateBridgeMainReviewRenderCopies,
	readBridgeMainReviewCatalogChangesAfter,
	reconcileBridgeMainReviewRenderCopyMetadata,
	type MutableBridgeMainRenderSnapshot,
} from './bridge-main-review-display-state.js';
import type {
	BridgeWorkerContentAvailabilityPatchPayload,
	BridgeWorkerFileDisplayPatchEvent,
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerReviewDisplayPatch,
	BridgeWorkerReviewDisplayPatchEvent,
	BridgeWorkerRowPaintPatchPayload,
	BridgeWorkerSlicePatch,
	BridgeWorkerViewRecoveryStatusEvent,
} from './bridge-worker-contracts.js';
export type {
	BridgeMainFileItemDisplayPayload,
	BridgeMainFileQueryDisplayPayload,
	BridgeMainFileStatusDisplayPayload,
	BridgeMainFileTreeDisplaySlice,
} from './bridge-main-file-display-patch-applier.js';
export type { BridgeMainFileTreeDisplayRow } from './bridge-main-file-tree-display-index.js';
import type {
	BridgeWorkerCodeViewDiffItem,
	BridgeWorkerCodeViewFileItem,
} from './bridge-worker-pierre-render-job.js';

export type {
	BridgeMainReviewCandidatePresentation,
	BridgeMainReviewCandidateRole,
	BridgeMainReviewCandidateSnapshotUpdate,
	BridgeMainReviewCandidateStore,
	BridgeMainReviewCandidateWorkerPatch,
	BridgeMainReviewPublicationIdentity,
	BridgeMainReviewRefreshPresentation,
} from './bridge-main-review-candidate-bank.js';

export type BridgeMainCodeViewItem = BridgeWorkerCodeViewFileItem | BridgeWorkerCodeViewDiffItem;
export type BridgeMainReviewTreeDisplayRow = NonNullable<
	BridgeMainReviewDisplayState['reviewTreeRowsByIndex'][number]
>;

export interface BridgeMainSelectionSlice {
	readonly selectedItemId: string | null;
	readonly source: 'user' | 'keyboard' | 'programmatic' | null;
}

export interface BridgeMainViewportSlice {
	readonly firstVisibleIndex: number;
	readonly lastVisibleIndex: number;
	readonly visibleItemIds: readonly string[];
}

export interface BridgeMainReviewDisplayFreshness {
	readonly epoch: number;
	readonly projectionRevision: number;
	readonly sequence: number;
}

export type BridgeMainReviewSourceDisplaySlice =
	| Extract<
			BridgeWorkerReviewDisplayPatch,
			{ readonly operation: 'upsert'; readonly slice: 'reviewSource' }
	  >['payload']
	| Extract<
			BridgeWorkerReviewDisplayPatch,
			{ readonly operation: 'failed'; readonly slice: 'reviewSource' }
	  >['payload']
	| Extract<
			BridgeWorkerReviewDisplayPatch,
			{ readonly operation: 'replace'; readonly slice: 'reviewSource' }
	  >['payload'];

export interface BridgeMainReviewDisplayState {
	readonly reviewDisplayFreshness: BridgeMainReviewDisplayFreshness | null;
	readonly reviewItemById: Readonly<Record<string, BridgeWorkerReviewDisplayItem>>;
	readonly reviewItemIdsByIndex: readonly (string | null)[];
	readonly reviewSourceSlice: BridgeMainReviewSourceDisplaySlice | null;
	readonly reviewTreeRowsByIndex: readonly (
		| Extract<
				BridgeWorkerReviewDisplayPatch,
				{ readonly operation: 'batch'; readonly slice: 'reviewTree' }
		  >['payload']['windows'][number]['rows'][number]
		| null
	)[];
}

export type BridgeMainCodeViewItemPatch =
	| {
			readonly operation: 'delete';
			readonly itemId: string;
	  }
	| {
			readonly operation: 'reset';
	  }
	| {
			readonly operation: 'upsert';
			readonly itemId: string;
			readonly item: BridgeMainCodeViewItem;
	  };

export interface BridgeMainRenderSnapshotUpdate {
	readonly codeViewItemPatches?: readonly BridgeMainCodeViewItemPatch[];
	readonly localSelection?: SetBridgeMainLocalSelectionProps;
	readonly localViewport?: SetBridgeMainLocalViewportProps;
	readonly workerPatches?: readonly BridgeWorkerSlicePatch[];
}

export type BridgeMainViewRecoveryStatus = Pick<
	BridgeWorkerViewRecoveryStatusEvent,
	'status' | 'view'
>;

export interface BridgeMainRenderSnapshot
	extends BridgeMainFileDisplayState, BridgeMainReviewDisplayState {
	readonly selectionSlice: BridgeMainSelectionSlice;
	readonly viewportSlice: BridgeMainViewportSlice;
	readonly rowPaintById: Readonly<Record<string, BridgeWorkerRowPaintPatchPayload>>;
	readonly contentAvailabilityById: Readonly<
		Record<string, BridgeWorkerContentAvailabilityPatchPayload>
	>;
	readonly codeViewItemsById: Readonly<Record<string, BridgeMainCodeViewItem>>;
	readonly panelChromeSlice: BridgeMainPanelChromeSlice;
}

export interface SetBridgeMainLocalSelectionProps {
	readonly selectedItemId: string;
	readonly source: 'user' | 'keyboard' | 'programmatic';
}

export interface SetBridgeMainLocalViewportProps {
	readonly firstVisibleIndex: number;
	readonly lastVisibleIndex: number;
	readonly visibleItemIds: readonly string[];
}

export interface BridgeMainRenderSnapshotStore extends BridgeMainReviewCandidateStore {
	readonly dispose: () => void;
	readonly getSnapshot: () => BridgeMainRenderSnapshot;
	readonly getServerSnapshot: () => BridgeMainRenderSnapshot;
	readonly getReviewAvailabilitySnapshot: (
		itemId: string,
	) => BridgeWorkerContentAvailabilityPatchPayload | undefined;
	readonly getReviewCatalogSnapshot: () => BridgeMainReviewCatalogSnapshot;
	readonly getReviewCodeViewItemSnapshot: (itemId: string) => BridgeMainCodeViewItem | undefined;
	readonly getReviewItemIdAtIndex: (itemIndex: number) => string | null | undefined;
	readonly getReviewItemSnapshot: (itemId: string) => BridgeWorkerReviewDisplayItem | undefined;
	readonly readReviewCatalogChangesAfter: (cursor: number) => BridgeMainReviewCatalogChangeRead;
	readonly reviewCatalogContainsItem: (itemId: string) => boolean;
	readonly getReviewSelectionSnapshot: () => BridgeMainSelectionSlice;
	readonly getReviewSourceSnapshot: () => BridgeMainReviewSourceDisplaySlice | null;
	readonly getReviewTreeRowSnapshot: (rowId: string) => BridgeMainReviewTreeDisplayRow | undefined;
	readonly getReviewTreeRowAtIndex: (
		treeRowIndex: number,
	) => BridgeMainReviewTreeDisplayRow | null | undefined;
	readonly hasPendingReviewPaintRelease: (itemId: string) => boolean;
	readonly prepareForWorkerReplacement: () => void;
	readonly subscribe: (listener: () => void) => () => void;
	readonly subscribeReviewAvailability: (itemId: string, listener: () => void) => () => void;
	readonly subscribeReviewCatalog: (listener: () => void) => () => void;
	readonly subscribeReviewCodeViewItem: (itemId: string, listener: () => void) => () => void;
	readonly subscribeReviewItem: (itemId: string, listener: () => void) => () => void;
	readonly subscribeReviewSelection: (listener: () => void) => () => void;
	readonly subscribeReviewSource: (listener: () => void) => () => void;
	readonly subscribeReviewTreeRow: (rowId: string, listener: () => void) => () => void;
	readonly subscribeWorkerReplacement: (listener: () => void) => () => void;
	readonly setLocalSelection: (props: SetBridgeMainLocalSelectionProps) => void;
	readonly setLocalViewport: (props: SetBridgeMainLocalViewportProps) => void;
	readonly setWorkerCodeViewItem: (props: {
		readonly itemId: string;
		readonly item: BridgeMainCodeViewItem;
	}) => void;
	readonly applyWorkerPatch: (patch: BridgeWorkerSlicePatch) => void;
	readonly applySnapshotUpdate: (update: BridgeMainRenderSnapshotUpdate) => void;
	readonly applyFileDisplayPatchEvent: (event: BridgeWorkerFileDisplayPatchEvent) => void;
	readonly applyReviewDisplayPatchEvent: (event: BridgeWorkerReviewDisplayPatchEvent) => void;
	readonly applyViewRecoveryStatusEvent: (event: BridgeWorkerViewRecoveryStatusEvent) => void;
	readonly getViewRecoveryStatus: (
		kind: BridgeWorkerViewRecoveryStatusEvent['view']['kind'],
	) => BridgeMainViewRecoveryStatus | null;
	readonly subscribeViewRecoveryStatus: (listener: () => void) => () => void;
	readonly completeFileQueryTransaction: (transactionId: string) => boolean;
	readonly fileTreePatchStream: BridgeMainFileTreePatchStream;
}

export interface BridgeMainRenderSnapshotStoreProps extends BridgeMainFileDisplayPatchApplierProps {
	readonly onFileQueryTransactionPublished?: (transactionId: string) => void;
	readonly onReviewPaintedCopyReleased?: (itemId: string) => boolean;
}

export function createBridgeMainRenderSnapshotStore(
	storeProps: BridgeMainRenderSnapshotStoreProps = {},
): BridgeMainRenderSnapshotStore {
	const {
		onFileQueryTransactionPublished,
		onReviewPaintedCopyReleased,
		...fileDisplayApplierProps
	} = storeProps;
	const fileDisplayPatchApplier = new BridgeMainFileDisplayPatchApplier(fileDisplayApplierProps);
	let snapshot = emptyBridgeMainRenderSnapshot(fileDisplayPatchApplier.state);
	const listeners = new Set<() => void>();
	const viewRecoveryStatusByKind = new Map<
		BridgeWorkerViewRecoveryStatusEvent['view']['kind'],
		BridgeMainViewRecoveryStatus
	>();
	const viewRecoveryStatusListeners = new Set<() => void>();
	const reviewAvailabilityListeners = new BridgeMainKeyedListenerRegistry<string>();
	const reviewCatalogListeners = new Set<() => void>();
	const reviewCodeViewItemListeners = new BridgeMainKeyedListenerRegistry<string>();
	const pendingReviewPaintReleaseItemIds = new Set<string>();
	const releasePaintedCopy = (itemId: string): void => {
		if (onReviewPaintedCopyReleased?.(itemId) === true) {
			pendingReviewPaintReleaseItemIds.add(itemId);
		}
	};
	const reviewItemIndexById = new Map<string, number>();
	const reviewItemListeners = new BridgeMainKeyedListenerRegistry<string>();
	const reviewSelectionListeners = new Set<() => void>();
	const reviewSourceListeners = new Set<() => void>();
	const reviewCandidateSourceListeners = new Set<() => void>();
	const reviewRefreshPresentationListeners = new Set<() => void>();
	const reviewTreeRowById = new Map<string, BridgeMainReviewTreeDisplayRow>();
	const reviewTreeRowListeners = new BridgeMainKeyedListenerRegistry<string>();
	const workerReplacementListeners = new Set<() => void>();
	const fileTreePatchStreamUnsubscribers = new Set<() => void>();
	let isDisposed = false;
	let reviewCatalogChangeCursor = 0;
	const reviewCatalogChanges: BridgeMainReviewCatalogChange[] = [];
	let reviewCatalogSnapshot = emptyBridgeMainReviewCatalogSnapshot();
	const reviewCandidateBankOwner = new BridgeMainReviewCandidateBankOwner();
	const fileTreePatchStream: BridgeMainFileTreePatchStream = {
		getCursor: (): number =>
			isDisposed ? 0 : fileDisplayPatchApplier.fileTreePatchStream.getCursor(),
		getServerCursor: (): number =>
			isDisposed ? 0 : fileDisplayPatchApplier.fileTreePatchStream.getServerCursor(),
		readAfter: (
			cursor,
		): readonly ReturnType<BridgeMainFileTreePatchStream['readAfter']>[number][] =>
			isDisposed ? [] : fileDisplayPatchApplier.fileTreePatchStream.readAfter(cursor),
		subscribe: (listener): (() => void) => {
			if (isDisposed) return (): void => {};
			const unsubscribeFromStream = fileDisplayPatchApplier.fileTreePatchStream.subscribe(listener);
			let isSubscribed = true;
			const unsubscribe = (): void => {
				if (!isSubscribed) return;
				isSubscribed = false;
				fileTreePatchStreamUnsubscribers.delete(unsubscribe);
				unsubscribeFromStream();
			};
			fileTreePatchStreamUnsubscribers.add(unsubscribe);
			return unsubscribe;
		},
	};
	const publish = (nextSnapshot: MutableBridgeMainRenderSnapshot): void => {
		snapshot = nextSnapshot;
		for (const listener of listeners) {
			listener();
		}
	};
	const publishReviewRefreshPresentation = (): void => {
		publishBridgeMainListeners(reviewRefreshPresentationListeners);
	};
	const publishCandidatePresentation = (): void => {
		publishReviewRefreshPresentation();
		publishBridgeMainListeners(reviewCandidateSourceListeners);
	};
	const publishReviewCandidateTransition = (
		transition: () => boolean,
		notify: () => void,
	): boolean => {
		if (isDisposed) return false;
		const changed = transition();
		if (changed) notify();
		return changed;
	};
	const discardReviewCandidate = (identity?: BridgeMainReviewPublicationIdentity): boolean => {
		if (!reviewCandidateBankOwner.discard(identity)) return false;
		publishCandidatePresentation();
		return true;
	};
	const promoteReviewCandidate = (identity: BridgeMainReviewPublicationIdentity): boolean => {
		const candidate = reviewCandidateBankOwner.promote(identity);
		if (candidate === null) {
			// Metadata recovery supersedes an admitted candidate that never reached page installation.
			if (
				reviewCandidateBankOwner.currentPresentation.candidate?.role === 'installing' &&
				reviewCandidateBankOwner.currentCandidateSourceDiagnostic?.status === 'stale'
			) {
				discardReviewCandidate(identity);
			}
			return false;
		}
		publishBridgeMainListeners(reviewCandidateSourceListeners);
		const previousSnapshot = snapshot;
		const previousItemIds = Object.keys(previousSnapshot.reviewItemById);
		const nextItemIds = Object.keys(candidate.snapshot.reviewItemById);
		const previousRowIds = [...reviewTreeRowById.keys()];
		const nextRowIds = [...candidate.reviewTreeRowById.keys()];
		const publishesKeyedSameSourceChange = candidatePublishesKeyedSameSourceChange({
			candidate,
			previousSnapshot,
		});
		const completeItemIds = new Set([...previousItemIds, ...nextItemIds]);
		const completeRowIds = new Set([...previousRowIds, ...nextRowIds]);
		const affectedStableFileIdentities =
			candidate.startDisposition.kind === 'sameSource'
				? candidate.startDisposition.affectedStableFileIdentities
				: [];
		const promotedItemIds = publishesKeyedSameSourceChange
			? new Set([...candidate.promotionImpact.itemIds, ...affectedStableFileIdentities])
			: completeItemIds;
		const promotedRowIds = publishesKeyedSameSourceChange
			? candidate.promotionImpact.treeRowIds
			: completeRowIds;
		snapshot = mergeBridgeMainReviewCandidateSnapshot({
			activeSnapshot: previousSnapshot,
			candidateSnapshot: candidate.snapshot,
		});
		for (const itemId of previousItemIds) {
			if (
				previousSnapshot.codeViewItemsById[itemId] !== undefined &&
				snapshot.codeViewItemsById[itemId] === undefined
			) {
				releasePaintedCopy(itemId);
				pendingReviewPaintReleaseItemIds.delete(itemId);
			}
		}
		const selectionChanged = previousSnapshot.selectionSlice !== snapshot.selectionSlice;
		const availabilityItemIds = publishesKeyedSameSourceChange
			? changedRecordItemIds(
					previousSnapshot.contentAvailabilityById,
					snapshot.contentAvailabilityById,
					promotedItemIds,
				)
			: promotedItemIds;
		const codeViewItemIds = publishesKeyedSameSourceChange
			? changedRecordItemIds(
					previousSnapshot.codeViewItemsById,
					snapshot.codeViewItemsById,
					promotedItemIds,
				)
			: promotedItemIds;
		const rowPaintChanged = publishesKeyedSameSourceChange
			? changedRecordItemIds(previousSnapshot.rowPaintById, snapshot.rowPaintById, promotedItemIds)
					.size > 0
			: true;
		reviewItemIndexById.clear();
		for (const [itemId, itemIndex] of candidate.reviewItemIndexById) {
			reviewItemIndexById.set(itemId, itemIndex);
		}
		reviewTreeRowById.clear();
		for (const [rowId, row] of candidate.reviewTreeRowById) {
			reviewTreeRowById.set(rowId, row);
		}
		reviewCatalogChangeCursor += 1;
		reviewCatalogChanges.push({
			cursor: reviewCatalogChangeCursor,
			itemIds: [...promotedItemIds],
			itemOrderMutations: publishesKeyedSameSourceChange
				? candidate.promotionImpact.itemOrderMutations
				: [{ kind: 'replace', length: snapshot.reviewItemIdsByIndex.length }],
			reset: !publishesKeyedSameSourceChange,
			treeRowIds: [...promotedRowIds],
			treeRowOrderMutations: publishesKeyedSameSourceChange
				? candidate.promotionImpact.treeRowOrderMutations
				: [{ kind: 'replace', length: snapshot.reviewTreeRowsByIndex.length }],
		});
		if (reviewCatalogChanges.length > BRIDGE_MAIN_REVIEW_CATALOG_CHANGE_LIMIT) {
			reviewCatalogChanges.splice(
				0,
				reviewCatalogChanges.length - BRIDGE_MAIN_REVIEW_CATALOG_CHANGE_LIMIT,
			);
		}
		reviewCatalogSnapshot = {
			changeCursor: reviewCatalogChangeCursor,
			epoch: snapshot.reviewDisplayFreshness?.epoch ?? null,
			itemOrderLength: snapshot.reviewItemIdsByIndex.length,
			revision: snapshot.reviewDisplayFreshness?.projectionRevision ?? 0,
			treeRowOrderLength: snapshot.reviewTreeRowsByIndex.length,
		};
		if (
			!publishesKeyedSameSourceChange ||
			candidate.promotionImpact.comparisonChanged ||
			selectionChanged ||
			availabilityItemIds.size > 0 ||
			codeViewItemIds.size > 0 ||
			rowPaintChanged
		) {
			publish({ ...snapshot });
		}
		for (const itemId of promotedItemIds) reviewItemListeners.publish(itemId);
		for (const itemId of availabilityItemIds) reviewAvailabilityListeners.publish(itemId);
		for (const itemId of codeViewItemIds) reviewCodeViewItemListeners.publish(itemId);
		for (const rowId of promotedRowIds) {
			reviewTreeRowListeners.publish(rowId);
		}
		if (!publishesKeyedSameSourceChange || candidate.promotionImpact.sourceChanged) {
			publishBridgeMainListeners(reviewSourceListeners);
		}
		if (selectionChanged) publishBridgeMainListeners(reviewSelectionListeners);
		publishBridgeMainListeners(reviewCatalogListeners);
		publishReviewRefreshPresentation();
		return true;
	};

	return {
		dispose: (): void => {
			if (isDisposed) return;
			isDisposed = true;
			listeners.clear();
			viewRecoveryStatusByKind.clear();
			viewRecoveryStatusListeners.clear();
			reviewAvailabilityListeners.clear();
			reviewCatalogListeners.clear();
			reviewCodeViewItemListeners.clear();
			reviewItemListeners.clear();
			reviewSelectionListeners.clear();
			reviewSourceListeners.clear();
			reviewCandidateSourceListeners.clear();
			reviewRefreshPresentationListeners.clear();
			reviewTreeRowListeners.clear();
			workerReplacementListeners.clear();
			for (const unsubscribe of fileTreePatchStreamUnsubscribers) unsubscribe();
			reviewItemIndexById.clear();
			reviewTreeRowById.clear();
			reviewCatalogChanges.length = 0;
			reviewCatalogChangeCursor = 0;
			reviewCandidateBankOwner.dispose();
			pendingReviewPaintReleaseItemIds.clear();
			snapshot = emptyBridgeMainRenderSnapshot(new BridgeMainFileDisplayPatchApplier().state);
			reviewCatalogSnapshot = emptyBridgeMainReviewCatalogSnapshot();
		},
		getSnapshot: (): BridgeMainRenderSnapshot => snapshot,
		hasPendingReviewPaintRelease: (itemId): boolean => pendingReviewPaintReleaseItemIds.has(itemId),
		getServerSnapshot: (): BridgeMainRenderSnapshot => snapshot,
		getViewRecoveryStatus: (kind): BridgeMainViewRecoveryStatus | null =>
			viewRecoveryStatusByKind.get(kind) ?? null,
		subscribeViewRecoveryStatus: (listener): (() => void) => {
			if (isDisposed) return (): void => {};
			viewRecoveryStatusListeners.add(listener);
			return (): void => {
				viewRecoveryStatusListeners.delete(listener);
			};
		},
		applyViewRecoveryStatusEvent: (event): void => {
			if (isDisposed) return;
			const previousStatus = viewRecoveryStatusByKind.get(event.view.kind);
			if (
				previousStatus?.view.subscriptionId === event.view.subscriptionId &&
				previousStatus.status === event.status
			)
				return;
			viewRecoveryStatusByKind.set(event.view.kind, { status: event.status, view: event.view });
			publishBridgeMainListeners(viewRecoveryStatusListeners);
		},
		prepareForWorkerReplacement: (): void => {
			if (isDisposed) return;
			for (const itemId of Object.keys(snapshot.codeViewItemsById))
				pendingReviewPaintReleaseItemIds.add(itemId);
			publishBridgeMainListeners(workerReplacementListeners);
			discardReviewCandidate();
			if (reviewCandidateBankOwner.clearFailure()) publishReviewRefreshPresentation();
			const fileDisplayState = fileDisplayPatchApplier.prepareForWorkerReplacement();
			publish({
				...snapshot,
				...fileDisplayState,
				reviewDisplayFreshness: null,
			});
		},
		getReviewAvailabilitySnapshot: (
			itemId,
		): BridgeWorkerContentAvailabilityPatchPayload | undefined =>
			snapshot.contentAvailabilityById[itemId],
		getReviewCatalogSnapshot: (): BridgeMainReviewCatalogSnapshot => reviewCatalogSnapshot,
		getReviewCodeViewItemSnapshot: (itemId): BridgeMainCodeViewItem | undefined =>
			snapshot.codeViewItemsById[itemId],
		getReviewItemIdAtIndex: (itemIndex): string | null | undefined =>
			snapshot.reviewItemIdsByIndex[itemIndex],
		getReviewItemSnapshot: (itemId): BridgeWorkerReviewDisplayItem | undefined =>
			snapshot.reviewItemById[itemId],
		readReviewCatalogChangesAfter: (cursor): BridgeMainReviewCatalogChangeRead =>
			readBridgeMainReviewCatalogChangesAfter({
				changes: reviewCatalogChanges,
				currentCursor: reviewCatalogChangeCursor,
				cursor,
			}),
		reviewCatalogContainsItem: (itemId): boolean => reviewItemIndexById.has(itemId),
		getReviewSelectionSnapshot: (): BridgeMainSelectionSlice => snapshot.selectionSlice,
		getReviewSourceSnapshot: (): BridgeMainReviewSourceDisplaySlice | null =>
			snapshot.reviewSourceSlice,
		getReviewRefreshPresentation: (): BridgeMainReviewRefreshPresentation =>
			reviewCandidateBankOwner.currentPresentation,
		getReviewCandidateSourceDiagnostic: () =>
			reviewCandidateBankOwner.currentCandidateSourceDiagnostic,
		getReviewTreeRowSnapshot: (rowId): BridgeMainReviewTreeDisplayRow | undefined =>
			reviewTreeRowById.get(rowId),
		getReviewTreeRowAtIndex: (treeRowIndex): BridgeMainReviewTreeDisplayRow | null | undefined =>
			snapshot.reviewTreeRowsByIndex[treeRowIndex],
		subscribe: (listener: () => void): (() => void) => {
			if (isDisposed) return (): void => {};
			listeners.add(listener);
			return (): void => {
				listeners.delete(listener);
			};
		},
		subscribeReviewAvailability: (itemId, listener): (() => void) =>
			isDisposed ? (): void => {} : reviewAvailabilityListeners.subscribe(itemId, listener),
		subscribeReviewCatalog: (listener): (() => void) =>
			isDisposed ? (): void => {} : subscribeBridgeMainListener(reviewCatalogListeners, listener),
		subscribeReviewCodeViewItem: (itemId, listener): (() => void) =>
			isDisposed ? (): void => {} : reviewCodeViewItemListeners.subscribe(itemId, listener),
		subscribeReviewItem: (itemId, listener): (() => void) =>
			isDisposed ? (): void => {} : reviewItemListeners.subscribe(itemId, listener),
		subscribeReviewSelection: (listener): (() => void) =>
			isDisposed ? (): void => {} : subscribeBridgeMainListener(reviewSelectionListeners, listener),
		subscribeReviewSource: (listener): (() => void) =>
			isDisposed ? (): void => {} : subscribeBridgeMainListener(reviewSourceListeners, listener),
		subscribeReviewCandidateSource: (listener): (() => void) =>
			isDisposed
				? (): void => {}
				: subscribeBridgeMainListener(reviewCandidateSourceListeners, listener),
		subscribeReviewRefreshPresentation: (listener): (() => void) =>
			isDisposed
				? (): void => {}
				: subscribeBridgeMainListener(reviewRefreshPresentationListeners, listener),
		subscribeReviewTreeRow: (rowId, listener): (() => void) =>
			isDisposed ? (): void => {} : reviewTreeRowListeners.subscribe(rowId, listener),
		subscribeWorkerReplacement: (listener): (() => void) =>
			isDisposed
				? (): void => {}
				: subscribeBridgeMainListener(workerReplacementListeners, listener),
		setLocalSelection: (props: SetBridgeMainLocalSelectionProps): void => {
			if (isDisposed) return;
			publish(
				buildSnapshotFromUpdate(snapshot, {
					localSelection: props,
				}),
			);
			publishBridgeMainListeners(reviewSelectionListeners);
		},
		setLocalViewport: (props: SetBridgeMainLocalViewportProps): void => {
			if (isDisposed) return;
			publish(
				buildSnapshotFromUpdate(snapshot, {
					localViewport: props,
				}),
			);
		},
		setWorkerCodeViewItem: (props): void => {
			if (isDisposed) return;
			pendingReviewPaintReleaseItemIds.delete(props.itemId);
			publish(
				buildSnapshotFromUpdate(snapshot, {
					codeViewItemPatches: [
						{
							operation: 'upsert',
							itemId: props.itemId,
							item: props.item,
						},
					],
				}),
			);
			reviewCodeViewItemListeners.publish(props.itemId);
		},
		setReviewCandidateCodeViewItem: (props): boolean => {
			if (isDisposed) return false;
			return reviewCandidateBankOwner.update(props.identity, (candidateSnapshot, containsItem) =>
				containsItem(props.itemId)
					? buildSnapshotFromUpdate(candidateSnapshot, {
							codeViewItemPatches: [
								{ item: props.item, itemId: props.itemId, operation: 'upsert' },
							],
						})
					: null,
			);
		},
		startReviewCandidate: (props): boolean => {
			if (isDisposed) return false;
			const started = reviewCandidateBankOwner.start({ activeSnapshot: snapshot, ...props });
			if (started) publishCandidatePresentation();
			return started;
		},
		stageReviewCandidateDisplayEvent: (props): boolean => {
			if (isDisposed) return false;
			const presentationBeforeStage = reviewCandidateBankOwner.currentPresentation;
			const staged = reviewCandidateBankOwner.stage({ activeSnapshot: snapshot, ...props });
			if (staged && reviewCandidateBankOwner.currentPresentation !== presentationBeforeStage) {
				publishReviewRefreshPresentation();
			}
			if (staged) publishBridgeMainListeners(reviewCandidateSourceListeners);
			return staged;
		},
		applyReviewCandidateSnapshotUpdate: (update): boolean => {
			if (isDisposed) return false;
			return reviewCandidateBankOwner.update(update.identity, (candidateSnapshot, containsItem) =>
				buildSnapshotFromUpdate(candidateSnapshot, {
					...(update.codeViewItemPatches === undefined
						? {}
						: { codeViewItemPatches: update.codeViewItemPatches }),
					...(update.workerPatches === undefined
						? {}
						: {
								workerPatches: update.workerPatches.filter(
									(patch): boolean =>
										patch.slice === 'panelChrome' ||
										patch.operation === 'reset' ||
										containsItem(patch.itemId),
								),
							}),
				}),
			);
		},
		markReviewCandidateReady: (props): boolean =>
			publishReviewCandidateTransition(
				() => reviewCandidateBankOwner.markReady(props),
				publishReviewRefreshPresentation,
			),
		escalateReviewCandidatePresentation: (props): boolean =>
			publishReviewCandidateTransition(
				() => reviewCandidateBankOwner.escalatePresentation(props),
				publishReviewRefreshPresentation,
			),
		failReviewCandidate: (props): boolean =>
			publishReviewCandidateTransition(
				() => reviewCandidateBankOwner.fail(props),
				publishCandidatePresentation,
			),
		clearReviewCandidateFailure: (): boolean =>
			publishReviewCandidateTransition(
				() => reviewCandidateBankOwner.clearFailure(),
				publishReviewRefreshPresentation,
			),
		failReviewInstallation: (identity): boolean =>
			publishReviewCandidateTransition(
				() => reviewCandidateBankOwner.failInstallation(identity),
				publishCandidatePresentation,
			),
		promoteReviewCandidate: (identity): boolean =>
			isDisposed ? false : promoteReviewCandidate(identity),
		discardReviewCandidate: (identity): boolean =>
			isDisposed ? false : discardReviewCandidate(identity),
		applyWorkerPatch: (patch: BridgeWorkerSlicePatch): void => {
			if (isDisposed) return;
			if (
				patch.slice === 'contentAvailability' &&
				patch.operation === 'upsert' &&
				(patch.payload.state === 'failed' || patch.payload.state === 'unavailable')
			)
				pendingReviewPaintReleaseItemIds.delete(patch.itemId);
			const previousSnapshot = snapshot;
			const availabilityItemIdsBeforeReset =
				patch.slice === 'contentAvailability' && patch.operation === 'reset'
					? Object.keys(snapshot.contentAvailabilityById)
					: [];
			const codeViewItemIdsBeforeReset =
				patch.slice === 'rowPaint' && patch.operation === 'reset'
					? Object.keys(snapshot.codeViewItemsById)
					: [];
			publish(
				buildSnapshotFromUpdate(snapshot, {
					workerPatches: [patch],
				}),
			);
			if (
				patch.slice === 'rowPaint' &&
				patch.operation === 'delete' &&
				previousSnapshot.codeViewItemsById[patch.itemId] !== undefined &&
				snapshot.codeViewItemsById[patch.itemId] === undefined
			)
				releasePaintedCopy(patch.itemId);
			publishReviewWorkerPatchListeners({
				availabilityItemIdsBeforeReset,
				patch,
				reviewAvailabilityListeners,
				reviewSelectionListeners,
			});
			publishReviewCodeViewWorkerPatchListeners({
				codeViewItemIdsBeforeReset,
				patch,
				reviewCodeViewItemListeners,
			});
		},
		applySnapshotUpdate: (update: BridgeMainRenderSnapshotUpdate): void => {
			if (isDisposed) return;
			for (const patch of update.codeViewItemPatches ?? []) {
				if (patch.operation === 'upsert') pendingReviewPaintReleaseItemIds.delete(patch.itemId);
			}
			const previousCodeViewItems = snapshot.codeViewItemsById;
			const availabilityItemIdsBeforeReset = update.workerPatches?.some(
				(patch): boolean => patch.slice === 'contentAvailability' && patch.operation === 'reset',
			)
				? Object.keys(snapshot.contentAvailabilityById)
				: [];
			const codeViewItemIdsBeforeUpdate =
				update.codeViewItemPatches?.some((patch): boolean => patch.operation === 'reset') ===
					true ||
				update.workerPatches?.some(
					(patch): boolean => patch.slice === 'rowPaint' && patch.operation === 'reset',
				) === true
					? Object.keys(snapshot.codeViewItemsById)
					: [];
			publish(buildSnapshotFromUpdate(snapshot, update));
			for (const itemId of Object.keys(previousCodeViewItems)) {
				if (snapshot.codeViewItemsById[itemId] === undefined) releasePaintedCopy(itemId);
			}
			publishReviewCodeViewItemPatchListeners({
				codeViewItemIdsBeforeUpdate,
				patches: update.codeViewItemPatches ?? [],
				reviewCodeViewItemListeners,
			});
			for (const patch of update.workerPatches ?? []) {
				publishReviewWorkerPatchListeners({
					availabilityItemIdsBeforeReset,
					patch,
					reviewAvailabilityListeners,
					reviewSelectionListeners,
				});
				publishReviewCodeViewWorkerPatchListeners({
					codeViewItemIdsBeforeReset: codeViewItemIdsBeforeUpdate,
					patch,
					reviewCodeViewItemListeners,
				});
			}
			if (update.localSelection !== undefined) {
				publishBridgeMainListeners(reviewSelectionListeners);
			}
		},
		applyFileDisplayPatchEvent: (event: BridgeWorkerFileDisplayPatchEvent): void => {
			if (isDisposed) return;
			const fileDisplayState = fileDisplayPatchApplier.applyEvent(event);
			if (fileDisplayState !== null) publish({ ...snapshot, ...fileDisplayState });
		},
		applyReviewDisplayPatchEvent: (event: BridgeWorkerReviewDisplayPatchEvent): void => {
			if (isDisposed) return;
			const shouldPublishInitialRootSnapshot = snapshot.reviewDisplayFreshness === null;
			const activeIdentity = reviewCandidateBankOwner.currentPresentation.activeIdentity;
			const incomingIdentity = event.reviewPublicationIdentity;
			const replaysExactActivePublication =
				activeIdentity !== null &&
				incomingIdentity !== null &&
				activeIdentity.packageId === incomingIdentity.packageId &&
				activeIdentity.publicationId === incomingIdentity.publicationId &&
				activeIdentity.generation === incomingIdentity.reviewGeneration &&
				activeIdentity.revision === incomingIdentity.revision &&
				activeIdentity.sourceIdentity === incomingIdentity.sourceIdentity;
			const replacesWorkerDerivationEpoch =
				snapshot.reviewDisplayFreshness !== null &&
				event.epoch > snapshot.reviewDisplayFreshness.epoch &&
				!replaysExactActivePublication;
			const effect = applyReviewDisplayPatchEventInPlace({
				event,
				reviewItemIndexById,
				reviewTreeRowById,
				snapshot,
			});
			if (effect === null) return;
			const renderCopyInvalidation = invalidateBridgeMainReviewRenderCopies({
				itemIds: bridgeMainReviewRenderCopyInvalidationItemIds({
					currentItemsById: snapshot.reviewItemById,
					previousItemsById: effect.previousItemsById,
					preserveProjectionHiddenCopies:
						incomingIdentity === null || replaysExactActivePublication,
					retainedRenderCopyItemIds: bridgeMainReviewRetainedRenderCopyItemIds(snapshot),
					replacesWorkerDerivationEpoch,
				}),
				selectionItemIds: [...effect.itemIds],
				snapshot,
			});
			for (const itemId of renderCopyInvalidation.codeViewItemIds) {
				releasePaintedCopy(itemId);
			}
			const renderCopyMetadataReconciliation = reconcileBridgeMainReviewRenderCopyMetadata({
				currentItemsById: snapshot.reviewItemById,
				previousItemsById: effect.previousItemsById,
				snapshot: renderCopyInvalidation.snapshot,
			});
			snapshot = renderCopyMetadataReconciliation.snapshot;
			reviewCatalogChangeCursor += 1;
			const catalogChange: BridgeMainReviewCatalogChange = {
				cursor: reviewCatalogChangeCursor,
				itemIds: [...effect.itemIds],
				itemOrderMutations: effect.itemOrderMutations,
				reset: effect.reset,
				treeRowIds: [...effect.treeRowIds],
				treeRowOrderMutations: effect.treeRowOrderMutations,
			};
			reviewCatalogChanges.push(catalogChange);
			if (reviewCatalogChanges.length > BRIDGE_MAIN_REVIEW_CATALOG_CHANGE_LIMIT) {
				reviewCatalogChanges.splice(
					0,
					reviewCatalogChanges.length - BRIDGE_MAIN_REVIEW_CATALOG_CHANGE_LIMIT,
				);
			}
			reviewCatalogSnapshot = {
				changeCursor: reviewCatalogChangeCursor,
				epoch: event.epoch,
				itemOrderLength: snapshot.reviewItemIdsByIndex.length,
				revision: event.projectionRevision,
				treeRowOrderLength: snapshot.reviewTreeRowsByIndex.length,
			};
			if (
				shouldPublishInitialRootSnapshot ||
				effect.comparisonChanged ||
				renderCopyInvalidation.changed ||
				renderCopyMetadataReconciliation.changed
			) {
				publish({ ...snapshot });
			}
			for (const itemId of effect.itemIds) reviewItemListeners.publish(itemId);
			for (const rowId of effect.treeRowIds) reviewTreeRowListeners.publish(rowId);
			if (effect.sourceChanged) publishBridgeMainListeners(reviewSourceListeners);
			if (renderCopyInvalidation.selectionChanged) {
				publishBridgeMainListeners(reviewSelectionListeners);
			}
			for (const itemId of renderCopyInvalidation.availabilityItemIds) {
				reviewAvailabilityListeners.publish(itemId);
			}
			for (const itemId of renderCopyInvalidation.codeViewItemIds) {
				reviewCodeViewItemListeners.publish(itemId);
			}
			for (const itemId of renderCopyMetadataReconciliation.codeViewItemIds) {
				reviewCodeViewItemListeners.publish(itemId);
			}
			publishBridgeMainListeners(reviewCatalogListeners);
		},
		completeFileQueryTransaction: (transactionId: string): boolean => {
			if (isDisposed) return false;
			const fileDisplayState = fileDisplayPatchApplier.completeQueryTransaction(transactionId);
			if (fileDisplayState === null) return false;
			publish({ ...snapshot, ...fileDisplayState });
			onFileQueryTransactionPublished?.(transactionId);
			return true;
		},
		fileTreePatchStream,
	};
}

function emptyBridgeMainRenderSnapshot(
	fileDisplayState: BridgeMainFileDisplayState,
): MutableBridgeMainRenderSnapshot {
	return {
		...fileDisplayState,
		...emptyBridgeMainReviewDisplayState(),
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
		codeViewItemsById: {},
		panelChromeSlice: {},
	};
}

function subscribeBridgeMainListener(listeners: Set<() => void>, listener: () => void): () => void {
	listeners.add(listener);
	return (): void => {
		listeners.delete(listener);
	};
}

function publishBridgeMainListeners(listeners: ReadonlySet<() => void>): void {
	for (const listener of listeners) listener();
}

function candidatePublishesKeyedSameSourceChange(props: {
	readonly candidate: MutableBridgeMainReviewCandidateBank;
	readonly previousSnapshot: MutableBridgeMainRenderSnapshot;
}): boolean {
	const disposition = props.candidate.startDisposition;
	if (disposition.kind !== 'sameSource' || props.candidate.promotionImpact.reset) return false;
	if (
		disposition.presentationClass.kind === 'promoted' &&
		disposition.presentationClass.reason === 'unknown'
	) {
		return false;
	}
	const previousSource = props.previousSnapshot.reviewSourceSlice;
	return (
		previousSource !== null &&
		previousSource.status !== 'failed' &&
		previousSource.status !== 'readyEmpty' &&
		previousSource.packageId === props.candidate.identity.packageId &&
		previousSource.reviewGeneration === props.candidate.identity.generation &&
		previousSource.metadataSourceId === props.candidate.identity.sourceIdentity
	);
}

function changedRecordItemIds<TValue>(
	previous: Readonly<Record<string, TValue>>,
	next: Readonly<Record<string, TValue>>,
	candidateItemIds: ReadonlySet<string>,
): ReadonlySet<string> {
	const changedItemIds = new Set<string>();
	for (const itemId of candidateItemIds) {
		if (previous[itemId] !== next[itemId]) changedItemIds.add(itemId);
	}
	return changedItemIds;
}

function publishReviewWorkerPatchListeners(props: {
	readonly availabilityItemIdsBeforeReset: readonly string[];
	readonly patch: BridgeWorkerSlicePatch;
	readonly reviewAvailabilityListeners: BridgeMainKeyedListenerRegistry<string>;
	readonly reviewSelectionListeners: ReadonlySet<() => void>;
}): void {
	if (props.patch.slice === 'selection') {
		publishBridgeMainListeners(props.reviewSelectionListeners);
		return;
	}
	if (props.patch.slice !== 'contentAvailability') return;
	if (props.patch.operation === 'reset') {
		for (const itemId of props.availabilityItemIdsBeforeReset) {
			props.reviewAvailabilityListeners.publish(itemId);
		}
		return;
	}
	props.reviewAvailabilityListeners.publish(props.patch.itemId);
}

function publishReviewCodeViewItemPatchListeners(props: {
	readonly codeViewItemIdsBeforeUpdate: readonly string[];
	readonly patches: readonly BridgeMainCodeViewItemPatch[];
	readonly reviewCodeViewItemListeners: BridgeMainKeyedListenerRegistry<string>;
}): void {
	const affectedItemIds = new Set<string>();
	for (const patch of props.patches) {
		if (patch.operation === 'reset') {
			for (const itemId of props.codeViewItemIdsBeforeUpdate) affectedItemIds.add(itemId);
			continue;
		}
		affectedItemIds.add(patch.itemId);
	}
	for (const itemId of affectedItemIds) props.reviewCodeViewItemListeners.publish(itemId);
}

function publishReviewCodeViewWorkerPatchListeners(props: {
	readonly codeViewItemIdsBeforeReset: readonly string[];
	readonly patch: BridgeWorkerSlicePatch;
	readonly reviewCodeViewItemListeners: BridgeMainKeyedListenerRegistry<string>;
}): void {
	if (props.patch.slice !== 'rowPaint') return;
	if (props.patch.operation === 'reset') {
		for (const itemId of props.codeViewItemIdsBeforeReset) {
			props.reviewCodeViewItemListeners.publish(itemId);
		}
		return;
	}
	if (props.patch.operation === 'delete') {
		props.reviewCodeViewItemListeners.publish(props.patch.itemId);
	}
}
