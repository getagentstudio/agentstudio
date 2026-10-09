import { z } from 'zod';

import type { BridgeProductFileBatchRow } from '../../src/core/comm-worker/bridge-product-file-batch-row-contracts.ts';
import type { BridgeProductFileMemberStatusRecord } from '../../src/core/comm-worker/bridge-product-file-member-status-contracts.ts';
import type { BridgeProductViewInstallation } from '../../src/core/comm-worker/bridge-product-view-batch-receiver.ts';
import type { BridgeWorktreeDevFileContentRouteRequest } from '../bridge-worktree-dev-reload-diagnostics.ts';
import type {
	ReviewCollapseControlProof,
	ReviewContentRouteDeltaProof,
	ReviewContentRoutePressureProof,
	ReviewDemandTelemetryProof,
	ReviewInteractionPerformanceProof,
	ReviewMetadataBeforeContentProof,
	ReviewRenderedSelectionSnapshot,
	WorktreeFileDemandDispatchTelemetryProof,
	WorktreeInteractionPerformanceProof,
} from '../verify-bridge-viewer-worktree-review-proof.ts';

export const bridgeDevTelemetryStatusSampleSchema = z
	.object({
		scope: z.string().min(1),
		name: z.string().min(1),
		durationMilliseconds: z.number().nonnegative().nullable(),
		traceContext: z.unknown().nullable(),
		stringAttributes: z.record(z.string(), z.string()),
		numericAttributes: z.record(z.string(), z.number()),
		booleanAttributes: z.record(z.string(), z.boolean()),
	})
	.strict();

export type BridgeDevTelemetryStatusSample = z.infer<typeof bridgeDevTelemetryStatusSampleSchema>;

export const bridgeDevTelemetryStatusSchema = z
	.object({
		acceptedBatchCount: z.number().int().nonnegative(),
		acceptedSampleCount: z.number().int().nonnegative(),
		failedBatchCount: z.number().int().nonnegative(),
		lastError: z.string().nullable(),
		marker: z.string().min(1),
		recentSamples: z.array(bridgeDevTelemetryStatusSampleSchema).readonly(),
		serviceVersion: z.string().min(1),
		worktreeHash: z.string().min(1),
	})
	.strict();

export const nullableNumberSchema = z.number().nullable();

export const nullableStringSchema = z.string().nullable();

export const nullableNumberRecordSchema = z.record(z.string(), z.number()).nullable();

export const worktreeFileDemandDispatchTelemetryProofSchema = z
	.object({
		expectedVisibleFileCount: nullableNumberSchema,
		failedCount: nullableNumberSchema,
		failedCountByLane: nullableNumberRecordSchema,
		failedCountByReason: nullableNumberRecordSchema,
		firstDedupeKey: nullableStringSchema,
		firstDisposition: nullableStringSchema,
		firstExecutorInFlightMilliseconds: nullableNumberSchema,
		firstExecutorPendingWaitMilliseconds: nullableNumberSchema,
		firstFreshnessKey: nullableStringSchema,
		firstLane: nullableStringSchema,
		firstSchedulerQueueWaitMilliseconds: nullableNumberSchema,
		intentCount: nullableNumberSchema,
		loadedCount: nullableNumberSchema,
		executorInFlightBytesAfter: nullableNumberSchema,
		executorInFlightCountAfter: nullableNumberSchema,
		executorQueuedBytesAfter: nullableNumberSchema,
		executorQueuedLoadCountAfter: nullableNumberSchema,
		schedulerQueuedEstimatedBytesAfter: nullableNumberSchema,
		schedulerQueuedIntentCountAfter: nullableNumberSchema,
		recentlyUpdatedOpenFilePathAfter: nullableStringSchema,
		recentlyUpdatedOpenFilePathBefore: nullableStringSchema,
		status: nullableStringSchema,
		stimulusCount: nullableNumberSchema,
	})
	.strict();

export const worktreeReviewMetadataFrameResponseSchema = z
	.object({
		protocolFrame: z
			.object({
				frameKind: z.enum(['review.metadataSnapshot', 'review.metadataWindow']),
				streamId: z.string().min(1),
				generation: z.number().int().nonnegative(),
				sequence: z.number().int().nonnegative(),
				comparison: z
					.object({
						packageId: z.string().min(1),
						sourceIdentity: z.string().min(1),
						generation: z.number().int().nonnegative(),
						revision: z.number().int().nonnegative(),
						baseEndpoint: z
							.object({
								endpointId: z.string().min(1),
								kind: z.string().min(1),
								label: z.string().min(1),
								providerIdentity: z.string().min(1),
							})
							.passthrough(),
						headEndpoint: z
							.object({
								endpointId: z.string().min(1),
								kind: z.string().min(1),
								label: z.string().min(1),
								providerIdentity: z.string().min(1),
							})
							.passthrough(),
					})
					.passthrough()
					.optional(),
				packageId: z.string().min(1).optional(),
				revision: z.number().int().nonnegative().optional(),
				itemMetadata: z.array(
					z
						.object({
							itemId: z.string().min(1),
							basePath: z.string().min(1).nullable(),
							contentDescriptorIdsByRole: z
								.object({
									base: z.string().min(1).nullable().optional(),
									diff: z.string().min(1).nullable().optional(),
									file: z.string().min(1).nullable().optional(),
									head: z.string().min(1).nullable().optional(),
								})
								.passthrough()
								.optional(),
							headPath: z.string().min(1).nullable(),
						})
						.passthrough(),
				),
				treeRows: z
					.array(
						z
							.object({
								itemId: z.string().min(1),
								path: z.string().min(1),
								isDirectory: z.boolean(),
							})
							.passthrough(),
					)
					.optional(),
				extentFacts: z
					.array(
						z
							.object({
								itemId: z.string().min(1),
								lineCount: z.number().int().nonnegative(),
							})
							.passthrough(),
					)
					.optional(),
			})
			.passthrough(),
		nextWindowCursor: z.string().min(1).nullable().optional(),
	})
	.strict();

export type WorktreeProductFileDescriptor = NonNullable<
	BridgeProductFileBatchRow['descriptorOutcome']
>;

export type WorktreeFileTreeRow = Pick<
	BridgeProductFileBatchRow,
	'changeStatus' | 'depth' | 'fileClass' | 'fileId' | 'lineCount' | 'name' | 'rowId' | 'sizeBytes'
> & {
	readonly isDirectory: boolean;
	readonly parentPath: string | null;
	readonly path: string;
};

export interface WorktreeFileSurface {
	readonly frames: readonly BridgeProductViewInstallation[];
	readonly provenance: {
		readonly baseRef: string;
		readonly scenarioName: string;
		readonly worktreeRootToken: string;
	};
	readonly source: BridgeProductFileMemberStatusRecord['source'];
	readonly treeSizeFacts: {
		readonly estimatedTotalHeightPixels: number;
		readonly pathCount: number;
		readonly rowHeightPixels: number;
	};
}

export type WorktreeFileDescriptor = WorktreeProductFileDescriptor & {
	readonly contentDescriptor: {
		readonly descriptor: {
			readonly content: {
				readonly expectedBytes: number;
				readonly maxBytes: number;
			} | null;
		};
	};
	readonly contentHandle: string;
	readonly contentHash?: string;
	readonly isBinary: boolean;
	readonly lineCount?: number;
};

export type WorktreeFileTreeExtentSource = 'localProjection' | 'providerFacts';

export interface ReviewPerformanceClickTarget {
	readonly displayPath: string;
	readonly lineCount: number | null;
}

export interface InPageReviewTreeClickPerformanceSample {
	readonly appSelectionCommitMilliseconds: number | null;
	readonly codeViewMaterializedMilliseconds: number;
	readonly clickDispatchMilliseconds: number;
	readonly durationMilliseconds: number;
	readonly readyMilliseconds: number;
	readonly selectedMaterializationMilliseconds: number | null;
	readonly selectedMilliseconds: number;
	readonly treeSelectionVisibleMilliseconds: number;
	readonly visibleContentRenderedMilliseconds: number;
}

export interface WorktreeDevServerVerificationResult {
	readonly browserProof: WorktreeDevServerBrowserProof;
	readonly descriptorCount: number;
	readonly frameCount: number;
	readonly firstLoadContentState: string | null;
	readonly firstLoadDisplayPath: string | null;
	readonly firstLoadLineCount: number;
	readonly interactionPerformanceProof: WorktreeInteractionPerformanceProof;
	readonly observedLocationHref: string;
	readonly observedPageUrl: string;
	readonly packageForbiddenTextAbsent: boolean;
	readonly proofArtifactPath: string;
	readonly scenarioName: string;
	readonly scrollExtentCanary: WorktreeFileScrollExtentCanary;
	readonly selectedCharacterCount: number;
	readonly selectedContentSemanticProof: WorktreeFileSelectedContentSemanticProof;
	readonly selectedContentState: string | null;
	readonly selectedDisplayPath: string | null;
	readonly selectedLineCount: number;
	readonly screenshotPaths: WorktreeDevServerScreenshotPaths;
	readonly sourceBaseRef: string;
	readonly sourceCursor: string;
	readonly sourceId: string;
	readonly sourceScenarioName: string;
	readonly worktreeRootToken: string;
	readonly splitResetReplacementProof: WorktreeFileSplitResetReplacementProof;
	readonly staleRefreshProof: WorktreeFileStaleRefreshProof;
	readonly targetPath: string;
	readonly treePathCount: number | null;
	readonly treeTotalSizePixels: number | null;
	readonly treeTotalSizeSource: WorktreeFileTreeExtentSource | null;
	readonly positiveAssertions: readonly string[];
	readonly negativeAssertions: readonly string[];
	readonly productControlsProof: WorktreeFileProductControlsProof;
	readonly fileToReviewHandoffProof: WorktreeFileToReviewHandoffProof;
	readonly fileViewerClickToReadyTelemetry: WorktreeFileOpenLoadTelemetryProof;
	readonly fileViewerRecentlyUpdatedDemandTelemetry: WorktreeFileDemandDispatchTelemetryProof;
	readonly fileViewerVisibleDemandTelemetry: WorktreeFileDemandDispatchTelemetryProof;
	readonly reviewInteractionPerformanceProof: ReviewInteractionPerformanceProof;
	readonly reviewFileTargetRouteProof: WorktreeReviewFileTargetRouteProof;
	readonly reviewRouteProof: WorktreeReviewRouteProof;
	readonly sharedShellProof: WorktreeFileSharedShellProof;
	readonly selectedContentRouteProof: WorktreeFileSelectedContentRouteProof;
	readonly substituteGuardProof: WorktreeFileSubstituteGuardProof;
	readonly visibleAppProof: WorktreeFileVisibleAppProof;
}

export interface WorktreeDevServerPerformanceOnlyResult {
	readonly browserProof: WorktreeDevServerBrowserProof;
	readonly descriptorCount: number;
	readonly interactionPerformanceProof: WorktreeInteractionPerformanceProof;
	readonly reviewInteractionPerformanceProof: ReviewInteractionPerformanceProof;
	readonly observedPageUrl: string;
	readonly scenarioName: string;
}

export interface WorktreeDevServerBrowserProof {
	readonly browserName: string;
	readonly browserVersion: string;
	readonly headless: boolean;
	readonly viewportHeight: number;
	readonly viewportWidth: number;
}

export interface WorktreeDevServerScreenshotPaths {
	readonly ready: string;
	readonly review: string;
	readonly reviewFileTarget: string;
	readonly search: string;
	readonly stale: string;
}

export interface WorktreeFileStaleRefreshProof {
	readonly failedRefreshReturnedStale: boolean;
	readonly foreignContentRouteHitCount: number;
	readonly foreignContentRouteHitUrls: readonly string[];
	readonly initialContentStillVisibleWhileStale: boolean;
	readonly proofPath: string;
	readonly refreshLoadTelemetry: WorktreeFileOpenLoadTelemetryProof;
	readonly refreshFetchHitsAfterAutoRefresh: number;
	readonly refreshFetchHitsAfterStale: number;
	readonly refreshFetchHitsBeforeStale: number;
	readonly refreshEnteredRefreshing: boolean;
	readonly refreshReturnedReady: boolean;
	readonly refreshedContentVisible: boolean;
	readonly staleContentState: string | null;
	readonly staleMessageRect: WorktreeFileVisibleBox;
	readonly staleMessageVisible: boolean;
	readonly staleScreenshotPath: string;
}

export interface WorktreeFileSplitResetReplacementProof {
	readonly devReloadFrameCount: number;
	readonly devReloadFrameGenerations: readonly number[];
	readonly devReloadFrameKinds: readonly string[];
	readonly devReloadFrameSequences: readonly number[];
	readonly devReloadFrameStreamIds: readonly string[];
	readonly devReloadRequest: string | null;
	readonly devReloadSourceCursor: string | null;
	readonly devReloadStatus: string | null;
	readonly foreignContentRouteHitCount: number;
	readonly foreignContentRouteHitUrls: readonly string[];
	readonly initialContentStillVisibleWhileStale: boolean;
	readonly oldContentHandle: string;
	readonly oldContentRouteHitCount: number;
	readonly postRefreshContentRouteHitCount: number;
	readonly postReplacementContentRouteHitCount: number;
	readonly preDispatchContentRouteHitCount: number;
	readonly proofPath: string;
	readonly refreshDisabledAtFirstStale: boolean;
	readonly refreshEnabledAfterReplacement: boolean;
	readonly refreshedContentVisible: boolean;
	readonly replacementContentHandle: string;
	readonly replacementContentHash: string | null;
	readonly replacementContentRouteHitCount: number;
	readonly replacementSourceCursor: string;
	readonly selectedContentStateAfterReset: string | null;
	readonly staleMessageVisible: boolean;
}

export interface WorktreeFileContentRouteProbe {
	readonly dispose: () => Promise<void>;
	readonly foreignHitCount: () => number;
	readonly foreignHitUrls: () => readonly string[];
	readonly hitCount: () => number;
	readonly hits: () => readonly BridgeWorktreeDevFileContentRouteRequest[];
	readonly hitUrls: () => readonly string[];
}

export interface WorktreeDevReloadProof {
	readonly frameCount: number;
	readonly frameGenerations: readonly number[];
	readonly frameKinds: readonly string[];
	readonly frameSequences: readonly number[];
	readonly frameStreamIds: readonly string[];
	readonly request: string | null;
	readonly sourceCursor: string | null;
	readonly status: string | null;
}

export interface WorktreeFileSelectedContentRouteProof {
	readonly expectedContentHandle: string;
	readonly foreignHitCount: number;
	readonly foreignHitUrls: readonly string[];
	readonly hitCount: number;
	readonly hitUrls: readonly string[];
	readonly selectedResourceUrlContainsHandle: boolean;
	readonly selectedResourceUrlUsesDevServerFrontDoor: boolean;
}

export interface WorktreeFileSelectedContentSemanticProof {
	readonly expectedContentHash: string;
	readonly expectedContentHandle: string;
	readonly expectedDisplayPath: string;
	readonly observedDisplayPath: string | null;
	readonly observedLineCount: number;
	readonly renderedTextHash: string;
	readonly renderedTextIncludesExpectedContent: boolean;
}

export interface WorktreeFileControlsStateSnapshot {
	readonly filterMenuText: string | null;
	readonly filterStatusText: string | null;
	readonly regexPressed: string | null;
	readonly searchValue: string | null;
}

export interface WorktreeFileUnavailableOpenProof {
	readonly contentRouteHitCount: number;
	readonly expectedContentHandle: string;
	readonly foreignContentRouteHitCount: number;
	readonly foreignContentRouteHitUrls: readonly string[];
	readonly openedPath: string;
	readonly selectedContentState: string | null;
	readonly selectedLineCount: number;
}

export interface WorktreeFileSearchChromeProof {
	readonly regexToggleFontSize: string;
	readonly regexToggleHeight: number;
	readonly searchInputClassName: string;
	readonly searchInputContainedInRail: boolean;
	readonly searchInputFontSize: string;
	readonly searchInputHeight: number;
	readonly searchInputLeft: number;
	readonly searchInputRight: number;
	readonly searchRailLeft: number;
	readonly searchRailRight: number;
	readonly searchToggleFontSize: string;
	readonly searchToggleHeight: number;
}

export interface WorktreeFileProductControlsProof {
	readonly allFilterVisibleCount: number;
	readonly allRenderedPathSample: readonly string[];
	readonly allTreeSizePixels: number | null;
	readonly allTreeSizeSource: WorktreeFileTreeExtentSource | null;
	readonly expectedFetchableTreeSizePixels: number | null;
	readonly expectedInvalidRegexTreeSizePixels: number;
	readonly expectedRegexTreeSizePixels: number;
	readonly expectedSearchTreeSizePixels: number;
	readonly expectedUnavailableTreeSizePixels: number | null;
	readonly fetchableFilterActive: boolean;
	readonly fetchableFilterVisibleCount: number;
	readonly fetchableRenderedPathSample: readonly string[];
	readonly fetchableTreeSizePixels: number | null;
	readonly fetchableTreeSizeSource: WorktreeFileTreeExtentSource | null;
	readonly expectedFetchableFilterCount: number;
	readonly expectedUnavailableFilterCount: number;
	readonly expectedUnavailablePath: string | null;
	readonly initialVisibleCount: number;
	readonly initialRenderedPathSample: readonly string[];
	readonly initialTreeSizeSource: WorktreeFileTreeExtentSource | null;
	readonly invalidRegexModeActive: boolean;
	readonly invalidRegexRenderedPathSample: readonly string[];
	readonly invalidRegexStatusText: string;
	readonly invalidRegexTreeSizePixels: number | null;
	readonly invalidRegexTreeSizeSource: WorktreeFileTreeExtentSource | null;
	readonly regexModeActive: boolean;
	readonly regexVisibleCount: number;
	readonly regexRenderedPathSample: readonly string[];
	readonly regexTreeSizePixels: number | null;
	readonly regexTreeSizeSource: WorktreeFileTreeExtentSource | null;
	readonly searchScreenshotPath: string;
	readonly searchChromeProof: WorktreeFileSearchChromeProof;
	readonly searchResultIncludesTarget: boolean;
	readonly searchRenderedPathSample: readonly string[];
	readonly searchStatusText: string;
	readonly searchTreeSizePixels: number | null;
	readonly searchTreeSizeSource: WorktreeFileTreeExtentSource | null;
	readonly searchVisibleCount: number;
	readonly targetPath: string;
	readonly totalTreeRowCount: number;
	readonly unavailableFilterActive: boolean;
	readonly unavailableFilterVisibleCount: number;
	readonly unavailableOpenProof: WorktreeFileUnavailableOpenProof | null;
	readonly unavailableRenderedPathSample: readonly string[];
	readonly unavailableTreeSizePixels: number | null;
	readonly unavailableTreeSizeSource: WorktreeFileTreeExtentSource | null;
}

export interface WorktreeFileSharedShellProof {
	readonly appOwner: string | null;
	readonly appRootCount: number;
	readonly appRootOwnsCenterPoint: boolean;
	readonly codeCanvasCount: number;
	readonly codeCanvasOwnsCenterPoint: boolean;
	readonly codeOwner: string | null;
	readonly codeViewOverflow: string | null;
	readonly contentPaneStartsBelowTopbar: boolean;
	readonly contentHeaderAndRailToolbarTopAligned: boolean;
	readonly contentHeaderBackground: string;
	readonly contentHeaderMatchesRailToolbarBackground: boolean;
	readonly contentHeaderHeight: number;
	readonly contentHeaderMatchesRailToolbarHeight: boolean;
	readonly contentTopbarCount: number;
	readonly contentTopbarOwnsCenterPoint: boolean;
	readonly contentTopbarStopsBeforeSidebar: boolean;
	readonly contentTopbarVisible: boolean;
	readonly contextFileButtonHeight: number;
	readonly contextReviewButtonHeight: number;
	readonly contextSegmentMatchesRailButtonHeight: boolean;
	readonly contextSwitcherHeight: number;
	readonly contentTitleText: string;
	readonly contextSwitcherInsideContentTopbar: boolean;
	readonly fileContextButtonSelected: string | null;
	readonly hasPierreTreeShadowRoot: boolean;
	readonly modeHostActive: string | null;
	readonly modeHostCount: number;
	readonly modeHostParentIsSharedRoot: boolean;
	readonly rootVisible: boolean;
	readonly railButtonHeightsMatch: boolean;
	readonly railFilterButtonHeight: number;
	readonly railOpenReviewButtonHeight: number;
	readonly railSearchButtonHeight: number;
	readonly railToolbarBackground: string;
	readonly railToolbarBackgroundIsOpaque: boolean;
	readonly railToolbarHeight: number;
	readonly reviewContextButtonSelected: string | null;
	readonly sharedShellMode: string | null;
	readonly sharedShellOwner: string | null;
	readonly shellCount: number;
	readonly shellOwnsCenterPoint: boolean;
	readonly shellParentIsModeHost: boolean;
	readonly shellOwner: string | null;
	readonly sidebarCount: number;
	readonly sidebarIsRight: boolean;
	readonly sidebarOwnsCenterPoint: boolean;
	readonly sidebarPosition: string | null;
	readonly sidebarStartsAtContentTopbar: boolean;
	readonly shikiRendering: string | null;
	readonly treeOwner: string | null;
	readonly workerRequestedState: string | null;
	readonly workerDiagnosticFileSuccessCount: number;
	readonly workerDiagnosticFileSuccessCountBeforeTargetSelection: number;
	readonly workerDiagnosticLastFileSuccessCacheKey: string | null;
	readonly workerDiagnosticLastSuccessRequestType: string | null;
	readonly workerPoolFileCacheSize: number;
	readonly workerPoolManagerState: string | null;
	readonly workerPoolState: string | null;
	readonly codeViewThemeState: string | null;
}

export interface WorktreeFileSubstituteGuardProof {
	readonly reviewEmptyShellCount: number;
	readonly standaloneWorktreeFileAppCount: number;
}

export interface WorktreeReviewRouteProof {
	readonly appOwner: string | null;
	readonly appRootCount: number;
	readonly appRootVisible: boolean;
	readonly reviewBaseEndpointId: string | null;
	readonly reviewBaseEndpointKind: string | null;
	readonly reviewBaseProviderIdentity: string | null;
	readonly fileContextButtonSelected: string | null;
	readonly fileViewerCodeCanvasCount: number;
	readonly fileViewerShellCount: number;
	readonly fileViewerSidebarCount: number;
	readonly locationHref: string;
	readonly pageUrl: string;
	readonly reviewContentHeaderHeight: number;
	readonly reviewContentHeaderText: string | null;
	readonly reviewCanvasCount: number;
	readonly reviewCodeScrollCount: number;
	readonly reviewContextButtonSelected: string | null;
	readonly reviewCollapseControlProof: ReviewCollapseControlProof;
	readonly reviewContentRouteHitCount: number;
	readonly reviewContentRouteHitUrls: readonly string[];
	readonly reviewRoutePressureProof: ReviewContentRoutePressureProof;
	readonly reviewSelectedDemandTelemetryProof: ReviewDemandTelemetryProof;
	readonly reviewEmptyShellCount: number;
	readonly reviewHeaderMatchesRailToolbarHeight: boolean;
	readonly reviewMetadataRouteHitCount: number;
	readonly reviewMetadataRouteHitUrls: readonly string[];
	readonly reviewMetadataBeforeContentProof: ReviewMetadataBeforeContentProof;
	readonly reviewMetadataBaseEndpointId: string;
	readonly reviewMetadataBaseEndpointKind: string;
	readonly reviewMetadataBaseProviderIdentity: string;
	readonly reviewMetadataHeadEndpointId: string;
	readonly reviewMetadataHeadEndpointKind: string;
	readonly reviewMetadataHeadProviderIdentity: string;
	readonly reviewViewerShellCount: number;
	readonly reviewHeadEndpointId: string | null;
	readonly reviewHeadEndpointKind: string | null;
	readonly reviewHeadProviderIdentity: string | null;
	readonly reviewRailToolbarHeight: number;
	readonly reviewRailToolbarUsesSharedAttr: boolean;
	readonly reviewRenderedSelectionProof: ReviewRenderedSelectionSnapshot;
	readonly reviewSelectionContentRouteHitCount: number;
	readonly reviewSelectionPostClickContentRouteProof: ReviewContentRouteDeltaProof;
	readonly reviewSelectionProof: ReviewTreeSearchClickProof;
	readonly reviewSelectionSelectedContentState: string | null;
	readonly reviewSelectionSelectedDisplayPath: string | null;
	readonly reviewStartupTelemetrySamples: readonly WorktreeBridgeTelemetrySampleProof[];
	readonly reviewSelectedContentState: string | null;
	readonly reviewSelectedDisplayPath: string | null;
	readonly reviewVisibleDemandTelemetryProof: ReviewDemandTelemetryProof;
	readonly screenshotPath: string;
	readonly sharedShellMode: string | null;
	readonly sharedShellOwner: string | null;
	readonly standaloneWorktreeFileAppCount: number;
}

export interface WorktreeBridgeTelemetrySampleProof {
	readonly durationMilliseconds: number | null;
	readonly name: string;
	readonly numericAttributes: Readonly<Record<string, number>>;
	readonly phase: string | null;
	readonly result: string | null;
	readonly slice: string | null;
	readonly transport: string | null;
	readonly viewer: string | null;
	readonly workerCommand?: string | null;
	readonly workerLane?: string | null;
	readonly workerTaskKind?: string | null;
}

export interface ReviewTreeSearchClickProof {
	readonly clickedRowItemPath: string | null;
	readonly clickedRowItemType: string | null;
	readonly clickedRowVisible: boolean;
	readonly searchInputValue: string | null;
	readonly searchOpened: boolean;
	readonly selectedContentStateAfterClick: string | null;
	readonly selectedDisplayPathAfterClick: string | null;
	readonly selectionMethod:
		| 'playwright-review-tree-search-click'
		| 'preselected-review-tree-target';
	readonly targetPath: string;
}

export interface WorktreeReviewFileTargetRouteProof {
	readonly appOwner: string | null;
	readonly expectedDisplayPath: string;
	readonly expectedReviewItemId: string;
	readonly expectedVersion: 'base' | 'current' | 'head';
	readonly locationHref: string;
	readonly pageUrl: string;
	readonly reviewContentHeaderHeight: number;
	readonly reviewContentRouteHitCount: number;
	readonly reviewContentRouteHitUrls: readonly string[];
	readonly reviewHeaderMatchesRailToolbarHeight: boolean;
	readonly reviewMetadataRouteHitCount: number;
	readonly reviewRailToolbarHeight: number;
	readonly reviewRailToolbarUsesSharedAttr: boolean;
	readonly screenshotPath: string;
	readonly selectedCodeViewOverflow: string | null;
	readonly selectedContentRoleCount: number;
	readonly selectedContentState: string | null;
	readonly selectedDisplayPath: string | null;
	readonly selectedItemId: string | null;
	readonly selectedMaterializedFileLineCount: number;
	readonly selectedMaterializedItemType: string | null;
	readonly sharedShellMode: string | null;
	readonly sharedShellOwner: string | null;
	readonly standaloneWorktreeFileAppCount: number;
}

export interface WorktreeFileToReviewHandoffProof {
	readonly appRootCount: number;
	readonly appOwner: string | null;
	readonly beforeLocationHref: string;
	readonly afterLocationHref: string;
	readonly expectedDisplayPath: string;
	readonly expectedReviewItemId: string;
	readonly fileContextButtonSelectedAfterSwitch: string | null;
	readonly fileModeHostHiddenAfterSwitch: boolean;
	readonly fileModeHostHiddenAfterReturnToFile: boolean;
	readonly fileModeHostHiddenAfterReturnToReview: boolean;
	readonly fileModeHostActiveAfterReturnToFile: string | null;
	readonly fileModeHostActiveAfterReturnToReview: string | null;
	readonly fileViewerShellCountAfterSwitch: number;
	readonly fileViewerShellHiddenAfterSwitch: boolean;
	readonly fileViewerOpenLoadTelemetry: WorktreeFileOpenLoadTelemetryProof;
	readonly fileViewerSelectedPathAfterReturnToFile: string | null;
	readonly fileViewerSelectedPathAfterSwitch: string | null;
	readonly reviewHandoffContentRouteProof: ReviewContentRouteDeltaProof;
	readonly reviewContentRouteHitCount: number;
	readonly reviewContentRouteHitUrls: readonly string[];
	readonly reviewContextButtonSelectedAfterSwitch: string | null;
	readonly reviewContextButtonSelectedAfterReturnToReview: string | null;
	readonly reviewModeAfterReturnToFile: string | null;
	readonly reviewModeAfterReturnToReview: string | null;
	readonly reviewMetadataRouteHitCount: number;
	readonly reviewSelectedDisplayPathAfterReturnToReview: string | null;
	readonly selectedContentState: string | null;
	readonly selectedDisplayPath: string | null;
	readonly selectedItemId: string | null;
	readonly selectedMaterializedFileLineCount: number;
	readonly selectedMaterializedItemType: string | null;
	readonly sharedShellMode: string | null;
	readonly sharedShellOwner: string | null;
	readonly standaloneWorktreeFileAppCount: number;
}

export interface WorktreeFileOpenLoadTelemetryProof {
	readonly disposition: string | null;
	readonly durationMilliseconds: number | null;
	readonly estimatedBytes: number | null;
	readonly executorInFlightBytesAfter: number | null;
	readonly executorInFlightBytesBefore: number | null;
	readonly executorInFlightCountAfter: number | null;
	readonly executorInFlightCountBefore: number | null;
	readonly executorInFlightMilliseconds: number | null;
	readonly executorPendingWaitMilliseconds: number | null;
	readonly executorQueuedBytesAfter: number | null;
	readonly executorQueuedBytesBefore: number | null;
	readonly executorQueuedLoadCountAfter: number | null;
	readonly executorQueuedLoadCountBefore: number | null;
	readonly lane: string | null;
	readonly resourceBodyRegistryCommitMilliseconds: number | null;
	readonly resourceFetchResponseWaitMilliseconds: number | null;
	readonly resourceFirstChunkWaitMilliseconds: number | null;
	readonly resourceStreamReadMilliseconds: number | null;
	readonly schedulerQueueWaitMilliseconds: number | null;
	readonly schedulerQueuedEstimatedBytesAfter: number | null;
	readonly schedulerQueuedEstimatedBytesBefore: number | null;
	readonly schedulerQueuedIntentCountAfter: number | null;
	readonly schedulerQueuedIntentCountBefore: number | null;
}

export interface ReviewRouteProbe {
	readonly contentHitCount: () => number;
	readonly contentHitUrls: () => readonly string[];
	readonly dispose: () => Promise<void>;
	readonly metadataHitCount: () => number;
	readonly metadataHitUrls: () => readonly string[];
}

export interface WorktreeFileVisibleAppProof {
	readonly appRootRect: WorktreeFileVisibleRect;
	readonly contentPaneRect: WorktreeFileVisibleRect;
	readonly contentVisibleLineCount: number;
	readonly cssLayoutApplied: boolean;
	readonly filterMenuCount: number;
	readonly filterCountMeaningfullyVisible: boolean;
	readonly filterCountText: string;
	readonly forbiddenTextAbsentOutsideIntentionalUi: boolean;
	readonly regexToggleCount: number;
	readonly sourceProvenanceMeaningfullyVisible: boolean;
	readonly sourceProvenanceText: string;
	readonly sampledTreeRowCount: number;
	readonly sampledTreeRowsHaveDistinctVerticalPositions: boolean;
	readonly searchControlCount: number;
	readonly searchInputCount: number;
	readonly sharedRailToolbarCount: number;
	readonly sharedRailToolbarUsesSharedAttr: boolean;
	readonly sourceBaseRef: string | null;
	readonly sourceCursor: string | null;
	readonly sourceId: string | null;
	readonly sourceScenarioName: string | null;
	readonly sourceState: string | null;
	readonly treePaneRect: WorktreeFileVisibleRect;
	readonly worktreeRootToken: string | null;
}

export interface WorktreeFileVisibleRect {
	readonly height: number;
	readonly width: number;
}

export interface WorktreeFileVisibleBox extends WorktreeFileVisibleRect {
	readonly x: number;
	readonly y: number;
}

export interface WorktreeRenderedContentState {
	readonly selectedCharacterCount: number;
	readonly selectedContentState: string | null;
	readonly selectedDisplayPath: string | null;
	readonly selectedLineCount: number;
	readonly selectedText: string;
	readonly treeTotalSizePixels: number | null;
	readonly treeTotalSizeSource: WorktreeFileTreeExtentSource | null;
}

export interface WorktreeVerifierBrowserHelpers {
	readonly getBridgeFileViewerRenderedCodeLineCount: () => number;
	readonly getBridgeFileViewerRenderedCodeText: () => string;
	readonly getBridgeFileViewerScrollableContent: () => HTMLElement | null;
	readonly getPierreFileTreeItem: (path: string) => HTMLElement | null;
	readonly getPierreFileTreeItems: () => HTMLElement[];
	readonly getPierreFileTreeScrollElement: () => HTMLElement | null;
}

declare global {
	interface Window {
		readonly bridgeWorktreeVerifier: WorktreeVerifierBrowserHelpers;
		readonly bridgeWorktreeReviewMetadataBeforeContentProof: () => ReviewMetadataBeforeContentProof;
		bridgeWorktreeVerifierReviewClickSample?: InPageReviewTreeClickPerformanceSample;
		bridgeWorktreeVerifierTelemetrySamples?: WorktreeBridgeTelemetrySampleProof[];
		bridgeCompleteJourneyHandshakeReadyEpochMilliseconds?: number;
		bridgeWorktreeVerifierLastTreeAnchorSignature?: string;
		bridgeWorktreeVerifierStableTreeAnchorFrames?: number;
	}
}

export interface WorktreeFileScrollExtentCanary {
	readonly contentDeclaredTotalSizePixelsAfterReady: number | null;
	readonly contentDeclaredTotalSizePixelsAfterSelection: number | null;
	readonly contentHeightDeltaPixels: number;
	readonly contentScrollClientHeightAfterReady: number;
	readonly contentScrollClientHeightAfterSelection: number;
	readonly contentScrollHeightAfterReady: number;
	readonly contentScrollHeightAfterSelection: number;
	readonly contentScrollTopAfterReady: number;
	readonly contentScrollTopAfterSelection: number;
	readonly contentScrollTopDeltaPixels: number;
	readonly exactSizeTolerancePass: boolean;
	readonly stableAnchorPass: boolean;
	readonly stableAnchorReadout: WorktreeFileScrollExtentReadout;
	readonly selectedAnchorPath: string;
	readonly treeAnchorReadout: WorktreeFileTreeAnchorReadout;
	readonly treeDeclaredTotalSizePixels: number | null;
	readonly treeDeclaredTotalSizeSource: WorktreeFileTreeExtentSource | null;
	readonly treeHeightDeltaPixels: number;
	readonly treeScrollClientHeightAfterReady: number;
	readonly treeScrollHeightAfterReady: number;
	readonly treeScrollHeightBeforeSelection: number;
	readonly treeScrollTopAfterReady: number;
	readonly treeScrollTopBeforeSelection: number;
}

export interface WorktreeFileTreeAnchorReadout {
	readonly anchorItemId: string;
	readonly anchorOffsetAfterReady: number;
	readonly anchorOffsetBeforeSelection: number;
	readonly measuredItemIdsAfterReady: readonly string[];
	readonly measuredItemIdsBeforeSelection: readonly string[];
	readonly scrollTopAfterReady: number;
	readonly scrollTopBeforeSelection: number;
	readonly visibleRangeAfterReady: {
		readonly endIndex: number;
		readonly startIndex: number;
	};
	readonly visibleRangeBeforeSelection: {
		readonly endIndex: number;
		readonly startIndex: number;
	};
}

export interface WorktreeFileTreeAnchorSnapshot {
	readonly anchorItemId: string;
	readonly anchorOffset: number;
	readonly measuredItemIds: readonly string[];
	readonly scrollTop: number;
	readonly visibleRange: {
		readonly endIndex: number;
		readonly startIndex: number;
	};
}

export interface WorktreeFileScrollExtentReadout {
	readonly anchorItemId: string;
	readonly anchorOffset: number;
	readonly measuredItemIds: readonly string[];
	readonly reconciliationReason: 'exactLineCount';
	readonly scrollHeightAfter: number;
	readonly scrollHeightBefore: number;
	readonly scrollTopAfter: number;
	readonly scrollTopBefore: number;
	readonly scrollTopDeltaPixels: number;
	readonly totalContentHeightAfter: number | null;
	readonly totalContentHeightBefore: number | null;
	readonly virtualizerTotalSizeAfter: number | null;
	readonly virtualizerTotalSizeBefore: number | null;
	readonly visibleRange: {
		readonly endIndex: number;
		readonly startIndex: number;
	};
}

export interface WorktreeFileScrollExtentSnapshot {
	readonly contentDeclaredTotalSizePixels: number | null;
	readonly contentScrollClientHeight: number;
	readonly contentScrollHeight: number;
	readonly contentScrollTop: number;
	readonly treeDeclaredTotalSizePixels: number | null;
	readonly treeDeclaredTotalSizeSource: WorktreeFileTreeExtentSource | null;
	readonly treeScrollClientHeight: number;
	readonly treeScrollHeight: number;
	readonly treeScrollTop: number;
}

export const defaultFileLineHeightPixels = 20;

export const bridgeFileViewerTreeRowHeightPixels = 24;

export const interactionPerformanceSampleCount = 100;

export const interactionPerformanceSampleTimeoutMilliseconds = 2_000;

export const slowInteractionPerformanceSampleMilliseconds = 100;

export const worktreeFileTreeReachableScanCount = 160;

export const maximumNormalPerformanceLineCount = 2_000;

export const splitResetReplacementObservationDelayMilliseconds = 2_000;
