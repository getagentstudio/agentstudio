import { chromium, type Browser } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
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

const roundTripTimeoutMilliseconds = 60_000;

test('Review settles after switching the comparison target to another branch and back to main', async () => {
	// Arrange: a real Swift backend with Review settled on the initial target.
	const fixture = await createBridgeViewerViteProductFixture();
	let browser: Browser | null = null;
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let primaryError: unknown;
	try {
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		browser = await chromium.launch({ channel: 'chrome', headless: true });
		const page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
		const diagnostics = observeBrowserRuntimeDiagnostics(page);
		await page.goto(
			bridgeViewerViteProductReviewUrl(
				server.origin,
				requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
			),
			{
				timeout: roundTripTimeoutMilliseconds,
				waitUntil: 'domcontentloaded',
			},
		);
		await waitForSettledReviewComparison({
			expectedTargetLabel: 'HEAD',
			expectedTargetOID: fixture.oracle.baseRef,
			page,
			timeoutMilliseconds: roundTripTimeoutMilliseconds,
		});

		// Act: switch to another branch, then back to main, as a user does in the picker.
		await page.getByTestId(`comparison-branch-${fixture.oracle.comparisonTargetName}`).click();
		await waitForSettledReviewComparison({
			expectedTargetLabel: fixture.oracle.comparisonTargetName,
			expectedTargetOID: fixture.oracle.baseRef,
			page,
			timeoutMilliseconds: roundTripTimeoutMilliseconds,
		});
		// Assert: the second switch settles too, and Review never reports its metadata unavailable.
		try {
			// Selecting a branch closes the picker; reopen it as a user does.
			await openReviewComparisonPicker({ page, timeoutMilliseconds: roundTripTimeoutMilliseconds });
			await page
				.getByTestId('comparison-branch-main')
				.click({ timeout: roundTripTimeoutMilliseconds });
			await waitForSettledReviewComparison({
				expectedTargetLabel: 'main',
				expectedTargetOID: fixture.oracle.baseRef,
				page,
				timeoutMilliseconds: roundTripTimeoutMilliseconds,
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
}, 300_000);
