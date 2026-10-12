import type { Browser } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { bridgeProductControlRequestSchema } from '../../src/core/comm-worker/bridge-product-session-contracts.js';
import {
	selectReviewFile,
	waitForSelectedReviewReady,
} from './bridge-viewer-vite-annotation-save-journey.ts';
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

test('activates Review after a File-only bootstrap and returns to the selected Markdown document', async (context): Promise<void> => {
	return await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
		// Arrange — one browser page, native pane, and disposable filesystem for this journey.
		const fixture = await createBridgeViewerExplorationFixture();
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
		let failures: Awaited<ReturnType<typeof observeInteractionProfileFailures>> | null = null;
		const modeRequests: Array<{
			readonly method: string;
			readonly requestSequence: number;
			readonly workerDerivationEpoch: number;
		}> = [];
		let primaryFailure: { readonly error: unknown } | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage({ viewport: { width: 1728, height: 980 } });
			diagnostics = observeBrowserRuntimeDiagnostics(page);
			failures = await observeInteractionProfileFailures(page);
			page.on('request', (request): void => {
				if (new URL(request.url()).pathname !== '/__bridge-product/command') return;
				const parsed = bridgeProductControlRequestSchema.safeParse(request.postDataJSON());
				if (
					!parsed.success ||
					parsed.data.kind !== 'product.call' ||
					!parsed.data.call.method.endsWith('.activeViewerMode.update')
				)
					return;
				modeRequests.push({
					method: parsed.data.call.method,
					requestSequence: parsed.data.requestSequence,
					workerDerivationEpoch: parsed.data.workerDerivationEpoch,
				});
			});
			await page.goto(bridgeViewerViteProductFileUrl(server.origin, 'README.md'), {
				waitUntil: 'domcontentloaded',
			});
			const fileHost = page.getByTestId('bridge-viewer-mode-host-file');
			await fileHost
				.getByRole('heading', { name: 'Exploration README.md', exact: true })
				.waitFor({ state: 'visible' });

			// Act — use the existing visible mode action, never a bootstrap/replacement call.
			await fileHost.getByRole('button', { name: 'Review', exact: true }).click();
			const reviewFile = fixture.oracle.reviewFiles[0];
			if (reviewFile === undefined)
				throw new Error('Review activation fixture requires one changed file.');
			await selectReviewFile({ page, path: reviewFile.path });

			// Assert — real Review content renders, then the retained File selection remains usable.
			await waitForSelectedReviewReady({ page, itemId: reviewFile.itemId });
			expect(
				modeRequests.some(
					(request): boolean => request.method === 'review.activeViewerMode.update',
				),
			).toBe(true);
			await page
				.getByTestId('bridge-viewer-mode-host-review')
				.getByRole('button', { name: 'Files', exact: true })
				.click();
			await fileHost
				.getByRole('heading', { name: 'Exploration README.md', exact: true })
				.waitFor({ state: 'visible' });
		} catch (error: unknown) {
			primaryFailure = {
				error: new Error(
					`File-to-Review activation failed. Mode requests: ${JSON.stringify(modeRequests)}. Failures: ${JSON.stringify(await failures?.read())}. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
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
});
