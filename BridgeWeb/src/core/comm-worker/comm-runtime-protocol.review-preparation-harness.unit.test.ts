import { afterEach, describe, expect, test, vi } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	createReviewPreparationObservations as makeReviewPreparationObservations,
	cleanupReviewPreparationFixtures,
	driveReviewPreparationUntil,
	requirePreparationContinuationBeforeDrainCompletion,
} from './comm-runtime-protocol.review-preparation.test-support.js';

afterEach((): void => {
	vi.restoreAllMocks();
	vi.useRealTimers();
});

describe('Review preparation harness guards', () => {
	test('retires the continuation wait when the first drain fails', async (): Promise<void> => {
		const observations = makeReviewPreparationObservations();
		const failure = new Error('first drain failed');
		await expect(
			requirePreparationContinuationBeforeDrainCompletion({
				firstDrainCompletion: Promise.reject(failure),
				isContinuationScheduled: (fact): boolean =>
					fact.kind === 'drainScheduled' && fact.index === 1,
				observations,
			}),
		).rejects.toBe(failure);
		expect(() => observations.facts.record({ kind: 'retryDeadlineRegistered' })).not.toThrow();
		await expect(
			observations.facts.waitFor((): boolean => false, 'retired continuation history'),
		).rejects.toThrow(
			/Awaiting retired continuation history: first drain failed; last recorded facts=.*retryDeadlineRegistered/,
		);
		expect(() =>
			observations.schedule(async () => ({ completedIds: [], yielded: false })),
		).not.toThrow();
	});

	test('rejects when the actual drain completion precedes continuation scheduling', async (): Promise<void> => {
		const observations = makeReviewPreparationObservations();
		const firstDrainCompletion = (async (): Promise<void> => {})();
		await expect(
			requirePreparationContinuationBeforeDrainCompletion({
				firstDrainCompletion,
				isContinuationScheduled: (fact): boolean =>
					fact.kind === 'drainScheduled' && fact.index === 1,
				observations,
			}),
		).rejects.toThrow('completed before its continuation was scheduled');
	});

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

	test('joins a pending installation after source retirement', async (): Promise<void> => {
		const installation = createBridgeProductDeferred<void>();
		let sourceClosed = false;
		const cleanup = cleanupReviewPreparationFixtures({
			sources: [
				{
					close: (): void => {
						sourceClosed = true;
						installation.resolve();
					},
					pendingSourceInstallation: (): Promise<void> => installation.promise,
				},
			],
			observations: [],
			restore: (): void => {},
		});
		await Promise.resolve();
		expect(sourceClosed).toBe(true);
		await cleanup;
	});

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
