import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import type { ViteDevServer } from 'vite';
import { expect, test, vi, type MockInstance } from 'vitest';

import {
	BridgeProductMetadataFrameDecoder,
	encodeBridgeProductMetadataFrame,
} from '../../src/core/comm-worker/bridge-product-metadata-frame-codec.ts';
import {
	createBridgeViewerViteProductFixture,
	startBridgeViewerOwnedViteProductServer,
} from '../../tests/e2e/bridge-viewer-vite-product-fixture.ts';
import BridgeWebE2ERunner from '../../tests/e2e/bridge-web-e2e-runner.ts';
import { runBridgeWebE2ETestBody } from '../../tests/e2e/bridge-web-e2e-test-retirement.ts';
import { endToEndTestTimeoutMilliseconds } from '../../tests/vitest-hang-bounds.ts';
import { BridgeVerifierProductFileSession } from '../verify-bridge-viewer-worktree-dev-server/product-file-session.ts';
import { BridgeViewerOwnedViteServer } from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-regression.ts';
import { makeDeferred } from '../verify-bridge-viewer-worktree-dev-server/utils.ts';
import { createOwnedVerifierJourneyDeadline } from '../verify-bridge-viewer-worktree-dev-server/verifier-journey-deadline.ts';
import { BridgeWebTestLaunch } from './bridge-web-test-launch.ts';
import { handleLaunchPromise } from './handled-launch-promise.ts';

test.each(['configureServer', 'listener initialization'] as const)(
	'expiry closes Vite held in %s before joining acquisition and removing its root',
	async (phase) => {
		vi.useFakeTimers();
		const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
		const launch = await BridgeWebTestLaunch.start();
		const configuring = makeDeferred<ViteDevServer>();
		const configurationClosed = makeDeferred<void>();
		let closeServer: MockInstance<ViteDevServer['close']> | undefined;
		let capturedServer: ViteDevServer | undefined;
		const starting = handleLaunchPromise(
			launch.startVite({
				configFile: false,
				logLevel: 'silent',
				server: { watch: null, hmr: false },
				plugins: [
					{
						name: 'held-configuration-until-owner-close',
						enforce: 'pre',
						configureServer: {
							order: 'pre',
							handler: async (server): Promise<void> => {
								capturedServer = server;
								const nativeClose = server.close.bind(server);
								closeServer = vi
									.spyOn(server, 'close')
									.mockImplementation(async (): Promise<void> => {
										configurationClosed.resolve();
										await nativeClose();
									});
								if (phase === 'configureServer') {
									configuring.resolve(server);
									await configurationClosed.promise;
								}
							},
						},
						buildStart: async (): Promise<void> => {
							if (phase !== 'listener initialization') return;
							if (capturedServer === undefined)
								throw new Error('Vite owner was not captured before buildStart');
							configuring.resolve(capturedServer);
							await configurationClosed.promise;
						},
					},
				],
			}),
			'held Vite configuration',
		);
		const server = await configuring.promise;
		try {
			const pendingStep =
				phase === 'configureServer' ? 'Vite acquisition' : 'Vite listener readiness';
			expect(launch.pendingSteps).toContain(pendingStep);
			await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds);
			expect(closeServer).toHaveBeenCalled();
			expect(String(launch.signal.reason)).toContain(`waiting=${pendingStep}`);
			await expect(starting.value()).rejects.toThrow('held Vite configuration');
			expect(launch.cleanup.viteClosed).toBe(true);
			expect(server.httpServer?.listening).toBe(false);
			expect(launch.cleanup.lateViteListenerRetirement).toEqual(
				phase === 'listener initialization'
					? { kind: 'closed', closeEventObserved: true }
					: { kind: 'not-required' },
			);
			expect(launch.cleanup.dataRootRemoved).toBe(true);
			await expect(access(launch.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
		} finally {
			// Rescue only on a red implementation; the green assertions precede this.
			try {
				server.httpServer?.close();
				await server.close();
				await starting.settled;
				await handleLaunchPromise(launch.dispose(), 'Vite proof cleanup').settled;
			} finally {
				stderr.mockRestore();
				vi.useRealTimers();
			}
		}
	},
);

test('held Vite readiness outlives 30 seconds and only the launch bound retires it', async () => {
	vi.useFakeTimers();
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const spawned = makeDeferred<ChildProcessWithoutNullStreams>();
	const launch = await BridgeWebTestLaunch.start(
		{
			backend: {
				initialTarget: 'HEAD',
				paneId: 'held-backend',
				repoRootPath: '/fixture',
				worktreeRoot: '/fixture',
			},
		},
		{
			startBackend: async (props) => {
				const backend = {
					origin: 'http://127.0.0.1:1',
					pid: 0,
					stdoutTail: (): string => '',
					stderrTail: (): string => '',
					whenExited: Promise.resolve(),
					stop: async () => ({
						exitCode: 0,
						exitSignal: null,
						forcedTerminationRequired: false,
						ownedProcessAliveAfterStop: false,
					}),
				};
				props.onSpawn?.(backend);
				return backend;
			},
			startViteChild: async (props) =>
				await BridgeViewerOwnedViteServer.start(props, {
					spawnChild: (): ChildProcessWithoutNullStreams => {
						// Real process/exit events; the readiness producer is deliberately held.
						const child = spawn(process.execPath, ['--eval', 'process.stdin.resume()'], {
							stdio: ['pipe', 'pipe', 'pipe'],
						});
						spawned.resolve(child);
						return child;
					},
				}),
		},
	);
	const starting = handleLaunchPromise(
		launch.startViteChild({ bridgeWebRootPath: fileURLToPath(new URL('../../', import.meta.url)) }),
		'held Vite startup',
	);
	const child = await spawned.promise;
	const kill = vi.spyOn(child, 'kill');
	try {
		await vi.advanceTimersByTimeAsync(30_001);
		expect(kill).not.toHaveBeenCalled();
		expect(launch.pendingSteps).toContain('Vite readiness');
		expect(vi.getTimerCount()).toBe(1);
		await vi.advanceTimersByTimeAsync(endToEndTestTimeoutMilliseconds - 30_001);
		const outcome = await starting.settled;
		expect(outcome.kind).toBe('failed');
		expect(String(launch.signal.reason)).toContain('waiting=Vite readiness');
		expect(launch.cleanup.viteProcess?.ownedProcessAliveAfterStop).toBe(false);
		expect(launch.cleanup.dataRootRemoved).toBe(true);
		await expect(access(launch.dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
	} finally {
		await launch.dispose();
		await starting.settled;
		stderr.mockRestore();
		vi.useRealTimers();
	}
});

test('runner-boundary abort joins the real opening client, backend and fixture retirement', async (context) => {
	const stderr = vi.spyOn(process.stderr, 'write').mockReturnValue(true);
	const heldSnapshot = makeDeferred<void>();
	const nativeFetch = globalThis.fetch;
	const fetchSpy = vi
		.spyOn(globalThis, 'fetch')
		.mockImplementation(async (input, init): Promise<Response> => {
			const response = await nativeFetch(input, init);
			const endpoint =
				typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
			if (!endpoint.includes('/__bridge-product/stream') || response.body === null) return response;
			const decoder = new BridgeProductMetadataFrameDecoder();
			const body = response.body.pipeThrough(
				new TransformStream<Uint8Array, Uint8Array>({
					transform(chunk, controller): void {
						for (const frame of decoder.push(chunk)) {
							if (frame.kind === 'subscription.batchComplete') {
								heldSnapshot.resolve();
								continue;
							}
							controller.enqueue(encodeBridgeProductMetadataFrame(frame));
						}
					},
				}),
			);
			return new Response(body, { status: response.status, headers: response.headers });
		});
	let launch: BridgeWebTestLaunch | undefined;
	let dataRootPath = '';
	let worktreeRoot = '';
	let bodyRetired = false;
	let expire: () => void = (): void => {
		throw new Error('bound was not scheduled');
	};
	const deadline = createOwnedVerifierJourneyDeadline(
		{
			pendingSteps: (): readonly string[] => launch?.pendingSteps ?? ['real fixture startup'],
			closePages: async (): Promise<void> => {},
		},
		{
			schedule: (onExpiry, durationMilliseconds): (() => void) => {
				expect(durationMilliseconds).toBe(endToEndTestTimeoutMilliseconds);
				expire = onExpiry;
				return (): void => {};
			},
		},
	);
	const rawBody = handleLaunchPromise(
		runBridgeWebE2ETestBody(
			{ signal: deadline.signal, task: context.task },
			async (): Promise<void> => {
				const fixture = await createBridgeViewerViteProductFixture();
				worktreeRoot = fixture.oracle.worktreeRoot;
				try {
					const server = await startBridgeViewerOwnedViteProductServer(fixture.oracle);
					launch = server.testLaunch;
					dataRootPath = launch.dataRootPath;
					const client = new BridgeVerifierProductFileSession({
						baseUrl: server.origin,
						scenarioName: 'current-worktree',
					});
					try {
						await launch.readProductData(
							() => client,
							async (client) => {
								return await client.open();
							},
						);
					} finally {
						await server.stop();
					}
				} finally {
					await fixture.dispose();
					bodyRetired = true;
				}
			},
		),
		'real aborted E2E body',
	);
	try {
		await heldSnapshot.promise;
		expire();
		await expect(
			BridgeWebE2ERunner.prototype.onTaskFinished({
				id: context.task.id,
				result: { state: 'fail' },
			}),
		).rejects.toThrow('pre-navigation product data read');
		expect(bodyRetired).toBe(true);
		expect(launch?.cleanup.backend?.ownedProcessAliveAfterStop).toBe(false);
		expect(launch?.cleanup.viteProcess?.ownedProcessAliveAfterStop).toBe(false);
		expect(launch?.cleanup.dataRootRemoved).toBe(true);
		await expect(access(dataRootPath)).rejects.toMatchObject({ code: 'ENOENT' });
		await expect(access(worktreeRoot)).rejects.toMatchObject({ code: 'ENOENT' });
	} finally {
		await deadline.dispose();
		await launch?.dispose();
		await rawBody.settled;
		fetchSpy.mockRestore();
		stderr.mockRestore();
	}
});
