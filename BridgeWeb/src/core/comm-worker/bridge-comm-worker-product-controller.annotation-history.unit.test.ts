import { expect, test } from 'vitest';

import { BridgeCommWorkerProductController } from './bridge-comm-worker-product-controller.js';
import { BridgeProductBoundedAsyncQueue } from './bridge-product-async-queue.js';
import type { BridgeProductMetadataApplicationProtocolIdentity } from './bridge-product-metadata-application-protocol.js';
import {
	bridgeProductFileAnnotationMetadataApplicationProtocol,
	bridgeProductReviewAnnotationMetadataApplicationProtocol,
} from './bridge-product-metadata-application-registry.js';
import type { BridgeProductMetadataApplicationSubscription } from './bridge-product-transport-contract.js';
import type { BridgeProductTransportSession } from './bridge-product-transport.js';
import { createTestMetadataReopenPort } from './bridge-product-view-reopen.test-support.js';

type AnnotationMetadataProtocol =
	| typeof bridgeProductFileAnnotationMetadataApplicationProtocol
	| typeof bridgeProductReviewAnnotationMetadataApplicationProtocol;
type AnnotationMetadataSubscription =
	BridgeProductMetadataApplicationSubscription<AnnotationMetadataProtocol>;

test('opens paired annotation projections once and returns native command correlation', async () => {
	const fileEvents = new BridgeProductBoundedAsyncQueue<never>(8);
	const reviewEvents = new BridgeProductBoundedAsyncQueue<never>(8);
	const subscribedKinds: string[] = [];
	const calledMethods: string[] = [];
	const fileSubscription: AnnotationMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events: fileEvents,
		subscriptionId: 'file-annotations-1',
		subscriptionKind: 'file.annotations',
	};
	const reviewSubscription: AnnotationMetadataSubscription = {
		cancel: async (): Promise<void> => {},
		events: reviewEvents,
		subscriptionId: 'review-annotations-1',
		subscriptionKind: 'review.annotations',
	};
	const productTransport = {
		...unusedAnnotationProductTransport(),
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- This focused double implements only annotation calls.
		call: (async (method: string): Promise<unknown> => {
			calledMethods.push(method);
			return {
				kind: 'completed',
				outcome: {
					requestId: `${method}-request-1`,
					sessionId: null,
					status: { kind: 'committed' },
					surface: method === 'file.annotations.command' ? 'file' : 'review',
				},
			};
		}) as BridgeProductTransportSession['call'],
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- This focused double implements only annotation subscriptions.
		subscribe: ((protocol: BridgeProductMetadataApplicationProtocolIdentity): unknown => {
			const subscriptionKind = protocol.kind;
			subscribedKinds.push(subscriptionKind);
			return subscriptionKind === 'file.annotations' ? fileSubscription : reviewSubscription;
		}) as BridgeProductTransportSession['subscribe'],
	} satisfies BridgeProductTransportSession;
	const controller = new BridgeCommWorkerProductController({
		productTransport,
	});
	controller.ensureAnnotationSubscriptions();
	controller.ensureAnnotationSubscriptions();
	const fileResult = await controller.sendProductControl({
		method: 'file.annotations.command',
		params: { operation: { kind: 'session.discover' } },
	});
	const reviewResult = await controller.sendProductControl({
		method: 'review.annotations.command',
		params: {
			operation: { kind: 'session.discover' },
			reviewPublicationIdentity,
		},
	});
	await Promise.resolve();
	expect(subscribedKinds).toEqual(['file.annotations', 'review.annotations']);
	expect(calledMethods).toEqual(['file.annotations.command', 'review.annotations.command']);
	expect(fileResult).toMatchObject({ kind: 'completed' });
	expect(reviewResult).toMatchObject({ kind: 'completed' });
});

test('product controller preserves decoded nonempty annotation output history', async () => {
	const sessionId = '00000000-0000-7000-8000-000000000041';
	const historyResult = {
		kind: 'completed',
		outcome: {
			requestId: 'history-request-1',
			sessionId,
			status: {
				kind: 'history',
				summaries: [
					{
						attemptId: '00000000-0000-7000-8000-000000000042',
						canMarkNotHandled: true,
						createdAt: 1_700_000_000_000,
						messageCount: 1,
						outputKind: 'clipboard_markdown',
						repeatedFromAttemptId: null,
						sessionId,
						state: 'succeeded',
						updatedAt: 1_700_000_000_001,
					},
				],
			},
			surface: 'review',
		},
	} as const;
	const controller = new BridgeCommWorkerProductController({
		productTransport: decodedHistoryProductTransport(historyResult),
	});

	const result = await controller.sendProductControl({
		method: 'review.annotations.command',
		params: {
			operation: { kind: 'output.history', sessionId },
			reviewPublicationIdentity,
		},
	});

	expect(result).toEqual(historyResult);
});

function decodedHistoryProductTransport(historyResult: unknown): BridgeProductTransportSession {
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (): number => 0,
		// oxlint-disable-next-line typescript/no-unsafe-type-assertion -- This fake returns the one decoded annotation history result under test.
		call: (async (): Promise<unknown> => historyResult) as BridgeProductTransportSession['call'],
		openContent: (): never => {
			throw new Error('Unexpected annotation history content open.');
		},
		subscribe: (): never => {
			throw new Error('Unexpected annotation history subscription.');
		},
		workerDerivationEpoch: (): number => 0,
	};
}

const reviewPublicationIdentity = {
	packageId: 'package-installed',
	publicationId: '00000000-0000-7000-8000-000000000031',
	reviewGeneration: 7,
	revision: 3,
	sourceIdentity: 'source-installed',
} as const;

function unusedAnnotationProductTransport(): BridgeProductTransportSession {
	return {
		...createTestMetadataReopenPort(),
		advanceWorkerDerivationEpoch: (): number => 0,
		call: async (): Promise<never> => {
			throw new Error('Unexpected product call.');
		},
		openContent: (): never => {
			throw new Error('Unexpected content open.');
		},
		subscribe: (): never => {
			throw new Error('Unexpected direct subscription.');
		},
		workerDerivationEpoch: (): number => 0,
	};
}
