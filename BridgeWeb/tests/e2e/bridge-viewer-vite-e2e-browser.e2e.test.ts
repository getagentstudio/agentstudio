import type { Browser } from 'playwright';
import { test } from 'vitest';

import {
	actWarningProbeComponentName,
	defineConsoleErrorGuardProbe,
} from '../console-error-guard-probe.ts';
import { launchBridgeViewerE2EChromium } from './bridge-viewer-vite-e2e-browser.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

const notWrappedInActWarning = `An update to ${actWarningProbeComponentName} inside a test was not wrapped in act(...).`;
const notConfiguredForActWarning =
	'The current testing environment is not configured to support act(...)';

// Both React act() warning forms, logged by a real page in a browser launched
// for E2E journeys, fail the running test through the page-console relay.
defineConsoleErrorGuardProbe({
	runOwnedBody: runBridgeWebE2ETestBody,
	emitActWarning: async (context): Promise<void> => {
		await logFromRealPage(notWrappedInActWarning, context.signal);
	},
	suiteName: 'E2E page console (update not wrapped in act)',
});

defineConsoleErrorGuardProbe({
	runOwnedBody: runBridgeWebE2ETestBody,
	emitActWarning: async (context): Promise<void> => {
		await logFromRealPage(notConfiguredForActWarning, context.signal);
	},
	expectedWarningText: notConfiguredForActWarning,
	suiteName: 'E2E page console (environment not configured for act)',
});

test('an E2E page console.error that is not an act() warning does not fail the test', async (context) => {
	return await runBridgeWebE2ETestBody(context, async (): Promise<void> => {
		// The console error guard fails this test if the relay re-reports the message.
		await logFromRealPage(
			'Bridge page diagnostic that is not a React act() warning',
			context.signal,
		);
	});
});

// Logs `message` with console.error inside a real page and returns once the
// browser context has delivered that console event; the relay listens on the same
// context and was registered first, so it has already run.
async function logFromRealPage(message: string, testSignal: AbortSignal): Promise<void> {
	const browser: Browser = await launchBridgeViewerE2EChromium({ testSignal });
	try {
		const context = await browser.newContext();
		const page = await context.newPage();
		const deliveredConsoleEvent = context.waitForEvent('console');
		await page.evaluate((pageMessage: string): void => {
			console.error(pageMessage);
		}, message);
		await deliveredConsoleEvent;
	} finally {
		await browser.close();
	}
}
