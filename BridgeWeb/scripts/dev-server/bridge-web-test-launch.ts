import { access, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { chromium, type Browser, type LaunchOptions } from 'playwright';
import { createServer, type InlineConfig, type ViteDevServer } from 'vite';

import {
	BridgeViewerOwnedViteServer,
	type BridgeViewerViteServerCleanupProof,
} from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-regression.ts';
import {
	startOwnedBridgeDevelopmentServer,
	type OwnedBridgeDevelopmentServer,
	type OwnedBridgeDevelopmentServerCleanup,
} from './bridge-development-server-process.ts';
import {
	handleLaunchPromise,
	type HandledLaunchPromise,
	type LaunchPromiseOutcome,
} from './handled-launch-promise.ts';
import { reserveLoopbackPort } from './reserve-loopback-port.ts';

interface LaunchCleanupOperation {
	readonly name: string;
	readonly run: () => Promise<void>;
}

export interface BridgeWebTestLaunchCleanup {
	readonly backend: OwnedBridgeDevelopmentServerCleanup | null;
	readonly browserDisconnected: boolean;
	readonly dataRootRemoved: boolean;
	readonly failures: readonly string[];
	readonly viteClosed: boolean;
	readonly viteProcess: BridgeViewerViteServerCleanupProof | null;
}

export interface BridgeWebTestLaunchSpec {
	readonly backend?: Omit<
		Parameters<typeof startOwnedBridgeDevelopmentServer>[0],
		'dataRootPath' | 'onSpawn'
	>;
	readonly dataRootPrefix?: string;
}

export interface BridgeWebTestLaunchDependencies {
	readonly startBackend: typeof startOwnedBridgeDevelopmentServer;
}

// A process has one exit backstop, shared by every launch in it. Normal callers
// still await dispose(); a fatal process event reports its error and exits only
// after every registered owner has attempted cleanup.
const registryKey = Symbol.for('agentstudio.bridge-web-test-launch.registry');
interface LaunchRegistry {
	readonly launches: Set<BridgeWebTestLaunch>;
	removeExitHooks: (() => void) | null;
	fatalCleanup: Promise<void> | null;
}
const registryGlobal = globalThis as typeof globalThis & { [registryKey]?: LaunchRegistry };
const registry = (registryGlobal[registryKey] ??= {
	launches: new Set(),
	removeExitHooks: null,
	fatalCleanup: null,
});
const activeLaunches = registry.launches;

function installExitHooks(): void {
	if (registry.removeExitHooks !== null) return;
	const terminate = (error: unknown, exitCode: number): void => {
		registry.fatalCleanup ??= (async (): Promise<void> => {
			process.stderr.write(`BridgeWeb test launch terminated: ${String(error)}\n`);
			const results = await Promise.allSettled(
				[...activeLaunches].map((launch) => launch.dispose()),
			);
			for (const result of results) {
				if (result.status === 'rejected')
					process.stderr.write(`BridgeWeb teardown failed: ${String(result.reason)}\n`);
			}
			process.exit(exitCode);
		})();
		// The backstop itself cannot create an unhandled rejection.
		void registry.fatalCleanup.catch((failure: unknown): void => {
			process.stderr.write(`BridgeWeb fatal teardown failed: ${String(failure)}\n`);
			process.exit(exitCode);
		});
	};
	const unhandled = (error: unknown): void => terminate(error, 1);
	const interrupt = (): void => terminate('SIGINT', 130);
	const terminated = (): void => terminate('SIGTERM', 143);
	process.on('unhandledRejection', unhandled);
	process.on('SIGINT', interrupt);
	process.on('SIGTERM', terminated);
	registry.removeExitHooks = (): void => {
		process.off('unhandledRejection', unhandled);
		process.off('SIGINT', interrupt);
		process.off('SIGTERM', terminated);
		registry.removeExitHooks = null;
	};
}

export class BridgeWebTestLaunch {
	#dataRootPath: string | null = null;
	readonly #root: HandledLaunchPromise<string>;
	readonly #acquisitions = new Set<Promise<LaunchPromiseOutcome<unknown>>>();
	#backend: OwnedBridgeDevelopmentServer | null = null;
	#browser: Browser | null = null;
	#vite: ViteDevServer | null = null;
	#viteProcess: BridgeViewerOwnedViteServer | null = null;
	#closeBrowser: Browser['close'] | null = null;
	#browserCloseOptions: Parameters<Browser['close']>[0];
	#operations: LaunchCleanupOperation[] = [];
	#disposal: HandledLaunchPromise<BridgeWebTestLaunchCleanup> | null = null;
	#closed = false;
	#cleanup: BridgeWebTestLaunchCleanup = {
		backend: null,
		browserDisconnected: true,
		dataRootRemoved: false,
		failures: [],
		viteClosed: true,
		viteProcess: null,
	};

	private constructor(dataRootPath: Promise<string>) {
		this.#root = handleLaunchPromise(dataRootPath, 'create data root');
		activeLaunches.add(this);
		installExitHooks();
	}

	static async start(
		spec: BridgeWebTestLaunchSpec = {},
		dependencies: BridgeWebTestLaunchDependencies = {
			startBackend: startOwnedBridgeDevelopmentServer,
		},
	): Promise<BridgeWebTestLaunch> {
		const launch = new BridgeWebTestLaunch(
			mkdtemp(join(tmpdir(), spec.dataRootPrefix ?? 'bridge-web-test-launch-')),
		);
		try {
			launch.#dataRootPath = await launch.#root.value();
			launch.#requireOpen();
			if (spec.backend !== undefined) {
				await launch.#acquire(
					dependencies.startBackend({
						...spec.backend,
						dataRootPath: launch.dataRootPath,
						onSpawn: (backend): void => {
							launch.#backend = backend;
							if (launch.#closed) {
								const stopping = handleLaunchPromise(backend.stop(), 'late Swift spawn teardown');
								launch.#acquisitions.add(stopping.settled);
							}
						},
					}),
					(backend): void => {
						launch.#backend = backend;
					},
				);
			}
			launch.#requireOpen();
			return launch;
		} catch (error: unknown) {
			return await launch.disposeAfterFailure(error);
		}
	}

	get dataRootPath(): string {
		if (this.#dataRootPath === null) throw new Error('Test launch data root is not ready.');
		return this.#dataRootPath;
	}

	get backend(): OwnedBridgeDevelopmentServer {
		if (this.#backend === null) throw new Error('Test launch has no Swift backend.');
		return this.#backend;
	}

	get cleanup(): BridgeWebTestLaunchCleanup {
		return this.#cleanup;
	}

	async startVite(configuration: InlineConfig): Promise<ViteDevServer> {
		this.#requireOpen();
		if (this.#vite !== null || this.#viteProcess !== null)
			throw new Error('Test launch already owns Vite.');
		try {
			const vite = await this.#acquire(
				(async (): Promise<ViteDevServer> =>
					await createServer({
						...configuration,
						cacheDir: join(this.dataRootPath, 'vite-cache'),
						server: {
							...configuration.server,
							host: '127.0.0.1',
							port: await reserveLoopbackPort(),
							strictPort: true,
						},
					}))(),
				(server): void => {
					this.#vite = server;
				},
			);
			this.#vite = vite;
			this.#cleanup = { ...this.#cleanup, viteClosed: false };
			if (this.#closed) {
				await vite.close();
				this.#requireOpen();
			}
			this.#requireOpen();
			if (configuration.server?.middlewareMode !== true) await vite.listen();
			return vite;
		} catch (error: unknown) {
			return await this.disposeAfterFailure(error);
		}
	}

	async launchBrowser(options: LaunchOptions = { headless: true }): Promise<Browser> {
		this.#requireOpen();
		if (this.#browser !== null) throw new Error('Test launch already owns a browser.');
		try {
			const browser = await this.#acquire(chromium.launch(options), (ownedBrowser): void => {
				this.#browser = ownedBrowser;
				this.#closeBrowser = ownedBrowser.close.bind(ownedBrowser);
			});
			this.#browser = browser;
			this.#cleanup = { ...this.#cleanup, browserDisconnected: false };
			if (this.#closed) {
				await browser.close();
				this.#requireOpen();
			}
			this.#requireOpen();
			// Preserve the existing collectors' Browser API. close() delegates to
			// this owner; teardown calls the captured native close exactly once.
			browser.close = async (closeOptions): Promise<void> => {
				this.#browserCloseOptions = closeOptions;
				await this.dispose();
			};
			return browser;
		} catch (error: unknown) {
			return await this.disposeAfterFailure(error);
		}
	}

	async startChild(
		backend: NonNullable<BridgeWebTestLaunchSpec['backend']>,
	): Promise<BridgeWebTestLaunch> {
		this.#requireOpen();
		const child = await BridgeWebTestLaunch.start();
		try {
			this.ownFixture('child stack', async (): Promise<void> => {
				await child.dispose();
			});
			await child.#acquire(
				startOwnedBridgeDevelopmentServer({
					...backend,
					dataRootPath: this.dataRootPath,
					onSpawn: (server): void => {
						child.#backend = server;
						if (child.#closed) {
							child.#acquisitions.add(
								handleLaunchPromise(server.stop(), 'late child spawn teardown').settled,
							);
						}
					},
				}),
				(server): void => {
					child.#backend = server;
				},
			);
			child.#requireOpen();
			return child;
		} catch (error: unknown) {
			return await child.disposeAfterFailure(error);
		}
	}

	// Pre-navigation reads are a scoped lifetime. Their client is closed even
	// when the read fails, before plain data is returned to the page journey.
	async readProductData<TValue>(
		read: () => Promise<TValue>,
		closeClient: () => Promise<void>,
	): Promise<TValue> {
		this.#requireOpen();
		let closing: HandledLaunchPromise<void> | null = null;
		const close = async (): Promise<void> => {
			closing ??= handleLaunchPromise(closeClient(), 'release product data client');
			await closing.value();
		};
		this.ownFixture('product data client', close);
		const outcome = await handleLaunchPromise(read(), 'pre-navigation product data read').settled;
		try {
			await close();
		} catch (error: unknown) {
			throw new AggregateError(
				outcome.kind === 'failed' ? [outcome.error, error] : [error],
				'Product data read/client release failed.',
			);
		}
		if (outcome.kind === 'failed') throw outcome.error;
		this.#requireOpen();
		return outcome.value;
	}

	async startViteChild(props: {
		readonly bridgeWebRootPath: string;
		readonly environment?: Readonly<Record<string, string>>;
	}): Promise<BridgeViewerOwnedViteServer> {
		this.#requireOpen();
		if (this.#vite !== null || this.#viteProcess !== null)
			throw new Error('Test launch already owns Vite.');
		try {
			return await this.#acquire(
				BridgeViewerOwnedViteServer.start({
					...props,
					bridgeDevelopmentServerOrigin: this.backend.origin,
					environment: {
						...props.environment,
						BRIDGE_WEB_VITE_CACHE_DIR: join(this.dataRootPath, 'vite-cache'),
					},
					onSpawn: (server): void => {
						this.#viteProcess = server;
						if (this.#closed)
							this.#acquisitions.add(
								handleLaunchPromise(server.stop(), 'late Vite spawn teardown').settled,
							);
					},
				}),
				(server): void => {
					this.#viteProcess = server;
				},
			);
		} catch (error: unknown) {
			return await this.disposeAfterFailure(error);
		}
	}

	// Test-owned extra fixtures (such as telemetry receivers) share this lifetime.
	// Stack resources themselves use the typed methods above.
	ownFixture(name: string, dispose: () => Promise<void>): void {
		this.#requireOpen();
		this.#operations.push({ name, run: dispose });
	}

	async disposeAfterFailure(error: unknown): Promise<never> {
		try {
			await this.dispose();
		} catch (cleanupError: unknown) {
			throw new AggregateError([error, cleanupError], 'BridgeWeb launch and teardown failed.', {
				cause: error,
			});
		}
		throw error;
	}

	async dispose(): Promise<BridgeWebTestLaunchCleanup> {
		this.#disposal ??= handleLaunchPromise(this.#dispose(), 'owned stack teardown');
		return await this.#disposal.value();
	}

	async #dispose(): Promise<BridgeWebTestLaunchCleanup> {
		this.#closed = true;
		// Stop a child already registered before readiness before joining pending
		// acquisition: its exit is what releases a stuck readiness operation.
		const earlyViteStop =
			this.#viteProcess === null
				? null
				: handleLaunchPromise(this.#viteProcess.stop(), 'stop starting Vite');
		const earlyBackendStop =
			this.#backend === null
				? null
				: handleLaunchPromise(this.#backend.stop(), 'stop starting backend');
		await Promise.all(this.#acquisitions);
		const rootOutcome = await this.#root.settled;
		if (rootOutcome.kind === 'succeeded') this.#dataRootPath = rootOutcome.value;
		const operations: LaunchCleanupOperation[] = [
			{
				name: 'browser',
				run: async (): Promise<void> => {
					await this.#closeBrowser?.(this.#browserCloseOptions);
					const browserDisconnected = !(this.#browser?.isConnected() ?? false);
					this.#cleanup = { ...this.#cleanup, browserDisconnected };
					if (!browserDisconnected)
						throw new Error('Owned browser remained connected after close.');
				},
			},
			{
				name: 'Vite',
				run: async (): Promise<void> => {
					await this.#vite?.close();
					const viteClosed = !(this.#vite?.httpServer?.listening ?? false);
					this.#cleanup = { ...this.#cleanup, viteClosed };
					if (!viteClosed) throw new Error('Owned Vite listener survived close.');
				},
			},
			{
				name: 'Vite child',
				run: async (): Promise<void> => {
					const viteProcess =
						earlyViteStop === null
							? ((await this.#viteProcess?.stop()) ?? null)
							: await earlyViteStop.value();
					this.#cleanup = { ...this.#cleanup, viteProcess };
					if (viteProcess?.ownedProcessAliveAfterStop === true)
						throw new Error('Owned Vite child survived teardown.');
				},
			},
			{
				name: 'Swift backend',
				run: async (): Promise<void> => {
					const backend =
						earlyBackendStop === null
							? ((await this.#backend?.stop()) ?? null)
							: await earlyBackendStop.value();
					this.#cleanup = { ...this.#cleanup, backend };
					if (backend?.ownedProcessAliveAfterStop === true)
						throw new Error('Owned Swift child survived teardown.');
				},
			},
			...this.#operations,
		];
		const results = await Promise.allSettled(
			operations.map(async (operation): Promise<void> => await operation.run()),
		);
		const failures: unknown[] = [];
		const failureNames: string[] = [];
		for (const [index, result] of results.entries()) {
			if (result.status === 'rejected') {
				failures.push(result.reason);
				failureNames.push(operations[index]?.name ?? 'unknown');
			}
		}
		if (rootOutcome.kind === 'failed') {
			failures.push(rootOutcome.error);
			failureNames.push('data root creation');
		} else
			try {
				await rm(this.dataRootPath, { force: true, recursive: true });
				try {
					await access(this.dataRootPath);
					throw new Error('Owned data root survived teardown.');
				} catch (error: unknown) {
					if (!(error instanceof Error && 'code' in error && error.code === 'ENOENT')) throw error;
				}
				this.#cleanup = { ...this.#cleanup, dataRootRemoved: true };
			} catch (error: unknown) {
				failures.push(error);
				failureNames.push('data root');
			}
		this.#cleanup = { ...this.#cleanup, failures: failureNames };
		activeLaunches.delete(this);
		if (activeLaunches.size === 0) registry.removeExitHooks?.();
		if (failures.length > 0)
			throw new AggregateError(
				failures,
				`BridgeWeb owned teardown failed: ${failureNames.join(', ')}`,
			);
		return this.#cleanup;
	}

	async #acquire<TResource>(
		promise: Promise<TResource>,
		register: (resource: TResource) => void,
	): Promise<TResource> {
		const observation = handleLaunchPromise(
			promise.then((resource): TResource => {
				register(resource);
				return resource;
			}),
			'acquire owned resource',
		);
		this.#acquisitions.add(observation.settled);
		try {
			return await observation.value();
		} finally {
			this.#acquisitions.delete(observation.settled);
		}
	}

	#requireOpen(): void {
		if (this.#closed) throw new Error('BridgeWeb test launch is disposed.');
	}
}
