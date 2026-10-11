import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import {
	selectReviewFile,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { createBridgeViewerExplorationFixture } from './bridge-viewer-vite-exploration-fixture.ts';
import {
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import {
	observeBrowserRuntimeDiagnostics,
	type BrowserRuntimeDiagnostics,
} from './bridge-viewer-vite-review-comparison-observation.ts';

test.each(['mode round-trip', 'content refresh'] as const)(
	'retains the selected Markdown scroll position after a %s',
	async (transition): Promise<void> => {
		// Arrange — the existing long Markdown/Mermaid fixture and real Vite/Swift route.
		const fixture = await createBridgeViewerExplorationFixture();
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let diagnostics: BrowserRuntimeDiagnostics | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium();
			const page = await browser.newPage({ viewport: { width: 1728, height: 980 } });
			// The vitest hang bound is the only clock this journey is allowed.
			diagnostics = observeBrowserRuntimeDiagnostics(page);
			await page.goto(bridgeViewerViteProductFileUrl(server.origin, 'docs/guide.md'), {
				waitUntil: 'domcontentloaded',
			});
			await waitForGuideRevision(page, 1);
			const initialScrollTop = await page
				.getByTestId('bridge-markdown-canvas')
				.evaluate((article): number => {
					const owner = article.closest('.bridge-scrollbar');
					if (!(owner instanceof HTMLElement)) throw new Error('Markdown scroll owner missing.');
					owner.scrollTop = Math.min(900, owner.scrollHeight - owner.clientHeight);
					owner.dispatchEvent(new Event('scroll', { bubbles: true }));
					return owner.scrollTop;
				});
			expect(initialScrollTop).toBeGreaterThan(0);

			// Act — no reselection, scroll restoration, reload, or second action in the test.
			if (transition === 'mode round-trip') {
				await page
					.getByTestId('bridge-viewer-mode-host-file')
					.getByRole('button', { name: 'Review', exact: true })
					.click();
				const reviewFile = fixture.oracle.reviewFiles[0];
				if (reviewFile === undefined) throw new Error('Fixture requires a Review file.');
				await selectReviewFile({ page, path: reviewFile.path });
				await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
				await page
					.getByTestId('bridge-viewer-mode-host-review')
					.getByRole('button', { name: 'Files', exact: true })
					.click();
			} else {
				await fixture.editMarkdown();
			}

			// Assert — exact document revision and diagrams are ready at the reader's prior offset.
			await waitForGuideRevision(page, transition === 'content refresh' ? 2 : 1);
			const finalScrollTop = await page
				.getByTestId('bridge-markdown-canvas')
				.evaluate(
					(article): number | null => article.closest('.bridge-scrollbar')?.scrollTop ?? null,
				);
			expect(finalScrollTop).not.toBeNull();
			expect(
				Math.abs((finalScrollTop ?? -1) - initialScrollTop),
				JSON.stringify({ transition, initialScrollTop, finalScrollTop }),
			).toBeLessThanOrEqual(1);
		} catch (error: unknown) {
			primaryFailure = {
				error: new Error(
					`Markdown ${transition} scroll retention failed. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
					{ cause: error },
				),
			};
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
							expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
							expect(cleanup.forcedTerminationRequired).toBe(false);
						},
					},
					{ name: 'fixture', run: fixture.dispose },
				],
				...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
			});
		}
	},
);

async function waitForGuideRevision(page: Page, revision: number): Promise<void> {
	await page.waitForFunction(guideRevisionIsReady, revision);
	// Do not accept the retained article in the frame before activation effects run.
	await page.evaluate(async (): Promise<void> => {
		await new Promise<void>((resolve): void => {
			requestAnimationFrame((): void => {
				requestAnimationFrame((): void => resolve());
			});
		});
	});
	await page.waitForFunction(guideRevisionIsReady, revision);
}

function guideRevisionIsReady(expectedRevision: number): boolean {
	const host = document.querySelector('[data-testid="bridge-viewer-mode-host-file"]');
	const article = host?.querySelector('[data-testid="bridge-markdown-canvas"]');
	return (
		host?.getAttribute('data-bridge-viewer-mode-active') === 'true' &&
		article?.getAttribute('data-bridge-markdown-source-path') === 'docs/guide.md' &&
		(article.textContent?.includes(`Document revision ${expectedRevision}.`) ?? false) &&
		article.querySelector('[data-bridge-mermaid-state="ready"] svg') !== null
	);
}
