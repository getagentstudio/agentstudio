import { spawn } from 'node:child_process';

import { expect, test } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import { stopBridgeViewerOwnedViteProductProcesses } from './bridge-viewer-vite-product-fixture.ts';
import {
	createTabOwnershipCleanup,
	createTabOwnershipStepCheckpoint,
	observeTabOwnershipBootstrap,
} from './bridge-viewer-vite-tab-ownership-test-support.ts';

test('runner finish stops the owned child while the journey and browser close are held', async (): Promise<void> => {
	const ownedChild = await startOwnedNodeChild();
	const journeyRelease = createBridgeProductDeferred<void>();
	const browserCloseRelease = createBridgeProductDeferred<void>();
	const browserCloseArrived = createBridgeProductDeferred<void>();
	const finishHooks: (() => Promise<void>)[] = [];
	let backendStops = 0;
	let browserCloses = 0;
	let fixtureDisposals = 0;
	const cleanup = createTabOwnershipCleanup({
		registerOnFinished: (finish): void => {
			finishHooks.push(finish);
		},
		stopServer: async (): Promise<void> => {
			backendStops += 1;
			await ownedChild.stop();
		},
		closeBrowser: async (): Promise<void> => {
			browserCloses += 1;
			browserCloseArrived.resolve();
			await browserCloseRelease.promise;
		},
		disposeFixture: async (): Promise<void> => {
			fixtureDisposals += 1;
		},
	});
	const journey = (async (): Promise<void> => {
		try {
			await journeyRelease.promise;
		} finally {
			await cleanup.stop();
		}
	})();
	let runnerFinish: Promise<void> | undefined;
	try {
		const finish = finishHooks[0];
		if (finish === undefined) throw new Error('Runner cleanup was not registered.');
		runnerFinish = finish();
		// The finish event is injected directly: no timer decides this regression verdict.
		const outcome = await Promise.race([
			ownedChild.whenExited.then((): string => 'owned-child-exited'),
			runnerFinish.then((): string => 'runner-returned-without-child-exit'),
		]);
		expect(outcome).toBe('owned-child-exited');
		await browserCloseArrived.promise;
		expect(fixtureDisposals).toBe(0);
		const normalCleanup = cleanup.stop();
		expect(cleanup.stop()).toBe(normalCleanup);
		browserCloseRelease.resolve();
		journeyRelease.resolve();
		await Promise.all([runnerFinish, normalCleanup, journey]);
		expect(backendStops).toBe(1);
		expect(browserCloses).toBe(1);
		expect(fixtureDisposals).toBe(1);
	} finally {
		browserCloseRelease.resolve();
		journeyRelease.resolve();
		await ownedChild.stop();
		await Promise.allSettled([journey, runnerFinish]);
	}
});

test('the backend exits while Vite shutdown remains held', async (): Promise<void> => {
	const ownedChild = await startOwnedNodeChild();
	const viteStopRelease = createBridgeProductDeferred<void>();
	const viteStopArrived = createBridgeProductDeferred<void>();
	const stopping = stopBridgeViewerOwnedViteProductProcesses([
		{
			name: 'Vite',
			run: async (): Promise<void> => {
				viteStopArrived.resolve();
				await viteStopRelease.promise;
			},
		},
		{ name: 'backend', run: ownedChild.stop },
	]);
	try {
		await viteStopArrived.promise;
		await ownedChild.whenExited;
	} finally {
		viteStopRelease.resolve();
		await ownedChild.stop();
		await stopping;
	}
});

test('cleanup retains process failures and still disposes the fixture', async (): Promise<void> => {
	const backendFailure = new Error('backend stop failed');
	let fixtureDisposed = false;
	const cleanup = createTabOwnershipCleanup({
		registerOnFinished: (): void => {},
		stopServer: async (): Promise<void> => {
			throw backendFailure;
		},
		closeBrowser: async (): Promise<void> => {
			throw new Error('browser close failed');
		},
		disposeFixture: async (): Promise<void> => {
			fixtureDisposed = true;
		},
	});
	await expect(cleanup.stop()).rejects.toMatchObject({
		errors: [expect.objectContaining({ errors: expect.arrayContaining([backendFailure]) })],
	});
	expect(fixtureDisposed).toBe(true);
});

test('all product process stops are attempted even when Vite stop fails synchronously', async (): Promise<void> => {
	let backendStopped = false;
	await expect(
		stopBridgeViewerOwnedViteProductProcesses([
			{
				name: 'Vite',
				run: (): Promise<void> => {
					throw new Error('Vite stop failed');
				},
			},
			{
				name: 'backend',
				run: async (): Promise<void> => {
					backendStopped = true;
				},
			},
		]),
	).rejects.toThrow('Owned product server cleanup failed.');
	expect(backendStopped).toBe(true);
});

test('Refresh observes the new document bootstrap rather than the old document response', async (): Promise<void> => {
	const transport = new BootstrapResponseTransport();
	const response = observeTabOwnershipBootstrap(transport.observationProps());
	const staleResponse = transport.response(1, '/__bridge-product/bootstrap');
	transport.emitResponse(staleResponse);
	transport.emitResponse(transport.response(2, '/__bridge-product/command'));
	const refreshedResponse = transport.response(2, '/__bridge-product/bootstrap');
	transport.emitResponse(refreshedResponse);
	expect(await response).toBe(refreshedResponse);
	expect(await response).not.toBe(staleResponse);
	expect(transport.listenerCount()).toBe(0);
});

test.each(['abort', 'close', 'requestfailed'] as const)(
	'bootstrap observation fails and detaches on %s',
	async (termination: 'abort' | 'close' | 'requestfailed'): Promise<void> => {
		const transport = new BootstrapResponseTransport();
		const response = observeTabOwnershipBootstrap(transport.observationProps());
		const failed = expect(response).rejects.toThrow();
		if (termination === 'abort') transport.controller.abort(new Error('runner aborted'));
		else if (termination === 'close') transport.close();
		else {
			transport.failRequest(transport.response(1, '/__bridge-product/bootstrap').request());
			transport.failRequest(transport.response(2, '/__bridge-product/bootstrap').request());
		}
		await failed;
		expect(transport.listenerCount()).toBe(0);
	},
);

test('a previously aborted runner cannot retain a bootstrap observer', async (): Promise<void> => {
	const transport = new BootstrapResponseTransport();
	transport.controller.abort(new Error('runner already aborted'));
	await expect(observeTabOwnershipBootstrap(transport.observationProps())).rejects.toThrow(
		'runner already aborted',
	);
	expect(transport.listenerCount()).toBe(0);
});

test('step checkpoints name the last begun wait without claiming completion', (): void => {
	const recorded: string[] = [];
	const checkpoint = createTabOwnershipStepCheckpoint({
		topology: 'shared-profile',
		record: (message: string): void => {
			recorded.push(message);
		},
	});
	checkpoint.begin('close first tab');
	checkpoint.begin('select second tab Review file after first tab close');
	expect(checkpoint.lastStep()).toBe('select second tab Review file after first tab close');
	expect(recorded).toEqual([
		'TQ35 shared-profile: begin close first tab',
		'TQ35 shared-profile: begin select second tab Review file after first tab close',
	]);
});

interface ObservedBootstrapRequest {
	readonly generation: number;
	readonly method: () => string;
	readonly url: () => string;
}

interface ObservedBootstrapResponse {
	readonly request: () => ObservedBootstrapRequest;
}

/** Only the external page event transport is faked; correlation/settlement stay real. */
class BootstrapResponseTransport {
	readonly controller = new AbortController();
	readonly #responseListeners = new Set<(response: ObservedBootstrapResponse) => void>();
	readonly #requestFailureListeners = new Set<(request: ObservedBootstrapRequest) => void>();
	readonly #closeListeners = new Set<() => void>();

	observationProps(): Parameters<
		typeof observeTabOwnershipBootstrap<ObservedBootstrapRequest, ObservedBootstrapResponse>
	>[0] {
		return {
			transport: {
				subscribeResponse: (listener): (() => void) => {
					this.#responseListeners.add(listener);
					return (): void => {
						this.#responseListeners.delete(listener);
					};
				},
				subscribeRequestFailure: (listener): (() => void) => {
					this.#requestFailureListeners.add(listener);
					return (): void => {
						this.#requestFailureListeners.delete(listener);
					};
				},
				subscribeClose: (listener): (() => void) => {
					this.#closeListeners.add(listener);
					return (): void => {
						this.#closeListeners.delete(listener);
					};
				},
			},
			requestGeneration: (request: ObservedBootstrapRequest): number => request.generation,
			expectedDocumentGeneration: 2,
			signal: this.controller.signal,
		};
	}

	response(generation: number, path: string): ObservedBootstrapResponse {
		const request = {
			generation,
			method: (): string => 'POST',
			url: (): string => `http://fixture${path}`,
		} satisfies ObservedBootstrapRequest;
		return { request: (): ObservedBootstrapRequest => request };
	}

	emitResponse(response: ObservedBootstrapResponse): void {
		for (const listener of this.#responseListeners) listener(response);
	}

	failRequest(request: ObservedBootstrapRequest): void {
		for (const listener of this.#requestFailureListeners) listener(request);
	}

	close(): void {
		for (const listener of this.#closeListeners) listener();
	}

	listenerCount(): number {
		return (
			this.#responseListeners.size + this.#requestFailureListeners.size + this.#closeListeners.size
		);
	}
}

interface OwnedNodeChild {
	readonly whenExited: Promise<void>;
	readonly stop: () => Promise<void>;
}

async function startOwnedNodeChild(): Promise<OwnedNodeChild> {
	const child = spawn(
		process.execPath,
		['-e', "process.on('message', () => {}); process.send('ready');"],
		{
			stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
		},
	);
	const whenExited = new Promise<void>((resolve, reject): void => {
		child.once('exit', (): void => resolve());
		child.once('error', reject);
	});
	try {
		await new Promise<void>((resolve, reject): void => {
			child.once('message', (message: unknown): void => {
				if (message === 'ready') resolve();
				else reject(new Error('Owned child announced an unexpected readiness message.'));
			});
			child.once('error', reject);
			child.once('exit', (): void => reject(new Error('Owned child exited before readiness.')));
		});
	} catch (error: unknown) {
		child.kill('SIGTERM');
		await whenExited;
		throw error;
	}
	return {
		whenExited,
		stop: async (): Promise<void> => {
			child.kill('SIGTERM');
			await whenExited;
		},
	};
}
