import { randomUUID } from 'node:crypto';

import type { Browser, Page } from 'playwright';
import { expect, onTestFailed, test } from 'vitest';

import {
	selectRangeForAnnotation,
	selectReviewFile,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import {
	bridgeViewerViteProductFileUrl,
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';

/**
 * This journey proves exactly one thing: against the real Swift backend, a comment the user saves is
 * persisted and is still there after a full document reload. The in-flight projection window — that a
 * committed comment stays visible while the authoritative projection is still arriving and the Saving
 * control clears — is proved in browser mode, where the test owns the projection
 * (worktree-annotation-ui-journey.browser.test.tsx, worktree-annotation-range-selection.browser.test.tsx).
 *
 * Every wait below is on owner-published state, and no wait carries a clock: the page's default
 * timeout is disabled, so the vitest hang bound in vitest.e2e.config.ts is the only clock in the test.
 */

const annotationThreadTestId = 'worktree-annotation-thread';

function cssAttributeValue(value: string): string {
	return JSON.stringify(value);
}

/**
 * File readiness is the File owner's published state: the code canvas names the open file and reports
 * it ready, and the render fulfillment coordinator stamps the container it actually painted.
 */
async function waitForFileSurfaceReady(props: {
	readonly page: Page;
	readonly path: string;
}): Promise<void> {
	const canvas = props.page.locator(
		`[data-testid="bridge-file-viewer-code-canvas"][data-worktree-open-file-state="ready"][data-worktree-open-file-path=${cssAttributeValue(props.path)}]`,
	);
	await canvas.waitFor({ state: 'attached' });
	await canvas
		.locator('diffs-container[data-bridge-painted-source-correlations]')
		.first()
		.waitFor({ state: 'attached' });
}

async function readFailureDiagnostic(page: Page | null): Promise<unknown> {
	if (page === null) return { page: 'never opened' };
	try {
		return {
			fileCanvas: await page
				.locator('[data-testid="bridge-file-viewer-code-canvas"]')
				.first()
				.evaluate((element: Element): unknown => ({
					openFilePath: element.getAttribute('data-worktree-open-file-path'),
					openFileState: element.getAttribute('data-worktree-open-file-state'),
				}))
				.catch((): null => null),
			reviewPanel: await page
				.locator('[data-testid="bridge-code-view-panel"]')
				.first()
				.evaluate((element: Element): unknown => ({
					selectedContentState: element.getAttribute('data-selected-content-state'),
					selectedItemId: element.getAttribute('data-selected-item-id'),
				}))
				.catch((): null => null),
			savingControlCount: await page.getByRole('button', { name: 'Saving annotation' }).count(),
			threadCount: await page.getByTestId(annotationThreadTestId).count(),
			url: page.url(),
		};
	} catch (error: unknown) {
		return { diagnosticError: error instanceof Error ? error.message : 'unknown' };
	}
}

test.each([
	['File', 'file'],
	['Review', 'review'],
] as const)(
	'persists a saved %s comment across a reload',
	async (_label, surface): Promise<void> => {
		let page: Page | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		onTestFailed(async (): Promise<void> => {
			console.error(
				`Annotation persistence journey (${surface}) failed: browser=${JSON.stringify(
					await readFailureDiagnostic(page),
				)} server=${server?.diagnostics() ?? 'no server'}`,
			);
		});

		// Arrange: this case owns its fixture, backend, and browser, so it starts with no annotation
		// session in existence and cannot inherit another attempt's state.
		const fixture = await createBridgeViewerViteProductFixture();
		let browser: Browser | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			const reviewFile = fixture.oracle.reviewFiles[0];
			if (surface === 'review' && reviewFile === undefined) {
				throw new Error('Review annotation persistence journey requires a changed review file.');
			}
			browser = await launchBridgeViewerE2EChromium();
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			// The vitest hang bound is the only clock this journey is allowed.
			page.setDefaultTimeout(0);
			page.setDefaultNavigationTimeout(0);
			await page.goto(
				surface === 'file'
					? bridgeViewerViteProductFileUrl(server.origin, fixture.oracle.largeFilePath)
					: bridgeViewerViteProductReviewUrl(
							server.origin,
							requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
						),
				{ waitUntil: 'domcontentloaded' },
			);
			if (surface === 'file') {
				await waitForFileSurfaceReady({ page, path: fixture.oracle.largeFilePath });
			} else {
				await selectReviewFile({ page, path: reviewFile?.path ?? '' });
				await waitForSelectedReviewReady({ itemId: reviewFile?.itemId ?? '', page });
			}
			expect(await page.getByTestId(annotationThreadTestId).count()).toBe(0);

			// Act: save one comment on a selected range.
			const savedBody = `Persisted ${surface} comment ${randomUUID()}`;
			await selectRangeForAnnotation({ endLine: 5, page, startLine: 2, surface });
			await page.getByRole('textbox', { name: 'Write an annotation in Markdown' }).fill(savedBody);
			await page.getByRole('button', { name: 'Save annotation' }).click();
			const savedThreadBody = page
				.getByTestId(annotationThreadTestId)
				.getByText(savedBody, { exact: true });
			await savedThreadBody.waitFor({ state: 'visible' });
			expect(await savedThreadBody.count()).toBe(1);
			// The committed body can be on screen while the Saving control is still up — browser mode
			// asserts exactly that window — so wait the control out instead of sampling for its absence.
			// This resolves immediately when the control is already gone.
			await page.getByRole('button', { name: 'Saving annotation' }).waitFor({ state: 'detached' });

			// Assert: the backend persisted it, so a brand new document still shows it exactly once.
			await page.reload({ waitUntil: 'domcontentloaded' });
			if (surface === 'file') {
				await waitForFileSurfaceReady({ page, path: fixture.oracle.largeFilePath });
			} else {
				await selectReviewFile({ page, path: reviewFile?.path ?? '' });
				await waitForSelectedReviewReady({ itemId: reviewFile?.itemId ?? '', page });
			}
			const reloadedThreadBody = page
				.getByTestId(annotationThreadTestId)
				.getByText(savedBody, { exact: true });
			await reloadedThreadBody.waitFor({ state: 'visible' });
			expect(await reloadedThreadBody.count()).toBe(1);
		} finally {
			await browser?.close();
			if (server !== null) {
				const cleanup = await server.stop();
				expect(cleanup.forcedTerminationRequired).toBe(false);
				expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
			}
			await fixture.dispose();
		}
	},
);
