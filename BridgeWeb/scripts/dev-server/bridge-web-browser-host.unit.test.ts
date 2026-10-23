import { spawn } from 'node:child_process';

import { chromium, type Browser } from 'playwright';
import { expect, test, vi } from 'vitest';

import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import {
	startOwnedBridgeDevelopmentServer,
	type OwnedBridgeDevelopmentServerCleanup,
} from './bridge-development-server-process.ts';
import { ownNodeFixture, requireProcessAlive } from './bridge-web-chromium-test-support.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

// Dynamic import leaves the original harness red runnable before the new owner exists.
const hostModule = async (): Promise<typeof import('./owned-bridge-web-browser-host.ts')> =>
	await import('./owned-bridge-web-browser-host.ts');

test.each(['spawn-error', 'early-exit', 'failed-line'] as const)(
	'browser host acquisition has a terminal exit: %s',
	async (mode) => {
		const { startOwnedBridgeWebBrowserHost } = await hostModule();
		const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
		const child =
			mode === 'spawn-error'
				? spawn('/bridge-web-proof-executable-does-not-exist', [], {
						stdio: ['pipe', 'pipe', 'pipe'],
					})
				: spawn(
						process.execPath,
						[
							'--eval',
							mode === 'early-exit'
								? 'process.exit(12)'
								: `process.stdin.resume(); process.stdout.write(JSON.stringify({kind:'failed',message:'fixture terminal launch failure'})+'\\n')`,
						],
						{ stdio: ['pipe', 'pipe', 'pipe'] },
					);
		const ended = new Promise<void>((resolve): void => {
			child.once('exit', (): void => resolve());
			child.once('error', (): void => resolve());
		});
		try {
			const starting = startOwnedBridgeWebBrowserHost({ options: {} }, { spawnChild: () => child });
			await expect(starting).rejects.toThrow(
				mode === 'spawn-error'
					? 'spawn'
					: mode === 'early-exit'
						? 'exited before readiness'
						: 'fixture terminal launch failure',
			);
			await ended;
			await decoy.ready;
			requireProcessAlive(decoy.child.pid);
		} finally {
			child.kill('SIGKILL');
			await ended;
			await decoy.reap();
		}
	},
);

test('a final failed host stop settles real readiness without an exit', async (context) => {
	const { startOwnedBridgeWebBrowserHost } = await hostModule();
	const fixture = ownNodeFixture(
		"process.stdin.resume(); process.stdout.write('held before readiness\\n')",
	);
	const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
	await Promise.all([fixture.ready, decoy.ready]);
	const kill = vi.spyOn(fixture.child, 'kill').mockReturnValue(true);
	const owner = new AbortController();
	const registered = makeDeferred<void>();
	vi.useFakeTimers();
	const launch = await BridgeWebTestLaunch.start(
		{ signal: owner.signal },
		{
			startBackend: startOwnedBridgeDevelopmentServer,
			startBrowserHost: async (props) =>
				await startOwnedBridgeWebBrowserHost(
					{
						...props,
						onSpawn: (host): void => {
							props.onSpawn?.(host);
							registered.resolve();
						},
					},
					{ spawnChild: () => fixture.child },
				),
		},
	);
	const onBound = (): void => {
		kill.mockRestore();
		vi.useRealTimers();
		void fixture.reap();
		void decoy.reap();
	};
	context.signal.addEventListener('abort', onBound, { once: true });
	const acquisition = handleLaunchPromise(launch.launchBrowser(), 'failed host stop acquisition');
	try {
		await registered.promise;
		owner.abort(new Error('stop cannot end host'));
		// Drive only the unchanged two shutdown escalation bounds.
		await vi.advanceTimersByTimeAsync(20_000);
		await expect(acquisition.value()).rejects.toThrow('host alive after stop');
		await expect(launch.dispose()).rejects.toThrow();
		expect(kill.mock.calls.map(([signal]) => signal)).toEqual(['SIGTERM', 'SIGKILL']);
		expect(launch.cleanup.dataRootRemoved).toBe(true);
		requireProcessAlive(decoy.child.pid);
	} finally {
		context.signal.removeEventListener('abort', onBound);
		kill.mockRestore();
		vi.useRealTimers();
		await fixture.reap();
		await decoy.reap();
		await acquisition.settled;
		await handleLaunchPromise(launch.dispose(), 'failed stop cleanup').settled;
	}
});

test('browser.close joins host retirement while leaving its launch usable', async () => {
	const fixture = ownNodeFixture("process.stdin.resume(); process.stdout.write('ready\\n')");
	const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
	await Promise.all([fixture.ready, decoy.ready]);
	let connected = true;
	const controlled = {
		contexts: (): [] => [],
		close: async (): Promise<void> => {
			connected = false;
		},
		isConnected: (): boolean => connected,
	} as unknown as Browser;
	const connect = vi.spyOn(chromium, 'connect').mockResolvedValue(controlled);
	const direct = vi
		.spyOn(chromium, 'launch')
		.mockRejectedValue(new Error('direct launch bypassed owned host'));
	const launch = await BridgeWebTestLaunch.start(
		{},
		{
			startBackend: startOwnedBridgeDevelopmentServer,
			startBrowserHost: async (props) => {
				const stopped = makeDeferred<OwnedBridgeDevelopmentServerCleanup>();
				const host = {
					pid: fixture.child.pid ?? 0,
					wsEndpoint: 'ws://fixture',
					whenExited: fixture.exited,
					whenStopped: stopped.promise,
					stdoutTail: (): string => '',
					stderrTail: (): string => '',
					stop: async () => {
						await fixture.reap();
						const cleanup = {
							exitCode: null,
							exitSignal: 'SIGKILL' as const,
							forcedTerminationRequired: false,
							ownedProcessAliveAfterStop: false,
							browserGroups: [],
						};
						stopped.resolve(cleanup);
						return cleanup;
					},
				};
				props.onSpawn?.(host);
				return host;
			},
		},
	);
	try {
		const browser = await launch.launchBrowser();
		await browser.close();
		// EOF/exit is the receipt, rather than a mocked stop-call assertion.
		expect(fixture.hasExited()).toBe(true);
		expect(browser.isConnected()).toBe(false);
		expect(launch.cleanup.dataRootRemoved).toBe(false);
		requireProcessAlive(decoy.child.pid);
	} finally {
		await fixture.reap();
		await decoy.reap();
		await launch.dispose();
		connect.mockRestore();
		direct.mockRestore();
	}
});
