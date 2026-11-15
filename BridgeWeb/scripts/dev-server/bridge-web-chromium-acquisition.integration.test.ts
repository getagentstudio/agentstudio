import { expect, test } from 'vitest';

import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import { startOwnedBridgeDevelopmentServer } from './bridge-development-server-process.ts';
import { spawnBrowserHostFixture } from './bridge-web-chromium-host.test-support.ts';
import {
	createStuckChromiumFixture,
	ownNodeFixture,
	requireProcessAlive,
} from './bridge-web-chromium-test-support.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';
import {
	startOwnedBridgeWebBrowserHost,
	type OwnedBridgeWebBrowserHost,
} from './owned-bridge-web-browser-host.ts';

test.for(['ordinary', 'forced', 'unreported'] as const)(
	'abort retires a real Playwright-spawned stuck Chromium: %s',
	async (mode, context) => {
		const stub = await createStuckChromiumFixture();
		const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
		const owner = new AbortController();
		const reported = makeDeferred<void>();
		let host: OwnedBridgeWebBrowserHost | undefined;
		let hostOutput = '';
		const launch = await BridgeWebTestLaunch.start(
			{ signal: owner.signal },
			{
				startBackend: startOwnedBridgeDevelopmentServer,
				startBrowserHost: async (props) =>
					await startOwnedBridgeWebBrowserHost(
						{
							...props,
							onSpawn: (value): void => {
								host = value;
								props.onSpawn?.(value);
							},
						},
						{
							spawnChild: () => {
								const child = spawnBrowserHostFixture({
									options: props.options,
									ignoreSIGTERM: mode !== 'ordinary',
									suppressGroupReport: mode === 'unreported',
								});
								child.stdout.on('data', (chunk: Buffer): void => {
									hostOutput += String(chunk);
									if (hostOutput.includes('"kind":"browserSpawned"')) reported.resolve();
								});
								return child;
							},
						},
					),
			},
		);
		const acquisition = handleLaunchPromise(
			launch.launchBrowser({ executablePath: stub.executablePath, headless: true }),
			'real stuck Chromium',
		);
		const reapOnBound = (): void => {
			process.stdout.write('CHROMIUM_STUB_RESCUE outerBound=true\n');
			void stub.reap();
		};
		context.signal.addEventListener('abort', reapOnBound, { once: true });
		try {
			const pid = await Promise.race([
				stub.ready,
				acquisition.value().then((): never => {
					throw new Error('stub unexpectedly launched');
				}),
			]);
			await decoy.ready;
			if (mode !== 'unreported') await Promise.race([reported.promise, acquisition.value()]);
			owner.abort(new Error('real stub owner aborted'));
			await expect(acquisition.value()).rejects.toThrow(
				'BridgeWeb launch aborted during Chromium acquisition',
			);
			if (host === undefined) throw new Error('No owned host was registered');
			const cleanup = await host.stop();
			await host.whenExited;
			if (mode === 'unreported') {
				await expect(acquisition.value()).rejects.toThrow('browser groups none reported');
				expect(stub.hasEnded()).toBe(false);
				// The accepted wedged/unreported-spawn residual is explicit. The outer
				// fixture owner, which knows this PID from the FIFO, reaps its own stub.
				await stub.reap();
			} else {
				expect(cleanup.browserGroups).toEqual([expect.objectContaining({ pid })]);
				if (mode === 'ordinary') expect(cleanup.forcedTerminationRequired).toBe(false);
				if (mode === 'forced') {
					expect(cleanup.forcedTerminationRequired).toBe(true);
				}
				// A signal-zero group snapshot is diagnostic, not the death oracle. EOF
				// from this still-open writer must arrive before outer fixture rescue.
				await stub.eof;
				context.signal.throwIfAborted();
				process.stdout.write(
					`CHROMIUM_STUB_RETIRED mode=${mode} naturalFIFO=EOF groups=${JSON.stringify(cleanup.browserGroups)}\n`,
				);
			}
			await launch.dispose();
			expect(launch.cleanup.dataRootRemoved).toBe(true);
			requireProcessAlive(decoy.child.pid);
		} finally {
			context.signal.removeEventListener('abort', reapOnBound);
			owner.abort(new Error('test cleanup'));
			await stub.reap();
			await decoy.reap();
			await acquisition.settled;
			await launch.dispose();
		}
	},
);
