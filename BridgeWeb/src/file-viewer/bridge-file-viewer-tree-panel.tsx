import { FileTree } from '@pierre/trees/react';
import type { ReactElement, ReactNode, Ref } from 'react';

import type { BridgeRegionPresentationState } from '../app/bridge-region-presentation-state.js';
import {
	BridgeRegionPresentation,
	BridgeRegionUpdatingIndicator,
} from '../app/bridge-region-presentation.js';
import { BridgeViewerRailToolbar } from '../app/bridge-viewer-rail-toolbar.js';
import { BridgeViewerRightRailShell } from '../app/bridge-viewer-right-rail-shell.js';
import { BridgeViewerSearchControl } from '../app/bridge-viewer-search-control.js';
import {
	BridgeViewerSearchField,
	BridgeViewerSearchStatus,
} from '../app/bridge-viewer-search-field.js';
import { bridgeViewerTreeStyle } from '../app/bridge-viewer-tree-theme.js';
import type { BridgeMainFileTreePatchStream } from '../core/comm-worker/bridge-main-file-display-patch-applier.js';
import type { BridgeTelemetryRecorder } from '../foundation/telemetry/bridge-telemetry-recorder.js';
import type { BridgeTraceContext } from '../foundation/telemetry/bridge-trace-context.js';
import type {
	BridgeFileViewerFilterMode,
	BridgeFileViewerSearchMode,
	BridgeFileViewerVisibleFileDemandChange,
} from './bridge-file-viewer-contracts.js';
import type {
	BridgeFileViewerDisplaySource,
	BridgeFileViewerDisplayTreeRow,
	BridgeFileViewerSelection,
} from './bridge-file-viewer-display-model.js';
import { BridgeFileViewerFacetMenu } from './bridge-file-viewer-facet-menu.js';
import { useBridgeFileViewerPierreTreeRuntime } from './bridge-file-viewer-pierre-tree-runtime.js';

export interface BridgeFileViewerTreePanelProps {
	readonly failureSummary?: ReactNode;
	readonly presentationState?: BridgeRegionPresentationState;
	readonly completeFileQueryTransaction: (transactionId: string) => boolean;
	readonly filterMode: BridgeFileViewerFilterMode;
	readonly fileTreePatchStream: BridgeMainFileTreePatchStream;
	readonly fileActivationSequence?: number | null;
	readonly fileActivationStartedAtPerfNow?: number | null;
	readonly isActive: boolean;
	readonly isFilterMenuOpen: boolean;
	readonly isSearchOpen: boolean;
	readonly onClearSearch: () => void;
	readonly onFilterMenuOpenChange: (isOpen: boolean) => void;
	readonly onFilterModeChange: (filterMode: BridgeFileViewerFilterMode) => void;
	readonly onSearchModeChange: (searchMode: BridgeFileViewerSearchMode) => void;
	readonly onSearchTextChange: (searchText: string) => void;
	readonly onSelectFile: (selection: BridgeFileViewerSelection) => void;
	readonly onToggleSearch: () => void;
	readonly onVisibleFileDemandChange?: (change: BridgeFileViewerVisibleFileDemandChange) => void;
	readonly projectedTreeRowCount: number;
	readonly searchError: string | null;
	readonly searchMode: BridgeFileViewerSearchMode;
	readonly searchStatusMessage: string | null;
	readonly searchText: string;
	readonly searchTriggerRef?: Ref<HTMLButtonElement>;
	readonly selectedPath: string | null;
	readonly source: BridgeFileViewerDisplaySource | null;
	readonly telemetryRecorder?: BridgeTelemetryRecorder | undefined;
	readonly telemetryTraceContext?: BridgeTraceContext | null | undefined;
	readonly totalTreeHeightPixels: number | null;
	readonly totalTreeHeightSource: 'localProjection' | 'providerFacts' | null;
	readonly totalTreeRowCount: number;
	readonly treeRowByPath: {
		readonly get: (path: string) => BridgeFileViewerDisplayTreeRow | undefined;
	};
	readonly viewerContextSwitcher?: ReactNode;
}

const bridgeFileViewerTreeRowHeightPixels = 24;

export function BridgeFileViewerTreePanel(props: BridgeFileViewerTreePanelProps): ReactElement {
	const { searchError, searchText } = props;
	const treeRuntime = useBridgeFileViewerPierreTreeRuntime({
		completeFileQueryTransaction: props.completeFileQueryTransaction,
		fileActivationSequence: props.fileActivationSequence ?? null,
		fileActivationStartedAtPerfNow: props.fileActivationStartedAtPerfNow ?? null,
		fileTreePatchStream: props.fileTreePatchStream,
		treeRowByPath: props.treeRowByPath,
		onSelectFile: props.onSelectFile,
		...(props.onVisibleFileDemandChange === undefined
			? {}
			: { onVisibleFileDemandChange: props.onVisibleFileDemandChange }),
		selectedPath: props.selectedPath,
		...(props.telemetryRecorder === undefined
			? {}
			: { telemetryRecorder: props.telemetryRecorder }),
		telemetryTraceContext: props.telemetryTraceContext,
	});
	const fallbackRenderedTreeHeightPixels =
		props.projectedTreeRowCount * bridgeFileViewerTreeRowHeightPixels;
	const declaredTreeHeightPixels = props.totalTreeHeightPixels ?? fallbackRenderedTreeHeightPixels;
	const declaredTreeHeightSource = props.totalTreeHeightSource ?? 'localProjection';
	const shouldShowSearchInput =
		props.isSearchOpen || searchText.trim().length > 0 || searchError !== null;
	const visibleCountLabel =
		props.searchError === null
			? `${props.projectedTreeRowCount}/${props.totalTreeRowCount}`
			: 'Invalid regex';
	const sourceLabel = props.source?.sourceId ?? '';

	return (
		<>
			{BridgeViewerRightRailShell({
				ariaLabel: 'Files',
				body: (
					<BridgeRegionPresentation
						keepContentMounted
						region="file-tree"
						shape="tree"
						state={props.presentationState ?? { kind: 'content' }}
						emptyCopy={{ noSelection: 'Select a worktree', certified: 'No files' }}
					>
						<FileTree
							className="h-full min-h-full"
							model={treeRuntime.model}
							style={bridgeViewerTreeStyle}
						/>
					</BridgeRegionPresentation>
				),
				bodyClassName: 'h-full min-h-0 overflow-hidden',
				bodyDataAttributes: {
					'data-worktree-tree-total-size': String(declaredTreeHeightPixels),
					'data-worktree-tree-total-size-source': declaredTreeHeightSource,
				},
				bodyElement: 'section',
				bodyOnClick: treeRuntime.handleTreeClick,
				bodyTestId: 'bridge-file-viewer-pierre-file-tree',
				bodyTabIndex: -1,
				headerTestId: 'bridge-file-viewer-toolbar',
				layout: 'grid',
				rootDataAttributes: { 'data-pierre-file-tree-owner': 'FileTree' },
				testId: 'bridge-file-viewer-sidebar',
				toolbar: BridgeViewerRailToolbar({
					className: 'min-w-0 gap-2',
					leading: (
						<>
							{props.viewerContextSwitcher}
							<BridgeRegionUpdatingIndicator
								state={props.presentationState ?? { kind: 'content' }}
							/>
							<span
								aria-live="polite"
								className="sr-only"
								data-testid="worktree-file-status"
								role="status"
							>
								<span className="sr-only" data-testid="worktree-file-filter-count">
									{visibleCountLabel}
								</span>
								<span className="sr-only" data-testid="worktree-file-provenance">
									{sourceLabel}
								</span>
							</span>
						</>
					),
					leadingClassName: 'flex-1',
					leadingTestId: 'bridge-file-viewer-rail-toolbar-leading',
					testId: 'bridge-file-viewer-rail-toolbar',
					trailing: (
						<>
							<BridgeFileViewerFacetMenu
								filterMode={props.filterMode}
								onFilterModeChange={props.onFilterModeChange}
								onOpenChange={props.onFilterMenuOpenChange}
								open={props.isFilterMenuOpen}
							/>
							<BridgeViewerSearchControl
								isActive={shouldShowSearchInput}
								onToggleSearch={props.onToggleSearch}
								searchToggleTestId="worktree-file-search-toggle"
								testId="worktree-file-search-control"
								{...(props.searchTriggerRef === undefined
									? {}
									: { triggerRef: props.searchTriggerRef })}
							/>
						</>
					),
					trailingClassName: 'shrink-0',
					trailingTestId: 'bridge-file-viewer-rail-toolbar-trailing',
				}),
				toolbarBelow: (
					<>
						{props.failureSummary}
						{shouldShowSearchInput ? (
							<BridgeViewerSearchField
								clearButtonTestId="worktree-file-search-clear"
								errorMessage={props.searchError === null ? null : 'Invalid regex'}
								inputTestId="worktree-file-search-input"
								onChange={props.onSearchTextChange}
								onClear={props.onClearSearch}
								onClose={props.onToggleSearch}
								onSearchModeChange={(searchMode) => {
									props.onSearchModeChange(searchMode.kind);
								}}
								regexToggleTestId="worktree-file-regex-toggle"
								searchMode={{ kind: props.searchMode }}
								value={props.searchText}
							/>
						) : null}
					</>
				),
				toolbarFooter: (
					<BridgeViewerSearchStatus
						message={props.searchStatusMessage ?? props.searchError}
						testId="worktree-file-filter-status"
					/>
				),
			})}
		</>
	);
}
