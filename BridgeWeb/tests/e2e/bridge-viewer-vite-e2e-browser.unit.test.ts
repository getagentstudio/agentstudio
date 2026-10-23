import type { Browser } from 'playwright';
import { chromium } from 'playwright';
import { afterEach, expect, test, vi } from 'vitest';

import type { OwnedBridgeDevelopmentServerCleanup } from '../../scripts/dev-server/bridge-development-server-process.ts';
import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import {
	closeBridgeViewerE2ETestBrowsers,
	launchBridgeViewerE2EChromium,
} from './bridge-viewer-vite-e2e-browser.ts';

afterEach((): void => {
	vi.restoreAllMocks();
});

test.each(['completed', 'failed'] as const)(
	'finished hook joins replacement registrations and held C closure: %s',
	async (disposition): Promise<void> => {
		const owner = new AbortController();
		const firstLaunch = createControlledPromise<Browser>();
		const firstLaunchEntered = createControlledPromise<void>();
		const lateCloseEntered = createControlledPromise<void>();
		const lateCloseRelease = createControlledPromise<void>();
		let secondAcquisition: Promise<Browser> | undefined;
		let thirdAcquisition: Promise<Browser> | undefined;
		const browserC = makeControlledBrowser(async (): Promise<void> => {
			lateCloseEntered.resolve();
			await lateCloseRelease.promise;
			if (disposition === 'failed') throw new Error('C retirement failed');
		});
		const browserB = makeControlledBrowser(async (): Promise<void> => {
			thirdAcquisition = launchBridgeViewerE2EChromium({ testSignal: owner.signal });
			void handleLaunchPromise(thirdAcquisition, 'late C acquisition').settled;
			if (disposition === 'failed') throw new Error('B retirement failed');
		});
		const browserA = makeControlledBrowser();
		// Stand in only for browser acquisition, preserving the helper's signal registry,
		// abort closure and physical retirement promises under test.
		vi.spyOn(BridgeWebTestLaunch, 'startBrowser')
			.mockImplementationOnce(async (): Promise<Browser> => {
				firstLaunchEntered.resolve();
				return await firstLaunch.promise;
			})
			.mockResolvedValueOnce(browserB.browser)
			.mockResolvedValueOnce(browserC.browser);
		const firstAcquisition = launchBridgeViewerE2EChromium({ testSignal: owner.signal });
		const registerSuccessor = handleLaunchPromise(
			firstAcquisition.then((): void => {
				secondAcquisition = launchBridgeViewerE2EChromium({ testSignal: owner.signal });
				void handleLaunchPromise(secondAcquisition, 'late B acquisition').settled;
			}),
			'register successor browser',
		);
		await firstLaunchEntered.promise;
		owner.abort();
		let finishReturned = false;
		const finish = handleLaunchPromise(
			closeBridgeViewerE2ETestBrowsers(owner.signal).finally((): void => {
				finishReturned = true;
			}),
			'browser finished hook',
		);
		firstLaunch.resolve(browserA.browser);
		try {
			const firstFact = await Promise.race([
				finish.settled.then((): string => 'finished'),
				lateCloseEntered.promise.then((): string => 'C closure entered'),
			]);
			expect(firstFact).toBe('C closure entered');
			expect(finishReturned).toBe(false);
			lateCloseRelease.resolve();
			const outcome = await finish.settled;
			if (disposition === 'failed') {
				if (outcome.kind !== 'failed' || !(outcome.error.cause instanceof AggregateError))
					throw new Error('Missing browser retirement failures');
				expect(outcome.error.cause.errors.map((error: Error): string => error.message)).toEqual([
					'B retirement failed',
					'C retirement failed',
				]);
			} else {
				await finish.value();
				expect(browserC.closed()).toBe(true);
			}
			expect(browserA.closed()).toBe(true);
			expect(finishReturned).toBe(true);
		} finally {
			lateCloseRelease.resolve();
			await finish.settled;
			await registerSuccessor.settled;
			if (secondAcquisition !== undefined)
				await handleLaunchPromise(secondAcquisition, 'B proof cleanup').settled;
			if (thirdAcquisition !== undefined)
				await handleLaunchPromise(thirdAcquisition, 'C proof cleanup').settled;
			await handleLaunchPromise(
				closeBridgeViewerE2ETestBrowsers(owner.signal),
				'remaining proof cleanup',
			).settled;
		}
	},
);

vi.mock('../../scripts/dev-server/owned-bridge-web-browser-host.ts', () => ({
	startOwnedBridgeWebBrowserHost: async (props: { readonly onSpawn?: (host: unknown) => void }) => {
		let resolveStopped: (cleanup: OwnedBridgeDevelopmentServerCleanup) => void = (): void => {};
		const whenStopped = new Promise<OwnedBridgeDevelopmentServerCleanup>((resolve): void => {
			resolveStopped = resolve;
		});
		const host = {
			whenStopped,
			pid: 0,
			wsEndpoint: 'ws://controlled-browser',
			whenExited: Promise.resolve(),
			stdoutTail: (): string => '',
			stderrTail: (): string => '',
			stop: async () => {
				const cleanup = {
					exitCode: 0,
					exitSignal: null,
					forcedTerminationRequired: false,
					ownedProcessAliveAfterStop: false,
					browserGroups: [],
				};
				resolveStopped(cleanup);
				return cleanup;
			},
		};
		props.onSpawn?.(host);
		return host;
	},
}));

test('V1 resumed aborted A cannot acquire a browser while B is active', async (): Promise<void> => {
	const ownerA = new AbortController();
	const ownerB = new AbortController();
	const browserA = makeControlledBrowser();
	const browserB = makeControlledBrowser();
	const launchChromium = vi
		.spyOn(chromium, 'connect')
		.mockResolvedValueOnce(browserB.browser)
		.mockResolvedValueOnce(browserA.browser);
	ownerA.abort();
	await launchBridgeViewerE2EChromium({ testSignal: ownerB.signal });
	try {
		await expect(launchBridgeViewerE2EChromium({ testSignal: ownerA.signal })).rejects.toThrow();
		expect(launchChromium).toHaveBeenCalledTimes(1);
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
	const launchChromium = vi.spyOn(chromium, 'connect').mockReturnValue(heldLaunch.promise);
	const acquisitionStarted = createControlledPromise<void>();
	launchChromium.mockImplementation(() => {
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

test('aborted browser retirement names its launch and records close start before settlement', async (): Promise<void> => {
	const owner = new AbortController();
	const closeEntered = createControlledPromise<void>();
	const closeRelease = createControlledPromise<void>();
	const browser = makeControlledBrowser(async (): Promise<void> => {
		closeEntered.resolve();
		await closeRelease.promise;
	});
	vi.spyOn(chromium, 'connect').mockResolvedValue(browser.browser);
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	await launchBridgeViewerE2EChromium({ testSignal: owner.signal });
	let finish: Promise<void> | undefined;
	try {
		owner.abort(new Error('held browser retirement probe'));
		await closeEntered.promise;
		const lines = stderr.mock.calls.map(([line]): string => String(line));
		const start = lines.find(
			(line): boolean =>
				line.includes('operation="retire browser"') && line.includes('phase=start'),
		);
		expect(start).toMatch(
			/^BRIDGE_LAUNCH_RETIREMENT waiting=retire browser; timestamp=\d{4}-\d{2}-\d{2}T\S+Z launch=[\da-f-]+ nativeBrowser=true operation="retire browser" phase=start outcome=started\n$/,
		);
		const launchId = start?.match(/ launch=([\da-f-]+) /)?.[1];
		if (launchId === undefined) throw new Error('Missing browser retirement launch identity.');
		const closeSettlements = (): string[] =>
			stderr.mock.calls
				.map(([line]): string => String(line))
				.filter(
					(line): boolean =>
						line.includes(`launch=${launchId} `) &&
						line.includes('operation="retire browser"') &&
						line.includes('phase=settle'),
				);
		expect(closeSettlements()).toEqual([]);
		finish = closeBridgeViewerE2ETestBrowsers(owner.signal);
		expect(browser.closed()).toBe(false);
		closeRelease.resolve();
		await finish;
		expect(browser.closed()).toBe(true);
		expect(closeSettlements()).toEqual([
			expect.stringMatching(
				/^BRIDGE_LAUNCH_RETIREMENT waiting=retire browser; timestamp=\d{4}-\d{2}-\d{2}T\S+Z launch=[\da-f-]+ nativeBrowser=true operation="retire browser" phase=settle outcome=succeeded\n$/,
			),
		]);
	} finally {
		closeRelease.resolve();
		await finish;
		await closeBridgeViewerE2ETestBrowsers(owner.signal);
		stderr.mockRestore();
	}
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
