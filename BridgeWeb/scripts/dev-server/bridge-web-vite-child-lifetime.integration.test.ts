import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { access, readdir, rm } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

import { expect, test, vi } from 'vitest';

import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';
import { BridgeViewerOwnedViteServer } from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-regression.ts';
import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { createBridgeWebVerifierModuleLoader } from './bridge-web-verifier-module-loader.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

const bridgeWebRootPath = fileURLToPath(new URL('../../', import.meta.url));

// A real child owns the cache writer. TERM announces retirement while its final
// write/exit is held by stdin; no library hook or fake exit supplies the join.
test.each(['startup expiry', 'held writer'] as const)(
	'child exit precedes root removal during %s',
	async (phase) => {
		if (phase === 'startup expiry') vi.useFakeTimers();
		const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
		const entered = makeDeferred<void>();
		const stopping = makeDeferred<void>();
		let child: ChildProcessWithoutNullStreams | undefined;
		const launch = await BridgeWebTestLaunch.start(
			{},
			{
				startBackend: async () => {
					throw new Error('No backend needed for process-lifetime proof');
				},
				startViteChild: async (props) =>
					await BridgeViewerOwnedViteServer.start(props, {
						spawnChild: (processProps): ChildProcessWithoutNullStreams => {
							child = spawn(
								process.execPath,
								[
									'--input-type=module',
									'--eval',
									`
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const cache = process.env.BRIDGE_WEB_VITE_CACHE_DIR;
mkdirSync(cache, {recursive:true});
writeFileSync(join(cache, 'held-writer'), 'owned');
process.stdin.resume();
process.on('SIGTERM', () => {
  process.stdout.write('stopping\\n');
  process.stdin.once('data', () => {
    writeFileSync(join(cache, 'final-write'), 'retired');
    process.exit(0);
  });
});
process.stdout.write('entered\\n');
if (${JSON.stringify(phase === 'held writer')}) process.stdout.write('http://127.0.0.1:${processProps.port}/\\n');
`,
								],
								{ env: processProps.environment, stdio: ['pipe', 'pipe', 'pipe'] },
							);
							const lines = createInterface({ input: child.stdout });
							lines.on('line', (line): void => {
								if (line === 'entered') entered.resolve();
								if (line === 'stopping') stopping.resolve();
							});
							child.once('close', (): void => lines.close());
							return child;
						},
					}),
			},
		);
		const starting = handleLaunchPromise(
			launch.startViteChild({
				bridgeWebRootPath,
				bridgeDevelopmentServerOrigin: 'http://127.0.0.1:1',
			}),
			'held child readiness',
		);
		let disposal: ReturnType<typeof handleLaunchPromise> | null = null;
		try {
			await entered.promise;
			if (phase === 'held writer') {
				await starting.value();
				disposal = handleLaunchPromise(launch.dispose(), 'held child disposal');
			} else {
				await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
				expect(String(launch.signal.reason)).toContain('waiting=Vite readiness');
			}
			await stopping.promise;
			// This event is emitted by the child while it can still write. A root
			// removed before exit is causally wrong regardless of machine speed.
			await expect(access(launch.dataRootPath)).resolves.toBeUndefined();
			expect(launch.cleanup.dataRootRemoved).toBe(false);
			child?.stdin.write('finish\n');
			if (phase === 'startup expiry')
				await expect(starting.value()).rejects.toThrow('waiting=Vite readiness');
			else await disposal?.value();
			await launch.dispose();
			expect(launch.cleanup.viteProcess?.exitCode).toBe(0);
			expect(launch.cleanup.viteProcess?.ownedProcessAliveAfterStop).toBe(false);
			expect(launch.cleanup.dataRootRemoved).toBe(true);
			await expect(access(launch.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
		} finally {
			child?.stdin.write('finish\n');
			await starting.settled;
			await disposal?.settled;
			await handleLaunchPromise(launch.dispose(), 'proof cleanup').settled;
			stderr.mockRestore();
			vi.useRealTimers();
		}
	},
);

test.each(['delivered', 'missing'] as const)(
	'response closure subscription is retired by child exit: %s',
	async (mode) => {
		let child: ChildProcessWithoutNullStreams | undefined;
		const launch = await BridgeWebTestLaunch.start(
			{},
			{
				startBackend: async () => {
					throw new Error('No backend needed');
				},
				startViteChild: async (props) =>
					await BridgeViewerOwnedViteServer.start(props, {
						spawnChild: (processProps): ChildProcessWithoutNullStreams => {
							child = spawn(
								process.execPath,
								[
									'--eval',
									`
process.stdin.resume();
process.stdout.write('http://127.0.0.1:${processProps.port}/\\n');
process.stdin.once('data', () => {
  if (${JSON.stringify(mode === 'delivered')}) process.stdout.write('BRIDGE_WEB_VITE_RESPONSE_FACT '+JSON.stringify({kind:'metadata-response-closed',requestSequence:1,route:'/__bridge-product/stream?subscription=fixture'})+'\\n');
  process.exit(0);
});
`,
								],
								{ env: processProps.environment, stdio: ['pipe', 'pipe', 'pipe'] },
							);
							return child;
						},
					}),
			},
		);
		try {
			const vite = await launch.startViteChild({
				bridgeWebRootPath,
				bridgeDevelopmentServerOrigin: 'http://127.0.0.1:1',
				observeMetadataResponses: true,
			});
			const facts = launch.observeViteMetadataResponses('fixture metadata response close');
			const next = handleLaunchPromise(facts.next(), 'fixture close fact');
			child?.stdin.write('stimulus\n');
			if (mode === 'delivered')
				expect(await next.value()).toMatchObject({
					requestSequence: 1,
					route: '/__bridge-product/stream?subscription=fixture',
				});
			else
				await expect(next.value()).rejects.toThrow(
					'Vite response facts ended waiting=fixture metadata response close',
				);
			await launch.dispose();
			expect(vite.responseFacts.subscriberCount).toBe(0);
			expect(launch.cleanup.dataRootRemoved).toBe(true);
		} finally {
			await launch.dispose();
		}
	},
);

test('module loader evaluates outside the launch root even with a product cache environment', async () => {
	const launch = await BridgeWebTestLaunch.start();
	const previousCache = process.env['BRIDGE_WEB_VITE_CACHE_DIR'];
	const previousUrl = process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];
	try {
		process.env['BRIDGE_WEB_VITE_CACHE_DIR'] = launch.dataRootPath;
		const loader = await createBridgeWebVerifierModuleLoader(launch);
		const module = await loader.loadModule('/scripts/dev-server/handled-launch-promise.ts');
		expect(module).toHaveProperty('handleLaunchPromise');
		process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] = 'http://127.0.0.1:10001/?viewer=file';
		const firstConfig = await loader.loadModule(
			'/scripts/verify-bridge-viewer-worktree-dev-server/config.ts',
		);
		process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] = 'http://127.0.0.1:10002/?viewer=file';
		const nextLoader = await createBridgeWebVerifierModuleLoader(launch);
		const nextConfig = await nextLoader.loadModule(
			'/scripts/verify-bridge-viewer-worktree-dev-server/config.ts',
		);
		expect(firstConfig).toHaveProperty('worktreeDevServerOrigin', 'http://127.0.0.1:10001');
		expect(nextConfig).toHaveProperty('worktreeDevServerOrigin', 'http://127.0.0.1:10002');
		expect(await readdir(launch.dataRootPath)).toEqual([]);
		await launch.dispose();
		await expect(access(launch.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
	} finally {
		if (previousUrl === undefined) delete process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'];
		else process.env['BRIDGE_VIEWER_WORKTREE_DEV_SERVER_URL'] = previousUrl;
		if (previousCache === undefined) delete process.env['BRIDGE_WEB_VITE_CACHE_DIR'];
		else process.env['BRIDGE_WEB_VITE_CACHE_DIR'] = previousCache;
		await launch.dispose();
	}
});

test('a surviving Vite child fails checked teardown without removing its root', async () => {
	const launch = await BridgeWebTestLaunch.start(
		{},
		{
			startBackend: async () => {
				throw new Error('No backend needed');
			},
			startViteChild: async (props) =>
				await BridgeViewerOwnedViteServer.start(props, {
					spawnChild: (processProps): ChildProcessWithoutNullStreams =>
						spawn(
							process.execPath,
							[
								'--eval',
								`process.stdin.resume(); process.stdout.write('http://127.0.0.1:${processProps.port}/\\n');`,
							],
							{ env: processProps.environment, stdio: ['pipe', 'pipe', 'pipe'] },
						),
				}),
		},
	);
	const vite = await launch.startViteChild({
		bridgeWebRootPath,
		bridgeDevelopmentServerOrigin: 'http://127.0.0.1:1',
	});
	const nativeStop = vite.stop.bind(vite);
	// The real child is still alive: inject the adapter's explicitly failed stop
	// receipt, then restore its owner to perform physical rescue after assertions.
	const stop = vi.spyOn(vite, 'stop').mockResolvedValue({
		exitCode: null,
		exitSignal: null,
		exitedWithinTimeout: false,
		forcedTerminationRequired: true,
		ownedProcessAliveAfterStop: true,
		pid: vite.startProof.pid,
	});
	try {
		await expect(launch.dispose()).rejects.toThrow('owned stack teardown');
		expect(launch.cleanup.failures).toContain('Vite child');
		expect(launch.cleanup.failures).toContain('data root');
		expect(launch.cleanup.dataRootRemoved).toBe(false);
		await expect(access(launch.dataRootPath)).resolves.toBeUndefined();
	} finally {
		stop.mockRestore();
		await nativeStop();
		await rm(launch.dataRootPath, { recursive: true, force: true });
	}
});
