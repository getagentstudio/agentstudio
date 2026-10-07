import { createHash } from 'node:crypto';

import type { Browser, Page, Request } from 'playwright';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { collectBridgeViewerProductOnlyContractViolations } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-contract.ts';
import { runBridgeViewerProductOnlyJourney } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-page.ts';
import {
	revealReviewTreeFilePath,
	reviewTreeReachablePathScrollTopMap,
	waitForVisibleReviewTreeFilePath,
} from '../../scripts/verify-bridge-viewer-worktree-dev-server/review-tree-click.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	clearFileSearchAndScrollTreeDeep,
	readFileDeepScrollObservation,
	scrollSelectedFileThroughMarkers,
} from './bridge-viewer-vite-file-deep-scroll-observation.ts';
import {
	decodePaintedSourceCorrelations,
	type PaintedSourceCorrelation,
} from './bridge-viewer-vite-painted-source-correlation.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServerCleanup,
	type BridgeViewerViteProductContentOracle,
	type BridgeViewerViteProductFixtureOracle,
	type BridgeViewerViteProductProofFixtureOracle,
	type BridgeViewerViteProductReviewFileOracle,
} from './bridge-viewer-vite-product-fixture.ts';
import {
	bridgeViewerViteProductFileUrl,
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';
import {
	observeBrowserRuntimeDiagnostics,
	waitForSettledReviewComparison,
	waitForSettledReviewComparisonWithDiagnostics,
} from './bridge-viewer-vite-review-comparison-observation.ts';

const productJourneyTimeoutMilliseconds = 120_000;

interface ProductContentRequestObservation {
	readonly contentKind: string;
	readonly contentRequestId: string;
	readonly descriptor: Readonly<Record<string, unknown>>;
	readonly leaseId: string;
	responseStatus: number | null;
}

interface ReviewSelectionObservation {
	readonly bodyText: string;
	readonly paintedCorrelations: readonly PaintedSourceCorrelation[];
	readonly paintedPublicationId: string | null;
}

interface ReviewSelectionBrowserSnapshot {
	readonly bodyText: string;
	readonly encodedCorrelations: string;
	readonly paintedPublicationId: string | null;
}

let disposeFixture: (() => Promise<void>) | null = null;
let fixtureOracle: BridgeViewerViteProductProofFixtureOracle | null = null;
let ownedServer: BridgeViewerOwnedViteProductServer | null = null;
let ownedServerCleanup: BridgeViewerOwnedViteProductServerCleanup | null = null;

describe('Bridge Viewer dedicated Vite product E2E', () => {
	beforeAll(async (): Promise<void> => {
		const fixture = await createBridgeViewerViteProductFixture();
		disposeFixture = fixture.dispose;
		fixtureOracle = fixture.oracle;
		ownedServer = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
	});

	afterAll(async (): Promise<void> => {
		try {
			if (ownedServer !== null) ownedServerCleanup = await ownedServer.stop();
		} finally {
			await disposeFixture?.();
		}
		if (ownedServerCleanup !== null) {
			expect(ownedServerCleanup.forcedTerminationRequired).toBe(false);
			expect(ownedServerCleanup.ownedProcessAliveAfterStop).toBe(false);
		}
	});

	test('correlates the disposable live-worktree journey through the product provider, worker, Pierre, and painted DOM', async () => {
		const oracle = requireFixtureOracle();
		const server = requireOwnedServer();
		expect(oracle.changedPaths).toHaveLength(16);
		expect(oracle.reviewFiles).toHaveLength(oracle.changedPaths.length);
		expect(oracle.fileProofCodeContent.length).toBeLessThanOrEqual(160);

		const journeyObservations = await runBridgeViewerProductOnlyJourney({
			baseUrl: server.origin,
			expectedReviewItemIds: oracle.expectedReviewItemIds,
			fileProofTargets: oracle.fileProofTargets,
		});

		expect(collectBridgeViewerProductOnlyContractViolations(journeyObservations)).toEqual([]);
		assertJourneyFreshness({ journeyObservations, oracle, server });
	});

	test('observes Review base/head body truth, request leases, painted publication correlation, and directory disclosure interaction', async () => {
		const oracle = requireFixtureOracle();
		const server = requireOwnedServer();
		const browser = await launchBridgeViewerE2EChromium();
		let page: Page | null = null;
		try {
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const contentRequests = observeProductContentRequests(page);
			await page.goto(
				bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(oracle),
				),
				{
					timeout: productJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			await page.waitForSelector('[data-testid="review-viewer-shell"]', {
				timeout: productJourneyTimeoutMilliseconds,
			});
			await collapseAndExpandReviewDirectory(page);

			const reviewFiles = selectedReviewOracleFiles(oracle.reviewFiles);
			const reviewTreeScrollTopByPath = await reviewTreeReachablePathScrollTopMap(page);
			const paintedDescriptorIds = new Set<string>();
			for (const reviewFile of reviewFiles) {
				const scrollTopHint = reviewTreeScrollTopByPath.get(reviewFile.path);
				if (scrollTopHint === undefined) {
					throw new Error(`Review tree path is not reachable: ${reviewFile.path}`);
				}
				// oxlint-disable-next-line no-await-in-loop -- Each virtualized row must be revealed before its real click.
				await revealReviewTreeFilePath({ page, path: reviewFile.path, scrollTopHint });
				// oxlint-disable-next-line no-await-in-loop -- Visibility is the bounded event before the real click.
				await waitForVisibleReviewTreeFilePath({ page, path: reviewFile.path });
				// oxlint-disable-next-line no-await-in-loop -- Each selection must reach painted terminal state before the next real user interaction.
				const selectionObservation = await selectReviewFileAndReadObservation({ page, reviewFile });
				expectReviewBodyLinesPainted(selectionObservation.bodyText, reviewFile.base.body);
				expectReviewBodyLinesPainted(selectionObservation.bodyText, reviewFile.head.body);
				expect(selectionObservation.paintedCorrelations).toHaveLength(2);
				for (const roleOracle of [reviewFile.base, reviewFile.head]) {
					const correlation = selectionObservation.paintedCorrelations.find(
						(candidate): boolean => candidate.role === roleOracle.role,
					);
					expect(correlation).toEqual(
						expect.objectContaining({
							disposition: 'painted',
							itemId: reviewFile.itemId,
							observedSha256: roleOracle.sha256,
							pierreItemId: reviewFile.itemId,
							position: 'whole',
							publicationId: selectionObservation.paintedPublicationId,
							role: roleOracle.role,
							semanticItemId: reviewFile.itemId,
							surface: 'review',
						}),
					);
					expect(correlation?.sourceGeneration).toBeGreaterThan(0);
					expect(correlation?.sourceIdentity).toMatch(/\S/u);
					if (correlation !== undefined) paintedDescriptorIds.add(correlation.descriptorId);
					const descriptorRequests = contentRequests.filter(
						(candidate): boolean =>
							candidate.descriptor['descriptorId'] === correlation?.descriptorId,
					);
					expect(descriptorRequests.length).toBeLessThanOrEqual(1);
					const request = descriptorRequests.find(
						(candidate): boolean => candidate.contentRequestId === correlation?.requestId,
					);
					if (correlation?.requestId === `resident-${correlation.descriptorId}`) {
						expect(request).toBeUndefined();
						continue;
					}
					expect(request).toEqual(
						expect.objectContaining({
							contentKind: 'review.content',
							leaseId: expect.stringMatching(/\S/u),
							responseStatus: 200,
						}),
					);
					expect(request?.descriptor).toEqual(
						expect.objectContaining({
							contentKind: 'review.content',
							itemId: reviewFile.itemId,
							reviewGeneration: correlation?.sourceGeneration,
							role: roleOracle.role,
							sourceIdentity: correlation?.sourceIdentity,
						}),
					);
				}
			}
			expect(paintedDescriptorIds.size).toBe(reviewFiles.length * 2);
		} finally {
			await page?.close();
			await browser.close();
		}
	});

	test('paints complete final File bytes after deep scroll with descriptor, role, request, source, and disposition correlation', async () => {
		const fixture = await createBridgeViewerViteProductFixture();
		const oracle = fixture.oracle;
		let browser: Browser | null = null;
		let page: Page | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(oracle);
			browser = await launchBridgeViewerE2EChromium();
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const contentRequests = observeProductContentRequests(page);
			const workerUrls: string[] = [];
			page.on('worker', (worker): void => {
				workerUrls.push(worker.url());
			});
			await page.goto(bridgeViewerViteProductFileUrl(server.origin, oracle.largeFilePath), {
				timeout: productJourneyTimeoutMilliseconds,
				waitUntil: 'domcontentloaded',
			});
			await waitForSelectedFileReady({ oracle, page });
			await clearFileSearchAndScrollTreeDeep({ oracle, page });
			const contentScrollObservation = await scrollSelectedFileThroughMarkers({
				content: oracle.fileContent,
				page,
			});
			const deepScrollObservation = await readFileDeepScrollObservation({
				oracle,
				page,
				workerUrls,
			});

			expect(deepScrollObservation.selectedPath).toBe(oracle.largeFilePath);
			expect(deepScrollObservation.renderedPath).toBe(oracle.largeFilePath);
			expect(deepScrollObservation.lineCount).toBe(oracle.largeFileLineCount);
			expect(deepScrollObservation.scrollHeight).toBeGreaterThan(980);
			expect(deepScrollObservation.scrollTop).toBeGreaterThan(0);
			expect(deepScrollObservation.treeScrollTop).toBeGreaterThan(0);
			expect(deepScrollObservation.deepTreePathPainted).toBe(true);
			expect(contentScrollObservation).toEqual({
				finalMarkerPainted: true,
				firstMarkerPainted: true,
				middleMarkerPainted: true,
			});
			expect(deepScrollObservation.finalMarkerPainted).toBe(true);
			expect(
				deepScrollObservation.workerUrls.some((url): boolean =>
					url.includes('bridge-comm-worker-vite-entry'),
				),
			).toBe(true);
			expect(deepScrollObservation.paintedCorrelations).toEqual([
				expect.objectContaining({
					descriptorId: expect.stringMatching(/^file-content-[0-9a-f]{32}$/u),
					disposition: 'painted',
					itemId: deepScrollObservation.renderedItemId,
					observedSha256: oracle.largeFileSha256,
					position: 'whole',
					publicationId: expect.stringMatching(/\S/u),
					requestId: expect.stringMatching(/\S/u),
					role: 'file',
					semanticItemId: deepScrollObservation.renderedItemId,
					sourceGeneration: expect.any(Number),
					sourceIdentity: expect.stringMatching(/\S/u),
					surface: 'file',
				}),
			]);
			expect(deepScrollObservation.paintedCorrelations[0]?.sourceGeneration).toBeGreaterThan(0);
			const initialCorrelation = deepScrollObservation.paintedCorrelations[0];
			const initialRequest = contentRequests.find(
				(candidate): boolean => candidate.contentRequestId === initialCorrelation?.requestId,
			);
			expect(initialRequest).toEqual(
				expect.objectContaining({
					contentKind: 'file.content',
					leaseId: expect.stringMatching(/\S/u),
					responseStatus: 200,
				}),
			);
			expect(initialRequest?.descriptor).toEqual(
				expect.objectContaining({
					declaredByteLength: oracle.fileContent.byteLength,
					expectedSha256: oracle.fileContent.sha256,
				}),
			);

			const mutatedContent = await fixture.mutateLargeFile();
			await page.reload({
				timeout: productJourneyTimeoutMilliseconds,
				waitUntil: 'domcontentloaded',
			});
			await waitForSelectedFileContentReady({ content: mutatedContent, oracle, page });
			await scrollSelectedFileThroughMarkers({ content: mutatedContent, page });
			const replacementObservation = await readFileDeepScrollObservation({
				content: mutatedContent,
				oracle,
				page,
				workerUrls,
			});
			expect(replacementObservation.paintedCorrelations).toEqual([
				expect.objectContaining({
					disposition: 'painted',
					observedSha256: mutatedContent.sha256,
					surface: 'file',
				}),
			]);
			expect(replacementObservation.paintedCorrelations).not.toEqual(
				expect.arrayContaining([
					expect.objectContaining({ observedSha256: oracle.fileContent.sha256 }),
				]),
			);
			const replacementRequest = contentRequests.find(
				(candidate): boolean =>
					candidate.contentRequestId === replacementObservation.paintedCorrelations[0]?.requestId,
			);
			expect(replacementRequest?.descriptor).toEqual(
				expect.objectContaining({
					declaredByteLength: mutatedContent.byteLength,
					expectedSha256: mutatedContent.sha256,
				}),
			);
			const initialRootRevisionToken = readFileDescriptorRootRevisionToken(
				initialRequest?.descriptor,
			);
			expect(initialRootRevisionToken).toEqual(expect.stringMatching(/\S/u));
			expect(readFileDescriptorRootRevisionToken(replacementRequest?.descriptor)).toBe(
				initialRootRevisionToken,
			);
		} catch (error: unknown) {
			primaryFailure = { error };
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'browser',
						run: async (): Promise<void> => {
							await browser?.close();
						},
					},
					{
						name: 'Vite and Swift',
						run: async (): Promise<void> => {
							if (server === null) return;
							const cleanup = await server.stop();
							expect(cleanup.forcedTerminationRequired).toBe(false);
							expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
						},
					},
					{ name: 'fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
			});
		}
	});

	test('restores a UI-committed symbolic comparison across backend restart and resolves the moved Git target', async () => {
		// Arrange
		const fixture = await createBridgeViewerViteProductFixture();
		let serverA: BridgeViewerOwnedViteProductServer | null = null;
		let serverB: BridgeViewerOwnedViteProductServer | null = null;
		const browser = await launchBridgeViewerE2EChromium();
		try {
			serverA = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			const pageA = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const pageADiagnostics = observeBrowserRuntimeDiagnostics(pageA);
			await pageA.goto(
				bridgeViewerViteProductReviewUrl(
					serverA.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					timeout: productJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			try {
				await pageA.waitForFunction(
					(): boolean =>
						document.querySelector('[data-testid="review-viewer-shell"]') !== null ||
						(document.body.textContent ?? '').includes('Review metadata is unavailable'),
					undefined,
					{
						timeout: productJourneyTimeoutMilliseconds,
					},
				);
				if ((await pageA.getByTestId('review-viewer-shell').count()) === 0) {
					throw new Error('Review metadata entered the unavailable state.');
				}
			} catch (error: unknown) {
				throw new Error(
					`Review shell did not load: ${await pageADiagnostics.describe()} server=${serverA.diagnostics()}`,
					{
						cause: error,
					},
				);
			}
			await waitForSettledReviewComparison({
				expectedTargetLabel: 'HEAD',
				expectedTargetOID: fixture.oracle.baseRef,
				page: pageA,
				timeoutMilliseconds: productJourneyTimeoutMilliseconds,
			});

			// Act: process A commits the symbolic target through the real Compare Worktree UI.
			await pageA.getByTestId(`comparison-branch-${fixture.oracle.comparisonTargetName}`).click();
			const processAObservation = await waitForSettledReviewComparison({
				expectedTargetLabel: fixture.oracle.comparisonTargetName,
				expectedTargetOID: fixture.oracle.baseRef,
				page: pageA,
				timeoutMilliseconds: productJourneyTimeoutMilliseconds,
			});
			await pageA.close();

			const processABackendPid = serverA.backendPid;
			const processACleanup = await serverA.stop();
			serverA = null;
			expect(processACleanup.forcedTerminationRequired).toBe(false);
			expect(processACleanup.ownedProcessAliveAfterStop).toBe(false);

			const movedTargetOID = await fixture.advanceComparisonTarget();
			serverB = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			const pageB = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const pageBDiagnostics = observeBrowserRuntimeDiagnostics(pageB);
			await pageB.goto(
				bridgeViewerViteProductReviewUrl(
					serverB.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					timeout: productJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			const processBObservation = await waitForSettledReviewComparisonWithDiagnostics({
				diagnostics: pageBDiagnostics,
				expectedTargetLabel: fixture.oracle.comparisonTargetName,
				expectedTargetOID: movedTargetOID,
				failureContext: (): string => `server=${serverB?.diagnostics() ?? '<stopped>'}`,
				page: pageB,
				timeoutMilliseconds: productJourneyTimeoutMilliseconds,
			});
			await pageB.close();

			const processBBackendPid = serverB.backendPid;
			const processBCleanup = await serverB.stop();
			serverB = null;

			// Assert
			const restartReceipt = {
				processA: { backendPid: processABackendPid, observation: processAObservation },
				processB: { backendPid: processBBackendPid, observation: processBObservation },
			};
			expect(restartReceipt.processA.backendPid).toBeGreaterThan(0);
			expect(restartReceipt.processB.backendPid).toBeGreaterThan(0);
			expect(restartReceipt.processB.backendPid).not.toBe(restartReceipt.processA.backendPid);
			expect(processBCleanup.forcedTerminationRequired).toBe(false);
			expect(processBCleanup.ownedProcessAliveAfterStop).toBe(false);
			expect(restartReceipt.processA.observation.targetOID).toBe(fixture.oracle.baseRef);
			expect(restartReceipt.processB.observation.targetOID).toBe(movedTargetOID);
			expect(restartReceipt.processB.observation.targetOID).not.toBe(
				restartReceipt.processA.observation.targetOID,
			);
			expect(restartReceipt.processB.observation.symbolicTargetLabel).toBe(
				restartReceipt.processA.observation.symbolicTargetLabel,
			);
			expect(restartReceipt.processB.observation.packageId).not.toBe(
				restartReceipt.processA.observation.packageId,
			);
		} finally {
			await browser.close();
			if (serverA !== null) await serverA.stop();
			if (serverB !== null) await serverB.stop();
			await fixture.dispose();
		}
	});
});

function assertJourneyFreshness(props: {
	readonly journeyObservations: Awaited<ReturnType<typeof runBridgeViewerProductOnlyJourney>>;
	readonly oracle: BridgeViewerViteProductProofFixtureOracle;
	readonly server: BridgeViewerOwnedViteProductServer;
}): void {
	expect(props.server.pid).toBeGreaterThan(0);
	expect(props.server.version).toMatch(/^\d+\.\d+\.\d+$/u);
	expect(new URL(props.journeyObservations.observedPageUrl).origin).toBe(props.server.origin);
	expect(props.journeyObservations.browser.name).toBe('chromium');
	expect(props.journeyObservations.fileMarkdownAtReviewFirstSwitch).toEqual(
		expect.objectContaining({
			canvasVisible: true,
			selectedDisplayPath: props.oracle.fileProofTargets.markdownPath,
			sourcePath: props.oracle.fileProofTargets.markdownPath,
		}),
	);
	const codeBodyPreviewSha256 = createHash('sha256')
		.update(props.oracle.fileProofCodeContent.slice(0, 160))
		.digest('hex');
	for (const fileState of [
		props.journeyObservations.fileAfterReviewFirstSwitch,
		props.journeyObservations.fileAfterFirstAcknowledgement,
		props.journeyObservations.fileAtCompletion,
	]) {
		expect(fileState.renderedDisplayPath).toBe(props.oracle.fileProofTargets.codePath);
		expect(fileState.bodyPreviewSha256).toBe(codeBodyPreviewSha256);
	}
	expect(props.journeyObservations.reviewFreshRoute.expectedItemIds).toEqual(
		props.oracle.expectedReviewItemIds,
	);
	expect(props.journeyObservations.reviewFreshRoute.observedHeaderItemIds).toEqual(
		props.oracle.expectedReviewItemIds,
	);
	expect(
		props.journeyObservations.reviewFreshRoute.hydrationMilestones.map(({ label }) => label),
	).toEqual(['initial', 'quarter', 'middle', 'threeQuarter', 'final']);
	expect(
		props.journeyObservations.workers.some((worker): boolean => worker.kind === 'comm-worker'),
	).toBe(true);
	expect(
		props.journeyObservations.productRouteTranscript.some(
			(entry): boolean => entry.contentKind === 'file.content' && entry.httpStatus === 200,
		),
	).toBe(true);
	expect(
		props.journeyObservations.productRouteTranscript.some(
			(entry): boolean => entry.contentKind === 'review.content' && entry.httpStatus === 200,
		),
	).toBe(true);
	expect(
		props.journeyObservations.productRouteTranscript.filter(
			(entry): boolean => entry.requestKind === 'content.acknowledge' && entry.httpStatus === 404,
		),
	).toHaveLength(0);
}

async function waitForSelectedFileReady(props: {
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
}): Promise<void> {
	await waitForSelectedFileContentReady({
		content: props.oracle.fileContent,
		oracle: props.oracle,
		page: props.page,
	});
}

async function waitForSelectedFileContentReady(props: {
	readonly content: BridgeViewerViteProductContentOracle;
	readonly oracle: BridgeViewerViteProductFixtureOracle;
	readonly page: Page;
}): Promise<void> {
	await props.page.waitForFunction(
		({ expectedLineCount, expectedSha256, path }): boolean => {
			const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			const painted = canvas?.querySelector(
				'diffs-container[data-bridge-painted-source-correlations]',
			);
			const correlations: unknown = JSON.parse(
				painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
			);
			return (
				canvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
				canvas.getAttribute('data-worktree-open-file-path') === path &&
				canvas.getAttribute('data-worktree-rendered-file-path') === path &&
				Number(canvas.getAttribute('data-worktree-rendered-line-count')) === expectedLineCount &&
				Array.isArray(correlations) &&
				correlations.some(
					(correlation): boolean =>
						typeof correlation === 'object' &&
						correlation !== null &&
						'observedSha256' in correlation &&
						correlation.observedSha256 === expectedSha256,
				)
			);
		},
		{
			expectedLineCount: props.content.lineCount,
			expectedSha256: props.content.sha256,
			path: props.oracle.largeFilePath,
		},
		{ timeout: productJourneyTimeoutMilliseconds },
	);
}

function observeProductContentRequests(page: Page): ProductContentRequestObservation[] {
	const observations: ProductContentRequestObservation[] = [];
	const observationByRequest = new WeakMap<Request, ProductContentRequestObservation>();
	page.on('request', (request): void => {
		if (
			request.method() !== 'POST' ||
			new URL(request.url()).pathname !== '/__bridge-product/content'
		) {
			return;
		}
		const body: unknown = request.postDataJSON();
		if (!isUnknownRecord(body) || !isUnknownRecord(body['descriptor'])) return;
		const contentKind = body['contentKind'];
		const contentRequestId = body['contentRequestId'];
		const leaseId = body['leaseId'];
		if (
			typeof contentKind !== 'string' ||
			typeof contentRequestId !== 'string' ||
			typeof leaseId !== 'string'
		) {
			return;
		}
		const observation: ProductContentRequestObservation = {
			contentKind,
			contentRequestId,
			descriptor: body['descriptor'],
			leaseId,
			responseStatus: null,
		};
		observations.push(observation);
		observationByRequest.set(request, observation);
	});
	page.on('response', (response): void => {
		const observation = observationByRequest.get(response.request());
		if (observation !== undefined) observation.responseStatus = response.status();
	});
	return observations;
}

async function collapseAndExpandReviewDirectory(page: Page): Promise<void> {
	const directoryPathHandle = await page.waitForFunction(
		(): string | null => {
			const host = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			const root = host?.shadowRoot;
			if (root === undefined || root === null) return null;
			return (
				root.querySelector('[data-item-path][aria-expanded]')?.getAttribute('data-item-path') ??
				null
			);
		},
		null,
		{ timeout: productJourneyTimeoutMilliseconds },
	);
	const directoryPath: unknown = await directoryPathHandle.jsonValue();
	if (typeof directoryPath !== 'string') throw new Error('Review directory path missing.');
	const initialExpanded = await page.evaluate((path): boolean => {
		const host = document.querySelector(
			'[data-testid="bridge-review-trees-panel"] file-tree-container',
		);
		return (
			host?.shadowRoot
				?.querySelector(`[data-item-path="${CSS.escape(path)}"][aria-expanded]`)
				?.getAttribute('aria-expanded') === 'true'
		);
	}, directoryPath);
	if (!initialExpanded) {
		await clickReviewDirectory({ directoryPath, page });
		await waitForReviewDirectoryDisclosure({ directoryPath, expectedExpanded: true, page });
	}
	for (const expectedExpanded of [false, true]) {
		// oxlint-disable-next-line no-await-in-loop -- Collapse and expand are distinct user-observed transitions.
		await clickReviewDirectory({ directoryPath, page });
		// oxlint-disable-next-line no-await-in-loop -- The tree exposes its disclosure transition through aria-expanded.
		await waitForReviewDirectoryDisclosure({ directoryPath, expectedExpanded, page });
	}
}

async function clickReviewDirectory(props: {
	readonly directoryPath: string;
	readonly page: Page;
}): Promise<void> {
	await props.page.evaluate((path): void => {
		const host = document.querySelector(
			'[data-testid="bridge-review-trees-panel"] file-tree-container',
		);
		const row = host?.shadowRoot?.querySelector(
			`[data-item-path="${CSS.escape(path)}"][aria-expanded]`,
		);
		if (!(row instanceof HTMLElement)) throw new Error('Review directory row missing.');
		row.click();
	}, props.directoryPath);
}

async function waitForReviewDirectoryDisclosure(props: {
	readonly directoryPath: string;
	readonly expectedExpanded: boolean;
	readonly page: Page;
}): Promise<void> {
	await props.page.waitForFunction(
		({ directoryPath, expectedExpanded }): boolean => {
			const host = document.querySelector(
				'[data-testid="bridge-review-trees-panel"] file-tree-container',
			);
			return (
				host?.shadowRoot
					?.querySelector(`[data-item-path="${CSS.escape(directoryPath)}"][aria-expanded]`)
					?.getAttribute('aria-expanded') === String(expectedExpanded)
			);
		},
		{ directoryPath: props.directoryPath, expectedExpanded: props.expectedExpanded },
		{ timeout: productJourneyTimeoutMilliseconds },
	);
}

function readFileDescriptorRootRevisionToken(
	descriptor: Readonly<Record<string, unknown>> | undefined,
): string | null {
	const source = descriptor?.['source'];
	return isUnknownRecord(source) && typeof source['rootRevisionToken'] === 'string'
		? source['rootRevisionToken']
		: null;
}

async function selectReviewFileAndReadObservation(props: {
	readonly page: Page;
	readonly reviewFile: BridgeViewerViteProductReviewFileOracle;
}): Promise<ReviewSelectionObservation> {
	await props.page.evaluate((path: string): void => {
		const host = document.querySelector(
			'[data-testid="bridge-review-trees-panel"] file-tree-container',
		);
		const row = host?.shadowRoot?.querySelector(`[data-item-path="${CSS.escape(path)}"]`);
		if (!(row instanceof HTMLElement)) throw new Error(`Review file row missing: ${path}`);
		row.click();
	}, props.reviewFile.path);
	const snapshotHandle = await props.page.waitForFunction(
		(itemId: string): ReviewSelectionBrowserSnapshot | null => {
			const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
			if (panel?.getAttribute('data-selected-item-id') !== itemId) return null;
			for (const host of queryAllOpenShadowRoots(panel, 'diffs-container')) {
				const marker =
					host.querySelector('[data-bridge-code-view-item-id]') ??
					host.shadowRoot?.querySelector('[data-bridge-code-view-item-id]');
				const correlations: unknown = JSON.parse(
					host.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
				);
				if (
					marker?.getAttribute('data-bridge-code-view-item-id') === itemId &&
					Array.isArray(correlations) &&
					correlations.length === 2 &&
					correlations.every(
						(correlation): boolean =>
							typeof correlation === 'object' &&
							correlation !== null &&
							'semanticItemId' in correlation &&
							correlation.semanticItemId === itemId,
					)
				) {
					return {
						bodyText: host.shadowRoot?.textContent ?? host.textContent ?? '',
						encodedCorrelations:
							host.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
						paintedPublicationId: host.getAttribute('data-bridge-painted-publication-id'),
					};
				}
			}
			return null;

			// oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright browser evaluation must carry this helper into the page realm.
			function queryAllOpenShadowRoots(root: Element, selector: string): Element[] {
				const matches: Element[] = [];
				const pending: Array<Element | ShadowRoot> = [root];
				while (pending.length > 0) {
					const current = pending.shift();
					if (current === undefined) break;
					matches.push(...current.querySelectorAll(selector));
					for (const descendant of current.querySelectorAll('*')) {
						if (descendant.shadowRoot !== null) pending.push(descendant.shadowRoot);
					}
				}
				return matches;
			}
		},
		props.reviewFile.itemId,
		{ timeout: productJourneyTimeoutMilliseconds },
	);
	const snapshot = await snapshotHandle.jsonValue();
	await snapshotHandle.dispose();
	if (snapshot === null) throw new Error(`Review painted host missing: ${props.reviewFile.itemId}`);
	return {
		bodyText: snapshot.bodyText,
		paintedCorrelations: decodePaintedSourceCorrelations(snapshot.encodedCorrelations),
		paintedPublicationId: snapshot.paintedPublicationId,
	};
}

function selectedReviewOracleFiles(
	reviewFiles: readonly BridgeViewerViteProductReviewFileOracle[],
): readonly BridgeViewerViteProductReviewFileOracle[] {
	const selectedIndexes = [0, Math.floor(reviewFiles.length / 2), reviewFiles.length - 1];
	return selectedIndexes.map((index): BridgeViewerViteProductReviewFileOracle => {
		const reviewFile = reviewFiles[index];
		if (reviewFile === undefined) throw new Error(`Review oracle missing at index ${index}.`);
		return reviewFile;
	});
}

function expectReviewBodyLinesPainted(paintedText: string, expectedBody: string): void {
	for (const expectedLine of expectedBody.split('\n').filter((line): boolean => line.length > 0)) {
		expect(paintedText).toContain(expectedLine);
	}
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function requireFixtureOracle(): BridgeViewerViteProductProofFixtureOracle {
	if (fixtureOracle === null) throw new Error('Vite product fixture was not initialized.');
	return fixtureOracle;
}

function requireOwnedServer(): BridgeViewerOwnedViteProductServer {
	if (ownedServer === null) throw new Error('Owned Vite product server was not initialized.');
	return ownedServer;
}
