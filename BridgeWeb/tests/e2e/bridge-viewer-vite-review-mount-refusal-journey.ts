import { expect, test } from 'vitest';

import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { selectReviewFile } from './bridge-viewer-vite-annotation-save-journey.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

export function registerReviewMountRefusalJourneyTests(): void {
	test('names a terminal Review mount refusal before explicit page retirement', async (context) => {
		await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
			const browser = await launchBridgeViewerE2EChromium({ testSignal: context.signal });
			try {
				const page = await browser.newPage();
				await page.setContent(
					'<main data-testid="bridge-dev-session-inactive">Open elsewhere</main>',
				);
				const selection = handleLaunchPromise(
					selectReviewFile({ page, path: 'owner-refusal.ts' }),
					'Review mount terminal refusal witness',
				);
				// This command follows selection's observer installation in the page.
				// Explicit closure settles the old locator wait too: no timeout is needed for red proof.
				await page.getByTestId('bridge-dev-session-inactive').waitFor({ state: 'attached' });
				await page.close();
				await expect(selection.value()).rejects.toThrow(
					'Review shell mount refused by bridge-dev-session-inactive',
				);
			} finally {
				await browser.close();
			}
		});
	});
}
