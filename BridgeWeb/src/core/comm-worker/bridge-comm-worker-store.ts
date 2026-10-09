import { createStore, type StoreApi } from 'zustand/vanilla';

import {
	createBridgeBodyRegistry,
	type BridgeBodyRegistry,
} from '../demand/bridge-body-registry.js';
import { bridgeContentDemandRetentionPolicy } from '../demand/bridge-content-demand-policy.js';
import type { BridgeCommWorkerFileViewRuntimeMutation } from './bridge-comm-worker-file-view-runtime-mutation.js';
import {
	applyBridgeCommWorkerFileViewSourceMutationFact,
	applyBridgeCommWorkerFileViewSourceUpdateFact,
} from './bridge-comm-worker-file-view-source-update.js';
import {
	isBridgeCommWorkerDemandEligibleContentMetadata,
	reconcileBridgeCommWorkerDemandMembership,
	serializeBridgeCommWorkerDemandMembership,
} from './bridge-comm-worker-reconciler.js';
import { instrumentBridgeCommWorkerStoreActions } from './bridge-comm-worker-store-telemetry.js';
import type { BridgeCommWorkerTelemetryRecorder } from './bridge-comm-worker-telemetry.js';
import type { BridgeProductSurface } from './bridge-product-contract-primitives.js';
import {
	BRIDGE_WORKER_WIRE_VERSION,
	bridgeWorkerSlicePatchEventSchema,
	type BridgeWorkerContentMetadata,
	type BridgeWorkerContentAvailabilityPatchPayload,
	type BridgeWorkerFileViewContentMetadata,
	type BridgeWorkerReviewContentMetadata,
	type BridgeWorkerSlicePatch,
	type BridgeWorkerSlicePatchEvent,
} from './bridge-worker-contracts.js';
import { BridgeWorkerRenderFulfillmentRegistry } from './bridge-worker-render-fulfillment-registry.js';
import type { BridgeWorkerResidentReviewContentBody } from './bridge-worker-review-content-fetch.js';

export interface BridgeCommWorkerRow {
	readonly id: string;
	readonly parentId: string | null;
	readonly index: number;
}

export interface BridgeCommWorkerViewportRange {
	readonly firstVisibleIndex: number;
	readonly lastVisibleIndex: number;
}

export interface BridgeCommWorkerStoreState {
	readonly rowById: Map<string, BridgeCommWorkerRow>;
	readonly orderedIds: Array<string | undefined>;
	readonly indexById: Map<string, number>;
	readonly childrenByParentId: Map<string, Set<string>>;
	readonly hoveredItemId: string | null;
	readonly selectedId: string | null;
	readonly selectedEpoch: number;
	readonly selectedDemandEnabled: boolean;
	readonly viewportRange: BridgeCommWorkerViewportRange | null;
	readonly visibleIds: readonly string[];
	readonly demandByKey: Map<string, string>;
	readonly byteCache: Map<string, string>;
	readonly paintReadyByItemId: Map<string, string>;
	readonly availabilityByItemId: Map<string, BridgeWorkerContentAvailabilityPatchPayload['state']>;
	readonly contentMetadataByItemId: Map<string, BridgeWorkerContentMetadata>;
}

export interface BridgeCommWorkerStoreRollbackSnapshot {
	readonly pendingSlicePatches: readonly BridgeWorkerSlicePatch[];
	readonly state: BridgeCommWorkerStoreState;
}

export interface CreateBridgeCommWorkerStoreProps {
	readonly contentItems: readonly BridgeWorkerContentMetadata[];
	readonly now?: () => number;
	readonly renderFulfillmentRegistry?: BridgeWorkerRenderFulfillmentRegistry;
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly surface: BridgeProductSurface;
	readonly telemetryClient?: BridgeCommWorkerTelemetryRecorder;
}

export interface BridgeCommWorkerTouchedResult {
	readonly resultReason?: BridgeCommWorkerContentAvailabilityReason;
	readonly selectedFileViewContentMetadataChanged?: boolean;
	readonly sourceEpoch?: number;
	readonly touchedKeys: readonly string[];
}

export interface ApplyBridgeCommWorkerSelectedFactProps {
	readonly itemId: string;
	readonly epoch: number;
}

export interface ApplyBridgeCommWorkerViewportFactProps {
	readonly visibleItemIds: readonly string[];
	readonly firstVisibleIndex: number;
	readonly lastVisibleIndex: number;
}

export interface ApplyBridgeCommWorkerHoveredFactProps {
	readonly hoveredItemId: string | null;
}

export interface ApplyBridgeCommWorkerContentReadyProps {
	readonly itemId: string;
	readonly contentCacheKey: string;
}

type BridgeCommWorkerTerminalContentAvailabilityState = Extract<
	BridgeWorkerContentAvailabilityPatchPayload['state'],
	'failed' | 'unavailable'
>;
type BridgeCommWorkerContentAvailabilityReason = NonNullable<
	BridgeWorkerContentAvailabilityPatchPayload['reason']
>;

export interface ApplyBridgeCommWorkerContentTerminalAvailabilityProps {
	readonly itemId: string;
	readonly reason: BridgeCommWorkerContentAvailabilityReason;
	readonly sourceEpoch: number;
	readonly state: BridgeCommWorkerTerminalContentAvailabilityState;
}

export interface ApplyBridgeCommWorkerReviewInvalidationFactProps {
	readonly epoch: number;
	readonly scope: 'package' | 'items' | 'paths' | 'treeWindow';
	readonly itemIds: readonly string[];
	readonly pathHints: readonly string[];
	readonly reason: 'sourceChanged' | 'watchEvent' | 'lineageReplaced' | 'unknown';
}

export interface ApplyBridgeCommWorkerSelectedSourceChurnFactProps {
	readonly itemId: string;
}

export interface BridgeCommWorkerSelectedDemandResult extends BridgeCommWorkerTouchedResult {
	readonly selectedDemandEpoch: number | null;
}

export interface ApplyBridgeCommWorkerReviewSourceUpdateFactProps {
	readonly completeContentItemIds?: readonly string[];
	readonly completeRowIds?: readonly string[];
	readonly contentItems: readonly BridgeWorkerReviewContentMetadata[];
	readonly epoch: number;
	readonly removedContentItemIds?: readonly string[];
	readonly resetComplete?: boolean;
	readonly rows: readonly BridgeCommWorkerRow[];
}

export interface BridgeCommWorkerReviewRowMutation {
	readonly removedRowIds: readonly string[];
	readonly rowUpserts: readonly BridgeCommWorkerRow[];
}

export interface ApplyBridgeCommWorkerReviewRowMutationFactProps {
	readonly epoch: number;
	readonly mutation: BridgeCommWorkerReviewRowMutation;
}

export interface ApplyBridgeCommWorkerFileViewSourceUpdateFactProps {
	readonly contentItems: readonly BridgeWorkerFileViewContentMetadata[];
	readonly epoch: number;
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly selectedContentRequestChanged: boolean;
}

export interface ApplyBridgeCommWorkerFileViewSourceMutationFactProps {
	readonly epoch: number;
	readonly mutation: BridgeCommWorkerFileViewRuntimeMutation;
	readonly selectedContentRequestChanged: boolean;
}

export interface TakePendingBridgeCommWorkerSlicePatchEventProps {
	readonly epoch: number;
	readonly sequence: number;
}

export interface BridgeCommWorkerStore {
	readonly captureRollbackSnapshot: () => BridgeCommWorkerStoreRollbackSnapshot;
	readonly getState: () => BridgeCommWorkerStoreState;
	readonly reviewBodyRegistry: BridgeBodyRegistry<BridgeWorkerResidentReviewContentBody>;
	readonly renderFulfillmentRegistry: BridgeWorkerRenderFulfillmentRegistry;
	readonly restoreRollbackSnapshot: (snapshot: BridgeCommWorkerStoreRollbackSnapshot) => void;
	readonly subscribe: StoreApi<BridgeCommWorkerStoreState>['subscribe'];
	readonly actions: {
		readonly clearSelectedFact: (props: {
			readonly epoch: number;
		}) => BridgeCommWorkerTouchedResult;
		readonly applyHoveredFact: (
			props: ApplyBridgeCommWorkerHoveredFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applySelectedFact: (
			props: ApplyBridgeCommWorkerSelectedFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyViewportFact: (
			props: ApplyBridgeCommWorkerViewportFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyContentReady: (
			props: ApplyBridgeCommWorkerContentReadyProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyContentTerminalAvailability: (
			props: ApplyBridgeCommWorkerContentTerminalAvailabilityProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyReviewInvalidationFact: (
			props: ApplyBridgeCommWorkerReviewInvalidationFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applySelectedSourceChurnFact: (
			props: ApplyBridgeCommWorkerSelectedSourceChurnFactProps,
		) => BridgeCommWorkerSelectedDemandResult;
		readonly applyReviewSourceUpdateFact: (
			props: ApplyBridgeCommWorkerReviewSourceUpdateFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyReviewRowMutationFact: (
			props: ApplyBridgeCommWorkerReviewRowMutationFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyFileViewSourceUpdateFact: (
			props: ApplyBridgeCommWorkerFileViewSourceUpdateFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly applyFileViewSourceMutationFact: (
			props: ApplyBridgeCommWorkerFileViewSourceMutationFactProps,
		) => BridgeCommWorkerTouchedResult;
		readonly takePendingSlicePatchEvent: (
			props: TakePendingBridgeCommWorkerSlicePatchEventProps,
		) => BridgeWorkerSlicePatchEvent | null;
	};
}

export function createBridgeCommWorkerStore(
	props: CreateBridgeCommWorkerStoreProps,
): BridgeCommWorkerStore {
	const store = createStore<BridgeCommWorkerStoreState>(() =>
		buildInitialBridgeCommWorkerStoreState(props),
	);
	const pendingSlicePatches: BridgeWorkerSlicePatch[] = [];
	const now = props.now ?? performance.now.bind(performance);
	const renderFulfillmentRegistry =
		props.renderFulfillmentRegistry ??
		new BridgeWorkerRenderFulfillmentRegistry({
			context: {
				paneSessionId: 'worker-local-unbound-pane',
				surface: props.surface,
				workerInstanceId: 'worker-local-unbound-instance',
			},
			...(props.now === undefined ? {} : { now: props.now }),
			receiptLeaseDurationMilliseconds: 5000,
			retryBackoffMilliseconds: 25,
		});

	const workerStore: BridgeCommWorkerStore = {
		captureRollbackSnapshot: (): BridgeCommWorkerStoreRollbackSnapshot => ({
			pendingSlicePatches: [...pendingSlicePatches],
			state: cloneBridgeCommWorkerStoreState(store.getState()),
		}),
		getState: store.getState,
		reviewBodyRegistry: createBridgeBodyRegistry({
			maxBytes: bridgeContentDemandRetentionPolicy.reviewBodyRegistryMaxBytes,
		}),
		renderFulfillmentRegistry,
		restoreRollbackSnapshot: (snapshot): void => {
			store.setState(cloneBridgeCommWorkerStoreState(snapshot.state), true);
			pendingSlicePatches.splice(0, pendingSlicePatches.length, ...snapshot.pendingSlicePatches);
		},
		subscribe: store.subscribe,
		actions: {
			clearSelectedFact: (fact): BridgeCommWorkerTouchedResult => {
				const previousState = store.getState();
				store.setState({
					...previousState,
					selectedDemandEnabled: false,
					selectedEpoch: fact.epoch,
					selectedId: null,
					demandByKey: buildDemandByKey({
						contentMetadataByItemId: previousState.contentMetadataByItemId,
						hoveredItemId: previousState.hoveredItemId,
						selectedDemandEpoch: null,
						selectedId: null,
						visibleIds: previousState.visibleIds,
					}),
				});
				pendingSlicePatches.push({ operation: 'delete', slice: 'selection' });
				return {
					touchedKeys:
						previousState.selectedId === null
							? []
							: ['selectedId', `demand:${previousState.selectedId}`],
				};
			},
			applyHoveredFact: (
				fact: ApplyBridgeCommWorkerHoveredFactProps,
			): BridgeCommWorkerTouchedResult => {
				const previousState = store.getState();
				if (previousState.hoveredItemId === fact.hoveredItemId) {
					return { touchedKeys: [] };
				}
				store.setState({
					...previousState,
					hoveredItemId: fact.hoveredItemId,
					demandByKey: buildDemandByKey({
						contentMetadataByItemId: previousState.contentMetadataByItemId,
						hoveredItemId: fact.hoveredItemId,
						selectedDemandEpoch: readSelectedDemandEpoch(previousState),
						selectedId: previousState.selectedId,
						visibleIds: previousState.visibleIds,
					}),
				});
				return {
					touchedKeys: [
						'hoveredItemId',
						...(previousState.hoveredItemId === null
							? []
							: [`demand:${previousState.hoveredItemId}`]),
						...(fact.hoveredItemId === null ? [] : [`demand:${fact.hoveredItemId}`]),
					],
				};
			},
			applySelectedFact: (
				fact: ApplyBridgeCommWorkerSelectedFactProps,
			): BridgeCommWorkerTouchedResult => {
				const contentMetadata = store.getState().contentMetadataByItemId.get(fact.itemId) ?? null;
				const isDemandEligible = isBridgeCommWorkerDemandEligibleContentMetadata(contentMetadata);
				const selectedDemandEnabled = isDemandEligible;
				const nextAvailabilityState =
					(props.surface === 'file' && contentMetadata === null) || selectedDemandEnabled
						? 'loading'
						: 'unavailable';
				store.setState((state) => {
					const selectedState = {
						...state,
						selectedDemandEnabled,
						selectedEpoch: fact.epoch,
						selectedId: fact.itemId,
						demandByKey: buildDemandByKey({
							contentMetadataByItemId: state.contentMetadataByItemId,
							hoveredItemId: state.hoveredItemId,
							selectedId: fact.itemId,
							selectedDemandEpoch: selectedDemandEnabled ? fact.epoch : null,
							visibleIds: state.visibleIds,
						}),
					};
					return nextAvailabilityState === null
						? selectedState
						: writeBridgeWorkerMap(
								selectedState,
								'availabilityByItemId',
								fact.itemId,
								nextAvailabilityState,
							);
				});
				pendingSlicePatches.push({
					slice: 'selection',
					operation: 'upsert',
					payload: { selectedItemId: fact.itemId },
				});
				if (nextAvailabilityState !== null) {
					pendingSlicePatches.push({
						slice: 'contentAvailability',
						operation: 'upsert',
						itemId: fact.itemId,
						payload: { state: nextAvailabilityState },
					});
				}
				return {
					touchedKeys: [
						'selectedId',
						...(nextAvailabilityState === null
							? []
							: [
									`rowPaint:${fact.itemId}`,
									`availability:${fact.itemId}`,
									`contentMetadata:${fact.itemId}`,
								]),
						...(selectedDemandEnabled ? [`demand:${fact.itemId}`] : []),
					],
				};
			},
			applyViewportFact: (
				fact: ApplyBridgeCommWorkerViewportFactProps,
			): BridgeCommWorkerTouchedResult => {
				const previousState = store.getState();
				const visibleIds = [...fact.visibleItemIds];
				const visibleDeltaIds = findChangedIds(previousState.visibleIds, visibleIds);
				const unavailableVisibleIds = visibleIds.filter((itemId) => {
					const metadata = previousState.contentMetadataByItemId.get(itemId) ?? null;
					return (
						metadata !== null &&
						!isBridgeCommWorkerDemandEligibleContentMetadata(metadata) &&
						previousState.availabilityByItemId.get(itemId) !== 'unavailable'
					);
				});
				let nextAvailabilityByItemId = previousState.availabilityByItemId;
				if (unavailableVisibleIds.length > 0) {
					const unavailableAvailabilityByItemId = new Map(previousState.availabilityByItemId);
					for (const itemId of unavailableVisibleIds) {
						unavailableAvailabilityByItemId.set(itemId, 'unavailable');
					}
					nextAvailabilityByItemId = unavailableAvailabilityByItemId;
				}
				store.setState((state) => ({
					...state,
					viewportRange: {
						firstVisibleIndex: fact.firstVisibleIndex,
						lastVisibleIndex: fact.lastVisibleIndex,
					},
					visibleIds,
					availabilityByItemId: nextAvailabilityByItemId,
					demandByKey: buildDemandByKey({
						contentMetadataByItemId: state.contentMetadataByItemId,
						hoveredItemId: state.hoveredItemId,
						selectedId: state.selectedId,
						selectedDemandEpoch: readSelectedDemandEpoch(state),
						visibleIds,
					}),
				}));
				pendingSlicePatches.push({
					slice: 'viewport',
					operation: 'upsert',
					payload: {
						firstVisibleIndex: fact.firstVisibleIndex,
						lastVisibleIndex: fact.lastVisibleIndex,
						visibleItemIds: visibleIds,
					},
				});
				for (const itemId of unavailableVisibleIds) {
					pendingSlicePatches.push({
						slice: 'contentAvailability',
						operation: 'upsert',
						itemId,
						payload: { state: 'unavailable' },
					});
				}
				return {
					touchedKeys: [
						'viewportRange',
						...visibleDeltaIds.map((itemId) => `visibleIds:${itemId}`),
						...visibleDeltaIds.map((itemId) => `demand:${itemId}`),
						...unavailableVisibleIds.map((itemId) => `availability:${itemId}`),
					],
				};
			},
			applyContentReady: (
				fact: ApplyBridgeCommWorkerContentReadyProps,
			): BridgeCommWorkerTouchedResult => {
				store.setState((state) => ({
					...writeBridgeWorkerMap(
						writeBridgeWorkerMap(
							writeBridgeWorkerMap(state, 'byteCache', fact.contentCacheKey, fact.itemId),
							'paintReadyByItemId',
							fact.itemId,
							fact.contentCacheKey,
						),
						'availabilityByItemId',
						fact.itemId,
						'ready',
					),
				}));
				pendingSlicePatches.push(
					{
						slice: 'rowPaint',
						operation: 'upsert',
						itemId: fact.itemId,
						payload: { contentCacheKey: fact.contentCacheKey },
					},
					{
						slice: 'contentAvailability',
						operation: 'upsert',
						itemId: fact.itemId,
						payload: { state: 'ready' },
					},
				);
				return {
					touchedKeys: [
						`byteCache:${fact.contentCacheKey}`,
						`paintReady:${fact.itemId}`,
						`availability:${fact.itemId}`,
					],
				};
			},
			applyContentTerminalAvailability: (
				fact: ApplyBridgeCommWorkerContentTerminalAvailabilityProps,
			): BridgeCommWorkerTouchedResult => {
				const previousState = store.getState();
				const previousContentCacheKey = previousState.paintReadyByItemId.get(fact.itemId);
				const nextByteCache = new Map(previousState.byteCache);
				const nextPaintReadyByItemId = new Map(previousState.paintReadyByItemId);
				const touchedKeys: string[] = [];
				if (previousContentCacheKey !== undefined && props.surface !== 'file') {
					nextPaintReadyByItemId.delete(fact.itemId);
					nextByteCache.delete(previousContentCacheKey);
					touchedKeys.push(`paintReady:${fact.itemId}`, `byteCache:${previousContentCacheKey}`);
					pendingSlicePatches.push({
						slice: 'rowPaint',
						operation: 'delete',
						itemId: fact.itemId,
					});
				}
				const nextAvailabilityByItemId = new Map(previousState.availabilityByItemId);
				nextAvailabilityByItemId.set(fact.itemId, fact.state);
				store.setState({
					...previousState,
					byteCache: nextByteCache,
					paintReadyByItemId: nextPaintReadyByItemId,
					availabilityByItemId: nextAvailabilityByItemId,
				});
				pendingSlicePatches.push({
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: fact.itemId,
					payload: { reason: fact.reason, state: fact.state },
				});
				return {
					touchedKeys: [...touchedKeys, `availability:${fact.itemId}`],
				};
			},
			applyReviewInvalidationFact: (
				fact: ApplyBridgeCommWorkerReviewInvalidationFactProps,
			): BridgeCommWorkerTouchedResult => {
				const previousState = store.getState();
				const invalidatedItemIds = resolveReviewInvalidationItemIds({
					fact,
					state: previousState,
				});
				const invalidatedItemIdSet = new Set(invalidatedItemIds);
				const nextByteCache = new Map(previousState.byteCache);
				const nextPaintReadyByItemId = new Map(previousState.paintReadyByItemId);
				const nextAvailabilityByItemId = new Map(previousState.availabilityByItemId);
				const touchedKeys: string[] = [];
				const nextPatches: BridgeWorkerSlicePatch[] = [];

				for (const itemId of invalidatedItemIds) {
					const previousContentCacheKey = previousState.paintReadyByItemId.get(itemId);
					if (previousContentCacheKey !== undefined) {
						nextPaintReadyByItemId.delete(itemId);
						nextByteCache.delete(previousContentCacheKey);
						touchedKeys.push(`paintReady:${itemId}`, `byteCache:${previousContentCacheKey}`);
						nextPatches.push({
							slice: 'rowPaint',
							operation: 'delete',
							itemId,
						});
					}
					if (
						previousContentCacheKey !== undefined ||
						previousState.availabilityByItemId.has(itemId) ||
						previousState.selectedId === itemId ||
						previousState.visibleIds.includes(itemId)
					) {
						nextAvailabilityByItemId.set(itemId, 'stale');
						touchedKeys.push(`availability:${itemId}`);
						nextPatches.push({
							slice: 'contentAvailability',
							operation: 'upsert',
							itemId,
							payload: { state: 'stale' },
						});
					}
					if (previousState.selectedId === itemId || previousState.visibleIds.includes(itemId)) {
						touchedKeys.push(`demand:${itemId}`);
					}
				}

				const selectedDemandEpoch =
					previousState.selectedId !== null && invalidatedItemIdSet.has(previousState.selectedId)
						? fact.epoch
						: readSelectedDemandEpoch(previousState);
				store.setState({
					...previousState,
					byteCache: nextByteCache,
					paintReadyByItemId: nextPaintReadyByItemId,
					availabilityByItemId: nextAvailabilityByItemId,
					demandByKey: buildDemandByKey({
						contentMetadataByItemId: previousState.contentMetadataByItemId,
						hoveredItemId: previousState.hoveredItemId,
						selectedId: previousState.selectedId,
						selectedDemandEpoch,
						visibleIds: previousState.visibleIds,
					}),
				});
				pendingSlicePatches.push(...nextPatches);
				return { touchedKeys };
			},
			applySelectedSourceChurnFact: (
				fact: ApplyBridgeCommWorkerSelectedSourceChurnFactProps,
			): BridgeCommWorkerSelectedDemandResult => {
				const previousState = store.getState();
				const selectedMetadata = previousState.contentMetadataByItemId.get(fact.itemId) ?? null;
				if (
					previousState.selectedId !== fact.itemId ||
					!isBridgeCommWorkerDemandEligibleContentMetadata(selectedMetadata)
				) {
					return { selectedDemandEpoch: null, touchedKeys: [] };
				}
				const selectedDemandEpoch =
					readSelectedDemandEpoch(previousState) ?? previousState.selectedEpoch;
				store.setState({
					...previousState,
					availabilityByItemId: new Map(previousState.availabilityByItemId).set(
						fact.itemId,
						'loading',
					),
					demandByKey: buildDemandByKey({
						contentMetadataByItemId: previousState.contentMetadataByItemId,
						hoveredItemId: previousState.hoveredItemId,
						selectedDemandEpoch,
						selectedId: fact.itemId,
						visibleIds: previousState.visibleIds,
					}),
					selectedDemandEnabled: true,
				});
				pendingSlicePatches.push({
					slice: 'contentAvailability',
					operation: 'upsert',
					itemId: fact.itemId,
					payload: { state: 'loading' },
				});
				return {
					selectedDemandEpoch,
					touchedKeys: [`availability:${fact.itemId}`, `demand:${fact.itemId}`],
				};
			},
			applyReviewSourceUpdateFact: (
				fact: ApplyBridgeCommWorkerReviewSourceUpdateFactProps,
			): BridgeCommWorkerTouchedResult => {
				return applyBridgeCommWorkerSourceUpdateFact({
					...(fact.completeContentItemIds === undefined
						? {}
						: { completeContentItemIds: fact.completeContentItemIds }),
					...(fact.completeRowIds === undefined ? {} : { completeRowIds: fact.completeRowIds }),
					contentItems: fact.contentItems,
					epoch: fact.epoch,
					pendingSlicePatches,
					...(fact.removedContentItemIds === undefined
						? {}
						: { removedContentItemIds: fact.removedContentItemIds }),
					...(fact.resetComplete === undefined ? {} : { resetComplete: fact.resetComplete }),
					rows: fact.rows,
					store,
				});
			},
			applyReviewRowMutationFact: (
				fact: ApplyBridgeCommWorkerReviewRowMutationFactProps,
			): BridgeCommWorkerTouchedResult => {
				const previousState = store.getState();
				const nextRowById = new Map(previousState.rowById);
				for (const rowId of fact.mutation.removedRowIds) nextRowById.delete(rowId);
				for (const row of fact.mutation.rowUpserts) nextRowById.set(row.id, row);
				return commitBridgeCommWorkerReviewSourceUpdate({
					epoch: fact.epoch,
					pendingSlicePatches,
					previousState,
					sourceIndexes: buildBridgeCommWorkerSourceIndexesFromMaps({
						contentMetadataByItemId: previousState.contentMetadataByItemId,
						rowById: nextRowById,
					}),
					store,
				});
			},
			applyFileViewSourceUpdateFact: (
				fact: ApplyBridgeCommWorkerFileViewSourceUpdateFactProps,
			): BridgeCommWorkerTouchedResult => {
				return applyBridgeCommWorkerFileViewSourceUpdateFact({
					contentItems: fact.contentItems,
					epoch: fact.epoch,
					pendingSlicePatches,
					rows: fact.rows,
					selectedContentRequestChanged: fact.selectedContentRequestChanged,
					store,
				});
			},
			applyFileViewSourceMutationFact: (
				fact: ApplyBridgeCommWorkerFileViewSourceMutationFactProps,
			): BridgeCommWorkerTouchedResult => {
				return applyBridgeCommWorkerFileViewSourceMutationFact({
					epoch: fact.epoch,
					mutation: fact.mutation,
					pendingSlicePatches,
					selectedContentRequestChanged: fact.selectedContentRequestChanged,
					store,
				});
			},
			takePendingSlicePatchEvent: (
				eventProps: TakePendingBridgeCommWorkerSlicePatchEventProps,
			): BridgeWorkerSlicePatchEvent | null => {
				if (pendingSlicePatches.length === 0) {
					return null;
				}
				const patches = pendingSlicePatches.splice(0, pendingSlicePatches.length);
				return bridgeWorkerSlicePatchEventSchema.parse({
					wireVersion: BRIDGE_WORKER_WIRE_VERSION,
					direction: 'serverWorkerToMain',
					transferDescriptors: [],
					kind: 'slicePatch',
					epoch: eventProps.epoch,
					sequence: eventProps.sequence,
					patches,
				});
			},
		},
	};
	return {
		...workerStore,
		actions: instrumentBridgeCommWorkerStoreActions({
			actions: workerStore.actions,
			now,
			pendingSlicePatches,
			...(props.telemetryClient === undefined ? {} : { telemetryClient: props.telemetryClient }),
		}),
	};
}

function cloneBridgeCommWorkerStoreState(
	state: BridgeCommWorkerStoreState,
): BridgeCommWorkerStoreState {
	return {
		availabilityByItemId: new Map(state.availabilityByItemId),
		byteCache: new Map(state.byteCache),
		childrenByParentId: new Map(
			[...state.childrenByParentId].map(([parentId, childIds]) => [parentId, new Set(childIds)]),
		),
		contentMetadataByItemId: new Map(state.contentMetadataByItemId),
		demandByKey: new Map(state.demandByKey),
		hoveredItemId: state.hoveredItemId,
		indexById: new Map(state.indexById),
		orderedIds: [...state.orderedIds],
		paintReadyByItemId: new Map(state.paintReadyByItemId),
		rowById: new Map(state.rowById),
		selectedDemandEnabled: state.selectedDemandEnabled,
		selectedEpoch: state.selectedEpoch,
		selectedId: state.selectedId,
		viewportRange: state.viewportRange === null ? null : { ...state.viewportRange },
		visibleIds: [...state.visibleIds],
	};
}

function applyBridgeCommWorkerSourceUpdateFact(props: {
	readonly completeContentItemIds?: readonly string[];
	readonly completeRowIds?: readonly string[];
	readonly contentItems: readonly BridgeWorkerContentMetadata[];
	readonly epoch: number;
	readonly pendingSlicePatches: BridgeWorkerSlicePatch[];
	readonly removedContentItemIds?: readonly string[];
	readonly resetComplete?: boolean;
	readonly rows: readonly BridgeCommWorkerRow[];
	readonly store: StoreApi<BridgeCommWorkerStoreState>;
}): BridgeCommWorkerTouchedResult {
	const previousState = props.store.getState();
	const sourceIndexes = buildBridgeCommWorkerSourceIndexes(props);
	if (props.resetComplete === false) {
		const nextRowById = new Map(previousState.rowById);
		const nextContentMetadataByItemId = new Map(previousState.contentMetadataByItemId);
		for (const row of props.rows) {
			nextRowById.set(row.id, row);
		}
		for (const contentItem of props.contentItems) {
			nextContentMetadataByItemId.set(contentItem.itemId, contentItem);
		}
		for (const itemId of props.removedContentItemIds ?? []) {
			nextContentMetadataByItemId.delete(itemId);
		}
		if (props.completeRowIds !== undefined) {
			const completeRowIds = new Set(props.completeRowIds);
			for (const itemId of nextRowById.keys()) {
				if (!completeRowIds.has(itemId)) {
					nextRowById.delete(itemId);
				}
			}
		}
		if (props.completeContentItemIds !== undefined) {
			const completeContentItemIds = new Set(props.completeContentItemIds);
			for (const itemId of nextContentMetadataByItemId.keys()) {
				if (!completeContentItemIds.has(itemId)) {
					nextContentMetadataByItemId.delete(itemId);
				}
			}
		}
		const mergedSourceIndexes = buildBridgeCommWorkerSourceIndexesFromMaps({
			contentMetadataByItemId: nextContentMetadataByItemId,
			rowById: nextRowById,
		});
		return commitBridgeCommWorkerReviewSourceUpdate({
			epoch: props.epoch,
			pendingSlicePatches: props.pendingSlicePatches,
			previousState,
			sourceIndexes: mergedSourceIndexes,
			store: props.store,
		});
	}
	return commitBridgeCommWorkerReviewSourceUpdate({
		epoch: props.epoch,
		pendingSlicePatches: props.pendingSlicePatches,
		previousState,
		sourceIndexes,
		store: props.store,
	});
}

function commitBridgeCommWorkerReviewSourceUpdate(props: {
	readonly epoch: number;
	readonly pendingSlicePatches: BridgeWorkerSlicePatch[];
	readonly previousState: BridgeCommWorkerStoreState;
	readonly sourceIndexes: Pick<
		BridgeCommWorkerStoreState,
		'rowById' | 'orderedIds' | 'indexById' | 'childrenByParentId' | 'contentMetadataByItemId'
	>;
	readonly store: StoreApi<BridgeCommWorkerStoreState>;
}): BridgeCommWorkerTouchedResult {
	const selectedId = props.previousState.selectedId;
	const selectedDemandEpoch = readSelectedDemandEpoch(props.previousState);
	props.store.setState({
		...props.previousState,
		...props.sourceIndexes,
		demandByKey: buildDemandByKey({
			contentMetadataByItemId: props.sourceIndexes.contentMetadataByItemId,
			hoveredItemId: props.previousState.hoveredItemId,
			selectedId,
			selectedDemandEpoch,
			visibleIds: props.previousState.visibleIds,
		}),
	});
	return {
		sourceEpoch: props.epoch,
		touchedKeys: ['sourceRows', 'sourceContentMetadata'],
	};
}

function buildBridgeCommWorkerSourceIndexesFromMaps(props: {
	readonly contentMetadataByItemId: ReadonlyMap<string, BridgeWorkerContentMetadata>;
	readonly rowById: ReadonlyMap<string, BridgeCommWorkerRow>;
}): Pick<
	BridgeCommWorkerStoreState,
	'rowById' | 'orderedIds' | 'indexById' | 'childrenByParentId' | 'contentMetadataByItemId'
> {
	const rows = [...props.rowById.values()].toSorted((left, right) => left.index - right.index);
	return {
		...buildBridgeCommWorkerSourceIndexes({
			contentItems: [...props.contentMetadataByItemId.values()],
			rows,
		}),
		contentMetadataByItemId: new Map(props.contentMetadataByItemId),
	};
}

function buildInitialBridgeCommWorkerStoreState(
	props: CreateBridgeCommWorkerStoreProps,
): BridgeCommWorkerStoreState {
	const sourceIndexes = buildBridgeCommWorkerSourceIndexes(props);
	return {
		...sourceIndexes,
		selectedId: null,
		selectedEpoch: 0,
		selectedDemandEnabled: false,
		hoveredItemId: null,
		viewportRange: null,
		visibleIds: [],
		demandByKey: new Map<string, string>(),
		byteCache: new Map<string, string>(),
		paintReadyByItemId: new Map<string, string>(),
		availabilityByItemId: new Map<string, BridgeWorkerContentAvailabilityPatchPayload['state']>(),
	};
}

function buildBridgeCommWorkerSourceIndexes(props: {
	readonly contentItems: readonly BridgeWorkerContentMetadata[];
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

function resolveReviewInvalidationItemIds(props: {
	readonly fact: ApplyBridgeCommWorkerReviewInvalidationFactProps;
	readonly state: BridgeCommWorkerStoreState;
}): readonly string[] {
	const itemIds = new Set<string>();
	if (props.fact.scope === 'package' || props.fact.scope === 'treeWindow') {
		for (const itemId of props.state.paintReadyByItemId.keys()) {
			itemIds.add(itemId);
		}
		if (props.state.selectedId !== null) {
			itemIds.add(props.state.selectedId);
		}
		for (const itemId of props.state.visibleIds) {
			itemIds.add(itemId);
		}
	} else {
		for (const itemId of props.fact.itemIds) {
			itemIds.add(itemId);
		}
	}
	for (const pathHint of props.fact.pathHints) {
		for (const metadata of props.state.contentMetadataByItemId.values()) {
			if (metadata.path === pathHint) {
				itemIds.add(metadata.itemId);
			}
		}
	}
	return [...itemIds];
}

function buildDemandByKey(props: {
	readonly contentMetadataByItemId: ReadonlyMap<string, BridgeWorkerContentMetadata>;
	readonly hoveredItemId: string | null;
	readonly selectedId: string | null;
	readonly selectedDemandEpoch: number | null;
	readonly visibleIds: readonly string[];
}): Map<string, string> {
	return serializeBridgeCommWorkerDemandMembership(
		reconcileBridgeCommWorkerDemandMembership(props),
	);
}

function readSelectedDemandEpoch(state: BridgeCommWorkerStoreState): number | null {
	if (state.selectedId === null) {
		return null;
	}
	const existingValue = state.demandByKey.get(state.selectedId);
	const selectedEpochMatch = /^selected:(\d+)$/u.exec(existingValue ?? '');
	if (selectedEpochMatch !== null) {
		return Number(selectedEpochMatch[1]);
	}
	return null;
}

type BridgeCommWorkerStringMapKey =
	| 'demandByKey'
	| 'byteCache'
	| 'paintReadyByItemId'
	| 'availabilityByItemId';

function writeBridgeWorkerMap(
	state: BridgeCommWorkerStoreState,
	key: BridgeCommWorkerStringMapKey,
	entryKey: string,
	value: string,
): BridgeCommWorkerStoreState {
	if (key === 'availabilityByItemId') {
		if (!isBridgeWorkerContentAvailabilityState(value)) {
			throw new Error(`Bridge comm worker rejected availability state ${value}.`);
		}
		state.availabilityByItemId.set(entryKey, value);
		return state;
	}
	state[key].set(entryKey, value);
	return state;
}

function isBridgeWorkerContentAvailabilityState(
	value: string,
): value is BridgeWorkerContentAvailabilityPatchPayload['state'] {
	return (
		value === 'failed' ||
		value === 'loading' ||
		value === 'ready' ||
		value === 'stale' ||
		value === 'unavailable'
	);
}

function findChangedIds(
	previousIds: readonly string[],
	nextIds: readonly string[],
): readonly string[] {
	const previousIdSet = new Set(previousIds);
	const nextIdSet = new Set(nextIds);
	return [
		...previousIds.filter((itemId) => !nextIdSet.has(itemId)),
		...nextIds.filter((itemId) => !previousIdSet.has(itemId)),
	];
}
