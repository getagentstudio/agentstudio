import { access } from 'node:fs/promises';

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
import BridgeWebE2ERunner from './bridge-web-e2e-runner.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

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
			'BRIDGE_LAUNCH_RETIREMENT waiting=retire held fixture cleanup\n',
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
