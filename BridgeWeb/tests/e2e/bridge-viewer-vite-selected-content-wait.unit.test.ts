import { expect, test } from 'vitest';

import { createBridgeProductDeferred } from '../../src/core/comm-worker/bridge-product-async-queue.js';
import { waitForOwnerOrRetirement } from './bridge-viewer-vite-selected-content-wait.ts';

test('an owner result releases the retirement subscription', async () => {
	let released = false;
	const owner = createBridgeProductDeferred<void>();
	const waiting = waitForOwnerOrRetirement({
		label: 'selected File',
		run: (): Promise<void> => owner.promise,
		subscribeRetirement: (): (() => void) => (): void => {
			released = true;
		},
	});
	owner.resolve();
	await waiting;
	expect(released).toBe(true);
});

test('retirement names its owner while the page operation is still held and consumes its rejection', async () => {
	const owner = createBridgeProductDeferred<void>();
	const retirement = createBridgeProductDeferred<(reason: string) => void>();
	let released = false;
	const waiting = waitForOwnerOrRetirement({
		label: 'selected Review',
		run: (): Promise<void> => owner.promise,
		subscribeRetirement: (retire): (() => void) => {
			retirement.resolve(retire);
			return (): void => {
				released = true;
			};
		},
	});
	const failure = expect(waiting).rejects.toThrow('selected Review ended: page-closed');
	(await retirement.promise)('page-closed');
	await failure;
	owner.reject(new Error('execution context destroyed'));
	await expect(owner.promise).rejects.toThrow('execution context destroyed');
	expect(released).toBe(true);
});

test('already retired pages release the subscription without starting a new evaluation', async () => {
	let evaluationStarted = false;
	let released = false;
	await expect(
		waitForOwnerOrRetirement({
			label: 'selected File',
			run: (): Promise<void> => {
				evaluationStarted = true;
				return Promise.resolve();
			},
			subscribeRetirement: (retire): (() => void) => {
				retire('page-closed');
				return (): void => {
					released = true;
				};
			},
		}),
	).rejects.toThrow('page-closed');
	expect(evaluationStarted).toBe(false);
	expect(released).toBe(true);
});
