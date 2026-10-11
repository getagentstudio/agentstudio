import { chromium, type Browser, type BrowserContext, type ConsoleMessage } from 'playwright';

import { isReactActWarning } from '../react-act-warning.ts';

let activeE2ETestSignal: AbortSignal | null = null;
const browsersByE2ETestSignal = new Map<AbortSignal, Set<Browser>>();

export function installBridgeViewerE2ETestSignal(signal: AbortSignal): void {
	activeE2ETestSignal = signal;
}

export function clearBridgeViewerE2ETestSignal(signal: AbortSignal): void {
	if (activeE2ETestSignal === signal) activeE2ETestSignal = null;
}

export async function closeBridgeViewerE2ETestBrowsers(signal: AbortSignal): Promise<void> {
	const browsers = browsersByE2ETestSignal.get(signal);
	if (browsers === undefined) return;
	await Promise.allSettled([...browsers].map((browser) => browser.close()));
	browsersByE2ETestSignal.delete(signal);
}

// This launcher owns zero action/navigation defaults, the test's abort-driven
// page closure, and browser cleanup. Every Vite E2E journey launches here so a
// React act() warning inside
// any page of any context fails the journey. The warning is re-reported through
// the test process's console.error, which ../console-error-guard.ts (loaded by
// vitest.e2e.config.ts) turns into a failure of the running test.
export async function launchBridgeViewerE2EChromium(): Promise<Browser> {
	// Capture the owner before suspension so a timed-out launch cannot attach
	// to the next test's signal.
	const testSignal = activeE2ETestSignal;
	const browser = await chromium.launch({ channel: 'chrome', headless: true });
	if (testSignal !== null) {
		const browsers = browsersByE2ETestSignal.get(testSignal) ?? new Set<Browser>();
		browsers.add(browser);
		browsersByE2ETestSignal.set(testSignal, browsers);
	}
	const closeOnAbort = (): void => {
		const reason = 'Vitest E2E test aborted';
		for (const context of browser.contexts()) {
			for (const page of context.pages()) {
				void page.close({ reason }).catch((): void => undefined);
			}
		}
		void browser.close({ reason }).catch((): void => undefined);
	};
	if (testSignal !== null) {
		if (testSignal.aborted) {
			closeOnAbort();
		} else {
			testSignal.addEventListener('abort', closeOnAbort, { once: true });
		}
	}
	browser.on('context', (context: BrowserContext): void => {
		context.setDefaultTimeout(0);
		context.setDefaultNavigationTimeout(0);
		context.on('console', reportPageActWarning);
	});
	browser.on('disconnected', (): void => {
		testSignal?.removeEventListener('abort', closeOnAbort);
	});
	return browser;
}

export function reportPageActWarning(message: Pick<ConsoleMessage, 'text'>): void {
	const text = message.text();
	if (isReactActWarning(text)) {
		console.error(`E2E page console reported a React act() warning: ${text}`);
	}
}
