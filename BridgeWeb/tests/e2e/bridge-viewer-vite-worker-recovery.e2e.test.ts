import type { Browser, Request, Response } from 'playwright';
import { expect, test } from 'vitest';

import { decodeBridgeProductDevBootstrapDelivery } from '../../src/core/comm-worker/bridge-product-dev-bootstrap.js';
import { bridgeProductAdmissionResponseSchema } from '../../src/core/comm-worker/bridge-product-operation-wire-contracts.js';
import {
	selectRangeForAnnotation,
	selectReviewFile,
	waitForCommittedAnnotationCommand,
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
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';
import {
	observeBrowserRuntimeDiagnostics,
	readBrowserDiagnosticWithinDeadline,
	waitForSettledReviewComparison,
} from './bridge-viewer-vite-review-comparison-observation.ts';
import {
	installReviewRenderObservation,
	readReviewRenderObservation,
} from './bridge-viewer-vite-review-render-observation.ts';

test.each(['proxy502', 'abortedDelivery'] as const)(
	'replaces the worker after exhausted installed receipts (%s) and installs the next Review revision',
	async (lostReplyMode) => {
		// Arrange — intercept only installed receipts; all source, metadata and content remain real.
		const fixture = await createBridgeViewerViteProductFixture();
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let browser: Browser | null = null;
		let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
		let rejectedReceiptCount = 0;
		const replayedAdmissionBodies: string[] = [];
		const replayedOperationIds: string[] = [];
		let phase = 'fixture-ready';
		const markPhase = (nextPhase: string): void => {
			phase = nextPhase;
			console.info('Installed-receipt recovery phase', phase);
		};
		try {
			markPhase('browser-starting');
			browser = await launchBridgeViewerE2EChromium();
			markPhase('server-starting');
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			diagnostics = observeBrowserRuntimeDiagnostics(page);
			const unchangedFile = fixture.oracle.reviewFiles[1];
			if (unchangedFile === undefined)
				throw new Error('Receipt recovery requires two Review files.');
			await installReviewRenderObservation({ itemId: unchangedFile.itemId, page });
			const initialBootstrap = page.waitForResponse(
				(response): boolean => isBootstrapResponse(response, 'initial'),
				{ timeout: 30_000 },
			);
			const admissionAttemptLimit = initialBootstrap.then(async (response): Promise<number> => {
				const bytes = Uint8Array.from(await response.body());
				return (
					decodeBridgeProductDevBootstrapDelivery(bytes.buffer).bootstrap.policy
						.admissionRetryCount + 1
				);
			});
			await page.route('**/__bridge-product/command', async (route): Promise<void> => {
				const body: unknown = route.request().postDataJSON();
				if (
					typeof body === 'object' &&
					body !== null &&
					'kind' in body &&
					body.kind === 'product.call' &&
					'call' in body &&
					typeof body.call === 'object' &&
					body.call !== null &&
					'method' in body.call &&
					body.call.method === 'review.publication.applied' &&
					rejectedReceiptCount < (await admissionAttemptLimit)
				) {
					const requestBytes = route.request().postDataBuffer();
					if (requestBytes === null) throw new Error('Installed receipt has no encoded body.');
					replayedAdmissionBodies.push(requestBytes.toString('base64'));
					const nativeAdmission = await route.fetch();
					expect(nativeAdmission.status()).toBe(200);
					const parsedAdmission = bridgeProductAdmissionResponseSchema.parse(
						await nativeAdmission.json(),
					);
					if (parsedAdmission.kind !== 'operation.admitted') {
						throw new Error('Native refused the intercepted installed receipt.');
					}
					replayedOperationIds.push(parsedAdmission.operationId);
					rejectedReceiptCount += 1;
					if (lostReplyMode === 'proxy502') {
						await route.fulfill({ body: '', contentType: 'text/plain', status: 502 });
					} else {
						await route.abort('failed');
					}
					return;
				}
				await route.continue();
			});
			const replacementBootstrap = page.waitForResponse(
				(response): boolean => isBootstrapResponse(response, 'workerReplacement'),
				{ timeout: 30_000 },
			);
			let mainFrameNavigationCount = 0;
			page.on('framenavigated', (frame): void => {
				if (frame === page.mainFrame()) mainFrameNavigationCount += 1;
			});

			// Act — native admits one receipt; the proxy loses each reply to the worker.
			markPhase('replacement-bootstrap-waiting');
			const [initialResponse, replacementResponse] = await Promise.all([
				initialBootstrap,
				replacementBootstrap,
				page.goto(
					bridgeViewerViteProductReviewUrl(
						server.origin,
						requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
					),
					{
						timeout: 120_000,
						waitUntil: 'domcontentloaded',
					},
				),
			]);
			expect(rejectedReceiptCount).toBe(await admissionAttemptLimit);
			expect(new Set(replayedAdmissionBodies).size).toBe(1);
			expect(new Set(replayedOperationIds).size).toBe(1);
			const successorWorkerInstanceId = await bootstrapWorkerInstanceId(replacementResponse);
			expect(successorWorkerInstanceId).not.toBe(await bootstrapWorkerInstanceId(initialResponse));
			markPhase('recovered-comparison-waiting');
			const recoveredComparison = await waitForSettledReviewComparison({
				expectedTargetLabel: 'HEAD',
				expectedTargetOID: fixture.oracle.baseRef,
				page,
				timeoutMilliseconds: 30_000,
			});
			markPhase('unchanged-file-selecting');
			await selectReviewFile({ page, path: unchangedFile.path });
			markPhase('unchanged-file-content-waiting');
			await waitForSelectedReviewReady({ itemId: unchangedFile.itemId, page });

			// Assert — a subsequent real mutation must advance displayed authority, not merely repaint.
			markPhase('source-mutation');
			const successorReceipt = waitForProductCallSettlement(page, (response): boolean => {
				const request = response.request();
				if (new URL(request.url()).pathname !== '/__bridge-product/command') return false;
				const body: unknown = request.postDataJSON();
				return (
					typeof body === 'object' &&
					body !== null &&
					'workerInstanceId' in body &&
					body.workerInstanceId === successorWorkerInstanceId &&
					'call' in body &&
					typeof body.call === 'object' &&
					body.call !== null &&
					'method' in body.call &&
					body.call.method === 'review.publication.applied'
				);
			});
			await fixture.mutateReviewFile();
			markPhase('successor-revision-waiting');
			await expect
				.poll(
					async (): Promise<number> =>
						Number(
							await page
								.getByTestId('review-viewer-shell')
								.getAttribute('data-review-metadata-revision'),
						),
					{ timeout: 30_000 },
				)
				.toBeGreaterThan(recoveredComparison.revision);
			markPhase('successor-content-waiting');
			await waitForSelectedReviewReady({ itemId: unchangedFile.itemId, page });
			const successorApplied = await successorReceipt;
			expect(successorApplied.result).toMatchObject({
				kind: 'call.completed',
				call: { method: 'review.publication.applied' },
			});
			expect(mainFrameNavigationCount).toBe(1);
			expect(rejectedReceiptCount).toBe(await admissionAttemptLimit);
			markPhase('verified');
		} catch (error: unknown) {
			const activePage = browser?.contexts()[0]?.pages()[0];
			const renderObservation =
				activePage === undefined
					? null
					: await readBrowserDiagnosticWithinDeadline(readReviewRenderObservation(activePage));
			const selectionObservation =
				activePage === undefined
					? null
					: await readBrowserDiagnosticWithinDeadline(
							activePage.evaluate(() => {
								const panel = document.querySelector('[data-testid="bridge-code-view-panel"]');
								const shell = document.querySelector('[data-testid="review-viewer-shell"]');
								const attributes = (element: Element | null): Record<string, string> =>
									Object.fromEntries(
										[...(element?.attributes ?? [])]
											.filter((attribute) => attribute.name.startsWith('data-'))
											.map((attribute) => [attribute.name, attribute.value]),
									);
								return {
									panel: attributes(panel),
									panelText: panel?.textContent?.slice(0, 300) ?? null,
									shell: attributes(shell),
									workerSession: Reflect.get(
										window,
										'__bridgeReviewSelectionDiagnostic',
									) as unknown,
								};
							}),
						);
			throw new Error(
				`Installed-receipt recovery failed at ${phase}. Rejected: ${rejectedReceiptCount}. Render: ${JSON.stringify(renderObservation)}. Selection: ${JSON.stringify(selectionObservation)}. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
				{ cause: error },
			);
		} finally {
			markPhase('cleanup-browser');
			try {
				await browser?.close();
			} finally {
				try {
					if (server !== null) {
						markPhase('cleanup-server');
						const cleanup = await server.stop();
						expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
						expect(cleanup.forcedTerminationRequired).toBe(false);
					}
				} finally {
					await fixture.dispose();
				}
			}
		}
	},
);

test('reclaims a durable Review draft after worker failure and one unavailable replacement bootstrap', async () => {
	// Arrange — real Vite, Swift, comm worker, metadata and content establish a usable Review.
	const fixture = await createBridgeViewerViteProductFixture();
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let browser: Browser | null = null;
	try {
		browser = await launchBridgeViewerE2EChromium();
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		const reviewFile = fixture.oracle.reviewFiles[0];
		if (reviewFile === undefined) throw new Error('Worker recovery requires a real Review file.');
		let rejectedReplacementCount = 0;
		await page.route('**/__bridge-product/bootstrap', async (route): Promise<void> => {
			if (
				bootstrapReason(route.request()) === 'workerReplacement' &&
				rejectedReplacementCount === 0
			) {
				rejectedReplacementCount += 1;
				await route.fulfill({ body: '', contentType: 'text/plain', status: 502 });
				return;
			}
			await route.continue();
		});
		const initialBootstrapResponse = page.waitForResponse(
			(response): boolean => isBootstrapResponse(response, 'initial'),
			{ timeout: 30_000 },
		);
		const [initialResponse] = await Promise.all([
			initialBootstrapResponse,
			page.goto(
				bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					timeout: 120_000,
					waitUntil: 'domcontentloaded',
				},
			),
		]);
		const initialWorkerInstanceId = await bootstrapWorkerInstanceId(initialResponse);
		await selectReviewFile({ page, path: reviewFile.path });
		await waitForSelectedReviewReady({ itemId: reviewFile.itemId, page });
		await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface: 'review' });
		const draftBody = 'Durable draft remains reclaimable after worker replacement.';
		const draftCreated = waitForCommittedAnnotationCommand(page, 'root.create', 'review');
		await Promise.all([
			draftCreated,
			page.getByRole('textbox', { name: 'Write an annotation in Markdown' }).fill(draftBody),
		]);
		await page
			.locator('[data-testid="worktree-annotation-message"][data-annotation-draft="present"]')
			.waitFor({ state: 'visible', timeout: 30_000 });
		const worker = page
			.workers()
			.find((candidate) => candidate.url().includes('bridge-comm-worker-vite-entry.ts'));
		if (worker === undefined) throw new Error('The real pane comm worker was not created.');

		// Act — an uncaught worker error retires the worker; one proxy failure interrupts replacement.
		const unavailableReplacement = page.waitForResponse(
			(response): boolean =>
				isBootstrapResponse(response, 'workerReplacement') && response.status() === 502,
			{ timeout: 30_000 },
		);
		const freshBootstrapResponse = page.waitForResponse(
			(response): boolean => isBootstrapResponse(response, 'initial'),
			{ timeout: 30_000 },
		);
		const pageReload = page.waitForEvent('framenavigated', {
			predicate: (frame): boolean => frame === page.mainFrame(),
			timeout: 30_000,
		});
		const [, , freshResponse] = await Promise.all([
			unavailableReplacement,
			pageReload,
			freshBootstrapResponse,
			worker.evaluate((): void => {
				queueMicrotask((): never => {
					throw new Error('Controlled comm-worker failure for replacement recovery proof.');
				});
			}),
		]);

		// Assert — real backend authority changed and the requested Review is usable again.
		expect(rejectedReplacementCount).toBe(1);
		expect(await bootstrapWorkerInstanceId(freshResponse)).not.toBe(initialWorkerInstanceId);
		await selectReviewFile({ page, path: reviewFile.path });
		await waitForSelectedReviewReady({ itemId: reviewFile.itemId, page });
		const restoredDraft = page.getByText(draftBody, { exact: true });
		await restoredDraft.waitFor({ state: 'visible', timeout: 30_000 });

		// Act — reclaim the persisted draft through the replacement worker and save an edit.
		await page.getByRole('button', { name: 'Edit annotation', exact: true }).click();
		const savedBody = `${draftBody} Saved by the replacement worker.`;
		await page.getByRole('textbox', { name: 'Annotation Markdown', exact: true }).fill(savedBody);
		const saved = waitForCommittedAnnotationCommand(page, 'draft.save', 'review');
		await Promise.all([
			saved,
			page.getByRole('button', { name: 'Save annotation', exact: true }).click(),
		]);

		// Assert — a new committed mutation proves the old worker no longer owns the draft.
		await page.getByText(savedBody, { exact: true }).waitFor({ state: 'visible', timeout: 30_000 });
	} catch (error) {
		throw new Error(
			`Worker replacement journey failed. Backend: ${server?.diagnostics() ?? 'not started'}`,
			{
				cause: error,
			},
		);
	} finally {
		try {
			await browser?.close();
		} finally {
			try {
				if (server !== null) {
					const cleanup = await server.stop();
					expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
					expect(cleanup.forcedTerminationRequired).toBe(false);
				}
			} finally {
				await fixture.dispose();
			}
		}
	}
});

test('re-establishes annotation demand after an in-place worker replacement so Copy is enabled without reload', async () => {
	// Arrange — a saved Review annotation makes the drawer's output controls usable.
	const fixture = await createBridgeViewerViteProductFixture();
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let browser: Browser | null = null;
	let phase = 'fixture-ready';
	try {
		browser = await launchBridgeViewerE2EChromium();
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		const reviewFile = fixture.oracle.reviewFiles[0];
		if (reviewFile === undefined) throw new Error('Demand replay requires a real Review file.');
		page.setDefaultTimeout(0);
		page.setDefaultNavigationTimeout(0);
		let mainFrameNavigationCount = 0;
		page.on('framenavigated', (frame): void => {
			if (frame === page.mainFrame()) mainFrameNavigationCount += 1;
		});
		const initialBootstrapResponse = page.waitForResponse((response): boolean =>
			isBootstrapResponse(response, 'initial'),
		);
		const [initialResponse] = await Promise.all([
			initialBootstrapResponse,
			page.goto(
				bridgeViewerViteProductReviewUrl(
					server.origin,
					requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
				),
				{
					waitUntil: 'domcontentloaded',
				},
			),
		]);
		phase = 'review-ready';
		await selectReviewFile({ page, path: reviewFile.path });
		await waitForSelectedReviewReady({ itemId: reviewFile.itemId, page });
		await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface: 'review' });
		const savedBody = 'Saved annotation stays shareable across an in-place worker replacement.';
		phase = 'annotation-saving';
		const draftCreated = waitForCommittedAnnotationCommand(page, 'root.create', 'review');
		await Promise.all([
			draftCreated,
			page.getByRole('textbox', { name: 'Write an annotation in Markdown' }).fill(savedBody),
		]);
		const saveButton = page.getByRole('button', { name: 'Save annotation', exact: true });
		const saved = waitForCommittedAnnotationCommand(page, 'draft.save', 'review');
		await Promise.all([saved, saveButton.click()]);
		await page.getByText(savedBody, { exact: true }).waitFor({ state: 'visible' });
		const worker = page
			.workers()
			.find((candidate) => candidate.url().includes('bridge-comm-worker-vite-entry.ts'));
		if (worker === undefined) throw new Error('The real pane comm worker was not created.');

		// Act — an uncaught worker error retires the worker; native answers the replacement in place.
		phase = 'worker-replacing';
		const replacementBootstrap = page.waitForResponse((response): boolean =>
			isBootstrapResponse(response, 'workerReplacement'),
		);
		const [replacementResponse] = await Promise.all([
			replacementBootstrap,
			worker.evaluate((): void => {
				queueMicrotask((): never => {
					throw new Error('Controlled comm-worker failure for annotation demand replay proof.');
				});
			}),
		]);
		expect(await bootstrapWorkerInstanceId(replacementResponse)).not.toBe(
			await bootstrapWorkerInstanceId(initialResponse),
		);

		// Assert — without a reload, the replacement worker holds the session demand again.
		phase = 'output-controls-waiting';
		await page.getByRole('button', { name: 'Annotations', exact: true }).click();
		const copyButton = page.getByRole('button', { name: 'Copy Markdown' });
		await page.locator('button[aria-label="Copy Markdown"]:not(:disabled)').waitFor({
			state: 'visible',
		});
		expect(await copyButton.isEnabled()).toBe(true);
		expect(mainFrameNavigationCount).toBe(1);
	} catch (error) {
		throw new Error(
			`Annotation demand replay journey failed at ${phase}. Backend: ${server?.diagnostics() ?? 'not started'}`,
			{ cause: error },
		);
	} finally {
		try {
			await browser?.close();
		} finally {
			try {
				if (server !== null) {
					const cleanup = await server.stop();
					expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
					expect(cleanup.forcedTerminationRequired).toBe(false);
				}
			} finally {
				await fixture.dispose();
			}
		}
	}
});

function bootstrapReason(request: Request): string | null {
	const body: unknown = request.postDataJSON();
	return typeof body === 'object' &&
		body !== null &&
		'reason' in body &&
		typeof body.reason === 'string'
		? body.reason
		: null;
}

function isBootstrapResponse(response: Response, reason: string): boolean {
	return (
		new URL(response.url()).pathname === '/__bridge-product/bootstrap' &&
		bootstrapReason(response.request()) === reason
	);
}

async function bootstrapWorkerInstanceId(response: Response): Promise<string> {
	expect(response.status()).toBe(200);
	const bytes = Uint8Array.from(await response.body());
	return decodeBridgeProductDevBootstrapDelivery(bytes.buffer).bootstrap.workerInstanceId;
}
