import type { Browser } from 'playwright';
import { afterAll, beforeAll, expect, test } from 'vitest';

import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServerCleanup,
} from './bridge-viewer-vite-product-fixture.ts';

// Run explicitly with BRIDGE_E2E_ABORT_PROBE=1 and a runner-configured test
// hang bound. Time is the subject here: no per-operation timer or poll budget.
const probeEnabled = process.env['BRIDGE_E2E_ABORT_PROBE'] === '1';
let fixture: Awaited<ReturnType<typeof createBridgeViewerViteProductFixture>> | null = null;
let server: BridgeViewerOwnedViteProductServer | null = null;
let browser: Browser | null = null;
let waitFailureMessage = '';
let cleanupReceipt: BridgeViewerOwnedViteProductServerCleanup | null = null;
let runnerAborted = false;
let finishCleanup: (() => void) | null = null;
const cleanupFinished = new Promise<void>((resolve): void => {
	finishCleanup = resolve;
});

beforeAll(async (): Promise<void> => {
	if (!probeEnabled) return;
	fixture = await createBridgeViewerViteProductFixture();
	server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
});

afterAll(async (): Promise<void> => {
	if (!probeEnabled) return;
	await browser?.close();
	await server?.stop();
	await fixture?.dispose();
});

test
	.skipIf(!probeEnabled)
	.fails(
		'runner abort rejects missing readiness and executes owned cleanup',
		async (context): Promise<void> => {
			context.onTestFinished(async (): Promise<void> => {
				await cleanupFinished;
			});
			try {
				browser = await launchBridgeViewerE2EChromium();
				const page = await browser.newPage();
				if (server === null) throw new Error('Abort probe needs the owned backend');
				await page.goto(server.origin, { waitUntil: 'domcontentloaded' });
				await page.getByTestId('bridge-pr-a-never-ready').waitFor({ state: 'visible' });
			} catch (error: unknown) {
				waitFailureMessage = String(error);
				runnerAborted = context.signal.aborted;
				console.info(`PR A abort wait: ${waitFailureMessage}`);
				throw error;
			} finally {
				try {
					await browser?.close();
					cleanupReceipt = (await server?.stop()) ?? null;
					await fixture?.dispose();
					console.info(
						`PR A abort cleanup: ${JSON.stringify({ browserConnected: browser?.isConnected(), backend: cleanupReceipt })}`,
					);
				} finally {
					finishCleanup?.();
				}
			}
		},
	);

test.skipIf(!probeEnabled)(
	'abort proof names its missing locator and joins browser/backend retirement',
	(): void => {
		expect(runnerAborted).toBe(true);
		expect(waitFailureMessage).toContain('locator.waitFor');
		expect(waitFailureMessage).toContain("getByTestId('bridge-pr-a-never-ready')");
		expect(browser?.isConnected()).toBe(false);
		expect(cleanupReceipt?.ownedProcessAliveAfterStop).toBe(false);
		expect(cleanupReceipt?.exitObserved).toBe(true);
		expect(cleanupReceipt?.forcedTerminationRequired).toBe(false);
	},
);
