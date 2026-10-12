import { createServer } from 'node:http';

import { describe, expect, expectTypeOf, test } from 'vitest';

import {
	type BridgeDevelopmentServerLifecycleOutcome,
	BridgeDevelopmentServerReadinessLineReader,
	bridgeDevelopmentServerArguments,
	bridgeDevelopmentServerExecutablePath,
	bridgeDevelopmentServerProcessOwnsListeningPort,
	parseBridgeDevelopmentServerReadinessLine,
	resolveBridgeDevelopmentServerPort,
	runAllOwnedCleanupOperations,
	startOwnedBridgeDevelopmentServer,
	stopOwnedBridgeDevelopmentServerProcess,
	waitForBridgeDevelopmentServerReadiness,
} from './bridge-development-server-process.ts';

describe('owned Bridge development server executable', () => {
	test('start contract requires persisted identity inputs', () => {
		expectTypeOf(startOwnedBridgeDevelopmentServer).parameter(0).toEqualTypeOf<{
			readonly dataRootPath: string;
			readonly initialTarget: string;
			readonly onSpawn?: (
				server: import('./bridge-development-server-process.ts').OwnedBridgeDevelopmentServer,
			) => void;
			readonly paneId: string;
			readonly port?: number;
			readonly repoRootPath: string;
			readonly worktreeRoot: string;
		}>();
	});

	test('uses the configured Vite proxy port without reserving another port', async () => {
		// Arrange: ignoring this value would launch a backend the fixed Vite proxy cannot reach.
		let reservePortCallCount = 0;

		// Act
		const port = await resolveBridgeDevelopmentServerPort({
			configuredPort: 43_871,
			reservePort: async (): Promise<number> => {
				reservePortCallCount += 1;
				return 43_872;
			},
		});

		// Assert
		expect(port).toBe(43_871);
		expect(reservePortCallCount).toBe(0);
	});

	test('reserves an isolated port when the caller does not configure one', async () => {
		// Arrange: the existing test fixtures require independent concurrent backend ports.
		let reservePortCallCount = 0;

		// Act
		const port = await resolveBridgeDevelopmentServerPort({
			reservePort: async (): Promise<number> => {
				reservePortCallCount += 1;
				return 43_872;
			},
		});

		// Assert
		expect(port).toBe(43_872);
		expect(reservePortCallCount).toBe(1);
	});

	test('launch arguments carry one isolated root and exact pane identity without base authority', () => {
		// Arrange
		const paneId = '019fe721-7d8b-7ca0-b5c7-89e5fd7463f3';

		// Act
		const developmentServerArguments = bridgeDevelopmentServerArguments({
			dataRootPath: '/tmp/bridge-development-data',
			initialTarget: 'refs/heads/review-base',
			paneId,
			port: 43_871,
			worktreeRoot: '/tmp/repository',
		});

		// Assert
		expect(developmentServerArguments).toEqual([
			'--data-root',
			'/tmp/bridge-development-data',
			'--pane-id',
			paneId,
			'--seed-worktree',
			'/tmp/repository',
			'--seed-target',
			'refs/heads/review-base',
			'--port',
			'43871',
		]);
		expect(developmentServerArguments).not.toContain('--base');
	});

	test('resolves the prebuilt stable artifact path', () => {
		// Arrange
		const repoRootPath = '/tmp/agent-studio';

		// Act
		const executablePath = bridgeDevelopmentServerExecutablePath(repoRootPath);

		// Assert
		expect(executablePath).toBe(
			'/tmp/agent-studio/.build-bridge-development-server/agentstudio-bridge-dev-server',
		);
	});
});

describe('owned Bridge development server lifecycle', () => {
	test('resolves when the owned child announces its listener and owns the port', async () => {
		// Arrange
		const readinessLineReader = new BridgeDevelopmentServerReadinessLineReader();
		const ownershipProbes: string[] = [];

		// Act
		const readiness = waitForBridgeDevelopmentServerReadiness({
			expectedProcess: { pid: 4242, port: 43871 },
			lifecycleOutcome: new Promise((): void => {}),
			readinessAnnouncement: readinessLineReader.announcement,
			readinessOwnershipProbe: async (): Promise<boolean> => {
				ownershipProbes.push('probe');
				return true;
			},
			stderrTail: (): string => '',
			stdoutTail: (): string => '',
		});
		readinessLineReader.observeStdoutChunk(
			'starting\nbridge-development-server ready port=43871 pid=4242\n',
		);

		// Assert
		await expect(readiness).resolves.toBeUndefined();
		expect(ownershipProbes).toEqual(['probe']);
	});

	test('fails with the child log tails when the child exits before announcing readiness', async () => {
		// Arrange
		const readinessLineReader = new BridgeDevelopmentServerReadinessLineReader();
		const lifecycleOutcome = makeDeferred<BridgeDevelopmentServerLifecycleOutcome>();
		const readiness = waitForBridgeDevelopmentServerReadiness({
			expectedProcess: { pid: 4242, port: 43871 },
			lifecycleOutcome: lifecycleOutcome.promise,
			readinessAnnouncement: readinessLineReader.announcement,
			readinessOwnershipProbe: async (): Promise<boolean> => true,
			stderrTail: (): string => 'fatal: seed worktree missing',
			stdoutTail: (): string => 'starting',
		});

		// Act
		lifecycleOutcome.resolve({ code: 1, kind: 'exit', signal: null });

		// Assert
		await expect(readiness).rejects.toThrow(
			/exited before readiness.*"code":1.*fatal: seed worktree missing.*starting/u,
		);
	});

	test('recognizes a readiness line split across two stdout chunks', async () => {
		// Arrange
		const readinessLineReader = new BridgeDevelopmentServerReadinessLineReader();

		// Act
		readinessLineReader.observeStdoutChunk('bridge-development-server rea');
		readinessLineReader.observeStdoutChunk('dy port=43871 pid=4242\n');

		// Assert
		await expect(readinessLineReader.announcement).resolves.toEqual({ pid: 4242, port: 43871 });
	});

	test('ignores lines that only resemble the readiness announcement', () => {
		// Arrange / Act / Assert
		expect(
			parseBridgeDevelopmentServerReadinessLine('bridge-development-server ready port=1'),
		).toBeNull();
		expect(
			parseBridgeDevelopmentServerReadinessLine(
				'note: bridge-development-server ready port=1 pid=2',
			),
		).toBeNull();
		expect(
			parseBridgeDevelopmentServerReadinessLine('bridge-development-server ready port=1 pid=2\r'),
		).toEqual({ pid: 2, port: 1 });
	});

	test('rejects a readiness announcement whose listener the owned child does not own', async () => {
		// A process already listening on the selected port must not satisfy owned-child readiness.
		const collider = createServer((_request, response): void => {
			response.writeHead(204).end();
		});
		await new Promise<void>((resolve, reject): void => {
			collider.once('error', reject);
			collider.listen(0, '127.0.0.1', (): void => resolve());
		});
		const address = collider.address();
		if (address === null || typeof address === 'string') {
			throw new Error('Collider did not bind a loopback TCP port.');
		}
		const ownedChildPid = process.pid + 1_000_000;

		try {
			expect(
				await bridgeDevelopmentServerProcessOwnsListeningPort({
					pid: process.pid,
					port: address.port,
				}),
			).toBe(true);

			// Act
			const readiness = waitForBridgeDevelopmentServerReadiness({
				expectedProcess: { pid: ownedChildPid, port: address.port },
				lifecycleOutcome: new Promise((): void => {}),
				readinessAnnouncement: Promise.resolve({ pid: ownedChildPid, port: address.port }),
				readinessOwnershipProbe: async (): Promise<boolean> =>
					await bridgeDevelopmentServerProcessOwnsListeningPort({
						pid: ownedChildPid,
						port: address.port,
					}),
				stderrTail: (): string => '',
				stdoutTail: (): string => '',
			});

			// Assert
			await expect(readiness).rejects.toThrow(/does not own its listening port/u);
		} finally {
			await new Promise<void>((resolve, reject): void => {
				collider.close((error): void => (error === undefined ? resolve() : reject(error)));
			});
		}
	});

	test('treats a child spawn error as a terminal readiness outcome', async () => {
		// Arrange
		const readinessLineReader = new BridgeDevelopmentServerReadinessLineReader();
		const readiness = waitForBridgeDevelopmentServerReadiness({
			expectedProcess: { pid: 0, port: 1 },
			lifecycleOutcome: Promise.resolve({ error: new Error('spawn ENOENT'), kind: 'spawn-error' }),
			readinessAnnouncement: readinessLineReader.announcement,
			readinessOwnershipProbe: async (): Promise<boolean> => true,
			stderrTail: (): string => '',
			stdoutTail: (): string => '',
		});

		// Act / Assert
		await expect(readiness).rejects.toThrow(/failed to spawn before readiness.*spawn ENOENT/u);
	});

	test('does not signal or wait for exit after a child spawn error', async () => {
		// Arrange
		const observedSignals: NodeJS.Signals[] = [];

		// Act
		const cleanup = await stopOwnedBridgeDevelopmentServerProcess(
			{
				kill: (signal): boolean => {
					observedSignals.push(signal);
					return true;
				},
			},
			Promise.resolve({ error: new Error('spawn ENOENT'), kind: 'spawn-error' }),
		);

		// Assert
		expect(cleanup).toEqual({
			exitCode: null,
			exitSignal: null,
			forcedTerminationRequired: false,
			ownedProcessAliveAfterStop: false,
		});
		expect(observedSignals).toEqual([]);
	});
});

function makeDeferred<TValue>(): {
	readonly promise: Promise<TValue>;
	readonly resolve: (value: TValue) => void;
} {
	let resolvePromise: ((value: TValue) => void) | null = null;
	const promise = new Promise<TValue>((resolve): void => {
		resolvePromise = resolve;
	});
	return {
		promise,
		resolve: (value): void => {
			if (resolvePromise === null) throw new Error('Deferred promise resolver is unavailable.');
			resolvePromise(value);
		},
	};
}

describe('owned Bridge development cleanup', () => {
	test('runs every cleanup and preserves the primary failure with cleanup failures', async () => {
		// Arrange
		const primaryError = new Error('journey failed');
		const firstCleanupError = new Error('Vite cleanup failed');
		const secondCleanupError = new Error('backend cleanup failed');
		const observedCleanupNames: string[] = [];

		// Act
		const cleanup = runAllOwnedCleanupOperations({
			operations: [
				{
					name: 'Vite',
					run: async (): Promise<void> => {
						observedCleanupNames.push('Vite');
						throw firstCleanupError;
					},
				},
				{
					name: 'backend',
					run: async (): Promise<void> => {
						observedCleanupNames.push('backend');
						throw secondCleanupError;
					},
				},
				{
					name: 'telemetry',
					run: async (): Promise<void> => {
						observedCleanupNames.push('telemetry');
					},
				},
			],
			primaryError,
		});

		// Assert
		await expect(cleanup).rejects.toEqual(
			expect.objectContaining({
				errors: [primaryError, firstCleanupError, secondCleanupError],
			}),
		);
		expect(observedCleanupNames).toEqual(['Vite', 'backend', 'telemetry']);
	});
});
