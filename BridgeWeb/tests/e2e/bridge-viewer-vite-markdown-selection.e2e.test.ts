import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { waitForSelectedFileReady } from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { createBridgeViewerExplorationFixture } from './bridge-viewer-vite-exploration-fixture.ts';
import { observeInteractionProfileFailures } from './bridge-viewer-vite-interaction-profile-diagnostics.ts';
import {
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import { observeBrowserRuntimeDiagnostics } from './bridge-viewer-vite-review-comparison-observation.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

test.for(['Markdown', 'code'] as const)(
	'renders a second %s file after a completed Markdown and Mermaid document',
	async (targetKind, bridgeWebTestContext): Promise<void> => {
		return await runBridgeWebE2ETestBody(bridgeWebTestContext, async (): Promise<void> => {
			// Arrange — this is the two-click failure independently observed through Chrome CUA.
			const fixture = await createBridgeViewerExplorationFixture();
			let server: BridgeViewerOwnedViteProductServer | null = null;
			let browser: Browser | null = null;
			let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
			let failures: Awaited<ReturnType<typeof observeInteractionProfileFailures>> | null = null;
			let primaryFailure: { readonly error: unknown } | null = null;
			try {
				server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
				browser = await launchBridgeViewerE2EChromium();
				const page = await browser.newPage({ viewport: { width: 1728, height: 980 } });
				// The vitest hang bound is the only clock this journey is allowed.
				page.setDefaultTimeout(0);
				page.setDefaultNavigationTimeout(0);
				diagnostics = observeBrowserRuntimeDiagnostics(page);
				failures = await observeInteractionProfileFailures(page);
				await page.goto(bridgeViewerViteProductFileUrl(server.origin, 'README.md'), {
					waitUntil: 'domcontentloaded',
				});
				await waitForMarkdownDocument(page, 'README.md');
				const nextPath =
					targetKind === 'Markdown' ? 'docs/diagram.md' : fixture.oracle.largeFilePath;
				if (targetKind === 'code') {
					await page
						.locator(
							'[data-testid="bridge-file-viewer-pierre-file-tree"] [data-file-tree-virtualized-scroll="true"]',
						)
						.evaluate((scrollOwner: HTMLElement): void => {
							scrollOwner.scrollTop = scrollOwner.scrollHeight;
							scrollOwner.dispatchEvent(new Event('scroll', { bubbles: true }));
						});
				}

				// Act — select one discovered target; do not rebootstrap or reselect.
				await page
					.getByTestId('bridge-viewer-mode-host-file')
					.locator(`[data-item-path="${nextPath}"]`)
					.click();

				// Assert — the selected renderer completes the exact new target.
				if (targetKind === 'Markdown') await waitForMarkdownDocument(page, nextPath);
				else await waitForSelectedFileReady({ oracle: fixture.oracle, page });
			} catch (error: unknown) {
				primaryFailure = {
					error: new Error(
						`Second ${targetKind} selection failed. Failures: ${JSON.stringify(await failures?.read())}. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
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
		});
	},
);

async function waitForMarkdownDocument(page: Page, path: string): Promise<void> {
	await page.waitForFunction((expectedPath: string): boolean => {
		const canvas = document.querySelector('[data-testid="bridge-markdown-canvas"]');
		return (
			canvas?.querySelector('h1')?.textContent === `Exploration ${expectedPath}` &&
			canvas.querySelector('[data-bridge-mermaid-state="ready"] svg') !== null
		);
	}, path);
}
