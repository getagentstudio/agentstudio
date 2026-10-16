import { access } from 'node:fs/promises';

import { chromium, type Browser } from 'playwright';
import { expect, test, vi } from 'vitest';

import {
	currentBridgeWebLaunchScope,
	runWithBridgeWebLaunchScope,
} from '../../scripts/dev-server/bridge-web-test-launch-scope.ts';
import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { makeDeferred } from '../../scripts/verify-bridge-viewer-worktree-dev-server/utils.ts';
import { createOwnedVerifierJourneyDeadline } from '../../scripts/verify-bridge-viewer-worktree-dev-server/verifier-journey-deadline.ts';
import { endToEndTestTimeoutMilliseconds } from '../vitest-hang-bounds.ts';
import {
	closeBridgeViewerE2ETestBrowsers,
	launchBridgeViewerE2EChromium,
} from './bridge-viewer-vite-e2e-browser.ts';
import { createTabOwnershipReplacementHold } from './bridge-viewer-vite-tab-ownership-test-support.ts';
import BridgeWebE2ERunner from './bridge-web-e2e-runner.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

test('a failed body names its already-pending browser close and joins it across owner abort', async () => {
	const owner = new AbortController();
	const closeEntered = makeDeferred<void>();
	const closeRelease = makeDeferred<void>();
	const primaryFailure = new Error('named journey operation failed');
	let connected = true;
	let nativeCloseCount = 0;
	let bodyRetired = false;
	let boundaryRetired = false;
	const controlledBrowser = {
		close: async (): Promise<void> => {
			nativeCloseCount += 1;
			closeEntered.resolve();
			await closeRelease.promise;
			connected = false;
		},
		contexts: (): [] => [],
		isConnected: (): boolean => connected,
		on: (): void => {},
	} as unknown as Browser;
	const launchChromium = vi.spyOn(chromium, 'launch').mockResolvedValue(controlledBrowser);
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const task = { id: 'tq127-failed-body-close', name: 'TQ127 failed journey browser retirement' };
	const body = handleLaunchPromise(
		runBridgeWebE2ETestBody({ signal: owner.signal, task }, async (): Promise<void> => {
			const browser = await launchBridgeViewerE2EChromium({ testSignal: owner.signal });
			try {
				throw primaryFailure;
			} finally {
				await browser.close();
				bodyRetired = true;
			}
		}),
		'TQ127 failed raw body',
	);
	let boundary: ReturnType<typeof handleLaunchPromise<void>> | undefined;
	try {
		await closeEntered.promise;
		owner.abort(new Error('TQ127 owner aborted during physical retirement'));
		boundary = handleLaunchPromise(
			BridgeWebE2ERunner.prototype
				.onTaskFinished({ id: task.id, result: { state: 'fail' } })
				.finally((): void => {
					boundaryRetired = true;
				}),
			'TQ127 runner physical retirement',
		);
		expect(stderr).toHaveBeenCalledWith(
			expect.stringMatching(
				/^BRIDGE_E2E_ABORT waiting=body retirement: TQ127 failed journey browser retirement; launch=(?<launch>[\da-f-]+) nativeBrowser=true operation="retire browser"(?:, launch=\k<launch> nativeBrowser=true operation="retire (?:Vite child|Swift backend)"){0,2}\n$/,
			),
		);
		expect(nativeCloseCount).toBe(1);
		expect(bodyRetired).toBe(false);
		expect(boundaryRetired).toBe(false);
		expect(controlledBrowser.isConnected()).toBe(true);
		closeRelease.resolve();
		await boundary.settled;
		await expect(body.value()).rejects.toThrow(primaryFailure.message);
		await expect(boundary.value()).rejects.toThrow(primaryFailure.message);
		expect(nativeCloseCount).toBe(1);
		expect(bodyRetired).toBe(true);
		expect(boundaryRetired).toBe(true);
		expect(controlledBrowser.isConnected()).toBe(false);
	} finally {
		closeRelease.resolve();
		await body.settled;
		await boundary?.settled;
		await closeBridgeViewerE2ETestBrowsers(owner.signal);
		launchChromium.mockRestore();
		stderr.mockRestore();
	}
});

test.each(['completed', 'failed'] as const)(
	'final retirement joins A registering B registering held C: %s',
	async (disposition) => {
		const owner = new AbortController();
		const cleanupEntered = makeDeferred<void>();
		const cleanupRelease = makeDeferred<void>();
		const ownedLaunches: BridgeWebTestLaunch[] = [];
		const taskId = `late-registration-${disposition}`;
		await runBridgeWebE2ETestBody(
			{ signal: owner.signal, task: { id: taskId, name: taskId } },
			async (): Promise<void> => {
				const scope = currentBridgeWebLaunchScope();
				if (scope === undefined) throw new Error('Test body has no launch scope');
				const ownLaunch = async (name: string, retire: () => Promise<void>): Promise<void> => {
					const launch = await BridgeWebTestLaunch.start();
					ownedLaunches.push(launch);
					launch.ownFixture(`${name} retirement`, async (): Promise<void> => {
						await runWithBridgeWebLaunchScope(scope, retire);
						if (disposition === 'failed') throw new Error(`${name} retirement failed`);
					});
				};
				await ownLaunch('A', async (): Promise<void> => {
					await ownLaunch('B', async (): Promise<void> => {
						await ownLaunch('C', async (): Promise<void> => {
							cleanupEntered.resolve();
							await cleanupRelease.promise;
						});
					});
				});
			},
		);
		let finishReturned = false;
		const boundary = handleLaunchPromise(
			BridgeWebE2ERunner.prototype
				.onTaskFinished({ id: taskId, result: { state: 'pass' } })
				.finally((): void => {
					finishReturned = true;
				}),
			'late registration runner boundary',
		);
		try {
			const firstFact = await Promise.race([
				boundary.settled.then((): string => 'finished'),
				cleanupEntered.promise.then((): string => 'C cleanup entered'),
			]);
			expect(firstFact).toBe('C cleanup entered');
			expect(finishReturned).toBe(false);
			expect(ownedLaunches[2]?.cleanup.dataRootRemoved).toBe(false);
			cleanupRelease.resolve();
			const outcome = await boundary.settled;
			if (disposition === 'failed') {
				expect(outcome).toMatchObject({
					kind: 'failed',
					error: { cause: { errors: expect.any(Array) } },
				});
				if (outcome.kind !== 'failed' || !(outcome.error.cause instanceof AggregateError))
					throw new Error('Missing G4 retirement verdict');
				expect(outcome.error.cause.errors.map((error: Error): string => error.message)).toEqual([
					expect.stringContaining('A retirement'),
					expect.stringContaining('B retirement'),
					expect.stringContaining('C retirement'),
				]);
			} else await boundary.value();
			expect(finishReturned).toBe(true);
			expect(ownedLaunches).toHaveLength(3);
			for (const launch of ownedLaunches)
				await expect(access(launch.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
		} finally {
			cleanupRelease.resolve();
			await boundary.settled;
			// Red cleanup: include any launch the old snapshot drain missed.
			for (const launch of ownedLaunches)
				await handleLaunchPromise(launch.dispose(), 'red proof cleanup').settled;
		}
	},
);

test('the actual runner boundary joins held fixture cleanup and the timed-out raw body', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const fixtureReady = makeDeferred<void>();
	const cleanupStarted = makeDeferred<void>();
	const cleanupRelease = makeDeferred<void>();
	let launch: BridgeWebTestLaunch | undefined;
	let bodyRetired = false;
	let nextTestEntered = false;
	const deadline = createOwnedVerifierJourneyDeadline({
		pendingSteps: (): readonly string[] => launch?.pendingSteps ?? ['test body'],
		closePages: async (): Promise<void> => {},
	});
	const body = handleLaunchPromise(
		runBridgeWebE2ETestBody(
			{ signal: deadline.signal, task: { id: 'held-retirement', name: 'held fixture retirement' } },
			async (): Promise<void> => {
				launch = await BridgeWebTestLaunch.start();
				launch.ownFixture('held fixture cleanup', async (): Promise<void> => {
					cleanupStarted.resolve();
					await cleanupRelease.promise;
				});
				fixtureReady.resolve();
				try {
					await new Promise<void>((resolve): void => {
						deadline.signal.addEventListener('abort', (): void => resolve(), { once: true });
					});
				} finally {
					await launch.dispose();
					bodyRetired = true;
				}
			},
		),
		'raw E2E body',
	);
	try {
		await fixtureReady.promise;
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		const boundary = handleLaunchPromise(
			BridgeWebE2ERunner.prototype
				.onTaskFinished({ id: 'held-retirement', result: { state: 'fail' } })
				.then((): void => {
					nextTestEntered = true;
				}),
			'actual task boundary',
		);
		await cleanupStarted.promise;
		expect(stderr).toHaveBeenCalledWith(
			expect.stringMatching(
				/^BRIDGE_LAUNCH_RETIREMENT waiting=retire held fixture cleanup; timestamp=\S+Z launch=[\da-f-]+ nativeBrowser=false operation="retire held fixture cleanup" phase=start outcome=started\n$/,
			),
		);
		expect(nextTestEntered).toBe(false);
		expect(bodyRetired).toBe(false);
		cleanupRelease.resolve();
		await boundary.value();
		expect(bodyRetired).toBe(true);
		expect(nextTestEntered).toBe(true);
		expect(launch?.cleanup.dataRootRemoved).toBe(true);
		if (launch === undefined) throw new Error('Owned fixture launch missing.');
		await expect(access(launch.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
	} finally {
		cleanupRelease.resolve();
		await body.settled;
		await deadline.dispose();
		await launch?.dispose();
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('the unchanged runner hang bound retires a tab replacement whose native commit never arrives', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const entered = makeDeferred<void>();
	const resourceRetired = makeDeferred<void>();
	let launch: BridgeWebTestLaunch | undefined;
	let bodyRetired = false;
	const deadline = createOwnedVerifierJourneyDeadline({
		pendingSteps: (): readonly string[] => launch?.pendingSteps ?? ['TQ109 held native commit'],
		closePages: async (): Promise<void> => {},
	});
	const replacementHold = createTabOwnershipReplacementHold(deadline.signal);
	const body = handleLaunchPromise(
		runBridgeWebE2ETestBody(
			{
				signal: deadline.signal,
				task: { id: 'tq116-held-commit', name: 'TQ116 held native replacement commit' },
			},
			async (): Promise<void> => {
				launch = await BridgeWebTestLaunch.start();
				launch.ownFixture(
					'TQ116 resource retirement',
					async (): Promise<void> => resourceRetired.resolve(),
				);
				try {
					const waiting = launch.observeStep(
						'TQ109 first-tab replacement native commit held before Main delivery',
						replacementHold.committed.promise,
					);
					entered.resolve();
					await waiting.value();
				} finally {
					replacementHold.dispose();
					await launch.dispose();
					bodyRetired = true;
				}
			},
		),
		'TQ116 raw body',
	);
	let boundary: ReturnType<typeof handleLaunchPromise<void>> | undefined;
	try {
		await entered.promise;
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		expect(deadline.signal.aborted).toBe(true);
		boundary = handleLaunchPromise(
			BridgeWebE2ERunner.prototype.onTaskFinished({
				id: 'tq116-held-commit',
				result: { state: 'fail' },
			}),
			'TQ116 actual runner boundary',
		);
		await resourceRetired.promise;
		// Resource close is the correlated end of abort disposal. The local commit
		// observation must already be terminal; no extra clock or turn may decide it.
		await expect(
			Promise.race([
				replacementHold.committed.promise,
				Promise.reject(
					new Error(
						'TQ109 native commit still pending after runner expiry and owned resource retirement',
					),
				),
			]),
		).rejects.toThrow('TQ109 held native commit owner aborted');
		await boundary.settled;
		expect(bodyRetired).toBe(true);
		await expect(body.value()).rejects.toThrow('TQ109 held native commit owner aborted');
		expect(launch?.cleanup.dataRootRemoved).toBe(true);
	} finally {
		// Settle the old unowned deferred after the red assertion, so the proof
		// itself never waits for a second timeout and never leaves a detached body.
		replacementHold.committed.reject(new Error('TQ116 red proof cleanup'));
		replacementHold.dispose();
		await body.settled;
		await boundary?.settled;
		await launch?.dispose();
		await deadline.dispose();
		stderr.mockRestore();
		vi.useRealTimers();
	}
});
