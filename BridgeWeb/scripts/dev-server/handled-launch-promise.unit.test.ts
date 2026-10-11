import { expect, test } from 'vitest';

import { handleLaunchPromise } from './handled-launch-promise.ts';

test('an early failure settles before the later await and retains the named step', async () => {
	const originalFailure = new Error('upstream failed');
	const observation = handleLaunchPromise(
		Promise.reject(originalFailure),
		'initial content request',
	);
	const settled = await observation.settled;
	expect(settled.kind).toBe('failed');
	await expect(observation.value()).rejects.toThrow('initial content request');
	await expect(observation.value()).rejects.toMatchObject({ cause: originalFailure });
});

test('an early success retains its value at the later await', async () => {
	const observation = handleLaunchPromise(Promise.resolve(42), 'initial content response');
	expect(await observation.settled).toEqual({ kind: 'succeeded', value: 42 });
	expect(await observation.value()).toBe(42);
});
