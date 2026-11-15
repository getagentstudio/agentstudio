import { EventEmitter } from 'node:events';

import { chromium, type Browser, type BrowserContext } from 'playwright';
import { expect, test, vi } from 'vitest';

import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import {
	startOwnedBridgeDevelopmentServer,
	type OwnedBridgeDevelopmentServerCleanup,
} from './bridge-development-server-process.ts';
import { ownNodeFixture, requireProcessAlive } from './bridge-web-chromium-test-support.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';
import {
	startOwnedBridgeWebBrowserHost,
	type OwnedBridgeWebBrowserHost,
} from './owned-bridge-web-browser-host.ts';

test('a ready host final failed stop ends held connect before late Browser cleanup', async (context) => {
	const fixture = ownNodeFixture(
		"process.stdin.resume(); process.stdout.write('armed\\n'); process.stdin.once('data', () => process.stdout.write(JSON.stringify({kind:'ready',wsEndpoint:'ws://fixture'})+'\\n'))",
	);
	const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
	await Promise.all([fixture.ready, decoy.ready]);
	const owner = new AbortController();
	const connectEntered = makeDeferred<void>();
	const releaseConnect = makeDeferred<Browser>();
	const lateClosed = makeDeferred<void>();
	let released = false;
	let connected = true;
	const browser = {
		contexts: (): [] => [],
		close: async (): Promise<void> => {
			connected = false;
			lateClosed.resolve();
		},
		isConnected: (): boolean => connected,
	} as unknown as Browser;
	const connect = vi.spyOn(chromium, 'connect').mockImplementation(async (): Promise<Browser> => {
		connectEntered.resolve();
		return await releaseConnect.promise;
	});
	const kill = vi.spyOn(fixture.child, 'kill').mockReturnValue(true);
	let host: OwnedBridgeWebBrowserHost | undefined;
	vi.useFakeTimers();
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
							fixture.child.stdin.write('announce\n');
						},
					},
					{ spawnChild: () => fixture.child },
				),
		},
	);
	const acquisition = handleLaunchPromise(launch.launchBrowser(), 'held connect final failed stop');
	const onBound = (): void => {
		process.stdout.write('CHROMIUM_CONNECT_RESCUE outerBound=true lateConnectReleased=true\n');
		released = true;
		releaseConnect.resolve(browser);
		kill.mockRestore();
		vi.useRealTimers();
		void fixture.reap();
		void decoy.reap();
	};
	context.signal.addEventListener('abort', onBound, { once: true });
	try {
		await Promise.race([
			connectEntered.promise,
			acquisition.value().then((): never => {
				throw new Error('connect ended before arrival');
			}),
		]);
		owner.abort(new Error('connect owner aborted'));
		const disposal = handleLaunchPromise(launch.dispose(), 'failed host connect disposal');
		await vi.advanceTimersByTimeAsync(20_000);
		if (host === undefined) throw new Error('Host was not registered');
		expect((await host.stop()).ownedProcessAliveAfterStop).toBe(true);
		// No release of connect may be needed to settle acquisition or disposal.
		await expect(acquisition.value()).rejects.toThrow('host alive after stop');
		const disposalOutcome = await disposal.settled;
		if (disposalOutcome.kind !== 'failed')
			throw new Error('Final failed stop did not fail disposal');
		expect(collectErrorMessages(disposalOutcome.error)).toContain(
			'Owned browser host alive after stop.',
		);
		expect(released).toBe(false);
		expect(connected).toBe(true);
		expect(kill.mock.calls.map(([signal]) => signal)).toEqual(['SIGTERM', 'SIGKILL']);
		process.stdout.write(
			'CHROMIUM_CONNECT_EXIT acquisition=failed disposal=failed hostAlive=true connectReleased=false\n',
		);
		released = true;
		releaseConnect.resolve(browser);
		await lateClosed.promise;
		expect(connected).toBe(false);
		requireProcessAlive(decoy.child.pid);
		process.stdout.write('CHROMIUM_CONNECT_LATE browserClosed=true\n');
	} finally {
		context.signal.removeEventListener('abort', onBound);
		released = true;
		releaseConnect.resolve(browser);
		kill.mockRestore();
		vi.useRealTimers();
		await fixture.reap();
		await decoy.reap();
		await acquisition.settled;
		await handleLaunchPromise(launch.dispose(), 'final connect fixture disposal').settled;
		connect.mockRestore();
	}
});

test('harness retirement joins an already-closing context event before disconnect', async () => {
	const fixture = ownNodeFixture("process.stdin.resume(); process.stdout.write('ready\\n')");
	const decoy = ownNodeFixture("process.stdin.resume(); process.stdout.write('decoy\\n')");
	await Promise.all([fixture.ready, decoy.ready]);
	const eventOwner = new EventEmitter();
	const closeEntered = makeDeferred<void>();
	let closeEventReleased = false;
	let connected = true;
	const closingContext = Object.assign(eventOwner, {
		close: async (): Promise<void> => {
			closeEntered.resolve();
		},
	}) as unknown as BrowserContext;
	const disconnect = vi.fn(async (): Promise<void> => {
		expect(closeEventReleased).toBe(true);
		connected = false;
	});
	const browser = {
		contexts: (): BrowserContext[] => [closingContext],
		close: disconnect,
		isConnected: (): boolean => connected,
	} as unknown as Browser;
	const connect = vi.spyOn(chromium, 'connect').mockResolvedValue(browser);
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
						return {
							exitCode: 0,
							exitSignal: null,
							forcedTerminationRequired: false,
							ownedProcessAliveAfterStop: false,
						};
					},
				};
				props.onSpawn?.(host);
				return host;
			},
		},
	);
	let retirement: ReturnType<typeof handleLaunchPromise<void>> | undefined;
	try {
		const acquired = await launch.launchBrowser();
		// The first caller's close is underway: subsequent close() calls fulfill
		// immediately, while only the held event announces actual retirement.
		await closingContext.close();
		retirement = handleLaunchPromise(acquired.close(), 'already-closing context retirement');
		await closeEntered.promise;
		expect(eventOwner.listenerCount('close')).toBe(1);
		expect(disconnect).not.toHaveBeenCalled();
		closeEventReleased = true;
		eventOwner.emit('close');
		await retirement.value();
		expect(disconnect).toHaveBeenCalledOnce();
		expect(connected).toBe(false);
		requireProcessAlive(decoy.child.pid);
	} finally {
		closeEventReleased = true;
		eventOwner.emit('close');
		await fixture.reap();
		await decoy.reap();
		await retirement?.settled;
		await handleLaunchPromise(launch.dispose(), 'final context fixture disposal').settled;
		connect.mockRestore();
	}
});

function collectErrorMessages(error: unknown): string[] {
	if (!(error instanceof Error)) return [String(error)];
	return [
		error.message,
		...(error.cause === undefined ? [] : collectErrorMessages(error.cause)),
		...(error instanceof AggregateError ? error.errors.flatMap(collectErrorMessages) : []),
	];
}
