import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import type { Browser, JSHandle, Page } from 'playwright';
import { expect, onTestFailed, test } from 'vitest';

import { runAllOwnedCleanupOperations } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { waitForSelectedFileReady } from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { observeSelectedFileRetention } from './bridge-viewer-vite-file-retention-probe.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
	type BridgeViewerOwnedViteProductServer,
} from './bridge-viewer-vite-product-fixture.ts';
import { bridgeViewerViteProductFileUrl } from './bridge-viewer-vite-product-url.ts';
import {
	observeBrowserRuntimeDiagnostics,
	type BrowserRuntimeDiagnostics,
} from './bridge-viewer-vite-review-comparison-observation.ts';

interface FileScrollRetentionReport {
	readonly frameCount: number;
	readonly initialScrollTop: number;
	readonly firstLoss: {
		readonly ownerRetained: boolean;
		readonly scrollTop: number | null;
	} | null;
}

interface FileScrollRetentionProbe {
	readonly stop: () => FileScrollRetentionReport;
}

test('retains the scrolled selected File through sixteen distinct worktree edits', async (context) => {
	let phase = 'fixture-creating';
	let currentUpdate: number | null = null;
	let completedUpdates = 0;
	onTestFailed((): void => {
		console.error(
			`Sustained File refresh failed during ${phase}; current update=${currentUpdate ?? 'none'}; completed updates=${completedUpdates}.`,
		);
	});

	// Arrange — real filesystem, Swift source, transport, worker and CodeView.
	const fixture = await createBridgeViewerViteProductFixture();
	let server: BridgeViewerOwnedViteProductServer | null = null;
	let browser: Browser | null = null;
	let page: Page | null = null;
	let diagnostics: BrowserRuntimeDiagnostics | null = null;
	let retention: Awaited<ReturnType<typeof observeSelectedFileRetention>> | null = null;
	let scrollProbe: JSHandle<FileScrollRetentionProbe> | null = null;
	let primaryFailure: { readonly error: unknown } | null = null;
	const pageErrors: string[] = [];
	try {
		phase = 'server-starting';
		server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
		phase = 'browser-starting';
		browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
		phase = 'page-creating';
		page = await browser.newPage({ viewport: { width: 1728, height: 980 } });
		page.on('pageerror', (error: Error): void => {
			pageErrors.push(error.message);
		});
		diagnostics = observeBrowserRuntimeDiagnostics(page);
		phase = 'page-navigating';
		await page.goto(bridgeViewerViteProductFileUrl(server.origin, fixture.oracle.largeFilePath), {
			waitUntil: 'domcontentloaded',
		});
		phase = 'initial-file-ready-waiting';
		await waitForSelectedFileReady({ oracle: fixture.oracle, page });
		phase = 'initial-scroll-positioning';
		await page
			.locator('[data-testid="bridge-file-viewer-code-view"] .bridge-code-view-scroll-owner')
			.evaluate((owner: HTMLElement): void => {
				owner.scrollTop = (owner.scrollHeight - owner.clientHeight) / 2;
				owner.dispatchEvent(new Event('scroll', { bubbles: true }));
			});
		phase = 'scroll-observation-starting';
		scrollProbe = await observeFileScrollRetention(page);
		phase = 'file-retention-observation-starting';
		retention = await observeSelectedFileRetention(page, fixture.oracle.largeFilePath);
		const filePath = join(fixture.oracle.worktreeRoot, fixture.oracle.largeFilePath);
		phase = 'source-file-reading';
		const originalBody = await readFile(filePath, 'utf8');

		// Act / Assert — each real edit must paint its own exact bytes before the next.
		for (let update = 1; update <= 16; update += 1) {
			currentUpdate = update;
			const nextBody = originalBody.replaceAll(
				'bridge-vite-product-line',
				`bridge-vite-edit-${String(update).padStart(2, '0')}-line`,
			);
			const expectedSha256 = createHash('sha256').update(nextBody).digest('hex');
			// oxlint-disable-next-line no-await-in-loop -- Sequential edits witness every installed successor, not a coalesced final result.
			phase = `update-${update}-writing`;
			await writeFile(filePath, nextBody);
			// oxlint-disable-next-line no-await-in-loop -- Exact painted content is the completion event for each edit.
			phase = `update-${update}-painted-hash-waiting`;
			await waitForPaintedFileHash(page, expectedSha256);
			completedUpdates += 1;
		}
		phase = 'assertions';
		const scrollReport = await scrollProbe.evaluate(
			(probe): FileScrollRetentionReport => probe.stop(),
		);
		expect(completedUpdates).toBe(16);
		expect(scrollReport.initialScrollTop).toBeGreaterThan(0);
		expect(scrollReport.frameCount).toBeGreaterThan(0);
		expect(scrollReport.firstLoss).toBeNull();
		expect(pageErrors).toEqual([]);
		phase = 'complete';
	} catch (error: unknown) {
		phase = 'failure-diagnostics';
		primaryFailure = {
			error: new Error(
				`Sustained File refresh failed after ${completedUpdates} updates. Browser: ${await diagnostics?.describe()}. Backend: ${server?.diagnostics() ?? 'not started'}`,
				{ cause: error },
			),
		};
	} finally {
		phase = 'cleanup';
		await runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'scroll observation',
					run: async (): Promise<void> => {
						if (scrollProbe !== null) {
							await scrollProbe.evaluate((probe): FileScrollRetentionReport => probe.stop());
							await scrollProbe.dispose();
						}
					},
				},
				{
					name: 'visible File retention',
					run: async (): Promise<void> => {
						if (retention !== null) expect.soft(await retention.stop()).toBeNull();
					},
				},
				{
					name: 'browser',
					run: async (): Promise<void> => {
						await browser?.close();
					},
				},
				{
					name: 'Vite and Swift',
					run: async (): Promise<void> => {
						if (server !== null) {
							const cleanup = await server.stop();
							expect(cleanup.ownedProcessAliveAfterStop).toBe(false);
							expect(cleanup.forcedTerminationRequired).toBe(false);
						}
					},
				},
				{ name: 'fixture', run: fixture.dispose },
			],
			...(primaryFailure === null ? {} : { primaryError: primaryFailure.error }),
		});
	}
});

async function observeFileScrollRetention(page: Page): Promise<JSHandle<FileScrollRetentionProbe>> {
	return await page.evaluateHandle((): FileScrollRetentionProbe => {
		const selector = '[data-testid="bridge-file-viewer-code-view"] .bridge-code-view-scroll-owner';
		const owner = document.querySelector(selector);
		if (!(owner instanceof HTMLElement) || owner.scrollTop <= 0)
			throw new Error('Scrolled File owner is required.');
		const initialScrollTop = owner.scrollTop;
		let frameCount = 0;
		let firstLoss: FileScrollRetentionReport['firstLoss'] = null;
		let animationFrame = 0;
		const observeFrame = (): void => {
			frameCount += 1;
			const currentOwner = document.querySelector(selector);
			const ownerRetained = currentOwner === owner && owner.isConnected;
			const scrollTop = currentOwner instanceof HTMLElement ? currentOwner.scrollTop : null;
			if (
				firstLoss === null &&
				(scrollTop === null || Math.abs(scrollTop - initialScrollTop) > 1)
			) {
				firstLoss = { ownerRetained, scrollTop };
			}
			animationFrame = requestAnimationFrame(observeFrame);
		};
		animationFrame = requestAnimationFrame(observeFrame);
		return {
			stop: (): FileScrollRetentionReport => {
				cancelAnimationFrame(animationFrame);
				return { frameCount, initialScrollTop, firstLoss };
			},
		};
	});
}

async function waitForPaintedFileHash(page: Page, expectedSha256: string): Promise<void> {
	await page.waitForFunction((expected: string): boolean => {
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
					correlation.observedSha256 === expected,
			)
		);
	}, expectedSha256);
}
