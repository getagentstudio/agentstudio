import { describe, expect, test } from 'vitest';

import observationCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-operation-observation-corpus.json' with { type: 'json' };
import {
	bridgeProductOperationLateOutcomeAcknowledgementSchema,
	bridgeProductOperationObservationRequestSchema,
	bridgeProductOperationObservationResponseSchema,
} from './bridge-product-operation-observation-wire-contracts.js';

describe('Bridge product mutation observation wire', () => {
	test('round-trips revision-aware observation and late evidence', () => {
		for (const request of observationCorpus.observeRequests) {
			expect(bridgeProductOperationObservationRequestSchema.parse(request)).toEqual(request);
		}
		for (const response of observationCorpus.observeResponses) {
			expect(bridgeProductOperationObservationResponseSchema.parse(response)).toEqual(response);
		}
		for (const acknowledgement of observationCorpus.lateOutcomeAcknowledgements) {
			expect(bridgeProductOperationLateOutcomeAcknowledgementSchema.parse(acknowledgement)).toEqual(
				acknowledgement,
			);
		}
	});

	test('late evidence cannot itself be outcomeUnknown', () => {
		const late = observationCorpus.observeResponses[1];
		expect(late).toBeDefined();
		if (late === undefined) return;
		expect(
			bridgeProductOperationObservationResponseSchema.safeParse({
				...late,
				outcome: 'outcomeUnknown',
			}).success,
		).toBe(false);
	});
});
