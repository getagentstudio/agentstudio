import { describe, expect, test } from 'vitest';

import { BridgeProductReadAhead } from './bridge-product-read-ahead.js';

describe('Bridge product fetch read ahead', () => {
	test('keeps a pull outstanding while each delivered chunk is being processed', async () => {
		const pendingPulls: ReadableStreamDefaultController<Uint8Array>[] = [];
		let pullCount = 0;
		const pullNotifications: Array<() => void> = [];
		const pullEvents = Array.from(
			{ length: 3 },
			(): Promise<void> =>
				new Promise<void>((resolve): void => {
					pullNotifications.push(resolve);
				}),
		);
		const stream = new ReadableStream<Uint8Array>(
			{
				pull(controller): void {
					pendingPulls.push(controller);
					pullNotifications[pullCount]?.();
					pullCount += 1;
				},
			},
			{ highWaterMark: 0 },
		);
		const reader = stream.getReader();
		const readAhead = new BridgeProductReadAhead(reader);
		await pullEvents[0];
		expect(pullCount).toBe(1);
		pendingPulls.at(-1)?.enqueue(new Uint8Array([1]));
		const first = await readAhead.next();
		expect(first.value).toEqual(new Uint8Array([1]));
		await pullEvents[1];
		expect(pullCount).toBe(2);
		pendingPulls.at(-1)?.enqueue(new Uint8Array([2]));
		const second = await readAhead.next();
		expect(second.value).toEqual(new Uint8Array([2]));
		await pullEvents[2];
		expect(pullCount).toBe(3);
		pendingPulls.at(-1)?.close();
		expect((await readAhead.next()).done).toBe(true);
		reader.releaseLock();
	});
});
