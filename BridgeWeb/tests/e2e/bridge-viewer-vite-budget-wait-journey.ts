import { expect, test } from 'vitest';

import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { selectReviewFile } from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { createBridgeViewerViteProductFixture } from './bridge-viewer-vite-product-fixture.ts';
import { waitForStreamRecoveryFilePaint } from './bridge-viewer-vite-stream-recovery-readiness.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

export function registerReviewActivationWaitProof(): void {
	test('names held Review activation and ends selection from inactive-owner refusal', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			const browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage();
			let selection: ReturnType<typeof handleLaunchPromise<void>> | null = null;
			try {
				await page.setContent('<main>Review metadata delivery held</main>');
				selection = handleLaunchPromise(
					selectReviewFile({ page, path: 'held-review.ts', testLaunch: fixture.oracle.testLaunch }),
					'held Review activation',
				);
				expect(await page.getByTestId('review-viewer-shell').count()).toBe(0);
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(
					'Review shell mount: metadata and presentation projection before selecting held-review.ts',
				);
				await page.setContent(
					'<main data-testid="bridge-dev-session-inactive">Open elsewhere</main>',
				);
				await expect(selection.value()).rejects.toThrow(
					'Review shell mount refused by bridge-dev-session-inactive',
				);
				console.log('TQ85_OWNER_PROOF pending=Review-shell-mount terminal=open-elsewhere');
			} finally {
				await page.close();
				await selection?.settled;
				await browser.close();
				await fixture.dispose();
			}
		});
	});
}

export function registerStreamRecoveryWaitProof(): void {
	test('names held File recovery paint and settles only from the ready matching source', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const fixture = await createBridgeViewerViteProductFixture();
			const browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			const page = await browser.newPage();
			let paint: ReturnType<typeof handleLaunchPromise<void>> | null = null;
			try {
				await page.setContent(
					'<main data-testid="bridge-file-viewer-code-canvas" data-worktree-open-file-state="ready"><diffs-container data-bridge-painted-source-correlations=\'[{"observedSha256":"old-source"}]\'></diffs-container></main>',
				);
				paint = handleLaunchPromise(
					waitForStreamRecoveryFilePaint({
						page,
						expectedSha256: 'new-source',
						streamState: 'disconnected',
						testLaunch: fixture.oracle.testLaunch,
					}),
					'held File recovery paint',
				);
				expect(
					await page
						.locator('diffs-container')
						.getAttribute('data-bridge-painted-source-correlations'),
				).toContain('old-source');
				const step =
					'File metadata disconnected: selected File ready and painted source new-source';
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(step);
				await page.evaluate((): void => {
					document.querySelector('main')?.setAttribute('data-worktree-open-file-state', 'loading');
					document
						.querySelector('diffs-container')
						?.setAttribute(
							'data-bridge-painted-source-correlations',
							JSON.stringify([{ observedSha256: 'new-source' }]),
						);
				});
				expect(await page.locator('main').getAttribute('data-worktree-open-file-state')).toBe(
					'loading',
				);
				expect(fixture.oracle.testLaunch.pendingSteps).toContain(step);
				await page.evaluate((): void => {
					document.querySelector('main')?.setAttribute('data-worktree-open-file-state', 'ready');
				});
				await paint.value();
				expect(fixture.oracle.testLaunch.pendingSteps).not.toContain(step);
				console.log('TQ90_OWNER_PROOF pending=selected-File-paint release=ready-matching-SHA');
			} finally {
				await page.close();
				await paint?.settled;
				await browser.close();
				await fixture.dispose();
			}
		});
	});
}
