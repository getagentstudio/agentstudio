import { afterEach, describe, expect, test, vi } from 'vitest';

import {
	createReviewPreparationObservations as makeReviewPreparationObservations,
	cleanupReviewPreparationFixtures,
	driveReviewPreparationUntil,
} from './comm-runtime-protocol.review-preparation.test-support.js';

afterEach((): void => {
	vi.restoreAllMocks();
	vi.useRealTimers();
});

describe('Review preparation harness guards', () => {
	test('drain failure retires the recording wrapper before later callbacks arrive', async (): Promise<void> => {
		const observations = makeReviewPreparationObservations();
		const failure = new Error('held drain failed');
		observations.schedule(async (): Promise<never> => {
			throw failure;
		});
		await expect(
			driveReviewPreparationUntil({
				hasExpectedEvent: (): boolean => false,
				observations,
				startIndex: 0,
			}),
		).rejects.toBe(failure);
		expect(() => observations.retryDeadlineRegistered()).not.toThrow();
		expect(() =>
			observations.schedule(async () => ({ completedIds: [], yielded: false })),
		).not.toThrow();
	});

	test.each(['rejecting', 'unpublished'] as const)(
		'cleanup restores timers and recorders after %s installation',
		async (kind): Promise<void> => {
			const originalDateNow = Date.now;
			vi.useFakeTimers();
			vi.spyOn(Date, 'now').mockReturnValue(-1);
			const failure = new Error('held installation rejected');
			const installation = kind === 'rejecting' ? Promise.reject(failure) : null;
			void installation?.catch((): void => {});
			let restored = false;
			let sourceClosed = false;
			let recorderClosed = false;
			const outcome = await cleanupReviewPreparationFixtures({
				sources: [
					{
						close: (): void => {
							sourceClosed = true;
						},
						pendingSourceInstallation: (): Promise<void> | null => installation,
					},
				],
				observations: [
					{
						close: (): void => {
							recorderClosed = true;
						},
					},
				],
				restore: (): void => {
					vi.restoreAllMocks();
					vi.useRealTimers();
					restored = true;
				},
			}).then(
				(): unknown => null,
				(error: unknown): unknown => error,
			);
			expect(sourceClosed).toBe(true);
			expect(recorderClosed).toBe(true);
			expect(restored).toBe(true);
			expect(vi.isFakeTimers()).toBe(false);
			expect(Date.now).toBe(originalDateNow);
			expect(outcome).toBe(kind === 'rejecting' ? failure : null);
		},
	);

	test('fails a retired preparation wait instead of returning at an attempt cap', async (): Promise<void> => {
		vi.useFakeTimers();
		const observations = makeReviewPreparationObservations();
		const outcome = driveReviewPreparationUntil({
			hasExpectedEvent: (): boolean => false,
			observations,
			startIndex: 0,
		}).then(
			(): string => 'unexpected completion',
			(error: unknown): string => String(error),
		);
		observations.close();
		await vi.runAllTimersAsync();
		expect(await outcome).toContain('Review preparation observation closed');
	});
});
