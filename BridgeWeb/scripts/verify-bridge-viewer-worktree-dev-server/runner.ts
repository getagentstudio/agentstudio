import type { BridgeWebTestLaunch } from '../dev-server/bridge-web-test-launch.ts';
import {
	reviewInteractionPerformanceSatisfied,
	reviewStartupLoadTimingSatisfied,
	worktreeInteractionPerformanceSatisfied,
	worktreeStartupLoadTimingSatisfied,
} from '../verify-bridge-viewer-worktree-review-proof.ts';
import {
	worktreeFileOpenLoadTelemetrySatisfied,
	worktreeFileVisibleDemandTelemetrySatisfied,
} from '../verify-bridge-viewer-worktree-review-proof.ts';
import {
	worktreeDevServerConsoleProof,
	worktreeDevServerPerformanceConsoleProof,
	writeWorktreeDevServerPerformanceProofArtifact,
	writeWorktreeDevServerProofArtifact,
} from './artifacts.ts';
import { clearVerifierBrowser, installVerifierBrowser } from './browser-session.ts';
import { collectBridgeDevelopmentCompleteJourneyLaunch } from './complete-journey-collector.ts';
import { performanceOnlyMode } from './config.ts';
import {
	fileToReviewHandoffFixtureRelativePath,
	initialContentFixtureRelativePath,
	recentlyUpdatedFixtureRelativePath,
	repoRootPath,
	reviewSelectionFixtureRelativePath,
	scenarioNameFromDevServerUrl,
	splitResetFixtureRelativePath,
	staleRefreshFixtureRelativePath,
	worktreeDevServerUrl,
} from './config.ts';
import {
	assertRenderedWorktreeContent,
	assertSelectedContentRouteProof,
	assertWorktreeFileVisibleAppProof,
	assertWorktreeScrollExtentCanary,
	clickWorktreeFilePath,
	makeScrollExtentCanary,
	readWorktreeFileScrollExtentSnapshot,
	readWorktreeFileTreeAnchorSnapshot,
	readWorktreeFileVisibleAppProof,
	readWorktreeRenderedContentState,
	renderedTextIncludesContent,
	scrollContentPaneToNonzeroOffset,
	scrollTreeToFilePath,
	waitForPierreFileTreeAnchorSettled,
	waitForRenderedWorktreeContent,
} from './content-state.ts';
import {
	verifyWorktreeFileProductControls,
	verifyWorktreeFileSplitResetReplacement,
	verifyWorktreeFileStaleRefresh,
} from './file-refresh-proofs.ts';
import {
	clickWorktreeFilePathViaSearch,
	verifyWorktreeFileToReviewHandoff,
} from './file-review-handoff.ts';
import {
	captureWorktreeDevServerScreenshot,
	fillWorktreeFileSearch,
	waitForWorktreeOpenFileState,
} from './file-search-filter.ts';
import {
	collectReviewInteractionPerformanceProof,
	collectReviewStartupLoadTimingProof,
	collectWorktreeInteractionPerformanceProof,
	collectWorktreeStartupLoadTimingProof,
} from './interaction-performance.ts';
import { makeVerificationPage } from './page-factory.ts';
import {
	assertNoStandaloneWorktreeFileApp,
	assertObservedWorktreeDevServerUrl,
	assertSharedBridgeFileViewerShell,
	readBridgePierreWorkerFileSuccessCount,
	reloadWorktreeDevServerPage,
	waitForBridgePierreWorkerFileSuccessForCacheKey,
	worktreeFilePierreCacheKey,
} from './page-shell.ts';
import { verifyWorktreeReviewFileTargetRoute, verifyWorktreeReviewRoute } from './review-routes.ts';
import { installFileContentRouteGate } from './route-probes.ts';
import { resetWorktreeFileTreeForPerformanceSamples } from './scroll-performance.ts';
import {
	readWorktreeFileOpenLoadTelemetry,
	verifyWorktreeFileRecentlyUpdatedDemand,
	waitForWorktreeFileVisibleDemandTelemetry,
} from './telemetry.ts';
import type {
	WorktreeDevServerPerformanceOnlyResult,
	WorktreeDevServerVerificationResult,
	WorktreeFileSelectedContentSemanticProof,
	WorktreeRenderedContentState,
} from './types.ts';
import { hashText, makeDeferred } from './utils.ts';
import { createOwnedVerifierJourneyDeadline } from './verifier-journey-deadline.ts';
import {
	assertWorktreeTreeExtentMatchesSurfaceFacts,
	bridgeWorktreeDevRootTokenForPath,
	closeAllWorktreeFileSurfaces,
	fetchFetchableWorktreeFileDescriptorForPath,
	fetchPerformanceWorktreeFileDescriptors,
	fetchWorktreeFileContent,
	fetchWorktreeSurface,
	readBrowserProof,
	resolveTargetDescriptor,
	restoreWorktreeFileModifiedFixture,
	restoreWorktreeFileStaleRefreshFixture,
	worktreeFileModifiedFixture,
	worktreeFileStaleRefreshFixture,
	worktreeFileTreeRows,
	type WorktreeFileModifiedFixture,
	type WorktreeFileStaleRefreshFixture,
} from './worktree-data.ts';

interface WorktreeDevServerStartupSurfaceResultBase {
	readonly browserProof: Awaited<ReturnType<typeof readBrowserProof>>;
	readonly observedPageUrl: string;
	readonly scenarioName: string;
}

export type WorktreeDevServerStartupSurfaceResult =
	| (WorktreeDevServerStartupSurfaceResultBase & {
			readonly proof: Awaited<ReturnType<typeof collectWorktreeStartupLoadTimingProof>>;
			readonly satisfied: boolean;
			readonly surface: 'file';
	  })
	| (WorktreeDevServerStartupSurfaceResultBase & {
			readonly proof: Awaited<ReturnType<typeof collectReviewStartupLoadTimingProof>>;
			readonly satisfied: boolean;
			readonly surface: 'review';
	  });

export async function runBridgeViewerWorktreeDevServerVerifier(
	launch: BridgeWebTestLaunch,
): Promise<void> {
	const browser = await launch.launchBrowser({ headless: true });
	const deadline = createOwnedVerifierJourneyDeadline({
		closePages: async (reason): Promise<void> => {
			await Promise.allSettled(
				browser
					.contexts()
					.flatMap((context) => context.pages())
					.map((page) => page.close({ reason })),
			);
			await browser.close({ reason });
		},
	});
	installVerifierBrowser(browser, deadline.signal);
	try {
		if (performanceOnlyMode) {
			const result = await verifyWorktreeDevServerPerformanceOnly(launch);
			const proofArtifactPath = await writeWorktreeDevServerPerformanceProofArtifact(result);
			console.log(
				JSON.stringify(
					worktreeDevServerPerformanceConsoleProof(result, proofArtifactPath),
					null,
					2,
				),
			);
			if (
				!worktreeInteractionPerformanceSatisfied(result.interactionPerformanceProof) ||
				!reviewInteractionPerformanceSatisfied(result.reviewInteractionPerformanceProof)
			) {
				process.exitCode = 1;
			}
		} else {
			const result = await verifyWorktreeDevServer();
			const proofArtifactPath = await writeWorktreeDevServerProofArtifact(result);
			console.log(
				JSON.stringify(worktreeDevServerConsoleProof(result, proofArtifactPath), null, 2),
			);
			if (
				!worktreeInteractionPerformanceSatisfied(result.interactionPerformanceProof) ||
				!reviewInteractionPerformanceSatisfied(result.reviewInteractionPerformanceProof)
			) {
				throw new Error(
					`Expected Worktree/File and Worktree/Review interaction performance proof to satisfy p95/p99 budgets: ${proofArtifactPath}`,
				);
			}
		}
	} finally {
		clearVerifierBrowser();
		try {
			await closeAllWorktreeFileSurfaces();
		} finally {
			await deadline.dispose();
		}
	}
}

export async function runBridgeViewerWorktreeDevServerStartupSurfaceVerifier(
	surface: 'file' | 'review',
	launch: BridgeWebTestLaunch,
): Promise<WorktreeDevServerStartupSurfaceResult> {
	const browser = await launch.launchBrowser({ headless: true });
	const deadline = createOwnedVerifierJourneyDeadline({
		closePages: async (reason): Promise<void> => {
			await Promise.allSettled(
				browser
					.contexts()
					.flatMap((context) => context.pages())
					.map((page) => page.close({ reason })),
			);
			await browser.close({ reason });
		},
	});
	installVerifierBrowser(browser, deadline.signal);
	try {
		const page = await makeVerificationPage();
		if (surface === 'file') {
			const proof = await collectWorktreeStartupLoadTimingProof({ page });
			return {
				browserProof: await readBrowserProof(page),
				observedPageUrl: page.url(),
				proof,
				satisfied: worktreeStartupLoadTimingSatisfied({ startupLoadTiming: proof }),
				scenarioName: scenarioNameFromDevServerUrl(worktreeDevServerUrl),
				surface,
			};
		}
		const proof = await collectReviewStartupLoadTimingProof({ page });
		return {
			browserProof: await readBrowserProof(page),
			observedPageUrl: page.url(),
			proof,
			satisfied: reviewStartupLoadTimingSatisfied({ reviewStartupLoadTiming: proof }),
			scenarioName: scenarioNameFromDevServerUrl(worktreeDevServerUrl),
			surface,
		};
	} finally {
		clearVerifierBrowser();
		try {
			await closeAllWorktreeFileSurfaces();
		} finally {
			await deadline.dispose();
		}
	}
}

export async function runBridgeViewerWorktreeDevServerCompleteJourneyLaunch(props: {
	readonly launch: BridgeWebTestLaunch;
	readonly attemptCount: number;
	readonly launchId: string;
	readonly sourceHead: string;
}): Promise<Awaited<ReturnType<typeof collectBridgeDevelopmentCompleteJourneyLaunch>>> {
	const browser = await props.launch.launchBrowser({ headless: true });
	const deadline = createOwnedVerifierJourneyDeadline({
		closePages: async (reason): Promise<void> => {
			await Promise.allSettled(
				browser
					.contexts()
					.flatMap((context) => context.pages())
					.map((page) => page.close({ reason })),
			);
			await browser.close({ reason });
		},
	});
	installVerifierBrowser(browser, deadline.signal);
	try {
		return await collectBridgeDevelopmentCompleteJourneyLaunch(props);
	} finally {
		clearVerifierBrowser();
		try {
			await closeAllWorktreeFileSurfaces();
		} finally {
			await deadline.dispose();
		}
	}
}

export async function verifyWorktreeDevServerPerformanceOnly(
	launch: BridgeWebTestLaunch,
): Promise<WorktreeDevServerPerformanceOnlyResult> {
	const page = await makeVerificationPage();
	const { surface, descriptors } = await launch.readProductData(async () => {
		const surface = await fetchWorktreeSurface();
		const descriptors = await fetchPerformanceWorktreeFileDescriptors(surface);
		return { surface, descriptors };
	}, closeAllWorktreeFileSurfaces);
	const startupLoadTiming = await collectWorktreeStartupLoadTimingProof({
		page,
	});
	await resetWorktreeFileTreeForPerformanceSamples({
		page,
		totalMetadataTreeRowCount: worktreeFileTreeRows(surface.frames).length,
	});
	const interactionPerformanceProof = await collectWorktreeInteractionPerformanceProof({
		descriptors,
		page,
		startupLoadTiming,
	});
	const reviewInteractionPerformanceProof = await collectReviewInteractionPerformanceProof({
		page,
	});
	return {
		browserProof: await readBrowserProof(page),
		descriptorCount: descriptors.length,
		interactionPerformanceProof,
		reviewInteractionPerformanceProof,
		observedPageUrl: page.url(),
		scenarioName: scenarioNameFromDevServerUrl(worktreeDevServerUrl),
	};
}

export async function verifyWorktreeDevServer(): Promise<WorktreeDevServerVerificationResult> {
	const page = await makeVerificationPage();
	let fileToReviewHandoffFixture: WorktreeFileModifiedFixture | null = null;
	let reviewSelectionFixture: WorktreeFileModifiedFixture | null = null;
	let recentlyUpdatedFixture: WorktreeFileModifiedFixture | null = null;
	let staleRefreshInitialFixture: WorktreeFileModifiedFixture | null = null;
	let staleRefreshFixture: WorktreeFileStaleRefreshFixture | null = null;
	let splitResetInitialFixture: WorktreeFileModifiedFixture | null = null;
	let splitResetFixture: WorktreeFileStaleRefreshFixture | null = null;
	try {
		fileToReviewHandoffFixture = await worktreeFileModifiedFixture({
			relativePath: fileToReviewHandoffFixtureRelativePath,
			tag: 'file_to_review_handoff',
		});
		reviewSelectionFixture = await worktreeFileModifiedFixture({
			markerPlacement: 'prependComment',
			relativePath: reviewSelectionFixtureRelativePath,
			tag: 'review_selection',
		});
		staleRefreshInitialFixture = await worktreeFileModifiedFixture({
			markerPlacement: 'prependComment',
			relativePath: staleRefreshFixtureRelativePath,
			tag: 'stale_refresh_initial',
		});
		splitResetInitialFixture = await worktreeFileModifiedFixture({
			markerPlacement: 'prependComment',
			relativePath: splitResetFixtureRelativePath,
			tag: 'split_reset_initial',
		});
		recentlyUpdatedFixture = await worktreeFileModifiedFixture({
			markerPlacement: 'prependComment',
			relativePath: recentlyUpdatedFixtureRelativePath,
			tag: 'recently_updated',
		});
		const surface = await fetchWorktreeSurface();
		const expectedWorktreeRootToken = await bridgeWorktreeDevRootTokenForPath(repoRootPath);
		if (surface.provenance.worktreeRootToken !== expectedWorktreeRootToken) {
			throw new Error(
				`Expected current checkout worktree token ${expectedWorktreeRootToken}, got ${surface.provenance.worktreeRootToken}`,
			);
		}
		const descriptors = await fetchPerformanceWorktreeFileDescriptors(surface);
		const initialDescriptor = await fetchFetchableWorktreeFileDescriptorForPath({
			path: initialContentFixtureRelativePath,
			surface,
		});
		const targetDescriptor = await resolveTargetDescriptor(surface);
		const initialContent = await fetchWorktreeFileContent(initialDescriptor);
		const content = await fetchWorktreeFileContent(targetDescriptor);
		const staleRefreshDescriptor = await fetchFetchableWorktreeFileDescriptorForPath({
			path: staleRefreshFixtureRelativePath,
			surface,
		});
		const splitResetDescriptor = await fetchFetchableWorktreeFileDescriptorForPath({
			path: splitResetFixtureRelativePath,
			surface,
		});
		const recentlyUpdatedDescriptor = await fetchFetchableWorktreeFileDescriptorForPath({
			path: recentlyUpdatedFixtureRelativePath,
			surface,
		});
		const staleRefreshInitialContent = await fetchWorktreeFileContent(staleRefreshDescriptor);
		const splitResetInitialContent = await fetchWorktreeFileContent(splitResetDescriptor);
		staleRefreshFixture = await worktreeFileStaleRefreshFixture({
			descriptor: staleRefreshDescriptor,
			initialContent: staleRefreshInitialContent,
		});
		splitResetFixture = await worktreeFileStaleRefreshFixture({
			descriptor: splitResetDescriptor,
			initialContent: splitResetInitialContent,
		});
		const surfaceText = JSON.stringify(surface);
		if (
			content.length > 0 &&
			surfaceText.includes(content.slice(0, Math.min(80, content.length)))
		) {
			throw new Error('Expected Worktree/File surface metadata to omit file body content');
		}
		const reviewRouteProof = await verifyWorktreeReviewRoute();
		const reviewFileTargetRouteProof = await verifyWorktreeReviewFileTargetRoute();
		const fileToReviewHandoffProof = await verifyWorktreeFileToReviewHandoff();
		await page.goto(worktreeDevServerUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
		await page.waitForSelector('[data-testid="bridge-file-viewer-shell"]', { timeout: 30_000 });
		const observedRoute = await assertObservedWorktreeDevServerUrl(page);
		const substituteGuardProof = await assertNoStandaloneWorktreeFileApp(page);
		await clickWorktreeFilePathViaSearch({ page, path: initialDescriptor.path });
		await page.waitForFunction(
			(path: string): boolean =>
				document
					.querySelector('[data-worktree-open-file-path]')
					?.getAttribute('data-worktree-open-file-path') === path,
			initialDescriptor.path,
			{ timeout: 10_000 },
		);
		await page.waitForFunction(
			(): boolean =>
				document
					.querySelector('[data-worktree-open-file-state]')
					?.getAttribute('data-worktree-open-file-state') === 'ready',
			{ timeout: 20_000 },
		);
		const firstLoadRendered = await readWorktreeRenderedContentState(page);
		assertRenderedWorktreeContent({
			content: initialContent,
			label: 'first-load Worktree/File content',
			rendered: firstLoadRendered,
			targetPath: initialDescriptor.path,
		});
		await fillWorktreeFileSearch(page, '');
		await scrollTreeToFilePath(page, targetDescriptor.path);
		await waitForPierreFileTreeAnchorSettled(page, targetDescriptor.path);
		const scrollExtentBeforeSelection = await readWorktreeFileScrollExtentSnapshot(page);
		const treeAnchorBeforeSelection = await readWorktreeFileTreeAnchorSnapshot(
			page,
			targetDescriptor.path,
		);
		const contentRouteGate = makeDeferred<void>();
		const contentRouteProbe = await installFileContentRouteGate({ gate: contentRouteGate, page });
		let scrollExtentAfterSelection;
		let workerFileSuccessCountBeforeTargetSelection;
		let selectedContentRouteProof;
		try {
			await clickWorktreeFilePath(page, targetDescriptor.path);
			await page.waitForFunction(
				(path: string): boolean =>
					document
						.querySelector('[data-worktree-open-file-path]')
						?.getAttribute('data-worktree-open-file-path') === path,
				targetDescriptor.path,
				{ timeout: 10_000 },
			);
			await page.waitForFunction(
				(expected: { readonly path: string }): boolean => {
					const contentPanel = document.querySelector(
						'[data-testid="bridge-file-viewer-code-canvas"]',
					);
					const state = contentPanel?.getAttribute('data-worktree-open-file-state');
					return (
						contentPanel?.getAttribute('data-worktree-open-file-path') === expected.path &&
						(state === 'loading' || state === 'stale')
					);
				},
				{ path: targetDescriptor.path },
				{ timeout: 20_000 },
			);
			await scrollContentPaneToNonzeroOffset(page);
			scrollExtentAfterSelection = await readWorktreeFileScrollExtentSnapshot(page);
			workerFileSuccessCountBeforeTargetSelection =
				await readBridgePierreWorkerFileSuccessCount(page);
			contentRouteGate.resolve();
			const targetStateAfterGateRelease = await page.evaluate((path: string): string | null => {
				const contentPanel = document.querySelector(
					'[data-testid="bridge-file-viewer-code-canvas"]',
				);
				return contentPanel?.getAttribute('data-worktree-open-file-path') === path
					? (contentPanel.getAttribute('data-worktree-open-file-state') ?? null)
					: null;
			}, targetDescriptor.path);
			if (targetStateAfterGateRelease === 'stale') {
				await clickWorktreeFilePath(page, targetDescriptor.path);
			}
			await waitForWorktreeOpenFileState({
				page,
				path: targetDescriptor.path,
				state: 'ready',
			});
			selectedContentRouteProof = assertSelectedContentRouteProof({
				expectedContentHandle: targetDescriptor.contentHandle,
				probe: contentRouteProbe,
			});
		} finally {
			await contentRouteProbe.dispose();
		}
		const scrollExtentAfterReady = await readWorktreeFileScrollExtentSnapshot(page);
		await waitForPierreFileTreeAnchorSettled(page, targetDescriptor.path);
		const treeAnchorAfterReady = await readWorktreeFileTreeAnchorSnapshot(
			page,
			targetDescriptor.path,
		);
		const rendered = await waitForRenderedWorktreeContent({
			content,
			label: 'selected Worktree/File content',
			page,
			targetPath: targetDescriptor.path,
		});
		await waitForBridgePierreWorkerFileSuccessForCacheKey({
			expectedFileCacheKey: worktreeFilePierreCacheKey(targetDescriptor),
			page,
			previousFileSuccessCount: workerFileSuccessCountBeforeTargetSelection,
		});
		const selectedContentSemanticProof: WorktreeFileSelectedContentSemanticProof = {
			expectedContentHandle: targetDescriptor.contentHandle,
			expectedContentHash: hashText(content),
			expectedDisplayPath: targetDescriptor.path,
			observedDisplayPath: rendered.selectedDisplayPath,
			observedLineCount: rendered.selectedLineCount,
			renderedTextHash: hashText(rendered.selectedText),
			renderedTextIncludesExpectedContent: renderedTextIncludesContent(
				rendered.selectedText,
				content,
			),
		};
		const { selectedText: _selectedText, ...renderedResult }: WorktreeRenderedContentState =
			rendered;
		if (rendered.treeTotalSizePixels === null || rendered.treeTotalSizePixels <= 0) {
			throw new Error('Expected Worktree/File tree extent to be reserved from provider facts');
		}
		if (rendered.treeTotalSizeSource !== 'providerFacts') {
			throw new Error(
				`Expected Worktree/File tree extent source to be providerFacts, got ${rendered.treeTotalSizeSource ?? 'none'}`,
			);
		}
		assertWorktreeTreeExtentMatchesSurfaceFacts({
			renderedTreeTotalSizePixels: rendered.treeTotalSizePixels,
			surfaceTreeSizeFacts: surface.treeSizeFacts,
		});
		const sharedShellProof = await assertSharedBridgeFileViewerShell({
			page,
			targetDescriptor,
			workerFileSuccessCountBeforeTargetSelection,
		});
		const visibleAppProof = await readWorktreeFileVisibleAppProof(page);
		assertWorktreeFileVisibleAppProof({
			expectedSourceBaseRef: surface.provenance.baseRef,
			expectedSourceCursor: surface.source.sourceCursor,
			expectedSourceId: surface.source.sourceId,
			expectedSourceScenarioName: surface.provenance.scenarioName,
			expectedWorktreeRootToken,
			proof: visibleAppProof,
		});
		const fileViewerVisibleDemandTelemetry = await waitForWorktreeFileVisibleDemandTelemetry(page);
		if (!worktreeFileVisibleDemandTelemetrySatisfied(fileViewerVisibleDemandTelemetry)) {
			throw new Error(
				`Expected FileViewer visible preload demand telemetry to be attributed: ${JSON.stringify(fileViewerVisibleDemandTelemetry)}`,
			);
		}
		const fileViewerClickToReadyTelemetry = await readWorktreeFileOpenLoadTelemetry(page);
		if (!worktreeFileOpenLoadTelemetrySatisfied(fileViewerClickToReadyTelemetry)) {
			throw new Error(
				`Expected FileViewer click-to-ready load telemetry to be drained and attributed: ${JSON.stringify(fileViewerClickToReadyTelemetry)}`,
			);
		}
		const fileViewerRecentlyUpdatedDemandTelemetry = await verifyWorktreeFileRecentlyUpdatedDemand({
			descriptor: recentlyUpdatedDescriptor,
			page,
			sourceId: surface.source.sourceId,
		});
		const readyScreenshotPath = await captureWorktreeDevServerScreenshot({
			name: 'worktree-file-ready.png',
			page,
		});
		const productControlsProof = await verifyWorktreeFileProductControls({
			descriptors,
			page,
			targetPath: targetDescriptor.path,
		});
		const splitResetReplacementProof = await verifyWorktreeFileSplitResetReplacement({
			descriptor: splitResetDescriptor,
			fixture: splitResetFixture,
			page,
		});
		await reloadWorktreeDevServerPage(page);
		const staleRefreshProof = await verifyWorktreeFileStaleRefresh({
			descriptor: staleRefreshDescriptor,
			fixture: staleRefreshFixture,
			page,
		});
		const scrollExtentCanary = makeScrollExtentCanary({
			afterReady: scrollExtentAfterReady,
			afterSelection: scrollExtentAfterSelection,
			beforeSelection: scrollExtentBeforeSelection,
			selectedAnchorPath: targetDescriptor.path,
			treeAnchorAfterReady,
			treeAnchorBeforeSelection,
		});
		assertWorktreeScrollExtentCanary(scrollExtentCanary);
		const startupLoadTiming = await collectWorktreeStartupLoadTimingProof({
			page,
		});
		const performanceSurface = await fetchWorktreeSurface();
		const performanceDescriptors =
			await fetchPerformanceWorktreeFileDescriptors(performanceSurface);
		await resetWorktreeFileTreeForPerformanceSamples({
			page,
			totalMetadataTreeRowCount: worktreeFileTreeRows(performanceSurface.frames).length,
		});
		const interactionPerformanceProof = await collectWorktreeInteractionPerformanceProof({
			descriptors: performanceDescriptors,
			page,
			startupLoadTiming,
		});
		const reviewInteractionPerformanceProof = await collectReviewInteractionPerformanceProof({
			page,
		});
		return {
			...renderedResult,
			browserProof: await readBrowserProof(page),
			descriptorCount: descriptors.length,
			firstLoadContentState: firstLoadRendered.selectedContentState,
			firstLoadDisplayPath: firstLoadRendered.selectedDisplayPath,
			firstLoadLineCount: firstLoadRendered.selectedLineCount,
			frameCount: surface.frames.length,
			interactionPerformanceProof,
			reviewInteractionPerformanceProof,
			observedLocationHref: observedRoute.locationHref,
			observedPageUrl: observedRoute.pageUrl,
			packageForbiddenTextAbsent: visibleAppProof.forbiddenTextAbsentOutsideIntentionalUi,
			positiveAssertions: [
				'shared BridgeViewer FileViewer shell rendered',
				'FileViewer opens selected file target in ReviewViewer without page navigation',
				'Pierre FileTree rendered in right rail',
				'Pierre CodeView file canvas rendered on left',
				'Shiki/Pierre worker-backed path requested and ready for workers=on',
				'provider tree extent facts reached DOM',
				'search, regex, and filters changed rendered Pierre rows',
				'source-less split reset preserved stale body and fetched replacement only on refresh',
			],
			proofArtifactPath: '',
			negativeAssertions: [
				'standalone WorktreeFileApp test id absent',
				'review empty shell absent for worktree-file protocol',
				'raw worktree payload text absent outside intended UI',
			],
			scrollExtentCanary,
			selectedContentSemanticProof,
			selectedContentRouteProof,
			scenarioName: scenarioNameFromDevServerUrl(worktreeDevServerUrl),
			screenshotPaths: {
				ready: readyScreenshotPath,
				review: reviewRouteProof.screenshotPath,
				reviewFileTarget: reviewFileTargetRouteProof.screenshotPath,
				search: productControlsProof.searchScreenshotPath,
				stale: staleRefreshProof.staleScreenshotPath,
			},
			sourceCursor: surface.source.sourceCursor,
			sourceId: surface.source.sourceId,
			sourceBaseRef: surface.provenance.baseRef,
			sourceScenarioName: surface.provenance.scenarioName,
			worktreeRootToken: surface.provenance.worktreeRootToken,
			splitResetReplacementProof,
			staleRefreshProof,
			targetPath: targetDescriptor.path,
			treePathCount: surface.treeSizeFacts.pathCount ?? null,
			treeTotalSizeSource: rendered.treeTotalSizeSource,
			sharedShellProof,
			substituteGuardProof,
			visibleAppProof,
			fileToReviewHandoffProof,
			fileViewerClickToReadyTelemetry,
			fileViewerRecentlyUpdatedDemandTelemetry,
			fileViewerVisibleDemandTelemetry,
			productControlsProof,
			reviewFileTargetRouteProof,
			reviewRouteProof,
		};
	} finally {
		await page.close();
		if (splitResetFixture !== null) {
			await restoreWorktreeFileStaleRefreshFixture(splitResetFixture);
		}
		if (staleRefreshFixture !== null) {
			await restoreWorktreeFileStaleRefreshFixture(staleRefreshFixture);
		}
		if (recentlyUpdatedFixture !== null) {
			await restoreWorktreeFileModifiedFixture(recentlyUpdatedFixture);
		}
		if (splitResetInitialFixture !== null) {
			await restoreWorktreeFileModifiedFixture(splitResetInitialFixture);
		}
		if (staleRefreshInitialFixture !== null) {
			await restoreWorktreeFileModifiedFixture(staleRefreshInitialFixture);
		}
		if (fileToReviewHandoffFixture !== null) {
			await restoreWorktreeFileModifiedFixture(fileToReviewHandoffFixture);
		}
		if (reviewSelectionFixture !== null) {
			await restoreWorktreeFileModifiedFixture(reviewSelectionFixture);
		}
	}
}
