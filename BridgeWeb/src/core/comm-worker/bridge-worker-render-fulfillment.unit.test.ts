import { describe, expect, test } from 'vitest';
import { z } from 'zod';

import {
	bridgeWorkerRenderDispositionReceiptSchema,
	bridgeWorkerRenderReceiptTransitionSchema,
	createBridgeWorkerRenderFulfillment,
	reduceBridgeWorkerContentAvailability,
	reduceBridgeWorkerRenderFulfillment,
	type BridgeWorkerRenderDisposition,
	type BridgeWorkerRenderFulfillmentEvent,
	type BridgeWorkerRenderFulfillmentState,
} from './bridge-worker-render-fulfillment.js';
import {
	createBridgeWorkerSemanticWindowIdentity,
	type BridgeWorkerSemanticWindowIdentityInput,
} from './bridge-worker-semantic-identity.js';

const semanticIdentityInput: BridgeWorkerSemanticWindowIdentityInput = {
	documentKind: 'diff',
	orderedContentDigests: [
		{
			role: 'base',
			algorithm: 'sha256',
			digest: 'a'.repeat(64),
		},
		{
			role: 'head',
			algorithm: 'sha256',
			digest: 'b'.repeat(64),
		},
	],
	partitionId: 'partition-1',
	windowId: 'window-1',
	startLine: 0,
	endLineExclusive: 400,
	windowDigest: {
		algorithm: 'sha256',
		digest: 'c'.repeat(64),
	},
};

const canonicalRenderContext = {
	paneSessionId: 'pane-session-1',
	workerInstanceId: 'worker-instance-1',
	surface: 'review',
	workerDerivationEpoch: 3,
} as const;

const foreignRenderContextCases = [
	['pane session', { paneSessionId: 'pane-session-foreign' }],
	['worker instance', { workerInstanceId: 'worker-instance-foreign' }],
	['surface', { surface: 'file' }],
	['worker derivation epoch', { workerDerivationEpoch: 4 }],
] as const;

describe('Bridge worker semantic identity', () => {
	test('ignores transport and metadata churn while retaining content identity', () => {
		const firstDescriptor = {
			semanticIdentity: semanticIdentityInput,
			sourceGeneration: 7,
			workerDerivationEpoch: 2,
			leaseId: 'lease-1',
			metadataRevision: 10,
		} as const;
		const retouchedDescriptor = {
			semanticIdentity: semanticIdentityInput,
			sourceGeneration: 8,
			workerDerivationEpoch: 3,
			leaseId: 'lease-2',
			metadataRevision: 11,
		} as const;
		const first = createBridgeWorkerSemanticWindowIdentity(firstDescriptor.semanticIdentity);
		const retouched = createBridgeWorkerSemanticWindowIdentity(
			retouchedDescriptor.semanticIdentity,
		);

		expect(retouched).toEqual(first);
	});

	test('changes identity for same-size different bytes', () => {
		const first = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
		const changedBytes = createBridgeWorkerSemanticWindowIdentity({
			...semanticIdentityInput,
			windowDigest: {
				algorithm: 'sha256',
				digest: 'd'.repeat(64),
			},
		});

		expect(changedBytes.windowKey).not.toBe(first.windowKey);
		expect(changedBytes.semanticDocumentRevision).toBe(first.semanticDocumentRevision);
	});

	test('treats ordered content roles as semantic document input', () => {
		const first = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
		const reversed = createBridgeWorkerSemanticWindowIdentity({
			...semanticIdentityInput,
			orderedContentDigests: semanticIdentityInput.orderedContentDigests.toReversed(),
		});

		expect(reversed.semanticDocumentRevision).not.toBe(first.semanticDocumentRevision);
	});
});

describe('Bridge worker render fulfillment', () => {
	test('carries selected-content correlation through render disposition receipts', () => {
		const operationCorrelationId = 'a'.repeat(64);
		const receipt = bridgeWorkerRenderDispositionReceiptSchema.parse({
			...disposition('queued'),
			operationCorrelationId,
		});

		expect(receipt.operationCorrelationId).toBe(operationCorrelationId);
	});

	test('dispatches receipt transitions by kind', () => {
		expect(bridgeWorkerRenderReceiptTransitionSchema).toBeInstanceOf(z.ZodDiscriminatedUnion);
	});

	test('accepts one monotonic idempotent disposition chain and fulfills only at painted', () => {
		const identity = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
		let state = createBridgeWorkerRenderFulfillment({
			...canonicalRenderContext,
			identity,
			itemId: 'item-11',
			publicationId: 'render-publication-review-4-11',
			publicationSequence: 11,
			submissionId: 'submission-1',
		});

		state = reduceBridgeWorkerRenderFulfillment(state, { kind: 'preparation.started' });
		state = reduceBridgeWorkerRenderFulfillment(state, {
			kind: 'publication.started',
			attemptId: 'attempt-1',
			publishedAtMilliseconds: 0,
			receiptLeaseExpiresAtMilliseconds: 100,
		});
		state = reduceBridgeWorkerRenderFulfillment(state, disposition('queued'));
		const queuedState = state;
		state = reduceBridgeWorkerRenderFulfillment(state, disposition('queued'));
		expect(state).toBe(queuedState);
		expect(state.isDesired).toBe(true);

		state = reduceBridgeWorkerRenderFulfillment(state, disposition('applied'));
		expect(state.isDesired).toBe(true);
		state = reduceBridgeWorkerRenderFulfillment(state, disposition('painted'));

		expect(state.stage).toBe('painted');
		expect(state.isDesired).toBe(false);
		expect(state.paintedResidency).toEqual(renderReceiptIdentity());
	});

	test('rejects out-of-order, conflicting, or foreign receipts', () => {
		const published = publishedFulfillment();

		expect(() => reduceBridgeWorkerRenderFulfillment(published, disposition('applied'))).toThrow(
			/out of order/iu,
		);
		expect(() =>
			reduceBridgeWorkerRenderFulfillment(published, {
				...disposition('queued'),
				attemptId: 'attempt-foreign',
			}),
		).toThrow(/attempt/iu);
		expect(() =>
			reduceBridgeWorkerRenderFulfillment(published, {
				...disposition('queued'),
				windowKey: 'foreign-window',
			}),
		).toThrow(/identity/iu);
		expect(() =>
			reduceBridgeWorkerRenderFulfillment(published, {
				...disposition('queued'),
				receivedAtMilliseconds: 101,
			}),
		).toThrow(/receipt lease/iu);
	});

	test.each(foreignRenderContextCases)(
		'rejects a foreign %s disposition before mutating the active attempt',
		(_caseName, foreignContext) => {
			const published = publishedFulfillment();

			expect(() =>
				reduceBridgeWorkerRenderFulfillment(published, {
					...disposition('queued'),
					...foreignContext,
				}),
			).toThrow(/context/iu);

			const accepted = reduceBridgeWorkerRenderFulfillment(published, disposition('queued'));
			expect(accepted.stage).toBe('queued');
		},
	);

	test.each(['rejected', 'superseded'] as const)(
		'returns a still-desired %s attempt through bounded retry with a fresh attempt id',
		(dispositionKind) => {
			let state = publishedFulfillment();
			const terminalDisposition = disposition(dispositionKind);
			state = reduceBridgeWorkerRenderFulfillment(state, terminalDisposition);

			expect(state.stage).toBe('retry_wait');
			expect(state.isDesired).toBe(true);
			expect(state.closedAttempts.at(-1)).toMatchObject({
				disposition: dispositionKind,
				reason: terminalDisposition.reason,
			});
			expect(() =>
				reduceBridgeWorkerRenderFulfillment(state, {
					kind: 'retry.ready',
					atMilliseconds: 119,
				}),
			).toThrow(/backoff/iu);

			state = reduceBridgeWorkerRenderFulfillment(state, {
				kind: 'retry.ready',
				atMilliseconds: 120,
			});
			state = reduceBridgeWorkerRenderFulfillment(state, { kind: 'preparation.started' });
			expect(() =>
				reduceBridgeWorkerRenderFulfillment(state, {
					kind: 'publication.started',
					attemptId: 'attempt-1',
					publishedAtMilliseconds: 120,
					receiptLeaseExpiresAtMilliseconds: 220,
				}),
			).toThrow(/fresh attempt/iu);
		},
	);

	test('requires a closed bounded reason only for rejected and superseded receipts', () => {
		const rejected = disposition('rejected');
		const { reason: _requiredReason, ...missingReason } = rejected;

		expect(bridgeWorkerRenderDispositionReceiptSchema.safeParse(rejected).success).toBe(true);
		expect(bridgeWorkerRenderDispositionReceiptSchema.safeParse(missingReason).success).toBe(false);
		expect(
			bridgeWorkerRenderDispositionReceiptSchema.safeParse({
				...rejected,
				reason: 'unbounded free-form rejection',
			}).success,
		).toBe(false);
		expect(
			bridgeWorkerRenderDispositionReceiptSchema.safeParse({
				...disposition('queued'),
				reason: 'stale_attempt',
			}).success,
		).toBe(false);
	});

	test('strictly rejects undeclared receipt-transition fields', () => {
		expect(
			bridgeWorkerRenderReceiptTransitionSchema.safeParse({
				...renderReceiptIdentity(),
				kind: 'selection.accepted',
				uiIntentRevision: 7,
				atMilliseconds: 90,
				validationLeaseExpiresAtMilliseconds: 100,
				undeclaredReceiptField: true,
			}).success,
		).toBe(false);
	});

	test('requires every canonical context field on receipt transitions', () => {
		const validReceipt = disposition('queued');
		expect(bridgeWorkerRenderReceiptTransitionSchema.safeParse(validReceipt).success).toBe(true);
		const { paneSessionId: _paneSessionId, ...withoutPaneSession } = validReceipt;
		const { workerInstanceId: _workerInstanceId, ...withoutWorkerInstance } = validReceipt;
		const { surface: _surface, ...withoutSurface } = validReceipt;
		const { workerDerivationEpoch: _workerDerivationEpoch, ...withoutWorkerDerivationEpoch } =
			validReceipt;

		for (const incompleteReceipt of [
			withoutPaneSession,
			withoutWorkerInstance,
			withoutSurface,
			withoutWorkerDerivationEpoch,
		]) {
			expect(bridgeWorkerRenderReceiptTransitionSchema.safeParse(incompleteReceipt).success).toBe(
				false,
			);
		}
		expect(
			bridgeWorkerRenderReceiptTransitionSchema.safeParse({
				...validReceipt,
				workerEpoch: 3,
			}).success,
		).toBe(false);
	});

	test('expires a receipt lease without parking selected demand', () => {
		let state = publishedFulfillment();
		state = reduceBridgeWorkerRenderFulfillment(state, {
			...renderReceiptIdentity(),
			kind: 'receiptLease.expired',
			atMilliseconds: 100,
			retryAtMilliseconds: 110,
		});

		expect(state).toMatchObject({
			stage: 'retry_wait',
			isDesired: true,
			retryAtMilliseconds: 110,
		});
	});

	test.each(foreignRenderContextCases)(
		'rejects a foreign %s receipt-lease expiration before closing the attempt',
		(_caseName, foreignContext) => {
			const published = publishedFulfillment();

			expect(() =>
				reduceBridgeWorkerRenderFulfillment(published, {
					...renderReceiptIdentity(),
					...foreignContext,
					kind: 'receiptLease.expired',
					atMilliseconds: 100,
					retryAtMilliseconds: 110,
				}),
			).toThrow(/context/iu);

			const accepted = reduceBridgeWorkerRenderFulfillment(published, {
				...renderReceiptIdentity(),
				kind: 'receiptLease.expired',
				atMilliseconds: 100,
				retryAtMilliseconds: 110,
			});
			expect(accepted.stage).toBe('retry_wait');
		},
	);

	test('accepts fresh-display reuse only for current painted residency with a valid lease', () => {
		let state = paintedFulfillment();
		state = reduceBridgeWorkerRenderFulfillment(state, {
			...renderReceiptIdentity(),
			kind: 'selection.accepted',
			uiIntentRevision: 7,
			atMilliseconds: 90,
			validationLeaseExpiresAtMilliseconds: 100,
		});

		expect(state.acceptedUiIntentRevision).toBe(7);
		expect(state.attemptIds).toEqual(['attempt-1']);
		expect(() =>
			reduceBridgeWorkerRenderFulfillment(state, {
				...renderReceiptIdentity(),
				kind: 'selection.accepted',
				uiIntentRevision: 8,
				atMilliseconds: 101,
				validationLeaseExpiresAtMilliseconds: 100,
			}),
		).toThrow(/lease/iu);
	});

	test.each(foreignRenderContextCases)(
		'rejects a foreign %s selection acceptance before advancing its UI revision',
		(_caseName, foreignContext) => {
			const painted = paintedFulfillment();

			expect(() =>
				reduceBridgeWorkerRenderFulfillment(painted, {
					...renderReceiptIdentity(),
					...foreignContext,
					kind: 'selection.accepted',
					uiIntentRevision: 7,
					atMilliseconds: 90,
					validationLeaseExpiresAtMilliseconds: 100,
				}),
			).toThrow(/context/iu);

			const accepted = reduceBridgeWorkerRenderFulfillment(painted, {
				...renderReceiptIdentity(),
				kind: 'selection.accepted',
				uiIntentRevision: 7,
				atMilliseconds: 90,
				validationLeaseExpiresAtMilliseconds: 100,
			});
			expect(accepted.acceptedUiIntentRevision).toBe(7);
		},
	);
});

describe('Bridge worker content availability', () => {
	test('forbids ready-to-loading demotion for one semantic window identity', () => {
		const identity = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
		const ready = reduceBridgeWorkerContentAvailability(null, {
			identity,
			state: 'ready',
		});

		expect(() =>
			reduceBridgeWorkerContentAvailability(ready, {
				identity,
				state: 'loading',
			}),
		).toThrow(/ready.*loading/iu);
	});

	test('allows a changed semantic window to start loading without rewriting the prior identity', () => {
		const firstIdentity = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
		const changedIdentity = createBridgeWorkerSemanticWindowIdentity({
			...semanticIdentityInput,
			windowDigest: { algorithm: 'sha256', digest: 'd'.repeat(64) },
		});
		const ready = reduceBridgeWorkerContentAvailability(null, {
			identity: firstIdentity,
			state: 'ready',
		});
		const replacement = reduceBridgeWorkerContentAvailability(ready, {
			identity: changedIdentity,
			state: 'loading',
		});

		expect(replacement.identity.windowKey).toBe(changedIdentity.windowKey);
		expect(ready.identity.windowKey).toBe(firstIdentity.windowKey);
	});
});

function publishedFulfillment(): BridgeWorkerRenderFulfillmentState {
	const identity = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
	let state = createBridgeWorkerRenderFulfillment({
		...canonicalRenderContext,
		identity,
		itemId: 'item-11',
		publicationId: 'render-publication-review-4-11',
		publicationSequence: 11,
		submissionId: 'submission-1',
	});
	state = reduceBridgeWorkerRenderFulfillment(state, { kind: 'preparation.started' });
	return reduceBridgeWorkerRenderFulfillment(state, {
		kind: 'publication.started',
		attemptId: 'attempt-1',
		publishedAtMilliseconds: 0,
		receiptLeaseExpiresAtMilliseconds: 100,
	});
}

function paintedFulfillment(): BridgeWorkerRenderFulfillmentState {
	let state = publishedFulfillment();
	state = reduceBridgeWorkerRenderFulfillment(state, disposition('queued'));
	state = reduceBridgeWorkerRenderFulfillment(state, disposition('applied'));
	return reduceBridgeWorkerRenderFulfillment(state, disposition('painted'));
}

type RenderDispositionReceipt = Extract<
	BridgeWorkerRenderFulfillmentEvent,
	{ kind: 'render.disposition' }
>;
type PositiveRenderDispositionReceipt = Extract<
	RenderDispositionReceipt,
	{ disposition: 'held' | 'queued' | 'applied' | 'painted' }
>;
type NegativeRenderDispositionReceipt = Extract<
	RenderDispositionReceipt,
	{ disposition: 'rejected' | 'superseded' }
>;

function disposition(
	dispositionKind: 'held' | 'queued' | 'applied' | 'painted',
): PositiveRenderDispositionReceipt;
function disposition(dispositionKind: 'rejected' | 'superseded'): NegativeRenderDispositionReceipt;
function disposition(dispositionKind: BridgeWorkerRenderDisposition): RenderDispositionReceipt {
	const receiptBase = {
		...renderReceiptIdentity(),
		kind: 'render.disposition' as const,
		receivedAtMilliseconds: 50,
	};
	switch (dispositionKind) {
		case 'held':
		case 'queued':
		case 'applied':
		case 'painted':
			return { ...receiptBase, disposition: dispositionKind };
		case 'rejected':
			return {
				...receiptBase,
				disposition: dispositionKind,
				reason: 'foreign_context',
				retryAtMilliseconds: 120,
			};
		case 'superseded':
			return {
				...receiptBase,
				disposition: dispositionKind,
				reason: 'stale_submission',
				retryAtMilliseconds: 120,
			};
	}
	return assertNever(dispositionKind);
}

function renderReceiptIdentity(): {
	readonly attemptId: string;
	readonly itemId: string;
	readonly operationCorrelationId: string | null;
	readonly paneSessionId: string;
	readonly publicationId: string;
	readonly publicationSequence: number;
	readonly submissionId: string;
	readonly surface: 'review';
	readonly windowKey: string;
	readonly workerDerivationEpoch: number;
	readonly workerInstanceId: string;
} {
	const identity = createBridgeWorkerSemanticWindowIdentity(semanticIdentityInput);
	return {
		...canonicalRenderContext,
		attemptId: 'attempt-1',
		itemId: 'item-11',
		operationCorrelationId: null,
		publicationId: 'render-publication-review-4-11',
		publicationSequence: 11,
		submissionId: 'submission-1',
		windowKey: identity.windowKey,
	};
}

function assertNever(value: never): never {
	throw new Error(`Unexpected render disposition fixture: ${String(value)}.`);
}
