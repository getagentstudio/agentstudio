import { describe, expect, test } from 'vitest';

import { makeContentRequestDescriptor } from './bridge-comm-worker-runtime-protocol.test-support.js';
import type { BridgeProductContentRequestFor } from './bridge-product-content-contracts.js';
import { BridgeProductContentResponseAdmission } from './bridge-product-content-response-admission.js';
import { readBridgeProductContentResponse } from './bridge-product-content-response-reader.js';
import { openBridgeProductContentStream } from './bridge-product-content-stream-opening.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import { productSessionBootstrap } from './bridge-product-session-authority.test-support.js';
import { fetchBridgeWorkerReviewContentResource } from './bridge-worker-review-content-fetch.js';

describe('Bridge Review producer capacity response', () => {
	test.each([
		{
			label: 'marked capacity',
			status: 503,
			marker: 'producer_capacity',
			retryable: true,
			cancelled: false,
		},
		{
			label: 'conflict',
			status: 409,
			marker: 'producer_capacity',
			retryable: false,
			cancelled: false,
		},
		{
			label: 'server error',
			status: 500,
			marker: 'producer_capacity',
			retryable: false,
			cancelled: false,
		},
		{
			label: 'unmarked unavailable',
			status: 503,
			marker: null,
			retryable: false,
			cancelled: false,
		},
		{
			label: 'unrecognized unavailable',
			status: 503,
			marker: 'other',
			retryable: false,
			cancelled: false,
		},
		{
			label: 'cancelled capacity',
			status: 503,
			marker: 'producer_capacity',
			retryable: false,
			cancelled: true,
		},
	])(
		'$label preserves its retry disposition through the real reader and fetcher',
		async (scenario) => {
			// Arrange: replace only the HTTP executor; keep response reading and classification real.
			const descriptor = makeContentRequestDescriptor({ role: 'head', text: 'capacity fixture' });
			const bootstrap = productSessionBootstrap();
			const authority = {
				bootstrap,
				capabilityHeader: 'private-capability',
				open: Promise.resolve(),
			};
			const pendingDeadlines = new Set<() => void>();
			const clock: BridgeProductDeadlineClock = {
				schedule: (_delayMilliseconds, onDeadline): (() => void) => {
					pendingDeadlines.add(onDeadline);
					return (): void => {
						pendingDeadlines.delete(onDeadline);
					};
				},
			};
			const headers = new Headers();
			if (scenario.marker !== null)
				headers.set('X-AgentStudio-Bridge-Content-Rejection', scenario.marker);
			const response = new Response(null, { status: scenario.status, headers });
			let responseCompleted: Promise<void> = Promise.resolve();
			let acknowledgementCount = 0;
			const abortController = new AbortController();
			const readerFailures: unknown[] = [];

			// Act: the reader settles both its frame iterator and terminal on every HTTP outcome.
			const result = await fetchBridgeWorkerReviewContentResource({
				descriptor,
				signal: abortController.signal,
				openContent: (openedDescriptor, abortSignal) => {
					const request: BridgeProductContentRequestFor<'review.content'> = {
						kind: 'content.open',
						wireVersion: 2,
						paneSessionId: bootstrap.paneSessionId,
						workerInstanceId: bootstrap.workerInstanceId,
						workerDerivationEpoch: 1,
						contentRequestId: 'capacity-content-request',
						leaseId: 'capacity-lease',
						operationCorrelationId: null,
						contentKind: 'review.content',
						descriptor: openedDescriptor,
					};
					return openBridgeProductContentStream({
						abortSignal,
						request,
						readResponse: (opening): Promise<void> => {
							responseCompleted = (async (): Promise<void> => {
								const terminalSettled = opening.terminal.promise.then(
									() => true,
									() => true,
								);
								// These HTTP refusals must emit no frames. Observe completion before fallback cleanup.
								const framesSettled = opening.frames.next().then(
									(frame) => {
										if (!frame.done)
											readerFailures.push(new Error('HTTP refusal emitted a content frame.'));
										return frame.done === true;
									},
									() => true,
								);
								try {
									await readBridgeProductContentResponse({
										opening: {
											...opening,
											terminal: {
												...opening.terminal,
												reject: (error: unknown): void => {
													// The real reader has already classified capacity; race cancellation at its sink.
													if (scenario.cancelled) abortController.abort('selected demand retired');
													opening.terminal.reject(error);
												},
											},
										},
										authority,
										clock,
										responseAdmission: new BridgeProductContentResponseAdmission(),
										executeProductRequest: async (): Promise<Response> => response,
										acknowledgeReceivedThrough: async (): Promise<void> => {
											acknowledgementCount += 1;
										},
									});
									// Observe terminal settlement against its producing reader ending, without a turn budget.
									if (!(await Promise.race([terminalSettled, Promise.resolve(false)]))) {
										readerFailures.push(
											new Error('Content reader ended before settling its terminal.'),
										);
									}
									if (!(await Promise.race([framesSettled, Promise.resolve(false)]))) {
										readerFailures.push(
											new Error('Content reader ended before settling its frames.'),
										);
									}
								} catch (error) {
									readerFailures.push(error);
								} finally {
									// An ended reader must not leave fetch waiting on either owner, even on a regression.
									const ended = new Error('Content reader ended without settling its stream.');
									opening.frames.fail(ended, true);
									opening.terminal.reject(ended);
									await framesSettled;
								}
							})();
							return responseCompleted;
						},
					});
				},
			});
			await responseCompleted;

			// Assert: only the reviewed status + marker pair defers a native producer admission.
			if (scenario.cancelled) {
				expect(result).toMatchObject({
					disposition: 'discarded',
					localFailure: { code: 'aborted', kind: 'abort' },
				});
			} else if (scenario.retryable) {
				expect(result).toMatchObject({
					contentRequestId: 'capacity-content-request',
					disposition: 'retryWait',
					terminal: {
						contentKind: 'review.content',
						descriptorId: descriptor.descriptorId,
						kind: 'error',
						code: 'internal',
						retryable: true,
					},
				});
			} else {
				expect(result).toMatchObject({
					disposition: 'terminal',
					localFailure: { code: 'internal_failure', kind: 'internal' },
				});
			}
			expect(acknowledgementCount).toBe(0);
			expect(pendingDeadlines.size).toBe(0);
			expect(readerFailures).toEqual([]);
		},
	);
});
