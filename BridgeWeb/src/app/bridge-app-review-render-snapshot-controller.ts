import type { MutableRefObject } from 'react';
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';

import {
	encodeBridgeWorkerHoverCommand,
	encodeBridgeWorkerMarkFileViewedCommand,
	encodeBridgeWorkerReviewComparisonUpdateCommand,
	encodeBridgeWorkerReviewComparisonTargetsQueryCommand,
	encodeBridgeWorkerReviewComparisonTargetsQueryCancelCommand,
	encodeBridgeWorkerReviewIntakeReadyCommand,
	encodeBridgeWorkerViewRecoveryRetryCommand,
	encodeBridgeWorkerSelectCommand,
	encodeBridgeWorkerViewportCommand,
} from '../core/comm-worker/bridge-comm-worker-protocol.js';
import { prepareBridgeMainPierreItemForPresentation } from '../core/comm-worker/bridge-main-pierre-item-adapter.js';
import type { BridgeMainRenderFulfillmentCoordinator } from '../core/comm-worker/bridge-main-render-fulfillment-coordinator.js';
import {
	type BridgeMainCodeViewItem,
	type BridgeMainRenderSnapshotStore,
	type BridgeMainViewRecoveryStatus,
	type BridgeMainReviewCatalogSnapshot,
	type BridgeMainReviewRefreshPresentation,
	type BridgeMainReviewSourceDisplaySlice,
} from '../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeMainPanelChromeSlice } from '../core/comm-worker/bridge-main-review-comparison-presentation.js';
import {
	createBridgeMainReviewPublicationIntegration,
	type BridgeMainReviewPublicationIntegration,
} from '../core/comm-worker/bridge-main-review-publication-integration.js';
import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeProductReviewComparisonTargetCatalog } from '../core/comm-worker/bridge-product-review-comparison-contracts.js';
import type {
	BridgeWorkerContentAvailabilityPatchPayload,
	BridgeWorkerReviewComparisonUpdateCommand,
	BridgeWorkerReviewDisplayItem,
	BridgeWorkerReviewProjectionUpdateCommand,
	BridgeWorkerServerToMainMessage,
} from '../core/comm-worker/bridge-worker-contracts.js';
import {
	createBridgeWorkerPierreCourier,
	type BridgeWorkerPierreCourier,
} from '../core/comm-worker/bridge-worker-pierre-courier.js';
import type { BridgeWorkerPierreRenderJob } from '../core/comm-worker/bridge-worker-pierre-render-job.js';
import type { BridgeWorkerRpcLifecycleSnapshot } from '../core/comm-worker/bridge-worker-rpc-lifecycle-store.js';
import { recordBridgeSelectionLifecycleSnapshot } from '../foundation/diagnostics/bridge-review-selection-diagnostic.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';

const BRIDGE_REVIEW_INTAKE_READY_MAX_ATTEMPTS = 3;

type BridgeReviewIntakeReadyAttemptState = 'acked' | 'exhausted' | 'idle' | 'pending' | 'sending';

interface BridgeReviewIntakeReadyAttempt {
	attemptCount: number;
	readonly client: BridgePaneSurfaceClient;
	requestId: string | null;
	state: BridgeReviewIntakeReadyAttemptState;
}

export interface UseBridgeReviewRenderSnapshotControllerProps {
	readonly pierreCourier: BridgeWorkerPierreCourier;
	readonly prepareActiveEditorsForInstallation: () => Promise<boolean>;
	readonly reviewClient: BridgePaneSurfaceClient;
	readonly telemetryRecorderRef?: { readonly current: BridgeTelemetryRecorder };
}

export interface BridgeReviewDirectDisplayStore extends Pick<
	BridgeMainRenderSnapshotStore,
	| 'getReviewItemIdAtIndex'
	| 'getReviewCodeViewItemSnapshot'
	| 'getReviewItemSnapshot'
	| 'hasPendingReviewPaintRelease'
	| 'getReviewTreeRowAtIndex'
	| 'getReviewTreeRowSnapshot'
	| 'readReviewCatalogChangesAfter'
	| 'reviewCatalogContainsItem'
	| 'subscribeReviewItem'
	| 'subscribeReviewCodeViewItem'
	| 'subscribeReviewTreeRow'
> {}

export interface BridgeReviewRenderSnapshotController {
	readonly applyReviewRefreshNow: () => Promise<void>;
	readonly catalogSnapshot: BridgeMainReviewCatalogSnapshot;
	readonly comparisonTargetsQueryState: BridgeReviewComparisonTargetsQueryState;
	readonly clearSelectedReviewItemId: () => void;
	readonly commitSelectedReviewItemId: (itemId: string) => void;
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly emitHoveredReviewItemIntent: (itemId: string | null) => void;
	readonly emitSelectedReviewItemIntent: (
		itemId: string,
		selectedSource: 'keyboard' | 'programmatic' | 'user',
	) => void;
	readonly markFileViewed: (itemId: string, onDeliveryFailure?: () => void) => boolean;
	readonly panelChromeSlice: BridgeMainPanelChromeSlice;
	readonly reviewSourceSlice: BridgeMainReviewSourceDisplaySlice | null;
	readonly reviewRefreshPresentation: BridgeMainReviewRefreshPresentation;
	readonly viewRecoveryStatus: BridgeMainViewRecoveryStatus | null;
	readonly selectedCodeViewItem: BridgeMainCodeViewItem | null;
	readonly selectedContentAvailability: BridgeWorkerContentAvailabilityPatchPayload | null;
	readonly selectedItemId: string | null;
	readonly selectedReviewItem: BridgeWorkerReviewDisplayItem | null;
	readonly setReviewCodeViewVisibleItemIds: (itemIds: readonly string[]) => void;
	readonly setReviewRefreshSemanticAttention: (
		stableFileIdentities: readonly string[],
		activeEditorStableFileIdentities?: readonly string[],
	) => void;
	readonly setReviewTreeVisibleItemIds: (itemIds: readonly string[]) => void;
	readonly updateReviewDisplayProjection: (
		query: BridgeWorkerReviewProjectionUpdateCommand['query'],
	) => void;
	readonly updateReviewComparisonTarget: (
		target: BridgeWorkerReviewComparisonUpdateCommand['target'],
	) => void;
	readonly retryFailedMetadataView: (
		comparisonTarget: BridgeWorkerReviewComparisonUpdateCommand['target'] | null,
	) => void;
	readonly queryReviewComparisonTargets: () => void;
	readonly cancelReviewComparisonTargetsQuery: () => void;
	readonly visibleCodeViewItems: readonly BridgeMainCodeViewItem[];
}

export type BridgeReviewComparisonTargetsQueryState =
	| { readonly status: 'idle' | 'loading'; readonly catalog: null; readonly message: null }
	| {
			readonly status: 'ready';
			readonly catalog: BridgeProductReviewComparisonTargetCatalog;
			readonly message: null;
	  }
	| {
			readonly status: 'failed';
			readonly catalog: null;
			readonly message: string;
	  }
	| {
			readonly status: 'empty';
			readonly catalog: BridgeProductReviewComparisonTargetCatalog;
			readonly message: string;
	  };

export function useBridgeReviewRenderSnapshotController(
	props: UseBridgeReviewRenderSnapshotControllerProps,
): BridgeReviewRenderSnapshotController {
	if (props.reviewClient.surface !== 'review') {
		throw new Error('Bridge Review Viewer requires its pane-owned Review surface client.');
	}
	const displayStore = props.reviewClient.renderStore;
	const pierreCourier = props.pierreCourier;
	const reviewPublicationIntegrationRef = useRef<BridgeMainReviewPublicationIntegration | null>(
		null,
	);
	const catalogSnapshot = useSyncExternalStore(
		displayStore.subscribeReviewCatalog,
		displayStore.getReviewCatalogSnapshot,
		displayStore.getReviewCatalogSnapshot,
	);
	const reviewSourceSlice = useSyncExternalStore(
		displayStore.subscribeReviewSource,
		displayStore.getReviewSourceSnapshot,
		displayStore.getReviewSourceSnapshot,
	);
	const reviewRefreshPresentation = useSyncExternalStore(
		displayStore.subscribeReviewRefreshPresentation,
		displayStore.getReviewRefreshPresentation,
		displayStore.getReviewRefreshPresentation,
	);
	const viewRecoveryStatus = useSyncExternalStore(
		displayStore.subscribeViewRecoveryStatus,
		(): BridgeMainViewRecoveryStatus | null =>
			displayStore.getViewRecoveryStatus('review.metadata'),
		(): BridgeMainViewRecoveryStatus | null =>
			displayStore.getViewRecoveryStatus('review.metadata'),
	);
	const selectionSlice = useSyncExternalStore(
		displayStore.subscribeReviewSelection,
		displayStore.getReviewSelectionSnapshot,
		displayStore.getReviewSelectionSnapshot,
	);
	const getPanelChromeSnapshot = useCallback(
		(): BridgeMainPanelChromeSlice => displayStore.getSnapshot().panelChromeSlice,
		[displayStore],
	);
	const panelChromeSlice = useSyncExternalStore(
		displayStore.subscribe,
		getPanelChromeSnapshot,
		getPanelChromeSnapshot,
	);
	const selectedItemId = selectionSlice.selectedItemId;
	const selectedReviewItem = useSelectedReviewStoreValue({
		getSnapshot: displayStore.getReviewItemSnapshot,
		itemId: selectedItemId,
		subscribe: displayStore.subscribeReviewItem,
	});
	const selectedCodeViewItem = useSelectedReviewStoreValue({
		getSnapshot: displayStore.getReviewCodeViewItemSnapshot,
		itemId: selectedItemId,
		subscribe: displayStore.subscribeReviewCodeViewItem,
	});
	const rawSelectedContentAvailability = useSelectedReviewStoreValue({
		getSnapshot: displayStore.getReviewAvailabilitySnapshot,
		itemId: selectedItemId,
		subscribe: displayStore.subscribeReviewAvailability,
	});
	const selectedReadyCopyMissing =
		selectedItemId !== null &&
		rawSelectedContentAvailability?.state === 'ready' &&
		selectedCodeViewItem === null;
	const selectedPaintReleasePending =
		selectedItemId !== null &&
		selectedReadyCopyMissing &&
		displayStore.hasPendingReviewPaintRelease(selectedItemId);
	const reportedMissingReadyCopies = useRef<Set<string>>(new Set());
	useEffect((): void => {
		if (selectedItemId === null) return;
		if (!selectedReadyCopyMissing || selectedPaintReleasePending) {
			reportedMissingReadyCopies.current.delete(selectedItemId);
			return;
		}
		if (reportedMissingReadyCopies.current.has(selectedItemId)) return;
		reportedMissingReadyCopies.current.add(selectedItemId);
		console.error('Bridge Review render-copy invariant breach', {
			kind: 'review_selected_ready_without_render_copy',
			itemId: selectedItemId,
		});
	}, [selectedItemId, selectedPaintReleasePending, selectedReadyCopyMissing]);
	const selectedContentAvailability = resolveSelectedReviewContentAvailability({
		hasCodeViewItem: selectedCodeViewItem !== null,
		paintReleasePending: selectedPaintReleasePending,
		rawAvailability: rawSelectedContentAvailability ?? null,
	});
	const [codeViewRenderedItemIds, setCodeViewRenderedItemIds] = useState<readonly string[]>([]);
	const [comparisonTargetsQueryState, setComparisonTargetsQueryState] =
		useState<BridgeReviewComparisonTargetsQueryState>({
			catalog: null,
			message: null,
			status: 'idle',
		});
	const visibleCodeViewItems = useVisibleReviewCodeViewItems({
		displayStore,
		itemIds: codeViewRenderedItemIds,
	});
	const workerViewportItemIds = useMemo(
		(): readonly string[] => reviewCodeViewBodyDemandItemIds(codeViewRenderedItemIds),
		[codeViewRenderedItemIds],
	);
	const workerEpochRef = useRef(0);
	const hoveredReviewItemIdRef = useRef<string | null>(null);
	const reviewIntakeReadyAttemptRef = useRef<BridgeReviewIntakeReadyAttempt | null>(null);
	const latestReviewSelectRequestIdRef = useRef<string | null>(null);
	const latestComparisonTargetsQueryRequestIdRef = useRef<string | null>(null);
	const markFileViewedFailureCallbacksRef = useRef<Map<string, () => void>>(new Map());
	const settleWorkerRequests = useCallback((): void => {
		const lifecycleSnapshot = props.reviewClient.lifecycle.getSnapshot();
		recordBridgeSelectionLifecycleSnapshot({
			requestId: latestReviewSelectRequestIdRef.current,
			snapshot: lifecycleSnapshot,
			surface: 'review',
		});
		settleBridgeReviewWorkerLifecycleRequests({
			failureCallbacksByRequestId: markFileViewedFailureCallbacksRef.current,
			lifecycleSnapshot,
		});
		settleBridgeReviewIntakeReadyAttempt({
			attemptRef: reviewIntakeReadyAttemptRef,
			client: props.reviewClient,
			lifecycleSnapshot,
			workerEpochRef,
		});
	}, [props.reviewClient]);
	useEffect((): (() => void) => {
		const reviewPublicationIntegration = createBridgeMainReviewPublicationIntegration({
			client: props.reviewClient,
			nextCommandEpoch: (): number => nextBridgeReviewWorkerEpoch(workerEpochRef),
			onActiveRenderPatchesApplied: (message, patches): void => {
				for (const patch of patches) {
					if (patch.slice !== 'panelChrome') continue;
					recordAppliedReviewPanelChrome({
						message,
						patch,
						...(props.telemetryRecorderRef === undefined
							? {}
							: { telemetryRecorder: props.telemetryRecorderRef.current }),
					});
				}
			},
			pierreCourier,
			prepareActiveEditorsForInstallation: props.prepareActiveEditorsForInstallation,
			renderFulfillmentCoordinator: props.reviewClient.renderFulfillmentCoordinator,
			store: displayStore,
			telemetryRecorderRef: props.telemetryRecorderRef,
		});
		reviewPublicationIntegrationRef.current = reviewPublicationIntegration;
		reviewPublicationIntegration.start();
		const failureCallbacksByRequestId = markFileViewedFailureCallbacksRef.current;
		const unsubscribeMessages = props.reviewClient.subscribeMessages((message): void => {
			if (reviewPublicationIntegration.handleMessage(message)) return;
			if (
				message.kind === 'health' &&
				message.status === 'degraded' &&
				message.requestId === latestComparisonTargetsQueryRequestIdRef.current
			) {
				latestComparisonTargetsQueryRequestIdRef.current = null;
				setComparisonTargetsQueryState({
					catalog: null,
					message: 'Comparison targets are unavailable.',
					status: 'failed',
				});
				return;
			}
			if (message.kind === 'reviewComparisonTargetsQuery') {
				if (message.requestId !== latestComparisonTargetsQueryRequestIdRef.current) return;
				setComparisonTargetsQueryState(
					message.status === 'ready' && message.catalog !== null
						? { catalog: message.catalog, message: null, status: 'ready' }
						: message.status === 'empty' && message.catalog !== null
							? {
									catalog: message.catalog,
									message:
										message.message ?? 'No branch choices are available from the last 30 days.',
									status: 'empty',
								}
							: {
									catalog: null,
									message: message.message ?? 'Comparison targets are unavailable.',
									status: 'failed',
								},
				);
				return;
			}
			applyBridgeWorkerMessagesToMainRenderSnapshotStore({
				messages: [message],
				pierreCourier,
				renderFulfillmentCoordinator: props.reviewClient.renderFulfillmentCoordinator,
				renderSnapshotStore: displayStore,
				...(props.telemetryRecorderRef === undefined
					? {}
					: { telemetryRecorder: props.telemetryRecorderRef.current }),
			});
		});
		const unsubscribeLifecycle = props.reviewClient.lifecycle.subscribe(settleWorkerRequests);
		beginBridgeReviewIntakeReadyDelivery({
			attemptRef: reviewIntakeReadyAttemptRef,
			client: props.reviewClient,
			workerEpochRef,
		});
		return (): void => {
			if (reviewPublicationIntegrationRef.current === reviewPublicationIntegration) {
				reviewPublicationIntegrationRef.current = null;
			}
			reviewPublicationIntegration.dispose();
			unsubscribeMessages();
			unsubscribeLifecycle();
			failureCallbacksByRequestId.clear();
			latestComparisonTargetsQueryRequestIdRef.current = null;
		};
	}, [
		displayStore,
		pierreCourier,
		props.prepareActiveEditorsForInstallation,
		props.reviewClient,
		props.telemetryRecorderRef,
		settleWorkerRequests,
	]);
	useEffect((): void => {
		setComparisonTargetsQueryState({ catalog: null, message: null, status: 'idle' });
	}, [props.reviewClient]);
	const clearSelectedReviewItemId = useCallback((): void => {
		displayStore.applyWorkerPatch({ operation: 'delete', slice: 'selection' });
		latestReviewSelectRequestIdRef.current = props.reviewClient.send(
			encodeBridgeWorkerSelectCommand({
				epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
				requestId: 'review-client-owned',
				selectedItemId: null,
				selectedSource: null,
				surface: 'review',
			}),
		);
	}, [displayStore, props.reviewClient]);
	const commitSelectedReviewItemId = useCallback(
		(itemId: string): void => {
			displayStore.setLocalSelection({ selectedItemId: itemId, source: 'user' });
		},
		[displayStore],
	);
	const emitSelectedReviewItemIntent = useCallback(
		(itemId: string, selectedSource: 'keyboard' | 'programmatic' | 'user'): void => {
			latestReviewSelectRequestIdRef.current = props.reviewClient.send(
				encodeBridgeWorkerSelectCommand({
					epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
					requestId: 'review-client-owned',
					selectedItemId: itemId,
					selectedSource,
					surface: 'review',
				}),
			);
		},
		[props.reviewClient],
	);
	const emitHoveredReviewItemIntent = useCallback(
		(itemId: string | null): void => {
			if (hoveredReviewItemIdRef.current === itemId) return;
			props.reviewClient.send(
				encodeBridgeWorkerHoverCommand({
					epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
					hoveredItemId: itemId,
					requestId: 'review-client-owned',
					surface: 'review',
				}),
			);
			hoveredReviewItemIdRef.current = itemId;
		},
		[props.reviewClient],
	);
	const updateReviewDisplayProjection = useCallback(
		(query: BridgeWorkerReviewProjectionUpdateCommand['query']): void => {
			props.reviewClient.send({
				command: 'reviewProjectionUpdate',
				epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
				query,
			});
		},
		[props.reviewClient],
	);
	const updateReviewComparisonTarget = useCallback(
		(target: BridgeWorkerReviewComparisonUpdateCommand['target']): void => {
			props.reviewClient.send(
				encodeBridgeWorkerReviewComparisonUpdateCommand({
					epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
					requestId: 'review-client-owned',
					target,
				}),
			);
		},
		[props.reviewClient],
	);
	const retryFailedMetadataView = useCallback(
		(comparisonTarget: BridgeWorkerReviewComparisonUpdateCommand['target'] | null): void => {
			const installationFailed =
				displayStore.getReviewRefreshPresentation().failure?.kind === 'installation';
			if (
				viewRecoveryStatus === null ||
				(!installationFailed && viewRecoveryStatus.status !== 'failedRetryable')
			)
				return;
			props.reviewClient.send(
				encodeBridgeWorkerViewRecoveryRetryCommand({
					epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
					requestId: 'review-view-recovery-retry',
					view: viewRecoveryStatus.view,
				}),
			);
			if (!installationFailed && comparisonTarget !== null)
				updateReviewComparisonTarget(comparisonTarget);
		},
		[displayStore, props.reviewClient, updateReviewComparisonTarget, viewRecoveryStatus],
	);
	const queryReviewComparisonTargets = useCallback((): void => {
		setComparisonTargetsQueryState({ catalog: null, message: null, status: 'loading' });
		try {
			const requestId = props.reviewClient.send(
				encodeBridgeWorkerReviewComparisonTargetsQueryCommand({
					epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
					requestId: 'review-client-owned',
				}),
			);
			latestComparisonTargetsQueryRequestIdRef.current = requestId;
			if (props.reviewClient.lifecycle.getSnapshot().requestsById[requestId]?.state === 'failed') {
				latestComparisonTargetsQueryRequestIdRef.current = null;
				setComparisonTargetsQueryState({
					catalog: null,
					message: 'Comparison targets are unavailable.',
					status: 'failed',
				});
			}
		} catch {
			latestComparisonTargetsQueryRequestIdRef.current = null;
			setComparisonTargetsQueryState({
				catalog: null,
				message: 'Comparison targets are unavailable.',
				status: 'failed',
			});
		}
	}, [props.reviewClient]);
	const cancelReviewComparisonTargetsQuery = useCallback((): void => {
		const queryRequestId = latestComparisonTargetsQueryRequestIdRef.current;
		latestComparisonTargetsQueryRequestIdRef.current = null;
		setComparisonTargetsQueryState({ catalog: null, message: null, status: 'idle' });
		if (queryRequestId === null) return;
		try {
			props.reviewClient.send(
				encodeBridgeWorkerReviewComparisonTargetsQueryCancelCommand({
					epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
					queryRequestId,
					requestId: 'review-client-owned',
				}),
			);
		} catch {
			// The picker is already locally cancelled; worker delivery is best effort.
		}
	}, [props.reviewClient]);
	useEffect((): void => {
		const lastVisibleIndex = Math.max(0, workerViewportItemIds.length - 1);
		displayStore.setLocalViewport({
			firstVisibleIndex: 0,
			lastVisibleIndex,
			visibleItemIds: workerViewportItemIds,
		});
		props.reviewClient.send(
			encodeBridgeWorkerViewportCommand({
				epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
				firstVisibleIndex: 0,
				lastVisibleIndex,
				phase: 'settled',
				requestId: 'review-client-owned',
				surface: 'review',
				visibleItemIds: workerViewportItemIds,
			}),
		);
	}, [displayStore, props.reviewClient, workerViewportItemIds]);
	const setReviewCodeViewVisibleItemIds = useCallback((itemIds: readonly string[]): void => {
		const uniqueItemIds = reviewCodeViewBodyDemandItemIds(itemIds);
		setCodeViewRenderedItemIds((currentItemIds): readonly string[] =>
			stringArraysEqual(currentItemIds, uniqueItemIds) ? currentItemIds : uniqueItemIds,
		);
	}, []);
	const setReviewTreeVisibleItemIds = useCallback((_itemIds: readonly string[]): void => {
		// Review metadata already carries the complete tree manifest. Tree visibility is UI-local
		// and must not become CodeView body demand; body preparation follows CodeView visibility.
	}, []);
	const applyReviewRefreshNow = useCallback(
		(): Promise<void> => reviewPublicationIntegrationRef.current?.applyNow() ?? Promise.resolve(),
		[],
	);
	const setReviewRefreshSemanticAttention = useCallback(
		(
			stableFileIdentities: readonly string[],
			activeEditorStableFileIdentities: readonly string[] = [],
		): void => {
			reviewPublicationIntegrationRef.current?.setSemanticAttention({
				activeEditorStableFileIdentities,
				stableFileIdentities,
			});
		},
		[],
	);
	const markFileViewed = useCallback(
		(itemId: string, onDeliveryFailure?: () => void): boolean => {
			if (displayStore.getReviewItemSnapshot(itemId) === undefined) return false;
			let requestId: string;
			try {
				requestId = props.reviewClient.send(
					encodeBridgeWorkerMarkFileViewedCommand({
						epoch: nextBridgeReviewWorkerEpoch(workerEpochRef),
						fileId: itemId,
						requestId: 'review-client-owned',
					}),
				);
			} catch {
				onDeliveryFailure?.();
				return false;
			}
			if (onDeliveryFailure !== undefined) {
				markFileViewedFailureCallbacksRef.current.set(requestId, onDeliveryFailure);
				settleWorkerRequests();
			}
			return true;
		},
		[displayStore, props.reviewClient, settleWorkerRequests],
	);
	return {
		applyReviewRefreshNow,
		catalogSnapshot,
		comparisonTargetsQueryState,
		clearSelectedReviewItemId,
		commitSelectedReviewItemId,
		displayStore,
		emitHoveredReviewItemIntent,
		emitSelectedReviewItemIntent,
		markFileViewed,
		panelChromeSlice,
		reviewSourceSlice,
		reviewRefreshPresentation,
		viewRecoveryStatus,
		selectedCodeViewItem: selectedCodeViewItem ?? null,
		selectedContentAvailability,
		selectedItemId,
		selectedReviewItem: selectedReviewItem ?? null,
		queryReviewComparisonTargets,
		cancelReviewComparisonTargetsQuery,
		setReviewCodeViewVisibleItemIds,
		setReviewRefreshSemanticAttention,
		setReviewTreeVisibleItemIds,
		updateReviewComparisonTarget,
		retryFailedMetadataView,
		updateReviewDisplayProjection,
		visibleCodeViewItems,
	};
}

export function resolveSelectedReviewContentAvailability(props: {
	readonly hasCodeViewItem: boolean;
	readonly paintReleasePending: boolean;
	readonly rawAvailability: BridgeWorkerContentAvailabilityPatchPayload | null;
}): BridgeWorkerContentAvailabilityPatchPayload | null {
	if (props.rawAvailability?.state !== 'ready' || props.hasCodeViewItem) {
		return props.rawAvailability;
	}
	return { state: props.paintReleasePending ? 'loading' : 'failed' };
}

function useVisibleReviewCodeViewItems(props: {
	readonly displayStore: BridgeReviewDirectDisplayStore;
	readonly itemIds: readonly string[];
}): readonly BridgeMainCodeViewItem[] {
	const selector = useMemo(() => createVisibleReviewCodeViewItemsSelector(), []);
	const subscribe = useCallback(
		(listener: () => void): (() => void) => {
			const unsubscribers = props.itemIds.map((itemId) =>
				props.displayStore.subscribeReviewCodeViewItem(itemId, listener),
			);
			return (): void => {
				for (const unsubscribe of unsubscribers) unsubscribe();
			};
		},
		[props.displayStore, props.itemIds],
	);
	const getSnapshot = useCallback(
		(): readonly BridgeMainCodeViewItem[] =>
			selector({
				getItem: props.displayStore.getReviewCodeViewItemSnapshot,
				itemIds: props.itemIds,
			}),
		[props.displayStore, props.itemIds, selector],
	);
	return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

export function createVisibleReviewCodeViewItemsSelector(): (props: {
	readonly getItem: (itemId: string) => BridgeMainCodeViewItem | undefined;
	readonly itemIds: readonly string[];
}) => readonly BridgeMainCodeViewItem[] {
	let previousItems: readonly BridgeMainCodeViewItem[] = [];
	return (props): readonly BridgeMainCodeViewItem[] => {
		const nextItems = props.itemIds.flatMap((itemId): readonly BridgeMainCodeViewItem[] => {
			const item = props.getItem(itemId);
			return item === undefined || item.bridgeMetadata.itemId !== itemId ? [] : [item];
		});
		if (
			previousItems.length === nextItems.length &&
			previousItems.every((item, index): boolean => item === nextItems[index])
		) {
			return previousItems;
		}
		previousItems = nextItems;
		return nextItems;
	};
}

export function reviewCodeViewBodyDemandItemIds(
	codeViewVisibleItemIds: readonly string[],
): readonly string[] {
	return [...new Set(codeViewVisibleItemIds)];
}

function stringArraysEqual(first: readonly string[], second: readonly string[]): boolean {
	return (
		first.length === second.length &&
		first.every((itemId, itemIndex): boolean => itemId === second[itemIndex])
	);
}

function useSelectedReviewStoreValue<TValue>(props: {
	readonly getSnapshot: (itemId: string) => TValue | undefined;
	readonly itemId: string | null;
	readonly subscribe: (itemId: string, listener: () => void) => () => void;
}): TValue | undefined {
	const { getSnapshot: getItemSnapshot, itemId, subscribe: subscribeToItem } = props;
	const subscribe = useCallback(
		(listener: () => void): (() => void) =>
			itemId === null ? (): void => {} : subscribeToItem(itemId, listener),
		[itemId, subscribeToItem],
	);
	const getSnapshot = useCallback(
		(): TValue | undefined => (itemId === null ? undefined : getItemSnapshot(itemId)),
		[getItemSnapshot, itemId],
	);
	return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

export function applyBridgeWorkerMessagesToMainRenderSnapshotStore(props: {
	readonly messages: readonly BridgeWorkerServerToMainMessage[];
	readonly pierreCourier: BridgeWorkerPierreCourier;
	readonly renderFulfillmentCoordinator: Pick<
		BridgeMainRenderFulfillmentCoordinator,
		'acceptPublication' | 'bindPublicationItem' | 'markPublicationQueued' | 'rejectPublication'
	>;
	readonly renderSnapshotStore: BridgeMainRenderSnapshotStore;
	readonly telemetryRecorder?: BridgeTelemetryRecorder | undefined;
}): void {
	for (const message of props.messages) {
		switch (message.kind) {
			case 'fileDisplayPatch':
			case 'filePierreRenderJob':
			case 'fileRenderPatch':
				break;
			case 'reviewDisplayPatch':
				props.renderSnapshotStore.applyReviewDisplayPatchEvent(message);
				break;
			case 'reviewRenderPatch': {
				const publicationMatchesDisplay = bridgeReviewPublicationMatchesDisplayEpoch(
					props.renderSnapshotStore,
					message,
				);
				const currentMemberPatches = message.patches.filter(
					(patch): boolean =>
						patch.slice === 'panelChrome' ||
						(publicationMatchesDisplay &&
							(patch.operation === 'reset' ||
								props.renderSnapshotStore.reviewCatalogContainsItem(patch.itemId))),
				);
				if (currentMemberPatches.length > 0) {
					props.renderSnapshotStore.applySnapshotUpdate({ workerPatches: currentMemberPatches });
					for (const patch of currentMemberPatches) {
						if (patch.slice !== 'panelChrome') continue;
						recordAppliedReviewPanelChrome({
							message,
							patch,
							telemetryRecorder: props.telemetryRecorder,
						});
					}
				}
				break;
			}
			case 'slicePatch':
				break;
			case 'annotationCommandAccepted':
			case 'annotationCatalogStaging':
			case 'annotationOutputInspection':
			case 'annotationProjectionConvergence':
			case 'health':
			case 'viewRecoveryStatus':
			case 'nativeSurfaceSelectionRequest':
			case 'reviewCandidateReady':
			case 'reviewCandidateFailed':
			case 'reviewCandidateStarted':
			case 'subscription':
			case 'reviewComparisonTargetsQuery':
			case 'reviewPublicationInstallAdmission':
				break;
			case 'reviewPierreRenderJob':
				if (
					!bridgeReviewPublicationMatchesDisplayEpoch(props.renderSnapshotStore, message) ||
					!props.renderSnapshotStore.reviewCatalogContainsItem(message.job.itemId)
				) {
					props.renderFulfillmentCoordinator.rejectPublication(message, 'stale_submission');
					break;
				}
				if (props.renderFulfillmentCoordinator.acceptPublication(message) === 'duplicate') {
					break;
				}
				const publicationItem = message.job.payload.item;
				const currentItem = props.renderSnapshotStore.getReviewCodeViewItemSnapshot(
					message.job.itemId,
				);
				if (currentItem === undefined) {
					const preparedItem = prepareBridgeMainPierreItemForPresentation({
						currentItem,
						presentationItem: publicationItem,
					});
					props.renderFulfillmentCoordinator.bindPublicationItem({
						finalItem: preparedItem.item,
						publicationItem,
						residency: preparedItem.residency,
					});
					props.renderSnapshotStore.setWorkerCodeViewItem({
						item: preparedItem.item,
						itemId: message.job.itemId,
					});
					props.pierreCourier.submit(message.job);
					props.renderFulfillmentCoordinator.markPublicationQueued(message);
					break;
				}
				props.renderSnapshotStore.setWorkerCodeViewItem({
					item: publicationItem,
					itemId: message.job.itemId,
				});
				props.pierreCourier.submit(message.job);
				props.renderFulfillmentCoordinator.markPublicationQueued(message);
				break;
			default:
				assertNeverBridgeWorkerServerMessage(message);
		}
	}
}

function recordAppliedReviewPanelChrome(props: {
	readonly message: Extract<
		BridgeWorkerServerToMainMessage,
		{ readonly kind: 'reviewRenderPatch' }
	>;
	readonly patch: Extract<
		Extract<
			BridgeWorkerServerToMainMessage,
			{ readonly kind: 'reviewRenderPatch' }
		>['patches'][number],
		{ readonly slice: 'panelChrome' }
	>;
	readonly telemetryRecorder?: BridgeTelemetryRecorder | undefined;
}): void {
	const attempt =
		props.patch.operation === 'upsert' ? props.patch.payload.reviewComparison?.attempt : null;
	props.telemetryRecorder?.record({
		scope: 'web',
		name: 'performance.bridge.web.pane_presentation',
		durationMilliseconds: null,
		traceContext: null,
		stringAttributes: {
			'agentstudio.bridge.comparison.attempt.status':
				attempt === null || attempt === undefined
					? 'absent'
					: attempt.status === 'noSource'
						? 'no_source'
						: attempt.status === 'selectionRequired'
							? 'selection_required'
							: attempt.status,
			'agentstudio.bridge.panel.operation': props.patch.operation,
			'agentstudio.bridge.phase': 'panel_chrome_applied',
			'agentstudio.bridge.plane': 'control',
			'agentstudio.bridge.presentation.disposition': 'applied',
			'agentstudio.bridge.priority': 'hot',
			'agentstudio.bridge.result': 'success',
			'agentstudio.bridge.slice': 'review_metadata',
			'agentstudio.bridge.transport': 'local',
			'agentstudio.bridge.viewer': 'review',
		},
		numericAttributes: {
			'agentstudio.bridge.presentation.publication_sequence': props.message.publicationSequence,
			'agentstudio.bridge.worker.derivation_epoch': props.message.workerDerivationEpoch,
			...(attempt?.status === 'pending' || attempt?.status === 'settled'
				? { 'agentstudio.bridge.review.generation': attempt.reviewGeneration }
				: {}),
		},
		booleanAttributes: {},
	});
}

function bridgeReviewPublicationMatchesDisplayEpoch(
	store: BridgeMainRenderSnapshotStore,
	publication: Extract<
		BridgeWorkerServerToMainMessage,
		{ readonly kind: 'reviewPierreRenderJob' | 'reviewRenderPatch' }
	>,
): boolean {
	return store.getSnapshot().reviewDisplayFreshness?.epoch === publication.workerDerivationEpoch;
}

export function createBridgeReviewWorkerPierreCourier(): BridgeWorkerPierreCourier {
	return createBridgeWorkerPierreCourier({
		submitPierreRenderJob: (_job: BridgeWorkerPierreRenderJob): void => {},
	});
}

function settleBridgeReviewWorkerLifecycleRequests(props: {
	readonly failureCallbacksByRequestId: Map<string, () => void>;
	readonly lifecycleSnapshot: BridgeWorkerRpcLifecycleSnapshot;
}): void {
	for (const request of Object.values(props.lifecycleSnapshot.requestsById)) {
		if (request.state === 'pending') continue;
		const failureCallback = props.failureCallbacksByRequestId.get(request.requestId);
		if (failureCallback === undefined) continue;
		props.failureCallbacksByRequestId.delete(request.requestId);
		if (request.state !== 'acked') failureCallback();
	}
}

function beginBridgeReviewIntakeReadyDelivery(props: {
	readonly attemptRef: MutableRefObject<BridgeReviewIntakeReadyAttempt | null>;
	readonly client: BridgePaneSurfaceClient;
	readonly workerEpochRef: MutableRefObject<number>;
}): void {
	props.attemptRef.current = {
		attemptCount: 0,
		client: props.client,
		requestId: null,
		state: 'idle',
	};
	startBridgeReviewIntakeReadyAttempt(props);
}

function startBridgeReviewIntakeReadyAttempt(props: {
	readonly attemptRef: MutableRefObject<BridgeReviewIntakeReadyAttempt | null>;
	readonly client: BridgePaneSurfaceClient;
	readonly workerEpochRef: MutableRefObject<number>;
}): void {
	const attempt = props.attemptRef.current;
	if (attempt?.client !== props.client || attempt.state !== 'idle') return;
	if (attempt.attemptCount >= BRIDGE_REVIEW_INTAKE_READY_MAX_ATTEMPTS) {
		attempt.state = 'exhausted';
		return;
	}
	attempt.attemptCount += 1;
	attempt.requestId = null;
	attempt.state = 'sending';
	let requestId: string;
	try {
		requestId = props.client.send(
			encodeBridgeWorkerReviewIntakeReadyCommand({
				epoch: nextBridgeReviewWorkerEpoch(props.workerEpochRef),
				requestId: 'review-client-owned',
				streamId: null,
			}),
		);
	} catch (error: unknown) {
		if (props.attemptRef.current === attempt) attempt.state = 'exhausted';
		throw error;
	}
	if (props.attemptRef.current !== attempt) return;
	attempt.requestId = requestId;
	attempt.state = 'pending';
	settleBridgeReviewIntakeReadyAttempt({
		...props,
		lifecycleSnapshot: props.client.lifecycle.getSnapshot(),
	});
}

function settleBridgeReviewIntakeReadyAttempt(props: {
	readonly attemptRef: MutableRefObject<BridgeReviewIntakeReadyAttempt | null>;
	readonly client: BridgePaneSurfaceClient;
	readonly lifecycleSnapshot: BridgeWorkerRpcLifecycleSnapshot;
	readonly workerEpochRef: MutableRefObject<number>;
}): void {
	const attempt = props.attemptRef.current;
	if (
		attempt?.client !== props.client ||
		attempt.state !== 'pending' ||
		attempt.requestId === null
	) {
		return;
	}
	const request = props.lifecycleSnapshot.requestsById[attempt.requestId];
	if (request === undefined || request.state === 'pending') return;
	if (request.state === 'acked') {
		attempt.state = 'acked';
		return;
	}
	if (request.state !== 'failed' && request.state !== 'timed_out') return;
	attempt.requestId = null;
	attempt.state =
		attempt.attemptCount >= BRIDGE_REVIEW_INTAKE_READY_MAX_ATTEMPTS ? 'exhausted' : 'idle';
	if (attempt.state === 'idle') startBridgeReviewIntakeReadyAttempt(props);
}

function nextBridgeReviewWorkerEpoch(workerEpochRef: MutableRefObject<number>): number {
	workerEpochRef.current += 1;
	return workerEpochRef.current;
}

function assertNeverBridgeWorkerServerMessage(_message: never): never {
	throw new Error('Unhandled bridge worker server message.');
}
