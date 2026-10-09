import { describe, expect, test } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import type { BridgeProductMetadataApplicationOpen } from './bridge-product-metadata-application-protocol.js';
import {
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
	bridgeProductReviewMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import {
	BridgeProductControlRequestError,
	type BridgeProductSubscriptionOpenAccepted,
} from './bridge-product-session-authority.js';
import {
	bridgeProductMetadataFrameSchema,
	type BridgeProductMetadataFrame,
} from './bridge-product-session-contracts.js';
import {
	BridgeProductSubscriptionEpochRetiredError,
	BridgeProductSubscriptionState,
	BridgeProductSubscriptionResetError,
	type BridgeProductSubscriptionFrame,
	type BridgeProductSubscriptionStateControlMux,
} from './bridge-product-subscription-state.js';
import { BridgeProductSurfaceEpochAuthority } from './bridge-product-surface-epoch-authority.js';

type ReviewAnnotationOpen = BridgeProductMetadataApplicationOpen<
	typeof bridgeProductReviewAnnotationMetadataApplicationProtocol
>;

describe('Bridge product subscription state', () => {
	test('cancel settles before a held metadata stream opens and leaves no local subscription', async () => {
		const metadataReady = createBridgeProductDeferred<void>();
		let openCount = 0;
		const terminalSubscriptions: string[] = [];
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				cancelSubscription: async (): Promise<void> => {},
				openSubscription: async (props): Promise<BridgeProductSubscriptionOpenAccepted> => {
					openCount += 1;
					return {
						kind: 'subscription.openAccepted',
						paneSessionId: 'pane-session-review',
						requestId: 'held-metadata-open',
						requestSequence: 1,
						subscriptionId: props.subscriptionId,
						subscriptionKind: 'review.metadata',
						wireVersion: 2,
						workerInstanceId: 'worker-instance-review',
					};
				},
			},
			ensureMetadataStream: (): Promise<void> => metadataReady.promise,
			initialOptions: {},
			onTerminal: (subscriptionId): void => {
				terminalSubscriptions.push(subscriptionId);
			},
			protocol: bridgeProductReviewMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 0,
			subscriptionId: 'held-metadata-subscription',
		});
		void state.start();
		const nextEvent = state.publicSubscription.events[Symbol.asyncIterator]().next();
		try {
			await state.cancel();
			expect(await nextEvent).toEqual({ done: true, value: undefined });
			expect(openCount).toBe(0);
			metadataReady.resolve();
			expect(terminalSubscriptions).toEqual(['held-metadata-subscription']);
		} finally {
			metadataReady.resolve();
			state.fail(new Error('Held metadata test cleanup.'));
		}
	});

	test('cancel sends its escape while an admitted open result is unanswered', async () => {
		const openRequested = createBridgeProductDeferred<void>();
		const openReply = createBridgeProductDeferred<BridgeProductSubscriptionOpenAccepted>();
		let nativeCancelCount = 0;
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				cancelSubscription: async (): Promise<void> => {
					nativeCancelCount += 1;
				},
				openSubscription: (): Promise<BridgeProductSubscriptionOpenAccepted> => {
					openRequested.resolve();
					return openReply.promise;
				},
			},
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 0,
			subscriptionId: 'held-open-result-subscription',
		});
		void state.start();
		const nextEvent = state.publicSubscription.events[Symbol.asyncIterator]().next();
		await openRequested.promise;
		try {
			await state.cancel();
			expect(nativeCancelCount).toBe(1);
			expect(await nextEvent).toEqual({ done: true, value: undefined });
		} finally {
			openReply.resolve({
				kind: 'subscription.openAccepted',
				paneSessionId: 'pane-session-review',
				requestId: 'held-open-result',
				requestSequence: 1,
				subscriptionId: 'held-open-result-subscription',
				subscriptionKind: 'review.metadata',
				wireVersion: 2,
				workerInstanceId: 'worker-instance-review',
			});
			state.fail(new Error('Held open result test cleanup.'));
		}
	});

	test('a subscription that fails while its open result is held never opens its view', async (): Promise<void> => {
		const openRequested = createBridgeProductDeferred<void>();
		const openReply = createBridgeProductDeferred<BridgeProductSubscriptionOpenAccepted>();
		const openedSubscriptionIds: string[] = [];
		const subscriptionId = 'failed-during-open-subscription';
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				cancelSubscription: async (): Promise<void> => {},
				openSubscription: (): Promise<BridgeProductSubscriptionOpenAccepted> => {
					openRequested.resolve();
					return openReply.promise;
				},
			},
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onOpened: async (openedSubscriptionId): Promise<void> => {
				openedSubscriptionIds.push(openedSubscriptionId);
			},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 0,
			subscriptionId,
		});
		const initialization = state.start();
		await openRequested.promise;
		state.fail(new Error('Metadata session poisoned.'));
		openReply.resolve({
			kind: 'subscription.openAccepted',
			paneSessionId: 'pane-session-review',
			requestId: 'held-open-result',
			requestSequence: 1,
			subscriptionId,
			subscriptionKind: 'review.metadata',
			wireVersion: 2,
			workerInstanceId: 'worker-instance-review',
		});
		await initialization;
		expect(openedSubscriptionIds).toEqual([]);
	});

	test('cancellation releases a subscription while its initial view scope reply is held', async () => {
		const scopeStarted = createBridgeProductDeferred<void>();
		const scopeAborted = createBridgeProductDeferred<void>();
		let cancelled = 0;
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				cancelSubscription: async (): Promise<void> => {
					cancelled += 1;
				},
				openSubscription: async (props): Promise<BridgeProductSubscriptionOpenAccepted> => ({
					kind: 'subscription.openAccepted',
					paneSessionId: 'pane-session-review',
					requestId: 'request-open-review',
					requestSequence: 1,
					subscriptionId: props.subscriptionId,
					subscriptionKind: 'review.metadata',
					wireVersion: 2,
					workerInstanceId: 'worker-instance-review',
				}),
			},
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onOpened: async (_subscriptionId, signal): Promise<void> => {
				scopeStarted.resolve();
				await new Promise<void>((_resolve, reject): void => {
					signal.addEventListener(
						'abort',
						(): void => {
							scopeAborted.resolve();
							reject(signal.reason);
						},
						{ once: true },
					);
				});
			},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 0,
			subscriptionId: 'held-scope-subscription',
		});
		void state.start();
		await scopeStarted.promise;

		const cancellation = state.cancel();
		await scopeAborted.promise;
		await expect(cancellation).resolves.toBeUndefined();
		expect(cancelled).toBe(1);
	});

	test('reconciles an older subscription against the current surface epoch without retagging its admission', async () => {
		// Arrange: an annotation subscription opens before its surface metadata
		// advances the shared epoch, as in the real four-subscription startup.
		const harness = createAnnotationControlHarness();
		let surfaceEpoch = 0;
		const state = new BridgeProductSubscriptionState({
			controlMux: harness.controlMux,
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => surfaceEpoch,
			subscriptionId: 'older-annotation-subscription',
		});
		void state.start();
		const admittedOpen = await harness.capturedOpen;

		try {
			// Act: reconciliation asks native whether this ID can serve the current
			// epoch. Native, not the worker, decides whether a fresh ID is required.
			surfaceEpoch = 1;
			const claim = state.reconciliationClaim();

			// Assert
			expect(admittedOpen.workerDerivationEpoch).toBe(0);
			expect(claim).toMatchObject({
				subscriptionId: 'older-annotation-subscription',
				workerDerivationEpoch: 1,
			});
			const terminal = state.publicSubscription.events[Symbol.asyncIterator]().next();
			void terminal.catch((): void => {});
			await state.applyReconciliation({
				disposition: 'reopenRequired',
				reason: 'epoch_advanced',
				requiredWorkerDerivationEpoch: 1,
				subscriptionId: 'older-annotation-subscription',
				subscriptionKind: 'review.annotations',
			});
			// Native moved the surface past this admission: a retirement, not a failure.
			await expect(terminal).rejects.toMatchObject({
				name: 'BridgeProductSubscriptionEpochRetiredError',
				nextWorkerDerivationEpoch: 1,
				surface: 'review',
			});
		} finally {
			state.fail(new Error('Epoch reconciliation test cleanup.'));
		}
	});

	test('fails a subscription native reports missing at its own epoch', async () => {
		// Arrange
		const harness = createAnnotationControlHarness();
		const terminalErrors: unknown[] = [];
		const state = new BridgeProductSubscriptionState({
			controlMux: harness.controlMux,
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (_subscriptionId, error): void => {
				terminalErrors.push(error);
			},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 1,
			subscriptionId: 'missing-annotation-subscription',
		});
		void state.start();
		await harness.capturedOpen;
		const terminal = state.publicSubscription.events[Symbol.asyncIterator]().next();
		void terminal.catch((): void => {});

		// Act
		await state.applyReconciliation({
			disposition: 'reopenRequired',
			reason: 'native_missing',
			requiredWorkerDerivationEpoch: 1,
			subscriptionId: 'missing-annotation-subscription',
			subscriptionKind: 'review.annotations',
		});

		// Assert: no newer epoch was involved, so the consumer sees a reset.
		await expect(terminal).rejects.toBeInstanceOf(BridgeProductSubscriptionResetError);
		expect(terminalErrors).toHaveLength(1);
	});

	test('retires an unreleased subscription when native ends it for a newer surface epoch', async () => {
		// Arrange: the worker already serves epoch 2; native's floor retired the
		// epoch-1 subscription before the worker released it.
		const harness = createAnnotationControlHarness();
		let surfaceEpoch = 1;
		const terminalErrors: unknown[] = [];
		const state = new BridgeProductSubscriptionState({
			controlMux: harness.controlMux,
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (_subscriptionId, error, drainUntilNativeTerminal): void => {
				terminalErrors.push({ drainUntilNativeTerminal, error });
			},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => surfaceEpoch,
			subscriptionId: 'floor-retired-subscription',
		});
		void state.start();
		const open = await harness.capturedOpen;
		const terminal = state.publicSubscription.events[Symbol.asyncIterator]().next();
		void terminal.catch((): void => {});
		const correlation = {
			subscriptionId: open.subscriptionId,
			subscriptionKind: 'review.annotations',
			workerDerivationEpoch: open.workerDerivationEpoch,
		};
		state.acceptFrame(
			requireSubscriptionFrame(
				bridgeProductMetadataFrameSchema.parse({
					...metadataFrameIdentity(1),
					...correlation,
					kind: 'subscription.accepted',
					subscriptionSequence: 0,
				}),
			),
		);
		surfaceEpoch = 2;

		// Act
		state.acceptFrame(
			requireSubscriptionFrame(
				bridgeProductMetadataFrameSchema.parse({
					...metadataFrameIdentity(2),
					...correlation,
					kind: 'subscription.reset',
					reason: 'epoch_retired',
					subscriptionSequence: 1,
				}),
			),
		);

		// Assert: a clean native terminal that the consumer reads as a retirement.
		await expect(terminal).rejects.toMatchObject({
			name: 'BridgeProductSubscriptionEpochRetiredError',
			nextWorkerDerivationEpoch: 2,
		});
		expect(terminalErrors).toEqual([{ drainUntilNativeTerminal: undefined, error: undefined }]);
	});

	test('local cancellation settles while native refuses an active subscription', async () => {
		// Arrange
		const harness = createAnnotationControlHarness();
		let nativeCancelAttempts = 0;
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				...harness.controlMux,
				cancelSubscription: async (): Promise<never> => {
					nativeCancelAttempts += 1;
					throw new Error('Native refused the cancel.');
				},
			},
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 0,
			subscriptionId: 'active-cancel-refusal-subscription',
		});
		void state.start();
		await harness.capturedOpen;

		// Act
		const nextEvent = state.publicSubscription.events[Symbol.asyncIterator]().next();
		await state.cancel();

		// The consumer is released locally; the independent native escape was attempted.
		expect(await nextEvent).toEqual({ done: true, value: undefined });
		expect(nativeCancelAttempts).toBe(1);
	});

	test('drains a subscription whose stale cancel native refused until native retires it for the new epoch', async () => {
		// Arrange: native's surface floor already advanced, so it refuses the epoch-1
		// cancel and ends the subscription itself with an epoch_retired reset.
		const harness = createAnnotationControlHarness();
		const terminalErrors: unknown[] = [];
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				...harness.controlMux,
				cancelSubscription: async (): Promise<never> => {
					throw new BridgeProductControlRequestError({
						code: 'resync_required',
						message: 'Stale worker derivation epoch.',
						retryAfterMilliseconds: null,
						retryable: true,
					});
				},
			},
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (_subscriptionId, error): void => {
				terminalErrors.push(error);
			},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 1,
			subscriptionId: 'stale-cancel-subscription',
		});
		void state.start();
		const open = await harness.capturedOpen;
		const correlation = {
			subscriptionId: open.subscriptionId,
			subscriptionKind: 'review.annotations',
			workerDerivationEpoch: open.workerDerivationEpoch,
		};

		// Act
		await state.cancel();
		const lateFrame = (): void => {
			state.acceptFrame(
				requireSubscriptionFrame(
					bridgeProductMetadataFrameSchema.parse({
						...metadataFrameIdentity(1),
						...correlation,
						kind: 'subscription.accepted',
						subscriptionSequence: 0,
					}),
				),
			);
		};

		// Assert: frames native queued before its terminal drain instead of poisoning
		// the shared stream, and the epoch_retired reset ends the subscription cleanly.
		expect(lateFrame).not.toThrow();
		expect(terminalErrors).toEqual([undefined]);
		state.acceptFrame(
			requireSubscriptionFrame(
				bridgeProductMetadataFrameSchema.parse({
					...metadataFrameIdentity(2),
					...correlation,
					kind: 'subscription.reset',
					reason: 'epoch_retired',
					subscriptionSequence: 1,
				}),
			),
		);
		expect(terminalErrors).toEqual([undefined]);
	});

	test('surface epoch admission proceeds while an older native cancel escape is unanswered', async () => {
		const nativeCancelStarted = createBridgeProductDeferred<void>();
		const nativeCancelReply = createBridgeProductDeferred<void>();
		const harness = createAnnotationControlHarness();
		const authority = new BridgeProductSurfaceEpochAuthority({ review: 1 });
		const state = new BridgeProductSubscriptionState({
			controlMux: {
				...harness.controlMux,
				cancelSubscription: (): Promise<void> => {
					nativeCancelStarted.resolve();
					return nativeCancelReply.promise;
				},
			},
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => authority.current('review'),
			subscriptionId: 'held-native-cancel-subscription',
		});
		void state.start();
		await harness.capturedOpen;
		try {
			authority.advance('review', (nextEpoch) => [
				state.retireBeforeWorkerDerivationEpochAdvance(
					new BridgeProductSubscriptionEpochRetiredError({
						nextWorkerDerivationEpoch: nextEpoch,
						surface: 'review',
					}),
				),
			]);
			await nativeCancelStarted.promise;
			expect(await authority.admitAt('review', (epoch): number => epoch)).toBe(2);
		} finally {
			nativeCancelReply.resolve();
			state.fail(new Error('Held native cancel test cleanup.'));
		}
	});

	test('releases an admitted subscription at its own epoch before a surface advance and leaves an unadmitted one alone', async () => {
		// Arrange
		const cancelledEpochs: number[] = [];
		const harness = createAnnotationControlHarness();
		const controlMux = {
			...harness.controlMux,
			cancelSubscription: async (props: {
				readonly workerDerivationEpoch: number;
			}): Promise<void> => {
				cancelledEpochs.push(props.workerDerivationEpoch);
			},
		};
		const admitted = new BridgeProductSubscriptionState({
			controlMux,
			ensureMetadataStream: async (): Promise<void> => {},
			initialOptions: {},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 1,
			subscriptionId: 'admitted-retire-subscription',
		});
		void admitted.start();
		await harness.capturedOpen;
		const unadmitted = new BridgeProductSubscriptionState({
			controlMux,
			ensureMetadataStream: (): Promise<void> => new Promise<void>((): void => {}),
			initialOptions: {},
			onTerminal: (): void => {},
			protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
			readWorkerDerivationEpochAtAdmission: (): number => 2,
			subscriptionId: 'unadmitted-retire-subscription',
		});
		void unadmitted.start();
		const retirement = new BridgeProductSubscriptionEpochRetiredError({
			nextWorkerDerivationEpoch: 2,
			surface: 'review',
		});
		const admittedEvent = admitted.publicSubscription.events[Symbol.asyncIterator]().next();

		try {
			// Act
			await Promise.all([
				admitted.retireBeforeWorkerDerivationEpochAdvance(retirement),
				unadmitted.retireBeforeWorkerDerivationEpochAdvance(retirement),
			]);

			// Assert: one cancel, tagged with the epoch native admitted it at, and the
			// consumer learns it was retired rather than failed.
			expect(cancelledEpochs).toEqual([1]);
			await expect(admittedEvent).rejects.toBe(retirement);
		} finally {
			admitted.fail(new Error('Retirement test cleanup.'));
			unadmitted.fail(new Error('Retirement test cleanup.'));
		}
	});

	test.each(['producer_overflow', 'sequence_gap', 'stale_source', 'snapshot_required'] as const)(
		'preserves the generic %s reset reason as a terminal typed error',
		async (reason) => {
			// Arrange
			const controlHarness = createAnnotationControlHarness();
			let terminalCount = 0;
			const state = new BridgeProductSubscriptionState({
				controlMux: controlHarness.controlMux,
				ensureMetadataStream: async (): Promise<void> => {},
				initialOptions: {},
				onTerminal: (): void => {
					terminalCount += 1;
				},
				protocol: bridgeProductReviewAnnotationMetadataApplicationProtocol,
				readWorkerDerivationEpochAtAdmission: (): number => 1,
				subscriptionId: 'reset-reason-subscription',
			});
			void state.start();
			const open = await controlHarness.capturedOpen;
			const correlation = {
				subscriptionId: open.subscriptionId,
				subscriptionKind: 'review.annotations',
				workerDerivationEpoch: open.workerDerivationEpoch,
			};
			state.acceptFrame(
				requireSubscriptionFrame(
					bridgeProductMetadataFrameSchema.parse({
						...metadataFrameIdentity(1),
						...correlation,
						kind: 'subscription.accepted',
						subscriptionSequence: 0,
					}),
				),
			);
			const nextEvent = state.publicSubscription.events[Symbol.asyncIterator]().next();

			// Act
			state.acceptFrame(
				requireSubscriptionFrame(
					bridgeProductMetadataFrameSchema.parse({
						...metadataFrameIdentity(2),
						...correlation,
						kind: 'subscription.reset',
						reason,
						subscriptionSequence: 1,
					}),
				),
			);

			// Assert
			await expect(nextEvent).rejects.toBeInstanceOf(BridgeProductSubscriptionResetError);
			await expect(nextEvent).rejects.toMatchObject({ reason });
			state.fail(new Error('Already-terminal reset cleanup.'));
			expect(terminalCount).toBe(1);
		},
	);
});

interface CapturedAnnotationOpen {
	readonly subscriptionId: string;
	readonly workerDerivationEpoch: number;
}

function createAnnotationControlHarness(): {
	readonly capturedOpen: Promise<CapturedAnnotationOpen>;
	readonly controlMux: BridgeProductSubscriptionStateControlMux<
		'review.annotations',
		ReviewAnnotationOpen
	>;
} {
	let resolveCapturedOpen: ((open: CapturedAnnotationOpen) => void) | null = null;
	const capturedOpen = new Promise<CapturedAnnotationOpen>((resolve): void => {
		resolveCapturedOpen = resolve;
	});
	const controlMux: BridgeProductSubscriptionStateControlMux<
		'review.annotations',
		ReviewAnnotationOpen
	> = {
		cancelSubscription: async (): Promise<never> => {
			throw new Error('Annotation admission harness does not cancel subscriptions.');
		},
		openSubscription: async (props) => {
			if (props.subscription.subscriptionKind !== 'review.annotations') {
				throw new Error('Annotation admission harness accepts only Review annotations.');
			}
			resolveCapturedOpen?.(props);
			return {
				kind: 'subscription.openAccepted',
				paneSessionId: 'pane-session-annotations',
				requestId: 'request-open-review-annotations',
				requestSequence: 2,
				subscriptionId: props.subscriptionId,
				subscriptionKind: props.subscription.subscriptionKind,
				worktreeId: '00000000-0000-7000-8000-000000000001',
				wireVersion: 2,
				workerInstanceId: 'worker-instance-annotations',
			};
		},
	};
	return { capturedOpen, controlMux };
}

function metadataFrameIdentity(streamSequence: number): {
	readonly metadataStreamId: string;
	readonly paneSessionId: string;
	readonly streamSequence: number;
	readonly wireVersion: 2;
	readonly workerInstanceId: string;
} {
	return {
		metadataStreamId: 'metadata-stream-annotations',
		paneSessionId: 'pane-session-annotations',
		streamSequence,
		wireVersion: 2,
		workerInstanceId: 'worker-instance-annotations',
	};
}

function requireSubscriptionFrame(
	frame: BridgeProductMetadataFrame,
): BridgeProductSubscriptionFrame {
	switch (frame.kind) {
		case 'subscription.accepted':
		case 'subscription.cancelled':
		case 'subscription.end':
		case 'subscription.reset':
			return frame;
		case 'content.cancelled':
		case 'metadataStream.accepted':
		case 'stream.keepalive':
		case 'metadataStream.error':
		case 'pane.presentation':
		case 'pane.surfaceSelectionRequested':
		case 'subscription.batchBegin':
		case 'subscription.batchPart':
		case 'subscription.batchComplete':
			throw new Error(`Expected a subscription frame, received ${frame.kind}.`);
	}
	throw new Error('Unsupported Bridge product metadata frame.');
}
