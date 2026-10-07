import { afterEach, describe, expect, test, vi } from 'vitest';

import validProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	bridgeProductFileMetadataApplicationProtocol,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import { bridgeProductMetadataFrameSchema } from './bridge-product-session-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	requestErrorResponse,
	subscriptionAccepted,
	subscriptionCancelled,
	subscriptionReset,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async () => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

class ControlledMetadataDeadlineClock implements BridgeProductDeadlineClock {
	readonly deadlines: Array<{ active: boolean; delayMilliseconds: number; fire: () => void }> = [];
	readonly #scheduleWaiters: Array<{ count: number; resolve: () => void }> = [];

	schedule(delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = {
			active: true,
			delayMilliseconds,
			fire: (): void => {
				if (!deadline.active) throw new Error('Expected an active metadata progress deadline.');
				deadline.active = false;
				onDeadline();
			},
		};
		this.deadlines.push(deadline);
		for (const waiter of this.#scheduleWaiters.filter(
			(candidate) => candidate.count <= this.deadlines.length,
		)) {
			waiter.resolve();
		}
		this.#scheduleWaiters.splice(
			0,
			this.#scheduleWaiters.length,
			...this.#scheduleWaiters.filter((candidate) => candidate.count > this.deadlines.length),
		);
		return (): void => {
			deadline.active = false;
		};
	}

	waitForScheduleCount(count: number): Promise<void> {
		if (this.deadlines.length >= count) return Promise.resolve();
		return new Promise((resolve): void => {
			this.#scheduleWaiters.push({ count, resolve });
		});
	}

	activeDeadline(): (typeof this.deadlines)[number] {
		const deadline = this.deadlines.find((candidate) => candidate.active);
		if (deadline === undefined) throw new Error('Expected an armed metadata progress deadline.');
		return deadline;
	}
}

describe('Bridge product transport', () => {
	test('reopen exhaustion for a retired E3 uses the existing recovery status and native policy', async () => {
		const statuses: string[] = [];
		const harness = createTransportHarness({
			deadlineClock: new ControlledMetadataDeadlineClock(),
			onViewRecoveryStatus: (status): void => {
				statuses.push(`${status.view.kind}:${status.status}`);
			},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		const stream = await harness.server.waitForMetadataStreamOpened();
		harness.server.emitMetadata(metadataAccepted(stream, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'file.metadata',
				request: stream,
				streamSequence: 1,
				subscriptionId: subscription.subscriptionId,
			}),
		);
		await harness.server.waitForControlRequest('subscription.setScope');
		await subscription.cancel();
		harness.transport.reportMetadataReopenExhausted('file.metadata');
		expect(statuses.at(-1)).toBe('file.metadata:failedRetryable');
		expect(harness.transport.metadataReopenPolicy.viewMaximumConsecutiveResnapshots).toBe(3);
		await harness.transport.retryView?.(subscription.subscriptionId);
		expect(statuses.at(-1)).toBe('file.metadata:recovering');
	});

	test('File render failure uses the real view Retry facade without declaring the session suspect', async () => {
		const statuses: string[] = [];
		const suspectReasons: string[] = [];
		const harness = createTransportHarness({
			deadlineClock: new ControlledMetadataDeadlineClock(),
			onSessionSuspect: (reason): void => {
				suspectReasons.push(reason);
			},
			onViewRecoveryStatus: (status): void => {
				statuses.push(`${status.view.kind}:${status.status}`);
			},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		try {
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			await harness.server.waitForControlRequest('subscription.setScope');
			await harness.transport.setViewScopeForSubscription?.({
				subscriptionId: subscription.subscriptionId,
				scope: { kind: 'file', changeFilter: { kind: 'none' }, interests: [], pathScope: [] },
			});
			if (harness.transport.failFileRender === undefined)
				throw new Error('Expected the File render failure facade.');
			harness.transport.failFileRender();
			expect(statuses.at(-1)).toBe('file.metadata:failedRetryable');
			await harness.transport.retryView?.(subscription.subscriptionId);
			expect(statuses.at(-1)).toBe('file.metadata:recovering');
			expect(
				harness.server.controlRequests.filter(
					(request) => request.kind === 'subscription.resnapshot',
				),
			).toHaveLength(1);
			expect(suspectReasons).toEqual([]);
		} finally {
			await subscription.cancel();
		}
	});
	test('a failed background cancel escape publishes the existing session-suspect fact', async () => {
		const suspectFact = createBridgeProductDeferred<string>();
		const suspectReasons: string[] = [];
		const harness = createTransportHarness({
			onSessionSuspect: (reason): void => {
				suspectReasons.push(reason);
				suspectFact.resolve(reason);
			},
		});
		let cancelAttempts = 0;
		harness.server.cancelHandler = (): Response => {
			cancelAttempts += 1;
			return new Response(null, { status: 502 });
		};
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const nextEvent = subscription.events[Symbol.asyncIterator]().next();
		const stream = await harness.server.waitForMetadataStreamOpened();
		harness.server.emitMetadata(metadataAccepted(stream, 0));
		await harness.server.waitForControlRequestWhere(
			(request) =>
				request.kind === 'subscription.open' &&
				request.subscriptionId === subscription.subscriptionId,
		);
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request: stream,
				streamSequence: 1,
				subscriptionId: subscription.subscriptionId,
			}),
		);

		await subscription.cancel();
		expect(await nextEvent).toEqual({ done: true, value: undefined });
		expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(0);
		expect(await suspectFact.promise).toBe('admissionReplyExhausted');
		expect(suspectReasons).toEqual(['admissionReplyExhausted']);
		expect(cancelAttempts).toBe(3);
	});

	test('silent metadata fetch has finite progress and cancellation settles without its reply', async () => {
		const clock = new ControlledMetadataDeadlineClock();
		const harness = createTransportHarness({ deadlineClock: clock });
		const fetchStarted = createBridgeProductDeferred<void>();
		const fetchAborted = createBridgeProductDeferred<void>();
		const silentFetch = createBridgeProductDeferred<Response>();
		const serverFetch = harness.server.fetch;
		vi.stubGlobal(
			'fetch',
			async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
				const url =
					input instanceof Request ? input.url : input instanceof URL ? input.href : input;
				if (url !== 'agentstudio://rpc/stream') return serverFetch(input, init);
				fetchStarted.resolve();
				init?.signal?.addEventListener(
					'abort',
					(): void => {
						fetchAborted.resolve();
						silentFetch.reject(new Error('Metadata fetch aborted.'));
					},
					{ once: true },
				);
				return silentFetch.promise;
			},
		);
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const nextEvent = subscription.events[Symbol.asyncIterator]().next();
		try {
			await fetchStarted.promise;
			await subscription.cancel();
			expect(await nextEvent).toEqual({ done: true, value: undefined });
			expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(0);
			await clock.waitForScheduleCount(1);
			expect(clock.activeDeadline().delayMilliseconds).toBe(5_000);
			clock.activeDeadline().fire();
			await fetchAborted.promise;
		} finally {
			silentFetch.reject(new Error('Silent metadata fetch test cleanup.'));
		}
	});

	test('an opened metadata response without acceptance expires and clears subscriptions', async () => {
		const clock = new ControlledMetadataDeadlineClock();
		const harness = createTransportHarness({ deadlineClock: clock });
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const nextEvent = subscription.events[Symbol.asyncIterator]().next();
		await harness.server.waitForMetadataStreamOpened();
		await clock.waitForScheduleCount(2);
		expect(clock.activeDeadline().delayMilliseconds).toBe(5_000);
		clock.activeDeadline().fire();
		await expect(nextEvent).rejects.toMatchObject({
			name: 'BridgeProductFiniteProgressDeadlineExpired',
		});
		expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(0);
		expect(harness.server.metadataReaderCancelCount).toBe(1);
	});

	test('W4 replacement snapshots exhaust W2 budget and a certified install rearms the same E3', async () => {
		const harness = createTransportHarness();
		let replacementCount = 0;
		let notifyBudgetReached: (() => void) | undefined;
		const budgetReached = new Promise<void>((resolve) => {
			notifyBudgetReached = resolve;
		});
		let notifyInstalled: (() => void) | undefined;
		const installed = new Promise<void>((resolve) => {
			notifyInstalled = resolve;
		});
		harness.transport.setBatchFrameSinks?.({
			install: (): void => {},
			receipt: (): void => {},
			replacementSnapshot: (): void => {
				replacementCount += 1;
				if (replacementCount === 3) notifyBudgetReached?.();
			},
			certifiedInstallCompleted: (): void => notifyInstalled?.(),
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		try {
			const stream = await harness.server.waitForMetadataStreamOpened();
			harness.server.emitMetadata(metadataAccepted(stream, 0));
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request: stream,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
			);
			const scopeRequest = await harness.server.waitForControlRequest('subscription.setScope');
			if (scopeRequest.kind !== 'subscription.setScope')
				throw new Error('Expected File view scope.');
			const frameIdentity = {
				domain: scopeRequest.domain,
				handle: scopeRequest.handle,
				incarnation: scopeRequest.incarnation,
				metadataStreamId: stream.metadataStreamId,
				paneSessionId: stream.paneSessionId,
				scopeRevision: scopeRequest.scopeRevision,
				subscriptionId: subscription.subscriptionId,
				subscriptionKind: 'file.metadata',
				wireVersion: stream.wireVersion,
				workerInstanceId: stream.workerInstanceId,
			} as const;
			for (let index = 0; index < 4; index += 1) {
				harness.server.emitMetadata(
					bridgeProductBatchFrameSchema.parse({
						...frameIdentity,
						baseRevision: 0,
						batchId: `transport-recovery-${index}`,
						kind: 'subscription.batchBegin',
						mode: 'snapshot',
						partCount: 0,
						scope: scopeRequest.scope,
						streamSequence: index + 2,
						targetRevision: 1,
					}),
				);
			}
			await budgetReached;
			await harness.transport.resnapshotView?.({
				domain: frameIdentity.domain,
				handle: frameIdentity.handle,
				incarnation: frameIdentity.incarnation,
				scopeRevision: frameIdentity.scopeRevision,
				subscriptionId: frameIdentity.subscriptionId,
				subscriptionKind: frameIdentity.subscriptionKind,
			});
			expect(
				harness.server.controlRequests.filter(
					(request) => request.kind === 'subscription.resnapshot',
				),
			).toHaveLength(0);
			harness.server.emitMetadata(
				bridgeProductBatchFrameSchema.parse({
					...frameIdentity,
					batchId: 'transport-recovery-3',
					coveredScope: scopeRequest.scope,
					kind: 'subscription.batchComplete',
					streamSequence: 6,
				}),
			);
			await installed;
			await harness.transport.resnapshotView?.({
				domain: frameIdentity.domain,
				handle: frameIdentity.handle,
				incarnation: frameIdentity.incarnation,
				scopeRevision: frameIdentity.scopeRevision,
				subscriptionId: frameIdentity.subscriptionId,
				subscriptionKind: frameIdentity.subscriptionKind,
			});
			const retry = await harness.server.waitForControlRequest('subscription.resnapshot');
			expect(retry).toMatchObject({
				handle: frameIdentity.handle,
				incarnation: frameIdentity.incarnation,
				subscriptionId: frameIdentity.subscriptionId,
			});
			expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(1);
		} finally {
			await subscription.cancel();
			harness.server.shutdown();
		}
	});
	test('opens the initial Comment scope with native worktree authority from openAccepted', async () => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewAnnotationMetadataApplicationProtocol,
			{},
		);
		try {
			await harness.server.waitForMetadataStream();
			harness.server.emitMetadata(metadataAccepted(harness.server.requiredMetadataRequest(), 0));
			await harness.server.waitForControlKind('subscription.open');
			await harness.server.waitForControlKind('subscription.setScope');

			expect(harness.server.requiredControlRequest('subscription.setScope', 0)).toMatchObject({
				scope: {
					kind: 'comment',
					sessionIds: [],
					worktreeId: '00000000-0000-4000-8000-000000000002',
				},
				subscriptionId: subscription.subscriptionId,
				subscriptionKind: 'review.annotations',
			});
		} finally {
			harness.server.shutdown();
		}
	});

	test('batch begin and complete advance without legacy frame observation acknowledgements', async () => {
		const harness = createTransportHarness();
		const installed = createBridgeProductDeferred<void>();
		harness.transport.setBatchFrameSinks?.({
			install: (): void => {
				installed.resolve();
			},
			receipt: (): void => {},
			resnapshot: (): void => {},
			resnapshotLatest: (): void => {},
		});
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request,
				streamSequence: 1,
				subscriptionId: subscription.subscriptionId,
			}),
		);
		const batchBegin = validProductSessionCorpus.transportV2.batchFrames.find(
			(frame) => frame.kind === 'subscription.batchBegin',
		);
		const batchComplete = validProductSessionCorpus.transportV2.batchFrames.find(
			(frame) => frame.kind === 'subscription.batchComplete',
		);
		if (batchBegin === undefined || batchComplete === undefined)
			throw new Error('Review batch fixtures are missing.');
		const batchIdentity = {
			batchId: batchBegin.batchId,
			domain: batchBegin.domain,
			handle: batchBegin.handle,
			incarnation: batchBegin.incarnation,
			metadataStreamId: request.metadataStreamId,
			paneSessionId: request.paneSessionId,
			scopeRevision: batchBegin.scopeRevision,
			subscriptionId: subscription.subscriptionId,
			subscriptionKind: 'review.metadata',
			wireVersion: request.wireVersion,
			workerInstanceId: request.workerInstanceId,
		} as const;
		harness.server.emitMetadata(
			bridgeProductMetadataFrameSchema.parse({
				...batchBegin,
				...batchIdentity,
				partCount: 0,
				streamSequence: 2,
			}),
		);
		harness.server.emitMetadata(
			bridgeProductMetadataFrameSchema.parse({
				...batchComplete,
				...batchIdentity,
				streamSequence: 3,
			}),
		);
		await installed.promise;
		expect(harness.transport.metadataStreamDiagnostics?.().lastRoutedFrameKind).toBe(
			'subscription.batchComplete',
		);
		expect(harness.server.frameAcknowledgements).toHaveLength(0);
	});

	test('records an unknown subscription acceptance as a route failure before read three', async () => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const nextEvent = subscription.events[Symbol.asyncIterator]().next();
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request,
				streamSequence: 1,
				subscriptionId: 'unknown-subscription',
			}),
		);

		await expect(nextEvent).rejects.toThrow(/unknown subscription/iu);
		expect(harness.server.metadataReaderCancelCount).toBe(1);
		expect(harness.server.frameAcknowledgements).toEqual([]);
		expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
			activeSubscriptionCount: 0,
			committedFrameCount: 2,
			failureStage: 'route',
			lastCommittedFrameKind: 'subscription.accepted',
			lastRoutedFrameKind: 'metadataStream.accepted',
			lifecycleState: 'failed',
			readFulfilledCount: 2,
			readPending: false,
			readRequestCount: 2,
			routeFailureCode: 'unknown_subscription',
			routedFrameCount: 1,
		});
	});

	test('exposes payload-free metadata stream diagnostics after a poisoned packaged frame', async () => {
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(bridgeProductFileMetadataApplicationProtocol, {
			source: fileSourceConfiguration(),
		});
		const nextEvent = subscription.events[Symbol.asyncIterator]().next();
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			bridgeProductMetadataFrameSchema.parse({
				...subscriptionAccepted({
					epoch: 0,
					kind: 'file.metadata',
					request,
					streamSequence: 1,
					subscriptionId: subscription.subscriptionId,
				}),
				metadataStreamId: 'metadata-stream-mismatch',
			}),
		);

		await expect(nextEvent).rejects.toThrow();
		expect(harness.server.metadataReaderCancelCount).toBe(1);
		expect(harness.transport.metadataStreamDiagnostics?.()).toEqual({
			activeSubscriptionCount: 0,
			committedFrameCount: 1,
			decoderState: 'poisoned',
			expectedNextStreamSequence: 1,
			failureStage: 'decode',
			failureCode: 'stream_identity_mismatch',
			identityMismatchField: 'metadataStreamId',
			lastSubscriptionTermination: null,
			routeFailureSubscriptionId: null,
			lastChunkByteCount: expect.any(Number),
			lastCommittedFrameKind: 'metadataStream.accepted',
			lastRoutedFrameKind: 'metadataStream.accepted',
			lifecycleState: 'failed',
			peakRetainedByteCount: expect.any(Number),
			pushCount: 2,
			readFulfilledCount: 2,
			readPending: false,
			readRequestCount: 2,
			receivedByteCount: expect.any(Number),
			retainedByteCount: 0,
			routeFailureCode: null,
			routedFrameCount: 1,
			streamOpenCount: 1,
		});
	});

	test('opens a fresh metadata stream after a physical stream failure', async () => {
		const harness = createTransportHarness();
		const firstSubscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		const firstEvent = firstSubscription.events[Symbol.asyncIterator]().next();
		await harness.server.waitForMetadataStream();
		const firstRequest = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(firstRequest, 0));
		harness.server.emitMetadata(
			bridgeProductMetadataFrameSchema.parse({
				...metadataAccepted(firstRequest, 1),
				metadataStreamId: 'metadata-stream-mismatch',
			}),
		);

		await expect(firstEvent).rejects.toThrow();

		const secondSubscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		await harness.server.waitForMetadataStream(2);
		const secondRequest = harness.server.requiredMetadataRequest();
		expect(secondRequest.metadataStreamId).not.toBe(firstRequest.metadataStreamId);
		harness.server.emitMetadata(metadataAccepted(secondRequest, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request: secondRequest,
				streamSequence: 1,
				subscriptionId: secondSubscription.subscriptionId,
			}),
		);
		await harness.server.waitForControlRequestWhere(
			(request) =>
				request.kind === 'subscription.open' &&
				request.subscriptionId === secondSubscription.subscriptionId,
		);
		const secondCancel = secondSubscription.cancel();
		await harness.server.waitForControlKind('subscription.cancel');
		harness.server.emitMetadata(
			subscriptionCancelled({
				epoch: 0,
				request: secondRequest,
				streamSequence: 2,
				subscriptionId: secondSubscription.subscriptionId,
			}),
		);
		await secondCancel;
	});

	test('settles cancel on native acknowledgement and drains the correlated terminal frame', async () => {
		// Arrange
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request,
				streamSequence: 1,
				subscriptionId: subscription.subscriptionId,
			}),
		);
		await harness.server.waitForControlKind('subscription.open');

		// Act: native acknowledges the cancel but has not yet delivered its terminal.
		await subscription.cancel();

		// Assert: the consumer is done without waiting on a frame, and the terminal that
		// follows drains cleanly instead of naming an unknown subscription.
		expect(await subscription.events[Symbol.asyncIterator]().next()).toEqual({
			done: true,
			value: undefined,
		});
		harness.server.emitMetadata(
			subscriptionCancelled({
				epoch: 0,
				request,
				streamSequence: 2,
				subscriptionId: subscription.subscriptionId,
			}),
		);
		await subscription.events[Symbol.asyncIterator]().next();
		expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
			activeSubscriptionCount: 0,
			failureStage: null,
			routeFailureCode: null,
		});
	});

	test('releases an older-epoch sibling before any request at the advanced epoch reaches native', async () => {
		// Arrange: a Review annotation subscription is admitted at epoch 1 and its open
		// is still in flight, so its release must queue behind that open.
		const harness = createTransportHarness({ reviewEpoch: 1 });
		const sibling = harness.transport.subscribe(
			bridgeProductReviewAnnotationMetadataApplicationProtocol,
			{},
		);
		const siblingTerminal = sibling.events[Symbol.asyncIterator]().next();
		void siblingTerminal.catch((): void => {});
		await harness.server.waitForMetadataStream();
		harness.server.holdNextSubscriptionOpen();
		harness.server.emitMetadata(metadataAccepted(harness.server.requiredMetadataRequest(), 0));
		await harness.server.waitForControlKind('subscription.open');

		// Act: Review advances and immediately subscribes its replacement metadata.
		const nextEpoch = harness.transport.advanceWorkerDerivationEpoch('review');
		harness.transport.subscribe(bridgeProductReviewMetadataApplicationProtocol, {});
		harness.server.releaseHeldSubscriptionOpen();
		await harness.server.waitForControlKind('subscription.open', 2);
		await harness.server.waitForControlKind('subscription.setScope');

		// Assert: native sees the epoch-1 cancel before the first epoch-2 request, and the
		// sibling's consumer learns it was retired for the new epoch.
		expect(
			harness.server.controlRequests.map((request) =>
				request.kind === 'subscription.open'
					? `open:${request.subscription.subscriptionKind}:${request.workerDerivationEpoch}`
					: request.kind === 'subscription.cancel'
						? `cancel:${request.subscriptionKind}:${request.workerDerivationEpoch}`
						: request.kind,
			),
		).toEqual([
			'open:review.annotations:1',
			'cancel:review.annotations:1',
			'open:review.metadata:2',
			'subscription.setScope',
		]);
		await expect(siblingTerminal).rejects.toMatchObject({
			name: 'BridgeProductSubscriptionEpochRetiredError',
			nextWorkerDerivationEpoch: nextEpoch,
		});
	});

	test('keeps routing a retired sibling whose cancel native refused until its in-flight terminal lands', async () => {
		// Arrange: native already reset the Review annotation subscription and dropped
		// its record, so it refuses the retirement cancel while the reset frame is still
		// queued on the shared metadata stream.
		const harness = createTransportHarness();
		const sibling = harness.transport.subscribe(
			bridgeProductReviewAnnotationMetadataApplicationProtocol,
			{},
		);
		const siblingTerminal = sibling.events[Symbol.asyncIterator]().next();
		void siblingTerminal.catch((): void => {});
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.annotations',
				request,
				streamSequence: 1,
				subscriptionId: sibling.subscriptionId,
			}),
		);
		await harness.server.waitForControlKind('subscription.open');
		harness.server.cancelHandler = (cancel): Response => requestErrorResponse(cancel, 'internal');

		// Act: Review advances and subscribes its metadata; native then delivers the
		// sibling's queued reset ahead of the new subscription's frames.
		const nextEpoch = harness.transport.advanceWorkerDerivationEpoch('review');
		const metadata = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		await harness.server.waitForControlKind('subscription.open', 2);
		harness.server.emitMetadata(
			subscriptionReset({
				epoch: 0,
				kind: 'review.annotations',
				reason: 'stale_source',
				request,
				streamSequence: 2,
				subscriptionId: sibling.subscriptionId,
				subscriptionSequence: 1,
			}),
		);
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: nextEpoch,
				kind: 'review.metadata',
				request,
				streamSequence: 3,
				subscriptionId: metadata.subscriptionId,
			}),
		);
		await harness.server.waitForControlRequestWhere(
			(control): boolean =>
				control.kind === 'subscription.setScope' &&
				control.subscriptionId === metadata.subscriptionId,
		);
		// Assert: the refused sibling's terminal drains instead of poisoning the shared
		// stream, and the replacement subscription remains active.
		expect(harness.transport.metadataStreamDiagnostics?.().activeSubscriptionCount).toBe(1);
		expect(harness.transport.metadataStreamDiagnostics?.().routeFailureCode).toBeNull();
		await expect(siblingTerminal).rejects.toMatchObject({
			name: 'BridgeProductSubscriptionEpochRetiredError',
			nextWorkerDerivationEpoch: nextEpoch,
		});
		await metadata.cancel();
	});

	test('does not hold an advance behind a consumer cancel whose terminal frame is still in flight', async () => {
		// Arrange: the consumer cancelled and native acknowledged, but native has not
		// yet delivered the cancelled frame.
		const harness = createTransportHarness();
		const subscription = harness.transport.subscribe(
			bridgeProductReviewMetadataApplicationProtocol,
			{},
		);
		await harness.server.waitForMetadataStream();
		const request = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(request, 0));
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 0,
				kind: 'review.metadata',
				request,
				streamSequence: 1,
				subscriptionId: subscription.subscriptionId,
			}),
		);
		await harness.server.waitForControlKind('subscription.open');
		await harness.server.waitForControlKind('subscription.setScope');
		await subscription.cancel();

		// Act
		const nextEpoch = harness.transport.advanceWorkerDerivationEpoch('review');
		await harness.transport.call('review.markFileViewed', { itemId: 'item-1' });

		// Assert: one cancel for the subscription, and the call went out at the new epoch.
		expect(
			harness.server.controlRequests.map((control) =>
				control.kind === 'product.call' ? `call:${control.workerDerivationEpoch}` : control.kind,
			),
		).toEqual([
			'subscription.open',
			'subscription.setScope',
			'subscription.cancel',
			`call:${nextEpoch}`,
		]);
	});

	test('owns independent File and Review derivation epochs', () => {
		const harness = createTransportHarness({ fileEpoch: 4, reviewEpoch: 9 });

		expect(harness.transport.advanceWorkerDerivationEpoch('file')).toBe(5);
		expect(harness.transport.workerDerivationEpoch('review')).toBe(9);
		expect(harness.transport.advanceWorkerDerivationEpoch('review')).toBe(10);
		expect(harness.transport.workerDerivationEpoch('file')).toBe(5);
	});

	test('round-trips current File source discovery with the captured File epoch', async () => {
		const harness = createTransportHarness({ fileEpoch: 7, reviewEpoch: 2 });

		const result = await harness.transport.call('file.source.current', {});

		expect(result).toEqual({ source: fileSourceConfiguration(), status: 'available' });
		expect(harness.server.requiredControlRequest('product.call', 0)).toMatchObject({
			call: { method: 'file.source.current', request: {} },
			workerDerivationEpoch: 7,
		});
	});
});
