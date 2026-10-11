import { chromium, type Browser, type BrowserContext, type ConsoleMessage } from 'playwright';

import { isReactActWarning } from '../react-act-warning.ts';

const acquisitionsByTestSignal = new Map<AbortSignal, Set<Promise<Browser>>>();
const retirementByBrowser = new WeakMap<Browser, Promise<void>>();

export async function closeBridgeViewerE2ETestBrowsers(signal: AbortSignal): Promise<void> {
	const acquisitions = acquisitionsByTestSignal.get(signal);
	if (acquisitions === undefined) return;
	// Drain acquisitions registered while an earlier launch is being retired.
	// Each iteration joins concrete work; it never polls readiness or time.
	while (acquisitions.size > 0) {
		await Promise.allSettled(
			[...acquisitions].map(async (acquisition): Promise<void> => {
				try {
					await retireE2EBrowser(await acquisition);
				} finally {
					acquisitions.delete(acquisition);
				}
			}),
		);
	}
	acquisitionsByTestSignal.delete(signal);
}

// Callers carry their own signal across preparation awaits. This launcher owns
// zero action/navigation defaults and abort-driven page/browser closure. The
// finished hook joins browser closure and pending launches, but does not join
// the resumed test body's backend/fixture retirement: the authoritative
// test-launch harness (#536, G1) owns those fixture lifetimes and their join.
// Page console warnings are relayed to ../console-error-guard.ts.
export function launchBridgeViewerE2EChromium(props: {
	readonly testSignal: AbortSignal;
}): Promise<Browser> {
	let resolveBrowser!: (browser: Browser) => void;
	let rejectLaunch!: (error: unknown) => void;
	const acquisition = new Promise<Browser>((resolve, reject): void => {
		resolveBrowser = resolve;
		rejectLaunch = reject;
	});
	const acquisitions =
		acquisitionsByTestSignal.get(props.testSignal) ?? new Set<Promise<Browser>>();
	acquisitions.add(acquisition);
	acquisitionsByTestSignal.set(props.testSignal, acquisitions);
	// Registration precedes the first suspension inside Chromium acquisition.
	void acquireE2EBrowser(props.testSignal).then(resolveBrowser, rejectLaunch);
	const removeRetiredAcquisition = (): void => {
		acquisitions.delete(acquisition);
		if (
			acquisitions.size === 0 &&
			acquisitionsByTestSignal.get(props.testSignal) === acquisitions
		) {
			acquisitionsByTestSignal.delete(props.testSignal);
		}
	};
	void acquisition.then((): void => {
		// A body can resume after its finished hook has already returned. Its
		// aborted acquisition retires itself without recreating retained ownership.
		if (props.testSignal.aborted) removeRetiredAcquisition();
	}, removeRetiredAcquisition);
	return acquisition;
}

async function acquireE2EBrowser(testSignal: AbortSignal): Promise<Browser> {
	const browser = await chromium.launch({ channel: 'chrome', headless: true });
	const closeOnAbort = (): void => {
		void retireE2EBrowser(browser).catch((): void => undefined);
	};
	browser.on('context', (context: BrowserContext): void => {
		context.setDefaultTimeout(0);
		context.setDefaultNavigationTimeout(0);
		context.on('console', reportPageActWarning);
	});
	browser.on('disconnected', (): void => {
		testSignal.removeEventListener('abort', closeOnAbort);
	});
	if (testSignal.aborted) {
		await retireE2EBrowser(browser);
	} else {
		testSignal.addEventListener('abort', closeOnAbort, { once: true });
	}
	return browser;
}

function retireE2EBrowser(browser: Browser): Promise<void> {
	const existingRetirement = retirementByBrowser.get(browser);
	if (existingRetirement !== undefined) return existingRetirement;
	const reason = 'Vitest E2E test aborted or finished';
	for (const context of browser.contexts()) {
		for (const page of context.pages()) {
			void page.close({ reason }).catch((): void => undefined);
		}
	}
	const retirement = browser.close({ reason });
	retirementByBrowser.set(browser, retirement);
	return retirement;
}

export function reportPageActWarning(message: Pick<ConsoleMessage, 'text'>): void {
	const text = message.text();
	if (isReactActWarning(text)) {
		console.error(`E2E page console reported a React act() warning: ${text}`);
	}
}
