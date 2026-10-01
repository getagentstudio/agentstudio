import {
	lazy,
	Suspense,
	useCallback,
	useEffect,
	useMemo,
	useRef,
	useState,
	type ComponentType,
	type ReactElement,
} from 'react';

import { BridgeViewerViewSettingsMenu } from '../app/bridge-viewer-view-settings-menu.js';
import type { BridgeFilesViewSettings } from '../app/bridge-viewer-view-settings.js';
import { resolveBridgeFileMarkdownIntent } from '../app/markdown/bridge-file-markdown-intent.js';
import { useBridgeMarkdownPresentation } from '../app/markdown/use-bridge-markdown-presentation.js';
import { useBridgeMarkdownSelectionRetirement } from '../app/markdown/use-bridge-markdown-selection-retirement.js';
import { useBridgeViewerToolbarShortcuts } from '../app/use-bridge-viewer-toolbar-shortcuts.js';
import { bridgeWorkerFileQueryKey } from '../core/comm-worker/bridge-worker-file-query-contracts.js';
import { recordBridgeFileSelectionCommitTelemetrySample } from '../foundation/telemetry/bridge-viewer-activation-telemetry.js';
import { recordBridgeViewerFileOpenReadyTelemetrySample } from '../foundation/telemetry/bridge-viewer-telemetry-adapter.js';
import { useWorktreeAnnotationNavigationTarget } from '../worktree-annotations/use-worktree-annotation-navigation-target.js';
import { useWorktreeAnnotationNavigation } from '../worktree-annotations/worktree-annotation-navigation.js';
import { WorktreeAnnotationShareHeaderControl } from '../worktree-annotations/worktree-annotation-output-controls.js';
import type { BridgeFileViewerAppProps } from './bridge-file-viewer-app-props.js';
import {
	bridgeFileViewerCodeViewOptions,
	createBridgeFilesViewSettingsDefaults,
	deriveBridgeFilesCodeViewOptions,
} from './bridge-file-viewer-code-view-options.js';
import { bridgeFileViewerContentHeaderTitle } from './bridge-file-viewer-content-header-title.js';
import {
	bridgeFileViewerDisplayModelForSnapshot,
	bridgeFileViewerOpenStateForSelection,
	type BridgeFileViewerSelection,
} from './bridge-file-viewer-display-model.js';
import { BridgeFileViewerLazyLoadingFrame } from './bridge-file-viewer-lazy-loading-frame.js';
import { useBridgeFileViewerRenderSnapshotController } from './bridge-file-viewer-render-snapshot-controller.js';
import type { BridgeFileViewerShellProps } from './bridge-file-viewer-shell.js';
import { useBridgeFileViewerControlEventListeners } from './use-bridge-file-viewer-control-event-listeners.js';
import { useBridgeFileViewerDisplaySourceReporter } from './use-bridge-file-viewer-display-source-reporter.js';
import { useBridgeFileViewerStoreBindings } from './use-bridge-file-viewer-store-bindings.js';
import { useBridgeFileViewerVisibleDemandController } from './use-bridge-file-viewer-visible-demand-controller.js';

export type { BridgeFileViewerOpenState } from './bridge-file-viewer-display-model.js';
export type {
	BridgeFileViewerAppProps,
	BridgeFileViewerOpenPathCommand,
} from './bridge-file-viewer-app-props.js';

const LazyBridgeFileViewerShell = lazy(async () => {
	const module = await import('./bridge-file-viewer-shell.js');
	return { default: module.BridgeFileViewerShell };
});

const bridgeFileViewerDisplayLineHeightPixels = 20;
const bridgeFileViewerTreeRowHeightPixels = 24;
const bridgeFilesDefaultViewSettings = createBridgeFilesViewSettingsDefaults(
	bridgeFileViewerCodeViewOptions,
);
const bridgeFileViewerNavigationCommandIsAlwaysEligible = (): boolean => true;

export function BridgeFileViewerApp(props: BridgeFileViewerAppProps = {}): ReactElement {
	return (
		<BridgeFileViewerAppImplementation {...props} shellComponent={LazyBridgeFileViewerShell} />
	);
}

export interface BridgeFileViewerAppImplementationProps extends BridgeFileViewerAppProps {
	readonly shellComponent: ComponentType<BridgeFileViewerShellProps>;
}

export function BridgeFileViewerAppImplementation(
	props: BridgeFileViewerAppImplementationProps,
): ReactElement {
	const {
		activationCause = null,
		activationSequence = null,
		activationStartedAtPerfNow = null,
		autoOpenInitialFile = false,
		codeViewWorkerFactory,
		codeViewWorkerPoolEnabled,
		controlTarget = document,
		isActive = true,
		markdownWorkerClient = null,
		mermaidRenderer,
		isNavigationCommandStillEligible = bridgeFileViewerNavigationCommandIsAlwaysEligible,
		navigationCommand,
		openPathCommand,
		onDisplaySourceChange,
		telemetryRecorder,
		telemetryTraceContext,
		viewerContextSwitcher,
		shellComponent: FileViewerShell,
	} = props;
	const [selection, setSelection] = useState<BridgeFileViewerSelection | null>(null);
	const annotationNavigation = useWorktreeAnnotationNavigation();
	const annotationTarget = useWorktreeAnnotationNavigationTarget('file', isActive);
	const appliedAnnotationRequestRef = useRef<number | null>(null);
	const [isFilterMenuOpen, setIsFilterMenuOpen] = useState(false);
	const [searchRejectionMessage, setSearchRejectionMessage] = useState<string | null>(null);
	const [viewSettings, setViewSettings] = useState<BridgeFilesViewSettings>(
		bridgeFilesDefaultViewSettings,
	);
	const [viewSettingsMenuOpen, setViewSettingsMenuOpen] = useState(false);
	const projectionExclusionClearedSelectionRef = useRef(false);
	const appliedOpenPathCommandIdRef = useRef<number | null>(null);
	const recordedFileOpenReadyActivationSequenceRef = useRef<number | null>(null);
	const recordedSelectionCommitActivationSequenceRef = useRef<number | null>(null);
	const selectionQueryKeyRef = useRef('');
	useEffect((): void => {
		if (!isActive) {
			setIsFilterMenuOpen(false);
			setViewSettingsMenuOpen(false);
		}
	}, [isActive]);
	const codeViewOptions = useMemo(
		() =>
			deriveBridgeFilesCodeViewOptions({
				compatibilityOptions: bridgeFileViewerCodeViewOptions,
				viewSettings,
			}),
		[viewSettings],
	);
	const isActiveRef = useRef(isActive);
	isActiveRef.current = isActive;
	const appliedNavigationApplicationKeyRef = useRef<string | null>(null);
	const controlProbeSequenceRef = useRef(0);
	const { rootSnapshot, viewerActions, viewerStore } = useBridgeFileViewerStoreBindings();
	const { filterMode, search } = rootSnapshot;
	const { acceptedCriteria, enteredCriteria } = search;
	const searchMode = acceptedCriteria.mode;
	const searchText = acceptedCriteria.query;
	const queryKey = bridgeWorkerFileQueryKey({ filterMode, searchMode, searchText });
	const renderSnapshotController = useBridgeFileViewerRenderSnapshotController({ selection });
	const contentHeaderControls = (
		<>
			<WorktreeAnnotationShareHeaderControl />
			{isActive ? (
				<BridgeViewerViewSettingsMenu
					defaultSettings={bridgeFilesDefaultViewSettings}
					onChange={setViewSettings}
					onOpenChange={setViewSettingsMenuOpen}
					open={viewSettingsMenuOpen}
					settings={viewSettings}
					surface="file"
				/>
			) : null}
		</>
	);
	const dispatchFileViewQueryFact = renderSnapshotController.dispatchFileViewQueryFact;
	useEffect((): void => {
		dispatchFileViewQueryFact({ filterMode, searchMode, searchText });
	}, [dispatchFileViewQueryFact, filterMode, searchMode, searchText]);
	const displayModel = useMemo(
		() => bridgeFileViewerDisplayModelForSnapshot(renderSnapshotController.fileDisplaySnapshot),
		[renderSnapshotController.fileDisplaySnapshot],
	);
	const toggleSearch = useCallback((): void => {
		setSearchRejectionMessage(null);
		viewerActions.transitionSearch({ type: search.isOpen ? 'close' : 'open' });
	}, [search.isOpen, viewerActions]);
	const changeSearchText = useCallback(
		(query: string): void => {
			const transition = viewerActions.transitionSearch({ type: 'change_query', query });
			setSearchRejectionMessage(
				transition.rejectionReason === 'search_query_too_long' ? 'Search query is too long' : null,
			);
		},
		[viewerActions],
	);
	const toggleFilters = useCallback(
		(): void => setIsFilterMenuOpen((isOpen): boolean => !isOpen),
		[],
	);
	useBridgeViewerToolbarShortcuts({
		isActive,
		onToggleFilters: toggleFilters,
		onToggleSearch: toggleSearch,
		target: controlTarget,
	});
	useBridgeFileViewerDisplaySourceReporter({
		...(onDisplaySourceChange === undefined ? {} : { onDisplaySourceChange }),
		source: displayModel.source,
	});
	const selectedDisplayItem =
		selection === null ? null : (displayModel.fileItemById.get(selection.fileId) ?? null);
	const openFileState = bridgeFileViewerOpenStateForSelection({
		contentAvailability: renderSnapshotController.selectedContentAvailability,
		displayItem: selectedDisplayItem,
		hasPierreItem: renderSnapshotController.selectedCodeViewItem !== null,
		selection,
		status: displayModel.status,
	});
	const selectedPath = selection?.path ?? null;
	const markdownDecision = useMemo(
		() =>
			resolveBridgeFileMarkdownIntent({
				displaySource: displayModel.source,
				openFileStatus: openFileState.status,
				selectedCodeViewItem: renderSnapshotController.selectedCodeViewItem,
				selectedPath,
			}),
		[
			displayModel.source,
			openFileState.status,
			renderSnapshotController.selectedCodeViewItem,
			selectedPath,
		],
	);
	const markdownPresentation = useBridgeMarkdownPresentation({
		abortKey: 'bridge-markdown-file',
		isActive,
		intent: markdownDecision.kind === 'render' ? markdownDecision.intent : null,
		selectedPath,
		workerClient: markdownWorkerClient,
	});
	const displayedMarkdownItemId =
		markdownDecision.kind === 'pierre' ? null : (selection?.fileId ?? null);
	useBridgeMarkdownSelectionRetirement({
		coordinator: renderSnapshotController.renderFulfillmentCoordinator,
		displayedItemId: displayedMarkdownItemId,
	});
	const selectFile = useCallback(
		(
			nextSelection: BridgeFileViewerSelection,
			source: 'programmatic' | 'user',
			annotationRequestId?: number,
		): void => {
			if (!isActiveRef.current) {
				return;
			}
			if (
				annotationNavigation?.request != null &&
				annotationNavigation.request.requestId !== annotationRequestId
			)
				annotationNavigation.finish(annotationNavigation.request.requestId);
			projectionExclusionClearedSelectionRef.current = false;
			selectionQueryKeyRef.current = queryKey;
			setSelection(nextSelection);
			renderSnapshotController.dispatchSelectedFileViewContentRequest({
				fileId: nextSelection.fileId,
				selectedSource: source,
			});
			if (
				activationCause !== null &&
				activationSequence !== null &&
				displayModel.source !== null &&
				recordedSelectionCommitActivationSequenceRef.current !== activationSequence
			) {
				recordedSelectionCommitActivationSequenceRef.current = activationSequence;
				recordBridgeFileSelectionCommitTelemetrySample({
					activationSequence,
					selectionOrigin: activationCause,
					sourceGeneration: displayModel.source.generation,
					telemetryRecorder,
					traceContext: openPathCommand?.traceContext ?? null,
				});
			}
		},
		[
			annotationNavigation,
			activationCause,
			activationSequence,
			displayModel.source,
			openPathCommand,
			queryKey,
			renderSnapshotController,
			telemetryRecorder,
		],
	);
	useEffect((): void => {
		if (
			!isActive ||
			selection === null ||
			displayModel.acceptedQueryKey !== queryKey ||
			selectionQueryKeyRef.current === queryKey
		)
			return;
		const selectedRow = displayModel.treeRowByPath.get(selection.path);
		if (selectedRow?.fileId === selection.fileId && !selectedRow.isDirectory) {
			selectionQueryKeyRef.current = queryKey;
			return;
		}
		projectionExclusionClearedSelectionRef.current = true;
		selectionQueryKeyRef.current = queryKey;
		setSelection(null);
		renderSnapshotController.clearSelectedFileViewContent();
		const treeFallback = document.querySelector(
			'[data-testid="bridge-file-viewer-pierre-file-tree"]',
		);
		if (treeFallback instanceof HTMLElement) treeFallback.focus({ preventScroll: true });
	}, [
		displayModel.acceptedQueryKey,
		displayModel.treeRowByPath,
		isActive,
		queryKey,
		renderSnapshotController,
		selection,
	]);
	const selectFileFromTree = useCallback(
		(nextSelection: BridgeFileViewerSelection): void => {
			if (annotationNavigation?.request !== null && annotationNavigation?.request !== undefined)
				annotationNavigation.finish(annotationNavigation.request.requestId);
			selectFile(nextSelection, 'user');
		},
		[annotationNavigation, selectFile],
	);
	useEffect((): void => {
		if (
			annotationTarget === null ||
			appliedAnnotationRequestRef.current === annotationTarget.request.requestId
		)
			return;
		const path = annotationTarget.thread.context.path;
		if (path === null) return;
		if (filterMode !== 'all' || search.enteredCriteria.query !== '') {
			viewerActions.setFilterMode('all');
			viewerActions.transitionSearch({ type: 'reset' });
			return;
		}
		if (displayModel.acceptedQueryKey !== queryKey || displayModel.source === null) return;
		const row = displayModel.treeRowByPath.get(path);
		if (row?.fileId == null || row.isDirectory) {
			annotationNavigation?.finish(
				annotationTarget.request.requestId,
				'This file is not available in Files.',
			);
			return;
		}
		appliedAnnotationRequestRef.current = annotationTarget.request.requestId;
		selectFile(
			{ fileId: row.fileId, path: row.path },
			'programmatic',
			annotationTarget.request.requestId,
		);
	}, [
		annotationNavigation,
		annotationTarget,
		displayModel,
		filterMode,
		queryKey,
		search.enteredCriteria.query,
		selectFile,
		viewerActions,
	]);
	useBridgeFileViewerControlEventListeners({
		controlProbeSequenceRef,
		displayModel,
		isActive,
		onSearchResult: (reason): void => {
			setSearchRejectionMessage(
				reason === 'search_query_too_long' ? 'Search query is too long' : null,
			);
		},
		rootSnapshot,
		selectFile,
		selectedFileId: selection?.fileId ?? null,
		target: controlTarget,
		viewerActions,
		viewerStore,
	});

	useEffect((): void => {
		if (!isActive) {
			return;
		}
		if (
			openPathCommand !== undefined &&
			appliedOpenPathCommandIdRef.current !== openPathCommand.commandId
		) {
			const row = displayModel.treeRowByPath.get(openPathCommand.path);
			if (row?.fileId !== null && row?.fileId !== undefined && !row.isDirectory) {
				appliedOpenPathCommandIdRef.current = openPathCommand.commandId;
				selectFile({ fileId: row.fileId, path: row.path }, 'programmatic');
			}
			return;
		}
		const navigationPath = bridgeFileViewerNavigationPath(navigationCommand);
		const navigationApplicationKey = bridgeFileViewerNavigationApplicationKey(navigationCommand);
		if (
			navigationPath !== null &&
			navigationCommand !== undefined &&
			appliedNavigationApplicationKeyRef.current !== navigationApplicationKey
		) {
			const row = displayModel.treeRowByPath.get(navigationPath);
			if (row?.fileId !== null && row?.fileId !== undefined && !row.isDirectory) {
				if (!isNavigationCommandStillEligible(navigationCommand)) return;
				appliedNavigationApplicationKeyRef.current = navigationApplicationKey;
				selectFile({ fileId: row.fileId, path: row.path }, 'programmatic');
			}
			return;
		}
		if (
			annotationNavigation?.request != null ||
			!autoOpenInitialFile ||
			selection !== null ||
			projectionExclusionClearedSelectionRef.current
		) {
			return;
		}
		const firstFileRow = displayModel.firstFileRow;
		if (firstFileRow?.fileId !== null && firstFileRow?.fileId !== undefined) {
			selectFile({ fileId: firstFileRow.fileId, path: firstFileRow.path }, 'programmatic');
		}
	}, [
		annotationNavigation,
		autoOpenInitialFile,
		displayModel.treeRowByPath,
		displayModel.firstFileRow,
		isActive,
		isNavigationCommandStillEligible,
		navigationCommand,
		openPathCommand,
		selectFile,
		selection,
	]);
	useEffect((): (() => void) | void => {
		if (
			!isActive ||
			activationSequence === null ||
			activationStartedAtPerfNow === null ||
			telemetryRecorder === undefined ||
			recordedFileOpenReadyActivationSequenceRef.current === activationSequence ||
			openFileState.status !== 'ready' ||
			renderSnapshotController.selectedCodeViewItem === null
		) {
			return;
		}
		const frameId = requestAnimationFrame((): void => {
			if (recordedFileOpenReadyActivationSequenceRef.current === activationSequence) return;
			recordedFileOpenReadyActivationSequenceRef.current = activationSequence;
			recordBridgeViewerFileOpenReadyTelemetrySample({
				demandQueueWaitMilliseconds: null,
				disposition: 'cold-loaded',
				durationMilliseconds: performance.now() - activationStartedAtPerfNow,
				estimatedBytes: selectedDisplayItem?.payloadByteCount ?? null,
				executorInFlightMilliseconds: null,
				executorPendingWaitMilliseconds: null,
				lane: 'foreground',
				requestId: activationSequence,
				resourceBodyRegistryCommitMilliseconds: null,
				resourceFetchResponseWaitMilliseconds: null,
				resourceFirstChunkWaitMilliseconds: null,
				resourceStreamReadMilliseconds: null,
				result: 'success',
				resultReason: null,
				sourceGeneration: displayModel.source?.generation ?? null,
				telemetryRecorder,
				traceContext: openPathCommand?.traceContext ?? null,
			});
		});
		return (): void => cancelAnimationFrame(frameId);
	}, [
		activationSequence,
		activationStartedAtPerfNow,
		displayModel.source,
		isActive,
		openFileState.status,
		openPathCommand,
		renderSnapshotController.selectedCodeViewItem,
		selectedDisplayItem,
		telemetryRecorder,
	]);

	const dispatchVisibleFileDemand = useBridgeFileViewerVisibleDemandController({
		dispatchVisibleFileViewViewportFact:
			renderSnapshotController.dispatchVisibleFileViewViewportFact,
		isActive,
	});
	const contentHeaderTitle = bridgeFileViewerContentHeaderTitle({
		selectedPath,
		sourceId: displayModel.source?.sourceId ?? '',
	});
	const openFileTotalHeightPixels =
		selectedDisplayItem === null
			? null
			: selectedDisplayItem.payloadLineCount * bridgeFileViewerDisplayLineHeightPixels;
	const totalTreeRowCount = displayModel.totalRowCount;
	const totalTreeHeight = {
		heightPixels: totalTreeRowCount * bridgeFileViewerTreeRowHeightPixels,
		source: 'localProjection' as const,
	};

	return (
		<Suspense
			fallback={
				<BridgeFileViewerLazyLoadingFrame
					isActive={isActive}
					viewerContextSwitcher={viewerContextSwitcher}
					viewerHeaderControls={contentHeaderControls}
				/>
			}
		>
			<FileViewerShell
				paneReloadPort={props.paneReloadPort}
				railVisible={props.railVisible}
				onRetryFileRead={(): void => {
					if (selection !== null)
						renderSnapshotController.dispatchSelectedFileViewContentRequest({
							fileId: selection.fileId,
							selectedSource: 'user',
						});
				}}
				paneFailedStart={props.paneFailedStart ?? null}
				recoveryFailed={
					renderSnapshotController.fileViewRecoveryStatus?.status === 'failedRetryable'
				}
				onRetryFile={renderSnapshotController.retryUnavailableFileRefresh}
				codeViewOptions={codeViewOptions}
				completeFileQueryTransaction={renderSnapshotController.completeFileQueryTransaction}
				contentHeaderTitle={contentHeaderTitle}
				dispatchVisibleFileDemand={dispatchVisibleFileDemand}
				displayModel={displayModel}
				filterMode={filterMode}
				isFilterMenuOpen={isFilterMenuOpen}
				fileTreePatchStream={renderSnapshotController.fileTreePatchStream}
				fileActivationSequence={activationSequence}
				fileActivationStartedAtPerfNow={activationStartedAtPerfNow}
				isActive={isActive}
				isSearchOpen={search.isOpen}
				onFilterMenuOpenChange={setIsFilterMenuOpen}
				onFilterModeChange={viewerActions.setFilterMode}
				onClearSearch={(): void => {
					setSearchRejectionMessage(null);
					viewerActions.transitionSearch({ type: 'clear_or_close' });
				}}
				onSearchModeChange={(mode): void => {
					setSearchRejectionMessage(null);
					viewerActions.transitionSearch({ type: 'change_mode', mode });
				}}
				onSearchTextChange={changeSearchText}
				onSelectFile={selectFileFromTree}
				onToggleSearch={toggleSearch}
				openFileState={openFileState}
				markdownPresentation={
					markdownDecision.kind === 'pierre'
						? null
						: {
								intent: markdownDecision.kind === 'render' ? markdownDecision.intent : null,
								presentationState:
									markdownDecision.kind === 'loading' &&
									!(
										markdownPresentation.presentationState.status === 'ready' &&
										markdownPresentation.presentationState.sourcePath === selectedPath
									)
										? { status: 'loading', sourcePath: selectedPath ?? 'Markdown' }
										: markdownPresentation.presentationState,
								mermaidRenderer,
								retry: markdownPresentation.retry,
							}
				}
				openFileTotalHeightPixels={openFileTotalHeightPixels}
				panelChromeSlice={renderSnapshotController.panelChromeSlice}
				renderFulfillmentCoordinator={renderSnapshotController.renderFulfillmentCoordinator}
				searchError={search.error === null ? null : 'Invalid regex'}
				searchMode={enteredCriteria.mode}
				searchStatusMessage={searchRejectionMessage}
				searchText={enteredCriteria.query}
				selectedCodeViewItem={renderSnapshotController.selectedCodeViewItem}
				selectedPath={selectedPath}
				telemetryRecorder={telemetryRecorder}
				telemetryTraceContext={telemetryTraceContext ?? null}
				totalTreeHeight={totalTreeHeight}
				totalTreeRowCount={totalTreeRowCount}
				viewerContextSwitcher={viewerContextSwitcher}
				viewerHeaderControls={contentHeaderControls}
				{...(codeViewWorkerFactory === undefined ? {} : { codeViewWorkerFactory })}
				{...(codeViewWorkerPoolEnabled === undefined ? {} : { codeViewWorkerPoolEnabled })}
			/>
		</Suspense>
	);
}

function bridgeFileViewerNavigationPath(
	navigationCommand: BridgeFileViewerAppProps['navigationCommand'],
): string | null {
	return navigationCommand?.target.path ?? null;
}

function bridgeFileViewerNavigationApplicationKey(
	navigationCommand: BridgeFileViewerAppProps['navigationCommand'],
): string | null {
	if (navigationCommand === undefined) return null;
	return [
		navigationCommand.commandId,
		navigationCommand.bindingRevision,
		navigationCommand.source.sourceId,
		navigationCommand.source.subscriptionGeneration,
	].join('\u0000');
}
