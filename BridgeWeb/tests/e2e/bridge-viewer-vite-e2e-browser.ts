import { type Browser, type BrowserContext, type ConsoleMessage } from 'playwright';

import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { isReactActWarning } from '../react-act-warning.ts';

// Every Vite E2E journey launches Chromium here so a React act() warning inside
// any page of any context fails the journey. The warning is re-reported through
// the test process's console.error, which ../console-error-guard.ts (loaded by
// vitest.e2e.config.ts) turns into a failure of the running test.
export async function launchBridgeViewerE2EChromium(): Promise<Browser> {
	const browser = await BridgeWebTestLaunch.startBrowser({ channel: 'chrome', headless: true });
	browser.on('context', (context: BrowserContext): void => {
		context.on('console', reportPageActWarning);
	});
	return browser;
}

export function reportPageActWarning(message: Pick<ConsoleMessage, 'text'>): void {
	const text = message.text();
	if (isReactActWarning(text)) {
		console.error(`E2E page console reported a React act() warning: ${text}`);
	}
}
