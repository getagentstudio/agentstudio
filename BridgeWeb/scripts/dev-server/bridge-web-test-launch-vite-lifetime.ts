import type { Plugin, ViteDevServer } from 'vite';

import type { BridgeWebViteLateListenerRetirement } from './bridge-web-test-launch-contracts.ts';
import { handleLaunchPromise, type HandledLaunchPromise } from './handled-launch-promise.ts';

// Capture Vite before user configuration hooks suspend. Closing this resource
// precedes joining acquisition, so a close-aware hook can retire its work.
export class BridgeWebOwnedViteLifetime {
	#server: ViteDevServer | null = null;
	#retirementRequested = false;
	#disposal: HandledLaunchPromise<void> | null = null;
	#listenerClosed = true;
	#lateListenerRetirement: BridgeWebViteLateListenerRetirement = { kind: 'not-required' };

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
