import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { waitForSelectedFileReady } from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeSelectedFileRetention } from './bridge-viewer-vite-file-retention-probe.ts';
import { observeInteractionProfileFailures } from './bridge-viewer-vite-interaction-profile-diagnostics.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import { observeBrowserRuntimeDiagnostics } from './bridge-viewer-vite-review-comparison-observation.ts';
import {
	startBridgeStreamFaultProxy,
	type BridgeStreamFaultProxy,
} from './bridge-viewer-vite-stream-fault-proxy.ts';

test.each(['direct', 'healthy', 'disconnected'] as const)(
	'updates the selected File without user interaction after a %s metadata stream',
	async (streamState): Promise<void> => {
		// Arrange — production browser worker, Vite and Swift with a transparent wire seam.
		const fixture = await createBridgeViewerViteProductFixture();
		let browser: Browser | null = null;
		let server: BridgeViewerOwnedViteProductServer | null = null;
		let proxy: BridgeStreamFaultProxy | null = null;
		let page: Page | null = null;
		let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
		let failures: Awaited<ReturnType<typeof observeInteractionProfileFailures>> | null = null;
		let primaryFailure: { readonly error: unknown } | null = null;
		let retention: Awaited<ReturnType<typeof observeSelectedFileRetention>> | null = null;
		try {
			server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
			if (streamState !== 'direct') proxy = await startBridgeStreamFaultProxy(server.origin);
			browser = await launchBridgeViewerE2EChromium();
			page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
			// The vitest hang bound is the only clock this journey is allowed.
			page.setDefaultTimeout(0);
			page.setDefaultNavigationTimeout(0);
			diagnostics = observeBrowserRuntimeDiagnostics(page);
			failures = await observeInteractionProfileFailures(page);
			await page.goto(
				bridgeViewerViteProductFileUrl(
					proxy?.origin ?? server.origin,
					fixture.oracle.largeFilePath,
				),
				{
					waitUntil: 'domcontentloaded',
				},
			);
			await waitForSelectedFileReady({ oracle: fixture.oracle, page });
			retention = await observeSelectedFileRetention(page, fixture.oracle.largeFilePath);
			const before = proxy?.snapshot();
			if (before !== undefined) {
				expect(before.activeMetadataResponses).toBe(1);
				expect(before.metadataByteCount).toBeGreaterThan(0);
			}

			// Act — cut only the established metadata connection, not the worker or backend.
			if (streamState === 'disconnected') expect(proxy?.disconnectMetadata()).toBe(1);
			const updatedContent = await fixture.mutateLargeFile();

			// Assert — no second click, explicit subscribe, reload, or replacement call from the test.
			await page.waitForFunction(
				(expectedSha256: string): boolean => {
					const canvas = document.querySelector('[data-testid="bridge-file-viewer-code-canvas"]');
					const painted = canvas?.querySelector(
						'diffs-container[data-bridge-painted-source-correlations]',
					);
					const correlations: unknown = JSON.parse(
						painted?.getAttribute('data-bridge-painted-source-correlations') ?? '[]',
					);
					return (
						canvas?.getAttribute('data-worktree-open-file-state') === 'ready' &&
						Array.isArray(correlations) &&
						correlations.some(
							(correlation: unknown): boolean =>
								typeof correlation === 'object' &&
								correlation !== null &&
								'observedSha256' in correlation &&
								correlation.observedSha256 === expectedSha256,
						)
					);
				},
				updatedContent.sha256,
				{ timeout: 30_000 },
			);
			if (proxy !== null && before !== undefined && streamState === 'healthy') {
				expect(proxy.snapshot().metadataRequestCount).toBe(before.metadataRequestCount);
			} else if (proxy !== null && before !== undefined) {
				expect(proxy.snapshot().metadataRequestCount).toBeGreaterThan(before.metadataRequestCount);
			}
			if (proxy !== null) expect(proxy.snapshot().activeMetadataResponses).toBe(1);
		} catch (error: unknown) {
			primaryFailure = {
				error: new Error(
					`Metadata ${streamState} recovery failed. Wire: ${JSON.stringify(proxy?.snapshot())}. Failures: ${JSON.stringify(await failures?.read())}. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
					{ cause: error },
				),
			};
		} finally {
			await runAllOwnedCleanupOperations({
				operations: [
					{
						name: 'retention observation',
						run: async (): Promise<void> => {
							if (retention !== null)
								expect
									.soft(await retention.stop(), 'last-complete selected File must remain mounted')
									.toBeNull();
						},
					},
					{
						name: 'browser',
						run: async (): Promise<void> => {
							await browser?.close();
						},
					},
					{
						name: 'fault proxy',
						run: async (): Promise<void> => {
							await proxy?.stop();
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
