import { afterEach, describe, expect, test, vi } from 'vitest';

import type { BridgeCommWorkerAnnotationProjectionPublication } from './bridge-comm-worker-annotation-projection-query-controller.js';
import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { bridgeProductMetadataFrameSchema } from './bridge-product-session-contracts.js';
import type {
	BridgeProductControlRequest,
	BridgeProductMetadataFrame,
	BridgeProductMetadataStreamRequest,
} from './bridge-product-session-contracts.js';
import type { BridgeProductSubscriptionKind } from './bridge-product-subscription-contracts.js';
import { bridgeProductSubscriptionKindSchema } from './bridge-product-subscription-contracts.js';
import {
	createTransportHarness,
	disposeTransportHarnesses,
	fileSourceConfiguration,
	metadataAccepted,
	subscriptionAccepted,
	requestErrorResponse,
	subscriptionCancelled,
} from './test-fixtures/bridge-product-transport-metadata.test-support.js';

afterEach(async (): Promise<void> => {
	try {
		await disposeTransportHarnesses();
	} finally {
		vi.unstubAllGlobals();
	}
});

describe('Bridge annotation subscription worker-epoch cutover', () => {
	test('opens replacement File metadata without waiting for the annotation sibling, then moves annotations to the new epoch', async () => {
		// Arrange
		const harness = createTransportHarness();
		const fileConvergenceStates: string[] = [];
		const controller = new BridgeCommWorkerProductController({
			callCurrentFileSource: async () => ({
				source: fileSourceConfiguration(),
				status: 'available',
			}),
			onAnnotationProjectionConvergence: ({ state, surface }): void => {
				if (surface !== 'file') return;
				fileConvergenceStates.push(
					state.kind === 'ready' ? 'ready' : `${state.kind}:${state.catalogAuthorityRetired}`,
				);
			},
			productTransport: harness.transport,
		});
		const initialFileSource = controller.ensureFileSource();
		controller.ensureReviewMetadata();
		await harness.server.waitForMetadataStream();
		const streamRequest = harness.server.requiredMetadataRequest();
		harness.server.emitMetadata(metadataAccepted(streamRequest, 0));
		await harness.server.waitForControlKind('subscription.open', 2);
		const initialMetadataOpens = subscriptionOpenRequests(harness.server.controlRequests);
		for (const [index, request] of initialMetadataOpens.entries()) {
			const subscriptionKind = bridgeProductSubscriptionKindSchema.parse(
				request.subscription.subscriptionKind,
			);
			if (subscriptionKind !== 'file.metadata' && subscriptionKind !== 'review.metadata') {
				throw new Error('Expected both metadata sources to establish epoch-one authority first.');
			}
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 1,
					kind: subscriptionKind,
					request: streamRequest,
					streamSequence: index + 1,
					subscriptionId: request.subscriptionId,
				}),
			);
		}
		await initialFileSource;

		controller.ensureAnnotationSubscriptions();
		await harness.server.waitForControlKind('subscription.open', 4);

		const initialOpenByKind = new Map<BridgeProductSubscriptionKind, SubscriptionOpenRequest>();
		for (const [index, request] of subscriptionOpenRequests(
			harness.server.controlRequests,
		).entries()) {
			const subscriptionKind = bridgeProductSubscriptionKindSchema.parse(
				request.subscription.subscriptionKind,
			);
			initialOpenByKind.set(subscriptionKind, request);
			if (initialMetadataOpens.includes(request)) continue;
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 1,
					kind: subscriptionKind,
					request: streamRequest,
					streamSequence: index + 1,
					subscriptionId: request.subscriptionId,
				}),
			);
		}

		const initialFileAnnotation = requiredSubscriptionOpen(initialOpenByKind, 'file.annotations');
		const initialFileMetadata = requiredSubscriptionOpen(initialOpenByKind, 'file.metadata');
		const initialReviewAnnotation = requiredSubscriptionOpen(
			initialOpenByKind,
			'review.annotations',
		);
		const initialReviewMetadata = requiredSubscriptionOpen(initialOpenByKind, 'review.metadata');

		// Act: File's own E3 reset advances its surface epoch. The annotation
		// sibling has not delivered a cancellation terminal.
		harness.server.emitMetadata(
			subscriptionResetFrame({
				epoch: 1,
				kind: 'file.metadata',
				request: streamRequest,
				streamSequence: 5,
				subscriptionId: initialFileMetadata.subscriptionId,
			}),
		);
		await harness.server.waitForControlKind('subscription.cancel');
		await harness.server.waitForControlRequestWhere((request): boolean =>
			hasReplacementOpen([request], 'file.metadata', initialFileMetadata.subscriptionId),
		);
		let nextStreamSequence = 6;

		const controlRequests = harness.server.controlRequests;
		const replacementFileMetadata = requiredReplacementOpen(
			controlRequests,
			'file.metadata',
			initialFileMetadata.subscriptionId,
		);

		// Assert: File content opened at the new epoch while the annotation sibling's
		// retirement was still undrained, so comments never delay the file itself.
		expect(replacementFileMetadata.workerDerivationEpoch).toBe(2);
		// Native refuses controls tagged with a stale epoch once the surface advances,
		// so the epoch-1 sibling is released before any epoch-2 request reaches it.
		const siblingCancellationIndex = controlRequests.indexOf(
			requiredCancellation(controlRequests, initialFileAnnotation.subscriptionId),
		);
		expect(siblingCancellationIndex).toBeLessThan(controlRequests.indexOf(replacementFileMetadata));

		await harness.server.waitForControlRequestWhere((request): boolean =>
			hasReplacementOpen([request], 'file.annotations', initialFileAnnotation.subscriptionId),
		);
		const replacementFileAnnotation = requiredReplacementOpen(
			harness.server.controlRequests,
			'file.annotations',
			initialFileAnnotation.subscriptionId,
		);
		expect(replacementFileAnnotation.workerDerivationEpoch).toBe(2);
		expect(
			requiredCancellation(controlRequests, initialFileAnnotation.subscriptionId).subscriptionKind,
		).toBe('file.annotations');
		// A routine refresh keeps comments visible as refreshing; it is never unavailable.
		expect(fileConvergenceStates).toContain('refreshing:true');
		expect(fileConvergenceStates.filter((state) => state.startsWith('unavailable'))).toEqual([]);

		for (const replacement of [replacementFileMetadata, replacementFileAnnotation]) {
			const subscriptionKind = bridgeProductSubscriptionKindSchema.parse(
				replacement.subscription.subscriptionKind,
			);
			harness.server.emitMetadata(
				subscriptionAccepted({
					epoch: 2,
					kind: subscriptionKind,
					request: streamRequest,
					streamSequence: nextStreamSequence,
					subscriptionId: replacement.subscriptionId,
				}),
			);
			nextStreamSequence += 1;
		}

		expect(harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
			failureStage: null,
			streamOpenCount: 1,
		});
		expect(
			controlRequests.filter(
				(request) =>
					request.kind === 'subscription.cancel' &&
					(request.subscriptionId === initialReviewAnnotation.subscriptionId ||
						request.subscriptionId === initialReviewMetadata.subscriptionId),
			),
		).toEqual([]);
		expect(
			subscriptionOpenRequests(controlRequests).filter(
				(request) =>
					request.subscription.subscriptionKind === 'review.annotations' ||
					request.subscription.subscriptionKind === 'review.metadata',
			),
		).toEqual([initialReviewMetadata, initialReviewAnnotation]);
		expect(harness.transport.workerDerivationEpoch('review')).toBe(1);
	});

	test('advances the surface epoch when native resets the annotation sibling during its cutover cancellation', async () => {
		// Arrange: the File cutover retires metadata, then native resets the
		// annotation sibling (for example, its source is unavailable) while the
		// sibling's cancellation is pending.
		const scenario = await establishEpochOneSubscriptions();
		const initialFileAnnotation = requiredSubscriptionOpen(
			scenario.initialOpenByKind,
			'file.annotations',
		);
		const initialFileMetadata = requiredSubscriptionOpen(
			scenario.initialOpenByKind,
			'file.metadata',
		);
		scenario.harness.server.emitMetadata(
			subscriptionResetFrame({
				epoch: 1,
				kind: 'file.metadata',
				request: scenario.streamRequest,
				streamSequence: 5,
				subscriptionId: initialFileMetadata.subscriptionId,
			}),
		);
		await scenario.harness.server.waitForControlKind('subscription.cancel');
		const annotationCancellation = requiredCancellation(
			scenario.harness.server.controlRequests,
			initialFileAnnotation.subscriptionId,
		);

		// Act
		scenario.harness.server.emitMetadata(
			subscriptionResetFrame({
				epoch: 1,
				kind: 'file.annotations',
				request: scenario.streamRequest,
				streamSequence: 6,
				subscriptionId: annotationCancellation.subscriptionId,
			}),
		);
		await scenario.harness.server.waitForControlRequestWhere((request): boolean =>
			hasReplacementOpen([request], 'file.annotations', initialFileAnnotation.subscriptionId),
		);

		// Assert: the reset retired the sibling as completely as a cancellation, so
		// both File successors open at the advanced epoch without a second cancel.
		expect(scenario.harness.transport.workerDerivationEpoch('file')).toBe(2);
		expect(
			requiredReplacementOpen(
				scenario.harness.server.controlRequests,
				'file.metadata',
				initialFileMetadata.subscriptionId,
			).workerDerivationEpoch,
		).toBe(2);
		expect(
			requiredReplacementOpen(
				scenario.harness.server.controlRequests,
				'file.annotations',
				initialFileAnnotation.subscriptionId,
			).workerDerivationEpoch,
		).toBe(2);
		expect(
			cancellationRequests(scenario.harness.server.controlRequests).map(
				(request) => request.subscriptionId,
			),
		).toEqual([initialFileAnnotation.subscriptionId]);
	});

	test('keeps Review annotations refreshing when native floor-retires the sibling and refuses its stale cancel', async () => {
		// Arrange: a newer-epoch content request already advanced native's Review
		// floor, so native refuses the worker's epoch-1 annotation cancel and ends the
		// subscription itself with an epoch_retired reset.
		const reviewConvergenceStates: string[] = [];
		const scenario = await establishEpochOneSubscriptions({
			onAnnotationProjectionConvergence: ({ state, surface }): void => {
				if (surface !== 'review') return;
				reviewConvergenceStates.push(
					state.kind === 'ready' ? 'ready' : `${state.kind}:${state.catalogAuthorityRetired}`,
				);
			},
		});
		const initialReviewAnnotation = requiredSubscriptionOpen(
			scenario.initialOpenByKind,
			'review.annotations',
		);
		scenario.harness.server.cancelHandler = (cancel): Response =>
			cancel.subscriptionKind === 'review.annotations'
				? requestErrorResponse(cancel, 'resync_required')
				: new Response(
						JSON.stringify({
							kind: 'subscription.cancelAccepted',
							paneSessionId: cancel.paneSessionId,
							requestId: cancel.requestId,
							requestSequence: cancel.requestSequence,
							subscriptionId: cancel.subscriptionId,
							subscriptionKind: cancel.subscriptionKind,
							wireVersion: cancel.wireVersion,
							workerInstanceId: cancel.workerInstanceId,
						}),
						{ headers: { 'Content-Type': 'application/json' } },
					);

		// Act: Review's own metadata reset advances the surface epoch.
		const initialReviewMetadata = requiredSubscriptionOpen(
			scenario.initialOpenByKind,
			'review.metadata',
		);
		scenario.harness.server.emitMetadata(
			subscriptionResetFrame({
				epoch: 1,
				kind: 'review.metadata',
				request: scenario.streamRequest,
				streamSequence: 5,
				subscriptionId: initialReviewMetadata.subscriptionId,
			}),
		);
		await scenario.harness.server.waitForControlRequestWhere(
			(request): boolean =>
				request.kind === 'subscription.cancel' &&
				request.subscriptionId === initialReviewAnnotation.subscriptionId,
		);
		scenario.harness.server.emitMetadata(
			subscriptionResetFrame({
				epoch: 1,
				kind: 'review.annotations',
				reason: 'epoch_retired',
				request: scenario.streamRequest,
				streamSequence: 6,
				subscriptionId: initialReviewAnnotation.subscriptionId,
			}),
		);
		await scenario.harness.server.waitForControlRequestWhere((request): boolean =>
			hasReplacementOpen([request], 'review.annotations', initialReviewAnnotation.subscriptionId),
		);

		// Assert: the drawer refreshes with retired catalog authority and never reports
		// updates unavailable; the replacement admits at the new epoch on a live stream.
		expect(reviewConvergenceStates).toEqual(['refreshing:true']);
		expect(
			requiredReplacementOpen(
				scenario.harness.server.controlRequests,
				'review.annotations',
				initialReviewAnnotation.subscriptionId,
			).workerDerivationEpoch,
		).toBe(scenario.harness.transport.workerDerivationEpoch('review'));
		expect(scenario.harness.transport.metadataStreamDiagnostics?.()).toMatchObject({
			failureStage: null,
			streamOpenCount: 1,
		});
	});

	test('a repeated annotation request during an epoch replacement opens no duplicate subscription', async () => {
		// Arrange: File advances to epoch 2 and its annotation replacement opens while
		// the retired epoch-1 sibling's cancellation is still pending.
		const scenario = await establishEpochOneSubscriptions();
		const initialFileAnnotation = requiredSubscriptionOpen(
			scenario.initialOpenByKind,
			'file.annotations',
		);
		const initialFileMetadata = requiredSubscriptionOpen(
			scenario.initialOpenByKind,
			'file.metadata',
		);
		scenario.harness.server.emitMetadata(
			subscriptionResetFrame({
				epoch: 1,
				kind: 'file.metadata',
				request: scenario.streamRequest,
				streamSequence: 5,
				subscriptionId: initialFileMetadata.subscriptionId,
			}),
		);
		await scenario.harness.server.waitForControlKind('subscription.cancel');
		await scenario.harness.server.waitForControlRequestWhere((request): boolean =>
			hasReplacementOpen([request], 'file.annotations', initialFileAnnotation.subscriptionId),
		);

		// Act: the runtime requests annotations again, then the retired sibling drains.
		scenario.controller.ensureAnnotationSubscriptions();
		scenario.harness.server.emitMetadata(
			subscriptionCancelled({
				epoch: 1,
				kind: 'file.annotations',
				request: scenario.streamRequest,
				streamSequence: 6,
				subscriptionId: requiredCancellation(
					scenario.harness.server.controlRequests,
					initialFileAnnotation.subscriptionId,
				).subscriptionId,
				subscriptionSequence: 1,
			}),
		);

		// Assert: one epoch-2 replacement, however the request and retirement interleave.
		expect(
			subscriptionOpenRequests(scenario.harness.server.controlRequests)
				.filter((request) => request.subscription.subscriptionKind === 'file.annotations')
				.map((request) => request.workerDerivationEpoch),
		).toEqual([1, 2]);
	});
});

type SubscriptionOpenRequest = Extract<BridgeProductControlRequest, { kind: 'subscription.open' }>;
type SubscriptionCancelRequest = Extract<
	BridgeProductControlRequest,
	{ kind: 'subscription.cancel' }
>;

interface EpochOneSubscriptionScenario {
	readonly controller: BridgeCommWorkerProductController;
	readonly harness: ReturnType<typeof createTransportHarness>;
	readonly initialOpenByKind: ReadonlyMap<BridgeProductSubscriptionKind, SubscriptionOpenRequest>;
	readonly streamRequest: BridgeProductMetadataStreamRequest;
}

async function establishEpochOneSubscriptions(
	props: {
		readonly onAnnotationProjectionConvergence?: (
			publication: BridgeCommWorkerAnnotationProjectionPublication,
		) => void;
	} = {},
): Promise<EpochOneSubscriptionScenario> {
	const harness = createTransportHarness();
	const controller = new BridgeCommWorkerProductController({
		callCurrentFileSource: async () => ({
			source: fileSourceConfiguration(),
			status: 'available',
		}),
		...(props.onAnnotationProjectionConvergence === undefined
			? {}
			: { onAnnotationProjectionConvergence: props.onAnnotationProjectionConvergence }),
		productTransport: harness.transport,
	});
	const initialFileSource = controller.ensureFileSource();
	controller.ensureReviewMetadata();
	await harness.server.waitForMetadataStream();
	const streamRequest = harness.server.requiredMetadataRequest();
	harness.server.emitMetadata(metadataAccepted(streamRequest, 0));
	await harness.server.waitForControlKind('subscription.open', 2);
	let nextStreamSequence = 1;
	for (const request of subscriptionOpenRequests(harness.server.controlRequests)) {
		const subscriptionKind = bridgeProductSubscriptionKindSchema.parse(
			request.subscription.subscriptionKind,
		);
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 1,
				kind: subscriptionKind,
				request: streamRequest,
				streamSequence: nextStreamSequence,
				subscriptionId: request.subscriptionId,
			}),
		);
		nextStreamSequence += 1;
	}
	await initialFileSource;
	controller.ensureAnnotationSubscriptions();
	await harness.server.waitForControlKind('subscription.open', 4);
	const initialOpenByKind = new Map<BridgeProductSubscriptionKind, SubscriptionOpenRequest>();
	for (const request of subscriptionOpenRequests(harness.server.controlRequests)) {
		const subscriptionKind = bridgeProductSubscriptionKindSchema.parse(
			request.subscription.subscriptionKind,
		);
		initialOpenByKind.set(subscriptionKind, request);
		if (subscriptionKind === 'file.metadata' || subscriptionKind === 'review.metadata') continue;
		harness.server.emitMetadata(
			subscriptionAccepted({
				epoch: 1,
				kind: subscriptionKind,
				request: streamRequest,
				streamSequence: nextStreamSequence,
				subscriptionId: request.subscriptionId,
			}),
		);
		nextStreamSequence += 1;
	}
	return { controller, harness, initialOpenByKind, streamRequest };
}

function subscriptionOpenRequests(
	requests: readonly BridgeProductControlRequest[],
): readonly SubscriptionOpenRequest[] {
	return requests.filter(
		(request): request is SubscriptionOpenRequest => request.kind === 'subscription.open',
	);
}

function requiredSubscriptionOpen(
	requestsByKind: ReadonlyMap<BridgeProductSubscriptionKind, SubscriptionOpenRequest>,
	kind: BridgeProductSubscriptionKind,
): SubscriptionOpenRequest {
	const request = requestsByKind.get(kind);
	if (request === undefined) throw new Error(`Missing initial ${kind} subscription.`);
	return request;
}

function hasReplacementOpen(
	requests: readonly BridgeProductControlRequest[],
	kind: BridgeProductSubscriptionKind,
	initialSubscriptionId: string,
): boolean {
	return subscriptionOpenRequests(requests).some(
		(request) =>
			request.subscription.subscriptionKind === kind &&
			request.subscriptionId !== initialSubscriptionId,
	);
}

function requiredReplacementOpen(
	requests: readonly BridgeProductControlRequest[],
	kind: BridgeProductSubscriptionKind,
	initialSubscriptionId: string,
): SubscriptionOpenRequest {
	const request = subscriptionOpenRequests(requests).find(
		(candidate) =>
			candidate.subscription.subscriptionKind === kind &&
			candidate.subscriptionId !== initialSubscriptionId,
	);
	if (request === undefined) throw new Error(`Missing replacement ${kind} subscription.`);
	return request;
}

function cancellationRequests(
	requests: readonly BridgeProductControlRequest[],
): readonly SubscriptionCancelRequest[] {
	return requests.filter(
		(request): request is SubscriptionCancelRequest => request.kind === 'subscription.cancel',
	);
}

function requiredCancellation(
	requests: readonly BridgeProductControlRequest[],
	subscriptionId: string,
): SubscriptionCancelRequest {
	const request = requests.find(
		(candidate): candidate is SubscriptionCancelRequest =>
			candidate.kind === 'subscription.cancel' && candidate.subscriptionId === subscriptionId,
	);
	if (request === undefined) throw new Error(`Missing cancellation for ${subscriptionId}.`);
	return request;
}

function subscriptionResetFrame(props: {
	readonly epoch: number;
	readonly kind: BridgeProductSubscriptionKind;
	readonly reason?: 'epoch_retired' | 'stale_source';
	readonly request: BridgeProductMetadataStreamRequest;
	readonly streamSequence: number;
	readonly subscriptionId: string;
}): BridgeProductMetadataFrame {
	return bridgeProductMetadataFrameSchema.parse({
		metadataStreamId: props.request.metadataStreamId,
		paneSessionId: props.request.paneSessionId,
		streamSequence: props.streamSequence,
		wireVersion: props.request.wireVersion,
		workerInstanceId: props.request.workerInstanceId,
		kind: 'subscription.reset',
		reason: props.reason ?? 'stale_source',
		subscriptionId: props.subscriptionId,
		subscriptionKind: props.kind,
		subscriptionSequence: 1,
		workerDerivationEpoch: props.epoch,
	});
}
