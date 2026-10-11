import { beforeEach, type TestContext } from 'vitest';

import {
	clearBridgeViewerE2ETestSignal,
	closeBridgeViewerE2ETestBrowsers,
	installBridgeViewerE2ETestSignal,
} from './bridge-viewer-vite-e2e-browser.ts';

beforeEach((context: TestContext): void => {
	installBridgeViewerE2ETestSignal(context.signal);
	context.onTestFinished(async (): Promise<void> => {
		await closeBridgeViewerE2ETestBrowsers(context.signal);
		clearBridgeViewerE2ETestSignal(context.signal);
	});
});
