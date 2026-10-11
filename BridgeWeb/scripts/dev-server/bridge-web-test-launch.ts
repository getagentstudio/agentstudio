import { access, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { chromium, type Browser, type LaunchOptions } from 'playwright';
import { createServer, type InlineConfig, type ViteDevServer } from 'vite';

import { BridgeViewerOwnedViteServer } from '../verify-bridge-viewer-worktree-dev-server/product-only-real-router-regression.ts';
import { createOwnedVerifierJourneyDeadline } from '../verify-bridge-viewer-worktree-dev-server/verifier-journey-deadline.ts';
import {
	startOwnedBridgeDevelopmentServer,
	type OwnedBridgeDevelopmentServer,
} from './bridge-development-server-process.ts';
import type {
	BridgeWebOwnedProductDataClient,
	BridgeWebTestLaunchCleanup,
	BridgeWebTestLaunchSpec,
	BridgeWebTestLaunchDependencies,
} from './bridge-web-test-launch-contracts.ts';
import {
	activeLaunches,
	installExitHooks,
	removeUnusedExitHooks,
} from './bridge-web-test-launch-registry.ts';
import {
	currentBridgeWebLaunchScope,
	runWithBridgeWebLaunchScope,
} from './bridge-web-test-launch-scope.ts';
import {
	handleLaunchPromise,
	type HandledLaunchPromise,
	type LaunchPromiseOutcome,
} from './handled-launch-promise.ts';
export type {
	BridgeWebOwnedProductDataClient,
	BridgeWebTestLaunchCleanup,
	BridgeWebTestLaunchSpec,
	BridgeWebTestLaunchDependencies,
} from './bridge-web-test-launch-contracts.ts';
import { reserveLoopbackPort } from './reserve-loopback-port.ts';

interface LaunchCleanupOperation {
	readonly name: string;
	readonly run: () => Promise<void>;
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
	#browserDisposal: HandledLaunchPromise<void> | null = null;
	#operations: LaunchCleanupOperation[] = [];
	#disposal: HandledLaunchPromise<BridgeWebTestLaunchCleanup> | null = null;
	#closed = false;
	readonly #pendingSteps = new Map<symbol, string>();
	readonly #children = new Set<BridgeWebTestLaunch>();
	readonly #signal: AbortSignal;
	readonly #deadline: ReturnType<typeof createOwnedVerifierJourneyDeadline> | null;
	readonly #cancelClients = new Set<BridgeWebOwnedProductDataClient>();
	readonly #dependencies: BridgeWebTestLaunchDependencies;
	#parent: BridgeWebTestLaunch | null = null;
	readonly #onAbort = (): void => {
		void handleLaunchPromise(this.dispose(), 'abort-driven owned teardown').settled;
	};
	#cleanup: BridgeWebTestLaunchCleanup = {
		backend: null,
		browserDisconnected: true,
		dataRootRemoved: false,
		failures: [],
		viteClosed: true,
		viteProcess: null,
	};

	private constructor(
		dataRootPath: Promise<string>,
		spec: BridgeWebTestLaunchSpec,
		dependencies: BridgeWebTestLaunchDependencies,
	) {
		this.#dependencies = dependencies;
		this.#root = this.observeStep('create data root', dataRootPath);
		activeLaunches.add(this);
		installExitHooks();
		const ownerSignal = spec.signal ?? currentBridgeWebLaunchScope()?.signal;
		this.#deadline =
			ownerSignal === undefined
				? createOwnedVerifierJourneyDeadline({
						pendingSteps: (): readonly string[] => this.pendingSteps,
						closePages: async (): Promise<void> => {
							await this.dispose();
						},
					})
				: null;
		const signal = ownerSignal ?? this.#deadline?.signal;
		if (signal === undefined) throw new Error('Launch lifetime has no bound owner.');
		this.#signal = signal;
		this.#signal.addEventListener('abort', this.#onAbort, { once: true });
		this.#attachScope(true);
		if (this.#signal.aborted) this.#onAbort();
	}

	static async start(
		spec: BridgeWebTestLaunchSpec = {},
		dependencies: BridgeWebTestLaunchDependencies = {
			startBackend: startOwnedBridgeDevelopmentServer,
		},
	): Promise<BridgeWebTestLaunch> {
		const launch = new BridgeWebTestLaunch(
			mkdtemp(join(tmpdir(), spec.dataRootPrefix ?? 'bridge-web-test-launch-')),
			spec,
			dependencies,
		);
		try {
			launch.#dataRootPath = await launch.#root.value();
			launch.#requireOpen();
			if (spec.backend !== undefined) await launch.#startBackend(spec.backend, launch.dataRootPath);
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

	// Browser-only proofs have their own complete launch scope. A browser used
	// inside a shared stack instead closes only that browser's owned resource.
	static async startBrowser(options: LaunchOptions, signal?: AbortSignal): Promise<Browser> {
		const launch = await BridgeWebTestLaunch.start(signal === undefined ? {} : { signal });
		const browser = await launch.launchBrowser(options);
		browser.close = async (closeOptions): Promise<void> => {
			launch.#browserCloseOptions = closeOptions;
			await launch.dispose();
		};
		return browser;
	}

	get backend(): OwnedBridgeDevelopmentServer {
		if (this.#backend === null) throw new Error('Test launch has no Swift backend.');
		return this.#backend;
	}

	get cleanup(): BridgeWebTestLaunchCleanup {
		return this.#cleanup;
	}

	observeStep<TValue>(name: string, promise: Promise<TValue>): HandledLaunchPromise<TValue> {
		const observation = handleLaunchPromise(promise, name);
		const identity = Symbol(name);
		this.#pendingSteps.set(identity, name);
		if (this.#closed && this.#signal.aborted)
			process.stderr.write(`BRIDGE_LAUNCH_RETIREMENT waiting=${name}\n`);
		void observation.settled.then((): void => {
			this.#pendingSteps.delete(identity);
		});
		return observation;
	}

	get signal(): AbortSignal {
		return this.#signal;
	}
	get pendingSteps(): readonly string[] {
		return [
			...this.#pendingSteps.values(),
			...[...this.#children].flatMap((child) => child.pendingSteps),
		];
	}
	startJourneyHangBound(): AbortSignal {
		this.#requireOpen();
		return this.#signal;
	}

	async run<TValue>(operation: () => Promise<TValue>): Promise<TValue> {
		return await runWithBridgeWebLaunchScope(
			{
				signal: this.#signal,
				ownLaunch: (child): void => {
					if (child !== this) this.#children.add(child);
				},
			},
			operation,
		);
	}

	async runStep<TValue>(
		name: string,
		operation: (signal: AbortSignal) => Promise<TValue>,
	): Promise<TValue> {
		this.#requireOpen();
		try {
			return await this.#acquire(operation(this.#signal), (): void => {}, name);
		} catch (error: unknown) {
			return await this.disposeAfterFailure(error);
		}
	}

	async #startBackend(
		spec: NonNullable<BridgeWebTestLaunchSpec['backend']>,
		dataRootPath: string,
	): Promise<void> {
		await this.#acquire(
			this.#dependencies.startBackend({
				...spec,
				dataRootPath,
				onSpawn: (server): void => {
					this.#backend = server;
					if (this.#closed)
						this.#acquisitions.add(
							handleLaunchPromise(server.stop(), 'late Swift spawn teardown').settled,
						);
				},
			}),
			(server): void => {
				this.#backend = server;
			},
			'Swift readiness',
		);
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
				'Vite acquisition',
			);
			this.#vite = vite;
			this.#cleanup = { ...this.#cleanup, viteClosed: false };
			if (this.#closed) {
				await vite.close();
				this.#requireOpen();
			}
			this.#requireOpen();
			if (configuration.server?.middlewareMode !== true)
				await this.#acquire(vite.listen(), (): void => {}, 'Vite listener readiness');
			return vite;
		} catch (error: unknown) {
			return await this.disposeAfterFailure(error);
		}
	}

	async launchBrowser(options: LaunchOptions = { headless: true }): Promise<Browser> {
		this.#requireOpen();
		if (this.#browser !== null) throw new Error('Test launch already owns a browser.');
		try {
			const browser = await this.#acquire(
				chromium.launch({ ...options, timeout: 0 }),
				(ownedBrowser): void => {
					this.#browser = ownedBrowser;
					this.#closeBrowser = ownedBrowser.close.bind(ownedBrowser);
				},
				'Chromium acquisition',
			);
			this.#browser = browser;
			this.#cleanup = { ...this.#cleanup, browserDisconnected: false };
			if (this.#closed) {
				await browser.close();
				this.#requireOpen();
			}
			this.#requireOpen();
			// Preserve the Browser API while this harness owns resource closure.
			// Closing a journey's browser must not stop a suite's shared stack.
			browser.close = async (closeOptions): Promise<void> => {
				this.#browserCloseOptions = closeOptions;
				await this.#disposeBrowser();
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
		const child = await BridgeWebTestLaunch.start({ signal: this.#signal }, this.#dependencies);
		child.#parent = this;
		child.#attachScope();
		try {
			this.ownFixture('child stack', async (): Promise<void> => {
				await child.dispose();
			});
			await child.#startBackend(backend, this.dataRootPath);
			child.#requireOpen();
			return child;
		} catch (error: unknown) {
			return await child.disposeAfterFailure(error);
		}
	}

	// Own clients before open() suspends; normal completion acknowledges release,
	// while expiry aborts their HTTP/stream owners before joining their work.
	async readProductData<TClient extends BridgeWebOwnedProductDataClient, TValue>(
		createClient: () => TClient,
		read: (client: TClient) => Promise<TValue>,
	): Promise<TValue> {
		this.#requireOpen();
		try {
			const client = createClient();
			this.#cancelClients.add(client);
			const result = await this.#acquire(
				read(client),
				(): void => {},
				'pre-navigation product data read',
			);
			await this.#acquire(
				client.close(),
				(): void => {},
				'acknowledged product installation release',
			);
			this.#cancelClients.delete(client);
			this.#requireOpen();
			return result;
		} catch (error: unknown) {
			return await this.disposeAfterFailure(error);
		}
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
				(
					this.#dependencies.startViteChild ??
					((props: Parameters<typeof BridgeViewerOwnedViteServer.start>[0]) =>
						BridgeViewerOwnedViteServer.start(props))
				)({
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
				'Vite readiness',
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
				cause: cleanupError,
			});
		}
		throw error;
	}

	async dispose(): Promise<BridgeWebTestLaunchCleanup> {
		this.#disposal ??= handleLaunchPromise(this.#dispose(), 'owned stack teardown');
		return await this.#disposal.value();
	}

	async #disposeBrowser(): Promise<void> {
		this.#browserDisposal ??= handleLaunchPromise(
			(async (): Promise<void> => {
				await this.#closeBrowser?.(this.#browserCloseOptions);
				const browserDisconnected = !(this.#browser?.isConnected() ?? false);
				this.#cleanup = { ...this.#cleanup, browserDisconnected };
				if (!browserDisconnected) throw new Error('Owned browser remained connected after close.');
			})(),
			'close owned browser',
		);
		await this.#browserDisposal.value();
	}

	async #dispose(): Promise<BridgeWebTestLaunchCleanup> {
		this.#closed = true;
		const childStops = [...this.#children].map((child) =>
			handleLaunchPromise(child.dispose(), 'retire nested launch'),
		);
		const clientCancellations = [...this.#cancelClients].map((client) =>
			handleLaunchPromise(
				Promise.resolve().then(
					async (): Promise<void> =>
						await client.abort(this.#signal.reason ?? new Error('owned launch disposed')),
				),
				'abort product client',
			),
		);
		const cancelledClients = await Promise.all(
			clientCancellations.map((cancellation) => cancellation.settled),
		);
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
		const childOutcomes = await Promise.all(childStops.map((stopping) => stopping.settled));
		const rootOutcome = await this.#root.settled;
		if (rootOutcome.kind === 'succeeded') this.#dataRootPath = rootOutcome.value;
		const operations: LaunchCleanupOperation[] = [
			{
				name: 'browser',
				run: async (): Promise<void> => {
					await this.#disposeBrowser();
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
			operations.map(
				async (operation): Promise<void> =>
					await this.observeStep(
						`retire ${operation.name}`,
						Promise.resolve().then(operation.run),
					).value(),
			),
		);
		const failures: unknown[] = [...cancelledClients, ...childOutcomes].flatMap((outcome) =>
			outcome.kind === 'failed' ? [outcome.error] : [],
		);
		const failureNames: string[] = failures.map(() => 'retire owned dependent');
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
		this.#deadline?.cancel();
		this.#signal.removeEventListener('abort', this.#onAbort);
		activeLaunches.delete(this);
		removeUnusedExitHooks();
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
		name: string = 'acquire owned resource',
	): Promise<TResource> {
		const observation = this.observeStep(
			name,
			promise.then((resource): TResource => {
				register(resource);
				return resource;
			}),
		);
		this.#acquisitions.add(observation.settled);
		try {
			const value = await observation.value();
			this.#requireOpen();
			return value;
		} catch (error: unknown) {
			if (this.#signal.aborted)
				throw new Error(`BridgeWeb launch aborted: ${String(this.#signal.reason)}`, {
					cause: error,
				});
			throw error;
		} finally {
			this.#acquisitions.delete(observation.settled);
		}
	}

	#attachScope(created: boolean = false): void {
		const scope = currentBridgeWebLaunchScope();
		if (scope !== undefined) {
			scope.ownLaunch(this, created);
			if (this.#parent !== null) this.#parent.#attachScope();
		}
	}

	#requireOpen(): void {
		this.#attachScope();
		this.#signal.throwIfAborted();
		if (this.#closed) throw new Error('BridgeWeb test launch is disposed.');
	}
}
