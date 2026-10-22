import { expect, test } from 'vitest';

import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

test.for(['browser.close', 'launch.dispose'] as const)(
	'harness %s delivers dedicated Worker close before disconnecting the real host',
	async (closeThrough, context) => {
		const launch = await BridgeWebTestLaunch.start({ signal: context.signal });
		try {
			const browser = await launch.launchBrowser({ channel: 'chrome', headless: true });
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
			else await launch.dispose();
			// Disconnect is the terminal observation. Missing Worker.close fails here
			// without awaiting an event the retired connection can no longer deliver.
			expect(events).toEqual(['worker closed', 'browser disconnected']);
			expect(browser.isConnected()).toBe(false);
			process.stdout.write(
				`CHROMIUM_WORKER_RETIREMENT close=${closeThrough} workerBeforeDisconnect=true\n`,
			);
		} finally {
			await launch.dispose();
		}
	},
);
