import { useEffect, useRef, type ReactElement, type ReactNode, type RefObject } from 'react';

import type { BridgeFileTreeFilterCandidate } from '../../app/bridge-app-control.js';
import { BridgePaneFailureSummarySlot } from '../../app/bridge-pane-failure-summary-slot.js';
import type { BridgePaneReloadPort } from '../../app/bridge-pane-reload-port.js';
import type {
	BridgeRegionSurfaceStatus,
	BridgeRegionFailure,
} from '../../app/bridge-region-presentation-state.js';
import { BridgeRegionPresentation } from '../../app/bridge-region-presentation.js';
import {
	bridgeReviewComparisonPaneIsLoading,
	type BridgeReviewComparisonPaneState,
} from '../../app/bridge-review-comparison-pane-state.js';
import type { BridgeReviewComparisonTarget } from '../../app/bridge-review-comparison-target.js';
import { bridgeReviewRegionDisplaySpec } from '../../app/bridge-review-region-display-spec.js';
import { BridgeViewerContentHeader } from '../../app/bridge-viewer-content-header.js';
import {
	BridgeViewerContextPanelProvider,
	BridgeViewerContextPanelViewport,
} from '../../app/bridge-viewer-context-panel-host.js';
import type { BridgeViewerFileCategory } from '../../app/bridge-viewer-file-class-options.js';
import type { BridgeViewerFacetMenuOption } from '../../app/bridge-viewer-filter-menu.js';
import { BridgeViewerRailToolbar } from '../../app/bridge-viewer-rail-toolbar.js';
import { BridgeViewerResizableRailLayout } from '../../app/bridge-viewer-resizable-rail-layout.js';
import { BridgeViewerRightRailShell } from '../../app/bridge-viewer-right-rail-shell.js';
import { BridgeViewerSearchControl } from '../../app/bridge-viewer-search-control.js';
import {
	BridgeViewerSearchField,
	BridgeViewerSearchStatus,
} from '../../app/bridge-viewer-search-field.js';
import type { BridgeViewerSearchError } from '../../app/bridge-viewer-search-state.js';
import { cn } from '../../app/class-name.js';
import { useBridgeViewerSearchFocusRestoration } from '../../app/use-bridge-viewer-search-focus-restoration.js';
import type { BridgeMainCodeViewItem } from '../../core/comm-worker/bridge-main-render-snapshot-store.js';
import type { BridgeMainPanelChromeSlice } from '../../core/comm-worker/bridge-main-review-comparison-presentation.js';
import { compileBridgeFileTreeSearchPattern } from '../../core/models/bridge-file-tree-search.js';
import {
	bridgeReviewReadyRegionPresentation,
	bridgeReviewRegionSurfaceStatus,
	bridgeReviewSelectedContentReadFailure,
} from '../../features/review/bridge-review-region-presentation.js';
import type { ReviewTreeRowMetadata } from '../../features/review/models/review-protocol-models.js';
import {
	type BridgeReviewItemRegistry,
	reviewItemPathLabel,
} from '../../foundation/review-package/bridge-review-item-registry.js';
import type {
	BridgeFileChangeKind,
	BridgeReviewPackage,
} from '../../foundation/review-package/bridge-review-package.js';
import type { BridgeTelemetryRecorder } from '../../foundation/telemetry/bridge-telemetry-recorder.js';
import type { BridgeTraceContext } from '../../foundation/telemetry/bridge-trace-context.js';
import { BridgeReviewFacetMenu } from '../chrome/bridge-review-facet-menu.js';
import type { BridgeCodeViewItemPresentation } from '../code-view/bridge-code-view-materialization.js';
import type { BridgeReviewCodeViewOptions } from '../code-view/bridge-code-view-options.js';
import type { SelectedContentPaintTelemetryStart } from '../code-view/bridge-code-view-panel-types.js';
import type { BridgeCodeViewAnnotationReveal } from '../code-view/bridge-code-view-panel-types.js';
import {
	BridgeCodeViewPanel,
	type BridgeCodeViewControlHandle,
} from '../code-view/bridge-code-view-panel.js';
import type { BridgeCodeViewRenderFulfillmentCoordinator } from '../code-view/bridge-code-view-render-fulfillment.js';
import type { ReviewContentDemandTelemetry } from '../content/review-content-demand-types.js';
import type {
	BridgeReviewProjectionMode,
	BridgeReviewProjectionResult,
	BridgeReviewSearchMode,
} from '../models/review-projection-models.js';
import { scheduleBridgeReviewActivationSelectedContentPaint } from '../telemetry/bridge-review-viewer-telemetry.js';
import { bridgeTreesDisclosurePolicyIdentity } from '../trees/bridge-trees-controller.js';
import { BridgeReviewTreesPanel } from '../trees/bridge-trees-panel.js';
import type { BridgeReviewTreeSelectionRevealRequest } from '../trees/bridge-trees-panel.js';

export interface ReviewViewerShellProps {
	readonly paneReloadPort?: BridgePaneReloadPort | undefined;
	readonly railVisible?: boolean | undefined;
	readonly onRetryRead?: (() => void) | undefined;
	readonly regionSurfaceStatus?: BridgeRegionSurfaceStatus;
	readonly onRetryRegion?: () => void;
	readonly annotationReveal?: BridgeCodeViewAnnotationReveal | null;
	readonly onAnnotationRevealComplete?: (requestId: number) => void;
	readonly activationCause?: 'context_switcher' | 'native_request' | 'review_file_corner';
	readonly activationSequence?: number;
	readonly activationStartedAtPerfNow?: number;
	readonly codeViewOptions?: BridgeReviewCodeViewOptions;
	readonly presentationRegistry: BridgeReviewItemRegistry;
	readonly presentationPositionKey: string;
	readonly reviewPackage: BridgeReviewPackage;
	readonly comparisonPaneState: BridgeReviewComparisonPaneState;
	readonly onRetryComparison: (target: BridgeReviewComparisonTarget) => void;
	readonly reviewTreeRows?: readonly ReviewTreeRowMetadata[];
	readonly projection: BridgeReviewProjectionResult;
	readonly renderFulfillmentCoordinator: BridgeCodeViewRenderFulfillmentCoordinator;
	readonly selectedItemId: string | null;
	readonly selectedContentLoadingItemId?: string | null;
	readonly selectedContentPaintTelemetryStart?: SelectedContentPaintTelemetryStart | null;
	readonly onSelectItem: (itemId: string) => void;
	readonly onHoveredItemIdChange?: (itemId: string | null) => void;
	readonly panelChromeSlice: BridgeMainPanelChromeSlice;
	readonly selectedContentText?: string | null;
	readonly selectedCodeViewItem?: BridgeMainCodeViewItem | null;
	readonly selectionCommitDurationMilliseconds?: number | null;
	readonly selectedItemPresentation?: BridgeCodeViewItemPresentation | null;
	readonly selectedContentUnavailablePath?: string | null;
	readonly selectedContentFailure?: BridgeRegionFailure | null;
	readonly selectedCanvasLoadingReason?: BridgeReviewCanvasLoadingReason | null;
	readonly lastSelectedDemandTelemetry?: ReviewContentDemandTelemetry | null;
	readonly lastVisibleDemandTelemetry?: ReviewContentDemandTelemetry | null;
	readonly codeViewWorkerPoolEnabled?: boolean;
	readonly codeViewWorkerFactory?: () => Worker;
	readonly projectionMode?: BridgeReviewProjectionMode;
	readonly treeSearchText?: string;
	readonly treeAcceptedSearchText?: string;
	readonly treeSelectionRevealRequest?: BridgeReviewTreeSelectionRevealRequest | null;
	readonly treeSearchMode?: BridgeReviewSearchMode;
	readonly treeAcceptedSearchMode?: BridgeReviewSearchMode;
	readonly treeSearchError?: BridgeViewerSearchError | null;
	readonly treeSearchStatusMessage?: string | null;
	readonly treeSearchOpen?: boolean;
	readonly onTreeSearchToggle?: () => void;
	readonly onTreeSearchModeChange?: (mode: BridgeReviewSearchMode) => void;
	readonly onTreeSearchTextChange?: (searchText: string) => void;
	readonly onTreeSearchClear?: () => void;
	readonly onTreeSearchClose?: () => void;
	readonly facetMenuOpen: boolean;
	readonly onFacetMenuOpenChange: (isOpen: boolean) => void;
	readonly gitStatusFilter?: BridgeFileChangeKind | 'all';
	readonly isActive?: boolean;
	readonly onFilterChange?: (
		filter: Extract<BridgeFileTreeFilterCandidate, { readonly surface: 'review' }>,
	) => void;
	readonly categoryFilter?: BridgeViewerFileCategory | 'all';
	readonly showBinary?: boolean;
	readonly showLarge?: boolean;
	readonly onCodeViewControlHandleChange?: (handle: BridgeCodeViewControlHandle | null) => void;
	readonly onOpenFile?: (path: string) => void;
	readonly onCodeViewVisibleItemIdsChange?: (itemIds: readonly string[]) => void;
	readonly onAnnotationAttentionItemIdsChange?: (itemIds: readonly string[]) => void;
	readonly onAnnotationEditorAttentionItemIdsChange?: (itemIds: readonly string[]) => void;
	readonly onReadingPositionItemIdChange?: (itemId: string | null) => void;
	readonly onTreeVisibleItemIdsChange?: (itemIds: readonly string[]) => void;
	readonly telemetryRecorder?: BridgeTelemetryRecorder;
	readonly telemetryParentTraceContext?: BridgeTraceContext | null;
	readonly visibleCodeViewItems?: readonly BridgeMainCodeViewItem[];
	readonly viewerContextSwitcher?: ReactNode;
	readonly viewerHeaderControls?: ReactNode;
}

export type BridgeReviewCanvasLoadingReason = 'content';

const hiddenVisiblePathTextByRegistry = new WeakMap<BridgeReviewItemRegistry, string>();

export function ReviewViewerShell(props: ReviewViewerShellProps): ReactElement {
	const surfaceRootRef = useRef<HTMLElement>(null);
	const searchTriggerRef = useRef<HTMLButtonElement>(null);
	const recordedActivationPaintSequenceRef = useRef<number | null>(null);
	useEffect((): (() => void) | void => {
		if (
			props.isActive !== true ||
			props.activationSequence === undefined ||
			props.activationStartedAtPerfNow === undefined ||
			props.selectedCodeViewItem === null ||
			props.selectedCodeViewItem === undefined ||
			props.telemetryRecorder === undefined ||
			recordedActivationPaintSequenceRef.current === props.activationSequence
		) {
			return;
		}
		const activationSequence = props.activationSequence;
		const activationStartedAtPerfNow = props.activationStartedAtPerfNow;
		const telemetryRecorder = props.telemetryRecorder;
		const cancelPaint = scheduleBridgeReviewActivationSelectedContentPaint({
			activationSequence,
			activationStartedAtPerfNow,
			onPainted: (): void => {
				recordedActivationPaintSequenceRef.current = activationSequence;
			},
			telemetryRecorder,
			traceContext: props.telemetryParentTraceContext ?? null,
		});
		return cancelPaint;
	}, [
		props.activationSequence,
		props.activationStartedAtPerfNow,
		props.isActive,
		props.selectedCodeViewItem,
		props.telemetryParentTraceContext,
		props.telemetryRecorder,
	]);
	const treeSearchText = props.treeSearchText ?? '';
	const treeSearchOpen = props.treeSearchOpen === true || treeSearchText.length > 0;
	useBridgeViewerSearchFocusRestoration({
		isActive: props.isActive ?? true,
		isSearchOpen: treeSearchOpen,
		searchTriggerRef,
		surfaceRootRef,
	});
	return renderReviewViewerShellPresentation({ props, searchTriggerRef, surfaceRootRef });
}

export function renderReviewViewerShellPresentation(presentation: {
	readonly props: ReviewViewerShellProps;
	readonly searchTriggerRef: RefObject<HTMLButtonElement | null>;
	readonly surfaceRootRef: RefObject<HTMLElement | null>;
}): ReactElement {
	const { props, searchTriggerRef, surfaceRootRef } = presentation;
	const registry = props.presentationRegistry;
	const hiddenVisiblePathText = hiddenVisiblePathTextForRegistry(registry);
	const projectionMode = props.projectionMode ?? { kind: 'normalReview' };
	const gitStatusFilter = props.gitStatusFilter ?? 'all';
	const categoryFilter = props.categoryFilter ?? 'all';
	const statusText = null;
	const comparisonIsLoading = bridgeReviewComparisonPaneIsLoading(props.comparisonPaneState);
	const treeSearchText = props.treeSearchText ?? '';
	const treeSearchMode = props.treeSearchMode ?? { kind: 'text' };
	const treeAcceptedSearchText = props.treeAcceptedSearchText ?? treeSearchText;
	const treeAcceptedSearchMode = props.treeAcceptedSearchMode ?? treeSearchMode;
	const treeSearchOpen = props.treeSearchOpen === true || treeSearchText.length > 0;
	const treeSearchCompilation = compileBridgeFileTreeSearchPattern({
		searchMode: treeSearchMode.kind,
		searchText: treeSearchText,
	});
	const treeSearchErrorMessage =
		props.treeSearchError === undefined
			? treeSearchCompilation.searchError === null
				? null
				: 'Invalid regex'
			: props.treeSearchError === null
				? null
				: 'Invalid regex';
	const projection = props.projection;
	const selectedItem =
		props.selectedItemId === null
			? null
			: (props.reviewPackage.itemsById[props.selectedItemId] ?? null);
	const selectedDisplayPath =
		selectedItem === null
			? null
			: (selectedItem.headPath ?? selectedItem.basePath ?? selectedItem.itemId);
	const contentHeaderTitle = bridgeReviewViewerHeaderTitle({
		reviewPackage: props.reviewPackage,
		selectedDisplayPath,
	});
	const selectedContentState = selectedContentStateForShell({
		selectedCanvasLoadingReason: props.selectedCanvasLoadingReason ?? null,
		selectedCodeViewItem: props.selectedCodeViewItem ?? null,
		selectedContentUnavailablePath: props.selectedContentUnavailablePath ?? null,
	});
	const canvasBranch = reviewCanvasBranchForShell({
		selectedContentUnavailablePath: props.selectedContentUnavailablePath ?? null,
	});
	const selectedDemandTelemetry = props.lastSelectedDemandTelemetry ?? null;
	const visibleDemandTelemetry = props.lastVisibleDemandTelemetry ?? null;
	const hasChangedFiles = props.reviewPackage.orderedItemIds.length > 0;
	const surface =
		props.regionSurfaceStatus ??
		bridgeReviewRegionSurfaceStatus({
			comparisonPaneState: props.comparisonPaneState,
			isActive: props.isActive ?? true,
		});
	const regionInput = {
		identity: `${props.reviewPackage.packageId}:${props.reviewPackage.reviewGeneration}:${props.reviewPackage.revision}`,
		hasChangedFiles,
		hasSelectedItem: props.selectedItemId !== null,
		selectedContentLoading: props.selectedCanvasLoadingReason === 'content',
		selectedContentFailure:
			props.selectedContentUnavailablePath == null
				? null
				: (props.selectedContentFailure ?? bridgeReviewSelectedContentReadFailure('unavailable')),
		surface,
	};
	const contentPresentation = bridgeReviewReadyRegionPresentation({
		...regionInput,
		region: 'content',
	});
	const treePresentation = bridgeReviewReadyRegionPresentation({ ...regionInput, region: 'tree' });
	const retryTarget =
		props.comparisonPaneState.kind === 'failedPrevious' ||
		props.comparisonPaneState.kind === 'failedInitial'
			? props.comparisonPaneState.retryTarget
			: null;
	const retrySurface =
		props.onRetryRegion ??
		((): void => {
			if (retryTarget !== null) props.onRetryComparison(retryTarget);
		});
	const failureSummary = (
		<BridgePaneFailureSummarySlot
			active={props.isActive}
			paneReloadPort={props.paneReloadPort}
			entries={[
				{ part: 'review', state: treePresentation, retry: retrySurface },
				{
					part: 'review',
					state: contentPresentation,
					fileName: selectedDisplayPath,
					retry:
						contentPresentation.kind === 'failed' && contentPresentation.failure.scope === 'read'
							? props.onRetryRead
							: retrySurface,
				},
			]}
		/>
	);

	return (
		<main
			ref={surfaceRootRef}
			className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-background text-foreground"
			data-review-selected-demand-admitted-bytes={selectedDemandTelemetry?.admittedBytes}
			data-review-selected-demand-admitted-bytes-by-lane={serializeReviewDemandLaneBytes(
				selectedDemandTelemetry?.admittedBytesByLane,
			)}
			data-review-selected-demand-byte-budget-source={selectedDemandTelemetry?.byteBudgetSource}
			data-review-selected-demand-configured-executor-max-concurrent-loads={
				selectedDemandTelemetry?.configuredExecutorMaxConcurrentLoads
			}
			data-review-selected-demand-configured-executor-max-in-flight-bytes={
				selectedDemandTelemetry?.configuredExecutorMaxInFlightBytes
			}
			data-review-selected-demand-deferred-count={selectedDemandTelemetry?.deferredCount}
			data-review-selected-demand-deferred-estimated-bytes-by-lane={serializeReviewDemandLaneBytes(
				selectedDemandTelemetry?.deferredEstimatedBytesByLane,
			)}
			data-review-selected-demand-dropped-estimated-bytes-by-lane={serializeReviewDemandLaneBytes(
				selectedDemandTelemetry?.droppedEstimatedBytesByLane,
			)}
			data-review-selected-demand-dropped-intent-count={selectedDemandTelemetry?.droppedIntentCount}
			data-review-selected-demand-duration-ms={selectedDemandTelemetry?.durationMilliseconds}
			data-review-selected-demand-executor-in-flight-after-dispatch={
				selectedDemandTelemetry?.executorInFlightCountAfterDispatch
			}
			data-review-selected-demand-executor-in-flight-after={
				selectedDemandTelemetry?.executorInFlightCountAfter
			}
			data-review-selected-demand-executor-in-flight-before={
				selectedDemandTelemetry?.executorInFlightCountBefore
			}
			data-review-selected-demand-executor-queued-load-after={
				selectedDemandTelemetry?.executorQueuedLoadCountAfter
			}
			data-review-selected-demand-failed-count={selectedDemandTelemetry?.failedCount}
			data-review-selected-demand-foreground-intent-count={
				selectedDemandTelemetry?.foregroundIntentCount
			}
			data-review-selected-demand-interest={selectedDemandTelemetry?.interest}
			data-review-selected-demand-item-id={selectedDemandTelemetry?.itemId}
			data-review-selected-demand-package-id={selectedDemandTelemetry?.packageId}
			data-review-selected-demand-package-generation={selectedDemandTelemetry?.reviewGeneration}
			data-review-selected-demand-package-revision={selectedDemandTelemetry?.revision}
			data-review-selected-demand-result-reason={selectedDemandTelemetry?.resultReason}
			data-review-selected-demand-result-status={selectedDemandTelemetry?.resultStatus}
			data-review-selected-demand-load-failure-kind={selectedDemandTelemetry?.resultLoadFailureKind}
			data-review-selected-demand-lane-upgrade-count={selectedDemandTelemetry?.laneUpgradeCount}
			data-review-selected-demand-loaded-count={selectedDemandTelemetry?.loadedCount}
			data-review-selected-demand-max-executor-in-flight={
				selectedDemandTelemetry?.maxExecutorInFlightCount
			}
			data-review-selected-demand-max-executor-queued-load={
				selectedDemandTelemetry?.maxExecutorQueuedLoadCount
			}
			data-review-selected-demand-stale-drop-count={selectedDemandTelemetry?.staleDropCount}
			data-review-selected-demand-visible-intent-count={selectedDemandTelemetry?.visibleIntentCount}
			data-review-visible-demand-admitted-bytes={visibleDemandTelemetry?.admittedBytes}
			data-review-visible-demand-admitted-bytes-by-lane={serializeReviewDemandLaneBytes(
				visibleDemandTelemetry?.admittedBytesByLane,
			)}
			data-review-visible-demand-byte-budget-source={visibleDemandTelemetry?.byteBudgetSource}
			data-review-visible-demand-configured-executor-max-concurrent-loads={
				visibleDemandTelemetry?.configuredExecutorMaxConcurrentLoads
			}
			data-review-visible-demand-configured-executor-max-in-flight-bytes={
				visibleDemandTelemetry?.configuredExecutorMaxInFlightBytes
			}
			data-review-visible-demand-deferred-count={visibleDemandTelemetry?.deferredCount}
			data-review-visible-demand-deferred-estimated-bytes-by-lane={serializeReviewDemandLaneBytes(
				visibleDemandTelemetry?.deferredEstimatedBytesByLane,
			)}
			data-review-visible-demand-dropped-estimated-bytes-by-lane={serializeReviewDemandLaneBytes(
				visibleDemandTelemetry?.droppedEstimatedBytesByLane,
			)}
			data-review-visible-demand-dropped-intent-count={visibleDemandTelemetry?.droppedIntentCount}
			data-review-visible-demand-duration-ms={visibleDemandTelemetry?.durationMilliseconds}
			data-review-visible-demand-executor-in-flight-after-dispatch={
				visibleDemandTelemetry?.executorInFlightCountAfterDispatch
			}
			data-review-visible-demand-executor-in-flight-after={
				visibleDemandTelemetry?.executorInFlightCountAfter
			}
			data-review-visible-demand-executor-in-flight-before={
				visibleDemandTelemetry?.executorInFlightCountBefore
			}
			data-review-visible-demand-executor-queued-load-after={
				visibleDemandTelemetry?.executorQueuedLoadCountAfter
			}
			data-review-visible-demand-failed-count={visibleDemandTelemetry?.failedCount}
			data-review-visible-demand-foreground-intent-count={
				visibleDemandTelemetry?.foregroundIntentCount
			}
			data-review-visible-demand-interest={visibleDemandTelemetry?.interest}
			data-review-visible-demand-item-id={visibleDemandTelemetry?.itemId}
			data-review-visible-demand-package-id={visibleDemandTelemetry?.packageId}
			data-review-visible-demand-package-generation={visibleDemandTelemetry?.reviewGeneration}
			data-review-visible-demand-package-revision={visibleDemandTelemetry?.revision}
			data-review-visible-demand-lane-upgrade-count={visibleDemandTelemetry?.laneUpgradeCount}
			data-review-visible-demand-loaded-count={visibleDemandTelemetry?.loadedCount}
			data-review-visible-demand-max-executor-in-flight={
				visibleDemandTelemetry?.maxExecutorInFlightCount
			}
			data-review-visible-demand-max-executor-queued-load={
				visibleDemandTelemetry?.maxExecutorQueuedLoadCount
			}
			data-review-visible-demand-stale-drop-count={visibleDemandTelemetry?.staleDropCount}
			data-review-visible-demand-visible-intent-count={visibleDemandTelemetry?.visibleIntentCount}
			data-review-selection-commit-duration-ms={
				props.selectionCommitDurationMilliseconds ?? undefined
			}
			data-review-canvas-branch={canvasBranch}
			data-selected-content-state={selectedContentState}
			data-selected-display-path={selectedDisplayPath ?? undefined}
			data-review-metadata-id={props.reviewPackage.packageId}
			data-review-metadata-generation={props.reviewPackage.reviewGeneration}
			data-review-metadata-revision={props.reviewPackage.revision}
			data-review-metadata-item-count={props.reviewPackage.orderedItemIds.length}
			data-review-metadata-tree-row-count={props.reviewTreeRows?.length ?? 0}
			data-review-base-endpoint-id={props.reviewPackage.query.baseEndpointId}
			data-review-base-endpoint-kind={props.reviewPackage.baseEndpoint.kind}
			data-review-base-provider-identity={props.reviewPackage.baseEndpoint.providerIdentity}
			data-review-head-endpoint-id={props.reviewPackage.query.headEndpointId}
			data-review-head-endpoint-kind={props.reviewPackage.headEndpoint.kind}
			data-review-head-provider-identity={props.reviewPackage.headEndpoint.providerIdentity}
			data-projection-id={projection.projectionId}
			data-projection-mode={projectionMode.kind}
			data-sidebar-position="right"
			data-testid="review-viewer-shell"
			tabIndex={-1}
		>
			<BridgeViewerResizableRailLayout
				railVisible={props.railVisible}
				failureSummary={failureSummary}
				autosaveId="bridge-viewer-right-rail"
				// The loaded review shell keeps its resizable frame mounted across activation so the
				// CodeView and tree are never remounted when Review goes hidden.
				// Rail-frame gating stays on the lightweight fallback shells, not real content.
				isActive={true}
				content={
					<BridgeViewerContextPanelProvider>
						<section
							aria-label="Selected content"
							className="grid h-full min-h-0 min-w-0 grid-rows-[auto_auto_minmax(0,1fr)] overflow-hidden overscroll-contain bg-background"
							data-testid="bridge-review-code-scroll"
						>
							<BridgeViewerContentHeader
								controls={props.viewerHeaderControls}
								mode="review"
								statusText={statusText}
								title={contentHeaderTitle}
							/>
							<div data-testid="bridge-review-comparison-status-slot"></div>
							<BridgeViewerContextPanelViewport testId="bridge-review-context-panel-viewport">
								<section
									aria-label="Code canvas"
									aria-busy={comparisonIsLoading ? 'true' : undefined}
									className={cn(
										'relative h-full min-h-0 min-w-0 bg-background',
										comparisonIsLoading ? 'pointer-events-none' : undefined,
									)}
									data-testid="bridge-review-canvas"
									inert={comparisonIsLoading || undefined}
								>
									<BridgeRegionPresentation
										region="review-content"
										testId={hasChangedFiles ? undefined : 'bridge-review-empty-canvas'}
										shape="diff"
										state={contentPresentation}
										keepContentMounted
										emptyCopy={{
											noSelection: bridgeReviewRegionDisplaySpec.noFileSelection,
											certified: bridgeReviewRegionDisplaySpec.certifiedContent,
										}}
									>
										{!hasChangedFiles ? (
											contentPresentation.kind === 'updating' ||
											(contentPresentation.kind === 'failed' &&
												contentPresentation.retainsContent) ? (
												<p className="px-3 py-2 text-sm text-muted-foreground">
													{bridgeReviewRegionDisplaySpec.certifiedContent}
												</p>
											) : null
										) : props.selectedContentUnavailablePath !== undefined &&
										  props.selectedContentUnavailablePath !== null ? null : (
											<BridgeCodeViewPanel
												annotationReveal={props.annotationReveal ?? null}
												{...(props.onAnnotationRevealComplete === undefined
													? {}
													: { onAnnotationRevealComplete: props.onAnnotationRevealComplete })}
												presentationPositionKey={props.presentationPositionKey}
												projection={projection}
												renderFulfillmentCoordinator={props.renderFulfillmentCoordinator}
												reviewPackage={props.reviewPackage}
												selectedCodeViewItem={props.selectedCodeViewItem ?? null}
												selectedContentLoadingItemId={props.selectedContentLoadingItemId ?? null}
												selectedContentPaintTelemetryStart={
													props.selectedContentPaintTelemetryStart ?? null
												}
												selectedItemId={props.selectedItemId}
												selectedItemPresentation={props.selectedItemPresentation ?? null}
												{...(props.onOpenFile === undefined
													? {}
													: { onOpenFile: props.onOpenFile })}
												telemetryParentTraceContext={props.telemetryParentTraceContext ?? null}
												visibleCodeViewItems={props.visibleCodeViewItems ?? []}
												{...(props.codeViewOptions === undefined
													? {}
													: { codeViewOptions: props.codeViewOptions })}
												{...(props.onCodeViewVisibleItemIdsChange === undefined
													? {}
													: { onVisibleItemIdsChange: props.onCodeViewVisibleItemIdsChange })}
												{...(props.onAnnotationAttentionItemIdsChange === undefined
													? {}
													: {
															onAnnotationAttentionItemIdsChange:
																props.onAnnotationAttentionItemIdsChange,
														})}
												{...(props.onAnnotationEditorAttentionItemIdsChange === undefined
													? {}
													: {
															onAnnotationEditorAttentionItemIdsChange:
																props.onAnnotationEditorAttentionItemIdsChange,
														})}
												{...(props.onReadingPositionItemIdChange === undefined
													? {}
													: {
															onReadingPositionItemIdChange: props.onReadingPositionItemIdChange,
														})}
												{...(props.onCodeViewControlHandleChange === undefined
													? {}
													: {
															onControlHandleChange: props.onCodeViewControlHandleChange,
														})}
												{...(props.codeViewWorkerPoolEnabled === undefined
													? {}
													: { workerPoolEnabled: props.codeViewWorkerPoolEnabled })}
												{...(props.codeViewWorkerFactory === undefined
													? {}
													: { workerFactory: props.codeViewWorkerFactory })}
												{...(props.telemetryRecorder === undefined
													? {}
													: { telemetryRecorder: props.telemetryRecorder })}
											/>
										)}
									</BridgeRegionPresentation>
								</section>
							</BridgeViewerContextPanelViewport>
						</section>
					</BridgeViewerContextPanelProvider>
				}
				contentTestId="bridge-review-content-panel"
				handleTestId="bridge-review-rail-resize-handle"
				rail={BridgeViewerRightRailShell({
					body: (
						<nav
							aria-label="Changed files"
							aria-busy={comparisonIsLoading ? 'true' : undefined}
							className={cn(
								'h-full min-h-0',
								comparisonIsLoading ? 'pointer-events-none' : undefined,
							)}
							data-testid="bridge-review-rail-tree-slot"
							inert={comparisonIsLoading || undefined}
						>
							<BridgeRegionPresentation
								region="review-tree"
								testId={hasChangedFiles ? undefined : 'bridge-review-empty-file-tree'}
								shape="tree"
								state={treePresentation}
								keepContentMounted
								emptyCopy={{
									noSelection: bridgeReviewRegionDisplaySpec.noSelection,
									certified: bridgeReviewRegionDisplaySpec.certifiedTree,
								}}
							>
								{hasChangedFiles ? (
									<BridgeReviewTreesPanel
										{...(props.activationCause === undefined
											? {}
											: { activationCause: props.activationCause })}
										{...(props.activationSequence === undefined
											? {}
											: { activationSequence: props.activationSequence })}
										{...(props.activationStartedAtPerfNow === undefined
											? {}
											: { activationStartedAtPerfNow: props.activationStartedAtPerfNow })}
										isActive={props.isActive === true}
										key={bridgeTreesDisclosurePolicyIdentity}
										presentationPositionKey={props.presentationPositionKey}
										onSelectItem={props.onSelectItem}
										{...(props.onHoveredItemIdChange === undefined
											? {}
											: { onHoveredItemIdChange: props.onHoveredItemIdChange })}
										{...(props.onTreeVisibleItemIdsChange === undefined
											? {}
											: { onVisibleItemIdsChange: props.onTreeVisibleItemIdsChange })}
										projection={projection}
										reviewPackage={props.reviewPackage}
										reviewTreeRows={props.reviewTreeRows ?? []}
										searchMode={treeAcceptedSearchMode}
										searchText={treeAcceptedSearchText}
										selectedItemId={props.selectedItemId}
										selectionRevealRequest={props.treeSelectionRevealRequest ?? null}
										{...(props.telemetryRecorder === undefined
											? {}
											: { telemetryRecorder: props.telemetryRecorder })}
										telemetryTraceContext={props.telemetryParentTraceContext ?? null}
									/>
								) : treePresentation.kind === 'updating' ||
								  (treePresentation.kind === 'failed' && treePresentation.retainsContent) ? (
									<p className="px-3 py-2 text-sm text-muted-foreground">
										{bridgeReviewRegionDisplaySpec.certifiedTree}
									</p>
								) : null}
							</BridgeRegionPresentation>
							{registry.visibleItems.length === 0 ? null : (
								<div aria-hidden="true" hidden>
									{hiddenVisiblePathText}
								</div>
							)}
						</nav>
					),
					bodyClassName: 'min-h-0 flex-1 overflow-hidden overscroll-contain',
					bodyTestId: 'bridge-review-rail-scroll',
					layout: 'stack',
					testId: 'bridge-review-sidebar',
					toolbarBelow: (
						<>
							{props.railVisible === false ? null : failureSummary}
							{treeSearchOpen ? (
								<BridgeViewerSearchField
									clearButtonTestId="bridge-review-search-clear"
									errorMessage={treeSearchErrorMessage}
									inputTestId="bridge-review-search-input"
									onChange={(value): void => props.onTreeSearchTextChange?.(value)}
									onClear={(): void => {
										if (props.onTreeSearchClear !== undefined) {
											props.onTreeSearchClear();
											return;
										}
										props.onTreeSearchTextChange?.('');
									}}
									onClose={(): void => props.onTreeSearchClose?.()}
									onSearchModeChange={(mode): void => props.onTreeSearchModeChange?.(mode)}
									regexToggleTestId="bridge-review-regex-toggle"
									searchMode={treeSearchMode}
									value={treeSearchText}
								/>
							) : null}
						</>
					),
					toolbarFooter: (
						<BridgeViewerSearchStatus
							message={props.treeSearchStatusMessage ?? treeSearchErrorMessage}
							testId="bridge-review-tree-search-status"
						/>
					),
					toolbar: BridgeViewerRailToolbar({
						leading: props.viewerContextSwitcher,
						leadingTestId: 'bridge-review-rail-toolbar-leading',
						testId: 'bridge-review-rail-toolbar',
						trailing: [
							<div className="shrink-0" data-testid="bridge-review-facet-menu" key="facet-menu">
								<BridgeReviewFacetMenu
									categoryFilter={categoryFilter}
									gitStatusFilter={gitStatusFilter}
									gitStatusOptions={gitStatusOptions}
									onFilterChange={(value): void => props.onFilterChange?.(value)}
									onOpenChange={props.onFacetMenuOpenChange}
									open={props.facetMenuOpen}
									showBinary={props.showBinary ?? false}
									showLarge={props.showLarge ?? false}
								/>
							</div>,
							<div data-testid="bridge-review-search-control-slot" key="search-control">
								<span className="sr-only">Search files</span>
								<BridgeViewerSearchControl
									isActive={treeSearchOpen}
									onToggleSearch={(): void => props.onTreeSearchToggle?.()}
									searchToggleTestId="bridge-review-search-toggle"
									testId="bridge-review-search-control"
									triggerRef={searchTriggerRef}
								/>
							</div>,
						],
						trailingTestId: 'bridge-review-rail-toolbar-trailing',
					}),
				})}
				railTestId="bridge-review-resizable-rail"
			/>
		</main>
	);
}

function hiddenVisiblePathTextForRegistry(registry: BridgeReviewItemRegistry): string {
	const cachedText = hiddenVisiblePathTextByRegistry.get(registry);
	if (cachedText !== undefined) {
		return cachedText;
	}
	const text = registry.visibleItems.map((item) => reviewItemPathLabel(item)).join(' ');
	hiddenVisiblePathTextByRegistry.set(registry, text);
	return text;
}

function bridgeReviewViewerHeaderTitle(props: {
	readonly reviewPackage: BridgeReviewPackage;
	readonly selectedDisplayPath: string | null;
}): string {
	const sourceTitle = bridgeReviewComparisonTitle(props.reviewPackage);
	return props.selectedDisplayPath === null
		? sourceTitle
		: `${sourceTitle} / ${props.selectedDisplayPath}`;
}

function bridgeReviewComparisonTitle(reviewPackage: BridgeReviewPackage): string {
	if (reviewPackage.comparisonOrigin?.kind === 'contribution') {
		const reviewedSubjectLabel = reviewPackage.reviewedSubjectLabel?.trim();
		return `${reviewedSubjectLabel === undefined || reviewedSubjectLabel.length === 0 ? 'Current worktree' : reviewedSubjectLabel} changes`;
	}
	if (
		reviewPackage.query.comparisonSemantics === 'indexDelta' &&
		reviewPackage.headEndpoint.kind === 'index'
	) {
		return 'Staged changes';
	}
	if (
		reviewPackage.query.comparisonSemantics === 'workingTreeDelta' &&
		reviewPackage.baseEndpoint.kind === 'index' &&
		reviewPackage.headEndpoint.kind === 'workingTree'
	) {
		return 'Unstaged changes';
	}
	return 'Current worktree changes';
}

function selectedContentStateForShell(props: {
	readonly selectedCanvasLoadingReason: BridgeReviewCanvasLoadingReason | null;
	readonly selectedCodeViewItem: BridgeMainCodeViewItem | null;
	readonly selectedContentUnavailablePath: string | null;
}): 'failed' | 'loading' | 'ready' | 'unavailable' {
	if (props.selectedContentUnavailablePath !== null) {
		return 'failed';
	}
	if (props.selectedCodeViewItem !== null) {
		return 'ready';
	}
	if (props.selectedCanvasLoadingReason === 'content') {
		return 'loading';
	}
	return 'unavailable';
}

function reviewCanvasBranchForShell(props: {
	readonly selectedContentUnavailablePath: string | null;
}): 'code' | 'unavailable' {
	if (props.selectedContentUnavailablePath !== null) {
		return 'unavailable';
	}
	return 'code';
}

const gitStatusOptions: readonly BridgeViewerFacetMenuOption<BridgeFileChangeKind | 'all'>[] = [
	{ value: 'all', label: 'All statuses', description: 'Show every Git change kind', icon: '*' },
	{ value: 'added', label: 'Added', description: 'New files and created paths', icon: 'A' },
	{ value: 'modified', label: 'Modified', description: 'Files changed in place', icon: 'M' },
	{ value: 'renamed', label: 'Renamed', description: 'Moves and path renames', icon: 'R' },
	{ value: 'deleted', label: 'Deleted', description: 'Removed files and paths', icon: 'D' },
	{
		value: 'copied',
		label: 'Copied',
		description: 'Copied paths when Git reports them',
		icon: 'C',
	},
];

function serializeReviewDemandLaneBytes(
	value: ReviewContentDemandTelemetry['admittedBytesByLane'] | undefined,
): string | undefined {
	return value === undefined ? undefined : JSON.stringify(value);
}
