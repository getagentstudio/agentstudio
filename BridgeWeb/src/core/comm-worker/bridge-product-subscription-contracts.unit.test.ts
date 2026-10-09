import { describe, expect, test } from 'vitest';

import fileCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-file-batch-row-corpus.json' with { type: 'json' };
import { bridgeProductFileDescriptorReadyPayloadSchema } from './bridge-product-subscription-contracts.js';

const fixtureOutcome = fileCorpus.rows[0]?.row.descriptorOutcome;
if (fixtureOutcome === null || fixtureOutcome === undefined) {
	throw new Error('File descriptor outcome fixture missing.');
}

describe('Bridge product File descriptor outcome contract', () => {
	test('accepts the certified File outcome used by W4 and a binary replacement', () => {
		expect(bridgeProductFileDescriptorReadyPayloadSchema.parse(fixtureOutcome)).toEqual(
			fixtureOutcome,
		);
		const binaryOutcome = {
			...fixtureOutcome,
			availability: { availabilityKind: 'binary' },
			encoding: null,
			endsMidLine: false,
			endsWithNewline: false,
			fileExtension: null,
			language: null,
			payloadByteCount: 0,
			payloadLineCount: 0,
			totalLineCount: null,
			truncationKind: 'none',
			virtualizedExtentKind: 'unavailable',
		};
		expect(bridgeProductFileDescriptorReadyPayloadSchema.parse(binaryOutcome)).toEqual(
			binaryOutcome,
		);
	});

	test('rejects inconsistent descriptor source, prefix lengths, and old carrier fields', () => {
		const contentDescriptor =
			fixtureOutcome.availability.availabilityKind === 'available'
				? fixtureOutcome.availability.contentDescriptor
				: null;
		if (contentDescriptor === null) throw new Error('Available descriptor fixture missing.');
		for (const invalidOutcome of [
			{ ...fixtureOutcome, encoding: null },
			{ ...fixtureOutcome, payloadByteCount: fixtureOutcome.sizeBytes + 1 },
			{ ...fixtureOutcome, payloadLineCount: 2 },
			{ ...fixtureOutcome, totalLineCount: 0 },
			{ ...fixtureOutcome, endsMidLine: true, endsWithNewline: true },
			{ ...fixtureOutcome, contentHandle: 'old-content-handle' },
			{
				...fixtureOutcome,
				availability: {
					availabilityKind: 'available',
					contentDescriptor: {
						...contentDescriptor,
						source: { ...contentDescriptor.source, sourceCursor: 'another-source' },
					},
				},
			},
		]) {
			expect(bridgeProductFileDescriptorReadyPayloadSchema.safeParse(invalidOutcome).success).toBe(
				false,
			);
		}
	});
});
