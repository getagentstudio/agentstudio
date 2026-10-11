import { access } from 'node:fs/promises';

import { expect, test, vi } from 'vitest';

import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';
import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import type { OwnedBridgeDevelopmentServerCleanup } from './bridge-development-server-process.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';

const backendSpec = {
	initialTarget: 'HEAD',
	paneId: '00000000-0000-7000-8000-000000000002',
	repoRootPath: '/fixture',
	worktreeRoot: '/fixture',
};
const stoppedBackend: OwnedBridgeDevelopmentServerCleanup = {
	exitCode: 0,
	exitSignal: null,
	forcedTerminationRequired: false,
	ownedProcessAliveAfterStop: false,
};

test('a rejected startup step stops the registered child and removes its data root', async () => {
	let dataRootPath = '';
	let stopCount = 0;
	const startupFailure = new Error('File metadata startup step stuck');
	await expect(
		BridgeWebTestLaunch.start(
			{ backend: backendSpec },
			{
				startBackend: async (props) => {
					dataRootPath = props.dataRootPath;
					props.onSpawn?.({
						origin: 'http://127.0.0.1:1',
						pid: 123,
						stderrTail: (): string => '',
						stdoutTail: (): string => '',
						whenExited: Promise.resolve(),
						stop: async (): Promise<OwnedBridgeDevelopmentServerCleanup> => {
							stopCount += 1;
							return stoppedBackend;
						},
					});
					throw startupFailure;
				},
			},
		),
	).rejects.toMatchObject({ cause: startupFailure });
	expect(stopCount).toBe(1);
	await expect(access(dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
});

test('a surviving child fails teardown and cleanup still removes the root', async () => {
	const launch = await BridgeWebTestLaunch.start(
		{ backend: backendSpec },
		{
			startBackend: async (props) => {
				const backend = {
					origin: 'http://127.0.0.1:1',
					pid: 123,
					stderrTail: (): string => '',
					stdoutTail: (): string => '',
					whenExited: Promise.resolve(),
					stop: async (): Promise<OwnedBridgeDevelopmentServerCleanup> => ({
						...stoppedBackend,
						ownedProcessAliveAfterStop: true,
					}),
				};
				props.onSpawn?.(backend);
				return backend;
			},
		},
	);
	await expect(launch.dispose()).rejects.toThrow('owned stack teardown');
	expect(launch.cleanup.backend?.ownedProcessAliveAfterStop).toBe(true);
	expect(launch.cleanup.failures).toContain('Swift backend');
	expect(launch.cleanup.dataRootRemoved).toBe(true);
});

test('dispose is idempotent and every fixture cleanup runs after a predecessor failure', async () => {
	const launch = await BridgeWebTestLaunch.start();
	const disposedFixtures: string[] = [];
	launch.ownFixture('broken fixture', async (): Promise<void> => {
		disposedFixtures.push('broken');
		throw new Error('cleanup failed');
	});
	launch.ownFixture('healthy fixture', async (): Promise<void> => {
		disposedFixtures.push('healthy');
	});
	await expect(launch.dispose()).rejects.toThrow('owned stack teardown');
	await expect(launch.dispose()).rejects.toThrow('owned stack teardown');
	expect(disposedFixtures).toEqual(['broken', 'healthy']);
	expect(launch.cleanup.dataRootRemoved).toBe(true);
});

test.each(['closed', 'failed'] as const)(
	'product data is gated by client release: %s',
	async (disposition) => {
		const launch = await BridgeWebTestLaunch.start();
		const arrival = makeDeferred<void>();
		const released = makeDeferred<void>();
		const data = { pathCount: 4 };
		const result = launch.readProductData(
			async () => data,
			async (): Promise<void> => {
				arrival.resolve();
				await released.promise;
				if (disposition === 'failed') throw new Error('release refused');
			},
		);
		await arrival.promise;
		released.resolve();
		if (disposition === 'failed') {
			await expect(result).rejects.toThrow('client release failed');
			await expect(launch.dispose()).rejects.toThrow('owned stack teardown');
		} else {
			expect(await result).toBe(data);
			await launch.dispose();
		}
	},
);

test('one journey hang bound names pending owner facts and clears on disposal', async () => {
	const launch = await BridgeWebTestLaunch.start();
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const metadata = makeDeferred<void>();
	try {
		const observation = launch.observeStep('startup file.metadata', metadata.promise);
		const signal = launch.startJourneyHangBound();
		expect(launch.startJourneyHangBound()).toBe(signal);
		expect(vi.getTimerCount()).toBe(1);
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		expect(signal.aborted).toBe(true);
		expect(String(signal.reason)).toContain('waiting=startup file.metadata');
		metadata.resolve();
		await observation.value();
		await launch.dispose();
		expect(vi.getTimerCount()).toBe(0);
	} finally {
		metadata.resolve();
		vi.useRealTimers();
		stderr.mockRestore();
		await launch.dispose();
	}
});
