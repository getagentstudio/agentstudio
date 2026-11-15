import type { Browser } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
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
import {
	observeBrowserRuntimeDiagnostics,
	openReviewComparisonPicker,
	waitForSettledReviewComparison,
} from './bridge-viewer-vite-review-comparison-observation.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

test('Review settles after switching the comparison target to another branch and back to main', async (context) => {
	return await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
		// Arrange: a real Swift backend with Review settled on the initial target.
		const fixture = await createBridgeViewerViteProductFixture();
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let primaryError: unknown;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			const diagnostics = observeBrowserRuntimeDiagnostics(page);
			await fixture.oracle.testLaunch
				.observeStep(
					'Review comparison: initial navigation DOM content loaded',
					page.goto(
						bridgeViewerViteProductReviewUrl(
							server.origin,
							requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
						),
						{ waitUntil: 'domcontentloaded' },
					),
				)
				.value();
			await waitForSettledReviewComparison({
				expectedTargetLabel: 'HEAD',
				expectedTargetOID: fixture.oracle.baseRef,
				page,
			});

			// Act: switch to another branch, then back to main, as a user does in the picker.
			await page.getByTestId(`comparison-branch-${fixture.oracle.comparisonTargetName}`).click();
			await waitForSettledReviewComparison({
				expectedTargetLabel: fixture.oracle.comparisonTargetName,
				expectedTargetOID: fixture.oracle.baseRef,
				page,
			});
			// Assert: the second switch settles too, and Review never reports its metadata unavailable.
			try {
				// Selecting a branch closes the picker; reopen it as a user does.
				await openReviewComparisonPicker({
					page,
				});
				await fixture.oracle.testLaunch
					.observeStep(
						'Review comparison: select main branch',
						page.getByTestId('comparison-branch-main').click(),
					)
					.value();
				await waitForSettledReviewComparison({
					expectedTargetLabel: 'main',
					expectedTargetOID: fixture.oracle.baseRef,
					page,
				});
			} catch (error: unknown) {
				throw new Error(
					`Review did not settle after returning to main: ${await diagnostics.describe()} server=${server.diagnostics()}`,
					{ cause: error },
				);
			}
			expect(await page.getByText('Review metadata is unavailable').count()).toBe(0);
		} catch (error: unknown) {
			primaryError = error;
			throw error;
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
						},
					},
					{ name: 'fixture', run: fixture.dispose },
				],
				...(primaryError === undefined ? {} : { primaryError }),
			});
		}
	});
}, 300_000);
