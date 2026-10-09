import { describe, expect, test } from 'vitest';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import {
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
} from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	BridgeProductControlMux,
	type BridgeProductSessionAuthority,
} from './bridge-product-session-authority.js';
import {
	bridgeProductControlRequestSchema,
	type BridgeProductControlRequest,
	type BridgeProductControlResponse,
	type BridgeProductResyncReconciliationOutcome,
} from './bridge-product-session-contracts.js';

type ActiveSubscriptions = Extract<
	BridgeProductControlRequest,
	{ kind: 'workerSession.resync' }
>['activeSubscriptions'];
type ResyncRequest = Extract<BridgeProductControlRequest, { kind: 'workerSession.resync' }>;
type ResyncResponse = Extract<BridgeProductControlResponse, { kind: 'resync.accepted' }>;

describe('Bridge product control mux resync', () => {
	test('exposes the strict worker-session resync operation', () => {
		const mux = createControlMux(async (): Promise<Response> => new Response(null));

		expect('resync' in mux).toBe(true);
	});

	test.each(canonicalReconciliationOutcomes())(
		'accepts a canonical $disposition reconciliation response',
		async (outcome) => {
			const activeSubscriptions = oneActiveSubscription();
			const mux = createControlMux(async (_route, requestInit): Promise<Response> => {
				const request = requireResyncRequest(requestInit);
				return responseWithJSON(resyncAcceptedResponse(request, [outcome]));
			});

			await expect(
				mux.resync({
					readActiveSubscriptions: () => activeSubscriptions,
					readLastAcceptedStreamSequence: () => 12,
				}),
			).resolves.toMatchObject({
				kind: 'resync.accepted',
				metadataStreamSequenceBarrier: 12,
				nextExpectedRequestSequence: 4,
				reconciliation: [outcome],
			});
		},
	);

	test('rejects a correlated response whose kind is not resync.accepted', async () => {
		await expectRejectedResyncResponse(
			(request) => ({
				...responseIdentity(request),
				kind: 'workerSession.accepted',
				result: null,
			}),
			/resync\.accepted/iu,
		);
	});

	test('rejects a response with a noncontiguous next request sequence', async () => {
		await expectRejectedResyncResponse(
			(request) => ({
				...resyncAcceptedResponse(request, [
					retainedOutcome(requireArrayItem(oneActiveSubscription(), 0, 'active subscription')),
				]),
				nextExpectedRequestSequence: request.requestSequence + 2,
			}),
			/unexpected next request sequence/iu,
		);
	});

	test('rejects a metadata barrier behind the claimed accepted sequence', async () => {
		await expectRejectedResyncResponse(
			(request) => ({
				...resyncAcceptedResponse(request, [
					retainedOutcome(requireArrayItem(oneActiveSubscription(), 0, 'active subscription')),
				]),
				metadataStreamSequenceBarrier: request.lastAcceptedStreamSequence - 1,
			}),
			/metadata barrier precedes/iu,
		);
	});

	test('rejects positional reconciliation identity mismatch', async () => {
		const activeSubscriptions = twoActiveSubscriptions();
		const mux = createControlMux(async (_route, requestInit): Promise<Response> => {
			const request = requireResyncRequest(requestInit);
			return responseWithJSON(
				resyncAcceptedResponse(request, [
					retainedOutcome(requireArrayItem(activeSubscriptions, 1, 'second active subscription')),
					retainedOutcome(requireArrayItem(activeSubscriptions, 0, 'first active subscription')),
				]),
			);
		});

		await expect(
			mux.resync({
				readActiveSubscriptions: () => activeSubscriptions,
				readLastAcceptedStreamSequence: () => 12,
			}),
		).rejects.toThrow(/order or identity/iu);
	});

	test('rejects a retained reconciliation with a mismatched worker epoch', async () => {
		await expectRejectedResyncResponse(
			(request) => ({
				...resyncAcceptedResponse(request, [
					{
						disposition: 'retained',
						subscriptionId: 'review-subscription-1',
						subscriptionKind: 'review.metadata',
						workerDerivationEpoch: 99,
					},
				]),
			}),
			/retained reconciliation epoch/iu,
		);
	});

	test('captures resync state after admission while a prior result remains held', async () => {
		const heldCallResponse = createBridgeProductDeferred<Response>();
		const heldCallStarted = createBridgeProductDeferred<void>();
		const admittedRequests: BridgeProductControlRequest[] = [];
		const requestIds = ['held-call', 'resync-after-held-call'];
		const executeProductRequest: BridgeProductRequestExecutor = async (
			_route,
			requestInit,
		): Promise<Response> => {
			const request = requireControlRequest(requestInit);
			admittedRequests.push(request);
			if (request.kind === 'product.call') {
				heldCallStarted.resolve();
				return await heldCallResponse.promise;
			}
			if (request.kind === 'workerSession.resync') {
				return responseWithJSON(
					resyncAcceptedResponse(request, request.activeSubscriptions.map(retainedOutcome)),
				);
			}
			throw new Error(`Unexpected control request ${request.kind}.`);
		};
		const mux = createControlMux(executeProductRequest, requestIds);
		let activeSubscriptions = oneActiveSubscription();
		let lastAcceptedStreamSequence = 4;
		let activeSubscriptionReadCount = 0;
		let streamSequenceReadCount = 0;
		const heldCall = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'review-item-1' },
			workerDerivationEpoch: 3,
		});
		await heldCallStarted.promise;
		const resync = mux.resync({
			readActiveSubscriptions: (): ActiveSubscriptions => {
				activeSubscriptionReadCount += 1;
				return activeSubscriptions;
			},
			readLastAcceptedStreamSequence: (): number => {
				streamSequenceReadCount += 1;
				return lastAcceptedStreamSequence;
			},
		});

		expect(activeSubscriptionReadCount).toBe(0);
		expect(streamSequenceReadCount).toBe(0);
		activeSubscriptions = twoActiveSubscriptions();
		lastAcceptedStreamSequence = 9;
		await expect(resync).resolves.toMatchObject({ nextExpectedRequestSequence: 5 });
		heldCallResponse.resolve(
			responseWithJSON({
				...responseIdentity(
					requireProductCallRequest(requireArrayItem(admittedRequests, 0, 'held request')),
				),
				call: { method: 'review.markFileViewed', result: null },
				kind: 'call.completed',
			}),
		);

		await expect(heldCall).resolves.toBeNull();
		expect(activeSubscriptionReadCount).toBe(1);
		expect(streamSequenceReadCount).toBe(1);
		const resyncRequest = requireResyncRequestValue(
			requireArrayItem(admittedRequests, 1, 'resync request'),
		);
		expect(resyncRequest).toMatchObject({
			activeSubscriptions,
			lastAcceptedRequestSequence: 3,
			lastAcceptedStreamSequence: 9,
			requestSequence: 4,
		});
	});

	test('retries an ambiguous resync failure with identical request bytes', async () => {
		const requestBodies: Uint8Array[] = [];
		let attemptCount = 0;
		const mux = createControlMux(
			async (_route, requestInit): Promise<Response> => {
				const request = requireResyncRequest(requestInit);
				return responseWithJSON(
					resyncAcceptedResponse(request, [
						retainedOutcome(requireArrayItem(oneActiveSubscription(), 0, 'active subscription')),
					]),
				);
			},
			['resync-request-1'],
			(requestInit): void => {
				const body = requireUint8Array(requestInit.body);
				requestBodies.push(Uint8Array.from(body));
				attemptCount += 1;
				if (attemptCount === 1) throw new Error('ambiguous resync transport failure');
			},
		);

		await expect(
			mux.resync({
				readActiveSubscriptions: oneActiveSubscription,
				readLastAcceptedStreamSequence: () => 12,
			}),
		).resolves.toMatchObject({ kind: 'resync.accepted' });
		expect(requestBodies).toHaveLength(2);
		expect([...requireArrayItem(requestBodies, 0, 'first resync attempt')]).toEqual([
			...requireArrayItem(requestBodies, 1, 'second resync attempt'),
		]);
	});
});

async function expectRejectedResyncResponse(
	createResponse: (request: ResyncRequest) => unknown,
	expectedError: RegExp,
): Promise<void> {
	const mux = createControlMux(async (_route, requestInit): Promise<Response> => {
		const request = requireResyncRequest(requestInit);
		return responseWithJSON(createResponse(request));
	});
	await expect(
		mux.resync({
			readActiveSubscriptions: oneActiveSubscription,
			readLastAcceptedStreamSequence: () => 12,
		}),
	).rejects.toThrow(expectedError);
}

function oneActiveSubscription(): ActiveSubscriptions {
	return [
		{
			subscriptionId: 'review-subscription-1',
			subscriptionKind: 'review.metadata',
			workerDerivationEpoch: 3,
		},
	];
}

function twoActiveSubscriptions(): ActiveSubscriptions {
	return [
		...oneActiveSubscription(),
		{
			subscriptionId: 'file-subscription-1',
			subscriptionKind: 'file.metadata',
			workerDerivationEpoch: 5,
		},
	];
}

function canonicalReconciliationOutcomes(): readonly BridgeProductResyncReconciliationOutcome[] {
	const activeSubscription = requireArrayItem(oneActiveSubscription(), 0, 'active subscription');
	return [
		retainedOutcome(activeSubscription),
		{
			disposition: 'cancelled',
			priorWorkerDerivationEpoch: activeSubscription.workerDerivationEpoch,
			reason: 'native_revoked',
			subscriptionId: activeSubscription.subscriptionId,
			subscriptionKind: activeSubscription.subscriptionKind,
		},
		{
			disposition: 'reopenRequired',
			reason: 'snapshot_required',
			requiredWorkerDerivationEpoch: activeSubscription.workerDerivationEpoch,
			subscriptionId: activeSubscription.subscriptionId,
			subscriptionKind: activeSubscription.subscriptionKind,
		},
	];
}

function retainedOutcome(
	activeSubscription: ActiveSubscriptions[number],
): BridgeProductResyncReconciliationOutcome {
	return {
		disposition: 'retained',
		subscriptionId: activeSubscription.subscriptionId,
		subscriptionKind: activeSubscription.subscriptionKind,
		workerDerivationEpoch: activeSubscription.workerDerivationEpoch,
	};
}

function resyncAcceptedResponse(
	request: ResyncRequest,
	reconciliation: readonly BridgeProductResyncReconciliationOutcome[],
): ResyncResponse {
	return {
		...responseIdentity(request),
		kind: 'resync.accepted',
		metadataStreamSequenceBarrier: request.lastAcceptedStreamSequence,
		nextExpectedRequestSequence: request.requestSequence + 1,
		reconciliation,
	};
}

function responseIdentity(request: BridgeProductControlRequest): {
	readonly paneSessionId: string;
	readonly requestId: string;
	readonly requestSequence: number;
	readonly wireVersion: 2;
	readonly workerInstanceId: string;
} {
	return {
		paneSessionId: request.paneSessionId,
		requestId: request.requestId,
		requestSequence: request.requestSequence,
		wireVersion: request.wireVersion,
		workerInstanceId: request.workerInstanceId,
	};
}

function createControlMux(
	executeProductRequest: BridgeProductRequestExecutor,
	requestIds: string[] = ['resync-request-1'],
	onAdmission?: (requestInit: RequestInit) => void,
): BridgeProductControlMux {
	const authority: BridgeProductSessionAuthority = {
		bootstrap: {
			kind: 'productSession.bootstrap',
			paneSessionId: 'pane-session-1',
			policy: {
				maximumContentBytes: BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
				maximumMetadataFrameBytes: BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
				maximumQueuedStreamBytes: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
				admissionRetryCount: 2,
				contentAcknowledgementDeadlineMilliseconds: 5_000,
				contentProgressDeadlineMilliseconds: 5_000,
				viewBatchProgressDeadlineMilliseconds: 5_000,
				streamKeepaliveIntervalMilliseconds: 350,
				telemetryPreReadyBufferMaxBytes: 64 * 1024,
				telemetryPreReadyBufferMaxSamples: 128,
				workerSettlementDeadlineMilliseconds: 5_000,
				viewAcknowledgementDeadlineMilliseconds: 4_000,
				viewCreditBytes: 524_288,
				viewCreditParts: 8,
				viewMaximumConsecutiveResnapshots: 3,
				viewMaximumDirtyKeys: 4_096,
				maximumQueuedStreamFrames: BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
				maximumRequestBodyBytes: BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
				terminalFrameReserve: BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
			},
			wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
			workerInstanceId: 'worker-instance-1',
		},
		capabilityHeader: 'private-capability',
		open: Promise.resolve(),
	};
	const pendingResults = new Map<string, Promise<Response>>();
	let nextOperationId = 1;
	let nextFallbackRequestId = 1;
	const executeV2Request: BridgeProductRequestExecutor = async (route, requestInit) => {
		const body: unknown = JSON.parse(new TextDecoder().decode(requireUint8Array(requestInit.body)));
		if (typeof body !== 'object' || body === null || !('kind' in body)) {
			throw new Error('Expected a typed product command.');
		}
		if (body.kind === 'operation.result') {
			const resultRequest = bridgeProductOperationResultRequestSchema.parse(body);
			const pendingResult = pendingResults.get(resultRequest.operationId);
			if (pendingResult === undefined) throw new Error('Result read has no admitted operation.');
			const finalResponse = await pendingResult;
			return responseWithJSON({
				failureCode: null,
				kind: 'operation.result',
				operationId: resultRequest.operationId,
				outcome: 'succeeded',
				result: JSON.parse(await finalResponse.text()),
			});
		}
		if (body.kind === 'operation.resultAcknowledgement') {
			const acknowledgement = bridgeProductOperationResultAcknowledgementSchema.parse(body);
			pendingResults.delete(acknowledgement.operationId);
			return responseWithJSON({ ...acknowledgement, kind: 'operation.resultAcknowledged' });
		}
		const request = bridgeProductControlRequestSchema.parse(body);
		onAdmission?.(requestInit);
		const operationId = `resync-operation-${nextOperationId++}`;
		const finalResponse = executeProductRequest(route, requestInit);
		void finalResponse.catch((): void => {});
		pendingResults.set(operationId, finalResponse);
		return responseWithJSON({
			...responseIdentity(request),
			kind: 'operation.admitted',
			operationId,
			waitKind: 'ordinary',
		});
	};
	return new BridgeProductControlMux({
		authority,
		createRequestId: (): string =>
			requestIds.shift() ?? `resync-result-ack-${nextFallbackRequestId++}`,
		executeProductRequest: executeV2Request,
	});
}

function requireControlRequest(requestInit: RequestInit): BridgeProductControlRequest {
	return bridgeProductControlRequestSchema.parse(
		JSON.parse(new TextDecoder().decode(requireUint8Array(requestInit.body))),
	);
}

function requireResyncRequest(requestInit: RequestInit): ResyncRequest {
	return requireResyncRequestValue(requireControlRequest(requestInit));
}

function requireResyncRequestValue(request: BridgeProductControlRequest): ResyncRequest {
	if (request.kind !== 'workerSession.resync') {
		throw new Error(`Expected workerSession.resync, received ${request.kind}.`);
	}
	return request;
}

function requireProductCallRequest(
	request: BridgeProductControlRequest,
): Extract<BridgeProductControlRequest, { kind: 'product.call' }> {
	if (request.kind !== 'product.call') throw new Error('Expected held product.call request.');
	return request;
}

function requireArrayItem<TValue>(
	values: readonly TValue[],
	index: number,
	description: string,
): TValue {
	const value = values[index];
	if (value === undefined) throw new Error(`Missing ${description} at index ${index}.`);
	return value;
}

function requireUint8Array(value: BodyInit | null | undefined): Uint8Array {
	if (!(value instanceof Uint8Array)) throw new Error('Expected encoded Uint8Array request body.');
	return value;
}

function responseWithJSON(value: unknown): Response {
	return new Response(JSON.stringify(value), { status: 200 });
}
