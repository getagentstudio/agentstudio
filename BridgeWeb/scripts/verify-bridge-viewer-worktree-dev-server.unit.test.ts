import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, test } from 'vitest';

import { makeFileBatchInstallation } from '../src/core/comm-worker/comm-runtime-protocol.file-product.test-support.js';
import {
	fileToReviewHandoffFixtureRelativePath,
	repoRootPath,
} from './verify-bridge-viewer-worktree-dev-server/config.ts';
import { registerWorktreeDevServerTelemetryAndSelectionTests } from './verify-bridge-viewer-worktree-dev-server/unit-telemetry-and-selection-tests.ts';
import {
	makePassingInteractionPerformanceProof,
	makePassingReviewInteractionPerformanceProof,
	makePassingReviewMetadataBeforeContentProof,
	makeReviewDemandTelemetryProof,
	makeReviewStartupTelemetrySample,
} from './verify-bridge-viewer-worktree-dev-server/unit-test-fixtures.ts';
import { readWorktreeDevServerVerifierSource } from './verify-bridge-viewer-worktree-dev-server/unit-test-source.ts';
import { worktreeFileTreeRows } from './verify-bridge-viewer-worktree-dev-server/worktree-data.ts';
import {
	buildReviewContentRoutePressureProof,
	reviewMetadataBeforeContentSatisfied,
	reviewRoutePressureSatisfied,
	reviewRouteCollapseControlArtifactSatisfied,
	reviewInteractionPerformanceSatisfied,
	reviewStartupLoadTimingSatisfied,
	reviewSelectedDemandTelemetrySatisfied,
	reviewStartupTelemetrySatisfied,
	reviewVisibleDemandTelemetryAttributed,
	summarizeInteractionSamples,
	worktreeInteractionPerformanceSatisfied,
	worktreeFileOpenLoadTelemetrySatisfied,
	worktreeFileSplitResetReplacementSatisfied,
	worktreeFileScrollExtentCanarySatisfied,
} from './verify-bridge-viewer-worktree-review-proof.ts';

const viteConfigSourceUrl = new URL('../vite.config.ts', import.meta.url);
const reviewRoutesSourceUrl = new URL(
	'./verify-bridge-viewer-worktree-dev-server/review-routes.ts',
	import.meta.url,
);

describe('worktree dev-server verifier Review interaction contract', () => {
	test('resolves canary fixture paths from the repository root', async () => {
		expect(repoRootPath).toBe(fileURLToPath(new URL('../..', import.meta.url)));

		await expect(
			readFile(join(repoRootPath, fileToReviewHandoffFixtureRelativePath), 'utf8'),
		).resolves.toContain('file-to-review handoff canary');
	});

	test('reads Worktree/File rows from a certified keyed batch', () => {
		const installation = makeFileBatchInstallation('open', 'file-subscription-worktree-verifier');
		expect(worktreeFileTreeRows([installation]).map((row) => row.path)).toEqual([
			'src',
			'src/a.ts',
		]);
	});

	test('summarizes interaction latency samples with p95 and p99 gates', () => {
		const summary = summarizeInteractionSamples(
			Array.from({ length: 100 }, (_, index): number => index + 1),
		);

		expect(summary).toEqual({
			failureCount: 0,
			maxMs: 100,
			medianMs: 50.5,
			minMs: 1,
			p95Ms: 95,
			p99Ms: 99,
			sampleCount: 100,
		});
	});

	test('rejects incomplete or over-budget interaction performance proof', () => {
		expect(worktreeInteractionPerformanceSatisfied(makePassingInteractionPerformanceProof())).toBe(
			true,
		);
		expect(
			worktreeInteractionPerformanceSatisfied({
				...makePassingInteractionPerformanceProof(),
				clickToFirstVisibleContentWindow: summarizeInteractionSamples(
					Array.from({ length: 99 }, (): number => 20),
				),
				fileClickSampleCount: 99,
			}),
		).toBe(false);
		expect(
			worktreeInteractionPerformanceSatisfied({
				...makePassingInteractionPerformanceProof(),
				wrongVisibleRowCount: 0,
				blankTreeWindowCount: 1,
			}),
		).toBe(false);
		expect(
			worktreeInteractionPerformanceSatisfied({
				...makePassingInteractionPerformanceProof(),
				clickToFirstVisibleContentWindow: summarizeInteractionSamples(
					Array.from({ length: 100 }, (_, index): number => (index < 98 ? 80 : 200)),
				),
			}),
		).toBe(false);
	});

	test('wires interaction performance proof into the worktree dev-server artifact', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('interactionPerformanceProof');
		expect(verifierSource).toContain('collectWorktreeInteractionPerformanceProof');
		expect(verifierSource).toContain('collectWorktreeFileClickPerformanceSamples');
		expect(verifierSource).toContain('collectWorktreeTreeScrollPerformanceSamples');
		expect(verifierSource).toContain('resetWorktreeFileTreeForPerformanceSamples');
		expect(verifierSource).toContain('worktreeFileTreeReachablePathSet');
		expect(verifierSource).toContain('worktreeFilePathEligibleForPerformanceClick');
		expect(verifierSource).toContain('demanded normal Worktree/File descriptors');
		expect(verifierSource).toContain('worktreeInteractionPerformanceSatisfied');
		expect(verifierSource).toContain('runMarker');
		expect(verifierSource).toContain('commitSha');
		expect(verifierSource).toContain('workerMode');
		expect(verifierSource).toContain('clickPhaseDurations');
		expect(verifierSource).not.toContain('demandQueueWait');
		expect(verifierSource).not.toContain('foregroundContentLoadTiming');
		expect(verifierSource).not.toContain('foregroundExecutorPendingWaitMilliseconds');
		expect(verifierSource).not.toContain('foregroundExecutorInFlightMilliseconds');
		expect(verifierSource).toContain('collectWorktreeStartupLoadTimingProof');
		expect(verifierSource).toContain('startupLoadTiming');
		expect(verifierSource).toContain('pageLoadToContentReady');
		expect(verifierSource).toContain('pageLoadToFirstVisibleContentWindow');
		expect(verifierSource).toContain('treeScrollSettleFrameCount');
		expect(verifierSource).toContain('settleFrameCounts');
		expect(verifierSource).toContain('summarizeClickPhaseDurations');
		expect(verifierSource).not.toContain('makePendingInteractionPerformanceProof');
	});

	test('measures FileView startup timing against the initial descriptor opened by the plain file route', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('path: initialDescriptor.path');
		expect(verifierSource).not.toContain(
			'path: targetDescriptor.path,\n\t\t});\n\t\tconst performanceSurface',
		);
	});

	test('resets FileView performance sampling against streamed metadata rows instead of descriptor sample count', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain(
			'totalMetadataTreeRowCount: worktreeFileTreeRows(performanceSurface.frames).length',
		);
		expect(verifierSource).toContain('readonly totalMetadataTreeRowCount: number;');
		expect(verifierSource).not.toContain(
			'readonly descriptorCount: number;\n\treadonly page: Page;',
		);
		expect(verifierSource).not.toContain(
			'waitForWorktreeFileFilterStatus(props.page, props.descriptorCount, props.descriptorCount)',
		);
	});

	test('does not depend on removed legacy FileView dev polling controls', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).not.toContain('setWorktreeDevPollingEnabled');
		expect(verifierSource).not.toContain('bridge-worktree-dev-pause-polling');
		expect(verifierSource).not.toContain('bridge-worktree-dev-resume-polling');
		expect(verifierSource).not.toContain('bridgeWorktreeDevPollingState');
	});

	test('requires Review click and tree-scroll performance proof in the official artifact', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(
			reviewInteractionPerformanceSatisfied(makePassingReviewInteractionPerformanceProof()),
		).toBe(true);
		expect(reviewStartupLoadTimingSatisfied(makePassingReviewInteractionPerformanceProof())).toBe(
			true,
		);
		expect(
			reviewInteractionPerformanceSatisfied({
				...makePassingReviewInteractionPerformanceProof(),
				reviewClickSampleCount: 99,
				reviewClickToSelectedReady: summarizeInteractionSamples(
					Array.from({ length: 99 }, (): number => 30),
				),
			}),
		).toBe(false);
		expect(
			reviewInteractionPerformanceSatisfied({
				...makePassingReviewInteractionPerformanceProof(),
				reviewTreeBlankWindowCount: 1,
			}),
		).toBe(false);
		expect(
			reviewInteractionPerformanceSatisfied({
				...makePassingReviewInteractionPerformanceProof(),
				reviewStartupLoadTiming: {
					...makePassingReviewInteractionPerformanceProof().reviewStartupLoadTiming,
					pageLoadToMetadata: summarizeInteractionSamples([]),
				},
			}),
		).toBe(false);
		expect(
			reviewInteractionPerformanceSatisfied({
				...makePassingReviewInteractionPerformanceProof(),
				reviewTreeScrollSettleFrameCount: summarizeInteractionSamples([]),
			}),
		).toBe(false);
		expect(verifierSource).toContain('reviewInteractionPerformanceProof');
		expect(verifierSource).toContain('collectReviewInteractionPerformanceProof');
		expect(verifierSource).toContain('collectReviewStartupLoadTimingProof');
		expect(verifierSource).toContain('collectReviewTreeClickPerformanceSamples');
		expect(verifierSource).toContain('collectInPageReviewTreeClickPerformanceSample');
		expect(verifierSource).toContain('reviewFirstVisibleContentWindowSatisfied');
		expect(verifierSource).toContain('window.bridgeWorktreeVerifierReviewClickSample');
		expect(verifierSource).toContain('collectReviewTreeScrollPerformanceSamples');
		expect(verifierSource).toContain('collectReviewCodeViewScrollPerformanceSamples');
		expect(verifierSource).not.toMatch(
			/collectReviewInteractionPerformanceProof\(\{[\s\S]*?fetchWorktreeReviewPerformanceClickTargets/u,
		);
		expect(verifierSource).toContain('reviewTreeReachablePathScrollTopMap');
		expect(verifierSource).toContain('data-review-visible-demand-interest');
		expect(verifierSource).toContain('ReviewPerformanceClickTarget');
		expect(verifierSource).toContain('normal Worktree/Review performance click targets');
		expect(verifierSource).toContain('summarizeReviewClickPhaseDurations');
		expect(verifierSource).toContain('reviewClickPhaseDurations');
		expect(verifierSource).toContain('summarizeReviewClickReadinessBreakdown');
		expect(verifierSource).toContain('reviewClickReadinessBreakdown');
		expect(verifierSource).toContain('reviewStartupLoadTiming');
		expect(verifierSource).toContain('pageLoadToMetadata');
		expect(verifierSource).toContain('pageLoadToSelectedContentReady');
		expect(verifierSource).not.toContain('performance.bridge.web.review_metadata_apply');
		expect(verifierSource).not.toContain('performance.bridge.web.selected_content_ready');
		expect(verifierSource).not.toContain('performance.bridge.web.review_ready');
		expect(verifierSource).toContain('reviewTreeScrollSettleFrameCount');
		expect(verifierSource).toContain('codeViewScrollSettleFrameCount');
		expect(verifierSource).toContain('treeSelectionVisibleMilliseconds');
		expect(verifierSource).toContain('codeViewMaterializedMilliseconds');
		expect(verifierSource).toContain('visibleContentRenderedMilliseconds');
		expect(verifierSource).toContain('workerQueueWait');
		expect(verifierSource).toContain('performance.bridge.worker.task');
		expect(verifierSource).toContain("command: 'select'");
		expect(verifierSource).toContain("command: 'viewport'");
		expect(verifierSource).toContain("lane: 'selected'");
		expect(verifierSource).toContain("lane: 'visible'");
		expect(verifierSource).toContain('extentFacts');
		expect(verifierSource).toContain('maximumNormalPerformanceLineCount');
		expect(verifierSource).toContain('reviewInteractionPerformanceSatisfied');
	});

	test('requires Review metadata tree projection before gated content completes', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(
			reviewMetadataBeforeContentSatisfied(makePassingReviewMetadataBeforeContentProof()),
		).toBe(true);
		expect(
			reviewMetadataBeforeContentSatisfied({
				...makePassingReviewMetadataBeforeContentProof(),
				selectedContentStateWhileBlocked: 'ready',
			}),
		).toBe(false);
		expect(
			reviewMetadataBeforeContentSatisfied({
				...makePassingReviewMetadataBeforeContentProof(),
				treeVisibleRowCountWhileBlocked: 0,
			}),
		).toBe(false);
		expect(verifierSource).toContain('startupContentGate');
		expect(verifierSource).toContain('waitForReviewMetadataBeforeContentStartupProof');
		expect(verifierSource).toContain('reviewMetadataBeforeContentProof');
		expect(verifierSource).toContain('reviewMetadataBeforeContentSatisfied');
		expect(verifierSource).toContain('bridgeWorktreeReviewMetadataBeforeContentProof');
	});

	test('fails the full worktree verifier when interaction performance proof is over budget', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain(
			'Expected Worktree/File and Worktree/Review interaction performance proof to satisfy p95/p99 budgets',
		);
	});

	test('refetches current Worktree/File descriptors after reset canaries before performance sampling', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('await reloadWorktreeDevServerPage(page)');
		expect(verifierSource).toContain('performanceSurface = await fetchWorktreeSurface()');
		expect(verifierSource).toContain('performanceDescriptors =');
		expect(verifierSource).toContain('fetchPerformanceWorktreeFileDescriptors(');
		expect(verifierSource).toContain('descriptors: performanceDescriptors');
	});

	test('uses a stable Worktree/File first-load canary instead of the alphabetically first repo file', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('initialContentFixtureRelativePath');
		expect(verifierSource).toContain('fetchFetchableWorktreeFileDescriptorForPath({');
		expect(verifierSource).toContain('path: initialContentFixtureRelativePath');
		expect(verifierSource).toContain(
			'await clickWorktreeFilePathViaSearch({ page, path: initialDescriptor.path })',
		);
		expect(verifierSource).toContain("await fillWorktreeFileSearch(page, '')");
		expect(verifierSource).not.toContain('fetchFirstFetchableWorktreeFileDescriptor(surface)');
	});

	test('scopes File-to-Review handoff ready waits to the FileViewer code canvas', async () => {
		const handoffSource = await readFile(
			new URL('./verify-bridge-viewer-worktree-dev-server/file-review-handoff.ts', import.meta.url),
			'utf8',
		);

		expect(handoffSource).toContain('waitForWorktreeOpenFileState');
		expect(handoffSource).toContain('waitForWorktreeFileViewerSurfaceReady');
		expect(handoffSource).toContain('waitForWorktreeOpenFileReadyOrStale');
		expect(handoffSource).toContain("state === 'stale'");
		expect(handoffSource).toContain('worktree-file-refresh');
		expect(handoffSource).toContain("state: 'ready'");
		expect(handoffSource).toContain('path: expectedDisplayPath');
		expect(handoffSource).not.toContain(
			"document\\n\\t\\t\\t\\t\\t.querySelector('[data-worktree-open-file-state]')",
		);
	});

	test('uses Playwright row clicks for filtered Worktree/File selections', async () => {
		const handoffSource = await readFile(
			new URL('./verify-bridge-viewer-worktree-dev-server/file-review-handoff.ts', import.meta.url),
			'utf8',
		);

		expect(handoffSource).toContain('await clickWorktreeFilePath(props.page, props.path)');
		expect(handoffSource).toContain('data-selected-display-path');
		expect(handoffSource).not.toContain('treeItem.click();');
	});

	test('selects the stable Review route canary without waiting on default selection order', async () => {
		const reviewRoutesSource = await readFile(reviewRoutesSourceUrl, 'utf8');

		expect(reviewRoutesSource).toContain('clickReviewTreeFilePathViaSearch');
		expect(reviewRoutesSource).toContain('reviewSelectionFixtureRelativePath');
		expect(reviewRoutesSource).not.toContain(
			"await waitForAnyReviewSelectedContentState({ page, state: 'ready' });",
		);
	});

	test('demands Worktree/File descriptors through the typed product session', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('BridgeVerifierProductFileSession');
		expect(verifierSource).toContain('session.demandDescriptor(props.path)');
		expect(verifierSource).toContain('installBridgeProductFileBatch(latestInstallation)');
		expect(verifierSource).toContain('worktreeFileDemandCandidatePaths(surface)');
		expect(verifierSource).not.toContain('function worktreeFileDescriptors(');
		expect(verifierSource).not.toContain('firstFetchableDescriptor(');
		expect(verifierSource).not.toContain('deepFetchableDescriptor(');
	});

	test('derives Review file-target ids directly from streamed metadata', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('worktreeReviewMetadataFrameResponseSchema');
		expect(verifierSource).toContain("new URL('/__bridge-worktree/review-metadata'");
		expect(verifierSource).toContain(
			"frameUrl.searchParams.set('frame', 'review-metadata-snapshot')",
		);
		expect(verifierSource).toContain('metadataFrameResponse.protocolFrame.itemMetadata.find');
		expect(verifierSource).not.toContain('worktreeReviewPackageDescriptorResourceFetchUrl');
		expect(verifierSource).not.toContain("packageUrl.searchParams.set('resource'");
		expect(verifierSource).not.toContain("packageUrl.searchParams.set('opaqueId'");
		expect(verifierSource).not.toContain('worktreeReviewPackageRouteResponseSchema');
		expect(verifierSource).not.toContain('reviewPackage: bridgeReviewPackageSchema');
	});

	test('ignores hidden keep-alive FileViewer DOM when proving the Review route', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('activeVisibleFileViewerSubstituteCount');
		expect(verifierSource).toContain('[data-testid="bridge-viewer-mode-host-file"]');
		expect(verifierSource).toContain("fileModeHost.getAttribute('data-bridge-viewer-mode-active')");
		expect(verifierSource).toContain("'bridge-file-viewer-shell'");
		expect(verifierSource).toContain("'bridge-file-viewer-sidebar'");
		expect(verifierSource).toContain("'bridge-file-viewer-code-canvas'");
		expect(verifierSource).not.toContain(
			'document.querySelectorAll(\'[data-testid="bridge-file-viewer-shell"]\').length',
		);
	});

	test('counts FileViewer content topbars inside the active file mode host', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain(
			'modeHost.querySelectorAll(\'[data-testid="bridge-viewer-content-topbar"]\')',
		);
		expect(verifierSource).not.toContain(
			'...document.querySelectorAll(\'[data-testid="bridge-viewer-content-topbar"]\')',
		);
	});

	test('proves the Worktree/File search control with the FileViewer selector', async () => {
		const contentStateSource = await readFile(
			new URL('./verify-bridge-viewer-worktree-dev-server/content-state.ts', import.meta.url),
			'utf8',
		);

		expect(contentStateSource).toContain('[data-testid="worktree-file-search-control"]');
		expect(contentStateSource).not.toContain('[data-testid="bridge-review-search-control"]');
	});

	test('selects Worktree/File filter options with FileViewer menu selectors', async () => {
		const fileSearchFilterSource = await readFile(
			new URL('./verify-bridge-viewer-worktree-dev-server/file-search-filter.ts', import.meta.url),
			'utf8',
		);

		expect(fileSearchFilterSource).toContain(
			'[data-testid="worktree-file-filter-menu-option-label"]',
		);
		expect(fileSearchFilterSource).toContain('[data-testid="worktree-file-filter-menu-option"]');
		expect(fileSearchFilterSource).not.toContain('[data-testid="bridge-review-filter-option"]');
	});

	test('routes Vite product traffic through the Swift backend proxy', async () => {
		const viteConfigSource = await readFile(viteConfigSourceUrl, 'utf8');

		expect(viteConfigSource).toContain('bridgeProductDevProxyConfiguration');
		expect(viteConfigSource).toContain('BRIDGE_PRODUCT_HTTP_COMMAND_ENDPOINT');
		expect(viteConfigSource).toContain('BRIDGE_PRODUCT_HTTP_STREAM_ENDPOINT');
		expect(viteConfigSource).not.toContain('createBridgeProductDevCarrier');
		expect(viteConfigSource).not.toContain('/__bridge-worktree/review-metadata');
		expect(viteConfigSource).not.toContain('/__bridge-worktree/review-package');
		expect(viteConfigSource).not.toContain('reviewPackage: packageResult.reviewPackage');
	});

	test('uses visible Pierre tree search interaction for Review selection proof', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).not.toContain('__bridge_select_review_item');
		expect(verifierSource).not.toContain('document.dispatchEvent');
		expect(verifierSource).toContain('clickReviewTreeFilePathViaSearch');
		expect(verifierSource).toContain('[data-testid="bridge-review-trees-panel"]');
		expect(verifierSource).toContain('[data-file-tree-search-input]');
		expect(verifierSource).toContain('await waitForReviewTreeScrollSettled(props.page)');
		expect(verifierSource).toContain('[data-file-tree-virtualized-root="true"]');
		expect(verifierSource).toContain('[data-file-tree-virtualized-list="true"]');
		expect(verifierSource).toContain(
			'await targetRowLocator.click({ force: attempt > 0, timeout: 2_000 })',
		);
		expect(verifierSource).not.toContain('const buttonHandle = await props.page.evaluateHandle');
		expect(verifierSource).toContain(':not([data-file-tree-sticky-row]):not([data-item-parked])');
		expect(verifierSource).not.toContain(':not([data-file-tree-sticky-row="true"])');
		expect(verifierSource).not.toContain(':not([data-item-parked="true"])');
	});

	test('waits for FileViewer surface readiness after reload before stale-refresh proof', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();
		const readinessFunctionSource = verifierSource.match(
			/export async function waitForWorktreeFileViewerSurfaceReady[\s\S]+?(?=export async function readBridgePierreWorkerFileSuccessCount)/u,
		)?.[0];

		expect(readinessFunctionSource).toBeDefined();
		expect(readinessFunctionSource).toContain("data-file-display-status') === 'ready'");
		expect(readinessFunctionSource).not.toContain("data-worktree-source-state') === 'live'");
		expect(readinessFunctionSource).toContain('totalCount > 0');
		expect(readinessFunctionSource).toContain('visibleCount > 0');
		expect(readinessFunctionSource).toContain('[data-testid="worktree-file-filter-count"]');
	});

	test('publishes visible CodeView collapse-control primitive proof in Review route artifacts', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('reviewCollapseControlProof');
		expect(verifierSource).toContain('readReviewCollapseControlProof');
		expect(verifierSource).toContain('reviewRouteCollapseControlArtifactSatisfied');
		expect(
			reviewRouteCollapseControlArtifactSatisfied({
				expectedItemId: 'worktree-review-gitignore',
				routeProof: {
					reviewCollapseControlProof: {
						ariaExpanded: 'true',
						fontSize: '13px',
						height: 24,
						itemId: 'worktree-review-gitignore',
						present: true,
						primitiveSlot: 'button',
					},
				},
			}),
		).toBe(true);
		expect(
			reviewRouteCollapseControlArtifactSatisfied({
				expectedItemId: 'worktree-review-gitignore',
				routeProof: {},
			}),
		).toBe(false);
	});

	test('requires Review startup telemetry samples in route artifacts', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('reviewStartupTelemetrySamples');
		expect(verifierSource).toContain('reviewStartupTelemetrySatisfied');
		expect(reviewStartupTelemetrySatisfied([])).toBe(false);
		expect(
			reviewStartupTelemetrySatisfied([
				makeReviewStartupTelemetrySample('performance.bridge.viewer.time_to_first_interaction'),
				makeReviewStartupTelemetrySample('performance.bridge.web.selected_content_painted'),
			]),
		).toBe(true);
		expect(
			reviewStartupTelemetrySatisfied([
				makeReviewStartupTelemetrySample('performance.bridge.viewer.time_to_first_interaction'),
			]),
		).toBe(false);
	});

	test('publishes selected Review demand pressure telemetry in route artifacts', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('reviewSelectedDemandTelemetryProof');
		expect(verifierSource).toContain('configured-executor-max-concurrent-loads');
		expect(verifierSource).toContain('admitted-bytes-by-lane');
		expect(verifierSource).toContain('dropped-estimated-bytes-by-lane');
		expect(verifierSource).toContain('lane-upgrade-count');
		expect(verifierSource).toContain('stale-drop-count');
		expect(verifierSource).toContain('max-executor-in-flight');
		expect(verifierSource).toContain('reviewSelectedDemandTelemetrySatisfied');
		expect(
			reviewSelectedDemandTelemetrySatisfied({
				admittedBytes: 40,
				admittedBytesByLane: { foreground: 40 },
				byteBudgetSource: 'review-content-demand',
				configuredExecutorMaxConcurrentLoads: 4,
				configuredExecutorMaxInFlightBytes: 1_000,
				configuredSchedulerMaxQueuedEstimatedBytes: 1_000,
				configuredSchedulerMaxQueuedIntentsPerLane: 8,
				deferredCount: 0,
				deferredEstimatedBytesByLane: { foreground: 0 },
				droppedEstimatedBytesByLane: { foreground: 0 },
				droppedIntentCount: 0,
				durationMilliseconds: 5,
				enqueueAcceptedCount: 2,
				enqueueRejectedCount: 0,
				executorInFlightCountAfterDispatch: 2,
				executorInFlightCountAfter: 0,
				executorInFlightCountBefore: 0,
				executorQueuedLoadCountAfter: 0,
				failedCount: 0,
				foregroundIntentCount: 2,
				interest: 'selected',
				itemId: 'worktree-review-target',
				packageId: 'package-1',
				packageReviewGeneration: 1,
				packageRevision: 1,
				currentPackageId: 'package-1',
				currentPackageReviewGeneration: 1,
				currentPackageRevision: 1,
				laneUpgradeCount: 0,
				loadedCount: 2,
				maxExecutorInFlightCount: 2,
				maxExecutorQueuedLoadCount: 0,
				maxSchedulerQueuedIntentCount: 2,
				schedulerQueuedIntentCountAfterEnqueue: 2,
				schedulerQueuedIntentCountAfter: 0,
				schedulerQueuedIntentCountBefore: 0,
				staleDropCount: 0,
				visibleIntentCount: 0,
			}),
		).toBe(true);
		expect(
			reviewSelectedDemandTelemetrySatisfied({
				admittedBytes: 247,
				admittedBytesByLane: { foreground: 247 },
				byteBudgetSource: 'review-content-demand',
				configuredExecutorMaxConcurrentLoads: 8,
				configuredExecutorMaxInFlightBytes: 8_388_608,
				configuredSchedulerMaxQueuedEstimatedBytes: 8_388_608,
				configuredSchedulerMaxQueuedIntentsPerLane: 128,
				deferredCount: 0,
				deferredEstimatedBytesByLane: { foreground: 0 },
				droppedEstimatedBytesByLane: { foreground: 0 },
				droppedIntentCount: 0,
				durationMilliseconds: 4,
				enqueueAcceptedCount: 1,
				enqueueRejectedCount: 0,
				executorInFlightCountAfterDispatch: 1,
				executorInFlightCountAfter: 2,
				executorInFlightCountBefore: 0,
				executorQueuedLoadCountAfter: 0,
				failedCount: 0,
				foregroundIntentCount: 1,
				interest: 'selected',
				itemId: 'worktree-review-target',
				packageId: 'package-1',
				packageReviewGeneration: 1,
				packageRevision: 1,
				currentPackageId: 'package-1',
				currentPackageReviewGeneration: 1,
				currentPackageRevision: 1,
				laneUpgradeCount: 0,
				loadedCount: 1,
				maxExecutorInFlightCount: 2,
				maxExecutorQueuedLoadCount: 0,
				maxSchedulerQueuedIntentCount: 1,
				schedulerQueuedIntentCountAfterEnqueue: 1,
				schedulerQueuedIntentCountAfter: 0,
				schedulerQueuedIntentCountBefore: 0,
				staleDropCount: 0,
				visibleIntentCount: 0,
			}),
		).toBe(true);
		expect(
			reviewSelectedDemandTelemetrySatisfied({
				admittedBytes: 40,
				admittedBytesByLane: { foreground: 40 },
				byteBudgetSource: 'review-content-demand',
				configuredExecutorMaxConcurrentLoads: 4,
				configuredExecutorMaxInFlightBytes: 1_000,
				configuredSchedulerMaxQueuedEstimatedBytes: 1_000,
				configuredSchedulerMaxQueuedIntentsPerLane: 8,
				deferredCount: 0,
				deferredEstimatedBytesByLane: { foreground: 0 },
				droppedEstimatedBytesByLane: { foreground: 0 },
				droppedIntentCount: 0,
				durationMilliseconds: 5,
				enqueueAcceptedCount: 2,
				enqueueRejectedCount: 0,
				executorInFlightCountAfterDispatch: 2,
				executorInFlightCountAfter: 0,
				executorInFlightCountBefore: 0,
				executorQueuedLoadCountAfter: 0,
				failedCount: 0,
				foregroundIntentCount: 2,
				interest: 'visible',
				itemId: 'worktree-review-target',
				packageId: 'package-1',
				packageReviewGeneration: 1,
				packageRevision: 1,
				currentPackageId: 'package-1',
				currentPackageReviewGeneration: 1,
				currentPackageRevision: 1,
				laneUpgradeCount: 0,
				loadedCount: 2,
				maxExecutorInFlightCount: 2,
				maxExecutorQueuedLoadCount: 0,
				maxSchedulerQueuedIntentCount: 2,
				schedulerQueuedIntentCountAfterEnqueue: 2,
				schedulerQueuedIntentCountAfter: 0,
				schedulerQueuedIntentCountBefore: 0,
				staleDropCount: 0,
				visibleIntentCount: 0,
			}),
		).toBe(false);
	});

	test('publishes attributed Review route-pressure proof instead of treating visible fanout as failure', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();
		const routePressureProof = buildReviewContentRoutePressureProof([
			'http://127.0.0.1:5173/__bridge-worktree/review-content/worktree-review-target-base',
			'http://127.0.0.1:5173/__bridge-worktree/review-content/worktree-review-target-head',
			'http://127.0.0.1:5173/__bridge-worktree/review-content/worktree-review-visible-base',
		]);
		const selectedTelemetry = makeReviewDemandTelemetryProof({
			admittedBytes: 40,
			admittedBytesByLane: { foreground: 40, visible: 0 },
			foregroundIntentCount: 2,
			interest: 'selected',
			loadedCount: 2,
			maxExecutorInFlightCount: 2,
			maxSchedulerQueuedIntentCount: 2,
			schedulerQueuedIntentCountAfterEnqueue: 2,
			visibleIntentCount: 0,
		});
		const visibleTelemetry = makeReviewDemandTelemetryProof({
			deferredCount: 1,
			deferredEstimatedBytesByLane: { foreground: 0, visible: 12_000 },
			executorInFlightCountAfterDispatch: 2,
			foregroundIntentCount: 0,
			interest: 'visible',
			itemId: 'worktree-review-target',
			maxExecutorInFlightCount: 2,
			schedulerQueuedIntentCountAfterEnqueue: 1,
			visibleIntentCount: 1,
		});

		expect(verifierSource).toContain('reviewRoutePressureProof');
		expect(verifierSource).toContain('buildReviewContentRoutePressureProof');
		expect(verifierSource).toContain('reviewRoutePressureSatisfied');
		expect(routePressureProof).toEqual({
			duplicateRouteCount: 0,
			duplicatedRouteUrls: [],
			routeHitContentDescriptorIds: [
				'worktree-review-target-base',
				'worktree-review-target-head',
				'worktree-review-visible-base',
			],
			routeHitCount: 3,
			routeHitItemIds: ['worktree-review-target', 'worktree-review-visible'],
			uniqueRouteHitCount: 3,
		});
		expect(reviewVisibleDemandTelemetryAttributed(visibleTelemetry)).toBe(true);
		expect(
			reviewVisibleDemandTelemetryAttributed({
				...visibleTelemetry,
				currentPackageId: 'package-2',
			}),
		).toBe(false);
		expect(
			reviewVisibleDemandTelemetryAttributed({
				...visibleTelemetry,
				currentPackageReviewGeneration: 2,
			}),
		).toBe(false);
		expect(
			reviewVisibleDemandTelemetryAttributed(visibleTelemetry, {
				expectedItemId: 'worktree-review-target',
			}),
		).toBe(true);
		expect(
			reviewVisibleDemandTelemetryAttributed(visibleTelemetry, {
				expectedItemId: 'worktree-review-other',
			}),
		).toBe(false);
		expect(
			reviewRoutePressureSatisfied({
				expectedVisibleContentDescriptorIds: ['worktree-review-target-head'],
				expectedVisibleItemId: 'worktree-review-target',
				routePressureProof,
				selectedDemandTelemetryProof: selectedTelemetry,
				visibleDemandTelemetryProof: visibleTelemetry,
			}),
		).toBe(true);
		expect(
			reviewRoutePressureSatisfied({
				expectedVisibleItemId: 'worktree-review-other',
				routePressureProof,
				selectedDemandTelemetryProof: selectedTelemetry,
				visibleDemandTelemetryProof: visibleTelemetry,
			}),
		).toBe(false);
	});

	test('rejects duplicate Review route-pressure hits for the same exact content URL', () => {
		const duplicatedUrl =
			'http://127.0.0.1:5173/__bridge-worktree/review-content/worktree-review-target-head';
		const routePressureProof = buildReviewContentRoutePressureProof([duplicatedUrl, duplicatedUrl]);

		expect(routePressureProof).toEqual({
			duplicateRouteCount: 1,
			duplicatedRouteUrls: [duplicatedUrl],
			routeHitContentDescriptorIds: ['worktree-review-target-head'],
			routeHitCount: 2,
			routeHitItemIds: ['worktree-review-target'],
			uniqueRouteHitCount: 1,
		});
		expect(
			reviewRoutePressureSatisfied({
				routePressureProof,
				selectedDemandTelemetryProof: makeReviewDemandTelemetryProof({
					admittedBytes: 40,
					admittedBytesByLane: { foreground: 40 },
					foregroundIntentCount: 1,
					interest: 'selected',
					loadedCount: 1,
					maxExecutorInFlightCount: 1,
					maxSchedulerQueuedIntentCount: 1,
					schedulerQueuedIntentCountAfterEnqueue: 1,
					visibleIntentCount: 0,
				}),
				visibleDemandTelemetryProof: makeReviewDemandTelemetryProof({
					deferredEstimatedBytesByLane: { visible: 1 },
					foregroundIntentCount: 0,
					interest: 'visible',
					visibleIntentCount: 1,
				}),
			}),
		).toBe(false);
	});

	test('uses post-handoff Review content route delta proof instead of total route hits', async () => {
		const verifierSource = await readWorktreeDevServerVerifierSource();

		expect(verifierSource).toContain('reviewHandoffContentRouteProof');
		expect(verifierSource).toContain('reviewContentHitCountBeforeHandoffClick');
		expect(verifierSource).toContain('reviewContentRouteDeltaSatisfied');
		expect(verifierSource).not.toContain(
			"handoffProof.fileViewerOpenLoadTelemetry.disposition !== 'cold-loaded'",
		);
	});

	test('accepts split-reset replacement proof from durable lineage instead of a transient refreshing frame', () => {
		expect(
			worktreeFileSplitResetReplacementSatisfied({
				devReloadFrameCount: 3,
				devReloadFrameGenerations: [9, 9, 9],
				devReloadFrameKinds: ['worktree.reset', 'worktree.snapshot', 'worktree.fileDescriptor'],
				devReloadFrameSequences: [1, 2, 3],
				devReloadFrameStreamIds: ['stream-1', 'stream-1', 'stream-1'],
				devReloadRequest: 'force-split-reset',
				devReloadSourceCursor: 'cursor-replacement',
				devReloadStatus: 'delivered',
				foreignContentRouteHitCount: 0,
				foreignContentRouteHitUrls: [],
				initialContentStillVisibleWhileStale: true,
				oldContentHandle: 'old-handle',
				oldContentRouteHitCount: 0,
				postRefreshContentRouteHitCount: 1,
				postReplacementContentRouteHitCount: 0,
				preDispatchContentRouteHitCount: 0,
				proofPath: 'BridgeWeb/src/test-fixtures/worktree-split-reset-canary.txt',
				refreshDisabledAtFirstStale: true,
				refreshEnabledAfterReplacement: false,
				refreshedContentVisible: true,
				replacementContentHandle: 'replacement-handle',
				replacementContentHash: 'replacement-hash',
				replacementContentRouteHitCount: 1,
				replacementSourceCursor: 'cursor-replacement',
				selectedContentStateAfterReset: 'stale',
				staleMessageVisible: false,
			}),
		).toBe(true);
	});

	test('accepts file scroll extent proof when cross-file ready content resets to top', () => {
		expect(
			worktreeFileScrollExtentCanarySatisfied({
				contentDeclaredTotalSizePixelsAfterReady: 140_752,
				contentDeclaredTotalSizePixelsAfterSelection: 140_752,
				contentHeightDeltaPixels: 0,
				contentScrollTopAfterReady: 0,
				contentScrollTopAfterSelection: 480,
				exactSizeTolerancePass: true,
				stableAnchorPass: true,
				treeDeclaredTotalSizePixels: 16_584,
				treeDeclaredTotalSizeSource: 'providerFacts',
				treeHeightDeltaPixels: 0,
				treeScrollHeightAfterReady: 16_584,
				treeScrollTopAfterReady: 476,
				treeScrollTopBeforeSelection: 476,
			}),
		).toBe(true);
	});

	test('rejects cache-hit as a substitute for warmed file-open provenance', () => {
		expect(
			worktreeFileOpenLoadTelemetrySatisfied({
				disposition: 'cache-hit',
				durationMilliseconds: 0.4,
				estimatedBytes: 640,
				executorInFlightBytesAfter: 0,
				executorInFlightBytesBefore: 0,
				executorInFlightCountAfter: 0,
				executorInFlightCountBefore: 0,
				executorInFlightMilliseconds: 0.4,
				executorPendingWaitMilliseconds: 0,
				executorQueuedBytesAfter: 0,
				executorQueuedBytesBefore: 0,
				executorQueuedLoadCountAfter: 0,
				executorQueuedLoadCountBefore: 0,
				lane: 'foreground',
				resourceBodyRegistryCommitMilliseconds: 0,
				resourceFetchResponseWaitMilliseconds: 1,
				resourceFirstChunkWaitMilliseconds: 1,
				resourceStreamReadMilliseconds: 1,
				schedulerQueueWaitMilliseconds: 0,
				schedulerQueuedEstimatedBytesAfter: 0,
				schedulerQueuedEstimatedBytesBefore: 0,
				schedulerQueuedIntentCountAfter: 0,
				schedulerQueuedIntentCountBefore: 0,
			}),
		).toBe(false);
		expect(
			worktreeFileOpenLoadTelemetrySatisfied({
				disposition: 'visible-preloaded',
				durationMilliseconds: 0.4,
				estimatedBytes: 640,
				executorInFlightBytesAfter: 0,
				executorInFlightBytesBefore: 0,
				executorInFlightCountAfter: 0,
				executorInFlightCountBefore: 0,
				executorInFlightMilliseconds: 0.4,
				executorPendingWaitMilliseconds: 0,
				executorQueuedBytesAfter: 0,
				executorQueuedBytesBefore: 0,
				executorQueuedLoadCountAfter: 0,
				executorQueuedLoadCountBefore: 0,
				lane: 'foreground',
				resourceBodyRegistryCommitMilliseconds: 0,
				resourceFetchResponseWaitMilliseconds: 1,
				resourceFirstChunkWaitMilliseconds: 1,
				resourceStreamReadMilliseconds: 1,
				schedulerQueueWaitMilliseconds: 0,
				schedulerQueuedEstimatedBytesAfter: 0,
				schedulerQueuedEstimatedBytesBefore: 0,
				schedulerQueuedIntentCountAfter: 0,
				schedulerQueuedIntentCountBefore: 0,
			}),
		).toBe(true);
	});

	test('accepts foreground file-open telemetry while existing lower-priority work is in flight', () => {
		expect(
			worktreeFileOpenLoadTelemetrySatisfied({
				disposition: 'cold-loaded',
				durationMilliseconds: 29.6,
				estimatedBytes: 24_905,
				executorInFlightBytesAfter: 0,
				executorInFlightBytesBefore: 26_199,
				executorInFlightCountAfter: 0,
				executorInFlightCountBefore: 2,
				executorInFlightMilliseconds: 29.6,
				executorPendingWaitMilliseconds: 0,
				executorQueuedBytesAfter: 0,
				executorQueuedBytesBefore: 0,
				executorQueuedLoadCountAfter: 0,
				executorQueuedLoadCountBefore: 0,
				lane: 'foreground',
				resourceBodyRegistryCommitMilliseconds: 0,
				resourceFetchResponseWaitMilliseconds: 10,
				resourceFirstChunkWaitMilliseconds: 2,
				resourceStreamReadMilliseconds: 17,
				schedulerQueueWaitMilliseconds: 0,
				schedulerQueuedEstimatedBytesAfter: 0,
				schedulerQueuedEstimatedBytesBefore: 0,
				schedulerQueuedIntentCountAfter: 0,
				schedulerQueuedIntentCountBefore: 0,
			}),
		).toBe(true);
	});

	registerWorktreeDevServerTelemetryAndSelectionTests();
});
