import { describe, expect, test } from 'vitest';
import { z } from 'zod';

import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
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
	BridgeProductSessionSuspectError,
} from './bridge-product-session-authority.js';
import {
	bridgeProductControlRequestSchema,
	type BridgeProductSessionBootstrap,
} from './bridge-product-session-contracts.js';

const commandSchema = z.union([
	bridgeProductControlRequestSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultAcknowledgementSchema,
]);

const noDeadlineClock: BridgeProductDeadlineClock = {
	schedule: (): (() => void) => (): void => {},
};

const bootstrap: BridgeProductSessionBootstrap = {
	kind: 'productSession.bootstrap',
	paneSessionId: 'pane-session-v2',
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
	workerInstanceId: 'worker-instance-v2',
};

describe('Bridge product v2 control admission', () => {
	test.each(['empty', 'truncated'] as const)(
		'%s operation result reply retries the same operation id and then suspects the session',
		async (replyKind) => {
			const resultOperationIds: string[] = [];
			const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
				if (!(requestInit.body instanceof Uint8Array)) throw new Error('Missing command body.');
				const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
				if (command.kind === 'operation.result') {
					resultOperationIds.push(command.operationId);
					return replyKind === 'empty'
						? new Response('', { status: 200 })
						: new Response('{', { headers: { 'Content-Length': '2' }, status: 200 });
				}
				return jsonResponse({
					...commandCorrelation(command),
					kind: 'operation.admitted',
					operationId: 'operation-open',
					waitKind: 'ordinary',
				});
			};
			const authority = new BridgeProductSessionAuthorityStore(
				executeProductRequest,
				noDeadlineClock,
			).install({
				bootstrap,
				productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
			});
			await expect(authority.open).rejects.toMatchObject({ phase: 'result' });
			expect(resultOperationIds).toEqual(
				Array.from({ length: bootstrap.policy.admissionRetryCount + 1 }, () => 'operation-open'),
			);
		},
	);

	test('a lost acknowledgement cannot replace a known succeeded mutation result', async () => {
		const replayedAck = createBridgeProductDeferred<void>();
		const acknowledgementBodies: string[] = [];
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Bridge product command did not send encoded bytes.');
			}
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
								...sessionIdentity,
								kind: 'workerSession.accepted',
								requestId: 'worker-session-open-1',
								requestSequence: 1,
								result: null,
							}
						: {
								...sessionIdentity,
								call: { method: 'review.markFileViewed', result: null },
								kind: 'call.completed',
								requestId: 'request-1',
								requestSequence: 3,
							},
				});
			}
			if (command.kind === 'operation.resultAcknowledgement') {
				if (command.operationId === 'operation-save') {
					acknowledgementBodies.push(body);
					if (acknowledgementBodies.length === 1) {
						return new Response('gateway lost reply', { status: 502 });
					}
					replayedAck.resolve();
				}
				return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
			}
			return jsonResponse({
				...commandCorrelation(command),
				kind: 'operation.admitted',
				operationId: command.kind === 'workerSession.open' ? 'operation-open' : 'operation-save',
				waitKind: 'ordinary',
			});
		};
		const authority = new BridgeProductSessionAuthorityStore(
			executeProductRequest,
			noDeadlineClock,
		).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => 'request-1',
			deadlineClock: noDeadlineClock,
			executeProductRequest,
		});
		await authority.open;
		await expect(
			mux.call({
				method: 'review.markFileViewed',
				request: { itemId: 'review-item-1' },
				workerDerivationEpoch: 1,
			}),
		).resolves.toBeNull();
		await replayedAck.promise;
		expect(acknowledgementBodies).toHaveLength(2);
		expect(acknowledgementBodies[1]).toBe(acknowledgementBodies[0]);
	});

	test('an unanswered operation result does not hold the next admission or result', async () => {
		const heldResult = createBridgeProductDeferred<Response>();
		const heldResultRequested = createBridgeProductDeferred<void>();
		const admittedSequences: number[] = [];
		const acknowledgedOperations: string[] = [];
		let productCallCount = 0;
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Bridge product command did not send encoded bytes.');
			}
			const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
			if (command.kind === 'operation.result') {
				if (command.operationId === 'operation-held') {
					heldResultRequested.resolve();
					return await heldResult.promise;
				}
				const originalRequest =
					command.operationId === 'operation-open'
						? {
								kind: 'workerSession.accepted',
								result: null,
								requestId: 'worker-session-open-1',
								requestSequence: 1,
							}
						: {
								kind: 'call.completed',
								call: { method: 'review.markFileViewed', result: null },
								requestId: 'request-2',
								requestSequence: 4,
							};
				return jsonResponse({
					failureCode: null,
					kind: 'operation.result',
					operationId: command.operationId,
					outcome: 'succeeded',
					result: { ...originalRequest, ...sessionIdentity },
				});
			}
			if (command.kind === 'operation.resultAcknowledgement') {
				acknowledgedOperations.push(command.operationId);
				return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
			}
			admittedSequences.push(command.requestSequence);
			if (command.kind === 'product.call') productCallCount += 1;
			const operationId =
				command.kind === 'workerSession.open'
					? 'operation-open'
					: productCallCount === 1
						? 'operation-held'
						: 'operation-second';
			return jsonResponse({
				...commandCorrelation(command),
				kind: 'operation.admitted',
				operationId,
				waitKind: 'ordinary',
			});
		};
		const authority = new BridgeProductSessionAuthorityStore(
			executeProductRequest,
			noDeadlineClock,
		).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (() => {
				let requestCount = 0;
				return (): string => `request-${++requestCount}`;
			})(),
			deadlineClock: noDeadlineClock,
			executeProductRequest,
		});
		await authority.open;
		const first = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'item-held' },
			workerDerivationEpoch: 1,
		});
		await heldResultRequested.promise;
		await expect(
			mux.call({
				method: 'review.markFileViewed',
				request: { itemId: 'item-second' },
				workerDerivationEpoch: 1,
			}),
		).resolves.toBeNull();
		await mux.waitForAcknowledgementsQuiescent();
		expect(admittedSequences).toEqual([1, 3, 4]);
		expect(acknowledgedOperations).toEqual(['operation-open', 'operation-second']);

		heldResult.resolve(
			jsonResponse({
				failureCode: null,
				kind: 'operation.result',
				operationId: 'operation-held',
				outcome: 'succeeded',
				result: {
					...sessionIdentity,
					call: { method: 'review.markFileViewed', result: null },
					kind: 'call.completed',
					requestId: 'request-1',
					requestSequence: 3,
				},
			}),
		);
		await expect(first).resolves.toBeNull();
		await mux.waitForAcknowledgementsQuiescent();
		expect(acknowledgedOperations).toEqual([
			'operation-open',
			'operation-second',
			'operation-held',
		]);
	});

	test('a lost admission reply resends identical bytes and consumes the operation once', async () => {
		const firstAttemptSeen = createBridgeProductDeferred<void>();
		const secondAttemptSeen = createBridgeProductDeferred<void>();
		const clock = new ManualDeadlineClock();
		const admissionBodies: string[] = [];
		let resultReads = 0;
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Bridge product command did not send encoded bytes.');
			}
			const body = new TextDecoder().decode(requestInit.body);
			const command = commandSchema.parse(JSON.parse(body));
			if (command.kind === 'operation.result') {
				resultReads += 1;
				return jsonResponse({
					failureCode: null,
					kind: 'operation.result',
					operationId: 'operation-replayed',
					outcome: 'succeeded',
					result: {
						...sessionIdentity,
						kind: 'workerSession.accepted',
						requestId: 'worker-session-open-1',
						requestSequence: 1,
						result: null,
					},
				});
			}
			if (command.kind === 'operation.resultAcknowledgement') {
				return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
			}
			admissionBodies.push(body);
			if (admissionBodies.length === 1) {
				firstAttemptSeen.resolve();
				return await new Promise<Response>(() => {});
			}
			secondAttemptSeen.resolve();
			return jsonResponse({
				...commandCorrelation(command),
				kind: 'operation.admitted',
				operationId: 'operation-replayed',
				waitKind: 'ordinary',
			});
		};
		const authority = new BridgeProductSessionAuthorityStore(executeProductRequest, clock).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		await firstAttemptSeen.promise;
		expect(clock.fireNext()).toBe(true);
		await secondAttemptSeen.promise;
		await expect(authority.open).resolves.toBeUndefined();
		expect(admissionBodies).toHaveLength(2);
		expect(admissionBodies[1]).toBe(admissionBodies[0]);
		expect(resultReads).toBe(1);
	});

	test('exhausted lost admission replies settle as one typed suspect declaration', async () => {
		const clock = new ManualDeadlineClock();
		const attemptSeen = [
			createBridgeProductDeferred<void>(),
			createBridgeProductDeferred<void>(),
			createBridgeProductDeferred<void>(),
		];
		const exactBodies: string[] = [];
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Bridge product command did not send encoded bytes.');
			}
			const body = new TextDecoder().decode(requestInit.body);
			const command = commandSchema.parse(JSON.parse(body));
			if (command.kind !== 'workerSession.open') {
				throw new Error('The unaccepted worker session cannot request a result.');
			}
			exactBodies.push(body);
			attemptSeen[exactBodies.length - 1]?.resolve();
			return await new Promise<Response>(() => {});
		};
		const authority = new BridgeProductSessionAuthorityStore(executeProductRequest, clock).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		for (const attempt of attemptSeen) {
			await attempt.promise;
			expect(clock.fireNext()).toBe(true);
		}
		await expect(authority.open).rejects.toMatchObject({
			name: 'BridgeProductSessionSuspectError',
			phase: 'admission',
			shouldNotify: true,
		} satisfies Partial<BridgeProductSessionSuspectError>);
		expect(exactBodies).toHaveLength(3);
		expect(new Set(exactBodies).size).toBe(1);
	});

	test.each([
		{ label: 'HTTP 502', status: 502 },
		{ label: 'unparseable HTTP 200', status: 200 },
	])(
		'ambiguous $label admission replies replay exact bytes before suspect settlement',
		async ({ status }) => {
			const admissionBodies: string[] = [];
			const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
				if (!(requestInit.body instanceof Uint8Array)) {
					throw new Error('Bridge product command did not send encoded bytes.');
				}
				const body = new TextDecoder().decode(requestInit.body);
				const command = commandSchema.parse(JSON.parse(body));
				if (command.kind !== 'workerSession.open') {
					throw new Error('An unaccepted worker session cannot issue a result request.');
				}
				admissionBodies.push(body);
				return new Response('not a typed admission', { status });
			};
			const authority = new BridgeProductSessionAuthorityStore(
				executeProductRequest,
				noDeadlineClock,
			).install({
				bootstrap,
				productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
			});
			await expect(authority.open).rejects.toMatchObject({
				name: 'BridgeProductSessionSuspectError',
				phase: 'admission',
			});
			expect(admissionBodies).toHaveLength(bootstrap.policy.admissionRetryCount + 1);
			expect(new Set(admissionBodies).size).toBe(1);
		},
	);

	test('a typed HTTP 409 admission refusal is final and is not replayed', async () => {
		let admissionCount = 0;
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Bridge product command did not send encoded bytes.');
			}
			const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
			if (command.kind !== 'workerSession.open') {
				throw new Error('A refused worker session cannot issue a result request.');
			}
			admissionCount += 1;
			return new Response(
				JSON.stringify({
					...commandCorrelation(command),
					code: 'unauthorized',
					kind: 'request.error',
					nextExpectedRequestSequence: null,
					retryAfterMilliseconds: null,
					retryable: false,
					safeMessage: null,
				}),
				{ headers: { 'Content-Type': 'application/json' }, status: 409 },
			);
		};
		const authority = new BridgeProductSessionAuthorityStore(
			executeProductRequest,
			noDeadlineClock,
		).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		await expect(authority.open).rejects.toThrow(/was refused/iu);
		expect(admissionCount).toBe(1);
	});

	test('a lost result reply settles as a typed session-suspect declaration', async () => {
		const clock = new ManualDeadlineClock();
		const resultReadAttempts = Array.from(
			{ length: bootstrap.policy.admissionRetryCount + 1 },
			() => createBridgeProductDeferred<void>(),
		);
		let resultReadCount = 0;
		const executeProductRequest: BridgeProductRequestExecutor = async (_route, requestInit) => {
			if (!(requestInit.body instanceof Uint8Array)) {
				throw new Error('Bridge product command did not send encoded bytes.');
			}
			const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
			if (command.kind === 'operation.result') {
				if (command.operationId === 'operation-open') {
					return jsonResponse({
						failureCode: null,
						kind: 'operation.result',
						operationId: command.operationId,
						outcome: 'succeeded',
						result: {
							...sessionIdentity,
							kind: 'workerSession.accepted',
							requestId: 'worker-session-open-1',
							requestSequence: 1,
							result: null,
						},
					});
				}
				resultReadAttempts[resultReadCount]?.resolve();
				resultReadCount += 1;
				return await new Promise<Response>(() => {});
			}
			if (command.kind === 'operation.resultAcknowledgement') {
				return jsonResponse({ ...command, kind: 'operation.resultAcknowledged' });
			}
			return jsonResponse({
				...commandCorrelation(command),
				kind: 'operation.admitted',
				operationId: command.kind === 'workerSession.open' ? 'operation-open' : 'operation-held',
				waitKind: 'ordinary',
			});
		};
		const authority = new BridgeProductSessionAuthorityStore(executeProductRequest, clock).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		await authority.open;
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => 'held-result-call',
			deadlineClock: clock,
			executeProductRequest,
		});
		const call = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'item-held-result' },
			workerDerivationEpoch: 1,
		});
		for (const attempt of resultReadAttempts) {
			await attempt.promise;
			expect(clock.fireNext()).toBe(true);
		}
		await expect(call).rejects.toMatchObject({
			name: 'BridgeProductSessionSuspectError',
			phase: 'result',
			shouldNotify: true,
		} satisfies Partial<BridgeProductSessionSuspectError>);
	});
});

class ManualDeadlineClock implements BridgeProductDeadlineClock {
	readonly #scheduled: Array<{ active: boolean; onDeadline: () => void }> = [];

	schedule(_delayMilliseconds: number, onDeadline: () => void): () => void {
		const deadline = { active: true, onDeadline };
		this.#scheduled.push(deadline);
		return (): void => {
			deadline.active = false;
		};
	}

	fireNext(): boolean {
		const next = this.#scheduled.find((deadline): boolean => deadline.active);
		if (next === undefined) return false;
		next.active = false;
		next.onDeadline();
		return true;
	}
}

const sessionIdentity = {
	paneSessionId: bootstrap.paneSessionId,
	wireVersion: bootstrap.wireVersion,
	workerInstanceId: bootstrap.workerInstanceId,
} as const;

function commandCorrelation(command: {
	readonly paneSessionId: string;
	readonly requestId: string;
	readonly requestSequence: number;
	readonly wireVersion: number;
	readonly workerInstanceId: string;
}): Readonly<Record<string, string | number>> {
	return {
		paneSessionId: command.paneSessionId,
		requestId: command.requestId,
		requestSequence: command.requestSequence,
		wireVersion: command.wireVersion,
		workerInstanceId: command.workerInstanceId,
	};
}

function jsonResponse(body: object): Response {
	return new Response(JSON.stringify(body), {
		headers: { 'Content-Type': 'application/json' },
		status: 200,
	});
}
