import { access } from 'node:fs/promises';

import { expect, test, vi } from 'vitest';

import { BridgeWebTestLaunch } from '../../scripts/dev-server/bridge-web-test-launch.ts';
import { handleLaunchPromise } from '../../scripts/dev-server/handled-launch-promise.ts';
import { makeDeferred } from '../../scripts/verify-bridge-viewer-worktree-dev-server/utils.ts';
import { createOwnedVerifierJourneyDeadline } from '../../scripts/verify-bridge-viewer-worktree-dev-server/verifier-journey-deadline.ts';
import { endToEndTestTimeoutMilliseconds } from '../vitest-hang-bounds.ts';
import BridgeWebE2ERunner from './bridge-web-e2e-runner.ts';
import { runBridgeWebE2ETestBody } from './bridge-web-e2e-test-retirement.ts';

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
