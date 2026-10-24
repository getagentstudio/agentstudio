import { expect, test } from 'vitest';

import {
	closeBridgeViewerE2ETestBrowsers,
	launchBridgeViewerE2EChromium,
} from '../../tests/e2e/bridge-viewer-vite-e2e-browser.ts';
import { createOwnedProductJourneyDeadline } from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-journey-deadline.ts';
import { closeBridgeViewerProductJourneyBrowser } from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-page.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

test.for(['browser.close', 'launch.dispose', 'journey', 'E2E helper', 'journey deadline'] as const)(
	'harness %s delivers dedicated Worker close before disconnecting the real host',
	async (closeThrough, context) => {
		const owner = new AbortController();
		const onBound = (): void => owner.abort(context.signal.reason);
		context.signal.addEventListener('abort', onBound, { once: true });
		const launch = await BridgeWebTestLaunch.start({ signal: owner.signal });
		try {
			const browser =
				closeThrough === 'E2E helper'
					? await launchBridgeViewerE2EChromium({ testSignal: owner.signal })
					: await launch.launchBrowser({ channel: 'chrome', headless: true });
			const page = await browser.newPage();
			page.setDefaultTimeout(0);
			const workerCreated = handleLaunchPromise(
				page.waitForEvent('worker'),
				'dedicated Worker created',
			);
			const workerReady = page.evaluate(async (): Promise<void> => {
				const source = new Blob(["postMessage('worker ready')"], { type: 'text/javascript' });
				const workerUrl = URL.createObjectURL(source);
				const worker = new Worker(workerUrl);
				await new Promise<void>((resolve, reject): void => {
					worker.onmessage = (event: MessageEvent<unknown>): void => {
						if (event.data === 'worker ready') resolve();
						else reject(new Error('Unexpected worker readiness message'));
					};
					worker.onerror = (event: ErrorEvent): void => reject(new Error(event.message));
				});
				URL.revokeObjectURL(workerUrl);
			});
			const worker = await workerCreated.value();
			await workerReady;
			const events: string[] = [];
			worker.once('close', (): void => {
				events.push('worker closed');
			});
			browser.once('disconnected', (): void => {
				events.push('browser disconnected');
			});
			if (closeThrough === 'browser.close') await browser.close();
			else if (closeThrough === 'launch.dispose') await launch.dispose();
			else if (closeThrough === 'journey')
				await closeBridgeViewerProductJourneyBrowser({ page, browser });
			else if (closeThrough === 'E2E helper') {
				owner.abort(new Error('shared E2E helper owner aborted'));
				await closeBridgeViewerE2ETestBrowsers(owner.signal);
			} else {
				const deadline = createOwnedProductJourneyDeadline({ signal: owner.signal, page, browser });
				owner.abort(new Error('journey deadline fixture'));
				await deadline.dispose();
				await launch.dispose();
			}
			// Disconnect is the terminal observation. Missing Worker.close fails here
			// without awaiting an event the retired connection can no longer deliver.
			expect(events).toEqual(['worker closed', 'browser disconnected']);
			expect(browser.isConnected()).toBe(false);
			process.stdout.write(
				`CHROMIUM_WORKER_RETIREMENT close=${closeThrough} workerBeforeDisconnect=true\n`,
			);
		} finally {
			context.signal.removeEventListener('abort', onBound);
			owner.abort(new Error('fixture cleanup'));
			await launch.dispose();
			if (closeThrough === 'E2E helper') await closeBridgeViewerE2ETestBrowsers(owner.signal);
		}
	},
);
