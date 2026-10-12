import type { Plugin, ViteDevServer } from 'vite';

import type { BridgeWebViteLateListenerRetirement } from './bridge-web-test-launch-contracts.ts';
import { handleLaunchPromise, type HandledLaunchPromise } from './handled-launch-promise.ts';

interface PendingOptimizerOutput {
	readonly completion: Promise<void>;
	readonly resolve: () => void;
}

// Capture Vite before user configuration hooks suspend. Closing this resource
// precedes joining acquisition, so a close-aware hook can retire its work.
export class BridgeWebOwnedViteLifetime {
	#server: ViteDevServer | null = null;
	#retirementRequested = false;
	#disposal: HandledLaunchPromise<void> | null = null;
	#listenerClosed = true;
	#lateListenerRetirement: BridgeWebViteLateListenerRetirement = { kind: 'not-required' };
	readonly #optimizerOutputs = new Set<PendingOptimizerOutput>();
	readonly #optimizerOutputQueue: PendingOptimizerOutput[] = [];
	readonly optimizerPlugin = {
		name: 'bridge-web-test-launch-optimizer-owner',
		generateBundle: (): void => {
			if (this.#retirementRequested)
				throw new Error('Vite optimizer output started after launch retirement');
			let resolveCompletion!: () => void;
			const completion = new Promise<void>((resolve): void => {
				resolveCompletion = resolve;
			});
			const output = { completion, resolve: resolveCompletion };
			this.#optimizerOutputs.add(output);
			this.#optimizerOutputQueue.push(output);
		},
		writeBundle: (): void => {
			this.#completeOptimizerOutput();
		},
		closeBundle: (): void => {
			while (this.#optimizerOutputQueue.length > 0) this.#completeOptimizerOutput();
		},
	};

	readonly plugin: Plugin = {
		name: 'bridge-web-test-launch-vite-owner',
		enforce: 'pre',
		configureServer: {
			order: 'pre',
			handler: (server): void => {
				this.#server = server;
				this.#listenerClosed = false;
				if (this.#retirementRequested) {
					void handleLaunchPromise(this.close(), 'late Vite capture retirement').settled;
					throw new Error('Vite acquisition retired before configuration completed');
				}
			},
		},
	};

	get owned(): boolean {
		return this.#server !== null;
	}

	get listenerClosed(): boolean {
		return this.#listenerClosed;
	}

	get lateListenerRetirement(): BridgeWebViteLateListenerRetirement {
		return this.#lateListenerRetirement;
	}

	async close(): Promise<void> {
		this.#retirementRequested = true;
		const server = this.#server;
		if (server === null) return;
		this.#disposal ??= handleLaunchPromise(
			(async (): Promise<void> => {
				await server.close();
			})(),
			'close owned Vite',
		);
		await this.#disposal.value();
		this.#listenerClosed = !(server.httpServer?.listening ?? false);
	}

	async waitForOptimizerOutputs(): Promise<void> {
		while (this.#optimizerOutputs.size > 0) {
			await Promise.all([...this.#optimizerOutputs].map((output) => output.completion));
		}
	}

	#completeOptimizerOutput(): void {
		const output = this.#optimizerOutputQueue.shift();
		if (output === undefined) return;
		this.#optimizerOutputs.delete(output);
		output.resolve();
	}

	// Vite memoizes close(). A suspended listen can reopen HTTP after that close;
	// acquisition must be physically joined before this last listener retirement.
	async retireLateListener(): Promise<void> {
		const httpServer = this.#server?.httpServer;
		if (httpServer === null || httpServer === undefined || !httpServer.listening) return;
		let closeEventObserved = false;
		const observeClose = (): void => {
			closeEventObserved = true;
		};
		try {
			await handleLaunchPromise(
				new Promise<void>((resolve, reject): void => {
					httpServer.once('close', observeClose);
					httpServer.close((error): void => {
						if (error !== undefined) reject(error);
						else if (!closeEventObserved)
							reject(new Error('Late Vite listener close event was not observed.'));
						else resolve();
					});
				}),
				'late Vite listener close event',
			).value();
			this.#listenerClosed = !httpServer.listening;
			if (!this.#listenerClosed) throw new Error('Owned late Vite listener survived close.');
			this.#lateListenerRetirement = { kind: 'closed', closeEventObserved: true };
		} catch (error: unknown) {
			this.#lateListenerRetirement = { kind: 'failed', closeEventObserved };
			throw error;
		} finally {
			httpServer.removeListener('close', observeClose);
		}
	}
}
