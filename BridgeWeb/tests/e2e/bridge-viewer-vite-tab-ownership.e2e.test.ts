import type { Browser } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import {
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
	bridgeViewerViteProductReviewUrl,
	requireBridgeViewerVitePrimaryReviewPath,
} from './bridge-viewer-vite-product-url.ts';

test.each(['shared-profile', 'separate-profile'] as const)(
	'development tabs show open elsewhere until the active tab closes (%s)',
	async (profileTopology): Promise<void> => {
		// Arrange: shared or isolated browser storage against one real isolated Swift backend.
		const fixture = await createBridgeViewerViteProductFixture();
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let primaryError: unknown;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium();
			const context = await browser.newContext({ viewport: { width: 1728, height: 980 } });
			// The vitest hang bound is the only clock this journey is allowed.
			context.setDefaultTimeout(0);
			context.setDefaultNavigationTimeout(0);
			const pageErrors: string[] = [];
			context.on('page', (createdPage): void => {
				createdPage.on('pageerror', (error): void => {
					pageErrors.push(error.message);
				});
			});
			const firstTab = await context.newPage();
			let firstBootstrapCount = 0;
			firstTab.on('request', (request): void => {
				if (new URL(request.url()).pathname === '/__bridge-product/bootstrap')
					firstBootstrapCount += 1;
			});
			const reviewFile = fixture.oracle.reviewFiles[0];
			if (reviewFile === undefined) throw new Error('Tab ownership fixture needs a changed file.');
			const url = bridgeViewerViteProductReviewUrl(
				server.origin,
				requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
			);
			await firstTab.goto(url, { waitUntil: 'domcontentloaded' });
			await selectReviewFile({ page: firstTab, path: reviewFile.path });
			await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });

			// Act: opening a competing tab must not displace the active tab.
			const secondContext =
				profileTopology === 'shared-profile'
					? context
					: await browser.newContext({ viewport: { width: 1728, height: 980 } });
			secondContext.setDefaultTimeout(0);
			secondContext.setDefaultNavigationTimeout(0);
			const secondTab = await secondContext.newPage();
			if (secondContext !== context) {
				secondTab.on('pageerror', (error): void => {
					pageErrors.push(error.message);
				});
			}
			await secondTab.goto(url, { waitUntil: 'domcontentloaded' });
			await secondTab.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'visible' });
			await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });
			expect(firstBootstrapCount).toBe(1);
			expect(await secondTab.getByRole('button').count()).toBe(1);

			// Refresh retries admission; it must never take control from the active tab.
			await secondTab.getByRole('button', { name: 'Refresh', exact: true }).click();
			await secondTab.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'visible' });
			await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });
			expect(firstBootstrapCount).toBe(1);

			// Closing the first tab releases its stream; Refresh then opens usable content.
			await firstTab.close();
			await secondTab.getByRole('button', { name: 'Refresh', exact: true }).click();
			await selectReviewFile({ page: secondTab, path: reviewFile.path });
			await waitForSelectedReviewReady({ page: secondTab, itemId: reviewFile.itemId });
			await secondTab.reload({ waitUntil: 'domcontentloaded' });
			await selectReviewFile({ page: secondTab, path: reviewFile.path });
			await waitForSelectedReviewReady({ page: secondTab, itemId: reviewFile.itemId });
			expect(pageErrors).toEqual([]);
		} catch (error: unknown) {
			primaryError = new Error(
				`Development tab ownership failed. Backend: ${server?.diagnostics() ?? 'not started'}`,
				{ cause: error },
			);
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
				...(primaryError === undefined ? {} : { primaryError }),
			});
		}
	},
);
