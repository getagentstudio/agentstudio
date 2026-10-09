import { describe, expect, test } from 'vitest';

import validProductSessionCorpus from '../../test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json' with { type: 'json' };
import { bridgeProductBatchFrameSchema } from './bridge-product-batch-wire-contracts.js';
import { bridgeProductMetadataFrameSchema } from './bridge-product-session-contracts.js';

describe('Bridge product raw metadata application envelope', () => {
	test('requires raw application data without validating an application schema', () => {
		const fixturePart = validProductSessionCorpus.transportV2.batchFrames.find(
			(frame) => frame.kind === 'subscription.batchPart',
		);
		if (fixturePart === undefined || fixturePart.kind !== 'subscription.batchPart') {
			throw new Error('Comment batch part fixture missing.');
		}
		const rawFrame = bridgeProductBatchFrameSchema.parse({
			...fixturePart,
			part: { ...fixturePart.part, value: { applicationOwned: true } },
		});
		if (rawFrame.kind !== 'subscription.batchPart') {
			throw new Error('Parsed application fixture is not a batch part.');
		}

		expect(bridgeProductMetadataFrameSchema.parse(rawFrame)).toEqual(rawFrame);
		if (rawFrame.part.operation !== 'put') {
			throw new Error('Application fixture must be a raw put record.');
		}
		const { value: _missingValue, ...partWithoutValue } = rawFrame.part;
		expect(
			bridgeProductBatchFrameSchema.safeParse({ ...rawFrame, part: partWithoutValue }).success,
		).toBe(false);
	});
});
