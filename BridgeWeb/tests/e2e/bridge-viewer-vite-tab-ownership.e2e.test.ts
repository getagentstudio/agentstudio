import type { Browser } from 'playwright';
import { expect, test, type TestContext } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { installBridgeViewerDocumentGenerations } from '../../scripts/verify-bridge-viewer-worktree-dev-server/product-only-real-router-document-generations.ts';
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
import {
	createTabOwnershipCleanup,
	createTabOwnershipStepCheckpoint,
	observeTabOwnershipBootstrap,
	tabOwnershipBootstrapTransportForPage,
} from './bridge-viewer-vite-tab-ownership-test-support.ts';

test.for(['shared-profile', 'separate-profile'] as const)(
	'development tabs show open elsewhere until the active tab closes (%s)',
	async (
		profileTopology: 'shared-profile' | 'separate-profile',
		testContext: TestContext,
	): Promise<void> => {
		// Arrange: shared or isolated browser storage against one real isolated Swift backend.
		let fixture: Awaited<ReturnType<typeof createBridgeViewerViteProductFixture>> | null = null;
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let primaryError: unknown;
		const checkpoint = createTabOwnershipStepCheckpoint({
			topology: profileTopology,
			record: (message: string): void => console.info(message),
		});
		// Runner cleanup exists before any acquisition, independently of the async body finally.
		const cleanup = createTabOwnershipCleanup({
			registerOnFinished: (finish): void => {
				testContext.onTestFinished(async (): Promise<void> => {
					if (testContext.signal.aborted || testContext.task.result?.state === 'fail') {
						console.info(
							`TQ35 ${profileTopology}: failed/aborted while awaiting ${checkpoint.lastStep()}. Backend: ${server?.diagnostics() ?? 'not acquired'}`,
						);
					}
					await finish();
				});
			},
			stopServer: async (): Promise<void> => {
				if (server === null) return;
				const stopped = await server.stop();
				expect(stopped.ownedProcessAliveAfterStop).toBe(false);
				expect(stopped.forcedTerminationRequired).toBe(false);
			},
			closeBrowser: async (): Promise<void> => {
				await browser?.close();
			},
			disposeFixture: async (): Promise<void> => {
				await fixture?.dispose();
			},
		});
		try {
			checkpoint.begin('create fixture');
			fixture = await createBridgeViewerViteProductFixture();
			checkpoint.begin('start Vite and Swift');
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			checkpoint.begin('launch Chromium');
			browser = await launchBridgeViewerE2EChromium();
			checkpoint.begin('create first browser context and page');
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
			const reviewFile = fixture.oracle.reviewFiles[0];
			if (reviewFile === undefined) throw new Error('Tab ownership fixture needs a changed file.');
			const url = bridgeViewerViteProductReviewUrl(
				server.origin,
				requireBridgeViewerVitePrimaryReviewPath(fixture.oracle),
			);
			checkpoint.begin('navigate first tab');
			await firstTab.goto(url, { waitUntil: 'domcontentloaded' });
			checkpoint.begin('select first tab Review file');
			await selectReviewFile({ page: firstTab, path: reviewFile.path });
			checkpoint.begin('first tab Review ready');
			await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });

			// Act: opening a competing tab must not displace the active tab.
			checkpoint.begin('create competing browser context and page');
			const secondContext =
				profileTopology === 'shared-profile'
					? context
					: await browser.newContext({ viewport: { width: 1728, height: 980 } });
			secondContext.setDefaultTimeout(0);
			secondContext.setDefaultNavigationTimeout(0);
			const secondTab = await secondContext.newPage();
			checkpoint.begin('install second tab document correlation');
			const documentGenerations = await installBridgeViewerDocumentGenerations(secondTab);
			if (secondContext !== context) {
				secondTab.on('pageerror', (error): void => {
					pageErrors.push(error.message);
				});
			}
			checkpoint.begin('navigate competing tab');
			await secondTab.goto(url, { waitUntil: 'domcontentloaded' });
			checkpoint.begin('competing tab inactive notice');
			await secondTab.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'visible' });
			checkpoint.begin('first tab remains ready after competing tab opens');
			await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });
			expect(await secondTab.getByRole('button').count()).toBe(1);

			// Refresh retries admission; it must never take control from the active tab.
			checkpoint.begin('competing Refresh bootstrap in new document');
			const refreshedBootstrap = observeTabOwnershipBootstrap({
				transport: tabOwnershipBootstrapTransportForPage(secondTab),
				requestGeneration: documentGenerations.requestGeneration,
				expectedDocumentGeneration: documentGenerations.currentGeneration() + 1,
				signal: testContext.signal,
			});
			const [, refreshedResponse] = await Promise.all([
				secondTab.getByRole('button', { name: 'Refresh', exact: true }).click(),
				refreshedBootstrap,
			]);
			expect(refreshedResponse.status()).toBe(409);
			checkpoint.begin('new document competing tab inactive notice');
			await secondTab.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'visible' });
			checkpoint.begin('first tab remains ready after refused Refresh');
			await waitForSelectedReviewReady({ page: firstTab, itemId: reviewFile.itemId });

			// Closing the first tab releases its stream; Refresh then opens usable content.
			// The native termination oracle is still a separate Bridge-owned gap; no retry here.
			checkpoint.begin('close first tab');
			await firstTab.close();
			checkpoint.begin('Refresh after first tab close');
			await secondTab.getByRole('button', { name: 'Refresh', exact: true }).click();
			checkpoint.begin('select second tab Review file after first tab close');
			await selectReviewFile({ page: secondTab, path: reviewFile.path });
			checkpoint.begin('second tab Review ready after first tab close');
			await waitForSelectedReviewReady({ page: secondTab, itemId: reviewFile.itemId });
			checkpoint.begin('reload admitted second tab');
			await secondTab.reload({ waitUntil: 'domcontentloaded' });
			checkpoint.begin('select reloaded second tab Review file');
			await selectReviewFile({ page: secondTab, path: reviewFile.path });
			checkpoint.begin('reloaded second tab Review ready');
			await waitForSelectedReviewReady({ page: secondTab, itemId: reviewFile.itemId });
			checkpoint.begin('assert page errors');
			expect(pageErrors).toEqual([]);
		} catch (error: unknown) {
			primaryError = new Error(
				`Development tab ownership failed while awaiting ${checkpoint.lastStep()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
				{ cause: error },
			);
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [{ name: 'tab ownership resources', run: cleanup.stop }],
				...(primaryError === undefined ? {} : { primaryError }),
			});
		}
	},
);
