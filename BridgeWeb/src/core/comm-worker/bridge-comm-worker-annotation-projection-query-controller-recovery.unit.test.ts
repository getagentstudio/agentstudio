import { describe, expect, test } from 'vitest';

import { BridgeProductControlRequestError } from './bridge-product-session-authority.js';
import {
	createHarness,
	deferred,
	flushTaskQueueUntil,
	makeProjectionPages,
	installSessionCatalog,
	uuidv7,
} from './test-fixtures/bridge-comm-worker-annotation-projection.test-support.js';

const reviewPublicationIdentity = {
	packageId: 'package-annotations-1',
	publicationId: uuidv7(41),
	reviewGeneration: 7,
	revision: 3,
	sourceIdentity: 'source-annotations-1',
} as const;

describe('Bridge annotation projection query recovery', () => {
	test('settles two retryable failures once and accepts a fresh metadata invalidation', async () => {
		const pages = await makeProjectionPages(1, 1);
		let queryCount = 0;
		const harness = await createHarness({
			pages,
			queryOverride: (): Promise<unknown> => {
				queryCount += 1;
				return queryCount <= 2
					? Promise.reject(retryableProjectionFailure(queryCount))
					: Promise.resolve({ descriptor: pages[0]?.descriptor, kind: 'content' });
			},
		});
		try {
			harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 1 });
			harness.controller.ensureSubscription();
			installSessionCatalog(harness.notifications, 1);
			await harness.controller.waitForIdle();

			expect(harness.querySourceGenerations).toEqual([1, 1]);
			expect(harness.statuses).toEqual(['refreshing', 'refreshing', 'unavailable']);
			expect(harness.failures).toHaveLength(1);

			harness.notifications.installCatalog(1);
			await harness.controller.waitForIdle();

			expect(harness.querySourceGenerations).toEqual([1, 1, 1]);
			expect(harness.failures).toHaveLength(1);
			expect(harness.publications).toHaveLength(1);
			expect(harness.publications[0]?.snapshot.sourceGeneration).toBe(1);
			expect(harness.statuses.at(-1)).toBe('ready');
			expect(harness.subscriptionCount()).toBe(1);
		} finally {
			await harness.controller.dispose();
		}
	});

	test.each(['file', 'review'] as const)(
		'does not publish unavailable from a %s attempt superseded by deactivate and newer demand',
		async (surface) => {
			const firstAttempt = deferred<unknown>();
			const pages = await makeProjectionPages(1, 2, undefined, surface);
			let queryCount = 0;
			const harness = await createHarness({
				pages,
				surface,
				queryOverride: (_request, signal): Promise<unknown> => {
					queryCount += 1;
					return queryCount === 1
						? new Promise<unknown>((resolve, reject): void => {
								const abort = (): void =>
									reject(signal.reason ?? new Error('Projection cancelled.'));
								signal.addEventListener('abort', abort, { once: true });
								void firstAttempt.promise.then(resolve, reject);
							})
						: Promise.resolve({ descriptor: pages[0]?.descriptor, kind: 'content' });
				},
			});
			try {
				harness.controller.setDemand({
					active: true,
					...(surface === 'review' ? { reviewPublicationIdentity } : {}),
					sessionIds: [],
					sourceGeneration: 1,
				});
				harness.controller.ensureSubscription();
				installSessionCatalog(harness.notifications, 1);
				await flushTaskQueueUntil(() => harness.querySourceGenerations.length === 1);

				harness.controller.setDemand({
					active: false,
					...(surface === 'review' ? { reviewPublicationIdentity } : {}),
					sessionIds: [],
					sourceGeneration: 1,
				});
				harness.controller.setDemand({
					active: true,
					...(surface === 'review' ? { reviewPublicationIdentity } : {}),
					sessionIds: [],
					sourceGeneration: 2,
				});
				harness.notifications.installCatalog(2);
				await harness.controller.waitForIdle();
				const firstCorrelation = harness.telemetrySamples.find(
					(sample) =>
						sample.stringAttributes['agentstudio.bridge.phase'] === 'content_transfer_started',
				)?.stringAttributes['agentstudio.bridge.operation.id'];
				expect(firstCorrelation).toBeDefined();
				const cancelledTerminals = harness.telemetrySamples.filter(
					(sample) =>
						sample.stringAttributes['agentstudio.bridge.operation.id'] === firstCorrelation &&
						sample.stringAttributes['agentstudio.bridge.result'] === 'cancelled' &&
						[
							'content_transfer_terminal',
							'projection_query_terminal',
							'projection_convergence_terminal',
							'worker_application_terminal',
						].includes(sample.stringAttributes['agentstudio.bridge.phase'] ?? ''),
				);
				expect(cancelledTerminals).toHaveLength(4);
				firstAttempt.resolve(Promise.reject(retryableProjectionFailure(1)));

				expect(harness.failures).toEqual([]);
				expect(harness.publications).toHaveLength(1);
				expect(harness.publications[0]?.snapshot.sourceGeneration).toBe(2);
				expect(harness.statuses.at(-1)).toBe('ready');
			} finally {
				await harness.controller.dispose();
			}
		},
	);

	test('converges on new source-generation demand after retry exhaustion without manual retry', async () => {
		const pages = await makeProjectionPages(1, 2);
		let queryCount = 0;
		const harness = await createHarness({
			pages,
			queryOverride: (): Promise<unknown> => {
				queryCount += 1;
				return queryCount <= 2
					? Promise.reject(retryableProjectionFailure(queryCount))
					: Promise.resolve({ descriptor: pages[0]?.descriptor, kind: 'content' });
			},
		});
		try {
			harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 1 });
			harness.controller.ensureSubscription();
			installSessionCatalog(harness.notifications, 1);
			await harness.controller.waitForIdle();
			expect(harness.failures).toHaveLength(1);

			harness.controller.setDemand({ active: true, sessionIds: [], sourceGeneration: 2 });
			await harness.controller.waitForIdle();

			expect(harness.querySourceGenerations).toEqual([1, 1, 2]);
			expect(harness.failures).toHaveLength(1);
			expect(harness.publications).toHaveLength(1);
			expect(harness.publications[0]?.snapshot.sourceGeneration).toBe(2);
			expect(harness.statuses.at(-1)).toBe('ready');
			expect(harness.subscriptionCount()).toBe(1);
		} finally {
			await harness.controller.dispose();
		}
	});
});

function retryableProjectionFailure(attempt: number): BridgeProductControlRequestError {
	return new BridgeProductControlRequestError({
		code: 'internal',
		message: `Projection query attempt ${attempt} failed.`,
		retryAfterMilliseconds: null,
		retryable: true,
	});
}
