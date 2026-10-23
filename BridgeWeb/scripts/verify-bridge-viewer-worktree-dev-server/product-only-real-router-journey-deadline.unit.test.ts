import { expect, test, vi } from 'vitest';

import { createOwnedProductJourneyDeadline } from './product-only-real-router-journey-deadline.ts';

test('the journey deadline also ends a missed worker close during cleanup', async (): Promise<void> => {
	vi.useFakeTimers();
	let releasePageClose!: () => void;
	const pageClosed = new Promise<void>((resolve): void => {
		releasePageClose = resolve;
	});
	const pageClose = vi.fn(async (): Promise<void> => {
		await pageClosed;
	});
	const browserClose = vi.fn(async (): Promise<void> => {});
	const deadlineController = new AbortController();
	const deadline = createOwnedProductJourneyDeadline({
		signal: deadlineController.signal,
		page: { close: pageClose },
		browser: { close: browserClose },
	});
	let closeWorker!: () => void;
	const workerClosed = new Promise<void>((resolve): void => {
		closeWorker = resolve;
	});
	const joined = deadline.waitFor(workerClosed, 'observed-worker-closure').then(
		(): string => 'closed',
		(error: unknown): string => String(error),
	);
	try {
		deadlineController.abort(new Error('inherited launch bound exceeded'));
		expect(await joined).toContain('awaiting observed-worker-closure');
		expect(pageClose).toHaveBeenCalledOnce();
		expect(browserClose).not.toHaveBeenCalled();
		releasePageClose();
		await deadline.dispose();
		expect(browserClose).toHaveBeenCalledOnce();
	} finally {
		releasePageClose();
		closeWorker();
		await joined;
		await deadline.dispose();
		vi.useRealTimers();
	}
});
