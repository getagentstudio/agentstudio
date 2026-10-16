import { afterEach, describe, expect, test, vi } from 'vitest';

import { executeAgentStudioBridgeProductRequest } from './bridge-product-agent-studio-request-executor.js';
import { createBridgeProductDeferred } from './bridge-product-async-queue.js';
import {
	BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH,
	BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
	BRIDGE_PRODUCT_WIRE_VERSION,
} from './bridge-product-contract-primitives.js';
import {
	BridgeProductControlMux,
	BridgeProductControlRequestError,
	BridgeProductSessionAuthorityStore,
} from './bridge-product-session-authority.js';
import {
	installFetchResponse,
	installWorkerOpenAndCallExchange,
	installWorkerOpenExchange,
	padJSONToByteLength,
	productResponseIdentity,
	productSessionBootstrap,
	requireShiftedValue,
	requireUint8Array,
	responseWithChunks,
	responseWithJSON,
	reviewSubscriptionCancelProps,
	reviewSubscriptionOpenProps,
	subscriptionCancelAcceptedResponse,
	subscriptionOpenAcceptedResponse,
	workerSessionAcceptedResponse,
	workerSessionAdmittedResponse,
	workerSessionResult,
	workerSessionResponseIdentity,
} from './bridge-product-session-authority.test-support.js';
import { bridgeProductControlRequestSchema } from './bridge-product-session-contracts.js';

const workerSessionOpenRequestSequence = 1;

describe('Bridge product session authority', () => {
	afterEach((): void => {
		vi.restoreAllMocks();
	});

	test('accepts an ordinary exactly correlated worker-session response', async () => {
		installWorkerOpenExchange(
			responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())),
		);

		const authority = installAuthority();

		await expect(authority.open).resolves.toBeUndefined();
	});

	test.each([
		['pane session', { paneSessionId: 'other-pane-session' }],
		['worker instance', { workerInstanceId: 'other-worker-instance' }],
		['request id', { requestId: 'other-request-id' }],
		['request sequence', { requestSequence: workerSessionOpenRequestSequence + 1 }],
	] as const)('rejects an accepted response with the wrong %s', async (_field, overrides) => {
		installWorkerOpenExchange(
			responseWithJSON(workerSessionResult(workerSessionAcceptedResponse(overrides))),
		);

		const authority = installAuthority();

		await expect(authority.open).rejects.toThrow(/does not match.*issued request/iu);
	});

	test('rejects a response with the wrong wire version', async () => {
		installWorkerOpenExchange(
			responseWithJSON(
				workerSessionResult(
					workerSessionAcceptedResponse({ wireVersion: BRIDGE_PRODUCT_WIRE_VERSION + 1 }),
				),
			),
		);

		const authority = installAuthority();

		await expect(authority.open).rejects.toThrow();
	});

	test('rejects a correlated typed response whose kind is not workerSession.accepted', async () => {
		installFetchResponse(
			responseWithJSON({
				...workerSessionResponseIdentity(),
				code: 'internal',
				kind: 'request.error',
				nextExpectedRequestSequence: null,
				retryAfterMilliseconds: null,
				retryable: false,
				safeMessage: null,
			}),
		);

		const authority = installAuthority();

		await expect(authority.open).rejects.toThrow(/was refused/iu);
	});

	test('incrementally accepts a schema-valid response of exactly 256 KiB', async () => {
		const responseBytes = padJSONToByteLength(
			workerSessionResult(workerSessionAcceptedResponse()),
			BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES,
		);
		const response = responseWithChunks([
			responseBytes.subarray(0, 32 * 1024),
			responseBytes.subarray(32 * 1024),
		]);
		const arrayBufferSpy = vi.spyOn(response, 'arrayBuffer');
		installWorkerOpenExchange(response);

		const authority = installAuthority();

		await expect(authority.open).resolves.toBeUndefined();
		expect(arrayBufferSpy).not.toHaveBeenCalled();
	});

	test('rejects cap plus one without materializing the response with arrayBuffer', async () => {
		const responseBytes = padJSONToByteLength(
			workerSessionResult(workerSessionAcceptedResponse()),
			BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES + 1,
		);
		const response = responseWithChunks([
			responseBytes.subarray(0, BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES),
			responseBytes.subarray(BRIDGE_PRODUCT_MAXIMUM_REQUEST_BODY_BYTES),
		]);
		const arrayBufferSpy = vi.spyOn(response, 'arrayBuffer');
		installWorkerOpenExchange(response);

		const authority = installAuthority();

		await expect(authority.open).rejects.toThrow(/response exceeds.*limit/iu);
		expect(arrayBufferSpy).not.toHaveBeenCalled();
	});

	test('handles a missing response body without using unbounded materialization', async () => {
		const response = new Response(null, { status: 200 });
		const arrayBufferSpy = vi.spyOn(response, 'arrayBuffer');
		installWorkerOpenExchange(response);

		const authority = installAuthority();

		await expect(authority.open).rejects.toThrow();
		expect(arrayBufferSpy).not.toHaveBeenCalled();
	});

	test('serializes the first typed call after the open result acknowledgement', async () => {
		const fetchSpy = installWorkerOpenAndCallExchange('product-call-1', {
			...productResponseIdentity('product-call-1', 3),
			call: { method: 'review.markFileViewed', result: null },
			kind: 'call.completed',
		});
		const authority = installAuthority();
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => 'product-call-1',
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		await expect(
			mux.call({
				method: 'review.markFileViewed',
				request: { itemId: 'item-1' },
				workerDerivationEpoch: 7,
			}),
		).resolves.toBeNull();

		expect(fetchSpy).toHaveBeenCalledTimes(6);
		const callRequest = fetchSpy.mock.calls[3];
		expect(callRequest?.[0]).toBe('agentstudio://rpc/command');
		expect(callRequest?.[1]?.headers).toMatchObject({
			'Content-Type': 'application/json',
			'X-AgentStudio-Bridge-Product-Capability': authority.capabilityHeader,
		});
		expect(JSON.parse(new TextDecoder().decode(requireUint8Array(callRequest?.[1]?.body)))).toEqual(
			{
				call: { method: 'review.markFileViewed', request: { itemId: 'item-1' } },
				kind: 'product.call',
				paneSessionId: 'pane-session-1',
				requestId: 'product-call-1',
				requestSequence: 3,
				wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
				workerDerivationEpoch: 7,
				workerInstanceId: 'worker-instance-1',
			},
		);
	});

	test('serializes an exact Review publication application receipt through the typed call mux', async () => {
		const publicationId = '11111111-1111-7111-8111-111111111111';
		const fetchSpy = installWorkerOpenAndCallExchange('publication-applied-1', {
			...productResponseIdentity('publication-applied-1', 3),
			call: { method: 'review.publication.applied', result: null },
			kind: 'call.completed',
		});
		const authority = installAuthority();
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => 'publication-applied-1',
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		await expect(
			mux.call({
				method: 'review.publication.applied',
				request: { publicationId },
				workerDerivationEpoch: 7,
			}),
		).resolves.toBeNull();

		const callRequest = fetchSpy.mock.calls[3];
		expect(JSON.parse(new TextDecoder().decode(requireUint8Array(callRequest?.[1]?.body)))).toEqual(
			{
				call: { method: 'review.publication.applied', request: { publicationId } },
				kind: 'product.call',
				paneSessionId: 'pane-session-1',
				requestId: 'publication-applied-1',
				requestSequence: 3,
				wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
				workerDerivationEpoch: 7,
				workerInstanceId: 'worker-instance-1',
			},
		);
	});

	test('serializes an exact Review publication install admission through the typed call mux', async () => {
		const candidatePublicationId = '22222222-2222-7222-8222-222222222222';
		const expectedDisplayedPublicationId = '11111111-1111-7111-8111-111111111111';
		const fetchSpy = installWorkerOpenAndCallExchange('publication-install-admit-1', {
			...productResponseIdentity('publication-install-admit-1', 3),
			call: {
				method: 'review.publication.install.admit',
				result: { status: 'admitted' },
			},
			kind: 'call.completed',
		});
		const authority = installAuthority();
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => 'publication-install-admit-1',
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		await expect(
			mux.call({
				method: 'review.publication.install.admit',
				request: { candidatePublicationId, expectedDisplayedPublicationId },
				workerDerivationEpoch: 7,
			}),
		).resolves.toEqual({ status: 'admitted' });

		const callRequest = fetchSpy.mock.calls[3];
		expect(JSON.parse(new TextDecoder().decode(requireUint8Array(callRequest?.[1]?.body)))).toEqual(
			{
				call: {
					method: 'review.publication.install.admit',
					request: { candidatePublicationId, expectedDisplayedPublicationId },
				},
				kind: 'product.call',
				paneSessionId: 'pane-session-1',
				requestId: 'publication-install-admit-1',
				requestSequence: 3,
				wireVersion: BRIDGE_PRODUCT_WIRE_VERSION,
				workerDerivationEpoch: 7,
				workerInstanceId: 'worker-instance-1',
			},
		);
	});

	test('retries an ambiguous call failure with identical request identity and bytes', async () => {
		const fetchSpy = vi
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
			.mockRejectedValueOnce(new Error('ambiguous transport failure'))
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('product-call-retry', 3),
					kind: 'operation.admitted',
					operationId: 'operation-call-retry',
					waitKind: 'ordinary',
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON({
					failureCode: null,
					kind: 'operation.result',
					operationId: 'operation-call-retry',
					outcome: 'succeeded',
					result: {
						...productResponseIdentity('product-call-retry', 3),
						call: { method: 'review.markFileViewed', result: null },
						kind: 'call.completed',
					},
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('product-call-retry', 4),
					kind: 'operation.resultAcknowledged',
					operationId: 'operation-call-retry',
				}),
			);
		const authority = installAuthority();
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => 'product-call-retry',
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		await expect(
			mux.call({
				method: 'review.markFileViewed',
				request: { itemId: 'item-1' },
				workerDerivationEpoch: 2,
			}),
		).resolves.toBeNull();

		const firstAttempt = requireUint8Array(fetchSpy.mock.calls[3]?.[1]?.body);
		const retryAttempt = requireUint8Array(fetchSpy.mock.calls[4]?.[1]?.body);
		expect([...firstAttempt]).toEqual([...retryAttempt]);
	});

	test('serializes call, subscription open, and cancel on one request sequence', async () => {
		const requestIds = ['call-1', 'cancel-1', 'open-1', 'result-ack-1', 'result-ack-2'];
		const admittedRequests = new Map<string, Record<string, unknown>>();
		const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (_url, init) => {
			const body = JSON.parse(new TextDecoder().decode(requireUint8Array(init?.body)));
			if (body['kind'] === 'workerSession.open') {
				return responseWithJSON(workerSessionAdmittedResponse());
			}
			if (body['kind'] === 'operation.result') {
				if (body['operationId'] === 'operation-open-1') {
					return responseWithJSON(workerSessionResult(workerSessionAcceptedResponse()));
				}
				const request = admittedRequests.get(String(body['operationId']));
				if (request === undefined)
					throw new Error('Result read did not match an admitted request.');
				const result =
					request['kind'] === 'product.call'
						? {
								...productResponseIdentity(
									String(request['requestId']),
									Number(request['requestSequence']),
								),
								kind: 'call.completed',
								call: { method: 'review.markFileViewed', result: null },
							}
						: subscriptionOpenAcceptedResponse(
								String(request['requestId']),
								Number(request['requestSequence']),
								'review-subscription-1',
							);
				return responseWithJSON({
					failureCode: null,
					kind: 'operation.result',
					operationId: body['operationId'],
					outcome: 'succeeded',
					result,
				});
			}
			if (body['kind'] === 'operation.resultAcknowledgement') {
				return responseWithJSON({ ...body, kind: 'operation.resultAcknowledged' });
			}
			if (body['kind'] === 'subscription.cancel') {
				return responseWithJSON(
					subscriptionCancelAcceptedResponse(
						String(body['requestId']),
						Number(body['requestSequence']),
						String(body['subscriptionId']),
					),
				);
			}
			const operationId = `operation-${String(body['requestId'])}`;
			admittedRequests.set(operationId, body);
			return responseWithJSON({
				...productResponseIdentity(String(body['requestId']), Number(body['requestSequence'])),
				kind: 'operation.admitted',
				operationId,
				waitKind: 'ordinary',
			});
		});
		const authority = installAuthority();
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => requireShiftedValue(requestIds),
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		const call = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'item-1' },
			workerDerivationEpoch: 7,
		});
		const open = mux.openSubscription(reviewSubscriptionOpenProps('review-subscription-1', 7));
		const cancel = mux.cancelSubscription(
			reviewSubscriptionCancelProps('review-subscription-1', 7),
		);

		await expect(call).resolves.toBeNull();
		const [openResult, cancelResult] = await Promise.all([open, cancel]);
		await mux.waitForAcknowledgementsQuiescent();
		expect([openResult.kind, cancelResult.kind]).toEqual([
			'subscription.openAccepted',
			'subscription.cancelAccepted',
		]);

		const controlBodies = fetchSpy.mock.calls
			.map((callArguments) =>
				JSON.parse(new TextDecoder().decode(requireUint8Array(callArguments[1]?.body))),
			)
			.filter((body) =>
				['product.call', 'subscription.open', 'subscription.cancel'].includes(body.kind),
			);
		expect(controlBodies.map((body) => [body.kind, body.requestSequence])).toEqual([
			['product.call', 3],
			['subscription.cancel', 4],
			['subscription.open', 6],
		]);
		expect(controlBodies.slice(1).map((body) => body.workerDerivationEpoch)).toEqual([7, 7]);
		expect(controlBodies[1]).not.toHaveProperty('surface');
	});

	test('retries an ambiguous subscription admission with identical bytes', async () => {
		const fetchSpy = installWorkerOpenExchange(
			responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())),
		)
			.mockRejectedValueOnce(new Error('ambiguous subscription transport failure'))
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('subscription-open-retry', 3),
					kind: 'operation.admitted',
					operationId: 'operation-subscription-retry',
					waitKind: 'ordinary',
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON({
					failureCode: null,
					kind: 'operation.result',
					operationId: 'operation-subscription-retry',
					outcome: 'succeeded',
					result: subscriptionOpenAcceptedResponse(
						'subscription-open-retry',
						3,
						'review-subscription-retry',
					),
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('subscription-open-retry', 4),
					kind: 'operation.resultAcknowledged',
					operationId: 'operation-subscription-retry',
				}),
			);
		const mux = new BridgeProductControlMux({
			authority: installAuthority(),
			createRequestId: (): string => 'subscription-open-retry',
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		await expect(
			mux.openSubscription(reviewSubscriptionOpenProps('review-subscription-retry', 3)),
		).resolves.toMatchObject({ kind: 'subscription.openAccepted' });

		const firstAttempt = requireUint8Array(fetchSpy.mock.calls[3]?.[1]?.body);
		const retryAttempt = requireUint8Array(fetchSpy.mock.calls[4]?.[1]?.body);
		expect([...firstAttempt]).toEqual([...retryAttempt]);
	});

	test('rejects wrong subscription response kinds and exact correlation', async () => {
		const fetchSpy = installWorkerOpenExchange(
			responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())),
		)
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('subscription-open-kind', 3),
					kind: 'operation.admitted',
					operationId: 'operation-subscription-kind',
					waitKind: 'ordinary',
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON({
					failureCode: null,
					kind: 'operation.result',
					operationId: 'operation-subscription-kind',
					outcome: 'succeeded',
					result: subscriptionCancelAcceptedResponse(
						'subscription-open-kind',
						3,
						'review-subscription-kind',
					),
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('subscription-open-result-ack', 4),
					kind: 'operation.resultAcknowledged',
					operationId: 'operation-subscription-kind',
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON(
					subscriptionCancelAcceptedResponse(
						'wrong-correlation',
						5,
						'review-subscription-correlation',
					),
				),
			)
			.mockResolvedValueOnce(
				responseWithJSON(
					subscriptionCancelAcceptedResponse(
						'wrong-correlation',
						5,
						'review-subscription-correlation',
					),
				),
			)
			.mockResolvedValueOnce(
				responseWithJSON(
					subscriptionCancelAcceptedResponse(
						'wrong-correlation',
						5,
						'review-subscription-correlation',
					),
				),
			);
		const requestIds = [
			'subscription-open-kind',
			'subscription-open-result-ack',
			'subscription-cancel-correlation',
		];
		const mux = new BridgeProductControlMux({
			authority: installAuthority(),
			createRequestId: (): string => requireShiftedValue(requestIds),
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		await expect(
			mux.openSubscription(reviewSubscriptionOpenProps('review-subscription-kind', 1)),
		).rejects.toThrow(/subscription\.openAccepted/iu);
		await expect(
			mux.cancelSubscription(reviewSubscriptionCancelProps('review-subscription-correlation', 1)),
		).rejects.toThrow(/did not settle within its bounded retry window/iu);
		expect(fetchSpy).toHaveBeenCalledTimes(9);
		const firstCancel = requireUint8Array(fetchSpy.mock.calls[6]?.[1]?.body);
		expect([...requireUint8Array(fetchSpy.mock.calls[7]?.[1]?.body)]).toEqual([...firstCancel]);
		expect([...requireUint8Array(fetchSpy.mock.calls[8]?.[1]?.body)]).toEqual([...firstCancel]);
	});

	test('consumes a correlated request.error sequence before admitting the next request', async () => {
		const fetchSpy = installWorkerOpenExchange(
			responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())),
		)
			.mockResolvedValueOnce(
				responseWithJSON({
					...productResponseIdentity('subscription-open-error', 3),
					code: 'unsupported_subscription',
					kind: 'request.error',
					nextExpectedRequestSequence: 4,
					retryAfterMilliseconds: null,
					retryable: false,
					safeMessage: 'Subscription source is not installed',
				}),
			)
			.mockResolvedValueOnce(
				responseWithJSON(
					subscriptionCancelAcceptedResponse(
						'subscription-cancel-after-error',
						4,
						'review-subscription-after-error',
					),
				),
			);
		const requestIds = ['subscription-open-error', 'subscription-cancel-after-error'];
		const mux = new BridgeProductControlMux({
			authority: installAuthority(),
			createRequestId: (): string => requireShiftedValue(requestIds),
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});

		const rejectedOpen = mux.openSubscription(
			reviewSubscriptionOpenProps('review-subscription-after-error', 4),
		);
		await expect(rejectedOpen).rejects.toThrow('Subscription source is not installed');
		await expect(rejectedOpen).rejects.toEqual(
			expect.objectContaining<Partial<BridgeProductControlRequestError>>({
				code: 'unsupported_subscription',
				retryAfterMilliseconds: null,
				retryable: false,
			}),
		);
		await expect(
			mux.cancelSubscription(reviewSubscriptionCancelProps('review-subscription-after-error', 4)),
		).resolves.toMatchObject({ requestSequence: 4 });

		const cancelBody = JSON.parse(
			new TextDecoder().decode(requireUint8Array(fetchSpy.mock.calls[4]?.[1]?.body)),
		);
		expect(cancelBody.requestSequence).toBe(4);
	});

	test.each([
		{ code: 'resync_required', nextExpectedRequestSequence: null },
		{ code: 'sequence_conflict', nextExpectedRequestSequence: 3 },
	] as const)(
		'preserves an unconsumed sequence after $code admission rejection',
		async ({ code, nextExpectedRequestSequence }) => {
			// Native rejects stale epochs before admission, so sequence 3 remains available.
			const fetchSpy = installWorkerOpenExchange(
				responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())),
			)
				.mockResolvedValueOnce(
					responseWithJSON({
						...productResponseIdentity('stale-epoch-call', 3),
						code,
						kind: 'request.error',
						nextExpectedRequestSequence,
						retryAfterMilliseconds: null,
						retryable: true,
						safeMessage: null,
					}),
				)
				.mockResolvedValueOnce(
					responseWithJSON({
						...productResponseIdentity('current-epoch-call', 3),
						kind: 'operation.admitted',
						operationId: 'operation-current-epoch',
						waitKind: 'ordinary',
					}),
				)
				.mockResolvedValueOnce(
					responseWithJSON({
						failureCode: null,
						kind: 'operation.result',
						operationId: 'operation-current-epoch',
						outcome: 'succeeded',
						result: {
							...productResponseIdentity('current-epoch-call', 3),
							call: { method: 'review.markFileViewed', result: null },
							kind: 'call.completed',
						},
					}),
				)
				.mockResolvedValueOnce(
					responseWithJSON({
						...productResponseIdentity('current-epoch-result-ack', 4),
						kind: 'operation.resultAcknowledged',
						operationId: 'operation-current-epoch',
					}),
				);
			const requestIds = ['stale-epoch-call', 'current-epoch-call', 'current-epoch-result-ack'];
			const mux = new BridgeProductControlMux({
				authority: installAuthority(),
				createRequestId: (): string => requireShiftedValue(requestIds),
				executeProductRequest: executeAgentStudioBridgeProductRequest,
			});

			// Act / Assert — the failed old intent must not consume the next current intent's sequence.
			await expect(
				mux.call({
					method: 'review.markFileViewed',
					request: { itemId: 'review-item-stale' },
					workerDerivationEpoch: 6,
				}),
			).rejects.toMatchObject({ code, retryable: true });
			await expect(
				mux.call({
					method: 'review.markFileViewed',
					request: { itemId: 'review-item-current' },
					workerDerivationEpoch: 7,
				}),
			).resolves.toBeNull();
			const currentRequest = bridgeProductControlRequestSchema.parse(
				JSON.parse(new TextDecoder().decode(requireUint8Array(fetchSpy.mock.calls[4]?.[1]?.body))),
			);
			expect(currentRequest.requestSequence).toBe(3);
		},
	);

	test('drops an aborted queued admission without consuming its request sequence', async () => {
		let resolveCallResponse: ((response: Response) => void) | undefined;
		const callResponse = new Promise<Response>((resolve) => {
			resolveCallResponse = resolve;
		});
		const fetchSpy = installWorkerOpenExchange(
			responseWithJSON(workerSessionResult(workerSessionAcceptedResponse())),
		).mockImplementation(async (_url, init) => {
			const body = JSON.parse(new TextDecoder().decode(requireUint8Array(init?.body)));
			switch (body.kind) {
				case 'product.call':
					return await callResponse;
				case 'operation.result':
					return responseWithJSON({
						failureCode: null,
						kind: 'operation.result',
						operationId: 'operation-blocking-call',
						outcome: 'succeeded',
						result: {
							...productResponseIdentity('blocking-call', 3),
							call: { method: 'review.markFileViewed', result: null },
							kind: 'call.completed',
						},
					});
				case 'operation.resultAcknowledgement':
					return responseWithJSON({ ...body, kind: 'operation.resultAcknowledged' });
				case 'subscription.cancel':
					return responseWithJSON(
						subscriptionCancelAcceptedResponse(
							body.requestId,
							body.requestSequence,
							body.subscriptionId,
						),
					);
				default:
					throw new Error('Unexpected queued control request.');
			}
		});
		const requestIds = [
			'blocking-call',
			'subscription-cancel-after-abort',
			'blocking-call-result-ack',
		];
		const mux = new BridgeProductControlMux({
			authority: installAuthority(),
			createRequestId: (): string => requireShiftedValue(requestIds),
			executeProductRequest: executeAgentStudioBridgeProductRequest,
		});
		const abortController = new AbortController();

		const blockingCall = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'item-1' },
			workerDerivationEpoch: 8,
		});
		const abortedOpen = mux.openSubscription(
			reviewSubscriptionOpenProps('review-subscription-after-abort', 8, abortController.signal),
		);
		const cancel = mux.cancelSubscription(
			reviewSubscriptionCancelProps('review-subscription-after-abort', 8),
		);
		abortController.abort();
		resolveCallResponse?.(
			responseWithJSON({
				...productResponseIdentity('blocking-call', 3),
				kind: 'operation.admitted',
				operationId: 'operation-blocking-call',
				waitKind: 'ordinary',
			}),
		);

		await expect(blockingCall).resolves.toBeNull();
		await expect(abortedOpen).rejects.toThrow(/abort/iu);
		await expect(cancel).resolves.toMatchObject({ requestSequence: 4 });
		const controlBodies = fetchSpy.mock.calls.map((callArguments) =>
			JSON.parse(new TextDecoder().decode(requireUint8Array(callArguments[1]?.body))),
		);
		expect(controlBodies.filter((body) => body.kind === 'subscription.open')).toHaveLength(0);
		expect(controlBodies.find((body) => body.kind === 'subscription.cancel')).toMatchObject({
			requestSequence: 4,
		});
	});

	test('drains an admitted result after feature abort while the next admission proceeds', async () => {
		const requestSequences: number[] = [];
		const acknowledgedOperations: string[] = [];
		const firstCallResponse = createBridgeProductDeferred<Response>();
		const firstResultRequested = createBridgeProductDeferred<void>();
		const firstResultAcknowledged = createBridgeProductDeferred<void>();
		const executeProductRequest: ConstructorParameters<
			typeof BridgeProductSessionAuthorityStore
		>[0] = async (_route, requestInit): Promise<Response> => {
			const body = JSON.parse(new TextDecoder().decode(requireUint8Array(requestInit.body)));
			if (typeof body.requestSequence === 'number') requestSequences.push(body.requestSequence);
			switch (body.kind) {
				case 'workerSession.open':
					return responseWithJSON(workerSessionAdmittedResponse());
				case 'operation.result':
					if (body.operationId === 'operation-open-1') {
						return responseWithJSON(workerSessionResult(workerSessionAcceptedResponse()));
					}
					if (body.operationId === 'operation-first-call') {
						firstResultRequested.resolve();
						return await firstCallResponse.promise;
					}
					return responseWithJSON({
						failureCode: null,
						kind: 'operation.result',
						operationId: 'operation-second-call',
						outcome: 'succeeded',
						result: {
							...productResponseIdentity('second-call', 4),
							call: { method: 'review.markFileViewed', result: null },
							kind: 'call.completed',
						},
					});
				case 'operation.resultAcknowledgement':
					acknowledgedOperations.push(body.operationId);
					if (body.operationId === 'operation-first-call') firstResultAcknowledged.resolve();
					return responseWithJSON({ ...body, kind: 'operation.resultAcknowledged' });
				case 'product.call':
					return responseWithJSON({
						...productResponseIdentity(body.requestId, body.requestSequence),
						kind: 'operation.admitted',
						operationId:
							body.requestId === 'first-call' ? 'operation-first-call' : 'operation-second-call',
						waitKind: 'ordinary',
					});
				default:
					throw new Error('Unexpected Bridge product request.');
			}
		};
		const authority = new BridgeProductSessionAuthorityStore(executeProductRequest).install({
			bootstrap: productSessionBootstrap(),
			productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
		});
		const requestIds = ['first-call', 'second-call', 'second-result-ack', 'first-result-ack'];
		const mux = new BridgeProductControlMux({
			authority,
			createRequestId: (): string => requireShiftedValue(requestIds),
			executeProductRequest,
		});
		const abortController = new AbortController();

		// Act
		const firstCall = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'item-1' },
			signal: abortController.signal,
			workerDerivationEpoch: 1,
		});
		await firstResultRequested.promise;
		const secondCall = mux.call({
			method: 'review.markFileViewed',
			request: { itemId: 'item-2' },
			workerDerivationEpoch: 1,
		});
		abortController.abort();
		const firstSettlement = firstCall.then(
			(): string => 'completed',
			(): string => 'cancelled',
		);
		expect(await Promise.race([firstSettlement, secondCall.then((): string => 'second')])).toBe(
			'cancelled',
		);
		await expect(secondCall).resolves.toBeNull();
		firstCallResponse.resolve(
			responseWithJSON({
				failureCode: null,
				kind: 'operation.result',
				operationId: 'operation-first-call',
				outcome: 'succeeded',
				result: {
					...productResponseIdentity('first-call', 3),
					call: { method: 'review.markFileViewed', result: null },
					kind: 'call.completed',
				},
			}),
		);

		// Assert
		await expect(firstCall).rejects.toThrow(/abort/iu);
		await firstResultAcknowledged.promise;
		expect(acknowledgedOperations).toContain('operation-first-call');
		expect(requestSequences).toEqual([1, 2, 3, 4, 5, 6]);
	});
});

function installAuthority(): ReturnType<BridgeProductSessionAuthorityStore['install']> {
	return new BridgeProductSessionAuthorityStore(executeAgentStudioBridgeProductRequest).install({
		bootstrap: productSessionBootstrap(),
		productCapability: new ArrayBuffer(BRIDGE_PRODUCT_CAPABILITY_BYTE_LENGTH),
	});
}
