import { chromium } from 'playwright';
import { expect, test, vi } from 'vitest';

import BridgeWebE2ERunner from '../../tests/e2e/bridge-web-e2e-runner.ts';
import { runBridgeWebE2ETestBody } from '../../tests/e2e/bridge-web-e2e-test-retirement.ts';
import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import { startOwnedBridgeDevelopmentServer } from './bridge-development-server-process.ts';
import { ownNodeFixture, requireProcessAlive } from './bridge-web-chromium-test-support.ts';
import type { BridgeWebTestLaunchDependencies } from './bridge-web-test-launch-contracts.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

test.for(['abort', 'late-ready', 'alive-after-stop', 'runner-join'] as const)(
	'Chromium acquisition retires an owned host: %s',
	async (mode, context) => {
		const fixture = ownNodeFixture("process.stdin.resume(); process.stdout.write('ready\\n')");
		const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
		const owner = new AbortController();
		const entered = makeDeferred<void>();
		const stopped = makeDeferred<void>();
		const release = makeDeferred<void>();
		const terminal = makeDeferred<Error>();

		const stopResult = {
			exitCode: 0,
			exitSignal: null,
			forcedTerminationRequired: false,
			ownedProcessAliveAfterStop: mode === 'alive-after-stop',
			browserGroups: [],
		};
		const host = {
			pid: fixture.child.pid ?? 0,
			wsEndpoint: 'ws://stub',
			whenExited: fixture.exited,
			stdoutTail: (): string => '',
			stderrTail: (): string => '',
			stop: vi.fn(async () => {
				stopped.resolve();
				if (mode === 'runner-join') await release.promise;
				if (mode !== 'alive-after-stop') await fixture.reap();
				terminal.resolve(
					new Error(mode === 'alive-after-stop' ? 'host alive after stop' : 'host stopped'),
				);
				return stopResult;
			}),
		};
		const dependencies = {
			startBackend: startOwnedBridgeDevelopmentServer,
			startBrowserHost: async (props: { readonly onSpawn?: (value: typeof host) => void }) => {
				props.onSpawn?.(host);
				entered.resolve();
				if (mode === 'late-ready') {
					await stopped.promise;
					return host;
				}
				throw await terminal.promise;
			},
		} satisfies BridgeWebTestLaunchDependencies;
		// On main, this makes the missing host seam fail immediately and safely.
		const direct = vi
			.spyOn(chromium, 'launch')
			.mockRejectedValue(new Error('direct launch bypassed owned host'));
		const connect = vi
			.spyOn(chromium, 'connect')
			.mockRejectedValue(new Error('must not connect after abort'));
		const task = { id: `chromium-host-${mode}`, name: `Chromium host ${mode}` };
		const onBound = (): void => {
			release.resolve();
			terminal.resolve(new Error('outer runner bound: held Chromium host'));
			void fixture.reap();
			void decoy.reap();
		};
		context.signal.addEventListener('abort', onBound, { once: true });
		let launch: BridgeWebTestLaunch | undefined;
		let stopReleased = false;
		let boundaryRetired = false;
		let boundary: ReturnType<typeof handleLaunchPromise<void>> | undefined;
		const bodyWork = async (): Promise<void> => {
			launch = await BridgeWebTestLaunch.start({ signal: owner.signal }, dependencies);
			await launch.launchBrowser();
		};
		const body = handleLaunchPromise(
			runBridgeWebE2ETestBody({ signal: owner.signal, task }, bodyWork),
			'host body',
		);
		try {
			await Promise.all([fixture.ready, decoy.ready]);
			expect(
				await Promise.race([
					entered.promise.then((): string => 'host entered'),
					body.settled.then((): string => 'body ended before host'),
				]),
			).toBe('host entered');
			owner.abort(new Error('fixture owner aborted'));
			if (mode === 'runner-join') {
				boundary = handleLaunchPromise(
					BridgeWebE2ERunner.prototype
						.onTaskFinished({ id: task.id, result: { state: 'fail' } })
						.finally((): void => {
							boundaryRetired = true;
							expect(stopReleased).toBe(true);
						}),
					'host runner join',
				);
				await stopped.promise;
				expect(boundaryRetired).toBe(false);
				stopReleased = true;
				release.resolve();
			}
			await expect(body.value()).rejects.toThrow(
				'BridgeWeb launch aborted during Chromium acquisition',
			);
			if (mode === 'alive-after-stop') {
				await expect(body.value()).rejects.toThrow('host alive after stop');
				await expect(launch?.dispose()).rejects.toThrow();
			} else {
				await launch?.dispose();
				await fixture.exited;
			}
			if (boundary !== undefined)
				await expect(boundary.value()).rejects.toThrow(
					'BridgeWeb launch aborted during Chromium acquisition',
				);
			expect(connect).not.toHaveBeenCalled();
			expect(host.stop).toHaveBeenCalled();
			requireProcessAlive(decoy.child.pid);
		} finally {
			context.signal.removeEventListener('abort', onBound);
			stopReleased = true;
			release.resolve();
			terminal.resolve(new Error('red cleanup'));
			owner.abort(new Error('test cleanup'));
			await fixture.reap();
			await decoy.reap();
			await body.settled;
			await handleLaunchPromise(
				launch?.dispose().then((): void => {}) ?? Promise.resolve(),
				'final disposal',
			).settled;
			await boundary?.settled;
			await handleLaunchPromise(
				BridgeWebE2ERunner.prototype.onTaskFinished({ id: task.id, result: { state: 'fail' } }),
				'final runner cleanup',
			).settled;
			direct.mockRestore();
			connect.mockRestore();
		}
	},
);
