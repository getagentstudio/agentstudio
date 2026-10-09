import { describe, expect, test } from 'vitest';

import validProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { parseBridgeProductRegisteredControlRequest } from './bridge-product-metadata-application-registry.js';
import {
	bridgeProductControlRequestSchema,
	bridgeProductControlResponseSchema,
} from './bridge-product-session-contracts.js';

const requestIdentity = {
	paneSessionId: 'pane-session-1',
	requestId: 'resync-request-1',
	requestSequence: 2,
	wireVersion: 2,
	workerInstanceId: 'worker-instance-1',
} as const;

const reviewEpochSeven = {
	subscriptionId: 'review-subscription-1',
	subscriptionKind: 'review.metadata',
	workerDerivationEpoch: 7,
} as const;

const fileEpochTwo = {
	subscriptionId: 'file-subscription-1',
	subscriptionKind: 'file.metadata',
	workerDerivationEpoch: 2,
} as const;

describe('Bridge product control admission and identity', () => {
	test('admits independent surface epochs and rejects split same-surface epochs', () => {
		const paneResync = {
			...requestIdentity,
			activeSubscriptions: [reviewEpochSeven, fileEpochTwo],
			kind: 'workerSession.resync',
			lastAcceptedRequestSequence: 1,
			lastAcceptedStreamSequence: 0,
		};

		expect(bridgeProductControlRequestSchema.safeParse(paneResync).success).toBe(true);
		expect(() => parseBridgeProductRegisteredControlRequest(paneResync)).not.toThrow();
		expect(() =>
			parseBridgeProductRegisteredControlRequest({
				...paneResync,
				activeSubscriptions: [
					reviewEpochSeven,
					{
						...reviewEpochSeven,
						subscriptionId: 'review-subscription-2',
						workerDerivationEpoch: 8,
					},
				],
			}),
		).toThrow(/one surface.*derivation epoch/iu);
	});

	test('requires native worktree authority only on Comment openAccepted responses', () => {
		const commentOpenAccepted = {
			kind: 'subscription.openAccepted',
			paneSessionId: 'pane-session-1',
			requestId: 'request-comment-open-accepted-1',
			requestSequence: 1,
			subscriptionId: 'review-annotations-subscription-1',
			subscriptionKind: 'review.annotations',
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
			worktreeId: '00000000-0000-7000-8000-000000000001',
		};
		const metadataOpenAccepted = {
			kind: 'subscription.openAccepted',
			paneSessionId: 'pane-session-1',
			requestId: 'request-review-open-accepted-1',
			requestSequence: 1,
			subscriptionId: 'review-metadata-subscription-1',
			subscriptionKind: 'review.metadata',
			wireVersion: 2,
			workerInstanceId: 'worker-instance-1',
		};

		expect(bridgeProductControlResponseSchema.parse(commentOpenAccepted)).toEqual(
			commentOpenAccepted,
		);
		expect(
			bridgeProductControlResponseSchema.safeParse({
				...commentOpenAccepted,
				worktreeId: undefined,
			}).success,
		).toBe(false);
		expect(bridgeProductControlResponseSchema.parse(metadataOpenAccepted)).toEqual(
			metadataOpenAccepted,
		);
		expect(
			bridgeProductControlResponseSchema.safeParse({
				...metadataOpenAccepted,
				worktreeId: '00000000-0000-7000-8000-000000000001',
			}).success,
		).toBe(false);
	});

	test('requires native worktree authority in every Comment view scope', () => {
		const reviewRequest = validProductSessionCorpus.transportV2.viewScopeRequests[0];
		if (reviewRequest === undefined) throw new Error('View scope fixture missing.');
		const commentRequest = {
			...reviewRequest,
			subscriptionKind: 'file.annotations',
			scope: { kind: 'comment', sessionIds: [], worktreeId: 'worktree-1' },
		};
		expect(bridgeProductControlRequestSchema.safeParse(commentRequest).success).toBe(true);
		expect(
			bridgeProductControlRequestSchema.safeParse({
				...commentRequest,
				scope: { kind: 'comment' },
			}).success,
		).toBe(false);
	});
});
