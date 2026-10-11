import { beforeEach, type TestContext } from 'vitest';

import { closeBridgeViewerE2ETestBrowsers } from './bridge-viewer-vite-e2e-browser.ts';

beforeEach((context: TestContext): void => {
	context.onTestFinished(async (): Promise<void> => {
		await closeBridgeViewerE2ETestBrowsers(context.signal);
	});
});
