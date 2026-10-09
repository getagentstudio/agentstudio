import type { Browser, Page, Response } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { verifyAnnotationOutputCaptures } from './bridge-viewer-vite-annotation-output-capture.ts';
import {
	runAnnotationSaveJourney,
	selectReviewFile,
	selectRangeForAnnotation,
	waitForCommittedAnnotationCommand,
	waitForSelectedFileReady,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { waitForProductCallSettlement } from './bridge-viewer-vite-product-operation-response.ts';
import {
	bridgeViewerViteProductFileUrl,
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';
import {
	observeBrowserRuntimeDiagnostics,
	waitForSettledReviewComparisonWithDiagnostics,
} from './bridge-viewer-vite-review-comparison-observation.ts';

const annotationRestartJourneyTimeoutMilliseconds = 120_000;
const annotationComposedConvergenceTimeoutMilliseconds = 30_000;

export function registerBridgeViewerViteAnnotationSystemJourneyTests(): void {
	test('restores distinct File and Review annotations after a cold Vite and Swift restart', async () => {
		const fixture = await createBridgeViewerViteProductFixture();
		let serverA: BridgeViewerOwnedViteProductServer | null = null;
		let serverB: BridgeViewerOwnedViteProductServer | null = null;
		let browser: Browser | null = null;
		let page: Page | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			serverA = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			const fileBeforeRestart = await runAnnotationSaveJourney({
				oracle: fixture.oracle,
				server: serverA,
				surface: 'file',
			});
			const reviewBeforeRestart = await runAnnotationSaveJourney({
				oracle: fixture.oracle,
				server: serverA,
				surface: 'review',
			});

			const backendPidA = serverA.backendPid;
			const cleanupA = await serverA.stop();
			expect(cleanupA.forcedTerminationRequired).toBe(false);
			expect(cleanupA.ownedProcessAliveAfterStop).toBe(false);
			serverA = null;

			serverB = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium();
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			await page.goto(
				bridgeViewerViteProductFileUrl(serverB.origin, fixture.oracle.largeFilePath),
				{
					timeout: annotationRestartJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			await waitForSelectedFileReady({ oracle: fixture.oracle, page });
			await page
				.getByText('File Save must settle from its exact command receipt.', { exact: true })
				.waitFor({ state: 'visible', timeout: annotationRestartJourneyTimeoutMilliseconds });
			const fileAfterRestart = await verifyAnnotationOutputCaptures({
				dataRootPath: fixture.oracle.dataRootPath,
				page,
				savedBody: 'File Save must settle from its exact command receipt.',
				timeoutMilliseconds: annotationComposedConvergenceTimeoutMilliseconds,
				worktreeRoot: fixture.oracle.worktreeRoot,
			});
			expect(fileAfterRestart).toEqual(fileBeforeRestart.outputIdentity);

			await page.goto(
				bridgeViewerViteProductReviewUrl(
					serverB.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					timeout: annotationRestartJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			const reviewOriginFile = fixture.oracle.reviewFiles[0];
			if (reviewOriginFile === undefined) {
				throw new Error('Restart journey requires a Review-origin file.');
			}
			await selectReviewFile({ page, path: reviewOriginFile.path });
			await waitForSelectedReviewReady({ itemId: reviewOriginFile.itemId, page });
			await page
				.getByText('Review Save must settle from its exact command receipt.', { exact: true })
				.waitFor({ state: 'visible', timeout: annotationComposedConvergenceTimeoutMilliseconds });
			const reviewAfterRestart = await verifyAnnotationOutputCaptures({
				dataRootPath: fixture.oracle.dataRootPath,
				page,
				savedBody: 'Review Save must settle from its exact command receipt.',
				timeoutMilliseconds: annotationComposedConvergenceTimeoutMilliseconds,
				worktreeRoot: fixture.oracle.worktreeRoot,
			});
			expect(reviewAfterRestart).toEqual(reviewBeforeRestart.outputIdentity);

			await page.goto(bridgeViewerViteProductFileUrl(serverB.origin, reviewOriginFile.path), {
				timeout: annotationRestartJourneyTimeoutMilliseconds,
				waitUntil: 'domcontentloaded',
			});
			await waitForFilePathReady({ page, path: reviewOriginFile.path });
			await page
				.getByText('Review Save must settle from its exact command receipt.', { exact: true })
				.waitFor({ state: 'visible', timeout: annotationComposedConvergenceTimeoutMilliseconds });
			expect(serverB.backendPid).not.toBe(backendPidA);
		} catch (error: unknown) {
			primaryFailure = { error };
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'cold-restart page',
						run: async (): Promise<void> => {
							await page?.close();
						},
					},
					{
						name: 'cold-restart browser',
						run: async (): Promise<void> => {
							await browser?.close();
						},
					},
					{
						name: 'cold-restart first product server',
						run: async (): Promise<void> => {
							if (serverA !== null) await stopOwnedProductServer(serverA);
						},
					},
					{
						name: 'cold-restart second product server',
						run: async (): Promise<void> => {
							if (serverB !== null) await stopOwnedProductServer(serverB);
						},
					},
					{ name: 'cold-restart fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
			});
		}
		// Named gap: this cold-stack journey does not prove a Swift-only restart while the
		// same Vite page and production comm worker reconnect. The current dev host recovers
		// backend health by reloading the document, which replaces that worker.
	});

	test('holds a promoted Review update for Apply now and auto-installs after focus leaves', async () => {
		const fixture = await createBridgeViewerViteProductFixture();
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let browser: Browser | null = null;
		let page: Page | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium();
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const runtimeDiagnostics = observeBrowserRuntimeDiagnostics(page);
			const annotationCommandTrace = observeReviewAnnotationCommandTrace(page);
			await page.goto(
				bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					timeout: annotationRestartJourneyTimeoutMilliseconds,
					waitUntil: 'domcontentloaded',
				},
			);
			const affectedFile = fixture.oracle.reviewFiles[0];
			const unaffectedFile = fixture.oracle.reviewFiles[1];
			if (affectedFile === undefined || unaffectedFile === undefined) {
				throw new Error('Promoted refresh journey requires two Review files.');
			}
			await selectReviewFile({ page, path: affectedFile.path });
			await waitForSelectedReviewReady({ itemId: affectedFile.itemId, page });
			const initialPackage = await requireReviewPackageIdentity(page);

			const firstAdvance = await fixture.advanceReviewedHeadByCommitCount(10);
			expect(firstAdvance.importedCommitCount).toBe(10);
			const promotedOutcome = await waitForPromotedReadyOrUnexpectedInstall({
				expectedTargetOID: firstAdvance.finalHeadOID,
				initialPackageId: initialPackage.packageId,
				page,
			});
			expect(promotedOutcome).toBe('updateReady');
			await page
				.getByText('Update ready', { exact: true })
				.waitFor({ state: 'visible', timeout: annotationComposedConvergenceTimeoutMilliseconds });
			const firstHeldCandidate = await waitForHeldCommitPromotionTelemetry({
				expectedReviewGeneration: initialPackage.reviewGeneration,
				page,
			});
			const heldPackage = await requireReviewPackageIdentity(page);
			if (
				heldPackage.packageId !== initialPackage.packageId ||
				heldPackage.reviewGeneration !== initialPackage.reviewGeneration
			) {
				throw new Error(
					`Promoted Review candidate was presented as held after display advanced: ${JSON.stringify(
						{
							heldPackage,
							initialPackage,
							refreshLifecycle: await reviewRefreshLifecycleDiagnostic(page),
							server: server.diagnostics(),
						},
					)}`,
				);
			}
			await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface: 'review' });
			const rootCreateCommitted = waitForCommittedAnnotationCommand(page, 'root.create', 'review');
			const savedDuringHoldBody = 'A new root comment saved while the promoted refresh was held.';
			await page
				.getByRole('textbox', { name: 'Write an annotation in Markdown' })
				.fill(savedDuringHoldBody);
			await rootCreateCommitted;
			await page
				.locator('[data-testid="worktree-annotation-message"][data-annotation-draft="present"]')
				.waitFor({
					state: 'visible',
					timeout: annotationComposedConvergenceTimeoutMilliseconds,
				});
			await page.waitForFunction(
				(): boolean => {
					const saveButton = document.querySelector<HTMLButtonElement>(
						'[aria-label="Save annotation"]',
					);
					return saveButton !== null && !saveButton.disabled;
				},
				undefined,
				{ timeout: annotationComposedConvergenceTimeoutMilliseconds },
			);
			const appliedReceiptResponse = waitForProductCallSettlement(
				page,
				isReviewPublicationAppliedResponse,
			);
			const applyNowButton = page.getByRole('button', { name: 'Apply now' });
			await expect
				.poll(async (): Promise<boolean> => applyNowButton.isEnabled(), {
					timeout: annotationComposedConvergenceTimeoutMilliseconds,
				})
				.toBe(true);
			await applyNowButton.press('Enter');
			requireCompletedReviewPublicationAppliedResponse((await appliedReceiptResponse).result);
			const appliedComparison = await waitForInstalledReviewPackage({
				expectedTargetLabel: 'HEAD',
				page,
				predecessor: initialPackage,
				timeoutMilliseconds: annotationRestartJourneyTimeoutMilliseconds,
			});
			expect(appliedComparison.packageId).toBe(initialPackage.packageId);
			expect(appliedComparison.reviewGeneration).toBe(firstHeldCandidate.reviewGeneration);
			expect(appliedComparison.revision).toBeGreaterThan(initialPackage.revision);
			await waitForSelectedReviewPathReady({ page, path: affectedFile.path });
			const retainedComposer = page.getByRole('textbox', {
				name: 'Write an annotation in Markdown',
			});
			try {
				await retainedComposer.waitFor({
					state: 'visible',
					timeout: annotationComposedConvergenceTimeoutMilliseconds,
				});
			} catch (error: unknown) {
				throw new Error(
					`Applied Review did not retain the active root composer: ${JSON.stringify({
						annotationDom: await annotationContinuityDomDiagnostic(page),
						annotationCommandTrace,
						refreshLifecycle: await reviewRefreshLifecycleDiagnostic(page),
						runtime: await runtimeDiagnostics.describe(),
						server: server.diagnostics(),
					})}`,
					{ cause: error },
				);
			}
			expect(await retainedComposer.inputValue()).toBe(savedDuringHoldBody);
			await page
				.locator('[data-testid="worktree-annotation-message"][data-annotation-draft="present"]')
				.waitFor({
					state: 'visible',
					timeout: annotationComposedConvergenceTimeoutMilliseconds,
				});
			const draftSaveCommitted = waitForCommittedAnnotationCommand(page, 'draft.save', 'review');
			try {
				await Promise.all([
					draftSaveCommitted,
					page.getByRole('button', { name: 'Save annotation' }).click(),
				]);
			} catch (error: unknown) {
				throw new Error(
					`Review draft save failed after apply: ${JSON.stringify({ annotationCommandTrace })}`,
					{ cause: error },
				);
			}
			expect(
				new Set(annotationCommandTrace.filter((kind) => kind.startsWith('draft.save@'))).size,
			).toBe(1);
			await page.getByText(savedDuringHoldBody, { exact: true }).waitFor({
				state: 'visible',
				timeout: annotationComposedConvergenceTimeoutMilliseconds,
			});
			await page.keyboard.press('Escape');
			await page
				.getByText('Update ready', { exact: true })
				.waitFor({ state: 'hidden', timeout: annotationRestartJourneyTimeoutMilliseconds });
			const verifiedAppliedComparison = await waitForSettledReviewComparisonWithDiagnostics({
				diagnostics: runtimeDiagnostics,
				expectedTargetLabel: 'HEAD',
				expectedTargetOID: firstAdvance.finalHeadOID,
				failureContext: (): string => server?.diagnostics() ?? 'server unavailable',
				page,
				timeoutMilliseconds: annotationRestartJourneyTimeoutMilliseconds,
			});
			expect(verifiedAppliedComparison.reviewGeneration).toBeGreaterThanOrEqual(
				appliedComparison.reviewGeneration,
			);

			const secondAdvance = await fixture.advanceReviewedHeadByCommitCount(10);
			expect(secondAdvance).toMatchObject({
				importedCommitCount: 10,
				previousHeadOID: firstAdvance.finalHeadOID,
			});
			const secondPromotedOutcome = await waitForPromotedReadyOrUnexpectedInstall({
				expectedTargetOID: secondAdvance.finalHeadOID,
				initialPackageId: verifiedAppliedComparison.packageId,
				page,
			});
			expect(secondPromotedOutcome).toBe('updateReady');
			await page
				.getByText('Update ready', { exact: true })
				.waitFor({ state: 'visible', timeout: annotationComposedConvergenceTimeoutMilliseconds });
			const secondHeldCandidate = await waitForHeldCommitPromotionTelemetry({
				expectedReviewGeneration: verifiedAppliedComparison.reviewGeneration,
				page,
			});
			await selectReviewFile({ page, path: unaffectedFile.path });
			await waitForSelectedReviewReady({ itemId: unaffectedFile.itemId, page });
			const automaticallyInstalledComparison = await waitForSettledReviewComparisonWithDiagnostics({
				diagnostics: runtimeDiagnostics,
				expectedTargetLabel: 'HEAD',
				expectedTargetOID: secondAdvance.finalHeadOID,
				failureContext: (): string => server?.diagnostics() ?? 'server unavailable',
				page,
				timeoutMilliseconds: annotationRestartJourneyTimeoutMilliseconds,
			});
			expect(automaticallyInstalledComparison.reviewGeneration).toBeGreaterThanOrEqual(
				secondHeldCandidate.reviewGeneration,
			);
			expect(await page.getByText('Update ready', { exact: true }).count()).toBe(0);
		} catch (error: unknown) {
			primaryFailure = { error };
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'promoted-refresh page',
						run: async (): Promise<void> => {
							await page?.close();
						},
					},
					{
						name: 'promoted-refresh browser',
						run: async (): Promise<void> => {
							await browser?.close();
						},
					},
					{
						name: 'promoted-refresh product server',
						run: async (): Promise<void> => {
							if (server !== null) await stopOwnedProductServer(server);
						},
					},
					{ name: 'promoted-refresh fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
			});
		}
	});
}

async function waitForInstalledReviewPackage(props: {
	readonly expectedTargetLabel: string;
	readonly page: Page;
	readonly predecessor: {
		readonly packageId: string;
		readonly reviewGeneration: number;
		readonly revision: number;
	};
	readonly timeoutMilliseconds: number;
}): Promise<{
	readonly packageId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
}> {
	let installedPackage = await requireReviewPackageIdentity(props.page);
	await expect
		.poll(
			async (): Promise<boolean> => {
				installedPackage = await requireReviewPackageIdentity(props.page);
				const targetLabel = await props.page
					.getByTestId('bridge-review-comparison-trigger')
					.textContent();
				return (
					installedPackage.packageId === props.predecessor.packageId &&
					installedPackage.reviewGeneration === props.predecessor.reviewGeneration &&
					installedPackage.revision > props.predecessor.revision &&
					targetLabel === props.expectedTargetLabel
				);
			},
			{ timeout: props.timeoutMilliseconds },
		)
		.toBe(true);
	return installedPackage;
}

function observeReviewAnnotationCommandTrace(page: Page): string[] {
	const operationKinds: string[] = [];
	page.on('request', (request): void => {
		if (new URL(request.url()).pathname !== '/__bridge-product/command') return;
		let body: unknown;
		try {
			body = request.postDataJSON();
		} catch {
			return;
		}
		if (!isUnknownRecord(body) || !isUnknownRecord(body['call'])) return;
		const call = body['call'];
		if (call['method'] !== 'review.annotations.command' || !isUnknownRecord(call['request'])) {
			return;
		}
		const operation = call['request']['operation'];
		if (!isUnknownRecord(operation) || typeof operation['kind'] !== 'string') return;
		operationKinds.push(`${operation['kind']}@${String(body['requestSequence'])}`);
	});
	return operationKinds;
}

function isUnknownRecord(value: unknown): value is Readonly<Record<string, unknown>> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

async function annotationContinuityDomDiagnostic(page: Page): Promise<unknown> {
	return await page.evaluate((): unknown => {
		const reviewShell = document.querySelector('[data-testid="review-viewer-shell"]');
		return {
			codePanelPresent: document.querySelector('[data-testid="bridge-code-view-panel"]') !== null,
			composerCount: document.querySelectorAll('[aria-label="Write an annotation in Markdown"]')
				.length,
			draftMessageCount: document.querySelectorAll(
				'[data-testid="worktree-annotation-message"][data-annotation-draft="present"]',
			).length,
			packageId: reviewShell?.getAttribute('data-review-metadata-id') ?? null,
			reviewGeneration: reviewShell?.getAttribute('data-review-metadata-generation') ?? null,
			threads: [...document.querySelectorAll('[data-testid="worktree-annotation-thread"]')].map(
				(thread) => ({
					placement: thread.getAttribute('data-annotation-placement'),
					threadId: thread.getAttribute('data-annotation-thread-id'),
				}),
			),
		};
	});
}

async function stopOwnedProductServer(server: BridgeViewerOwnedViteProductServer): Promise<void> {
	const cleanup = await server.stop();
	if (cleanup.forcedTerminationRequired || cleanup.ownedProcessAliveAfterStop) {
		throw new Error(`Owned product server cleanup failed: ${JSON.stringify(cleanup)}.`);
	}
}

async function waitForPromotedReadyOrUnexpectedInstall(props: {
	readonly expectedTargetOID: string;
	readonly initialPackageId: string;
	readonly page: Page;
}): Promise<'installedWithoutHold' | 'updateReady'> {
	const handle = await props.page.waitForFunction(
		({
			expectedTargetOID,
			initialPackageId,
		}: {
			readonly expectedTargetOID: string;
			readonly initialPackageId: string;
		}): 'installedWithoutHold' | 'updateReady' | false => {
			const updateReady = [...document.querySelectorAll('*')].some(
				(element): boolean => element.textContent?.trim() === 'Update ready',
			);
			if (updateReady) return 'updateReady';
			const packageId = document
				.querySelector('[data-testid="review-viewer-shell"]')
				?.getAttribute('data-review-metadata-id');
			const targetOID = document
				.querySelector('[data-testid="bridge-review-comparison-current-state"]')
				?.getAttribute('data-resolved-target-oid');
			return packageId !== null &&
				packageId !== undefined &&
				packageId !== initialPackageId &&
				targetOID === expectedTargetOID
				? 'installedWithoutHold'
				: false;
		},
		{ expectedTargetOID: props.expectedTargetOID, initialPackageId: props.initialPackageId },
		{ timeout: annotationComposedConvergenceTimeoutMilliseconds },
	);
	const outcome = await handle.jsonValue();
	if (outcome === false) throw new Error('Promoted Review produced neither a hold nor an install.');
	return outcome;
}

function isReviewPublicationAppliedResponse(response: Response): boolean {
	const request = response.request();
	if (
		request.method() !== 'POST' ||
		new URL(request.url()).pathname !== '/__bridge-product/command'
	) {
		return false;
	}
	const body: unknown = request.postDataJSON();
	if (typeof body !== 'object' || body === null || Reflect.get(body, 'kind') !== 'product.call') {
		return false;
	}
	const call = Reflect.get(body, 'call');
	return (
		typeof call === 'object' &&
		call !== null &&
		Reflect.get(call, 'method') === 'review.publication.applied'
	);
}

function requireCompletedReviewPublicationAppliedResponse(body: unknown): void {
	const call = typeof body === 'object' && body !== null ? Reflect.get(body, 'call') : null;
	if (
		typeof body !== 'object' ||
		body === null ||
		Reflect.get(body, 'kind') !== 'call.completed' ||
		typeof call !== 'object' ||
		call === null ||
		Reflect.get(call, 'method') !== 'review.publication.applied'
	) {
		throw new Error(`Review publication applied receipt did not complete: ${JSON.stringify(body)}`);
	}
}

async function waitForFilePathReady(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<void> {
	await props.page.waitForFunction(
		(path: string): boolean => {
			const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
			return (
				canvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
				canvas.getAttribute('data-worktree-open-file-path') === path &&
				canvas.getAttribute('data-worktree-rendered-file-path') === path
			);
		},
		props.path,
		{ timeout: annotationRestartJourneyTimeoutMilliseconds },
	);
}

async function waitForSelectedReviewPathReady(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<void> {
	await props.page.waitForFunction(
		(path: string): boolean => {
			const shell = document.querySelector('[data-testid="review-viewer-shell"]');
			return (
				shell?.getAttribute('data-selected-content-state') === 'ready' &&
				shell.getAttribute('data-selected-display-path') === path
			);
		},
		props.path,
		{ timeout: annotationRestartJourneyTimeoutMilliseconds },
	);
}

async function requireReviewPackageIdentity(page: Page): Promise<{
	readonly packageId: string;
	readonly reviewGeneration: number;
	readonly revision: number;
}> {
	const reviewShell = page.getByTestId('review-viewer-shell');
	const packageId = await reviewShell.getAttribute('data-review-metadata-id');
	const rawReviewGeneration = await reviewShell.getAttribute('data-review-metadata-generation');
	const rawRevision = await reviewShell.getAttribute('data-review-metadata-revision');
	const reviewGeneration = Number(rawReviewGeneration);
	const revision = Number(rawRevision);
	if (
		packageId === null ||
		packageId.length === 0 ||
		rawReviewGeneration === null ||
		rawRevision === null ||
		!Number.isSafeInteger(reviewGeneration) ||
		reviewGeneration < 0 ||
		!Number.isSafeInteger(revision) ||
		revision < 0
	) {
		throw new Error('Review shell did not expose its installed package identity.');
	}
	return { packageId, reviewGeneration, revision };
}

async function reviewRefreshLifecycleDiagnostic(
	page: Page,
): Promise<readonly Readonly<Record<string, unknown>>[]> {
	const statusUrl = new URL('/__bridge-dev-telemetry/status', page.url()).toString();
	const response = await fetch(statusUrl, { cache: 'no-store' });
	if (!response.ok) return [{ status: response.status }];
	const body: unknown = await response.json();
	if (typeof body !== 'object' || body === null) return [{ status: 'invalid-body' }];
	const recentSamples = Reflect.get(body, 'recentSamples');
	if (!Array.isArray(recentSamples)) return [{ status: 'missing-samples' }];
	return recentSamples
		.filter((sample): boolean => {
			if (typeof sample !== 'object' || sample === null) return false;
			return Reflect.get(sample, 'name') === 'performance.bridge.web.review_refresh_lifecycle';
		})
		.slice(-32)
		.map((sample): Readonly<Record<string, unknown>> => {
			const numericAttributes = Reflect.get(sample, 'numericAttributes');
			const stringAttributes = Reflect.get(sample, 'stringAttributes');
			return {
				generation:
					typeof numericAttributes === 'object' && numericAttributes !== null
						? Reflect.get(numericAttributes, 'agentstudio.bridge.review.generation')
						: null,
				phase:
					typeof stringAttributes === 'object' && stringAttributes !== null
						? Reflect.get(stringAttributes, 'agentstudio.bridge.phase')
						: null,
				presentationClass:
					typeof stringAttributes === 'object' && stringAttributes !== null
						? Reflect.get(stringAttributes, 'agentstudio.bridge.review.refresh.presentation_class')
						: null,
				promotionReason:
					typeof stringAttributes === 'object' && stringAttributes !== null
						? Reflect.get(stringAttributes, 'agentstudio.bridge.review.refresh.promotion_reason')
						: null,
				result:
					typeof stringAttributes === 'object' && stringAttributes !== null
						? Reflect.get(stringAttributes, 'agentstudio.bridge.review.refresh.result')
						: null,
				resultReason:
					typeof stringAttributes === 'object' && stringAttributes !== null
						? Reflect.get(stringAttributes, 'agentstudio.bridge.review.refresh.result_reason')
						: null,
			};
		});
}

async function waitForHeldCommitPromotionTelemetry(props: {
	readonly expectedReviewGeneration: number;
	readonly page: Page;
}): Promise<{ readonly reviewGeneration: number }> {
	const statusUrl = new URL('/__bridge-dev-telemetry/status', props.page.url()).toString();
	let observation: { readonly reviewGeneration: number } | null = null;
	try {
		await expect
			.poll(
				async (): Promise<boolean> => {
					const response = await fetch(statusUrl, { cache: 'no-store' });
					if (!response.ok) return false;
					const body: unknown = await response.json();
					if (typeof body !== 'object' || body === null || !('recentSamples' in body)) return false;
					const recentSamples = body.recentSamples;
					if (!Array.isArray(recentSamples)) return false;
					for (const sample of recentSamples.toReversed()) {
						if (typeof sample !== 'object' || sample === null) continue;
						const stringAttributes = Reflect.get(sample, 'stringAttributes');
						const numericAttributes = Reflect.get(sample, 'numericAttributes');
						if (
							typeof stringAttributes !== 'object' ||
							stringAttributes === null ||
							typeof numericAttributes !== 'object' ||
							numericAttributes === null ||
							Reflect.get(stringAttributes, 'agentstudio.bridge.phase') !==
								'review_refresh_candidate_held' ||
							Reflect.get(
								stringAttributes,
								'agentstudio.bridge.review.refresh.presentation_class',
							) !== 'promoted' ||
							Reflect.get(
								stringAttributes,
								'agentstudio.bridge.review.refresh.promotion_reason',
							) !== 'commits'
						) {
							continue;
						}
						const reviewGeneration = Reflect.get(
							numericAttributes,
							'agentstudio.bridge.review.generation',
						);
						if (
							typeof reviewGeneration === 'number' &&
							Number.isSafeInteger(reviewGeneration) &&
							reviewGeneration === props.expectedReviewGeneration
						) {
							observation = { reviewGeneration };
							return true;
						}
					}
					return false;
				},
				{ timeout: annotationComposedConvergenceTimeoutMilliseconds },
			)
			.toBe(true);
	} catch (error: unknown) {
		throw new Error(
			`Review candidate did not emit held commit-promotion telemetry: ${JSON.stringify(
				await reviewRefreshLifecycleDiagnostic(props.page),
			)}`,
			{ cause: error },
		);
	}
	if (observation === null) {
		throw new Error('Review candidate did not emit held commit-promotion telemetry.');
	}
	return observation;
}
