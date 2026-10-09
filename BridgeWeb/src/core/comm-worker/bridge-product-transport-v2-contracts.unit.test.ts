import { describe, expect, test } from 'vitest';

import invalidTransportV2Corpus from '../../test-fixtures/bridge-contract-fixtures/invalid/bridge-product-transport-v2-corpus.json' with { type: 'json' };
import validProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import validStartupTranscript from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-startup-transcript.json' with { type: 'json' };
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import {
	bridgeProductOperationAdmittedResponseSchema,
	bridgeProductOperationResultAckRefusedResponseSchema,
	bridgeProductOperationResultAcknowledgementSchema,
	bridgeProductOperationResultAcknowledgedResponseSchema,
	bridgeProductOperationResultRequestSchema,
	bridgeProductOperationResultResponseSchema,
} from './bridge-product-operation-wire-contracts.js';
import {
	bridgeProductViewAcceptedResponseSchema,
	bridgeProductViewAcknowledgedResponseSchema,
	bridgeProductViewAcknowledgementRequestSchema,
	bridgeProductViewResnapshotRequestSchema,
	bridgeProductViewScopeRequestSchema,
} from './bridge-product-view-control-wire-contracts.js';

describe('Bridge product v2 kind-agnostic wire envelopes', () => {
	test('round-trips the shared startup admission and settlement transcript', () => {
		expect(validStartupTranscript.envelopeTranscript).toHaveLength(4);
		for (const entry of validStartupTranscript.envelopeTranscript) {
			switch (entry.codec) {
				case 'operationAdmittedResponse':
					expect(bridgeProductOperationAdmittedResponseSchema.parse(entry.value)).toEqual(
						entry.value,
					);
					break;
				case 'operationResultRequest':
					expect(bridgeProductOperationResultRequestSchema.parse(entry.value)).toEqual(entry.value);
					break;
				case 'operationResultResponse': {
					expect(bridgeProductOperationResultResponseSchema.parse(entry.value)).toEqual(
						entry.value,
					);
					break;
				}
				case 'operationResultAcknowledgement':
					expect(bridgeProductOperationResultAcknowledgementSchema.parse(entry.value)).toEqual(
						entry.value,
					);
					break;
				default:
					throw new Error(`Unsupported v2 startup envelope codec: ${entry.codec}`);
			}
		}
	});

	test('decodes and re-encodes the shared operation and batch corpus', () => {
		const transport = validProductSessionCorpus.transportV2;
		const cases = [
			[bridgeProductOperationAdmittedResponseSchema, transport.admittedResponses],
			[bridgeProductOperationResultRequestSchema, transport.resultRequests],
			[bridgeProductOperationResultResponseSchema, transport.resultResponses],
			[bridgeProductOperationResultAcknowledgementSchema, transport.resultAcknowledgements],
			[
				bridgeProductOperationResultAcknowledgedResponseSchema,
				transport.resultAcknowledgedResponses,
			],
			[bridgeProductOperationResultAckRefusedResponseSchema, transport.resultAckRefusedResponses],
			[bridgeProductViewScopeRequestSchema, transport.viewScopeRequests],
			[bridgeProductViewResnapshotRequestSchema, transport.viewResnapshotRequests],
			[bridgeProductViewAcknowledgementRequestSchema, transport.viewAcknowledgements],
			[bridgeProductViewAcceptedResponseSchema, transport.viewScopeAcceptedResponses],
			[bridgeProductViewAcceptedResponseSchema, transport.viewResnapshotAcceptedResponses],
			[bridgeProductViewAcknowledgedResponseSchema, transport.viewAcknowledgedResponses],
			[bridgeProductBatchFrameSchema, transport.batchFrames],
		] as const;

		for (const [schema, values] of cases) {
			for (const value of values) {
				expect(schema.parse(value)).toEqual(value);
			}
		}
		expect(transport.batchFrames).toHaveLength(12);
		expect(transport.viewScopeAcceptedResponses[0]).toMatchObject({
			kind: 'subscription.scopeAccepted',
			scopeRevision: transport.viewScopeRequests[0]?.scopeRevision,
		});
		expect(transport.viewResnapshotAcceptedResponses[0]).toMatchObject({
			kind: 'subscription.resnapshotAccepted',
			scopeRevision: transport.viewResnapshotRequests[0]?.scopeRevision,
		});
		expect(transport.viewAcknowledgedResponses[0]).toMatchObject({
			kind: 'subscription.acknowledged',
			receivedThroughDeliverySequence:
				transport.viewAcknowledgements[0]?.receivedThroughDeliverySequence,
		});
		expect(
			bridgeProductViewAcceptedResponseSchema.safeParse({
				...transport.viewScopeAcceptedResponses[0],
				installed: true,
			}).success,
		).toBe(false);
	});

	test('requires the complete sealed-batch envelope and typed settlement', () => {
		const transport = validProductSessionCorpus.transportV2;
		const batchBegin = transport.batchFrames[0];
		const batchPart = transport.batchFrames[1];
		const settled = transport.resultResponses[0];
		expect(batchBegin).toBeDefined();
		expect(batchPart).toBeDefined();
		expect(settled).toBeDefined();
		if (batchBegin === undefined || batchPart === undefined || settled === undefined) return;
		const currentSettled = bridgeProductOperationResultResponseSchema.parse(settled);

		expect(
			bridgeProductBatchFrameSchema.safeParse({ ...batchBegin, partCount: undefined }).success,
		).toBe(false);
		expect(bridgeProductBatchFrameSchema.safeParse({ ...batchBegin, scope: null }).success).toBe(
			false,
		);
		expect(
			bridgeProductBatchFrameSchema.safeParse({ ...batchBegin, publicationId: undefined }).success,
		).toBe(false);
		const fileBegin = transport.batchFrames.find(
			(frame) =>
				frame.kind === 'subscription.batchBegin' && frame.subscriptionKind === 'file.metadata',
		);
		expect(fileBegin).toBeDefined();
		if (fileBegin !== undefined) {
			expect(
				bridgeProductBatchFrameSchema.safeParse({
					...fileBegin,
					publicationId: '00000000-0000-7000-8000-000000000011',
				}).success,
			).toBe(false);
		}
		expect(
			bridgeProductBatchFrameSchema.safeParse({ ...batchPart, deliverySequence: 0 }).success,
		).toBe(false);
		expect(
			bridgeProductOperationResultResponseSchema.safeParse({
				...currentSettled,
				outcome: 'cancelled',
				result: { published: true },
			}).success,
		).toBe(false);
	});

	test('rejects an uncommitted baseline extension and repeated File change kinds', () => {
		const fileScopeRequest = validProductSessionCorpus.transportV2.viewScopeRequests.at(-1);
		expect(fileScopeRequest).toBeDefined();
		if (fileScopeRequest === undefined) return;
		expect(
			bridgeProductViewScopeRequestSchema.safeParse({
				...fileScopeRequest,
				scope: {
					kind: 'file',
					changeFilter: {
						kind: 'changes',
						kinds: ['added'],
						baseline: { kind: 'commit', oid: 'abc' },
					},
				},
			}).success,
		).toBe(false);
		expect(
			bridgeProductViewScopeRequestSchema.safeParse({
				...fileScopeRequest,
				scope: {
					kind: 'file',
					changeFilter: {
						kind: 'changes',
						kinds: ['added', 'added'],
						baseline: { kind: 'uncommitted' },
					},
				},
			}).success,
		).toBe(false);
	});

	test('rejects the shared invalid operation, batch, and receipt envelopes', () => {
		for (const response of invalidTransportV2Corpus.resultResponses) {
			expect(bridgeProductOperationResultResponseSchema.safeParse(response).success).toBe(false);
		}
		for (const frame of invalidTransportV2Corpus.batchFrames) {
			expect(bridgeProductBatchFrameSchema.safeParse(frame).success).toBe(false);
		}
		for (const acknowledgement of invalidTransportV2Corpus.viewAcknowledgements) {
			expect(bridgeProductViewAcknowledgementRequestSchema.safeParse(acknowledgement).success).toBe(
				false,
			);
		}
	});
});
