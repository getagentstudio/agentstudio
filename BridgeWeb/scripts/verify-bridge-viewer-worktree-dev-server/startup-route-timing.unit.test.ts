import type { Page, Request, Response } from 'playwright';
import { expect, test, vi } from 'vitest';

import { handleLaunchPromise } from '../dev-server/handled-launch-promise.ts';
import { observeWorktreeFileContentRouteTiming } from './startup-route-timing.ts';

vi.mock('./browser-session.ts', (): object => ({
	observeVerifierStartupStep: (name: string, promise: Promise<unknown>) =>
		handleLaunchPromise(promise, name),
}));

test('route observations have no separate speed budget and settle early rejection before consumption', async () => {
	const waitForRequest = vi.fn(
		(): Promise<Request> => Promise.reject(new Error('request owner failed')),
	);
	const waitForResponse = vi.fn(
		(): Promise<Response> => Promise.reject(new Error('response owner failed')),
	);
	const observations = observeWorktreeFileContentRouteTiming({
		page: { waitForRequest, waitForResponse } as unknown as Page,
		startedAt: performance.now(),
	});
	expect(waitForRequest.mock.calls[0]).toHaveLength(1);
	expect(waitForResponse.mock.calls[0]).toHaveLength(1);
	expect((await observations.requestStartedMilliseconds.settled).kind).toBe('failed');
	expect((await observations.responseStartedMilliseconds.settled).kind).toBe('failed');
	await expect(observations.requestStartedMilliseconds.value()).rejects.toThrow(
		'initial File content request',
	);
	await expect(observations.responseStartedMilliseconds.value()).rejects.toThrow(
		'initial File content response',
	);
});
