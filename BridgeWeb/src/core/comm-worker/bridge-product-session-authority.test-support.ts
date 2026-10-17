import { vi, type MockInstance } from 'vitest';

import {
	BRIDGE_PRODUCT_MAXIMUM_CONTENT_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_METADATA_FRAME_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_BYTES,
	BRIDGE_PRODUCT_MAXIMUM_QUEUED_STREAM_FRAMES,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_TERMINAL_FRAME_RESERVE,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import type { BridgeProductSessionBootstrap } from './bridge-product-session-contracts.js';

const workerSessionOpenRequestId = 'worker-session-open-1';
const workerSessionOpenRequestSequence = 1;

interface TestReviewSubscriptionOpenProps {
	readonly signal?: AbortSignal;
	readonly subscription: { readonly subscriptionKind: 'review.metadata' };
	readonly subscriptionId: string;
	readonly workerDerivationEpoch: number;
}

interface TestReviewSubscriptionCancelProps {
	readonly subscriptionId: string;
	readonly subscriptionKind: 'review.metadata';
	readonly workerDerivationEpoch: number;
}

export function installFetchResponse(response: Response): void {
	vi.spyOn(globalThis, 'fetch').mockResolvedValue(response);
}

export function installWorkerOpenExchange(resultResponse: Response): MockInstance<typeof fetch> {
	return vi
		.spyOn(globalThis, 'fetch')
		.mockResolvedValueOnce(responseWithJSON(workerSessionAdmittedResponse()))
		.mockResolvedValueOnce(resultResponse)
		.mockResolvedValueOnce(
			responseWithJSON({
				...productResponseIdentity('worker-session-open-result-ack-2', 2),
				kind: 'operation.resultAcknowledged',
				operationId: 'operation-open-1',
			}),
		);
}

export function installWorkerOpenAndCallExchange(
	requestId: string,
	callResponse: object,
): MockInstance<typeof fetch> {
	return vi
		.spyOn(globalThis, 'fetch')
		.mockResolvedValueOnce(responseWithJSON(workerSessionAdmittedResponse()))
		.mockResolvedValueOnce(responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())))
		.mockResolvedValueOnce(
			responseWithJSON({
				...productResponseIdentity('worker-session-open-result-ack-2', 2),
				kind: 'operation.resultAcknowledged',
				operationId: 'operation-open-1',
			}),
		)
		.mockResolvedValueOnce(
			responseWithJSON({
				...productResponseIdentity(requestId, 3),
				kind: 'operation.admitted',
				operationId: 'operation-call-1',
				waitKind: 'ordinary',
			}),
		)
		.mockResolvedValueOnce(
			responseWithJSON({
				failureCode: null,
				kind: 'operation.result',
				operationId: 'operation-call-1',
				outcome: 'succeeded',
				result: callResponse,
			}),
		)
		.mockResolvedValueOnce(
			responseWithJSON({
				...productResponseIdentity(requestId, 4),
				kind: 'operation.resultAcknowledged',
				operationId: 'operation-call-1',
			}),
		);
}

export function productSessionBootstrap(): BridgeProductSessionBootstrap {
	return {
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
	};
}

export function workerSessionResponseIdentity(): Readonly<Record<string, unknown>> {
	return {
		paneSessionId: 'pane-session-1',
		requestId: workerSessionOpenRequestId,
		requestSequence: workerSessionOpenRequestSequence,
		wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
		workerInstanceId: 'worker-instance-1',
	};
}

export function workerSessionAcceptedResponse(
	overrides: Readonly<Record<string, unknown>> = {},
): Readonly<Record<string, unknown>> {
	return {
		...workerSessionResponseIdentity(),
		kind: 'workerSession.accepted',
		result: null,
		...overrides,
	};
}

export function workerSessionAdmittedResponse(): Readonly<Record<string, unknown>> {
	return {
		...workerSessionResponseIdentity(),
		kind: 'operation.admitted',
		operationId: 'operation-open-1',
		waitKind: 'ordinary',
	};
}

export function workerSessionResult(result: unknown): Readonly<Record<string, unknown>> {
	return {
		failureCode: null,
		kind: 'operation.result',
		operationId: 'operation-open-1',
		outcome: 'succeeded',
		result,
	};
}

export function productResponseIdentity(
	requestId: string,
	requestSequence: number,
): Readonly<Record<string, unknown>> {
	return {
		paneSessionId: 'pane-session-1',
		requestId,
		requestSequence,
		wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
		workerInstanceId: 'worker-instance-1',
	};
}

export function subscriptionOpenAcceptedResponse(
	requestId: string,
	requestSequence: number,
	subscriptionId: string,
): Readonly<Record<string, unknown>> {
	return {
		...productResponseIdentity(requestId, requestSequence),
		kind: 'subscription.openAccepted',
		subscriptionId,
		subscriptionKind: 'review.metadata',
	};
}

export function subscriptionCancelAcceptedResponse(
	requestId: string,
	requestSequence: number,
	subscriptionId: string,
): Readonly<Record<string, unknown>> {
	return {
		...productResponseIdentity(requestId, requestSequence),
		kind: 'subscription.cancelAccepted',
		subscriptionId,
		subscriptionKind: 'review.metadata',
	};
}

export function requireShiftedValue(values: string[]): string {
	const value = values.shift();
	if (value === undefined) {
		throw new Error('Test request id queue was exhausted.');
	}
	return value;
}

export function reviewSubscriptionOpenProps(
	subscriptionId: string,
	workerDerivationEpoch: number,
	signal?: AbortSignal,
): TestReviewSubscriptionOpenProps {
	return {
		...(signal === undefined ? {} : { signal }),
		subscription: { subscriptionKind: 'review.metadata' },
		subscriptionId,
		workerDerivationEpoch,
	};
}

export function reviewSubscriptionCancelProps(
	subscriptionId: string,
	workerDerivationEpoch: number,
): TestReviewSubscriptionCancelProps {
	return {
		subscriptionId,
		subscriptionKind: 'review.metadata',
		workerDerivationEpoch,
	};
}

export function responseWithJSON(value: unknown): Response {
	return new Response(JSON.stringify(value), { status: 200 });
}

export function responseWithChunks(chunks: readonly Uint8Array[]): Response {
	let chunkIndex = 0;
	return new Response(
		new ReadableStream<Uint8Array>({
			pull(controller): void {
				const chunk = chunks[chunkIndex];
				chunkIndex += 1;
				if (chunk === undefined) {
					controller.close();
					return;
				}
				controller.enqueue(chunk);
			},
		}),
		{ status: 200 },
	);
}

export function padJSONToByteLength(value: unknown, byteLength: number): Uint8Array {
	const encodedJSON = new TextEncoder().encode(JSON.stringify(value));
	if (encodedJSON.byteLength > byteLength) {
		throw new Error('Test JSON exceeds its requested padded byte length.');
	}
	const paddedJSON = new Uint8Array(byteLength);
	paddedJSON.fill(0x20);
	paddedJSON.set(encodedJSON);
	return paddedJSON;
}

export function requireUint8Array(value: BodyInit | null | undefined): Uint8Array {
	if (!(value instanceof Uint8Array)) {
		throw new Error('Expected encoded Uint8Array request body.');
	}
	return value;
}
