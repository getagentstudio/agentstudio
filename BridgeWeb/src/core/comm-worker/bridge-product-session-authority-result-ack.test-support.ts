import { expect } from 'vitest';
import { z } from 'zod';

import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
} from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	BridgeProductControlMux,
	BridgeProductSessionAuthorityStore,
} from './bridge-product-session-authority.js';
import {
	bridgeProductControlRequestSchema,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';
import type {
	BridgeWorkerAckAttemptOutcome,
	BridgeWorkerPriorControlRequest,
} from './bridge-worker-contracts.js';

export const commandSchema = z.union([
	bridgeProductControlRequestSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultAcknowledgementSchema,
]);
export const clock: BridgeProductDeadlineClock = { schedule: () => (): void => {} };
export const bootstrap: BridgeProductSessionBootstrap = {
	kind: 'productSession.bootstrap',
	paneSessionId: 'pane-result-ack',
	policy: {
		admissionRetryCount: 2,
		contentAcknowledgementDeadlineMilliseconds: 5_000,
		contentProgressDeadlineMilliseconds: 5_000,
		viewBatchProgressDeadlineMilliseconds: 5_000,
		streamKeepaliveIntervalMilliseconds: 350,
		maximumContentBytes: 2 * 1024 * 1024,
		maximumMetadataFrameBytes: 128 * 1024,
		maximumQueuedStreamBytes: 4 * 1024 * 1024,
		maximumQueuedStreamFrames: 64,
		maximumRequestBodyBytes: 256 * 1024,
		terminalFrameReserve: 1,
		telemetryPreReadyBufferMaxBytes: 64 * 1024,
		telemetryPreReadyBufferMaxSamples: 128,
		workerSettlementDeadlineMilliseconds: 5_000,
		viewAcknowledgementDeadlineMilliseconds: 4_000,
		viewCreditBytes: 524_288,
		viewCreditParts: 8,
		viewMaximumConsecutiveResnapshots: 3,
		viewMaximumDirtyKeys: 4_096,
	},
	wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
	workerInstanceId: 'worker-result-ack',
};

export function jsonResponse(value: object): Response {
	return new Response(JSON.stringify(value), {
		headers: { 'Content-Type': 'application/json' },
		status: 200,
	});
}

export function createExecutor(props: {
	readonly acknowledgementBodies: string[];
	readonly loseAcknowledgements: boolean;
	readonly acknowledgementReply?: (body: string) => Response;
}): BridgeProductRequestExecutor {
	let lastAdmittedRequest = { requestId: 'worker-session-open-1', requestSequence: 1 };
	return async (_route, requestInit): Promise<Response> => {
		if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected encoded body.');
		const body = new TextDecoder().decode(requestInit.body);
		const command = commandSchema.parse(JSON.parse(body));
		if (command.kind === 'operation.result') {
			const opening = command.operationId === 'operation-open';
			return jsonResponse({
				failureCode: null,
				kind: 'operation.result',
				operationId: command.operationId,
				outcome: 'succeeded',
				result: opening
					? {
							kind: 'workerSession.accepted',
							requestId: lastAdmittedRequest.requestId,
							requestSequence: lastAdmittedRequest.requestSequence,
							result: null,
							...sessionIdentity,
						}
					: {
							call: { method: 'review.markFileViewed', result: null },
							kind: 'call.completed',
							requestId: lastAdmittedRequest.requestId,
							requestSequence: lastAdmittedRequest.requestSequence,
							...sessionIdentity,
						},
			});
		}
		if (command.kind === 'operation.resultAcknowledgement') {
			if (command.operationId === 'operation-save') {
				props.acknowledgementBodies.push(body);
				if (props.acknowledgementReply !== undefined) return props.acknowledgementReply(body);
				if (props.loseAcknowledgements) return new Response('lost', { status: 502 });
			}
			return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
		}
		lastAdmittedRequest = {
			requestId: command.requestId,
			requestSequence: command.requestSequence,
		};
		return jsonResponse({
			kind: 'operation.admitted',
			operationId: command.kind === 'workerSession.open' ? 'operation-open' : 'operation-save',
			waitKind: 'ordinary',
			requestId: command.requestId,
			requestSequence: command.requestSequence,
			...sessionIdentity,
		});
	};
}

const sessionIdentity = {
	paneSessionId: bootstrap.paneSessionId,
	wireVersion: bootstrap.wireVersion,
	workerInstanceId: bootstrap.workerInstanceId,
} as const;

export async function callOnSession(props: {
	readonly acknowledgementBodies: string[];
	readonly loseAcknowledgements: boolean;
	readonly acknowledgementReply?: (body: string) => Response;
	readonly onSessionSuspect?: (
		reason: 'admissionReplyExhausted' | 'resultAcknowledgementExhausted',
		ackAttemptOutcomes: readonly BridgeWorkerAckAttemptOutcome[],
		priorControlRequests: readonly BridgeWorkerPriorControlRequest[],
		droppedPriorControlRequestCount: number,
	) => void;
}): Promise<BridgeProductControlMux> {
	const executeProductRequest = createExecutor(props);
	const authority = new BridgeProductSessionAuthorityStore(executeProductRequest, clock).install({
		bootstrap,
		productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
	});
	const mux = new BridgeProductControlMux({
		authority,
		createRequestId: (): string => 'request-1',
		deadlineClock: clock,
		executeProductRequest,
		...(props.onSessionSuspect === undefined ? {} : { onSessionSuspect: props.onSessionSuspect }),
	});
	await authority.open;
	await expect(
		mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'review-item-1' },
			workerDerivationEpoch: 1,
		}),
	).resolves.toBeNull();
	return mux;
}
