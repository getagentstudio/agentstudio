import { type Browser, type BrowserContext, type ConsoleMessage } from 'playwright';

import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { isReactActWarning } from '../react-act-warning.ts';

interface E2EBrowserAcquisition {
	readonly browser: Promise<Browser>;
	retirementFailure?: unknown;
}

const acquisitionsByTestSignal = new Map<AbortSignal, Set<E2EBrowserAcquisition>>();
const retirementByBrowser = new WeakMap<Browser, Promise<void>>();

export async function closeBridgeViewerE2ETestBrowsers(signal: AbortSignal): Promise<void> {
	const errors: unknown[] = [];
	// Drain acquisitions registered while an earlier launch is being retired.
	// Each iteration joins concrete work; it never polls readiness or time.
	for (;;) {
		const acquisitions = acquisitionsByTestSignal.get(signal);
		if (acquisitions === undefined) break;
		if (acquisitions.size === 0) {
			acquisitionsByTestSignal.delete(signal);
			break;
		}
		const results = await Promise.allSettled(
			[...acquisitions].map(async (acquisition): Promise<void> => {
				try {
					let browser: Browser;
					try {
						browser = await acquisition.browser;
					} catch {
						// Startup refusal/cancellation is returned to the raw test body.
						// Acquisition has already joined its harness teardown; retain
						// any failure of that teardown for the runner's G4 verdict.
						if (acquisition.retirementFailure !== undefined) throw acquisition.retirementFailure;
						return;
					}
					await retireE2EBrowser(browser);
				} finally {
					acquisitions.delete(acquisition);
				}
			}),
		);
		for (const result of results) if (result.status === 'rejected') errors.push(result.reason);
	}
	if (errors.length > 0) throw new AggregateError(errors, 'E2E browser retirement failed');
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
	const registration: E2EBrowserAcquisition = { browser: acquisition };
	const acquisitions =
		acquisitionsByTestSignal.get(props.testSignal) ?? new Set<E2EBrowserAcquisition>();
	acquisitions.add(registration);
	acquisitionsByTestSignal.set(props.testSignal, acquisitions);
	// Registration precedes the first suspension inside Chromium acquisition.
	void acquireE2EBrowser(props.testSignal, (error): void => {
		registration.retirementFailure = error;
	}).then(resolveBrowser, rejectLaunch);
	// Keep settled work (including failed retirement) registered until the runner
	// joins it. Removing it from a completion callback loses late successors.
	void acquisition.catch((): void => {});
	return acquisition;
}

async function acquireE2EBrowser(
	testSignal: AbortSignal,
	reportRetirementFailure: (error: unknown) => void,
): Promise<Browser> {
	let browser: Browser;
	try {
		browser = await BridgeWebTestLaunch.startBrowser(
			{ channel: 'chrome', headless: true },
			testSignal,
		);
	} catch (error: unknown) {
		// The harness aggregates startup and teardown only when cleanup failed.
		if (error instanceof AggregateError) reportRetirementFailure(error);
		throw error;
	}
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
		try {
			await retireE2EBrowser(browser);
		} catch (error: unknown) {
			reportRetirementFailure(error);
			throw error;
		}
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
