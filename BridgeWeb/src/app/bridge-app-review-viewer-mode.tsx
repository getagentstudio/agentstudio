import { useCallback, useEffect, useId, useMemo, useRef, useState, type ReactElement } from 'react';

import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import type { BridgeActiveViewerSource } from '../core/comm-worker/bridge-product-control-contracts.js';
import type { BridgeProductNavigationCommand } from '../core/comm-worker/bridge-product-session-contracts.js';
import type { BridgePaneFailedStartFact } from '../core/models/bridge-pane-failed-start.js';
import { bridgeReviewRegionSurfaceStatus } from '../features/review/bridge-review-region-presentation.js';
import { startBridgeFrameJankProbe } from '../foundation/diagnostics/bridge-frame-jank-probe.js';
import { startBridgeFrameLivenessProbe } from '../foundation/diagnostics/bridge-frame-liveness-probe.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import {
	recordBridgeFrameJankTelemetrySample,
	recordBridgeReviewComparisonPaneTelemetrySample,
} from '../foundation/telemetry/bridge-viewer-telemetry-adapter.js';
import { BridgeReviewProjectionMenu } from '../review-viewer/chrome/bridge-review-projection-menu.js';
import {
	bridgeCodeViewOptions,
	createBridgeReviewViewSettingsDefaults,
	deriveBridgeReviewCodeViewOptions,
} from '../review-viewer/code-view/bridge-code-view-options.js';
import type { BridgeCodeViewAnnotationReveal } from '../review-viewer/code-view/bridge-code-view-panel-types.js';
import type { BridgeCodeViewControlHandle } from '../review-viewer/code-view/bridge-code-view-panel.js';
import { reviewItemIdForAnnotationThread } from '../review-viewer/code-view/use-bridge-code-view-worktree-annotations.js';
import { reviewPierreAnnotationsForItem } from '../review-viewer/code-view/worktree-annotation-pierre-adapter.js';
import type {
	BridgeReviewProjectionMode,
	BridgeReviewSearchMode,
} from '../review-viewer/models/review-projection-models.js';
import type { BridgeReviewTreeSelectionRevealRequest } from '../review-viewer/trees/bridge-trees-panel.js';
import { useWorktreeAnnotationNavigationTarget } from '../worktree-annotations/use-worktree-annotation-navigation-target.js';
import { useWorktreeAnnotationNavigation } from '../worktree-annotations/worktree-annotation-navigation.js';
import {
	WorktreeAnnotationSurfaceProvider,
	useWorktreeAnnotationPrepareActiveEditorsForInstallation,
} from '../worktree-annotations/worktree-annotation-surface-provider.js';
import type { BridgeFileTreeFilterCandidate } from './bridge-app-control.js';
import {
	bridgeAppReviewNavigationSourceForDisplaySlice,
	type BridgeAppNavigationSource,
} from './bridge-app-navigation-admission.js';
import { useBridgeReviewNavigationController } from './bridge-app-review-navigation-controller.js';
import { bridgeReviewPresentationSnapshotForDisplay } from './bridge-app-review-presentation-adapter.js';
import { bridgeReviewRegionShellPresentation } from './bridge-app-review-region-shell-presentation.js';
import {
	createBridgeReviewWorkerPierreCourier,
	type BridgeReviewRenderSnapshotController,
	useBridgeReviewRenderSnapshotController,
} from './bridge-app-review-render-snapshot-controller.js';
import { useBridgeReviewSelectionController } from './bridge-app-review-selection-controller.js';
import { BridgeReviewViewerShellBoundary } from './bridge-app-review-viewer-shell-boundary.js';
import { bridgePaneFailedStartSurfaceStatus } from './bridge-pane-failed-start-presentation.js';
import type { BridgePaneReloadPort } from './bridge-pane-reload-port.js';
import {
	bridgeReviewComparisonPackageMatch,
	bridgeReviewComparisonPaneIsLoading,
	bridgeReviewComparisonPaneState,
} from './bridge-review-comparison-pane-state.js';
import { BridgeReviewHeaderPanels } from './bridge-review-header-panels.js';
import {
	BridgeReviewRefreshHeaderGroup,
	bridgeReviewRegionRefreshHeaderPresentation,
} from './bridge-review-refresh-header-chrome.js';
import {
	createBridgeViewerSearchState,
	transitionBridgeViewerSearchState,
	type BridgeViewerSearchAction,
	type BridgeViewerSearchRejectionReason,
} from './bridge-viewer-search-state.js';
import { BridgeViewerViewSettingsMenu } from './bridge-viewer-view-settings-menu.js';
import type { BridgeReviewViewSettings } from './bridge-viewer-view-settings.js';
import type { BridgeMarkdownRenderWorkerClient } from './markdown/worker/bridge-markdown-render-worker-client.js';
import { useBridgeReviewControlEventListeners } from './use-bridge-review-control-event-listeners.js';
import { useBridgeViewerToolbarShortcuts } from './use-bridge-viewer-toolbar-shortcuts.js';

export interface BridgeReviewViewerModeProps {
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly railVisible?: boolean | undefined;
	readonly paneFailedStart?: BridgePaneFailedStartFact | null;
	readonly activationCause?: 'context_switcher' | 'native_request' | 'review_file_corner';
	readonly activationSequence?: number;
	readonly activationStartedAtPerfNow?: number;
	readonly codeViewWorkerFactory?: () => Worker;
	readonly codeViewWorkerPoolEnabled?: boolean;
	readonly isActive: boolean;
	readonly markdownWorkerClient?: BridgeMarkdownRenderWorkerClient | null;
	readonly isNavigationCommandStillEligible: (
		command: Extract<
			BridgeProductNavigationCommand,
			{ readonly commandKind: 'activateTarget'; readonly surface: 'review' }
		>,
	) => boolean;
	readonly navigationCommand?: Extract<
		BridgeProductNavigationCommand,
		{ readonly commandKind: 'activateTarget'; readonly surface: 'review' }
	>;
	readonly onActiveSourceChange: (activeSource: BridgeActiveViewerSource | null) => void;
	readonly onNavigationSourceChange: (
		source: Extract<BridgeAppNavigationSource, { readonly sourceKind: 'review' }> | null,
	) => void;
	readonly onOpenFile?: (path: string) => void;
	readonly reviewClient: BridgePaneSurfaceClient;
	readonly target?: EventTarget;
	readonly telemetryRecorderRef: { readonly current: BridgeTelemetryRecorder };
	readonly viewerContextSwitcher: ReactElement;
}

type BridgeReviewFilterCandidate = Extract<
	BridgeFileTreeFilterCandidate,
	{ readonly surface: 'review' }
>;

const bridgeReviewDefaultViewSettings =
	createBridgeReviewViewSettingsDefaults(bridgeCodeViewOptions);
export function BridgeReviewViewerMode(props: BridgeReviewViewerModeProps): ReactElement {
	return (
		<WorktreeAnnotationSurfaceProvider
			markdownWorkerClient={props.markdownWorkerClient}
			surfaceClient={props.reviewClient}
			telemetryRecorder={props.telemetryRecorderRef.current}
		>
			<BridgeReviewViewerModeContent {...props} />
		</WorktreeAnnotationSurfaceProvider>
	);
}

function BridgeReviewViewerModeContent(props: BridgeReviewViewerModeProps): ReactElement {
	const {
		activationCause,
		activationSequence,
		activationStartedAtPerfNow,
		codeViewWorkerFactory,
		codeViewWorkerPoolEnabled,
		isActive,
		isNavigationCommandStillEligible,
		navigationCommand,
		onActiveSourceChange,
		onNavigationSourceChange,
		onOpenFile,
		reviewClient,
		target = document,
		telemetryRecorderRef,
		viewerContextSwitcher,
	} = props;
	const pierreCourier = useMemo(() => createBridgeReviewWorkerPierreCourier(), []);
	const annotationNavigation = useWorktreeAnnotationNavigation();
	const annotationTarget = useWorktreeAnnotationNavigationTarget('review', isActive);
	const appliedAnnotationRequest = useRef<number | null>(null);
	const presentationPositionKey = useId();
	const prepareActiveEditorsForInstallation =
		useWorktreeAnnotationPrepareActiveEditorsForInstallation();
	const controller = useBridgeReviewRenderSnapshotController({
		pierreCourier,
		prepareActiveEditorsForInstallation,
		reviewClient,
		telemetryRecorderRef,
	});
	const catalogSnapshot = controller.catalogSnapshot;
	const comparisonTargetsQueryState = controller.comparisonTargetsQueryState;
	const clearSelectedReviewItemId = controller.clearSelectedReviewItemId;
	const commitSelectedReviewItemId = controller.commitSelectedReviewItemId;
	const displayStore = controller.displayStore;
	const emitHoveredReviewItemIntent = controller.emitHoveredReviewItemIntent;
	const emitSelectedReviewItemIntent = controller.emitSelectedReviewItemIntent;
	const markFileViewed = controller.markFileViewed;
	const panelChromeSlice = controller.panelChromeSlice;
	const reviewRefreshPresentation = controller.reviewRefreshPresentation;
	const reviewSourceSlice = controller.reviewSourceSlice;
	const selectedCodeViewItem = controller.selectedCodeViewItem;
	const selectedContentAvailability = controller.selectedContentAvailability;
	const selectedItemId = controller.selectedItemId;
	const selectedReviewItem = controller.selectedReviewItem;
	const setReviewCodeViewVisibleItemIds = controller.setReviewCodeViewVisibleItemIds;
	const setReviewRefreshSemanticAttention = controller.setReviewRefreshSemanticAttention;
	const setReviewTreeVisibleItemIds = controller.setReviewTreeVisibleItemIds;
	const updateReviewDisplayProjection = controller.updateReviewDisplayProjection;
	const queryReviewComparisonTargets = controller.queryReviewComparisonTargets;
	const cancelReviewComparisonTargetsQuery = controller.cancelReviewComparisonTargetsQuery;
	const visibleCodeViewItems = controller.visibleCodeViewItems;
	const [readingPositionItemId, setReadingPositionItemId] = useState<string | null>(null);
	const [annotationAttentionItemIds, setAnnotationAttentionItemIds] = useState<readonly string[]>(
		[],
	);
	const [annotationEditorAttentionItemIds, setAnnotationEditorAttentionItemIds] = useState<
		readonly string[]
	>([]);
	const semanticAttentionItemIds = useMemo((): readonly string[] => {
		if (!isActive) return [];
		const itemIds = new Set<string>();
		if (selectedItemId !== null) itemIds.add(selectedItemId);
		if (readingPositionItemId !== null) itemIds.add(readingPositionItemId);
		for (const itemId of annotationAttentionItemIds) itemIds.add(itemId);
		return [...itemIds].toSorted();
	}, [annotationAttentionItemIds, isActive, readingPositionItemId, selectedItemId]);
	useEffect((): void => {
		setReviewRefreshSemanticAttention(
			semanticAttentionItemIds,
			isActive ? annotationEditorAttentionItemIds : [],
		);
	}, [
		annotationEditorAttentionItemIds,
		isActive,
		semanticAttentionItemIds,
		setReviewRefreshSemanticAttention,
	]);
	const [treeSearchState, setTreeSearchState] = useState(createBridgeViewerSearchState);
	const [treeSearchRejectionMessage, setTreeSearchRejectionMessage] = useState<string | null>(null);
	const treeSearchStateRef = useRef(treeSearchState);
	treeSearchStateRef.current = treeSearchState;
	const [reviewFilter, setReviewFilter] = useState<BridgeReviewFilterCandidate>({
		categoryFilter: 'all',
		gitStatusFilter: 'all',
		showBinary: false,
		showLarge: false,
		surface: 'review',
	});
	const { categoryFilter, gitStatusFilter, showBinary, showLarge } = reviewFilter;
	const [facetMenuOpen, setFacetMenuOpen] = useState(false);
	const [viewSettings, setViewSettings] = useState<BridgeReviewViewSettings>(
		bridgeReviewDefaultViewSettings,
	);
	const [viewSettingsMenuOpen, setViewSettingsMenuOpen] = useState(false);
	const [projectionMode, setProjectionMode] = useState<BridgeReviewProjectionMode>({
		kind: 'normalReview',
	});
	useEffect((): void => {
		if (!isActive) {
			setFacetMenuOpen(false);
			setViewSettingsMenuOpen(false);
		}
	}, [isActive]);
	const codeViewOptions = useMemo(
		() =>
			deriveBridgeReviewCodeViewOptions({
				compatibilityOptions: bridgeCodeViewOptions,
				viewSettings,
			}),
		[viewSettings],
	);
	const [treeSelectionRevealRequest, setTreeSelectionRevealRequest] =
		useState<BridgeReviewTreeSelectionRevealRequest | null>(null);
	const treeSelectionRevealRevisionRef = useRef(0);
	const codeViewControlHandleRef = useRef<BridgeCodeViewControlHandle | null>(null);
	const controlProbeSequenceRef = useRef(0);
	const isActiveRef = useRef(isActive);
	const wasReviewViewportActiveRef = useRef(isActive);
	isActiveRef.current = isActive;
	useEffect((): void => {
		if (catalogSnapshot.epoch === null) return;
		updateReviewDisplayProjection({ categoryFilter, gitStatusFilter, showBinary, showLarge });
	}, [
		catalogSnapshot.epoch,
		categoryFilter,
		gitStatusFilter,
		showBinary,
		showLarge,
		updateReviewDisplayProjection,
	]);
	useEffect((): (() => void) => startBridgeFrameLivenessProbe(), []);
	useEffect(
		(): (() => void) =>
			startBridgeFrameJankProbe({
				onJankSample: (sample): void => {
					recordBridgeFrameJankTelemetrySample({
						...sample,
						telemetryRecorder: telemetryRecorderRef.current,
						traceContext: null,
						viewer: 'review',
						viewerIsActive: isActiveRef.current,
					});
				},
			}),
		[telemetryRecorderRef],
	);
	useEffect((): void => {
		// The bounded Review display contract intentionally carries no native stream identity.
		// Active-surface mode is still sent through the pane client; do not fabricate a stream id.
		onActiveSourceChange(null);
	}, [onActiveSourceChange]);
	useEffect((): void => {
		onNavigationSourceChange(bridgeAppReviewNavigationSourceForDisplaySlice(reviewSourceSlice));
	}, [onNavigationSourceChange, reviewSourceSlice]);
	useEffect((): void => {
		const wasActive = wasReviewViewportActiveRef.current;
		wasReviewViewportActiveRef.current = isActive;
		if (wasActive && !isActive) {
			emitHoveredReviewItemIntent(null);
			setReviewCodeViewVisibleItemIds([]);
			setReviewTreeVisibleItemIds([]);
		}
	}, [
		emitHoveredReviewItemIntent,
		isActive,
		setReviewCodeViewVisibleItemIds,
		setReviewTreeVisibleItemIds,
	]);
	const publishCodeViewVisibleItemIds = useCallback(
		(itemIds: readonly string[]): void => {
			if (isActive) setReviewCodeViewVisibleItemIds(itemIds);
		},
		[isActive, setReviewCodeViewVisibleItemIds],
	);
	const publishTreeVisibleItemIds = useCallback(
		(itemIds: readonly string[]): void => {
			if (isActive) setReviewTreeVisibleItemIds(itemIds);
		},
		[isActive, setReviewTreeVisibleItemIds],
	);
	const publishHoveredReviewItemId = useCallback(
		(itemId: string | null): void => {
			if (isActive) emitHoveredReviewItemIntent(itemId);
		},
		[emitHoveredReviewItemIntent, isActive],
	);
	const applyTreeSearchActions = useCallback(
		(actions: readonly BridgeViewerSearchAction[]): BridgeViewerSearchRejectionReason | null => {
			let nextState = treeSearchStateRef.current;
			for (const action of actions) {
				const transition = transitionBridgeViewerSearchState(nextState, action);
				if (transition.rejectionReason !== null) {
					setTreeSearchRejectionMessage('Search query is too long');
					return transition.rejectionReason;
				}
				nextState = transition.state;
			}
			setTreeSearchRejectionMessage(null);
			treeSearchStateRef.current = nextState;
			setTreeSearchState(nextState);
			return null;
		},
		[],
	);
	const toggleTreeSearch = useCallback((): void => {
		applyTreeSearchActions([{ type: treeSearchStateRef.current.isOpen ? 'close' : 'open' }]);
	}, [applyTreeSearchActions]);
	const toggleFacetMenu = useCallback(
		(): void => setFacetMenuOpen((isOpen): boolean => !isOpen),
		[],
	);
	useBridgeViewerToolbarShortcuts({
		isActive,
		onToggleFilters: toggleFacetMenu,
		onToggleSearch: toggleTreeSearch,
		target,
	});
	const updateTreeSearchTextFromActiveTree = useCallback(
		(searchText: string): void => {
			if (!isActiveRef.current) {
				return;
			}
			applyTreeSearchActions([{ type: 'change_query', query: searchText }]);
		},
		[applyTreeSearchActions],
	);
	const updateTreeSearchMode = useCallback(
		(mode: BridgeReviewSearchMode): void => {
			applyTreeSearchActions([{ type: 'change_mode', mode: mode.kind }]);
		},
		[applyTreeSearchActions],
	);
	const clearOrCloseTreeSearch = useCallback((): void => {
		applyTreeSearchActions([{ type: 'clear_or_close' }]);
	}, [applyTreeSearchActions]);
	const closeTreeSearch = useCallback((): void => {
		applyTreeSearchActions([{ type: 'close' }]);
	}, [applyTreeSearchActions]);
	const presentationSnapshot = useMemo(
		() =>
			bridgeReviewPresentationSnapshotForDisplay({
				catalogSnapshot,
				displayStore,
				reviewSourceSlice,
			}),
		[catalogSnapshot, displayStore, reviewSourceSlice],
	);
	const displayedReviewPackage = presentationSnapshot?.reviewPackage ?? null;
	const comparisonPresentation = panelChromeSlice.reviewComparison;
	const rawComparisonPaneState = bridgeReviewComparisonPaneState({
		comparisonPresentation,
		displayedReviewPackage,
	});
	const comparisonPaneState = reviewComparisonPaneStateForRefreshPresentation({
		rawComparisonPaneState,
		reviewRefreshPresentation,
	});
	const comparisonPackageMatch =
		comparisonPresentation === null || comparisonPresentation === undefined
			? 'snapshot_not_current'
			: bridgeReviewComparisonPackageMatch({
					displayedReviewPackage,
					displayedSnapshot: comparisonPresentation.displayedSnapshot,
				});
	const comparisonAttemptTelemetryStatus =
		bridgeReviewComparisonAttemptTelemetryStatus(comparisonPresentation);
	const comparisonPaneTelemetryState =
		bridgeReviewComparisonPaneTelemetryState(rawComparisonPaneState);
	useEffect((): void => {
		recordBridgeReviewComparisonPaneTelemetrySample({
			attemptStatus: comparisonAttemptTelemetryStatus,
			packageMatch: comparisonPackageMatch,
			paneState: comparisonPaneTelemetryState,
			telemetryRecorder: telemetryRecorderRef.current,
		});
	}, [
		comparisonAttemptTelemetryStatus,
		comparisonPackageMatch,
		comparisonPaneTelemetryState,
		telemetryRecorderRef,
	]);
	const comparisonIsLoading = bridgeReviewComparisonPaneIsLoading(comparisonPaneState);
	const refreshRetryTarget = panelChromeSlice.reviewComparison?.activeTarget ?? null;
	const installationRetry = reviewRefreshPresentation.failure?.kind === 'installation';
	const regionSurfaceStatus =
		bridgePaneFailedStartSurfaceStatus(props.paneFailedStart) ??
		bridgeReviewRegionSurfaceStatus({
			comparisonPaneState: rawComparisonPaneState,
			recoveryStatus: controller.viewRecoveryStatus,
			refreshPresentation: reviewRefreshPresentation,
			isActive,
		});
	const refreshHeaderPresentation = bridgeReviewRegionRefreshHeaderPresentation({
		surface: regionSurfaceStatus,
		isActive,
	});
	const onRetryRegion = (): void => {
		if (installationRetry || controller.viewRecoveryStatus !== null || refreshRetryTarget === null)
			controller.retryFailedMetadataView(refreshRetryTarget);
		else controller.updateReviewComparisonTarget(refreshRetryTarget);
	};
	const contentHeaderControls = (
		<>
			<BridgeReviewRefreshHeaderGroup
				onApplyNow={(): void => void controller.applyReviewRefreshNow()}
				onRetry={(): void => {
					if (installationRetry) controller.retryFailedMetadataView(refreshRetryTarget);
					else if (refreshRetryTarget !== null)
						controller.updateReviewComparisonTarget(refreshRetryTarget);
				}}
				presentation={refreshHeaderPresentation}
			/>
			<BridgeReviewHeaderPanels
				regionSurfaceStatus={regionSurfaceStatus}
				comparisonPresentation={panelChromeSlice.reviewComparison}
				displayedReviewPackage={presentationSnapshot?.reviewPackage ?? null}
				disabled={comparisonIsLoading}
				isActive={isActive}
				onApplyTarget={controller.updateReviewComparisonTarget}
				onCancelTargetQuery={cancelReviewComparisonTargetsQuery}
				onQueryTargets={queryReviewComparisonTargets}
				targetQueryState={comparisonTargetsQueryState}
			>
				<BridgeReviewProjectionMenu
					disabled={comparisonIsLoading}
					onProjectionModeChange={setProjectionMode}
					projectionMode={projectionMode}
				/>
			</BridgeReviewHeaderPanels>
			{isActive ? (
				<BridgeViewerViewSettingsMenu
					defaultSettings={bridgeReviewDefaultViewSettings}
					disabled={comparisonIsLoading}
					onChange={setViewSettings}
					onOpenChange={setViewSettingsMenuOpen}
					open={viewSettingsMenuOpen}
					settings={viewSettings}
					surface="review"
				/>
			) : null}
		</>
	);
	const reviewGeneration = presentationSnapshot?.reviewPackage.reviewGeneration ?? null;
	const reviewPackageId = presentationSnapshot?.reviewPackage.packageId ?? null;
	const orderedItemIds = presentationSnapshot?.reviewPackage.orderedItemIds ?? [];
	const selectionController = useBridgeReviewSelectionController({
		commitLocalSelection: commitSelectedReviewItemId,
		emitSelectIntent: emitSelectedReviewItemIntent,
		hasReviewItem: (itemId): boolean => displayStore.getReviewItemSnapshot(itemId) !== undefined,
		isActive,
		markFileViewed,
		selectedItemId,
		telemetryRecorderRef,
	});
	const commitReviewSelection = selectionController.selectReviewItem;
	const selectReviewItem = useCallback(
		(
			itemId: string,
			selectedSource: Parameters<typeof selectionController.selectReviewItem>[1] = 'user',
			annotationRequestId?: number,
		): boolean => {
			if (
				annotationNavigation?.request != null &&
				annotationNavigation.request.requestId !== annotationRequestId
			)
				annotationNavigation.finish(annotationNavigation.request.requestId);
			return commitReviewSelection(itemId, selectedSource);
		},
		[annotationNavigation, commitReviewSelection],
	);
	const clearReviewSelection = useCallback((): void => {
		clearSelectedReviewItemId();
		const treeFallback = document.querySelector('[data-testid="bridge-review-trees-panel"]');
		if (treeFallback instanceof HTMLElement) treeFallback.focus({ preventScroll: true });
	}, [clearSelectedReviewItemId]);
	const selectReviewItemAndRevealTree = useCallback(
		(
			itemId: string,
			selectedSource: Parameters<typeof selectReviewItem>[1] = 'user',
			annotationRequestId?: number,
		): boolean => {
			if (!selectReviewItem(itemId, selectedSource, annotationRequestId)) {
				return false;
			}
			if (reviewGeneration === null || reviewPackageId === null) {
				return true;
			}
			treeSelectionRevealRevisionRef.current += 1;
			setTreeSelectionRevealRequest({
				itemId,
				packageId: reviewPackageId,
				reviewGeneration,
				revision: treeSelectionRevealRevisionRef.current,
			});
			return true;
		},
		[reviewGeneration, reviewPackageId, selectReviewItem],
	);
	const onTargetOutsideAcceptedProjection = useCallback((): void => {}, []);
	useEffect((): void => {
		if (
			annotationTarget === null ||
			presentationSnapshot === null ||
			appliedAnnotationRequest.current === annotationTarget.request.requestId
		)
			return;
		if (
			categoryFilter !== 'all' ||
			gitStatusFilter !== 'all' ||
			treeSearchState.enteredCriteria.query !== ''
		) {
			setReviewFilter((current) => ({ ...current, categoryFilter: 'all', gitStatusFilter: 'all' }));
			applyTreeSearchActions([{ type: 'reset' }]);
			return;
		}
		const itemId = reviewItemIdForAnnotationThread({
			context: annotationTarget.thread.context,
			reviewPackage: presentationSnapshot.reviewPackage,
		});
		if (itemId === null) {
			annotationNavigation?.finish(
				annotationTarget.request.requestId,
				'This comment is not in the current Review.',
			);
			return;
		}
		if (selectReviewItemAndRevealTree(itemId, 'programmatic', annotationTarget.request.requestId))
			appliedAnnotationRequest.current = annotationTarget.request.requestId;
	}, [
		annotationNavigation,
		annotationTarget,
		applyTreeSearchActions,
		categoryFilter,
		gitStatusFilter,
		presentationSnapshot,
		selectReviewItemAndRevealTree,
		treeSearchState.enteredCriteria.query,
	]);
	const annotationReveal = useMemo((): BridgeCodeViewAnnotationReveal | null => {
		if (
			annotationTarget === null ||
			presentationSnapshot === null ||
			selectedCodeViewItem === null ||
			selectedItemId === null
		)
			return null;
		const itemId = reviewItemIdForAnnotationThread({
			context: annotationTarget.thread.context,
			reviewPackage: presentationSnapshot.reviewPackage,
		});
		const item = itemId === null ? undefined : presentationSnapshot.reviewPackage.itemsById[itemId];
		if (item === undefined || itemId !== selectedItemId) return null;
		const annotations =
			selectedCodeViewItem.type === 'diff'
				? reviewPierreAnnotationsForItem({
						item,
						itemType: 'diff',
						threads: [annotationTarget.thread],
					})
				: reviewPierreAnnotationsForItem({
						item,
						itemType: 'file',
						threads: [annotationTarget.thread],
					});
		const metadata = annotations[0]?.metadata;
		return metadata?.kind === 'thread'
			? {
					itemId: selectedItemId,
					threadId: annotationTarget.request.threadId,
					requestId: annotationTarget.request.requestId,
					range: metadata.range,
				}
			: null;
	}, [annotationTarget, presentationSnapshot, selectedCodeViewItem, selectedItemId]);
	useBridgeReviewControlEventListeners({
		codeViewControlHandleRef,
		controlProbeSequenceRef,
		categoryFilter,
		gitStatusFilter,
		isActive,
		onSearchRejected: (): void => setTreeSearchRejectionMessage('Search query is too long'),
		projection: presentationSnapshot?.projection ?? null,
		reviewPackage: presentationSnapshot?.reviewPackage ?? null,
		selectedItemId,
		selectReviewItem: selectReviewItemAndRevealTree,
		applyTreeSearchActions,
		setReviewFilter,
		target,
		treeSearchStateRef,
		treeSearchState,
		showBinary,
		showLarge,
	});
	useBridgeReviewNavigationController({
		catalogRevision: catalogSnapshot.revision,
		clearReviewSelection,
		getReviewItem: displayStore.getReviewItemSnapshot,
		isActive,
		isNavigationCommandStillEligible,
		navigationCommand,
		onTargetOutsideAcceptedProjection,
		orderedItemIds,
		selectedItemId,
		selectInitialReviewItem: (itemId, selectedSource): boolean =>
			annotationNavigation?.request != null ? false : selectReviewItem(itemId, selectedSource),
		selectReviewItem: selectReviewItemAndRevealTree,
	});
	const presentationState = bridgeReviewRegionShellPresentation({
		paneReloadPort: props.paneReloadPort,
		railVisible: props.railVisible,
		onRetryRead: (): void => {
			if (selectedItemId !== null) controller.emitSelectedReviewItemIntent(selectedItemId, 'user');
		},
		regionSurfaceStatus,
		onRetryRegion,
		annotationReveal,
		onAnnotationRevealComplete: annotationNavigation?.finish,
		activationCause,
		activationSequence,
		activationStartedAtPerfNow,
		codeViewOptions,
		codeViewWorkerFactory,
		codeViewWorkerPoolEnabled,
		panelChromeSlice,
		comparisonPaneState,
		onRetryComparison: controller.updateReviewComparisonTarget,
		onAnnotationAttentionItemIdsChange: setAnnotationAttentionItemIds,
		onAnnotationEditorAttentionItemIdsChange: setAnnotationEditorAttentionItemIds,
		onReadingPositionItemIdChange: setReadingPositionItemId,
		projectionMode,
		codeViewControlHandleRef,
		facetMenuOpen,
		categoryFilter,
		gitStatusFilter,
		showBinary,
		showLarge,
		presentationPositionKey,
		presentationSnapshot,
		renderFulfillmentCoordinator: reviewClient.renderFulfillmentCoordinator,
		reviewSourceSlice,
		selectedCodeViewItem,
		selectedContentAvailability,
		selectedItemId,
		selectedReviewItem,
		selectReviewItem: selectReviewItemAndRevealTree,
		setReviewCodeViewVisibleItemIds: publishCodeViewVisibleItemIds,
		setReviewViewportItemIds: publishTreeVisibleItemIds,
		telemetryRecorder: telemetryRecorderRef.current,
		treeAcceptedSearchMode: { kind: treeSearchState.acceptedCriteria.mode },
		treeAcceptedSearchText: treeSearchState.acceptedCriteria.query,
		treeSearchError: treeSearchState.error,
		treeSearchMode: { kind: treeSearchState.enteredCriteria.mode },
		treeSearchOpen: treeSearchState.isOpen,
		treeSearchText: treeSearchState.enteredCriteria.query,
		treeSearchStatusMessage: treeSearchRejectionMessage,
		treeSelectionRevealRequest,
		visibleCodeViewItems,
		onTreeSearchClear: clearOrCloseTreeSearch,
		onTreeSearchClose: closeTreeSearch,
		onTreeSearchModeChange: updateTreeSearchMode,
		onTreeSearchToggle: toggleTreeSearch,
		onTreeSearchTextChange: updateTreeSearchTextFromActiveTree,
		onFacetMenuOpenChange: setFacetMenuOpen,
		onFilterChange: setReviewFilter,
		onHoveredItemIdChange: publishHoveredReviewItemId,
		...(onOpenFile === undefined ? {} : { onOpenFile }),
	});
	return (
		<BridgeReviewViewerShellBoundary
			paneReloadPort={props.paneReloadPort}
			railVisible={props.railVisible}
			regionSurfaceStatus={regionSurfaceStatus}
			recoveryStatus={controller.viewRecoveryStatus}
			onRetryMetadata={onRetryRegion}
			comparisonPaneState={comparisonPaneState}
			isActive={isActive}
			onRetryComparison={controller.updateReviewComparisonTarget}
			presentationState={presentationState}
			viewerContextSwitcher={viewerContextSwitcher}
			viewerHeaderControls={contentHeaderControls}
		/>
	);
}

function bridgeReviewComparisonAttemptTelemetryStatus(
	presentation: BridgeReviewRenderSnapshotController['panelChromeSlice']['reviewComparison'],
): 'absent' | 'pending' | 'selection_required' | 'settled' | 'unavailable' {
	const status = presentation?.attempt.status;
	if (status === undefined) return 'absent';
	return status === 'selectionRequired' ? 'selection_required' : status;
}

function bridgeReviewComparisonPaneTelemetryState(
	state: ReturnType<typeof bridgeReviewComparisonPaneState>,
): 'failed_initial' | 'failed_previous' | 'loading_initial' | 'loading_previous' | 'settled' {
	switch (state.kind) {
		case 'failedInitial':
			return 'failed_initial';
		case 'failedPrevious':
			return 'failed_previous';
		case 'loadingInitial':
			return 'loading_initial';
		case 'loadingPrevious':
			return 'loading_previous';
		case 'settled':
			return 'settled';
		default:
			return assertNeverBridgeReviewComparisonPaneTelemetryState(state);
	}
}

function assertNeverBridgeReviewComparisonPaneTelemetryState(state: never): never {
	throw new Error(`Unexpected Review comparison pane telemetry state: ${JSON.stringify(state)}`);
}

export function reviewComparisonPaneStateForRefreshPresentation(props: {
	readonly rawComparisonPaneState: ReturnType<typeof bridgeReviewComparisonPaneState>;
	readonly reviewRefreshPresentation: BridgeReviewRenderSnapshotController['reviewRefreshPresentation'];
}): ReturnType<typeof bridgeReviewComparisonPaneState> {
	const sameSourceCandidate =
		props.reviewRefreshPresentation.candidate?.startDisposition.kind === 'sameSource';
	const sameSourceFailure = props.reviewRefreshPresentation.failure !== null;
	return sameSourceCandidate || sameSourceFailure
		? { kind: 'settled' }
		: props.rawComparisonPaneState;
}
