import { access } from 'node:fs/promises';

import { expect, test, vi } from 'vitest';

import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';
import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import type { OwnedBridgeDevelopmentServerCleanup } from './bridge-development-server-process.ts';
import type { BridgeWebTestLaunchDependencies } from './bridge-web-test-launch-contracts.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

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

function fakeBackendDependencies(): BridgeWebTestLaunchDependencies {
	return {
		startBackend: async (props: Parameters<BridgeWebTestLaunchDependencies['startBackend']>[0]) => {
			const backend = {
				origin: 'http://127.0.0.1:1',
				pid: 123,
				stderrTail: (): string => '',
				stdoutTail: (): string => '',
				whenExited: Promise.resolve(),
				stop: async (): Promise<OwnedBridgeDevelopmentServerCleanup> => stoppedBackend,
			};
			props.onSpawn?.(backend);
			return backend;
		},
	};
}

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
		const result = handleLaunchPromise(
			launch.readProductData(
				() => ({
					abort: async (): Promise<void> => {},
					close: async (): Promise<void> => {
						arrival.resolve();
						await released.promise;
						if (disposition === 'failed') throw new Error('release refused');
					},
				}),
				async () => {
					return data;
				},
			),
			'product data release',
		);
		await arrival.promise;
		released.resolve();
		if (disposition === 'failed') {
			await expect(result.value()).rejects.toThrow('release refused');
			expect(launch.cleanup.dataRootRemoved).toBe(true);
		} else {
			expect(await result.value()).toBe(data);
			await launch.dispose();
		}
	},
);

test('one journey hang bound names pending owner facts and clears on disposal', async () => {
	vi.useFakeTimers();
	const launch = await BridgeWebTestLaunch.start();
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

test('renewing the journey hang bound starts a fresh unit without raising its duration', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const launch = await BridgeWebTestLaunch.start();
	try {
		const signal = launch.startJourneyHangBound();
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds - 1);
		launch.renewJourneyHangBound();
		await vi.advanceTimersByTimeAsync(1);
		expect(signal.aborted).toBe(false);
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		expect(signal.aborted).toBe(true);
	} finally {
		await launch.dispose();
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('renewing a child journey renews its parent bound without raising the duration', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const parent = await BridgeWebTestLaunch.start({}, fakeBackendDependencies());
	const child = await parent.startChild(backendSpec);
	try {
		const signal = parent.startJourneyHangBound();
		expect(vi.getTimerCount()).toBe(1);
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds - 1);
		child.renewJourneyHangBound();
		expect(vi.getTimerCount()).toBe(1);
		await vi.advanceTimersByTimeAsync(1);
		expect(signal.aborted).toBe(false);
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds - 2);
		expect(signal.aborted).toBe(false);
	} finally {
		await parent.dispose();
		await child.dispose();
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('a stalled child expires through the parent and names the child pending step', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const parent = await BridgeWebTestLaunch.start({}, fakeBackendDependencies());
	const child = await parent.startChild(backendSpec);
	const pending = makeDeferred<void>();
	const observation = child.observeStep('child pending step', pending.promise);
	try {
		const signal = parent.startJourneyHangBound();
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		expect(signal.aborted).toBe(true);
		expect(String(signal.reason)).toContain('waiting=child pending step');
	} finally {
		pending.resolve();
		await observation.value();
		await parent.dispose();
		await child.dispose();
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('without child activity the parent still expires on its own pending step', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const parent = await BridgeWebTestLaunch.start({}, fakeBackendDependencies());
	const child = await parent.startChild(backendSpec);
	const pending = makeDeferred<void>();
	const observation = parent.observeStep('parent pending step', pending.promise);
	try {
		const signal = parent.startJourneyHangBound();
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		expect(signal.aborted).toBe(true);
		expect(String(signal.reason)).toContain('waiting=parent pending step');
	} finally {
		pending.resolve();
		await observation.value();
		await parent.dispose();
		await child.dispose();
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('expiry itself retires a held pre-navigation read and its root', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const launch = await BridgeWebTestLaunch.start();
	let rejectRead: (reason: unknown) => void = (): void => {};
	const stuckRead = new Promise<void>((_resolve, reject): void => {
		rejectRead = reject;
	});
	const reading = handleLaunchPromise(
		launch.readProductData(
			() => ({
				close: async (): Promise<void> => {
					throw new Error('must not release a still-opening client');
				},
				abort: async (reason: unknown): Promise<void> => {
					rejectRead(reason);
				},
			}),
			async () => {
				await stuckRead;
			},
		),
		'held data read',
	);
	launch.startJourneyHangBound();
	try {
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		expect((await reading.settled).kind).toBe('failed');
		expect(launch.cleanup.dataRootRemoved).toBe(true);
		expect(String(launch.signal.reason)).toContain('pre-navigation product data read');
	} finally {
		await launch.dispose();
		await reading.settled;
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('the bound covers Swift acquisition before a browser or launch handle is available', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const spawned = makeDeferred<void>();
	let dataRootPath = '';
	let rejectReadiness: (reason: unknown) => void = (): void => {};
	const readiness = new Promise<never>((_resolve, reject): void => {
		rejectReadiness = reject;
	});
	const starting = handleLaunchPromise(
		BridgeWebTestLaunch.start(
			{ backend: backendSpec },
			{
				startBackend: async (props) => {
					dataRootPath = props.dataRootPath;
					props.onSpawn?.({
						origin: 'http://127.0.0.1:1',
						pid: 0,
						stderrTail: (): string => '',
						stdoutTail: (): string => '',
						whenExited: Promise.resolve(),
						stop: async () => {
							rejectReadiness(new Error('owned child exited'));
							return stoppedBackend;
						},
					});
					spawned.resolve();
					return await readiness;
				},
			},
		),
		'held Swift startup',
	);
	try {
		await spawned.promise;
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		await expect(starting.value()).rejects.toThrow('waiting=Swift readiness');
		await expect(access(dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
	} finally {
		await starting.settled;
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('expiry aborts a held installation release and completes checked teardown', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const launch = await BridgeWebTestLaunch.start();
	const releasing = makeDeferred<void>();
	let rejectRelease: (reason: unknown) => void = (): void => {};
	const release = new Promise<never>((_resolve, reject): void => {
		rejectRelease = reject;
	});
	const reading = handleLaunchPromise(
		launch.readProductData(
			() => ({
				close: async (): Promise<void> => {
					releasing.resolve();
					await release;
				},
				abort: async (reason: unknown): Promise<void> => {
					rejectRelease(reason);
				},
			}),
			async () => {},
		),
		'held release',
	);
	try {
		await releasing.promise;
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
		await expect(reading.value()).rejects.toThrow('acknowledged product installation release');
		expect(launch.cleanup.dataRootRemoved).toBe(true);
	} finally {
		await launch.dispose();
		await reading.settled;
		stderr.mockRestore();
		vi.useRealTimers();
	}
});
