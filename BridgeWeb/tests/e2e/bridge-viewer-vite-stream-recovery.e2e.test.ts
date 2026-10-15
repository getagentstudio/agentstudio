import type { Browser, Page } from 'playwright';
import { expect, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { waitForSelectedFileReady } from './bridge-viewer-vite-annotation-save-journey.ts';
import { registerStreamRecoveryWaitProof } from './bridge-viewer-vite-budget-wait-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeSelectedFileRetention } from './bridge-viewer-vite-file-retention-probe.ts';
import { observeInteractionProfileFailures } from './bridge-viewer-vite-interaction-profile-diagnostics.ts';
import { appendJourneyFailureDiagnostics } from './bridge-viewer-vite-journey-failure.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import { observeBrowserRuntimeDiagnostics } from './bridge-viewer-vite-review-comparison-observation.ts';
import {
	installSelectedContentOwnerObservation,
	readSelectedContentOwnerObservation,
} from './bridge-viewer-vite-selected-content-observation.ts';
import {
	startBridgeStreamFaultProxy,
	type BridgeStreamFaultProxy,
} from './bridge-viewer-vite-stream-fault-proxy.ts';
import { waitForStreamRecoveryFilePaint } from './bridge-viewer-vite-stream-recovery-readiness.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

test.for(['direct', 'healthy', 'disconnected'] as const)(
	'updates the selected File without user interaction after a %s metadata stream',
	async (streamState, context): Promise<void> => {
		return await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			// Arrange — production browser worker, Vite and Swift with a transparent wire seam.
			const fixture = await createBridgeViewerViteProductFixture();
			let browser: Browser | null = null;
			let server: BridgeViewerOwnedViteProductServer | null = null;
			let proxy: BridgeStreamFaultProxy | null = null;
			let page: Page | null = null;
			let diagnostics: ReturnType<typeof observeBrowserRuntimeDiagnostics> | null = null;
			let failures: Awaited<ReturnType<typeof observeInteractionProfileFailures>> | null = null;
			let primaryFailure: { readonly error: Error } | null = null;
			let phase = 'prepare fixture and server';
			let retention: Awaited<ReturnType<typeof observeSelectedFileRetention>> | null = null;
			try {
				server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
				if (streamState !== 'direct') proxy = await startBridgeStreamFaultProxy(server.origin);
				browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
				page = await browser.newPage({ viewport: { height: 980, width: 1728 } });
				phase = 'install owner observation before navigation';
				await installSelectedContentOwnerObservation(page);
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
				phase = 'initial selected File and readable paint';
				await waitForSelectedFileReady({ oracle: fixture.oracle, page });
				phase = 'bind the selected File identity before mutation';
				const selectedItemId = await page.evaluate(
					(): string | null =>
						window.bridgeSelectedContentOwnerObservation?.read('file').selectedItemId ??
						document
							.querySelector('[data-testid="bridge-file-viewer-code-canvas"]')
							?.getAttribute('data-worktree-rendered-item-id') ??
						null,
				);
				if (selectedItemId === null || selectedItemId.length === 0)
					throw new Error('Selected File readiness did not publish its item identity.');
				retention = await observeSelectedFileRetention(page, fixture.oracle.largeFilePath);
				const before = proxy?.snapshot();
				if (before !== undefined) {
					expect(before.activeMetadataResponses).toBe(1);
					expect(before.metadataByteCount).toBeGreaterThan(0);
				}

				// Act — cut only the established metadata connection, not the worker or backend.
				if (streamState === 'disconnected') expect(proxy?.disconnectMetadata()).toBe(1);
				phase = 'mutate fixture bytes';
				const updatedContent = await fixture.mutateLargeFile();
				phase = `new source, selected content owner result, and exact SHA paint ${updatedContent.sha256}`;
				console.info(`STREAM_RECOVERY ${streamState}: ${phase}`);

				// Assert — no second click, explicit subscribe, reload, or replacement call from the test.
				await waitForStreamRecoveryFilePaint({
					page,
					itemId: selectedItemId,
					expectedSha256: updatedContent.sha256,
					streamState,
					testLaunch: server.testLaunch,
				});
				if (proxy !== null && before !== undefined && streamState === 'healthy') {
					expect(proxy.snapshot().metadataRequestCount).toBe(before.metadataRequestCount);
				} else if (proxy !== null && before !== undefined) {
					expect(proxy.snapshot().metadataRequestCount).toBeGreaterThan(
						before.metadataRequestCount,
					);
				}
				if (proxy !== null) expect(proxy.snapshot().activeMetadataResponses).toBe(1);
			} catch (error: unknown) {
				primaryFailure = {
					error: new Error(`Metadata ${streamState} recovery failed while awaiting ${phase}`, {
						cause: error,
					}),
				};
				await appendJourneyFailureDiagnostics({
					primaryError: primaryFailure.error,
					reads: [
						{ name: 'wire', read: (): unknown => proxy?.snapshot() ?? 'direct stream' },
						{
							name: 'owner',
							read: async (): Promise<unknown> =>
								page === null ? 'no page' : readSelectedContentOwnerObservation(page),
						},
						{ name: 'failures', read: async (): Promise<unknown> => failures?.read() },
						{ name: 'browser', read: async (): Promise<unknown> => diagnostics?.describe() },
						{ name: 'backend', read: (): string => server?.diagnostics() ?? 'not started' },
					],
				});
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
							name: 'browser close',
							run: async (): Promise<void> => {
								await browser?.close();
							},
						},
						{
							name: 'fault proxy stop',
							run: async (): Promise<void> => {
								await proxy?.stop();
							},
						},
						{
							name: 'server stop',
							run: async (): Promise<void> => {
								if (server === null) return;
								const cleanup = await server.stop();
								expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
								expect(cleanup.forcedTerminationRequired).toBe(false);
							},
						},
						{ name: 'fixture dispose', run: fixture.dispose },
					].map((operation) => ({
						name: operation.name,
						run: async (): Promise<void> => {
							const retiring = operation.run();
							if (server === null) await retiring;
							else await server.testLaunch.observeRetirementStep(operation.name, retiring).value();
						},
					})),
					...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
				});
			}
		});
	},
);

registerStreamRecoveryWaitProof();
