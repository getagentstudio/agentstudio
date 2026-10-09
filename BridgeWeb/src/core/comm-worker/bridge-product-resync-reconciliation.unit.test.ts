import { describe, expect, test } from 'vitest';

import {
	assertBridgeProductResyncReconciliationMatchesRequest,
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
	type BridgeProductControlRequest,
	type BridgeProductControlResponse,
} from './bridge-product-session-contracts.js';

const reviewSubscription = {
	subscriptionId: 'review-subscription-1',
	subscriptionKind: 'review.metadata',
	workerDerivationEpoch: 7,
} as const;

const fileSubscription = {
	subscriptionId: 'file-subscription-1',
	subscriptionKind: 'file.metadata',
	workerDerivationEpoch: 3,
} as const;

function makeResyncRequest(): BridgeProductControlRequest {
	return bridgeProductControlRequestSchema.parse({
		activeSubscriptions: [reviewSubscription, fileSubscription],
		kind: 'workerSession.resync',
		lastAcceptedRequestSequence: 8,
		lastAcceptedStreamSequence: 12,
		paneSessionId: 'pane-session-1',
		requestId: 'resync-request-1',
		requestSequence: 9,
		wireVersion: 2,
		workerInstanceId: 'worker-instance-1',
	});
}

function makeResyncResponse(): BridgeProductControlResponse {
	return bridgeProductControlResponseSchema.parse({
		kind: 'resync.accepted',
		metadataStreamSequenceBarrier: 15,
		nextExpectedRequestSequence: 10,
		paneSessionId: 'pane-session-1',
		reconciliation: [
			{
				disposition: 'retained',
				...reviewSubscription,
			},
			{
				disposition: 'reopenRequired',
				reason: 'snapshot_required',
				requiredWorkerDerivationEpoch: fileSubscription.workerDerivationEpoch,
				subscriptionId: fileSubscription.subscriptionId,
				subscriptionKind: fileSubscription.subscriptionKind,
			},
		],
		requestId: 'resync-request-1',
		requestSequence: 9,
		wireVersion: 2,
		workerInstanceId: 'worker-instance-1',
	});
}

describe('Bridge product resync reconciliation', () => {
	test('accepts one ordered closed outcome for every worker-reported subscription', () => {
		const request = makeResyncRequest();
		const response = makeResyncResponse();

		expect(() =>
			assertBridgeProductResyncReconciliationMatchesRequest({ request, response }),
		).not.toThrow();
	});

	test('rejects count, order, kind, and identity mismatches', () => {
		const request = makeResyncRequest();
		const response = makeResyncResponse();
		if (response.kind !== 'resync.accepted') throw new Error('Expected resync.accepted.');

		for (const reconciliation of [
			response.reconciliation.slice(0, 1),
			response.reconciliation.toReversed(),
			[
				{ ...response.reconciliation[0], subscriptionKind: 'file.metadata' },
				response.reconciliation[1],
			],
			[
				{ ...response.reconciliation[0], subscriptionId: 'review-subscription-other' },
				response.reconciliation[1],
			],
		]) {
			const mismatchedResponse = bridgeProductControlResponseSchema.parse({
				...response,
				reconciliation,
			});
			expect(() =>
				assertBridgeProductResyncReconciliationMatchesRequest({
					request,
					response: mismatchedResponse,
				}),
			).toThrow(/reconciliation/iu);
		}
	});

	test('rejects unknown outcome variants and more than 64 outcomes', () => {
		const response = makeResyncResponse();
		if (response.kind !== 'resync.accepted') throw new Error('Expected resync.accepted.');

		expect(
			bridgeProductControlResponseSchema.safeParse({
				...response,
				reconciliation: [
					{ ...response.reconciliation[0], disposition: 'silentlyIgnored' },
					response.reconciliation[1],
				],
			}).success,
		).toBe(false);
		expect(
			bridgeProductControlResponseSchema.safeParse({
				...response,
				reconciliation: Array.from({ length: 65 }, (_, index) => ({
					...response.reconciliation[0],
					subscriptionId: `review-subscription-${index}`,
				})),
			}).success,
		).toBe(false);
	});
});
