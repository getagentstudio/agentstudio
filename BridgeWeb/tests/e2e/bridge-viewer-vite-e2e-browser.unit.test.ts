import type { Browser } from 'playwright';
import { chromium } from 'playwright';
import { afterEach, expect, test, vi } from 'vitest';

import {
	closeBridgeViewerE2ETestBrowsers,
	launchBridgeViewerE2EChromium,
} from './bridge-viewer-vite-e2e-browser.ts';

afterEach((): void => {
	vi.restoreAllMocks();
});

test('V1 resumed aborted A cannot acquire a browser while B is active', async (): Promise<void> => {
	const ownerA = new AbortController();
	const ownerB = new AbortController();
	const browserA = makeControlledBrowser();
	const browserB = makeControlledBrowser();
	vi.spyOn(chromium, 'launch')
		.mockResolvedValueOnce(browserB.browser)
		.mockResolvedValueOnce(browserA.browser);
	ownerA.abort();
	await launchBridgeViewerE2EChromium({ testSignal: ownerB.signal });
	try {
		await expect(launchBridgeViewerE2EChromium({ testSignal: ownerA.signal })).rejects.toThrow();
		expect(chromium.launch).toHaveBeenCalledTimes(1);
		expect(browserA.closed()).toBe(false); // No A browser was acquired; B remains owned by B.
		expect(browserB.closed()).toBe(false);
		await closeBridgeViewerE2ETestBrowsers(ownerA.signal);
		expect(browserB.closed()).toBe(false);
	} finally {
		await closeBridgeViewerE2ETestBrowsers(ownerA.signal);
		await closeBridgeViewerE2ETestBrowsers(ownerB.signal);
	}
});

test('V2a finished cleanup joins a held launch and its held browser closure', async (): Promise<void> => {
	const owner = new AbortController();
	const heldLaunch = createControlledPromise<Browser>();
	const heldClose = createControlledPromise<void>();
	const closeEntered = createControlledPromise<void>();
	const browser = makeControlledBrowser(async (): Promise<void> => {
		closeEntered.resolve();
		await heldClose.promise;
	});
	vi.spyOn(chromium, 'launch').mockReturnValue(heldLaunch.promise);
	const acquisitionStarted = createControlledPromise<void>();
	vi.mocked(chromium.launch).mockImplementation(() => {
		acquisitionStarted.resolve();
		return heldLaunch.promise;
	});
	const acquisition = launchBridgeViewerE2EChromium({ testSignal: owner.signal });
	const handledAcquisition = acquisition.then(
		(): void => {},
		(): void => {},
	);
	await acquisitionStarted.promise;
	owner.abort();
	let finishReturned = false;
	const finish = closeBridgeViewerE2ETestBrowsers(owner.signal).then((): void => {
		finishReturned = true;
	});
	heldLaunch.resolve(browser.browser);
	try {
		const boundary = await Promise.race([
			finish.then((): string => 'finished'),
			closeEntered.promise.then((): string => 'closing'),
		]);
		expect(boundary).toBe('closing');
		expect(finishReturned).toBe(false);
		expect(browser.closed()).toBe(false);
	} finally {
		heldClose.resolve();
		await Promise.all([handledAcquisition, finish]);
	}
	expect(browser.closed()).toBe(true);
	expect(finishReturned).toBe(true);
});

function makeControlledBrowser(beforeClose: () => Promise<void> = async (): Promise<void> => {}): {
	readonly browser: Browser;
	readonly closed: () => boolean;
} {
	let closed = false;
	const browser = {
		close: async (): Promise<void> => {
			await beforeClose();
			closed = true;
		},
		contexts: (): [] => [],
		isConnected: (): boolean => !closed,
		on: (): void => {},
	} as unknown as Browser;
	return { browser, closed: (): boolean => closed };
}

function createControlledPromise<TValue>(): {
	readonly promise: Promise<TValue>;
	readonly resolve: (value: TValue | PromiseLike<TValue>) => void;
} {
	let resolvePromise!: (value: TValue | PromiseLike<TValue>) => void;
	const promise = new Promise<TValue>((resolve): void => {
		resolvePromise = resolve;
	});
	return { promise, resolve: resolvePromise };
}
