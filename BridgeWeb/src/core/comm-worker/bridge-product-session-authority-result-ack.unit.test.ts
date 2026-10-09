import { describe, expect, test } from 'vitest';

import { BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH } from './bridge-product-contract-primitives.js';
import { bridgeProductOperationResultAcknowledgementSchema } from './bridge-product-operation-wire-contracts.js';
import type { BridgeProductRequestExecutor } from './bridge-product-request-executor.js';
import {
	bootstrap,
	callOnSession,
	clock,
	commandSchema,
	createExecutor,
	jsonResponse,
} from './bridge-product-session-authority-result-ack.test-support.js';
import {
	BridgeProductControlMux,
	BridgeProductSessionAuthorityStore,
} from './bridge-product-session-authority.js';
import { bridgeProductControlRequestSchema } from './bridge-product-session-contracts.js';
import type {
	BridgeWorkerAckAttemptOutcome,
	BridgeWorkerPriorControlRequest,
} from './bridge-worker-contracts.js';

describe('Bridge product result acknowledgement owner', () => {
	test('exhausted exact ack replay declares suspect once after delivering success', async () => {
		const acknowledgementBodies: string[] = [];
		const suspectEvents: {
			readonly reason: string;
			readonly outcomes: readonly BridgeWorkerAckAttemptOutcome[];
			readonly priorControls: readonly BridgeWorkerPriorControlRequest[];
			readonly dropped: number;
		}[] = [];
		const oldSession = await callOnSession({
			acknowledgementBodies,
			loseAcknowledgements: true,
			onSessionSuspect: (reason, outcomes, priorControls, dropped): void => {
				suspectEvents.push({ reason, outcomes, priorControls, dropped });
			},
		});
		await oldSession.waitForAcknowledgementsQuiescent();
		expect(acknowledgementBodies).toHaveLength(bootstrap.policy.admissionRetryCount + 1);
		expect(new Set(acknowledgementBodies).size).toBe(1);
		expect(suspectEvents).toEqual([
			{
				dropped: 0,
				reason: 'resultAcknowledgementExhausted',
				outcomes: Array.from({ length: 3 }, () => ({
					kind: 'httpStatus',
					code: 502,
					requestSequence: 4,
				})),
				priorControls: [
					{ kind: 'product.call', requestSequence: 3, outcome: 'ok', attemptOutcomes: [] },
				],
			},
		]);
		expect(oldSession.diagnosticSnapshot.pendingAcknowledgementCount).toBe(0);

		const successorBodies: string[] = [];
		const successor = await callOnSession({
			acknowledgementBodies: successorBodies,
			loseAcknowledgements: false,
		});
		await successor.waitForAcknowledgementsQuiescent();
		expect(successorBodies).toHaveLength(1);
	});

	test.each([
		{
			name: 'empty native HTTP refusal',
			reply: (): Response => new Response(null, { status: 400 }),
			expected: { kind: 'httpStatus', code: 400, requestSequence: 4 },
		},
		{
			name: 'typed native refusal',
			reply: (body: string): Response => {
				const request = bridgeProductOperationResultAcknowledgementSchema.parse(JSON.parse(body));
				return new Response(
					JSON.stringify({
						kind: 'operation.resultAckRefused',
						operationId: request.operationId,
						paneSessionId: request.paneSessionId,
						requestId: request.requestId,
						requestSequence: request.requestSequence,
						refusalKind: 'requestSequenceRejected',
						replayRejectionKind: 'sequenceConflict',
						nextExpectedRequestSequence: 5,
						wireVersion: request.wireVersion,
						workerInstanceId: request.workerInstanceId,
					}),
					{ status: 400 },
				);
			},
			expected: {
				kind: 'nativeRefusal',
				refusalKind: 'requestSequenceRejected',
				replayRejectionKind: 'sequenceConflict',
				nextExpectedRequestSequence: 5,
				requestSequence: 4,
			},
		},
		{
			name: 'malformed success',
			reply: (): Response => new Response('{', { status: 200 }),
			expected: { kind: 'parseFailure', requestSequence: 4 },
		},
		{
			name: 'mismatched success',
			reply: (body: string): Response => {
				const request = bridgeProductOperationResultAcknowledgementSchema.parse(JSON.parse(body));
				return jsonResponse({
					...request,
					kind: 'operation.resultAcknowledged',
					operationId: 'other',
				});
			},
			expected: { kind: 'identityMismatch', requestSequence: 4 },
		},
		{
			name: 'over-limit success',
			reply: (): Response => new Response('x'.repeat(300_000), { status: 200 }),
			expected: { kind: 'responseSizeLimit', requestSequence: 4 },
			expectedAttempts: 1,
		},
	])('records each $name attempt before declaring suspect', async (scenario) => {
		const expectedAttempts = 'expectedAttempts' in scenario ? scenario.expectedAttempts : 3;
		const acknowledgementBodies: string[] = [];
		const outcomes: BridgeWorkerAckAttemptOutcome[][] = [];
		const session = await callOnSession({
			acknowledgementBodies,
			acknowledgementReply: scenario.reply,
			loseAcknowledgements: false,
			onSessionSuspect: (_reason, attempts): void => {
				outcomes.push([...attempts]);
			},
		});
		await session.waitForAcknowledgementsQuiescent();
		expect(acknowledgementBodies).toHaveLength(expectedAttempts);
		expect(outcomes).toEqual([Array.from({ length: expectedAttempts }, () => scenario.expected)]);
	});

	test('retains the last sixteen control outcomes and reports dropped history before a failed ack', async () => {
		let successfulAcknowledgements = 0;
		const snapshots: {
			readonly priorControls: readonly BridgeWorkerPriorControlRequest[];
			readonly dropped: number;
		}[] = [];
		const session = await callOnSession({
			acknowledgementBodies: [],
			loseAcknowledgements: false,
			acknowledgementReply: (body): Response => {
				if (successfulAcknowledgements === 17) return new Response('lost', { status: 502 });
				successfulAcknowledgements += 1;
				const request = bridgeProductOperationResultAcknowledgementSchema.parse(JSON.parse(body));
				return jsonResponse({ ...request, kind: 'operation.resultAcknowledged' });
			},
			onSessionSuspect: (_reason, _outcomes, priorControls, dropped): void => {
				snapshots.push({ priorControls, dropped });
			},
		});
		await session.waitForAcknowledgementsQuiescent();
		for (let index = 0; index < 17; index += 1) {
			// oxlint-disable-next-line eslint/no-await-in-loop -- Each result ack establishes the next wire sequence.
			await session.call({
				method: 'review.markFileViewed',
				request: { itemId: 'review-item-1' },
				workerDerivationEpoch: 1,
			});
			// oxlint-disable-next-line eslint/no-await-in-loop -- The ack owner announces quiescence without a timer.
			await session.waitForAcknowledgementsQuiescent();
		}
		expect(snapshots).toHaveLength(1);
		expect(snapshots[0]?.dropped).toBe(2);
		expect(snapshots[0]?.priorControls).toHaveLength(16);
		expect(snapshots[0]?.priorControls[0]).toEqual({
			attemptOutcomes: [],
			kind: 'product.call',
			outcome: 'ok',
			requestSequence: 7,
		});
		expect(snapshots[0]?.priorControls.at(-1)).toEqual({
			attemptOutcomes: [],
			kind: 'product.call',
			outcome: 'ok',
			requestSequence: 37,
		});
	});

	test('a malformed accepted escape reply replays before a pending result ack takes its sequence', async () => {
		const baseExecutor = createExecutor({ acknowledgementBodies: [], loseAcknowledgements: false });
		let nativeNextSequence = 1;
		let cancelAttempts = 0;
		const ackSequences: number[] = [];
		const suspectAttempts: BridgeWorkerAckAttemptOutcome[][] = [];
		let releaseResult: () => void = (): void => {};
		const resultMaySettle = new Promise<void>((resolve): void => {
			releaseResult = resolve;
		});
		let reportCallAdmitted: () => void = (): void => {};
		const callAdmitted = new Promise<void>((resolve): void => {
			reportCallAdmitted = resolve;
		});
		const executor: BridgeProductRequestExecutor = async (
			route,
			requestInit,
		): Promise<Response> => {
			if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected encoded body.');
			const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
			if (command.kind === 'operation.result' && command.operationId === 'operation-save') {
				await resultMaySettle;
			}
			if (command.kind === 'operation.resultAcknowledgement') {
				ackSequences.push(command.requestSequence);
				if (command.requestSequence !== nativeNextSequence) {
					return new Response(
						JSON.stringify({
							kind: 'operation.resultAckRefused',
							nextExpectedRequestSequence: nativeNextSequence,
							operationId: command.operationId,
							paneSessionId: command.paneSessionId,
							replayRejectionKind: 'sequenceConflict',
							refusalKind: 'requestSequenceRejected',
							requestId: command.requestId,
							requestSequence: command.requestSequence,
							wireVersion: command.wireVersion,
							workerInstanceId: command.workerInstanceId,
						}),
						{ status: 400 },
					);
				}
				nativeNextSequence += 1;
			}
			if (command.kind === 'workerSession.open' || command.kind === 'product.call') {
				expect(command.requestSequence).toBe(nativeNextSequence);
				nativeNextSequence += 1;
				if (command.kind === 'product.call') reportCallAdmitted();
			}
			if (command.kind === 'subscription.cancel') {
				expect(command.requestSequence).toBe(nativeNextSequence - (cancelAttempts > 0 ? 1 : 0));
				cancelAttempts += 1;
				if (cancelAttempts === 1) {
					nativeNextSequence += 1;
					return new Response('{', { status: 200 });
				}
				return jsonResponse({
					kind: 'subscription.cancelAccepted',
					paneSessionId: command.paneSessionId,
					requestId: command.requestId,
					requestSequence: command.requestSequence,
					subscriptionId: command.subscriptionId,
					subscriptionKind: command.subscriptionKind,
					wireVersion: command.wireVersion,
					workerInstanceId: command.workerInstanceId,
				});
			}
			return await baseExecutor(route, requestInit);
		};
		const authority = new BridgeProductSessionAuthorityStore(executor, clock).install({
			bootstrap,
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		const mux = new BridgeProductControlMux({
			authority,
			deadlineClock: clock,
			executeProductRequest: executor,
			onSessionSuspect: (_reason, attempts): void => {
				suspectAttempts.push([...attempts]);
			},
		});
		await authority.open;
		const call = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'review-item-1' },
			workerDerivationEpoch: 1,
		});
		await callAdmitted;
		const cancelOutcome = mux
			.cancelSubscription({
				subscriptionId: 'review-subscription-1',
				subscriptionKind: 'review.metadata',
				workerDerivationEpoch: 1,
			})
			.then(
				(): 'accepted' => 'accepted',
				(): 'rejected' => 'rejected',
			);
		const cancellation = await cancelOutcome;
		releaseResult();
		await call;
		await mux.waitForAcknowledgementsQuiescent();
		expect(ackSequences.at(-1)).toBe(5);
		expect(cancellation).toBe('accepted');
		expect(cancelAttempts).toBe(2);
		expect(suspectAttempts).toEqual([]);
	});

	test.each([
		'wrongCorrelationThenReplay',
		'exhaustedLostReply',
		'callerAbortAfterNativeAccept',
	] as const)(
		'an ambiguous setScope %s preserves the pending result ack sequence',
		async (faultKind) => {
			const baseExecutor = createExecutor({
				acknowledgementBodies: [],
				loseAcknowledgements: false,
			});
			let nativeNextSequence = 1;
			let setScopeAttempts = 0;
			const scopeAbort = new AbortController();
			const ackSequences: number[] = [];
			const suspectFacts: Array<{
				readonly reason: string;
				readonly priorControls: readonly BridgeWorkerPriorControlRequest[];
			}> = [];
			let releaseResult: () => void = (): void => {};
			const resultMaySettle = new Promise<void>((resolve): void => {
				releaseResult = resolve;
			});
			let reportCallAdmitted: () => void = (): void => {};
			const callAdmitted = new Promise<void>((resolve): void => {
				reportCallAdmitted = resolve;
			});
			let acceptedScope: ReturnType<typeof bridgeProductControlRequestSchema.parse> | null = null;
			const executor: BridgeProductRequestExecutor = async (
				route,
				requestInit,
			): Promise<Response> => {
				if (!(requestInit.body instanceof Uint8Array)) throw new Error('Expected encoded body.');
				const command = commandSchema.parse(JSON.parse(new TextDecoder().decode(requestInit.body)));
				if (command.kind === 'operation.result' && command.operationId === 'operation-save') {
					await resultMaySettle;
				}
				if (command.kind === 'operation.result' && command.operationId === 'operation-scope') {
					if (acceptedScope?.kind !== 'subscription.setScope')
						throw new Error('Expected scope admission.');
					const scope = acceptedScope;
					return jsonResponse({
						failureCode: null,
						kind: 'operation.result',
						operationId: command.operationId,
						outcome: 'succeeded',
						result: {
							domain: scope.domain,
							handle: scope.handle,
							incarnation: scope.incarnation,
							kind: 'subscription.scopeAccepted',
							paneSessionId: scope.paneSessionId,
							requestId: scope.requestId,
							requestSequence: scope.requestSequence,
							scopeRevision: scope.scopeRevision,
							subscriptionId: scope.subscriptionId,
							subscriptionKind: scope.subscriptionKind,
							wireVersion: scope.wireVersion,
							workerInstanceId: scope.workerInstanceId,
						},
					});
				}
				if (command.kind === 'operation.resultAcknowledgement') {
					ackSequences.push(command.requestSequence);
					if (command.requestSequence !== nativeNextSequence) {
						return new Response(
							JSON.stringify({
								kind: 'operation.resultAckRefused',
								nextExpectedRequestSequence: nativeNextSequence,
								operationId: command.operationId,
								paneSessionId: command.paneSessionId,
								replayRejectionKind: 'sequenceConflict',
								refusalKind: 'requestSequenceRejected',
								requestId: command.requestId,
								requestSequence: command.requestSequence,
								wireVersion: command.wireVersion,
								workerInstanceId: command.workerInstanceId,
							}),
							{ status: 400 },
						);
					}
					nativeNextSequence += 1;
				}
				if (command.kind === 'workerSession.open' || command.kind === 'product.call') {
					expect(command.requestSequence).toBe(nativeNextSequence);
					nativeNextSequence += 1;
					if (command.kind === 'product.call') reportCallAdmitted();
				}
				if (command.kind === 'subscription.setScope') {
					expect(command.requestSequence).toBe(4);
					setScopeAttempts += 1;
					if (setScopeAttempts === 1) {
						expect(nativeNextSequence).toBe(4);
						nativeNextSequence = 5;
						acceptedScope = command;
						if (faultKind === 'callerAbortAfterNativeAccept') {
							scopeAbort.abort();
							return new Response('lost', { status: 502 });
						}
					}
					if (faultKind === 'exhaustedLostReply') return new Response('lost', { status: 502 });
					return jsonResponse({
						kind: 'operation.admitted',
						operationId: 'operation-scope',
						paneSessionId: command.paneSessionId,
						requestId: setScopeAttempts === 1 ? 'wrong-correlation' : command.requestId,
						requestSequence: command.requestSequence,
						waitKind: 'ordinary',
						wireVersion: command.wireVersion,
						workerInstanceId: command.workerInstanceId,
					});
				}
				return await baseExecutor(route, requestInit);
			};
			const authority = new BridgeProductSessionAuthorityStore(executor, clock).install({
				bootstrap,
				productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
			});
			const mux = new BridgeProductControlMux({
				authority,
				deadlineClock: clock,
				executeProductRequest: executor,
				onSessionSuspect: (reason, _ackAttempts, priorControls): void => {
					suspectFacts.push({ reason, priorControls });
				},
			});
			await authority.open;
			const call = mux.call({
				method: 'review.markFileViewed',
				request: { itemId: 'review-item-1' },
				workerDerivationEpoch: 1,
			});
			await callAdmitted;
			const scopeOutcome = mux
				.setViewScope({
					domain: 'review',
					handle: 'view-handle-1',
					incarnation: 'incarnation-1',
					scope: { kind: 'review', interests: [] },
					scopeRevision: 1,
					subscriptionId: 'review-subscription-1',
					subscriptionKind: 'review.metadata',
					...(faultKind === 'callerAbortAfterNativeAccept' ? { signal: scopeAbort.signal } : {}),
				})
				.then(
					(): 'accepted' => 'accepted',
					(): 'rejected' => 'rejected',
				);
			const scope = await scopeOutcome;
			releaseResult();
			await call;
			await mux.waitForAcknowledgementsQuiescent();
			if (faultKind === 'wrongCorrelationThenReplay') {
				expect(scope).toBe('accepted');
				expect(setScopeAttempts).toBe(2);
				expect(ackSequences).toEqual([2, 5, 6]);
				expect(suspectFacts).toEqual([]);
			} else if (faultKind === 'callerAbortAfterNativeAccept') {
				expect(scope).toBe('rejected');
				expect(setScopeAttempts).toBe(2);
				expect(ackSequences).toEqual([2, 5, 6]);
				expect(suspectFacts).toEqual([]);
			} else {
				expect(scope).toBe('rejected');
				expect(setScopeAttempts).toBe(bootstrap.policy.admissionRetryCount + 1);
				expect(ackSequences).toEqual([2]);
				expect(suspectFacts).toHaveLength(1);
				expect(suspectFacts[0]?.reason).toBe('admissionReplyExhausted');
				expect(suspectFacts[0]?.priorControls.at(-1)).toEqual({
					attemptOutcomes: Array.from({ length: 3 }, () => ({ kind: 'httpStatus', code: 502 })),
					kind: 'subscription.setScope',
					outcome: 'ambiguous',
					requestSequence: 4,
				});
			}
		},
	);
});
