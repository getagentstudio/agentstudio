import { describe, expect, test } from 'vitest';
import { z } from 'zod';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import type { BridgeProductDeadlineClock } from './bridge-product-deadline-clock.js';
import {
	bridgeProductOperationLateOutcomeAcknowledgementSchema,
	bridgeProductOperationObservationRequestSchema,
} from './bridge-product-operation-observation-wire-contracts.js';
import {
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultRequestSchema,
} from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	BridgeProductControlMux,
	BridgeProductControlRequestError,
	BridgeProductSessionAuthorityStore,
} from './bridge-product-session-authority.js';
import {
	bridgeProductControlRequestSchema,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';

const commandSchema = z.union([
	bridgeProductControlRequestSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationObservationRequestSchema,
	bridgeProductOperationLateOutcomeAcknowledgementSchema,
]);

const noDeadlineClock: BridgeProductDeadlineClock = {
	schedule: (): (() => void) => (): void => {},
};

const bootstrap: BridgeProductSessionBootstrap = {
	kind: 'productSession.bootstrap' as const,
	paneSessionId: 'pane-session-late',
	policy: {
		maximumContentBytes: 2 * 1024 * 1024,
		maximumMetadataFrameBytes: 128 * 1024,
		maximumQueuedStreamBytes: 4 * 1024 * 1024,
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
		maximumQueuedStreamFrames: 64,
		maximumRequestBodyBytes: 256 * 1024,
		terminalFrameReserve: 1,
	},
	wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
	workerInstanceId: 'worker-instance-late',
};

function jsonResponse(body: object): Response {
	return new Response(JSON.stringify(body), {
		headers: { 'Content-Type': 'application/json' },
		status: 200,
	});
}

describe('Bridge product in-session late mutation outcome', () => {
	test.each(['empty', 'truncated'] as const)(
		'%s observation reply re-observes the same operation and then suspects the session',
		async (replyKind) => {
			const observedOperationIds: string[] = [];
			const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
				if (!(requestInit.body instanceof Uint8Array)) throw new Error('Missing command body.');
				const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
				if (command.kind === 'operation.observe') {
					observedOperationIds.push(command.operationId);
					return replyKind === 'empty'
						? new Response('', { status: 200 })
						: new Response('{', { headers: { 'Content-Length': '2' }, status: 200 });
				}
				if (command.kind === 'operation.result') {
					return jsonResponse({
						failureCode: null,
						kind: 'operation.result',
						operationId: command.operationId,
						outcome: command.operationId === 'operation-open' ? 'succeeded' : 'outcomeUnknown',
						result:
							command.operationId === 'operation-open'
								? {
										kind: 'workerSession.accepted',
										paneSessionId: bootstrap.paneSessionId,
										requestId: 'worker-session-open-1',
										requestSequence: 1,
										result: null,
										wireVersion: bootstrap.wireVersion,
										workerInstanceId: bootstrap.workerInstanceId,
									}
								: null,
					});
				}
				if (command.kind === 'operation.resultAcknowledgement') {
					return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
				}
				return jsonResponse({
					kind: 'operation.admitted',
					operationId: command.kind === 'workerSession.open' ? 'operation-open' : 'operation-save',
					paneSessionId: command.paneSessionId,
					requestId: command.requestId,
					requestSequence: command.requestSequence,
					waitKind: 'ordinary',
					wireVersion: command.wireVersion,
					workerInstanceId: command.workerInstanceId,
				});
			};
			const authority = new BridgeProductSessionAuthorityStore(
				executeProductRequest,
				noDeadlineClock,
			).install({
				bootstrap,
				productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
			});
			await authority.open;
			const mux = new BridgeProductControlMux({
				authority,
				deadlineClock: noDeadlineClock,
				executeProductRequest,
			});
			let unknownError: unknown = null;
			try {
				await mux.call({
					method: 'review.markFileViewed',
					request: { itemId: 'item-save' },
					workerDerivationEpoch: 1,
				});
			} catch (error: unknown) {
				unknownError = error;
			}
			if (!(unknownError instanceof BridgeProductControlRequestError)) {
				throw new Error('Expected an outcome-unknown mutation.');
			}
			const observe = unknownError.observeLateOutcome;
			if (observe === undefined) throw new Error('Late outcome observation was not offered.');
			await expect(observe()).rejects.toMatchObject({ phase: 'result' });
			expect(observedOperationIds).toEqual(
				Array.from({ length: bootstrap.policy.admissionRetryCount + 1 }, () => 'operation-save'),
			);
		},
	);

	test.each(['accepted', 'lost'] as const)(
		'stillUnknown can be observed again, and revision two acknowledgement is %s',
		async (ackReply) => {
			const secondObservationRequested = createBridgeProductDeferred<void>();
			const lateResponse = createBridgeProductDeferred<Response>();
			let productCallCount = 0;
			let observationCount = 0;
			let lateAcknowledgements = 0;
			let controlPostCount = 0;
			const suspectReasons: string[] = [];
			let callRequestId = '';
			let callRequestSequence = 0;
			const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
				if (!(requestInit.body instanceof Uint8Array)) throw new Error('Missing command body.');
				const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
				controlPostCount += 1;
				if (command.kind === 'operation.result') {
					return command.operationId === 'operation-open'
						? jsonResponse({
								failureCode: null,
								kind: 'operation.result',
								operationId: command.operationId,
								outcome: 'succeeded',
								result: {
									kind: 'workerSession.accepted',
									paneSessionId: bootstrap.paneSessionId,
									requestId: 'worker-session-open-1',
									requestSequence: 1,
									result: null,
									wireVersion: bootstrap.wireVersion,
									workerInstanceId: bootstrap.workerInstanceId,
								},
							})
						: jsonResponse({
								failureCode: null,
								kind: 'operation.result',
								operationId: command.operationId,
								outcome: 'outcomeUnknown',
								result: null,
							});
				}
				if (command.kind === 'operation.resultAcknowledgement') {
					return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
				}
				if (command.kind === 'operation.observe') {
					observationCount += 1;
					if (observationCount === 1) {
						return jsonResponse({
							kind: 'operation.stillUnknown',
							operationId: command.operationId,
							revision: command.after,
						});
					}
					secondObservationRequested.resolve();
					return await lateResponse.promise;
				}
				if (command.kind === 'operation.lateOutcomeAcknowledgement') {
					lateAcknowledgements += 1;
					return ackReply === 'lost'
						? new Response('lost', { status: 502 })
						: new Response(null, { status: 204 });
				}
				if (command.kind === 'product.call') {
					productCallCount += 1;
					callRequestId = command.requestId;
					callRequestSequence = command.requestSequence;
				}
				return jsonResponse({
					kind: 'operation.admitted',
					operationId: command.kind === 'workerSession.open' ? 'operation-open' : 'operation-save',
					paneSessionId: command.paneSessionId,
					requestId: command.requestId,
					requestSequence: command.requestSequence,
					waitKind: 'ordinary',
					wireVersion: command.wireVersion,
					workerInstanceId: command.workerInstanceId,
				});
			};
			const authority = new BridgeProductSessionAuthorityStore(
				executeProductRequest,
				noDeadlineClock,
			).install({
				bootstrap,
				productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
			});
			await authority.open;
			const mux = new BridgeProductControlMux({
				authority,
				createRequestId: (() => {
					let requestCount = 0;
					return (): string => `late-request-${++requestCount}`;
				})(),
				deadlineClock: noDeadlineClock,
				executeProductRequest,
				onSessionSuspect: (reason): void => {
					suspectReasons.push(reason);
				},
			});
			let unknownError: unknown = null;
			try {
				await mux.call({
					method: 'review.markFileViewed',
					request: { itemId: 'item-save' },
					workerDerivationEpoch: 1,
				});
			} catch (error: unknown) {
				unknownError = error;
			}
			expect(unknownError).toMatchObject({ outcome: 'outcomeUnknown' });
			if (!(unknownError instanceof BridgeProductControlRequestError)) return;
			const observeLateOutcome = unknownError.observeLateOutcome;
			expect(observeLateOutcome).toBeDefined();
			if (observeLateOutcome === undefined) return;
			const pendingLate = observeLateOutcome();
			await secondObservationRequested.promise;
			lateResponse.resolve(
				jsonResponse({
					failureCode: null,
					kind: 'operation.lateOutcome',
					operationId: 'operation-save',
					outcome: 'succeeded',
					result: {
						call: { method: 'review.markFileViewed', result: null },
						kind: 'call.completed',
						paneSessionId: bootstrap.paneSessionId,
						requestId: callRequestId,
						requestSequence: callRequestSequence,
						wireVersion: bootstrap.wireVersion,
						workerInstanceId: bootstrap.workerInstanceId,
					},
					revision: 2,
				}),
			);
			const observed = await pendingLate;
			expect(observed.evidence.revision).toBe(2);
			expect(observationCount).toBe(2);
			expect(productCallCount).toBe(1);
			if (ackReply === 'accepted') {
				await observed.acknowledge();
				expect(lateAcknowledgements).toBe(1);
				expect(suspectReasons).toEqual([]);
			} else {
				await expect(observed.acknowledge()).rejects.toMatchObject({ phase: 'admission' });
				expect(lateAcknowledgements).toBe(bootstrap.policy.admissionRetryCount + 1);
				expect(suspectReasons).toEqual(['admissionReplyExhausted']);
				const postsBeforeFencedCall = controlPostCount;
				await expect(
					mux.call({
						method: 'review.markFileViewed',
						request: { itemId: 'item-after-lost-ack' },
						workerDerivationEpoch: 1,
					}),
				).rejects.toMatchObject({ phase: 'admission' });
				expect(controlPostCount).toBe(postsBeforeFencedCall);
			}
		},
	);
});
