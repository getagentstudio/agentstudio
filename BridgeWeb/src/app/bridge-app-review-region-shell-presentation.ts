import type { BridgePaneSurfaceClient } from '../core/comm-worker/bridge-pane-runtime.js';
import { bridgeReviewSelectedContentReadFailure } from '../features/review/bridge-review-region-presentation.js';
import type { BridgeFileChangeKind } from '../foundation/review-package/bridge-review-package.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import type { deriveBridgeReviewCodeViewOptions } from '../review-viewer/code-view/bridge-code-view-options.js';
import type { BridgeCodeViewAnnotationReveal } from '../review-viewer/code-view/bridge-code-view-panel-types.js';
import type { BridgeCodeViewControlHandle } from '../review-viewer/code-view/bridge-code-view-panel.js';
import type {
	BridgeReviewProjectionMode,
	BridgeReviewSearchMode,
} from '../review-viewer/models/review-projection-models.js';
import type { BridgeReviewTreeSelectionRevealRequest } from '../review-viewer/trees/bridge-trees-panel.js';
import type { BridgeFileTreeFilterCandidate } from './bridge-app-control.js';
import type { bridgeReviewPresentationSnapshotForDisplay } from './bridge-app-review-presentation-adapter.js';
import type { BridgeReviewRenderSnapshotController } from './bridge-app-review-render-snapshot-controller.js';
import type { BridgeReviewViewerModeProps } from './bridge-app-review-viewer-mode.js';
import type { BridgeReviewViewerPresentationState } from './bridge-app-review-viewer-shell-boundary.js';
import type { BridgeRegionSurfaceStatus } from './bridge-region-presentation-state.js';
import type { bridgeReviewComparisonPaneState } from './bridge-review-comparison-pane-state.js';
import type { BridgeViewerSearchError } from './bridge-viewer-search-state.js';
type BridgeReviewFilterCandidate = Extract<
	BridgeFileTreeFilterCandidate,
	{ readonly surface: 'review' }
>;
export function bridgeReviewRegionShellPresentation(props: {
	readonly regionSurfaceStatus: BridgeRegionSurfaceStatus;
	readonly onRetryRegion: () => void;
	readonly annotationReveal: BridgeCodeViewAnnotationReveal | null;
	readonly onAnnotationRevealComplete: ((requestId: number) => void) | undefined;
	readonly activationCause: BridgeReviewViewerModeProps['activationCause'];
	readonly activationSequence: number | undefined;
	readonly activationStartedAtPerfNow: number | undefined;
	readonly comparisonPaneState: ReturnType<typeof bridgeReviewComparisonPaneState>;
	readonly onRetryComparison: BridgeReviewRenderSnapshotController['updateReviewComparisonTarget'];
	readonly onAnnotationAttentionItemIdsChange: (itemIds: readonly string[]) => void;
	readonly onAnnotationEditorAttentionItemIdsChange: (itemIds: readonly string[]) => void;
	readonly onReadingPositionItemIdChange: (itemId: string | null) => void;
	readonly codeViewOptions: ReturnType<typeof deriveBridgeReviewCodeViewOptions>;
	readonly codeViewWorkerFactory: (() => Worker) | undefined;
	readonly codeViewWorkerPoolEnabled: boolean | undefined;
	readonly panelChromeSlice: BridgeReviewRenderSnapshotController['panelChromeSlice'];
	readonly projectionMode: BridgeReviewProjectionMode;
	readonly codeViewControlHandleRef: { current: BridgeCodeViewControlHandle | null };
	readonly facetMenuOpen: boolean;
	readonly categoryFilter: BridgeReviewFilterCandidate['categoryFilter'];
	readonly gitStatusFilter: BridgeFileChangeKind | 'all';
	readonly showBinary: boolean;
	readonly showLarge: boolean;
	readonly presentationPositionKey: string;
	readonly presentationSnapshot: ReturnType<typeof bridgeReviewPresentationSnapshotForDisplay>;
	readonly renderFulfillmentCoordinator: BridgePaneSurfaceClient['renderFulfillmentCoordinator'];
	readonly reviewSourceSlice: BridgeReviewRenderSnapshotController['reviewSourceSlice'];
	readonly selectedCodeViewItem: BridgeReviewRenderSnapshotController['selectedCodeViewItem'];
	readonly selectedContentAvailability: BridgeReviewRenderSnapshotController['selectedContentAvailability'];
	readonly selectedItemId: string | null;
	readonly selectedReviewItem: BridgeReviewRenderSnapshotController['selectedReviewItem'];
	readonly selectReviewItem: (itemId: string) => boolean;
	readonly setReviewCodeViewVisibleItemIds: (itemIds: readonly string[]) => void;
	readonly setReviewViewportItemIds: (itemIds: readonly string[]) => void;
	readonly telemetryRecorder: BridgeTelemetryRecorder;
	readonly treeAcceptedSearchMode: BridgeReviewSearchMode;
	readonly treeAcceptedSearchText: string;
	readonly treeSearchError: BridgeViewerSearchError | null;
	readonly treeSearchMode: BridgeReviewSearchMode;
	readonly treeSearchOpen: boolean;
	readonly treeSearchText: string;
	readonly treeSearchStatusMessage: string | null;
	readonly treeSelectionRevealRequest: BridgeReviewTreeSelectionRevealRequest | null;
	readonly visibleCodeViewItems: BridgeReviewRenderSnapshotController['visibleCodeViewItems'];
	readonly onTreeSearchClear: () => void;
	readonly onTreeSearchClose: () => void;
	readonly onTreeSearchModeChange: (mode: BridgeReviewSearchMode) => void;
	readonly onTreeSearchToggle: () => void;
	readonly onTreeSearchTextChange: (searchText: string) => void;
	readonly onFacetMenuOpenChange: (isOpen: boolean) => void;
	readonly onFilterChange: (filter: BridgeReviewFilterCandidate) => void;
	readonly onHoveredItemIdChange: (itemId: string | null) => void;
	readonly onOpenFile?: (path: string) => void;
}): BridgeReviewViewerPresentationState {
	if (props.panelChromeSlice.reviewComparison?.attempt.status === 'selectionRequired')
		return { status: 'noTarget' };
	if (props.reviewSourceSlice === null) return { status: 'metadataLoading' };
	if ('kind' in props.reviewSourceSlice && props.reviewSourceSlice.kind === 'readyEmpty') {
		return { status: 'readyEmpty' };
	}
	if (props.reviewSourceSlice.status === 'failed') {
		return { error: 'Review metadata is unavailable', status: 'metadataFailed' };
	}
	if (props.reviewSourceSlice.status === 'loading') return { status: 'metadataLoading' };
	if (props.presentationSnapshot === null) return { status: 'projectionPending' };
	const selectedUnavailablePath = reviewSelectedUnavailablePath(props);
	const selectedContentIsLoading =
		props.selectedItemId !== null &&
		props.selectedCodeViewItem === null &&
		selectedUnavailablePath === null;
	return {
		presentationKey: props.presentationSnapshot.presentationKey,
		shellProps: {
			regionSurfaceStatus: props.regionSurfaceStatus,
			onRetryRegion: props.onRetryRegion,
			annotationReveal: props.annotationReveal,
			...(props.onAnnotationRevealComplete === undefined
				? {}
				: { onAnnotationRevealComplete: props.onAnnotationRevealComplete }),
			...(props.activationCause === undefined ? {} : { activationCause: props.activationCause }),
			...(props.activationSequence === undefined
				? {}
				: { activationSequence: props.activationSequence }),
			...(props.activationStartedAtPerfNow === undefined
				? {}
				: { activationStartedAtPerfNow: props.activationStartedAtPerfNow }),
			comparisonPaneState: props.comparisonPaneState,
			codeViewOptions: props.codeViewOptions,
			facetMenuOpen: props.facetMenuOpen,
			categoryFilter: props.categoryFilter,
			gitStatusFilter: props.gitStatusFilter,
			showBinary: props.showBinary,
			showLarge: props.showLarge,
			onCodeViewControlHandleChange: (handle): void => {
				props.codeViewControlHandleRef.current = handle;
			},
			onFilterChange: props.onFilterChange,
			onFacetMenuOpenChange: props.onFacetMenuOpenChange,
			onHoveredItemIdChange: props.onHoveredItemIdChange,
			...(props.onOpenFile === undefined ? {} : { onOpenFile: props.onOpenFile }),
			onRetryComparison: props.onRetryComparison,
			onAnnotationAttentionItemIdsChange: props.onAnnotationAttentionItemIdsChange,
			onAnnotationEditorAttentionItemIdsChange: props.onAnnotationEditorAttentionItemIdsChange,
			onReadingPositionItemIdChange: props.onReadingPositionItemIdChange,
			panelChromeSlice: props.panelChromeSlice,
			projectionMode: props.projectionMode,
			presentationPositionKey: props.presentationPositionKey,
			presentationRegistry: props.presentationSnapshot.presentationRegistry,
			renderFulfillmentCoordinator: props.renderFulfillmentCoordinator,
			onCodeViewVisibleItemIdsChange: props.setReviewCodeViewVisibleItemIds,
			onTreeSearchModeChange: props.onTreeSearchModeChange,
			onTreeSearchClear: props.onTreeSearchClear,
			onTreeSearchClose: props.onTreeSearchClose,
			onTreeSearchToggle: props.onTreeSearchToggle,
			onTreeSearchTextChange: props.onTreeSearchTextChange,
			onSelectItem: (itemId): void => {
				props.selectReviewItem(itemId);
			},
			onTreeVisibleItemIdsChange: props.setReviewViewportItemIds,
			projection: props.presentationSnapshot.projection,
			reviewPackage: props.presentationSnapshot.reviewPackage,
			reviewTreeRows: props.presentationSnapshot.reviewTreeRows,
			selectedCanvasLoadingReason: selectedContentIsLoading ? 'content' : null,
			selectedCodeViewItem: props.selectedCodeViewItem,
			selectedContentLoadingItemId: selectedContentIsLoading ? props.selectedItemId : null,
			selectedContentUnavailablePath: selectedUnavailablePath,
			selectedContentFailure:
				selectedUnavailablePath === null
					? null
					: bridgeReviewSelectedContentReadFailure(
							props.selectedContentAvailability?.state === 'failed' ? 'failed' : 'unavailable',
						),
			selectedItemId: props.selectedItemId,
			telemetryRecorder: props.telemetryRecorder,
			treeSearchMode: props.treeSearchMode,
			treeSearchOpen: props.treeSearchOpen,
			treeSearchText: props.treeSearchText,
			treeSearchStatusMessage: props.treeSearchStatusMessage,
			treeAcceptedSearchMode: props.treeAcceptedSearchMode,
			treeAcceptedSearchText: props.treeAcceptedSearchText,
			treeSearchError: props.treeSearchError,
			treeSelectionRevealRequest: props.treeSelectionRevealRequest,
			visibleCodeViewItems: props.visibleCodeViewItems,
			...(props.codeViewWorkerFactory === undefined
				? {}
				: { codeViewWorkerFactory: props.codeViewWorkerFactory }),
			...(props.codeViewWorkerPoolEnabled === undefined
				? {}
				: { codeViewWorkerPoolEnabled: props.codeViewWorkerPoolEnabled }),
		},
		status: 'ready',
	};
}

function reviewSelectedUnavailablePath(
	props: Pick<
		Parameters<typeof bridgeReviewRegionShellPresentation>[0],
		'presentationSnapshot' | 'selectedContentAvailability' | 'selectedItemId' | 'selectedReviewItem'
	>,
): string | null {
	if (
		props.selectedItemId === null ||
		props.presentationSnapshot === null ||
		props.selectedContentAvailability === null ||
		!['failed', 'unavailable'].includes(props.selectedContentAvailability.state)
	) {
		return null;
	}
	return (
		props.selectedReviewItem?.metadata.headPath ??
		props.selectedReviewItem?.metadata.basePath ??
		props.presentationSnapshot.projection.primaryDisplayPathByItemId[props.selectedItemId] ??
		props.selectedItemId
	);
}
